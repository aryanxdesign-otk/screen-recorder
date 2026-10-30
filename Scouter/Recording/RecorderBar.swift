import AppKit
import SwiftUI

/// The floating capture bar shown when Scouter is opened.
final class RecorderBarPanel: NSPanel {
    private let hosting: NSHostingView<RecorderBarView>

    init(model: RecorderModel) {
        hosting = NSHostingView(rootView: RecorderBarView(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 84), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .scouterBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    func present(on screen: NSScreen) {
        let size = hosting.fittingSize
        setContentSize(size)
        let frame = screen.visibleFrame
        setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 72))
        orderFrontRegardless()
        makeKey()
    }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? NSHostingView<RecorderBarView>)?.rootView.model.close()
    }
}

struct RecorderBarView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(.horizontal, 20)

            BarDivider()

            HStack(spacing: 4) {
                ForEach(CaptureMode.allCases) { mode in
                    ModeButton(mode: mode, isActive: model.activeMode == mode) {
                        model.chooseMode(mode)
                    }
                }
            }
            .padding(.horizontal, 12)

            BarDivider()

            HStack(spacing: 2) {
                DeviceMenu(
                    title: model.cameraTitle,
                    symbol: model.selectedCameraID == nil ? "video.slash" : "video",
                    isOn: model.selectedCameraID != nil,
                    width: 170
                ) {
                    Button("No camera") { model.selectCamera(nil) }
                    if !model.cameras.isEmpty { Divider() }
                    ForEach(model.cameras) { camera in
                        Button {
                            model.selectCamera(camera.id)
                        } label: {
                            if camera.id == model.selectedCameraID {
                                Label(camera.name, systemImage: "checkmark")
                            } else {
                                Text(camera.name)
                            }
                        }
                    }
                }

                DeviceMenu(
                    title: model.microphoneTitle,
                    symbol: model.selectedMicrophoneID == nil ? "mic.slash" : "mic",
                    isOn: model.selectedMicrophoneID != nil,
                    width: 190
                ) {
                    Button("No microphone") { model.selectMicrophone(nil) }
                    if !model.microphones.isEmpty { Divider() }
                    ForEach(model.microphones) { mic in
                        Button {
                            model.selectMicrophone(mic.id)
                        } label: {
                            if mic.id == model.selectedMicrophoneID {
                                Label(mic.name, systemImage: "checkmark")
                            } else {
                                Text(mic.name)
                            }
                        }
                    }
                }

                Button {
                    model.captureSystemAudio.toggle()
                } label: {
                    BarItemLabel(
                        title: model.captureSystemAudio ? "Computer sound" : "No computer sound",
                        symbol: model.captureSystemAudio ? "speaker.wave.2" : "speaker.slash",
                        isOn: model.captureSystemAudio,
                        width: 200
                    )
                }
                .buttonStyle(.plain)
                .help("Record sound from your Mac (apps, videos, notifications)")
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }
}

private struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 52)
    }
}

private struct ModeButton: View {
    let mode: CaptureMode
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .frame(height: 26)
                Text(mode.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(isActive || hovering ? 1 : 0.72))
            .frame(width: 78, height: 62)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.2 : (hovering ? 0.1 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Record \(mode.title.lowercased())")
    }
}

private struct BarItemLabel: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let width: CGFloat
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white.opacity(isOn || hovering ? 1 : 0.6))
        .padding(.horizontal, 12)
        .frame(width: width, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct DeviceMenu<Content: View>: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            BarItemLabel(title: title, symbol: symbol, isOn: isOn, width: width)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
