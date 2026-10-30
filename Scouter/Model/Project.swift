import Foundation

enum ScouterError: LocalizedError {
    case notAProject
    case missingMedia
    case noDisplay
    case noWindow
    case writerFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAProject: "This folder isn't a Scouter recording."
        case .missingMedia: "The screen recording file is missing or unreadable."
        case .noDisplay: "The selected display is no longer available."
        case .noWindow: "The selected window is no longer available."
        case .writerFailed(let message): "Recording failed: \(message)"
        case .exportFailed(let message): "Export failed: \(message)"
        }
    }
}

/// A recording on disk: `<name>.scouter/` holding the raw media plus the edit state.
final class Project {
    let url: URL
    let info: RecordingInfo
    var state: EditState

    var name: String { url.deletingPathExtension().lastPathComponent }
    var screenURL: URL { Project.screenURL(in: url) }
    var cameraURL: URL { Project.cameraURL(in: url) }
    var micURL: URL { Project.micURL(in: url) }
    var systemAudioURL: URL { Project.systemAudioURL(in: url) }

    static func screenURL(in folder: URL) -> URL { folder.appendingPathComponent("screen.mov") }
    static func cameraURL(in folder: URL) -> URL { folder.appendingPathComponent("camera.mov") }
    static func micURL(in folder: URL) -> URL { folder.appendingPathComponent("microphone.m4a") }
    static func systemAudioURL(in folder: URL) -> URL { folder.appendingPathComponent("system-audio.m4a") }
    private static func infoURL(in folder: URL) -> URL { folder.appendingPathComponent("recording.json") }
    private static func stateURL(in folder: URL) -> URL { folder.appendingPathComponent("project.json") }

    private init(url: URL, info: RecordingInfo, state: EditState) {
        self.url = url
        self.info = info
        self.state = state
    }

    static func open(at url: URL) throws -> Project {
        let infoData: Data
        do {
            infoData = try Data(contentsOf: infoURL(in: url))
        } catch {
            throw ScouterError.notAProject
        }
        let info = try JSONDecoder().decode(RecordingInfo.self, from: infoData)
        let state: EditState
        if let data = try? Data(contentsOf: stateURL(in: url)),
           let decoded = try? JSONDecoder().decode(EditState.self, from: data) {
            state = decoded
        } else {
            state = initialState(for: info, style: StyleSettings(), camera: CameraOverlaySettings())
        }
        return Project(url: url, info: info, state: state)
    }

    /// Writes recording metadata plus a fresh edit state (with auto zooms) for a just-finished recording.
    static func create(at url: URL, info: RecordingInfo, style: StyleSettings, camera: CameraOverlaySettings) throws {
        let encoder = JSONEncoder()
        try encoder.encode(info).write(to: infoURL(in: url), options: .atomic)
        let state = initialState(for: info, style: style, camera: camera)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL(in: url), options: .atomic)
    }

    static func initialState(for info: RecordingInfo, style: StyleSettings, camera: CameraOverlaySettings) -> EditState {
        EditState(
            segments: [ClipSegment(start: 0, end: info.duration)],
            zooms: AutoZoom.regions(clicks: info.cursor.clicks, duration: info.duration, scale: style.zoomScale),
            style: style,
            camera: camera,
            audio: AudioSettings()
        )
    }

    func saveState() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: Project.stateURL(in: url), options: .atomic)
    }
}

enum ProjectStore {
    static var rootURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Scouter", isDirectory: true)
    }

    static func ensureRootFolder() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    static func makeNewProjectFolder() throws -> URL {
        ensureRootFolder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Recording \(formatter.string(from: Date()))"
        var url = rootURL.appendingPathComponent("\(base).scouter", isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = rootURL.appendingPathComponent("\(base) \(index).scouter", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("Scouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
