import CoreImage
import Foundation

/// Layout of the recording inside the output canvas. All rects use a top-left origin.
struct SceneGeometry {
    let canvas: CGSize
    let contentRect: CGRect

    init(canvas: CGSize, contentAspect: Double, padding: Double) {
        self.canvas = canvas
        let inset = padding * min(canvas.width, canvas.height)
        let available = CGSize(width: max(canvas.width - 2 * inset, 1), height: max(canvas.height - 2 * inset, 1))
        var width = available.width
        var height = width / contentAspect
        if height > available.height {
            height = available.height
            width = height * contentAspect
        }
        contentRect = CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
    }

    func focusPoint(_ focus: CGPoint) -> CGPoint {
        CGPoint(x: contentRect.minX + focus.x * contentRect.width, y: contentRect.minY + focus.y * contentRect.height)
    }

    /// The part of the canvas that is visible at a given zoom. Once zoomed past the padding,
    /// the view is kept inside the recording so the background doesn't creep in at the edges.
    func viewRect(scale: Double, focus: CGPoint) -> CGRect {
        let s = max(scale, 1)
        let size = CGSize(width: canvas.width / s, height: canvas.height / s)
        let center = focusPoint(focus)

        func axis(center: Double, size: Double, lo: Double, hi: Double, total: Double) -> Double {
            if size <= hi - lo {
                return min(max(center - size / 2, lo), hi - size)
            }
            let centered = (lo + hi) / 2 - size / 2
            return min(max(centered, 0), total - size)
        }

        let x = axis(center: center.x, size: size.width, lo: contentRect.minX, hi: contentRect.maxX, total: canvas.width)
        let y = axis(center: center.y, size: size.height, lo: contentRect.minY, hi: contentRect.maxY, total: canvas.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Immutable bundle of everything needed to render frames for one edit state.
final class RenderSnapshot: @unchecked Sendable {
    let state: EditState
    let canvas: CGSize
    let geometry: SceneGeometry
    /// Crop rect in source pixels, Core Image coordinates.
    let cropRect: CGRect
    let timeMap: TimeMap
    let cameraPath: CameraPath
    let background: CIImage
    let cornerRadius: Double

    init(state: EditState, sourceSize: CGSize, canvas: CGSize, cameraPath: CameraPath) {
        self.state = state
        self.canvas = canvas
        self.cameraPath = cameraPath
        let crop = state.crop
        cropRect = CGRect(
            x: crop.minX * sourceSize.width,
            y: (1 - crop.maxY) * sourceSize.height,
            width: max(crop.width * sourceSize.width, 1),
            height: max(crop.height * sourceSize.height, 1)
        )
        geometry = SceneGeometry(canvas: canvas, contentAspect: cropRect.width / cropRect.height, padding: state.style.padding)
        timeMap = TimeMap(segments: state.segments)
        background = BackgroundRenderer.shared.image(for: state.style.background, size: canvas)
        cornerRadius = state.style.cornerRadius * 0.05 * min(canvas.width, canvas.height)
    }
}

enum FrameRenderer {
    static func render(snapshot: RenderSnapshot, outputTime: Double, screen: CIImage?, camera: CIImage?) -> CIImage {
        let state = snapshot.state
        let canvas = snapshot.canvas
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let unit = min(canvas.width, canvas.height) / 1080
        let geometry = snapshot.geometry

        let sourceTime = snapshot.timeMap.sourceTime(atOutput: outputTime)
        let camState = snapshot.cameraPath.state(at: sourceTime)
        let view = geometry.viewRect(scale: camState.scale, focus: camState.focus)
        let s = canvas.width / view.width

        // Canvas (top-left) -> output (Core Image, bottom-left) for the current camera.
        let H = canvas.height
        let cameraTransform = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -view.minX * s, ty: H - s * (H - view.minY))

        var scene = snapshot.background.transformed(by: cameraTransform)

        let content = geometry.contentRect
        let placed = CGRect(
            x: (content.minX - view.minX) * s,
            y: H - (content.maxY - view.minY) * s,
            width: content.width * s,
            height: content.height * s
        )
        let radius = min(snapshot.cornerRadius * s, min(placed.width, placed.height) / 2)

        if state.style.shadow > 0.01 {
            scene = shadow(for: placed, radius: radius, strength: state.style.shadow, scale: s * unit).composited(over: scene)
        }

        let screenImage = screen ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: snapshot.cropRect)
        let fitted = place(screenImage, crop: snapshot.cropRect, into: placed)
        scene = roundCorners(fitted, rect: placed, radius: radius).composited(over: scene).cropped(to: canvasRect)

        if state.style.motionBlur > 0.01 {
            scene = applyMotionBlur(to: scene, snapshot: snapshot, sourceTime: sourceTime, view: view, scale: s, focus: camState.focus, unit: unit)
        }

        if let camera, state.camera.visible {
            scene = cameraBubble(camera, settings: state.camera, canvas: canvas).composited(over: scene)
        }

        return scene.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvasRect)).cropped(to: canvasRect)
    }

    // MARK: - Pieces

    private static func place(_ image: CIImage, crop: CGRect, into rect: CGRect) -> CIImage {
        let k = rect.width / crop.width
        return image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: k, y: k), highQualityDownsample: true)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
    }

    private static func roundedRect(_ rect: CGRect, radius: Double, color: CIColor) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": max(0, radius),
            "inputColor": color,
        ])?.outputImage ?? CIImage(color: color).cropped(to: rect)
    }

    private static func roundCorners(_ image: CIImage, rect: CGRect, radius: Double) -> CIImage {
        guard radius > 0.5 else { return image }
        let mask = roundedRect(rect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }

    private static func shadow(for rect: CGRect, radius: Double, strength: Double, scale: Double) -> CIImage {
        let blur = (6 + 44 * strength) * scale
        let offset = blur * 0.35
        let opacity = 0.2 + 0.45 * strength
        let shape = roundedRect(rect.offsetBy(dx: 0, dy: -offset), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: opacity))
        return shape.applyingGaussianBlur(sigma: blur / 2)
    }

    /// Subtle blur in the direction of camera motion: a radial zoom blur while zooming in/out,
    /// and a directional blur while panning. Strength follows the camera's speed.
    private static func applyMotionBlur(to scene: CIImage, snapshot: RenderSnapshot, sourceTime: Double, view: CGRect, scale s: Double, focus: CGPoint, unit: Double) -> CIImage {
        let canvas = snapshot.canvas
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let strength = snapshot.state.style.motionBlur
        let dt = 1.0 / 60.0
        let previous = snapshot.cameraPath.state(at: sourceTime - dt)
        let previousView = snapshot.geometry.viewRect(scale: previous.scale, focus: previous.focus)
        let previousScale = canvas.width / previousView.width

        var result = scene

        let zoomSpeed = abs(log(s) - log(previousScale)) / dt
        let zoomAmount = min(zoomSpeed * 7 * strength, 14) * unit
        if zoomAmount > 0.4 {
            let focusCanvas = snapshot.geometry.focusPoint(focus)
            let center = CIVector(x: (focusCanvas.x - view.minX) * s, y: canvas.height - (focusCanvas.y - view.minY) * s)
            result = result.clampedToExtent()
                .applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: center, kCIInputAmountKey: zoomAmount])
                .cropped(to: canvasRect)
        }

        let vx = (view.midX - previousView.midX) * s / dt
        let vy = (view.midY - previousView.midY) * s / dt
        let speed = hypot(vx, vy)
        let panRadius = min(speed * dt * 0.45 * strength, 16 * unit)
        if panRadius > 0.6 {
            result = result.clampedToExtent()
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: panRadius, kCIInputAngleKey: atan2(-vy, vx)])
                .cropped(to: canvasRect)
        }
        return result
    }

    private static func cameraBubble(_ camera: CIImage, settings: CameraOverlaySettings, canvas: CGSize) -> CIImage {
        let shortSide = min(canvas.width, canvas.height)
        let diameter = settings.size * shortSide
        let margin = 0.04 * shortSide
        let extent = camera.extent
        let side = min(extent.width, extent.height)
        guard side > 0 else { return CIImage.empty() }

        var image = camera
            .cropped(to: CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(extent.midX - side / 2), y: -(extent.midY - side / 2)))
        if settings.mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: side, ty: 0))
        }
        let k = diameter / side
        image = image.transformed(by: CGAffineTransform(scaleX: k, y: k), highQualityDownsample: true)

        let origin: CGPoint
        switch settings.corner {
        case .bottomLeft: origin = CGPoint(x: margin, y: margin)
        case .bottomRight: origin = CGPoint(x: canvas.width - margin - diameter, y: margin)
        case .topLeft: origin = CGPoint(x: margin, y: canvas.height - margin - diameter)
        case .topRight: origin = CGPoint(x: canvas.width - margin - diameter, y: canvas.height - margin - diameter)
        }
        image = image.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        let box = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        let center = CIVector(x: box.midX, y: box.midY)
        let radius = diameter / 2

        let mask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": max(radius - 1.2, 0),
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage?.cropped(to: box) ?? CIImage.empty()
        let circle = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])

        let ring = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": radius - 2.5 * (shortSide / 1080),
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0.35),
        ])?.outputImage?.cropped(to: box).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]) ?? CIImage.empty()

        let shadowCenter = CIVector(x: box.midX, y: box.midY - diameter * 0.03)
        let shadow = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": shadowCenter,
            "inputRadius0": radius * 0.9,
            "inputRadius1": radius * 1.12,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.4),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage?.cropped(to: box.insetBy(dx: -diameter * 0.2, dy: -diameter * 0.2)) ?? CIImage.empty()

        return ring.composited(over: circle).composited(over: shadow)
    }
}
