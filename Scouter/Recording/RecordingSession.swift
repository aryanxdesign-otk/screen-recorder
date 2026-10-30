import AppKit
import AVFoundation

/// One recording in progress: screen (+ system audio + mic), optional camera, and cursor track,
/// all on a shared clock so they line up in the editor.
@MainActor
final class RecordingSession {
    let folder: URL
    let target: CaptureTarget
    let clock = RecordingClock()

    private let screen: ScreenCapture
    private let camera: CameraCapture?
    private let captureSystemAudio: Bool
    private let microphoneID: String?
    private var mouse: MouseTracker?
    private var setup: ScreenCapture.Setup?

    var onStreamError: ((Error) -> Void)? {
        didSet {
            let handler = onStreamError
            screen.onStreamError = { error in
                Task { @MainActor in handler?(error) }
            }
        }
    }

    init(target: CaptureTarget, captureSystemAudio: Bool, microphoneID: String?, camera: CameraCapture?) throws {
        self.folder = try ProjectStore.makeNewProjectFolder()
        self.target = target
        self.captureSystemAudio = captureSystemAudio
        self.microphoneID = microphoneID
        self.camera = camera
        self.screen = ScreenCapture(clock: clock, folder: folder)
    }

    func prepare() async throws {
        let setup = try await screen.prepare(target: target, captureSystemAudio: captureSystemAudio, microphoneID: microphoneID)
        self.setup = setup
        mouse = MouseTracker(clock: clock, captureRect: setup.captureRect)
    }

    func go() {
        clock.start()
        screen.beginWriting()
        camera?.startRecording(to: Project.cameraURL(in: folder), clock: clock)
        mouse?.start()
    }

    var isPaused: Bool { clock.isPaused }
    var elapsed: Double { clock.elapsed().seconds }

    func pause() { clock.pause() }
    func resume() { clock.resume() }

    /// Stops everything and writes the project. Returns the project folder.
    func finish() async throws -> URL {
        clock.pause()
        let end = clock.elapsed()
        mouse?.stop()
        await screen.stop(at: end)
        let hasCamera = await camera?.finishRecording() ?? false
        if !hasCamera {
            try? FileManager.default.removeItem(at: Project.cameraURL(in: folder))
        }

        guard let setup else { throw ScouterError.missingMedia }
        let info = RecordingInfo(
            createdAt: Date(),
            duration: max(end.seconds, 0.1),
            pixelWidth: Int(setup.pixelSize.width),
            pixelHeight: Int(setup.pixelSize.height),
            hasCamera: hasCamera,
            hasMicrophone: screen.recordedMicrophone,
            hasSystemAudio: screen.recordedSystemAudio,
            cursor: mouse?.track ?? CursorTrack()
        )
        let preset = PresetStore.shared.defaultPreset
        try Project.create(
            at: folder,
            info: info,
            style: preset?.style ?? StyleSettings(),
            camera: preset?.camera ?? CameraOverlaySettings()
        )
        return folder
    }

    func cancel() async {
        mouse?.stop()
        await screen.cancel()
        _ = await camera?.finishRecording()
        try? FileManager.default.removeItem(at: folder)
    }
}
