import Foundation

/// Built-in procedural wallpapers: a diagonal base gradient with a few soft colour glows.
struct Wallpaper: Identifiable {
    struct Glow {
        let color: RGBA
        /// Normalised centre, top-left origin.
        let x: Double
        let y: Double
        /// Radius as a fraction of the canvas' long side.
        let radius: Double
    }

    let id: String
    let name: String
    let from: RGBA
    let to: RGBA
    let glows: [Glow]
}

enum Wallpapers {
    static let defaultID = "dusk"

    static let all: [Wallpaper] = [
        Wallpaper(id: "dusk", name: "Dusk", from: RGBA(hex: 0x1E1B4B), to: RGBA(hex: 0x4C1D95), glows: [
            .init(color: RGBA(hex: 0x8B5CF6), x: 0.15, y: 0.2, radius: 0.7),
            .init(color: RGBA(hex: 0xEC4899), x: 0.9, y: 0.85, radius: 0.6),
            .init(color: RGBA(hex: 0x3B82F6), x: 0.8, y: 0.1, radius: 0.45),
        ]),
        Wallpaper(id: "lagoon", name: "Lagoon", from: RGBA(hex: 0x083344), to: RGBA(hex: 0x115E59), glows: [
            .init(color: RGBA(hex: 0x2DD4BF), x: 0.2, y: 0.8, radius: 0.65),
            .init(color: RGBA(hex: 0x22D3EE), x: 0.85, y: 0.2, radius: 0.55),
            .init(color: RGBA(hex: 0xA7F3D0), x: 0.55, y: 0.5, radius: 0.3),
        ]),
        Wallpaper(id: "ember", name: "Ember", from: RGBA(hex: 0x431407), to: RGBA(hex: 0x7C2D12), glows: [
            .init(color: RGBA(hex: 0xF97316), x: 0.8, y: 0.25, radius: 0.6),
            .init(color: RGBA(hex: 0xEF4444), x: 0.15, y: 0.85, radius: 0.6),
            .init(color: RGBA(hex: 0xFBBF24), x: 0.5, y: 0.05, radius: 0.35),
        ]),
        Wallpaper(id: "aurora", name: "Aurora", from: RGBA(hex: 0x0B1026), to: RGBA(hex: 0x0F2E3F), glows: [
            .init(color: RGBA(hex: 0x34D399), x: 0.25, y: 0.65, radius: 0.6),
            .init(color: RGBA(hex: 0x6366F1), x: 0.8, y: 0.25, radius: 0.6),
            .init(color: RGBA(hex: 0x22D3EE), x: 0.6, y: 0.9, radius: 0.4),
        ]),
        Wallpaper(id: "peach", name: "Peach", from: RGBA(hex: 0xFED7C3), to: RGBA(hex: 0xF9A8A0), glows: [
            .init(color: RGBA(hex: 0xFDE68A), x: 0.15, y: 0.15, radius: 0.6),
            .init(color: RGBA(hex: 0xF472B6), x: 0.9, y: 0.9, radius: 0.55),
            .init(color: RGBA(hex: 0xFFFFFF, alpha: 0.6), x: 0.6, y: 0.35, radius: 0.35),
        ]),
        Wallpaper(id: "midnight", name: "Midnight", from: RGBA(hex: 0x020617), to: RGBA(hex: 0x111827), glows: [
            .init(color: RGBA(hex: 0x1E3A8A), x: 0.2, y: 0.25, radius: 0.7),
            .init(color: RGBA(hex: 0x312E81), x: 0.85, y: 0.8, radius: 0.6),
            .init(color: RGBA(hex: 0x0EA5E9, alpha: 0.5), x: 0.75, y: 0.15, radius: 0.35),
        ]),
        Wallpaper(id: "mint", name: "Mint", from: RGBA(hex: 0xD1FAE5), to: RGBA(hex: 0x99F6E4), glows: [
            .init(color: RGBA(hex: 0x6EE7B7), x: 0.8, y: 0.8, radius: 0.6),
            .init(color: RGBA(hex: 0xBAE6FD), x: 0.15, y: 0.2, radius: 0.6),
            .init(color: RGBA(hex: 0xFDE68A, alpha: 0.7), x: 0.6, y: 0.1, radius: 0.35),
        ]),
        Wallpaper(id: "grape", name: "Grape", from: RGBA(hex: 0x2E1065), to: RGBA(hex: 0x581C87), glows: [
            .init(color: RGBA(hex: 0xA855F7), x: 0.2, y: 0.8, radius: 0.6),
            .init(color: RGBA(hex: 0xD946EF), x: 0.85, y: 0.3, radius: 0.55),
            .init(color: RGBA(hex: 0x6366F1), x: 0.5, y: 0.0, radius: 0.4),
        ]),
        Wallpaper(id: "sand", name: "Sand", from: RGBA(hex: 0xF5E6D3), to: RGBA(hex: 0xE2C9A6), glows: [
            .init(color: RGBA(hex: 0xFDBA74), x: 0.85, y: 0.2, radius: 0.55),
            .init(color: RGBA(hex: 0xFEF3C7), x: 0.2, y: 0.75, radius: 0.6),
            .init(color: RGBA(hex: 0xD6B48A, alpha: 0.7), x: 0.6, y: 0.95, radius: 0.35),
        ]),
        Wallpaper(id: "ocean", name: "Ocean", from: RGBA(hex: 0x0C4A6E), to: RGBA(hex: 0x1E3A8A), glows: [
            .init(color: RGBA(hex: 0x38BDF8), x: 0.2, y: 0.2, radius: 0.6),
            .init(color: RGBA(hex: 0x1D4ED8), x: 0.85, y: 0.85, radius: 0.6),
            .init(color: RGBA(hex: 0x67E8F9, alpha: 0.6), x: 0.7, y: 0.3, radius: 0.3),
        ]),
        Wallpaper(id: "rose", name: "Rose", from: RGBA(hex: 0x4C0519), to: RGBA(hex: 0x9F1239), glows: [
            .init(color: RGBA(hex: 0xFB7185), x: 0.8, y: 0.2, radius: 0.6),
            .init(color: RGBA(hex: 0xF472B6), x: 0.2, y: 0.85, radius: 0.55),
            .init(color: RGBA(hex: 0xFDA4AF, alpha: 0.6), x: 0.5, y: 0.5, radius: 0.3),
        ]),
        Wallpaper(id: "citrus", name: "Citrus", from: RGBA(hex: 0xFDE047), to: RGBA(hex: 0xFB923C), glows: [
            .init(color: RGBA(hex: 0xFEF9C3), x: 0.2, y: 0.15, radius: 0.55),
            .init(color: RGBA(hex: 0xF43F5E, alpha: 0.7), x: 0.9, y: 0.9, radius: 0.55),
            .init(color: RGBA(hex: 0xA3E635, alpha: 0.5), x: 0.05, y: 0.9, radius: 0.4),
        ]),
        Wallpaper(id: "glacier", name: "Glacier", from: RGBA(hex: 0xE0F2FE), to: RGBA(hex: 0xC7D2FE), glows: [
            .init(color: RGBA(hex: 0xFFFFFF, alpha: 0.8), x: 0.25, y: 0.25, radius: 0.55),
            .init(color: RGBA(hex: 0x93C5FD), x: 0.85, y: 0.75, radius: 0.6),
            .init(color: RGBA(hex: 0xC4B5FD), x: 0.1, y: 0.95, radius: 0.4),
        ]),
        Wallpaper(id: "graphite", name: "Graphite", from: RGBA(hex: 0x111827), to: RGBA(hex: 0x374151), glows: [
            .init(color: RGBA(hex: 0x6B7280), x: 0.8, y: 0.2, radius: 0.55),
            .init(color: RGBA(hex: 0x1F2937), x: 0.2, y: 0.85, radius: 0.6),
            .init(color: RGBA(hex: 0x9CA3AF, alpha: 0.4), x: 0.45, y: 0.4, radius: 0.3),
        ]),
        Wallpaper(id: "forest", name: "Forest", from: RGBA(hex: 0x052E16), to: RGBA(hex: 0x14532D), glows: [
            .init(color: RGBA(hex: 0x22C55E), x: 0.8, y: 0.8, radius: 0.55),
            .init(color: RGBA(hex: 0x84CC16, alpha: 0.7), x: 0.2, y: 0.2, radius: 0.5),
            .init(color: RGBA(hex: 0x0D9488), x: 0.55, y: 0.45, radius: 0.35),
        ]),
    ]

    static func wallpaper(id: String) -> Wallpaper {
        all.first { $0.id == id } ?? all[0]
    }
}
