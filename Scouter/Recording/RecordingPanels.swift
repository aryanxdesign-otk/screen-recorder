import AppKit
import AVFoundation
import SwiftUI

// MARK: - Countdown

@MainActor
final class CountdownModel: ObservableObject {
    @Published var value = 3
}

/// 3-2-1 shown before recording starts. Excluded from the capture along with all of Scouter's windows.
final class CountdownPanel: NSPanel {
    private let model = CountdownModel()

    init(screen: NSScreen) {
        let size = CGSize(width: 180, height: 180)
        let frame = screen.frame
        super.init(
            contentRect: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .scouterCountdown
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: CountdownView(model: model))
    }

    func run(from start: Int = 3) async {
        orderFrontRegardless()
        for value in stride(from: start, to: 0, by: -1) {
            model.value = value
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        orderOut(nil)
    }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .background(VisualEffectBackground(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous)))
            Text("\(model.value)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.value)
        }
        .frame(width: 180, height: 180)
    }
}

// MARK: - Recording controls

@MainActor
final class RecordingControlsModel: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var isPaused = false
    var onTogglePause: () -> Void = {}
    var onStop: () -> Void = {}
    var onDiscard: () -> Void = {}
}

/// Stop / pause / discard pill shown while recording. Never appears in the recording.
final class RecordingControlsPanel: NSPanel {
    private let hosting: NSHostingView<RecordingControlsView>

    init(model: RecordingControlsModel) {
        hosting = NSHostingView(rootView: RecordingControlsView(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .scouterBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = hosting
    }

    func present(on screen: NSScreen) {
        let size = hosting.fittingSize
        setContentSize(size)
        let frame = screen.visibleFrame
        setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
        orderFrontRegardless()
    }
}

private struct RecordingControlsView: View {
    @ObservedObject var model: RecordingControlsModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(model.isPaused ? 1 : (pulse ? 0.35 : 1))
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                Text(formatClock(model.elapsed))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 52, alignment: .leading)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)

            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 24)

            ControlButton(symbol: model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Resume" : "Pause", action: model.onTogglePause)
            ControlButton(symbol: "stop.fill", help: "Stop and edit", tint: Color(red: 1, green: 0.36, blue: 0.36), action: model.onStop)
            ControlButton(symbol: "trash", help: "Discard recording", action: model.onDiscard)
                .padding(.trailing, 6)
        }
        .frame(height: 48)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
        .onAppear { pulse = true }
    }

    private func formatClock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ControlButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Camera bubble

/// Loom-style round webcam preview in the bottom corner. It's only a preview for you:
/// the camera is recorded to its own file and composited in the editor.
final class CameraBubblePanel: NSPanel {
    init(session: AVCaptureSession, diameter: CGFloat = 180) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .scouterBubble
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        view.wantsLayer = true
        view.layer?.cornerRadius = diameter / 2
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)

        let ring = CALayer()
        ring.frame = view.bounds
        ring.cornerRadius = diameter / 2
        ring.borderWidth = 3
        ring.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        view.layer?.addSublayer(ring)

        contentView = view
    }

    func place(on screen: NSScreen) {
        let frame = screen.visibleFrame
        setFrameOrigin(NSPoint(x: frame.minX + 36, y: frame.minY + 36))
    }
}
