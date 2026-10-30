import CoreGraphics
import Foundation

/// Cursor position, normalised to the captured area (0,0 top-left … 1,1 bottom-right).
/// Values outside 0…1 mean the pointer was outside the captured area.
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
}

struct ClickEvent: Codable {
    var t: Double
    var x: Double
    var y: Double

    var point: CGPoint { CGPoint(x: x, y: y) }
    var isInsideCapture: Bool { (0...1).contains(x) && (0...1).contains(y) }
}

struct CursorTrack: Codable {
    var samples: [CursorSample] = []
    var clicks: [ClickEvent] = []

    func position(at t: Double) -> CGPoint {
        guard let first = samples.first, let last = samples.last else { return CGPoint(x: 0.5, y: 0.5) }
        if t <= first.t { return CGPoint(x: first.x, y: first.y) }
        if t >= last.t { return CGPoint(x: last.x, y: last.y) }
        var lo = 0
        var hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo]
        let b = samples[hi]
        let f = (t - a.t) / max(b.t - a.t, 1e-6)
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

struct RecordingInfo: Codable {
    var version = 1
    var createdAt: Date
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var hasCamera: Bool
    var hasMicrophone: Bool
    var hasSystemAudio: Bool
    var cursor: CursorTrack

    var sourceSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
}
