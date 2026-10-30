import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4
    case gif

    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4" : "GIF" }
    var fileExtension: String { rawValue }
}

enum ExportResolution: Int, CaseIterable, Identifiable {
    case p720 = 720
    case p1080 = 1080

    var id: Int { rawValue }
    var title: String { "\(rawValue)p" }
}

struct ExportOptions {
    var format: ExportFormat = .mp4
    var resolution: ExportResolution = .p1080
    var fps: Int32 = 60

    static let gifFPS: Int32 = 15
}

/// Renders the edited project to an MP4 (H.264 + AAC) or an animated GIF.
final class Exporter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AVAssetExportSession?
    private var reader: AVAssetReader?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let session = self.session
        let reader = self.reader
        lock.unlock()
        session?.cancelExport()
        reader?.cancelReading()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func export(
        media: LoadedMedia,
        info: RecordingInfo,
        state: EditState,
        options: ExportOptions,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let built = try CompositionBuilder.build(
            media: media,
            segments: state.segments,
            includeMic: state.audio.micEnabled && state.audio.micVolume > 0,
            includeSystemAudio: state.audio.systemEnabled && state.audio.systemVolume > 0
        )
        let canvas = state.canvasSize(shortSide: Double(options.resolution.rawValue), sourceSize: info.sourceSize)
        let cameraPath = CameraPath(zooms: state.zooms, cursor: info.cursor, crop: state.crop, duration: info.duration)
        let snapshot = RenderSnapshot(state: state, sourceSize: info.sourceSize, canvas: canvas, cameraPath: cameraPath)
        try? FileManager.default.removeItem(at: url)

        switch options.format {
        case .mp4:
            let videoComposition = CompositionBuilder.videoComposition(for: built, snapshot: snapshot, fps: options.fps)
            let audioMix = CompositionBuilder.audioMix(for: built, audio: state.audio)
            try await exportMovie(built: built, videoComposition: videoComposition, audioMix: audioMix, to: url, progress: progress)
        case .gif:
            let videoComposition = CompositionBuilder.videoComposition(for: built, snapshot: snapshot, fps: ExportOptions.gifFPS)
            try exportGIF(built: built, videoComposition: videoComposition, to: url, progress: progress)
        }
    }

    private func exportMovie(
        built: BuiltComposition,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ScouterError.exportFailed("This Mac can't create an export session.")
        }
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        lock.lock()
        self.session = session
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw CancellationError() }

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        poller.cancel()

        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw CancellationError()
        default:
            throw ScouterError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
        }
    }

    private func exportGIF(
        built: BuiltComposition,
        videoComposition: AVVideoComposition,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: built.videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ScouterError.exportFailed("Couldn't read the composition.") }
        reader.add(output)

        lock.lock()
        self.reader = reader
        lock.unlock()

        guard reader.startReading() else {
            throw ScouterError.exportFailed(reader.error?.localizedDescription ?? "Couldn't start reading.")
        }

        // Frames are kept PNG-compressed in memory, because a GIF destination needs the exact frame count up front.
        var frames: [Data] = []
        let total = max(built.duration.seconds, 0.001)
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let buffer = sample.imageBuffer else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = RenderContext.ci.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: RenderContext.sRGB),
                  let png = Self.pngData(cg) else { continue }
            frames.append(png)
            progress(min(sample.presentationTimeStamp.seconds / total, 1) * 0.8)
        }
        if reader.status == .failed {
            throw ScouterError.exportFailed(reader.error?.localizedDescription ?? "Reading frames failed.")
        }
        guard !frames.isEmpty else { throw ScouterError.exportFailed("No frames were rendered.") }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ScouterError.exportFailed("Couldn't create the GIF file.")
        }
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let delay = 1.0 / Double(ExportOptions.gifFPS)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ]
        for (index, data) in frames.enumerated() {
            if isCancelled { throw CancellationError() }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            progress(0.8 + 0.2 * Double(index + 1) / Double(frames.count))
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ScouterError.exportFailed("Couldn't finish writing the GIF.")
        }
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
