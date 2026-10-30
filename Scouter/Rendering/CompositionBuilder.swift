import AVFoundation

/// The raw media of a project, loaded once per editor.
final class LoadedMedia: @unchecked Sendable {
    struct Track {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
    }

    let screen: Track
    let camera: Track?
    let microphone: Track?
    let systemAudio: Track?

    private init(screen: Track, camera: Track?, microphone: Track?, systemAudio: Track?) {
        self.screen = screen
        self.camera = camera
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    static func load(project: Project) async throws -> LoadedMedia {
        guard let screen = await loadTrack(url: project.screenURL, type: .video) else {
            throw ScouterError.missingMedia
        }
        let camera = project.info.hasCamera ? await loadTrack(url: project.cameraURL, type: .video) : nil
        let microphone = project.info.hasMicrophone ? await loadTrack(url: project.micURL, type: .audio) : nil
        let systemAudio = project.info.hasSystemAudio ? await loadTrack(url: project.systemAudioURL, type: .audio) : nil
        return LoadedMedia(screen: screen, camera: camera, microphone: microphone, systemAudio: systemAudio)
    }

    private static func loadTrack(url: URL, type: AVMediaType) async -> Track? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: type).first,
              let range = try? await track.load(.timeRange) else { return nil }
        return Track(asset: asset, track: track, range: range)
    }
}

struct BuiltComposition {
    let composition: AVMutableComposition
    let duration: CMTime
    let screenTrack: AVMutableCompositionTrack
    let cameraTrack: AVMutableCompositionTrack?
    let micTrack: AVMutableCompositionTrack?
    let systemTrack: AVMutableCompositionTrack?

    var videoTracks: [AVAssetTrack] { [screenTrack, cameraTrack].compactMap { $0 } }
}

enum CompositionBuilder {
    /// Stitches the kept segments of every source track into one composition.
    static func build(media: LoadedMedia, segments: [ClipSegment], includeMic: Bool, includeSystemAudio: Bool) throws -> BuiltComposition {
        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ScouterError.missingMedia
        }
        var cameraTrack = media.camera.flatMap { _ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var micTrack = (includeMic ? media.microphone : nil).flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var systemTrack = (includeSystemAudio ? media.systemAudio : nil).flatMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }

        func insert(_ source: LoadedMedia.Track?, into target: AVMutableCompositionTrack?, range: CMTimeRange, at time: CMTime) {
            guard let source, let target else { return }
            let clipped = range.intersection(source.range)
            guard clipped.duration > .zero else { return }
            try? target.insertTimeRange(clipped, of: source.track, at: time + (clipped.start - range.start))
        }

        var cursor = CMTime.zero
        for segment in segments {
            let requested = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                end: CMTime(seconds: segment.end, preferredTimescale: 600)
            )
            let range = requested.intersection(media.screen.range)
            guard range.duration > .zero else { continue }
            try screenTrack.insertTimeRange(range, of: media.screen.track, at: cursor)
            insert(media.camera, into: cameraTrack, range: range, at: cursor)
            insert(media.microphone, into: micTrack, range: range, at: cursor)
            insert(media.systemAudio, into: systemTrack, range: range, at: cursor)
            cursor = cursor + range.duration
        }

        func dropIfEmpty(_ track: inout AVMutableCompositionTrack?) {
            if let t = track, t.segments.isEmpty {
                composition.removeTrack(t)
                track = nil
            }
        }
        dropIfEmpty(&cameraTrack)
        dropIfEmpty(&micTrack)
        dropIfEmpty(&systemTrack)

        return BuiltComposition(composition: composition, duration: cursor, screenTrack: screenTrack, cameraTrack: cameraTrack, micTrack: micTrack, systemTrack: systemTrack)
    }

    static func videoComposition(for built: BuiltComposition, snapshot: RenderSnapshot, fps: Int32) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ScouterCompositor.self
        videoComposition.renderSize = snapshot.canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
        let instruction = CompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: built.duration),
            snapshot: snapshot,
            screenTrackID: built.screenTrack.trackID,
            cameraTrackID: built.cameraTrack?.trackID ?? kCMPersistentTrackID_Invalid
        )
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    static func audioMix(for built: BuiltComposition, audio: AudioSettings) -> AVMutableAudioMix {
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let track = built.micTrack {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(Float(audio.micEnabled ? audio.micVolume : 0), at: .zero)
            parameters.append(p)
        }
        if let track = built.systemTrack {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(Float(audio.systemEnabled ? audio.systemVolume : 0), at: .zero)
            parameters.append(p)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }
}
