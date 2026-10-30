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
    private var video: VideoTrackWriter?

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
            self.clock = clock
            // The file is created from the first frame, so it matches the camera's actual size.
            self.video = VideoTrackWriter(url: url, settings: VideoTrackWriter.cameraSettings)
        }
    }

    /// Finishes the file. Returns true if any frames were written.
    func finishRecording() async -> Bool {
        let video: VideoTrackWriter? = await withCheckedContinuation { continuation in
            queue.async {
                let video = self.video
                self.video = nil
                self.clock = nil
                continuation.resume(returning: video)
            }
        }
        guard let video else { return false }
        return await video.finish(on: queue, end: nil)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock, let video, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        var timestamp = sampleBuffer.presentationTimeStamp
        if let sessionClock = session.synchronizationClock {
            timestamp = CMSyncConvertTime(timestamp, from: sessionClock, to: CMClockGetHostTimeClock())
        }
        guard let time = clock.mediaTime(for: timestamp) else { return }
        video.append(pixelBuffer, at: time)
    }
}
