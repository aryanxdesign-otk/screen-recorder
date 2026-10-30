import CoreMedia
import Foundation

/// Shared timebase for every stream in a recording. Converts host-clock timestamps
/// (what ScreenCaptureKit, the camera and the mouse tracker all use) into media time
/// that starts at zero and skips paused stretches.
final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: CMTime?
    private var pauses: [(begin: CMTime, end: CMTime?)] = []

    static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startTime != nil
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = pauses.last { return last.end == nil }
        return false
    }

    func start(at time: CMTime = RecordingClock.now()) {
        lock.lock()
        startTime = time
        pauses.removeAll()
        lock.unlock()
    }

    func pause(at time: CMTime = RecordingClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        if let last = pauses.last, last.end == nil { return }
        pauses.append((time, nil))
    }

    func resume(at time: CMTime = RecordingClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        guard let last = pauses.last, last.end == nil else { return }
        pauses[pauses.count - 1].end = time
    }

    /// Media time for a host timestamp, or nil before the start or while paused.
    func mediaTime(for hostTime: CMTime) -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        guard let startTime, hostTime >= startTime else { return nil }
        var offset = startTime
        for pause in pauses where hostTime >= pause.begin {
            guard let end = pause.end, hostTime >= end else { return nil }
            offset = offset + (end - pause.begin)
        }
        return hostTime - offset
    }

    /// Recorded duration so far (frozen while paused).
    func elapsed(at now: CMTime = RecordingClock.now()) -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        guard let startTime else { return .zero }
        var reference = now
        var offset = startTime
        for pause in pauses {
            if let end = pause.end {
                offset = offset + (end - pause.begin)
            } else {
                reference = pause.begin
            }
        }
        let value = reference - offset
        return value > .zero ? value : .zero
    }
}
