import AppKit
import ScreenCaptureKit

/// Full-screen overlays used to pick what to record: hover a display or window and click,
/// or drag out an area.
@MainActor
final class SelectionOverlayController {
    struct WindowCandidate {
        let id: CGWindowID
        /// Global Quartz coordinates (top-left origin).
        let frame: CGRect
        let title: String
    }

    let mode: CaptureMode
    var onSelect: ((CaptureTarget) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [OverlayWindow] = []
    fileprivate var hoveredDisplay: CGDirectDisplayID?
    fileprivate var hoveredWindow: WindowCandidate?
    private var candidates: [WindowCandidate] = []

    init(mode: CaptureMode) {
        self.mode = mode
    }

    func show() async {
        if mode == .window {
            candidates = await Self.loadWindows()
        }
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, controller: self)
            window.orderFrontRegardless()
            windows.append(window)
        }
        let mouseScreen = NSScreen.withMouse
        (windows.first { $0.overlayScreen == mouseScreen } ?? windows.first)?.makeKey()
        NSApp.activate()
        updateHover(at: NSEvent.mouseLocation)
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    fileprivate func updateHover(at cocoaPoint: CGPoint) {
        switch mode {
        case .display:
            hoveredDisplay = NSScreen.screens.first { NSMouseInRect(cocoaPoint, $0.frame, false) }?.displayID
        case .window:
            let quartz = CGPoint(x: cocoaPoint.x, y: NSScreen.primaryHeight - cocoaPoint.y)
            hoveredWindow = candidates.first { $0.frame.contains(quartz) }
        case .area:
            break
        }
        for window in windows {
            window.contentView?.needsDisplay = true
        }
    }

    fileprivate func clearAreaSelections(except view: OverlayView) {
        for window in windows {
            if let other = window.contentView as? OverlayView, other !== view {
                other.clearSelection()
            }
        }
    }

    fileprivate func select(_ target: CaptureTarget) {
        onSelect?(target)
    }

    fileprivate func cancel() {
        onCancel?()
    }

    private static func loadWindows() async -> [WindowCandidate] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // ScreenCaptureKit doesn't promise z-order; CGWindowList is front-to-back.
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, entry) in info.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? NSNumber, order[number.uint32Value] == nil {
                order[number.uint32Value] = index
            }
        }

        return content.windows
            .filter { window in
                guard let app = window.owningApplication, app.processID != ownPID else { return false }
                return window.windowLayer == 0 && window.isOnScreen && window.frame.width > 80 && window.frame.height > 60
            }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
            .map { window in
                let appName = window.owningApplication?.applicationName ?? ""
                let title = window.title.map { $0.isEmpty ? appName : "\(appName) — \($0)" } ?? appName
                return WindowCandidate(id: window.windowID, frame: window.frame, title: title)
            }
    }
}

private final class OverlayWindow: NSWindow {
    let overlayScreen: NSScreen

