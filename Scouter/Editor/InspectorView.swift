import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                switch model.inspectorTab {
                case .background: BackgroundInspector(model: model)
                case .zoom: ZoomInspector(model: model)
                case .camera: CameraInspector(model: model)
                case .audio: AudioInspector(model: model)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
    }
}

private struct InspectorDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}

// MARK: - Background

private struct BackgroundInspector: View {
    @ObservedObject var model: EditorModel

    private var background: BackgroundSetting { model.state.style.background }

    private var kind: Binding<BackgroundSetting.Kind> {
        Binding(
            get: { background.kind },
            set: { newKind in
                guard newKind != background.kind else { return }
                switch newKind {
                case .wallpaper:
                    model.state.style.background = .wallpaper(id: Wallpapers.defaultID)
                case .gradient:
                    model.state.style.background = .gradient(from: RGBA(hex: 0x6366F1), to: RGBA(hex: 0xEC4899), angle: 45)
                case .color:
                    model.state.style.background = .color(RGBA(hex: 0x1F2937))
                case .image:
                    chooseImage()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Background")
                Picker("", selection: kind) {
                    ForEach(BackgroundSetting.Kind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch background {
            case .wallpaper(let id):
                wallpaperGrid(selected: id)
            case .gradient(let from, let to, let angle):
                gradientEditor(from: from, to: to, angle: angle)
            case .color(let color):
                ColorPicker("Color", selection: Binding(
                    get: { color.color },
                    set: { model.state.style.background = .color(RGBA($0)) }
                ), supportsOpacity: false)
                .font(.system(size: 13))
            case .image(let path):
                imageEditor(path: path)
            }

            InspectorDivider()

            SliderRow(title: "Padding", value: $model.state.style.padding, range: 0...0.25)
            SliderRow(title: "Corners", value: $model.state.style.cornerRadius, range: 0...1)
            SliderRow(title: "Shadow", value: $model.state.style.shadow, range: 0...1)
        }
    }

    private func wallpaperGrid(selected: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 9), count: 5), alignment: .leading, spacing: 9) {
                ForEach(Wallpapers.all) { wallpaper in
                    Button {
                        model.state.style.background = .wallpaper(id: wallpaper.id)
                    } label: {
                        Image(nsImage: BackgroundRenderer.shared.thumbnail(for: wallpaper))
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(wallpaper.id == selected ? Color.white : Color.white.opacity(0.1), lineWidth: wallpaper.id == selected ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(wallpaper.name)
                }
            }
            Button {
                let options = Wallpapers.all.filter { $0.id != selected }
                if let pick = options.randomElement() {
                    model.state.style.background = .wallpaper(id: pick.id)
                }
            } label: {
                Label("Pick random wallpaper", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func gradientEditor(from: RGBA, to: RGBA, angle: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                ColorPicker("From", selection: Binding(
                    get: { from.color },
                    set: { model.state.style.background = .gradient(from: RGBA($0), to: to, angle: angle) }
                ), supportsOpacity: false)
                ColorPicker("To", selection: Binding(
                    get: { to.color },
                    set: { model.state.style.background = .gradient(from: from, to: RGBA($0), angle: angle) }
                ), supportsOpacity: false)
            }
            .font(.system(size: 13))
            SliderRow(
                title: "Angle",
                value: Binding(
                    get: { angle },
                    set: { model.state.style.background = .gradient(from: from, to: to, angle: $0) }
                ),
                range: 0...360,
                format: { "\(Int($0))°" }
            )
        }
    }

    private func imageEditor(path: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose Image…") { chooseImage() }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        if panel.runModal() == .OK, let url = panel.url {
            model.state.style.background = .image(path: url.path)
        }
    }
}

// MARK: - Zoom

private struct ZoomInspector: View {
    @ObservedObject var model: EditorModel
    @State private var frameImage: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let zoom = model.selectedZoom {
                selectedZoomEditor(zoom)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Zoom")
                    Text("Select a zoom on the timeline to edit it. Click an empty spot on the zoom track, or press Z, to add one at the playhead.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorDivider()

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Auto zoom on clicks")
                SliderRow(
                    title: "Default zoom level",
                    value: $model.state.style.zoomScale,
                    range: 1.1...4,
                    format: { String(format: "%.1f×", $0) }
                )
                Text(coverageText(model.state.style.zoomScale))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                HStack {
                    Button("Apply to all zooms") { model.applyDefaultScaleToAllZooms() }
                    Button("Re-detect zooms") { model.regenerateAutoZooms() }
                        .help("Rebuild automatic zooms from the \(model.info.cursor.clicks.count) recorded clicks. Zooms you added or edited are kept.")
                }
                .controlSize(.small)
            }

            InspectorDivider()

            SliderRow(title: "Motion blur", value: $model.state.style.motionBlur, range: 0...1)
            Text("Subtle blur while the camera zooms in, zooms out and pans.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func selectedZoomEditor(_ zoom: ZoomRegion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(title: "Selected zoom")
                Spacer()
                Text(String(format: "%.1fs", zoom.duration))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }

            SliderRow(
                title: "Zoom level",
                value: Binding(get: { zoom.scale }, set: { value in model.updateZoom(zoom.id) { $0.scale = value } }),
                range: 1.1...4,
                format: { String(format: "%.1f×", $0) }
            )
            Text(coverageText(zoom.scale))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Focus")
                Picker("", selection: Binding(
                    get: { zoom.mode },
                    set: { mode in
                        let focus = model.cursorFocus(atSource: zoom.start)
                        model.updateZoom(zoom.id) {
                            if mode == .manual && $0.mode == .auto { $0.focus = focus }
                            $0.mode = mode
                        }
                    }
                )) {
                    ForEach(ZoomFocusMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if zoom.mode == .auto {
                    Text("Follows your clicks and cursor while zoomed in.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    FocusPicker(
                        image: frameImage,
                        crop: model.state.crop,
                        focus: Binding(get: { zoom.focus }, set: { value in model.updateZoom(zoom.id) { $0.focus = value } }),
                        scale: zoom.scale,
                        aspect: model.state.contentAspect(sourceSize: model.sourceSize)
                    )
                    Text("Drag to choose where to zoom.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .task(id: zoom.id) {
                frameImage = await model.sourceFrame(atSource: (zoom.start + zoom.end) / 2)
            }

            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Label("Remove zoom", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    private func coverageText(_ scale: Double) -> String {
        "Shows about \(Int((100 / (scale * scale)).rounded()))% of the screen"
    }
}

struct FocusPicker: View {
    let image: CGImage?
    let crop: CGRect
    @Binding var focus: CGPoint
    let scale: Double
    let aspect: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let viewWidth = size.width / max(scale, 1)
            let viewHeight = size.height / max(scale, 1)
            let cx = (focus.x * size.width).clamped(to: (viewWidth / 2)...(size.width - viewWidth / 2))
            let cy = (focus.y * size.height).clamped(to: (viewHeight / 2)...(size.height - viewHeight / 2))
            let window = CGRect(x: cx - viewWidth / 2, y: cy - viewHeight / 2, width: viewWidth, height: viewHeight)

            ZStack(alignment: .topLeading) {
                if let cropped = croppedImage() {
                    Image(decorative: cropped, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else {
                    Color.white.opacity(0.06)
                }
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(window)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: viewWidth, height: viewHeight)
                    .offset(x: window.minX, y: window.minY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        focus = CGPoint(
                            x: (value.location.x / size.width).clamped(to: 0...1),
                            y: (value.location.y / size.height).clamped(to: 0...1)
                        )
                    }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func croppedImage() -> CGImage? {
        guard let image else { return nil }
        let rect = CGRect(
            x: crop.minX * Double(image.width),
            y: crop.minY * Double(image.height),
            width: crop.width * Double(image.width),
            height: crop.height * Double(image.height)
        ).integral
        return image.cropping(to: rect) ?? image
    }
}

// MARK: - Camera

private struct CameraInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Camera")
            if !model.info.hasCamera {
                Text("No camera was recorded. Pick a camera in the recording bar to get a webcam bubble in your next recording.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Show camera bubble", isOn: $model.state.camera.visible)
                    .toggleStyle(.switch)
                    .font(.system(size: 13))
                SliderRow(title: "Size", value: $model.state.camera.size, range: 0.1...0.4)
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Position")
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            cornerButton(.topLeft)
                            cornerButton(.topRight)
                        }
                        GridRow {
                            cornerButton(.bottomLeft)
                            cornerButton(.bottomRight)
                        }
                    }
                }
                Toggle("Mirror camera", isOn: $model.state.camera.mirrored)
                    .toggleStyle(.switch)
                    .font(.system(size: 13))
            }
        }
    }

    private func cornerButton(_ corner: OverlayCorner) -> some View {
        let selected = model.state.camera.corner == corner
        let alignment: Alignment = switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
        return Button {
            model.state.camera.corner = corner
        } label: {
            ZStack(alignment: alignment) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.12 : 0.04))
                Circle()
                    .fill(selected ? Theme.accent : Color.white.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .padding(8)
            }
            .frame(width: 136, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(corner.title)
    }
}

// MARK: - Audio

private struct AudioInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Audio")
            if !model.info.hasMicrophone && !model.info.hasSystemAudio {
                Text("This recording has no audio. Choose a microphone or turn on computer sound in the recording bar to record audio next time.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Button("Mute all") {
                        model.state.audio.micEnabled = false
                        model.state.audio.systemEnabled = false
                    }
                    Button("Use full audio") {
                        model.state.audio = AudioSettings()
                    }
                }
                .controlSize(.small)
            }
            AudioTrackRow(
                title: "Microphone",
                symbol: "mic.fill",
                available: model.info.hasMicrophone,
                enabled: $model.state.audio.micEnabled,
                volume: $model.state.audio.micVolume
            )
            InspectorDivider()
            AudioTrackRow(
                title: "Computer sound",
                symbol: "speaker.wave.2.fill",
                available: model.info.hasSystemAudio,
                enabled: $model.state.audio.systemEnabled,
                volume: $model.state.audio.systemVolume
            )
        }
    }
}

private struct AudioTrackRow: View {
    let title: String
    let symbol: String
    let available: Bool
    @Binding var enabled: Bool
    @Binding var volume: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(available && enabled ? Theme.accent : Theme.tertiaryText)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if available {
                    Toggle("", isOn: $enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                } else {
                    Text("Not recorded")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            if available {
                SliderRow(title: "Volume", value: $volume, range: 0...1.5)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.4)
            }
        }
    }
}
