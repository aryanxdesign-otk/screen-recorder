import AppKit
import CoreImage
import SwiftUI

struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255,
            alpha
        )
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    var ciColor: CIColor { CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
}
