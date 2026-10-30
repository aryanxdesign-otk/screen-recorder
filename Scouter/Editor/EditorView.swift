import AVFoundation
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    CanvasHeader(model: model)
                    CanvasArea(model: model)
                }
                InspectorTabStrip(model: model)
                InspectorPanel(model: model)
                    .frame(width: 330)
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
            }
            TransportBar(model: model)
            TimelineView(model: model)
                .frame(height: 176)
        }
        .background(Theme.windowBackground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isExportPresented) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $model.isCropPresented) {
            CropSheet(model: model)
        }
    }
}

private struct CanvasHeader: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(AspectRatio.allCases) { ratio in
                    Button {
                        model.state.style.aspect = ratio
                    } label: {
                        if ratio == model.state.style.aspect {
                            Label("\(ratio.title)  \(ratio.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(ratio.title)  \(ratio.detail)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "aspectratio")
                    Text(model.state.style.aspect.title)
                    Text(model.state.style.aspect.detail)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.isCropPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "crop")
                    Text("Crop")
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(model.media == nil)

            Spacer()

            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 20)
        .frame(height: 40)
    }
}

private struct CanvasArea: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let canvas = model.previewCanvasSize
            let available = CGSize(width: max(geo.size.width - 40, 10), height: max(geo.size.height - 24, 10))
            let scale = min(available.width / canvas.width, available.height / canvas.height)
            let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
            ZStack {
                PlayerView(player: model.player)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                if model.media == nil && model.loadError == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlayback() }
        }
    }
}

private struct InspectorTabStrip: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    model.inspectorTab = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.inspectorTab == tab ? Theme.accent : Color.white.opacity(0.6))
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(model.inspectorTab == tab ? Theme.accent.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.horizontal, 8)
    }
}

struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Button { model.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut("b", modifiers: .command)
                    .help("Split clip at playhead (⌘B)")
                Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selection == nil)
                    .help("Delete selected clip or zoom (⌫)")
                Button { model.addZoom(atOutput: model.currentTime) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut("z", modifiers: [])
                    .help("Add zoom at playhead (Z)")
            }
            .frame(width: 200, alignment: .leading)

            Spacer()

            Text(formatTimecode(model.currentTime))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 80, alignment: .trailing)
            Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(IconButtonStyle())
                .help("Go to start")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(IconButtonStyle(size: 36))
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause (Space)")
            Button { model.seek(to: model.duration) } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(IconButtonStyle())
                .help("Go to end")
            Text(formatTimecode(model.duration))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 80, alignment: .leading)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(Theme.tertiaryText)
                Slider(value: $model.timelineZoom, in: 1...12)
                    .controlSize(.mini)
                    .frame(width: 120)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 12))
            .frame(width: 200, alignment: .trailing)
            .help("Zoom the timeline")
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
