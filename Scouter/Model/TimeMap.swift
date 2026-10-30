import Foundation

/// Maps between output time (the edited, cut-together timeline) and source time.
struct TimeMap {
    let segments: [ClipSegment]
    let outputStarts: [Double]
    let duration: Double

    init(segments: [ClipSegment]) {
        self.segments = segments
        var starts: [Double] = []
        var cursor = 0.0
        for segment in segments {
            starts.append(cursor)
            cursor += max(0, segment.duration)
        }
        outputStarts = starts
        duration = cursor
    }

    func segmentIndex(atOutput t: Double) -> Int {
        guard !segments.isEmpty else { return 0 }
        var index = 0
        for (i, start) in outputStarts.enumerated() where start <= t {
            index = i
        }
        return index
    }

    func sourceTime(atOutput t: Double) -> Double {
        guard !segments.isEmpty else { return t }
        let index = segmentIndex(atOutput: t)
        let segment = segments[index]
        return min(segment.end, segment.start + max(0, t - outputStarts[index]))
    }

    /// Output position of a source time. Source times that were cut away snap to the next kept frame.
    func outputTime(forSource s: Double) -> Double {
        for (i, segment) in segments.enumerated() {
            if s < segment.start { return outputStarts[i] }
            if s <= segment.end { return outputStarts[i] + (s - segment.start) }
        }
        return duration
    }

    func outputRange(of segmentID: UUID) -> ClosedRange<Double>? {
        guard let i = segments.firstIndex(where: { $0.id == segmentID }) else { return nil }
        return outputStarts[i]...(outputStarts[i] + segments[i].duration)
    }
}
