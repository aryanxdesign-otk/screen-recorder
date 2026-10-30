import AppKit
import AVFoundation
import Combine

enum InspectorTab: String, CaseIterable, Identifiable {
    case background, zoom, camera, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "Background"
        case .zoom: "Zoom"
        case .camera: "Camera"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .background: "photo"
        case .zoom: "plus.magnifyingglass"
        case .camera: "person.crop.circle"
        case .audio: "speaker.wave.2"
        }
    }
}

enum TimelineSelection: Equatable {
    case segment(UUID)
    case zoom(UUID)
}

@MainActor
final class EditorModel: ObservableObject {
    let project: Project
    let player = AVPlayer()

    @Published var state: EditState {
        didSet { stateDidChange(from: oldValue) }
    }
    @Published private(set) var media: LoadedMedia?
    @Published private(set) var loadError: String?
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var selection: TimelineSelection?
    @Published var inspectorTab: InspectorTab = .background
    @Published var timelineZoom: Double = 1
    @Published var isExportPresented = false
    @Published var isCropPresented = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private(set) var cameraPath: CameraPath
    private var built: BuiltComposition?
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var lastUndoCapture = Date.distantPast
    private var isRestoring = false
    private var needsNewPlayerItem = false
    private var refreshScheduled = false
    private var saveTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var seekInFlight = false
    private var pendingSeek: Double?
    var isScrubbing = false

    init(project: Project) {
        self.project = project
        self.state = project.state
        self.cameraPath = CameraPath(zooms: project.state.zooms, cursor: project.info.cursor, crop: project.state.crop, duration: project.info.duration)
        player.actionAtItemEnd = .pause
    }

    var info: RecordingInfo { project.info }
    var sourceSize: CGSize { project.info.sourceSize }
    var timeMap: TimeMap { TimeMap(segments: state.segments) }
    var duration: Double { timeMap.duration }

    var previewCanvasSize: CGSize { state.canvasSize(shortSide: 1080, sourceSize: sourceSize) }

    var selectedZoom: ZoomRegion? {
        guard case .zoom(let id)? = selection else { return nil }
        return state.zooms.first { $0.id == id }
    }

    // MARK: - Lifecycle

