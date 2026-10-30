import AppKit
import SwiftUI

struct TimelineView: View {
    @ObservedObject var model: EditorModel

    private let inset: CGFloat = 20
    private let rulerHeight: CGFloat = 24
    private let clipHeight: CGFloat = 56
    private let zoomHeight: CGFloat = 42
    private let spacing: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let duration = max(model.duration, 0.1)
            let visibleWidth = max(geo.size.width - inset * 2, 100)
            let pps = visibleWidth / duration * model.timelineZoom
            let contentWidth = duration * pps

            ScrollView(.horizontal, showsIndicators: model.timelineZoom > 1.01) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: spacing) {
                        TimeRuler(duration: duration, pps: pps)
                            .frame(width: contentWidth, height: rulerHeight)
                            .contentShape(Rectangle())
                            .gesture(scrubGesture(pps: pps))
                        ClipTrack(model: model, pps: pps, height: clipHeight)
                            .frame(width: contentWidth, height: clipHeight, alignment: .topLeading)
                        ZoomTrack(model: model, pps: pps, height: zoomHeight)
                            .frame(width: contentWidth, height: zoomHeight, alignment: .topLeading)
                    }
                    Playhead(
                        x: model.currentTime * pps,
                        height: rulerHeight + clipHeight + zoomHeight + spacing * 2 + 6
                    )
                    .gesture(scrubGesture(pps: pps))
                }
                .coordinateSpace(name: "timeline")
                .padding(.horizontal, inset)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.panel)
    }

    private func scrubGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if !model.isScrubbing {
                    model.isScrubbing = true
                    if model.isPlaying { model.pause() }
                }
                model.seek(to: value.location.x / pps)
            }
            .onEnded { _ in
                model.isScrubbing = false
            }
    }
}

// MARK: - Ruler

private struct TimeRuler: View {
    let duration: Double
    let pps: Double

    var body: some View {
        Canvas { context, size in
            let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let major = steps.first { $0 * pps >= 90 } ?? 600
            var t = 0.0
            while t <= duration + 0.0001 {
                let x = t * pps
                let label = Text(Self.label(t, step: major))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.42))
                context.draw(label, at: CGPoint(x: x, y: 8), anchor: t == 0 ? .leading : .center)
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: size.height - 5, width: 3, height: 3)), with: .color(Color.white.opacity(0.35)))
                let half = t + major / 2
                if half < duration {
                    let hx = half * pps
                    context.fill(Path(ellipseIn: CGRect(x: hx - 1, y: size.height - 4.5, width: 2, height: 2)), with: .color(Color.white.opacity(0.2)))
                }
                t += major
            }
        }
    }

    static func label(_ t: Double, step: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        if step < 1 {
            return String(format: "%d:%04.1f", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }
}

// MARK: - Playhead

private struct Playhead: View {
    let x: Double
    let height: Double

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .allowsHitTesting(false)
        }
        .frame(width: 16, height: height)
        .offset(x: x - 8, y: -4)
        .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

// MARK: - Clip track

private struct ClipTrack: View {
    @ObservedObject var model: EditorModel
    let pps: Double
    let height: CGFloat
    @State private var trim: TrimDrag?

    struct TrimDrag: Equatable {
        let id: UUID
        let leading: Bool
        var delta: Double
    }

    var body: some View {
        let map = model.timeMap
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
            ForEach(Array(model.state.segments.enumerated()), id: \.element.id) { index, segment in
                let geometry = frame(for: segment, index: index, map: map)
                SegmentBlock(
                    segment: segment,
                    isSelected: model.selection == .segment(segment.id),
                    width: geometry.width,
                    height: height,
                    onTrim: { leading, dx in updateTrim(segment: segment, index: index, map: map, leading: leading, dx: dx) },
                    onTrimEnd: { commitTrim(segment) }
                )
                .frame(width: geometry.width, height: height)
                .offset(x: geometry.x)
                .onTapGesture(coordinateSpace: .local) { location in
                    model.selection = .segment(segment.id)
                    model.seek(to: map.outputStarts[index] + location.x / pps)
                }
            }
        }
    }

    private func frame(for segment: ClipSegment, index: Int, map: TimeMap) -> (x: Double, width: Double) {
        var x = map.outputStarts[index] * pps
        var width = segment.duration * pps
        if let trim, trim.id == segment.id {
            if trim.leading {
                x += trim.delta * pps
                width -= trim.delta * pps
            } else {
                width += trim.delta * pps
            }
        }
        return (x, max(width, 8))
    }

    private func updateTrim(segment: ClipSegment, index: Int, map: TimeMap, leading: Bool, dx: Double) {
        guard let bounds = model.trimBounds(for: segment.id) else { return }
        if model.isPlaying { model.pause() }
        let requested = dx / pps
        let delta: Double
        if leading {
            let newStart = (segment.start + requested).clamped(to: bounds.lowerBound...(segment.end - 0.2))
            delta = newStart - segment.start
            if delta >= 0 { model.seek(to: map.outputStarts[index] + delta) }
        } else {
            let newEnd = (segment.end + requested).clamped(to: (segment.start + 0.2)...bounds.upperBound)
            delta = newEnd - segment.end
            if delta <= 0 { model.seek(to: map.outputStarts[index] + segment.duration + delta - 0.01) }
        }
        trim = TrimDrag(id: segment.id, leading: leading, delta: delta)
        model.selection = .segment(segment.id)
    }

    private func commitTrim(_ segment: ClipSegment) {
        guard let trim, trim.id == segment.id else { return }
        if trim.leading {
            model.trimSegment(segment.id, start: segment.start + trim.delta)
        } else {
            model.trimSegment(segment.id, end: segment.end + trim.delta)
        }
        self.trim = nil
    }
}

