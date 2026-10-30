import CoreGraphics
import Foundation

struct CameraState {
    var scale: Double
    /// Point the camera looks at, normalised to the cropped content.
    var focus: CGPoint
}

/// Precomputed, deterministic camera motion over source time.
///
/// Zoom level and focus are driven by critically damped springs, so zooming in/out and
/// following the cursor ease smoothly. Precomputing keeps rendering order-independent,
/// which matters because frames are rendered out of order while scrubbing and exporting.
final class CameraPath: @unchecked Sendable {
    static let rate = 60.0
    /// Higher = snappier zoom in/out.
    static let zoomStiffness = 6.0
    /// Higher = snappier following of the cursor.
    static let panStiffness = 4.5
    /// How far (as a fraction of half the visible area) the cursor may drift before the camera re-centres.
    static let deadZone = 0.6

    private var scales: [Double] = []
    private var focusX: [Double] = []
    private var focusY: [Double] = []

    init(zooms: [ZoomRegion], cursor: CursorTrack, crop: CGRect, duration: Double) {
        let count = max(2, Int((duration * Self.rate).rounded(.up)) + 2)
        scales.reserveCapacity(count)
        focusX.reserveCapacity(count)
        focusY.reserveCapacity(count)

        let sortedZooms = zooms.sorted { $0.start < $1.start }
        let clicks = cursor.clicks.filter(\.isInsideCapture).sorted { $0.t < $1.t }

        func toContent(_ p: CGPoint) -> (Double, Double) {
            let x = crop.width > 0 ? (p.x - crop.minX) / crop.width : 0.5
            let y = crop.height > 0 ? (p.y - crop.minY) / crop.height : 0.5
            return (x.clamped(to: 0...1), y.clamped(to: 0...1))
        }

        let dt = 1 / Self.rate
        var logScale = 0.0
        var logVelocity = 0.0
        var x = 0.5, y = 0.5
        var vx = 0.0, vy = 0.0
        var targetX = 0.5, targetY = 0.5
        var activeID: UUID?
        var clickIndex = 0
        var zoomIndex = 0

        for i in 0..<count {
            let t = Double(i) * dt

            var clickedNow: ClickEvent?
            while clickIndex < clicks.count, clicks[clickIndex].t <= t {
                clickedNow = clicks[clickIndex]
                clickIndex += 1
            }

            while zoomIndex < sortedZooms.count, sortedZooms[zoomIndex].end <= t {
                zoomIndex += 1
            }
            let active: ZoomRegion? = {
                guard zoomIndex < sortedZooms.count else { return nil }
                let z = sortedZooms[zoomIndex]
                return t >= z.start && t < z.end ? z : nil
            }()

            if let zoom = active {
                if zoom.mode == .manual {
                    targetX = zoom.focus.x.clamped(to: 0...1)
                    targetY = zoom.focus.y.clamped(to: 0...1)
                } else if activeID != zoom.id {
                    // Entering a zoom: aim at its first click, or wherever the pointer is.
                    let firstClick = clicks.first { $0.t >= zoom.start && $0.t < zoom.end }
                    (targetX, targetY) = toContent(firstClick?.point ?? cursor.position(at: t))
                } else if let click = clickedNow {
                    (targetX, targetY) = toContent(click.point)
                } else {
                    let (px, py) = toContent(cursor.position(at: t))
                    let half = 0.5 / max(exp(logScale), 1)
                    if abs(px - x) > half * Self.deadZone || abs(py - y) > half * Self.deadZone {
                        targetX = px
                        targetY = py
                    }
                }
                activeID = zoom.id
            } else {
                activeID = nil
            }

            let targetLog = log(max(active?.scale ?? 1, 1))
            Self.spring(&logScale, &logVelocity, target: targetLog, omega: Self.zoomStiffness, dt: dt)
            Self.spring(&x, &vx, target: targetX, omega: Self.panStiffness, dt: dt)
            Self.spring(&y, &vy, target: targetY, omega: Self.panStiffness, dt: dt)

            scales.append(exp(logScale))
            focusX.append(x)
            focusY.append(y)
        }
    }

    func state(at t: Double) -> CameraState {
        let position = max(0, t) * Self.rate
        let i = min(Int(position), scales.count - 2)
        let f = min(max(position - Double(i), 0), 1)
        func lerp(_ a: [Double]) -> Double { a[i] + (a[i + 1] - a[i]) * f }
        return CameraState(scale: lerp(scales), focus: CGPoint(x: lerp(focusX), y: lerp(focusY)))
    }

    /// Implicit-Euler critically damped spring; stable for any timestep.
    private static func spring(_ x: inout Double, _ v: inout Double, target: Double, omega: Double, dt: Double) {
        let f = 1 + 2 * dt * omega
        let oo = omega * omega
        let hoo = dt * oo
        let hhoo = dt * hoo
        let detInv = 1 / (f + hhoo)
        let detX = f * x + dt * v + hhoo * target
        let detV = v + hoo * (target - x)
        x = detX * detInv
        v = detV * detInv
    }
}
