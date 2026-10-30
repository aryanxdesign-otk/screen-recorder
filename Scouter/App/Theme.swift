import AppKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.40, green: 0.36, blue: 0.98)
    static let windowBackground = Color(white: 0.075)
    static let panel = Color(white: 0.115)
    static let panelRaised = Color(white: 0.16)
    static let stroke = Color.white.opacity(0.08)
    static let clip = Color(red: 0.91, green: 0.62, blue: 0.20)
    static let zoom = Color(red: 0.42, green: 0.36, blue: 0.98)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)
}

extension NSWindow.Level {
    // Above the menu bar so the selection overlay can cover it, but below pop-up menus.
    static let scouterOverlay = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    static let scouterBar = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    static let scouterBubble = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
    static let scouterCountdown = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4)
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onReset: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: title)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                if let onReset {
                    Button("Reset", action: onReset)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.0001))
            )
            .contentShape(Rectangle())
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

func formatTimecode(_ seconds: Double) -> String {
    let s = max(0, seconds)
    let minutes = Int(s) / 60
    let secs = Int(s) % 60
    let hundredths = Int((s - floor(s)) * 100)
    return String(format: "%d:%02d.%02d", minutes, secs, hundredths)
}

func formatShortDuration(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "%.0fs", max(seconds, 0).rounded()) }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