    func load() {
        Task {
            do {
                let media = try await LoadedMedia.load(project: project)
                self.media = media
                rebuildPlayerItem()
                observePlayer()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        saveTask?.cancel()
        project.state = state
        project.saveState()
        player.replaceCurrentItem(with: nil)
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.seekInFlight, self.isPlaying else { return }
                self.currentTime = min(time.seconds, self.duration)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    // MARK: - State changes

    private func stateDidChange(from old: EditState) {
        guard old != state else { return }
        if !isRestoring {
            let now = Date()
            // Coalesce rapid changes (slider drags) into a single undo step.
            if now.timeIntervalSince(lastUndoCapture) > 0.6 {
                undoStack.append(old)
                if undoStack.count > 200 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            lastUndoCapture = now
        }
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty

        if old.zooms != state.zooms || old.crop != state.crop {
            cameraPath = CameraPath(zooms: state.zooms, cursor: info.cursor, crop: state.crop, duration: info.duration)
        }
        if old.segments != state.segments {
            needsNewPlayerItem = true
        }
        scheduleRefresh()
        scheduleSave()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        isRestoring = true
        state = previous
        isRestoring = false
        lastUndoCapture = .distantPast
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        validateSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        isRestoring = true
        state = next
        isRestoring = false
        lastUndoCapture = .distantPast
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        validateSelection()
    }

    private func validateSelection() {
        switch selection {
        case .segment(let id)? where !state.segments.contains(where: { $0.id == id }):
            selection = nil
        case .zoom(let id)? where !state.zooms.contains(where: { $0.id == id }):
            selection = nil
        default:
            break
        }
        if currentTime > duration { seek(to: duration) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.project.state = self.state
            self.project.saveState()
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            self?.performRefresh()
        }
    }

    private func performRefresh() {
        refreshScheduled = false
        guard media != nil else { return }
        if needsNewPlayerItem || built == nil {
            needsNewPlayerItem = false
            rebuildPlayerItem()
            return
        }
        guard let built, let item = player.currentItem else { return }
        item.videoComposition = makeVideoComposition(for: built)
        item.audioMix = CompositionBuilder.audioMix(for: built, audio: state.audio)
        if !isPlaying {
            redrawCurrentFrame()
        }
    }

    private func rebuildPlayerItem() {
        guard let media else { return }
        let wasPlaying = isPlaying
        player.pause()
        do {
            let built = try CompositionBuilder.build(media: media, segments: state.segments, includeMic: true, includeSystemAudio: true)
            self.built = built
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = makeVideoComposition(for: built)
            item.audioMix = CompositionBuilder.audioMix(for: built, audio: state.audio)
            item.seekingWaitsForVideoCompositionRendering = true
            player.replaceCurrentItem(with: item)
            let time = min(currentTime, max(duration - 0.01, 0))
            currentTime = time
            seekInFlight = false
            pendingSeek = nil
            seek(to: time)
            if wasPlaying { play() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func makeVideoComposition(for built: BuiltComposition) -> AVVideoComposition {
        let snapshot = RenderSnapshot(state: state, sourceSize: sourceSize, canvas: previewCanvasSize, cameraPath: cameraPath)
        return CompositionBuilder.videoComposition(for: built, snapshot: snapshot, fps: 60)
    }

    private func redrawCurrentFrame() {
        let time = CMTime(seconds: currentTime, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        currentTime = min(player.currentTime().seconds, duration)
    }

    func seek(to time: Double) {
        let t = time.clamped(to: 0...max(duration, 0))
        currentTime = t
        if seekInFlight {
            pendingSeek = t
            return
        }
        seekInFlight = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next)
                }
            }
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    // MARK: - Clip editing

    func splitAtPlayhead() {
        let map = timeMap
        guard !state.segments.isEmpty else { return }
        let index = map.segmentIndex(atOutput: currentTime)
        let segment = state.segments[index]
        let source = map.sourceTime(atOutput: currentTime)
        guard source - segment.start > 0.1, segment.end - source > 0.1 else { return }
        var segments = state.segments
        segments[index].end = source
        let second = ClipSegment(start: source, end: segment.end)
        segments.insert(second, at: index + 1)
        state.segments = segments
        selection = .segment(second.id)
    }

    func deleteSelection() {
        switch selection {
        case .segment(let id)?:
            guard state.segments.count > 1 else {
                NSSound.beep()
                return
            }
            state.segments.removeAll { $0.id == id }
            selection = nil
            if currentTime > duration { seek(to: duration) }
        case .zoom(let id)?:
            state.zooms.removeAll { $0.id == id }
            selection = nil
        case nil:
            break
        }
    }

    /// Source-time bounds a segment can be trimmed to without overlapping its neighbours.
    func trimBounds(for id: UUID) -> ClosedRange<Double>? {
        guard let i = state.segments.firstIndex(where: { $0.id == id }) else { return nil }
        let lower = i > 0 ? state.segments[i - 1].end : 0
        let upper = i < state.segments.count - 1 ? state.segments[i + 1].start : info.duration
        return lower...upper
    }

    func trimSegment(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = state.segments.firstIndex(where: { $0.id == id }), let bounds = trimBounds(for: id) else { return }
        var segment = state.segments[i]
        if let start { segment.start = min(max(start, bounds.lowerBound), segment.end - 0.2) }
        if let end { segment.end = max(min(end, bounds.upperBound), segment.start + 0.2) }
        state.segments[i] = segment
    }

    // MARK: - Zoom editing

    func addZoom(atOutput time: Double) {
        let source = timeMap.sourceTime(atOutput: time)
        guard !state.zooms.contains(where: { source >= $0.start && source < $0.end }) else { return }
        var end = min(source + 2.5, info.duration)
        if let next = state.zooms.filter({ $0.start > source }).map(\.start).min() {
            end = min(end, next)
        }
        guard end - source > 0.4 else {
            NSSound.beep()
            return
        }
        let focus = cursorFocus(atSource: source)
        let zoom = ZoomRegion(start: source, end: end, scale: state.style.zoomScale, mode: .auto, focus: focus)
        state.zooms.append(zoom)
        state.zooms.sort { $0.start < $1.start }
        selection = .zoom(zoom.id)
        inspectorTab = .zoom
    }

    func updateZoom(_ id: UUID, _ change: (inout ZoomRegion) -> Void) {
        guard let i = state.zooms.firstIndex(where: { $0.id == id }) else { return }
        var zoom = state.zooms[i]
        change(&zoom)
        zoom.isAutomatic = false
        state.zooms[i] = zoom
    }

    /// Moves/resizes a zoom in source time, keeping it clear of its neighbours.
    func setZoomRange(_ id: UUID, start: Double, end: Double) {
        guard let i = state.zooms.firstIndex(where: { $0.id == id }) else { return }
        let others = state.zooms.filter { $0.id != id }
        let original = state.zooms[i]
        let lower = others.filter { $0.end <= original.start + 0.001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= original.end - 0.001 }.map(\.start).min() ?? info.duration
        var newStart = max(start, lower)
        var newEnd = min(end, upper)
        if newEnd - newStart < 0.4 {
            if start != original.start { newStart = newEnd - 0.4 } else { newEnd = newStart + 0.4 }
        }
        newStart = max(newStart, lower)
        newEnd = min(newEnd, upper)
        guard newEnd - newStart >= 0.3 else { return }
        updateZoom(id) {
            $0.start = newStart
            $0.end = newEnd
        }
    }

    func regenerateAutoZooms() {
        let manual = state.zooms.filter { !$0.isAutomatic }
        let automatic = AutoZoom.regions(clicks: info.cursor.clicks, duration: info.duration, scale: state.style.zoomScale)
            .filter { auto in !manual.contains { $0.start < auto.end && auto.start < $0.end } }
        state.zooms = (manual + automatic).sorted { $0.start < $1.start }
        selection = nil
    }

    func applyDefaultScaleToAllZooms() {
        let scale = state.style.zoomScale
        state.zooms = state.zooms.map { var z = $0; z.scale = scale; return z }
    }

    func cursorFocus(atSource time: Double) -> CGPoint {
        let p = info.cursor.position(at: time)
        let crop = state.crop
        return CGPoint(
            x: ((p.x - crop.minX) / max(crop.width, 0.001)).clamped(to: 0...1),
            y: ((p.y - crop.minY) / max(crop.height, 0.001)).clamped(to: 0...1)
        )
    }

    // MARK: - Presets

    func apply(_ preset: Preset) {
        state.style = preset.style
        state.camera = preset.camera
    }

    // MARK: - Frames for pickers

    func sourceFrame(atSource time: Double, maxSize: CGSize = CGSize(width: 960, height: 960)) async -> CGImage? {
        guard let media else { return nil }
        let generator = AVAssetImageGenerator(asset: media.screen.asset)
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }
}