    init(screen: NSScreen, controller: SelectionOverlayController) {
        overlayScreen = screen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .scouterOverlay
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = OverlayView(screen: screen, controller: controller)
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    private weak var controller: SelectionOverlayController?
    private let screen: NSScreen
    private let displayID: CGDirectDisplayID
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var isDragging = false

    init(screen: NSScreen, controller: SelectionOverlayController) {
        self.screen = screen
        self.controller = controller
        self.displayID = screen.displayID ?? CGMainDisplayID()
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var mode: CaptureMode { controller?.mode ?? .display }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        if mode == .area { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
    }

    func clearSelection() {
        selection = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .display:
            controller?.select(.display(displayID))
        case .window:
            controller?.updateHover(at: NSEvent.mouseLocation)
            if let window = controller?.hoveredWindow {
                controller?.select(.window(window.id))
            }
        case .area:
            if let selection, startButtonRect(for: selection).contains(point) {
                startArea()
                return
            }
            controller?.clearAreaSelections(except: self)
            dragStart = point
            selection = nil
            isDragging = true
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clampedX = min(max(point.x, 0), bounds.width)
        let clampedY = min(max(point.y, 0), bounds.height)
        selection = CGRect(x: min(start.x, clampedX), y: min(start.y, clampedY), width: abs(clampedX - start.x), height: abs(clampedY - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        isDragging = false
        dragStart = nil
        if let selection, selection.width < 40 || selection.height < 40 {
            self.selection = nil
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            controller?.cancel()
        case 36, 76: // Return, Enter
            if mode == .area, selection != nil { startArea() }
        default:
            super.keyDown(with: event)
        }
    }

    private func startArea() {
        guard let selection else { return }
        // View coordinates (bottom-left) -> display points (top-left).
        let rect = CGRect(x: selection.minX, y: bounds.height - selection.maxY, width: selection.width, height: selection.height).integral
        controller?.select(.area(displayID, rect))
    }

    private func startButtonRect(for selection: CGRect) -> CGRect {
        let size = CGSize(width: 168, height: 38)
        var y = selection.minY - size.height - 14
        if y < 20 { y = selection.minY + 14 }
        return CGRect(x: selection.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let dim = NSColor.black.withAlphaComponent(0.38)
        let accent = NSColor(red: 0.42, green: 0.38, blue: 1.0, alpha: 1)

        switch controller.mode {
        case .display:
            if controller.hoveredDisplay == displayID {
                accent.withAlphaComponent(0.16).setFill()
                bounds.fill()
                accent.setStroke()
                let border = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
                border.lineWidth = 6
                border.stroke()
                drawPill(text: "Click to record this display", detail: screen.localizedName, center: CGPoint(x: bounds.midX, y: bounds.midY), accent: accent)
            } else {
                dim.setFill()
                bounds.fill()
            }

        case .window:
            dim.setFill()
            bounds.fill()
            if let window = controller.hoveredWindow {
                let cocoa = NSScreen.cocoaRect(fromQuartz: window.frame)
                let local = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                guard local.intersects(bounds) else { return }
                NSColor.clear.setFill()
                local.fill(using: .copy)
                accent.withAlphaComponent(0.14).setFill()
                local.fill()
                accent.setStroke()
                let border = NSBezierPath(roundedRect: local.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
                border.lineWidth = 4
                border.stroke()
                let visible = local.intersection(bounds)
                drawPill(text: "Click to record window", detail: window.title, center: CGPoint(x: visible.midX, y: visible.midY), accent: accent)
            }

        case .area:
            dim.setFill()
            bounds.fill()
            if let selection {
                NSColor.clear.setFill()
                selection.fill(using: .copy)
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
                border.lineWidth = 2
                border.stroke()
                let scale = screen.backingScaleFactor
                let sizeText = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
                drawLabel(sizeText, at: CGPoint(x: selection.minX + 8, y: selection.maxY + 8))
                if !isDragging {
                    drawStartButton(in: startButtonRect(for: selection), accent: accent)
                }
            } else if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) {
                drawPill(text: "Drag to select an area", detail: "Esc to cancel", center: CGPoint(x: bounds.midX, y: bounds.midY), accent: accent)
            }
        }
    }

    private func drawPill(text: String, detail: String?, center: CGPoint, accent: NSColor) {
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let sub = detail.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ])
        }
        let titleSize = title.size()
        let subSize = sub?.size() ?? .zero
        let width = min(max(titleSize.width, subSize.width) + 44, 520)
        let height = titleSize.height + (sub == nil ? 0 : subSize.height + 4) + 24
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
        title.draw(at: CGPoint(x: rect.midX - titleSize.width / 2, y: rect.maxY - 12 - titleSize.height))
        if let sub {
            let clippedWidth = min(subSize.width, width - 24)
            sub.draw(in: CGRect(x: rect.midX - clippedWidth / 2, y: rect.minY + 12, width: clippedWidth, height: subSize.height))
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = string.size()
        var origin = point
        if origin.y + size.height + 8 > bounds.maxY { origin.y = point.y - size.height - 30 }
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 14, height: size.height + 8)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: rect.minX + 7, y: rect.minY + 4))
    }

    private func drawStartButton(in rect: CGRect, accent: NSColor) {
        accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let dot = CGRect(x: rect.minX + 16, y: rect.midY - 5, width: 10, height: 10)
        NSColor(red: 1, green: 0.4, blue: 0.4, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let text = NSAttributedString(string: "Start recording", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: dot.maxX + 10, y: rect.midY - size.height / 2))
    }
}
