import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

/// State shown by the recording bar.
@MainActor
final class RecorderModel: ObservableObject {
    @Published var cameras: [CaptureDevice] = []
    @Published var microphones: [CaptureDevice] = []
    @Published var selectedCameraID: String?
    @Published var selectedMicrophoneID: String?
    @Published var captureSystemAudio = false
    @Published var activeMode: CaptureMode?

    weak var controller: RecorderController?

    var cameraTitle: String {
        cameras.first { $0.id == selectedCameraID }?.name ?? "No camera"
    }

    var microphoneTitle: String {
        microphones.first { $0.id == selectedMicrophoneID }?.name ?? "No microphone"
    }

    func refreshDevices() {
        cameras = DeviceCatalog.cameras()
        microphones = DeviceCatalog.microphones()
        if let id = selectedCameraID, !cameras.contains(where: { $0.id == id }) { selectedCameraID = nil }
        if let id = selectedMicrophoneID, !microphones.contains(where: { $0.id == id }) { selectedMicrophoneID = nil }
    }

    func selectCamera(_ id: String?) {
        selectedCameraID = id
        controller?.updateCameraPreview()
    }

    func selectMicrophone(_ id: String?) {
        selectedMicrophoneID = id
        if id != nil {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    func chooseMode(_ mode: CaptureMode) {
        controller?.beginSelection(mode)
    }

    func close() {
        controller?.hideBar()
    }
}

/// Drives the whole capture flow: bar → pick target → countdown → recording controls → editor.
@MainActor
final class RecorderController: NSObject {
    let model = RecorderModel()
    var onProjectCreated: ((URL) -> Void)?

    private var bar: RecorderBarPanel?
    private var overlay: SelectionOverlayController?
    private var countdown: CountdownPanel?
    private var controls: RecordingControlsPanel?
    private let controlsModel = RecordingControlsModel()
    private var bubble: CameraBubblePanel?
    private var camera: CameraCapture?
    private var session: RecordingSession?
    private var elapsedTimer: Timer?
    private var isStarting = false

    override init() {
        super.init()
        model.controller = self
        controlsModel.onTogglePause = { [weak self] in self?.togglePause() }
        controlsModel.onStop = { [weak self] in self?.stopRecording() }
        controlsModel.onDiscard = { [weak self] in self?.discardRecording() }
    }

    private var isBarVisible: Bool { bar?.isVisible ?? false }

    // MARK: - Bar

    func showBar() {
        if session != nil || isStarting {
            controls?.orderFrontRegardless()
            return
        }
        model.refreshDevices()
        let bar = self.bar ?? RecorderBarPanel(model: model)
        self.bar = bar
        bar.present(on: NSScreen.withMouse)
        updateCameraPreview()
        NSApp.activate()
    }

    func hideBar() {
        cancelSelection()
        bar?.orderOut(nil)
        updateCameraPreview()
    }

    // MARK: - Camera preview

    func updateCameraPreview() {
        let shouldShow = (isBarVisible || session != nil || isStarting) && model.selectedCameraID != nil
        guard shouldShow, let id = model.selectedCameraID else {
            bubble?.orderOut(nil)
            if session == nil {
                camera?.stopRunning()
                camera = nil
            }
            return
        }
        if camera?.deviceID != id {
            camera?.stopRunning()
            camera = CameraCapture(deviceID: id)
            bubble?.orderOut(nil)
            bubble = nil
        }
        guard let camera else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor [weak self] in
                guard let self, granted else { return }
                camera.startRunning()
                let bubble = self.bubble ?? CameraBubblePanel(session: camera.session)
                self.bubble = bubble
                if !bubble.isVisible {
                    bubble.place(on: self.bar?.screen ?? NSScreen.withMouse)
                }
                bubble.orderFrontRegardless()
            }
        }
    }

    // MARK: - Target selection

    func beginSelection(_ mode: CaptureMode) {
        Task {
            guard await ensureScreenRecordingPermission() else { return }
            overlay?.close()
            model.activeMode = mode
            let overlay = SelectionOverlayController(mode: mode)
            overlay.onSelect = { [weak self] target in self?.startRecording(target) }
            overlay.onCancel = { [weak self] in self?.cancelSelection() }
            self.overlay = overlay
            await overlay.show()
            bar?.orderFrontRegardless()
            bubble?.orderFrontRegardless()
        }
    }

    func cancelSelection() {
        overlay?.close()
        overlay = nil
        model.activeMode = nil
    }

    private func ensureScreenRecordingPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Scouter needs Screen Recording permission"
            alert.informativeText = "Turn on Scouter in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Scouter."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }

    // MARK: - Recording

    private func startRecording(_ target: CaptureTarget) {
        guard session == nil, !isStarting else { return }
        isStarting = true
        let screen = Self.screen(for: target)
        overlay?.close()
        overlay = nil
        model.activeMode = nil
        bar?.orderOut(nil)

        Task {
            if model.selectedMicrophoneID != nil {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted {
                    Alerts.show(title: "Microphone access is off", message: "Allow Scouter in System Settings → Privacy & Security → Microphone, or choose “No microphone”.")
                    isStarting = false
                    showBar()
                    return
                }
            }

            let session: RecordingSession
            do {
                session = try RecordingSession(
                    target: target,
                    captureSystemAudio: model.captureSystemAudio,
                    microphoneID: model.selectedMicrophoneID,
                    camera: camera
                )
                try await session.prepare()
            } catch {
                isStarting = false
                Alerts.show(title: "Couldn't start recording", message: error.localizedDescription)
                showBar()
                return
            }
            session.onStreamError = { [weak self] error in
                self?.handleStreamError(error)
            }
            self.session = session

            let countdown = CountdownPanel(screen: screen)
            self.countdown = countdown
            await countdown.run()
            self.countdown = nil

            session.go()
            isStarting = false
            NSApp.deactivate()

            controlsModel.elapsed = 0
            controlsModel.isPaused = false
            let controls = self.controls ?? RecordingControlsPanel(model: controlsModel)
            self.controls = controls
            controls.present(on: screen)
            startElapsedTimer()
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.controlsModel.elapsed = session.elapsed
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func togglePause() {
        guard let session else { return }
        if session.isPaused {
            session.resume()
        } else {
            session.pause()
        }
        controlsModel.isPaused = session.isPaused
    }

    private func stopRecording() {
        guard let session else { return }
        elapsedTimer?.invalidate()
        controls?.orderOut(nil)
        Task {
            do {
                let url = try await session.finish()
                self.session = nil
                updateCameraPreview()
                onProjectCreated?(url)
            } catch {
                self.session = nil
                updateCameraPreview()
                Alerts.show(title: "Couldn't save the recording", message: error.localizedDescription)
            }
        }
    }

    private func discardRecording() {
        guard let session else { return }
        guard Alerts.confirm(title: "Discard this recording?", message: "It will be deleted.", confirmTitle: "Discard") else { return }
        elapsedTimer?.invalidate()
        controls?.orderOut(nil)
        Task {
            await session.cancel()
            self.session = nil
            showBar()
        }
    }

    private func handleStreamError(_ error: Error) {
        guard session != nil else { return }
        // The stream stopped underneath us (e.g. the window closed). Save what we have.
        stopRecording()
    }

    private static func screen(for target: CaptureTarget) -> NSScreen {
        switch target {
        case .display(let id), .area(let id, _):
            return NSScreen.screen(for: id) ?? NSScreen.withMouse
        case .window:
            return NSScreen.withMouse
        }
    }
}
