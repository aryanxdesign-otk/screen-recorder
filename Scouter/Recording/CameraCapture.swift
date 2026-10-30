import AVFoundation

/// Runs the webcam for the on-screen bubble preview and, while recording, writes it to its own file
/// so the editor can place and resize the bubble later.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let deviceID: String

    private let queue = DispatchQueue(label: "app.scouter.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()

    // Confined to queue.
    private var clock: RecordingClock?
    private var url: URL?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastTime = CMTime.negativeInfinity
    private var finished = false
    private var wroteFrames = false

    init?(deviceID: String) {
        guard let device = AVCaptureDevice(uniqueID: deviceID),
              let deviceInput = try? AVCaptureDeviceInput(device: device) else { return nil }
        self.deviceID = deviceID
        super.init()

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
        if session.canAddInput(deviceInput) {
            session.addInput(deviceInput)
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func startRunning() {
        queue.async {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stopRunning() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func startRecording(to url: URL, clock: RecordingClock) {
        queue.async {
            self.url = url
            self.clock = clock
            self.finished = false
            self.wroteFrames = false
            self.lastTime = .negativeInfinity
        }
    }

    /// Finishes the file. Returns true if any frames were written.
    func finishRecording() async -> Bool {
        let state: (AVAssetWriter?, Bool) = await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                self.input?.markAsFinished()
                let result = (self.writer, self.wroteFrames)
                self.writer = nil
                self.input = nil
                self.adaptor = nil
                self.clock = nil
                continuation.resume(returning: result)
            }
        }
        if let writer = state.0, writer.status == .writing {
            await writer.finishWriting()
        }
        return state.1
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock, !finished, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        var timestamp = sampleBuffer.presentationTimeStamp
        if let sessionClock = session.synchronizationClock {
            timestamp = CMSyncConvertTime(timestamp, from: sessionClock, to: CMClockGetHostTimeClock())
        }
        guard let time = clock.mediaTime(for: timestamp) else { return }
        if writer == nil {
            setUpWriter(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let input, let adaptor, input.isReadyForMoreMediaData, time > lastTime else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastTime = time
            wroteFrames = true
        }
    }

    private func setUpWriter(width: Int, height: Int) {
        guard let url, let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            finished = true
            return
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            finished = true
            return
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            finished = true
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            finished = true
            return
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }
}
