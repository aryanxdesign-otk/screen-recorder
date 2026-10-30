import AVFoundation

/// Writes video frames to a QuickTime file.
///
/// Not thread-safe: call `start`/`append` from one serial queue and pass that queue to `finish`.
final class VideoTrackWriter: @unchecked Sendable {
    typealias Settings = (_ width: Int, _ height: Int) -> [String: Any]

    private let url: URL
    private let makeSettings: Settings
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var failed = false
    private var finished = false
    private(set) var lastTime = CMTime.negativeInfinity
    private(set) var frameCount = 0

    init(url: URL, settings: @escaping Settings) {
        self.url = url
        self.makeSettings = settings
    }

    /// Creates the file. `append` calls this with the first frame's size if it wasn't called earlier.
    func start(width: Int, height: Int) throws {
        guard writer == nil else { return }
        do {
            let settings = makeSettings(width, height)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw ScouterError.writerFailed("The video encoder doesn't support \(width)×\(height).")
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw ScouterError.writerFailed("Couldn't add the video track.")
            }
            writer.add(input)
            // AVFoundation raises an exception if the adaptor is created after writing has started.
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.startWriting() else {
                throw ScouterError.writerFailed(writer.error?.localizedDescription ?? "Couldn't start writing.")
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        } catch {
            failed = true
            throw error
        }
    }

    /// Appends a frame at a media time. Frames that arrive while the encoder is busy, or out of order, are dropped.
    @discardableResult
    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard !finished, !failed else { return false }
        if writer == nil {
            do {
                try start(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            } catch {
                return false
            }
        }
        guard let writer, let input, let adaptor, writer.status == .writing,
              input.isReadyForMoreMediaData, time > lastTime,
              adaptor.append(pixelBuffer, withPresentationTime: time) else { return false }
        lastTime = time
        frameCount += 1
        return true
    }

    /// Closes the file. `end` extends the last frame so the file covers the whole recording.
    /// Returns true if a playable file was written; an empty file is deleted.
    func finish(on queue: DispatchQueue, end: CMTime?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                if let writer = self.writer, writer.status == .writing {
                    self.input?.markAsFinished()
                }
                continuation.resume()
            }
        }
        guard let writer else { return false }
        guard frameCount > 0 else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            return false
        }
        if writer.status == .writing {
            if let end {
                writer.endSession(atSourceTime: end > lastTime ? end : lastTime)
            }
            await writer.finishWriting()
        }
        return writer.status == .completed
    }

    /// Abandons the file. Call on the owning queue.
    func cancel() {
        finished = true
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
    }

    // MARK: - Settings

    /// HEVC for the screen: efficient at Retina sizes, no B-frames so the editor can scrub quickly.
    static func screenSettings(width: Int, height: Int) -> [String: Any] {
        let bitrate = min(Double(width * height) * 6, 90_000_000)
        return [
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
    }

    static func cameraSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
    }
}

/// Writes one audio stream (system audio or microphone) to an AAC file, retimed onto the recording clock.
/// The file is created from the first buffer so it matches the device's format.
///
/// Not thread-safe: call `append` from one serial queue and pass that queue to `finish`.
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
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a),
              writer.canApply(outputSettings: settings, forMediaType: .audio) else {
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
    }

    /// Closes the file. Returns true if any audio was written; an empty file is deleted.
    @discardableResult
    func finish(on queue: DispatchQueue) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                if let writer = self.writer, writer.status == .writing {
                    self.input?.markAsFinished()
                }
                continuation.resume()
            }
        }
        if let writer, writer.status == .writing {
            if hasSamples {
                await writer.finishWriting()
            } else {
                writer.cancelWriting()
            }
        }
        if !hasSamples || writer?.status != .completed {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }
}
