import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = RecorderController()
    private var editors: [EditorWindowController] = []
    private var launchedWithProject = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        MainMenu.install(target: self)
        ProjectStore.ensureRootFolder()
        recorder.onProjectCreated = { [weak self] url in
            self?.openProject(at: url)
        }
        if !launchedWithProject {
            recorder.showBar()
        }
        NSApp.activate()
    }

    // Spotlight / Finder / Dock relaunch of an already running app lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        recorder.showBar()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithProject = true
        for url in urls {
            openProject(at: url)
        }
    }

    func openProject(at url: URL) {
        if let existing = editors.first(where: { $0.projectURL.standardizedFileURL == url.standardizedFileURL }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        do {
            let project = try Project.open(at: url)
            let controller = EditorWindowController(project: project)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.editors.removeAll { $0 === controller }
            }
            controller.onDeleteProject = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.deleteProject(controller)
            }
            editors.append(controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } catch {
            Alerts.show(title: "Couldn't open project", message: error.localizedDescription)
        }
    }

    private func deleteProject(_ controller: EditorWindowController) {
        let confirmed = Alerts.confirm(
            title: "Move this recording to the Trash?",
            message: "\"\(controller.model.project.name)\" and its edits will be moved to the Trash.",
            confirmTitle: "Move to Trash"
        )
        guard confirmed else { return }
        let url = controller.projectURL
        controller.close()
        NSWorkspace.shared.recycle([url]) { _, _ in }
    }

    private var activeEditor: EditorWindowController? {
        editors.first { $0.window == NSApp.keyWindow } ?? editors.first { $0.window == NSApp.mainWindow }
    }

    @objc func newRecording(_ sender: Any?) {
        recorder.showBar()
    }

    @objc func openProjectPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectStore.rootURL
        panel.message = "Choose a Scouter recording"
        if panel.runModal() == .OK, let url = panel.url {
            openProject(at: url)
        }
    }

    @objc func undoEdit(_ sender: Any?) {
        activeEditor?.model.undo()
    }

    @objc func redoEdit(_ sender: Any?) {
        activeEditor?.model.redo()
    }
}

@MainActor
enum Alerts {
    static func show(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    static func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func askForText(title: String, message: String, defaultValue: String, confirmTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
