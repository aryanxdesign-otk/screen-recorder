import AppKit
import AVFoundation
import ScreenCaptureKit

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
    private var video: VideoTrackWriter?
    private var latestFrame: CVPixelBuffer?
    private var writing = false

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

        let video = VideoTrackWriter(url: Project.screenURL(in: folder), settings: VideoTrackWriter.screenSettings)
        try video.start(width: width, height: height)
        self.video = video
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

    /// Call after `clock.start()`. The most recent frame becomes frame zero so the
    /// video starts immediately even if the screen is static.
    func beginWriting() {
        videoQueue.async {
            self.writing = true
            if let frame = self.latestFrame {
                self.video?.append(frame, at: .zero)
            }
        }
    }

    func stop(at end: CMTime) async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoQueue.async {
                self.writing = false
                self.latestFrame = nil
                continuation.resume()
            }
        }
        _ = await video?.finish(on: videoQueue, end: end)
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
                self.writing = false
                self.latestFrame = nil
                self.video?.cancel()
                continuation.resume()
            }
        }
        await systemAudio?.finish(on: audioQueue)
        await microphone?.finish(on: micQueue)
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
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        guard writing else {
            // Keep the latest frame during the countdown so recording starts on a real frame.
            latestFrame = pixelBuffer
            return
        }
        latestFrame = nil
        guard let time = clock.mediaTime(for: sampleBuffer.presentationTimeStamp) else { return }
        video?.append(pixelBuffer, at: time)
    }
}
