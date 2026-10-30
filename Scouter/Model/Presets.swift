import Combine
import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: StyleSettings
    var camera: CameraOverlaySettings
}

/// Saved looks (background, padding, corners, shadow, zoom, motion blur, camera bubble).
/// The default preset is applied to every new recording.
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published private(set) var presets: [Preset] = []
    @Published private(set) var defaultPresetID: UUID?

    private struct StoredPresets: Codable {
        var presets: [Preset]
        var defaultPresetID: UUID?
    }

    private var fileURL: URL { ProjectStore.appSupportURL.appendingPathComponent("presets.json") }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(StoredPresets.self, from: data) {
            presets = stored.presets
            defaultPresetID = stored.defaultPresetID
        }
    }

    var defaultPreset: Preset? {
        presets.first { $0.id == defaultPresetID }
    }

    @discardableResult
    func add(name: String, style: StyleSettings, camera: CameraOverlaySettings) -> Preset {
        let preset = Preset(name: name, style: style, camera: camera)
        presets.append(preset)
        save()
        return preset
    }

    func update(_ id: UUID, style: StyleSettings, camera: CameraOverlaySettings) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].style = style
        presets[i].camera = camera
        save()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if defaultPresetID == id { defaultPresetID = nil }
        save()
    }

    func setDefault(_ id: UUID?) {
        defaultPresetID = id
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(StoredPresets(presets: presets, defaultPresetID: defaultPresetID)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
