import AppKit

/// Samples the pointer at 120 Hz and records clicks, in media time and normalised to the captured area.
/// Polling needs no extra permissions (unlike global event taps).
@MainActor
final class MouseTracker {
    private let clock: RecordingClock
    private let captureRect: CGRect
    private var timer: Timer?
    private(set) var track = CursorTrack()

    private var lastPosition: CGPoint?
    private var lastTick = -1.0
    private var lastEmitted = -1.0
    private var wasPressed = false

    init(clock: RecordingClock, captureRect: CGRect) {
        self.clock = clock
        self.captureRect = captureRect
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        defer { wasPressed = pressed }
        guard let media = clock.mediaTime(for: RecordingClock.now()) else { return }
        let t = media.seconds

        let cocoa = NSEvent.mouseLocation
        let quartz = CGPoint(x: cocoa.x, y: NSScreen.primaryHeight - cocoa.y)
        let position = CGPoint(
            x: (quartz.x - captureRect.minX) / max(captureRect.width, 1),
            y: (quartz.y - captureRect.minY) / max(captureRect.height, 1)
        )

        if position != lastPosition {
            // Keep a sample at the end of an idle stretch so interpolation doesn't drift.
            if let last = lastPosition, lastEmitted < lastTick {
                track.samples.append(CursorSample(t: lastTick, x: last.x, y: last.y))
            }
            track.samples.append(CursorSample(t: t, x: position.x, y: position.y))
            lastEmitted = t
            lastPosition = position
        }
        lastTick = t

        if pressed && !wasPressed && !isOverOwnPanel(cocoa) {
            track.clicks.append(ClickEvent(t: t, x: position.x, y: position.y))
        }
    }

    /// Clicks on our own floating controls (pause/stop, camera bubble) shouldn't trigger zooms.
    private func isOverOwnPanel(_ point: CGPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.level.rawValue > NSWindow.Level.normal.rawValue && window.frame.contains(point)
        }
    }
}