private struct SegmentBlock: View {
    let segment: ClipSegment
    let isSelected: Bool
    let width: Double
    let height: CGFloat
    let onTrim: (Bool, Double) -> Void
    let onTrimEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Theme.clip, Theme.clip.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            if width > 70 {
                VStack(spacing: 1) {
                    Text("Clip")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.65)
                    Text(formatShortDuration(segment.duration))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(Color.black.opacity(0.72))
                .allowsHitTesting(false)
            }
            HStack(spacing: 0) {
                handle(leading: true)
                Spacer(minLength: 0)
                handle(leading: false)
            }
        }
        .onHover { hovering = $0 }
    }

    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.black.opacity(hovering || isSelected ? 0.5 : 0.18))
            .frame(width: 3, height: 22)
            .frame(width: 14, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in onTrim(leading, value.translation.width) }
                    .onEnded { _ in onTrimEnd() }
            )
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

// MARK: - Zoom track

private struct ZoomTrack: View {
    @ObservedObject var model: EditorModel
    let pps: Double
    let height: CGFloat
    @State private var dragOrigin: DragOrigin?

    struct DragOrigin {
        let id: UUID
        let start: Double
        let end: Double
    }

    var body: some View {
        let map = model.timeMap
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    if model.state.zooms.isEmpty {
                        Text("Click here to add a zoom")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    model.addZoom(atOutput: location.x / pps)
                }

            ForEach(model.state.zooms) { zoom in
                let x0 = map.outputTime(forSource: zoom.start) * pps
                let x1 = map.outputTime(forSource: zoom.end) * pps
                if x1 - x0 > 2 {
                    ZoomBlock(
                        zoom: zoom,
                        isSelected: model.selection == .zoom(zoom.id),
                        width: x1 - x0,
                        height: height,
                        onDrag: { part, dx in drag(zoom, part: part, dx: dx) },
                        onDragEnd: { dragOrigin = nil }
                    )
                    .frame(width: x1 - x0, height: height)
                    .offset(x: x0)
                    .onTapGesture {
                        model.selection = .zoom(zoom.id)
                        model.inspectorTab = .zoom
                    }
                }
            }
        }
    }

    private func drag(_ zoom: ZoomRegion, part: ZoomBlock.Part, dx: Double) {
        if dragOrigin?.id != zoom.id {
            dragOrigin = DragOrigin(id: zoom.id, start: zoom.start, end: zoom.end)
            model.selection = .zoom(zoom.id)
            model.inspectorTab = .zoom
        }
        guard let origin = dragOrigin else { return }
        let dt = dx / pps
        switch part {
        case .body:
            let others = model.state.zooms.filter { $0.id != zoom.id }
            let lower = others.filter { $0.end <= origin.start + 0.001 }.map(\.end).max() ?? 0
            let upper = others.filter { $0.start >= origin.end - 0.001 }.map(\.start).min() ?? model.info.duration
            let shift = dt.clamped(to: (lower - origin.start)...(upper - origin.end))
            model.setZoomRange(zoom.id, start: origin.start + shift, end: origin.end + shift)
        case .leading:
            model.setZoomRange(zoom.id, start: origin.start + dt, end: origin.end)
        case .trailing:
            model.setZoomRange(zoom.id, start: origin.start, end: origin.end + dt)
        }
    }
}

private struct ZoomBlock: View {
    enum Part { case body, leading, trailing }

    let zoom: ZoomRegion
    let isSelected: Bool
    let width: Double
    let height: CGFloat
    let onDrag: (Part, Double) -> Void
    let onDragEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Theme.zoom, Theme.zoom.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            if width > 64 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                    Text(String(format: "%.1f×", zoom.scale))
                    if width > 110 {
                        Image(systemName: zoom.mode == .auto ? "cursorarrow.motionlines" : "scope")
                        Text(zoom.mode.title)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
            }
            HStack(spacing: 0) {
                handle(.leading)
                Spacer(minLength: 0)
                handle(.trailing)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in onDrag(.body, value.translation.width) }
                .onEnded { _ in onDragEnd() }
        )
        .onHover { hovering = $0 }
    }

    private func handle(_ part: Part) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white.opacity(hovering || isSelected ? 0.7 : 0.25))
            .frame(width: 3, height: 16)
            .frame(width: 12, height: height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in onDrag(part, value.translation.width) }
                    .onEnded { _ in onDragEnd() }
            )
    }
}
