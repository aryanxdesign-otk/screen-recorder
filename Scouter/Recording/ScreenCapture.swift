import AppKit
import AVFoundation
import ScreenCaptureKit

/// Writes one audio stream (system audio or microphone) to an AAC file.
/// The writer is created lazily from the first buffer so it matches the device's format.
final class AudioTrackWriter: @unchecked Sendable {
    private let url: URL
    private let clock: RecordingClock
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var finished = false
    private var failedSetup = false
    private(set) var hasSamples = false

    init(url: URL, clock: RecordingClock) {
        self.url = url
        self.clock = clock
    }

    /// Must be called on the owning queue.
    func append(_ buffer: CMSampleBuffer) {
        guard !finished, !failedSetup, buffer.isValid,
              let time = clock.mediaTime(for: buffer.presentationTimeStamp) else { return }
        if writer == nil { setUp(with: buffer) }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData,
              let retimed = buffer.retimed(to: time) else { return }
        if input.append(retimed) {
            hasSamples = true
        }
    }

    private func setUp(with buffer: CMSampleBuffer) {
        guard let format = buffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            failedSetup = true
            return
        }
        let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                failedSetup = true
                return
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                failedSetup = true
                return
            }
            writer.add(input)
            guard writer.startWriting() else {
                failedSetup = true
                return
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
        } catch {
            failedSetup = true
        }
    }

    func finish(on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                self.input?.markAsFinished()
                continuation.resume()
            }
        }
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }
        if !hasSamples {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Captures a display, window or area with ScreenCaptureKit and writes it to disk.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Setup {
        let pixelSize: CGSize
        /// Captured area in global Quartz coordinates (points, top-left origin). Used to map the cursor.
        let captureRect: CGRect
    }

    private let clock: RecordingClock
    private let folder: URL
    private var stream: SCStream?

    private let videoQueue = DispatchQueue(label: "app.scouter.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.scouter.capture.audio", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "app.scouter.capture.mic", qos: .userInteractive)

    // Confined to videoQueue.
    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var latestFrame: CVPixelBuffer?
    private var lastVideoTime = CMTime.negativeInfinity
    private var writing = false
    private var videoFinished = false

    private var systemAudio: AudioTrackWriter?
    private var microphone: AudioTrackWriter?

    var onStreamError: ((Error) -> Void)?

    var recordedSystemAudio: Bool { systemAudio?.hasSamples ?? false }
    var recordedMicrophone: Bool { microphone?.hasSamples ?? false }

    init(clock: RecordingClock, folder: URL) {
        self.clock = clock
        self.folder = folder
        super.init()
    }

    /// Starts the stream (frames are buffered but not written until `beginWriting`).
    func prepare(target: CaptureTarget, captureSystemAudio: Bool, microphoneID: String?) async throws -> Setup {
        // Not limited to on-screen windows: Scouter's own panels are hidden at this point, and we
        // still need its SCRunningApplication so the countdown and controls are excluded from capture.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }

        let filter: SCContentFilter
        let captureRect: CGRect
        var sourceRect: CGRect?
        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScouterError.noDisplay }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            captureRect = display.frame
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw ScouterError.noWindow }
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureRect = window.frame
        case .area(let id, let rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScouterError.noDisplay }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            let clipped = rect.intersection(bounds).integral
            sourceRect = clipped
            captureRect = clipped.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        }

        let scale = CGFloat(filter.pointPixelScale)
        let pointSize = sourceRect?.size ?? filter.contentRect.size
        func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let width = even(pointSize.width * scale)
        let height = even(pointSize.height * scale)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = captureSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        if let microphoneID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = microphoneID
        }

        try setUpVideoWriter(width: width, height: height)
        if captureSystemAudio {
            systemAudio = AudioTrackWriter(url: Project.systemAudioURL(in: folder), clock: clock)
        }
        if microphoneID != nil {
            microphone = AudioTrackWriter(url: Project.micURL(in: folder), clock: clock)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if microphoneID != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        try await stream.startCapture()
        self.stream = stream

        return Setup(pixelSize: CGSize(width: width, height: height), captureRect: captureRect)
    }

    private func setUpVideoWriter(width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: Project.screenURL(in: folder), fileType: .mov)
        let bitrate = min(Double(width * height) * 6, 90_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw ScouterError.writerFailed("The video encoder doesn't support \(width)×\(height).")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw ScouterError.writerFailed("Couldn't add the video track.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ScouterError.writerFailed(writer.error?.localizedDescription ?? "Couldn't start writing.")
        }
        writer.startSession(atSourceTime: .zero)
        videoWriter = writer
        videoInput = input
        self.adaptor = adaptor
    }

    /// Call after `clock.start()`. The most recent frame becomes frame zero so the
    /// video starts immediately even if the screen is static.
    func beginWriting() {
        videoQueue.async {
            self.writing = true
            if let frame = self.latestFrame {
                self.appendVideo(frame, at: .zero)
            }
        }
    }

    func stop(at end: CMTime) async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        let lastTime: CMTime = await withCheckedContinuation { continuation in
            videoQueue.async {
                self.videoFinished = true
                self.latestFrame = nil
                self.videoInput?.markAsFinished()
                continuation.resume(returning: self.lastVideoTime)
            }
        }
        if let writer = videoWriter, writer.status == .writing {
            writer.endSession(atSourceTime: end > lastTime ? end : lastTime)
            await writer.finishWriting()
        }
        await systemAudio?.finish(on: audioQueue)
        await microphone?.finish(on: micQueue)
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoQueue.async {
                self.videoFinished = true
                self.latestFrame = nil
                self.videoWriter?.cancelWriting()
                continuation.resume()
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            systemAudio?.append(sampleBuffer)
        case .microphone:
            microphone?.append(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamError?(error)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !videoFinished, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        latestFrame = pixelBuffer
        guard writing, let time = clock.mediaTime(for: sampleBuffer.presentationTimeStamp) else { return }
        appendVideo(pixelBuffer, at: time)
    }

    private func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData, time > lastVideoTime else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastVideoTime = time
        }
    }
}
