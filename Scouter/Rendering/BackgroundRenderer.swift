import AppKit
import CoreImage
import Metal

enum RenderContext {
    static let ci: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}

/// Renders and caches canvas backgrounds as bitmap-backed CIImages.
final class BackgroundRenderer: @unchecked Sendable {
    static let shared = BackgroundRenderer()

    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private var thumbnails: [String: NSImage] = [:]

    func image(for setting: BackgroundSetting, size: CGSize) -> CIImage {
        let key = "\(setting)|\(Int(size.width))x\(Int(size.height))"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let extent = CGRect(origin: .zero, size: size)
        let raw = Self.makeImage(for: setting, size: size).cropped(to: extent)
        let result: CIImage
        if let cg = RenderContext.ci.createCGImage(raw, from: extent, format: .RGBA8, colorSpace: RenderContext.sRGB) {
            result = CIImage(cgImage: cg)
        } else {
            result = raw
        }

        lock.lock()
        if cache.count > 24 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }

    func thumbnail(for wallpaper: Wallpaper) -> NSImage {
        lock.lock()
        if let cached = thumbnails[wallpaper.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let size = CGSize(width: 120, height: 120)
        let image = Self.makeImage(for: .wallpaper(id: wallpaper.id), size: size).cropped(to: CGRect(origin: .zero, size: size))
        let nsImage: NSImage
        if let cg = RenderContext.ci.createCGImage(image, from: image.extent) {
            nsImage = NSImage(cgImage: cg, size: NSSize(width: 60, height: 60))
        } else {
            nsImage = NSImage(size: NSSize(width: 60, height: 60))
        }

        lock.lock()
        thumbnails[wallpaper.id] = nsImage
        lock.unlock()
        return nsImage
    }

    // MARK: - Drawing

    private static func makeImage(for setting: BackgroundSetting, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        switch setting {
        case .wallpaper(let id):
            return wallpaperImage(Wallpapers.wallpaper(id: id), size: size)
        case .gradient(let from, let to, let angle):
            return dithered(linearGradient(from: from, to: to, angleDegrees: angle, size: size), extent: extent)
        case .color(let color):
            return CIImage(color: color.ciColor).cropped(to: extent)
        case .image(let path):
            guard let nsImage = NSImage(contentsOfFile: path),
                  let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.12)).cropped(to: extent)
            }
            return aspectFill(CIImage(cgImage: cg), into: size)
        }
    }

    private static func wallpaperImage(_ wallpaper: Wallpaper, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        var image = linearGradient(from: wallpaper.from, to: wallpaper.to, angleDegrees: 35, size: size)
        let longSide = max(size.width, size.height)
        for glow in wallpaper.glows {
            // Top-left normalised coordinates -> Core Image (bottom-left origin).
            let center = CIVector(x: glow.x * size.width, y: (1 - glow.y) * size.height)
            let radial = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": 0.0,
                "inputRadius1": glow.radius * longSide,
                "inputColor0": glow.color.withAlpha(glow.color.a * 0.85).ciColor,
                "inputColor1": glow.color.withAlpha(0).ciColor,
            ])?.outputImage
            if let radial {
                image = radial.composited(over: image)
            }
        }
        return dithered(image.cropped(to: extent), extent: extent)
    }

    private static func linearGradient(from: RGBA, to: RGBA, angleDegrees: Double, size: CGSize) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        let radians = angleDegrees * .pi / 180
        // Angle is measured clockwise from "left to right" in screen space; Core Image's y axis points up.
        let dx = cos(radians)
        let dy = -sin(radians)
        let half = (abs(dx) * size.width + abs(dy) * size.height) / 2
        let cx = size.width / 2
        let cy = size.height / 2
        let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: cx - dx * half, y: cy - dy * half),
            "inputPoint1": CIVector(x: cx + dx * half, y: cy + dy * half),
            "inputColor0": from.ciColor,
            "inputColor1": to.ciColor,
        ])
        return (filter?.outputImage ?? CIImage(color: from.ciColor)).cropped(to: extent)
    }

    /// A touch of grain so smooth gradients don't band after video compression.
    private static func dithered(_ image: CIImage, extent: CGRect) -> CIImage {
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let noise = random.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.47, y: 0.47, z: 0.47, w: 1),
        ]).cropped(to: extent)
        return noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    private static func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        let dx = (size.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: CGRect(origin: .zero, size: size))
    }
}
