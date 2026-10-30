import Foundation

/// Turns recorded clicks into zoom regions.
enum AutoZoom {
    /// Start zooming slightly before the click so the zoom has landed when it happens.
    static let leadIn = 0.45
    /// Stay zoomed for this long after the last click of a group.
    static let holdAfter = 1.5
    /// Clicks closer together than this share one zoom.
    static let groupingGap = 3.0
    static let minimumLength = 1.4
    /// Clicks right at the end are usually the user reaching for "stop".
    static let ignoreTail = 0.6

    static func regions(clicks: [ClickEvent], duration: Double, scale: Double) -> [ZoomRegion] {
        let usable = clicks
            .filter { $0.isInsideCapture && $0.t < duration - ignoreTail }
            .sorted { $0.t < $1.t }

        var groups: [[ClickEvent]] = []
        for click in usable {
            if let last = groups.last?.last, click.t - last.t <= groupingGap {
                groups[groups.count - 1].append(click)
            } else {
                groups.append([click])
            }
        }

        var result: [ZoomRegion] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let start = max(0, first.t - leadIn)
            var end = min(duration, last.t + holdAfter)
            if end - start < minimumLength {
                end = min(duration, start + minimumLength)
            }
            if let previous = result.last, start - previous.end < 0.5 {
                result[result.count - 1].end = max(previous.end, end)
                continue
            }
            guard end - start > 0.3 else { continue }
            result.append(ZoomRegion(start: start, end: end, scale: scale, mode: .auto, focus: first.point, isAutomatic: true))
        }
        return result
    }
}
