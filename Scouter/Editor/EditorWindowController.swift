import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let model: EditorModel
    var onClose: (() -> Void)?
    var onDeleteProject: (() -> Void)?

    var projectURL: URL { model.project.url }

    private static let leadingItem = NSToolbarItem.Identifier("scouter.leading")
    private static let titleItem = NSToolbarItem.Identifier("scouter.title")
    private static let trailingItem = NSToolbarItem.Identifier("scouter.trailing")

    init(project: Project) {
        model = EditorModel(project: project)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = project.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.075, alpha: 1)
        window.minSize = NSSize(width: 1100, height: 720)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "ScouterEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.delegate = self
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        model.load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        model.teardown()
        onClose?()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leadingItem, .flexibleSpace, Self.titleItem, .flexibleSpace, Self.trailingItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = false
        let view: NSView
        switch itemIdentifier {
        case Self.leadingItem:
            view = NSHostingView(rootView: ToolbarLeading(
                reveal: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.projectURL])
                },
                delete: { [weak self] in self?.onDeleteProject?() }
            ))
        case Self.titleItem:
            view = NSHostingView(rootView: ToolbarTitle(name: model.project.name))
        case Self.trailingItem:
            view = NSHostingView(rootView: ToolbarTrailing(model: model))
        default:
            return nil
        }
        view.setFrameSize(view.fittingSize)
        item.view = view
        return item
    }
}

private struct ToolbarLeading: View {
    let reveal: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: reveal) {
                Image(systemName: "folder")
            }
            .help("Show recording in Finder")
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .help("Move recording to Trash")
        }
        .buttonStyle(IconButtonStyle())
        .font(.system(size: 14))
        .foregroundStyle(Color.white.opacity(0.8))
        .fixedSize()
    }
}

private struct ToolbarTitle: View {
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .foregroundStyle(Color.white.opacity(0.9))
            Text(".scouter")
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: 420)
        .fixedSize()
    }
}

private struct ToolbarTrailing: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var presets = PresetStore.shared

    var body: some View {
        HStack(spacing: 6) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(IconButtonStyle())
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 4)

            Menu {
                if presets.presets.isEmpty {
                    Text("No presets yet")
                }
                ForEach(presets.presets) { preset in
                    Button(preset.id == presets.defaultPresetID ? "\(preset.name) (default)" : preset.name) {
                        model.apply(preset)
                    }
                }
                Divider()
                Button("Save Current Style as Preset…") { savePreset() }
                if !presets.presets.isEmpty {
                    Menu("Update Preset With Current Style") {
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { presets.update(preset.id, style: model.state.style, camera: model.state.camera) }
                        }
                    }
                    Menu("Default for New Recordings") {
                        Button("None") { presets.setDefault(nil) }
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { presets.setDefault(preset.id) }
                        }
                    }
                    Menu("Delete Preset") {
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { presets.delete(preset.id) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Presets")
                }
                .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.isExportPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .command)
            .help("Export (⌘E)")
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.white.opacity(0.85))
        .fixedSize()
    }

    private func savePreset() {
        let name = Alerts.askForText(
            title: "Save preset",
            message: "Saves the background, padding, corners, shadow, zoom, motion blur and camera bubble settings.",
            defaultValue: "Preset \(presets.presets.count + 1)",
            confirmTitle: "Save"
        )
        guard let name else { return }
        let preset = presets.add(name: name, style: model.state.style, camera: model.state.camera)
        if presets.presets.count == 1 {
            presets.setDefault(preset.id)
        }
    }
}
