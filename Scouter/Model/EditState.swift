import CoreGraphics
import Foundation

/// A kept piece of the source recording. Times are in source seconds.
struct ClipSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

enum ZoomFocusMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case manual

    var id: String { rawValue }
    var title: String { self == .auto ? "Auto" : "Manual" }
}

/// A zoom on the timeline. Times are in source seconds so zooms stay attached to
/// their content when the clip is cut. `focus` is normalised to the cropped content
/// (0,0 top-left … 1,1 bottom-right) and only used in manual mode.
struct ZoomRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double
    var mode: ZoomFocusMode = .auto
    var focus = CGPoint(x: 0.5, y: 0.5)
    var isAutomatic = false

    var duration: Double { end - start }
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case auto
    case wide
    case vertical
    case square
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .wide: "Wide"
        case .vertical: "Vertical"
        case .square: "Square"
        case .standard: "Standard"
        }
    }

    var detail: String {
        switch self {
        case .auto: "Match recording"
        case .wide: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .standard: "4:3"
        }
    }

    func ratio(contentAspect: Double) -> Double {
        switch self {
        case .auto: contentAspect
        case .wide: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        case .square: 1
        case .standard: 4.0 / 3.0
        }
    }

    /// Output size whose short side is `shortSide` pixels (720p / 1080p), rounded to even numbers.
    static func canvasSize(ratio: Double, shortSide: Double) -> CGSize {
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
        if ratio >= 1 {
            return CGSize(width: even(shortSide * ratio), height: even(shortSide))
        } else {
            return CGSize(width: even(shortSide), height: even(shortSide / ratio))
        }
    }
}

enum BackgroundSetting: Codable, Equatable, Hashable {
    case wallpaper(id: String)
    case gradient(from: RGBA, to: RGBA, angle: Double)
    case color(RGBA)
    case image(path: String)

    enum Kind: String, CaseIterable, Identifiable {
        case wallpaper, gradient, color, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wallpaper: "Wallpaper"
            case .gradient: "Gradient"
            case .color: "Color"
            case .image: "Image"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .wallpaper: .wallpaper
        case .gradient: .gradient
        case .color: .color
        case .image: .image
        }
    }
}

/// Everything that a preset captures.
struct StyleSettings: Codable, Equatable {
    var background: BackgroundSetting = .wallpaper(id: Wallpapers.defaultID)
    /// Space around the recording, as a fraction of the canvas' short side.
    var padding: Double = 0.08
    /// 0…1, mapped to a radius relative to the canvas.
    var cornerRadius: Double = 0.45
    /// 0…1 shadow strength.
    var shadow: Double = 0.55
    var aspect: AspectRatio = .wide
    /// 0…1 strength of the motion blur applied while the camera zooms or pans.
    var motionBlur: Double = 0.5
    /// Zoom level given to new zooms (auto and manual). 1.7× shows ~35% of the screen.
    var zoomScale: Double = 1.7
}

enum OverlayCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        }
    }
}

struct CameraOverlaySettings: Codable, Equatable {
    var visible = true
    /// Diameter as a fraction of the canvas' short side.
    var size: Double = 0.22
    var corner: OverlayCorner = .bottomLeft
    var mirrored = true
}

struct AudioSettings: Codable, Equatable {
    var micEnabled = true
    var micVolume: Double = 1
    var systemEnabled = true
    var systemVolume: Double = 1
}

struct EditState: Codable, Equatable {
    var segments: [ClipSegment]
    var zooms: [ZoomRegion]
    /// Normalised crop of the source (top-left origin).
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var style: StyleSettings
    var camera: CameraOverlaySettings
    var audio: AudioSettings

    func contentAspect(sourceSize: CGSize) -> Double {
        let w = crop.width * sourceSize.width
        let h = crop.height * sourceSize.height
        guard w > 0, h > 0 else { return 16.0 / 9.0 }
        return w / h
    }

    func canvasSize(shortSide: Double, sourceSize: CGSize) -> CGSize {
        let ratio = style.aspect.ratio(contentAspect: contentAspect(sourceSize: sourceSize))
        return AspectRatio.canvasSize(ratio: ratio, shortSide: shortSide)
    }
}
