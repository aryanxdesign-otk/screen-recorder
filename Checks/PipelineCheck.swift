// End-to-end check of Scouter's editing pipeline, run in CI on a macOS runner.
//
// Builds a synthetic recording (screen video, webcam video, microphone audio, cursor
// and clicks), then exercises the model logic, renders stills through FrameRenderer,
// and runs real MP4 and GIF exports through the custom compositor.
//
// Build: swiftc -parse-as-library Checks/PipelineCheck.swift Scouter/Model/*.swift Scouter/Rendering/*.swift \
//        Scouter/App/Theme.swift Scouter/Recording/RecordingClock.swift

import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct PipelineCheck {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            print("  ✓ \(message)")
        } else {
            print("  ✗ \(message)")
            failures += 1
        }
    }

    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/check", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        print("Model logic")
        checkTimeMap()
        checkAutoZoom()
        checkCameraPath()
        checkGeometry()
        checkClock()
        checkEncoderSupport()

        print("Synthetic recording")
        let project = try await makeSyntheticProject(in: output)
        let media = try await LoadedMedia.load(project: project)
        expect(media.camera != nil, "camera track loads")
        expect(media.microphone != nil, "microphone track loads")
        expect(project.state.zooms.count == 1, "clicks produce one auto zoom (got \(project.state.zooms.count))")

        print("Stills")
        try await renderStills(project: project, media: media, to: output)

        print("Exports")
        try await checkExports(project: project, media: media, to: output)

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("All checks passed")
    }

    // MARK: - Model

    static func checkTimeMap() {
        let a = ClipSegment(start: 0, end: 2)
        let b = ClipSegment(start: 3, end: 5)
        let map = TimeMap(segments: [a, b])
        expect(abs(map.duration - 4) < 1e-9, "time map duration skips the cut")
        expect(abs(map.sourceTime(atOutput: 2.5) - 3.5) < 1e-9, "output → source after a cut")
        expect(abs(map.outputTime(forSource: 2.5) - 2) < 1e-9, "cut-away source time snaps to next segment")
        expect(abs(map.outputTime(forSource: 4) - 3) < 1e-9, "source → output after a cut")
    }

    static func checkAutoZoom() {
        let clicks = [
            ClickEvent(t: 1.0, x: 0.3, y: 0.3),
            ClickEvent(t: 2.0, x: 0.35, y: 0.32),
            ClickEvent(t: 8.0, x: 0.8, y: 0.7),
            ClickEvent(t: 9.0, x: 1.4, y: 0.5),   // outside the capture: ignored
            ClickEvent(t: 9.9, x: 0.5, y: 0.5),   // right before stop: ignored
        ]
        let zooms = AutoZoom.regions(clicks: clicks, duration: 10, scale: 1.7)
        expect(zooms.count == 2, "nearby clicks share a zoom, stray clicks are ignored (got \(zooms.count))")
        if zooms.count == 2 {
            expect(abs(zooms[0].start - 0.55) < 1e-6 && abs(zooms[0].end - 3.5) < 1e-6, "zoom leads in before the first click and holds after the last")
        }
    }

    static func checkCameraPath() {
        var cursor = CursorTrack()
        cursor.samples = [CursorSample(t: 0, x: 0.8, y: 0.8), CursorSample(t: 5, x: 0.8, y: 0.8)]
        let zoom = ZoomRegion(start: 1, end: 3, scale: 2)
        let path = CameraPath(zooms: [zoom], cursor: cursor, crop: CGRect(x: 0, y: 0, width: 1, height: 1), duration: 5)
        expect(abs(path.state(at: 0.5).scale - 1) < 1e-6, "no zoom before the region")
        let mid = path.state(at: 2.5)
        expect(mid.scale > 1.9, "zoomed in during the region (\(String(format: "%.2f", mid.scale))×)")
        expect(mid.focus.x > 0.75, "auto focus follows the cursor")
        expect(path.state(at: 4.9).scale < 1.08, "zoomed back out after the region")
        let rising = path.state(at: 1.2).scale
        expect(rising > 1.05 && rising < 1.9, "zoom eases in rather than jumping (\(String(format: "%.2f", rising))×)")
    }

    static func checkGeometry() {
        let geometry = SceneGeometry(canvas: CGSize(width: 1920, height: 1080), contentAspect: 16.0 / 10.0, padding: 0.08)
        expect(geometry.contentRect.minY >= 86 - 0.5, "padding is applied")
        let full = geometry.viewRect(scale: 1, focus: CGPoint(x: 0.9, y: 0.9))
        expect(full == CGRect(x: 0, y: 0, width: 1920, height: 1080), "scale 1 shows the whole canvas")
        let zoomed = geometry.viewRect(scale: 2, focus: CGPoint(x: 1, y: 1))
        expect(zoomed.maxX <= geometry.contentRect.maxX + 0.5 && zoomed.maxY <= geometry.contentRect.maxY + 0.5, "zoomed view stays inside the recording")
        expect(AspectRatio.canvasSize(ratio: 9.0 / 16.0, shortSide: 1080) == CGSize(width: 1080, height: 1920), "vertical 1080p is 1080×1920")
    }

    static func checkClock() {
        let clock = RecordingClock()
        let t0 = CMTime(seconds: 100, preferredTimescale: 1_000_000)
        func t(_ s: Double) -> CMTime { t0 + CMTime(seconds: s, preferredTimescale: 1_000_000) }
        clock.start(at: t0)
        clock.pause(at: t(2))
        clock.resume(at: t(5))
        expect(clock.mediaTime(for: t(1))?.seconds == 1, "media time before a pause")
        expect(clock.mediaTime(for: t(3)) == nil, "samples during a pause are dropped")
        expect(abs((clock.mediaTime(for: t(6))?.seconds ?? 0) - 3) < 1e-6, "pause is removed from the timeline")
        expect(abs(clock.elapsed(at: t(7)).seconds - 4) < 1e-6, "elapsed excludes the pause")
    }

    static func checkEncoderSupport() {
        guard let writer = try? AVAssetWriter(outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("probe.mov"), fileType: .mov) else { return }
        let hevc: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 3024, AVVideoHeightKey: 1964]
        print("  · HEVC 3024×1964 encoder available on this machine: \(writer.canApply(outputSettings: hevc, forMediaType: .video))")
    }

    // MARK: - Synthetic recording

    static let screenSize = CGSize(width: 1920, height: 1200)
    static let duration = 4.0

    static func makeSyntheticProject(in output: URL) async throws -> Project {
        let folder = output.appendingPathComponent("Synthetic.scouter", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try await writeVideo(to: Project.screenURL(in: folder), size: screenSize, fps: 30, duration: duration) { context, size, time in
            drawFakeApp(context: context, size: size, time: time)
        }
        try await writeVideo(to: Project.cameraURL(in: folder), size: CGSize(width: 640, height: 480), fps: 30, duration: duration) { context, size, time in
            drawFakeCamera(context: context, size: size, time: time)
        }
        try writeTone(to: Project.micURL(in: folder), duration: duration)

        var cursor = CursorTrack()
        for i in 0...80 {
            let t = Double(i) * duration / 80
            let p = cursorPosition(at: t)
            cursor.samples.append(CursorSample(t: t, x: p.x, y: p.y))
        }
        cursor.clicks = [ClickEvent(t: 1.0, x: 0.28, y: 0.3), ClickEvent(t: 1.8, x: 0.42, y: 0.38)]

        let info = RecordingInfo(
            createdAt: Date(),
            duration: duration,
            pixelWidth: Int(screenSize.width),
            pixelHeight: Int(screenSize.height),
            hasCamera: true,
            hasMicrophone: true,
            hasSystemAudio: false,
            cursor: cursor
        )
        try Project.create(at: folder, info: info, style: StyleSettings(), camera: CameraOverlaySettings())
        let project = try Project.open(at: folder)
        expect(project.state.segments.count == 1, "project opens with one clip")
        return project
    }

    static func cursorPosition(at t: Double) -> CGPoint {
        let f = min(max(t / duration, 0), 1)
        return CGPoint(x: 0.2 + 0.5 * f, y: 0.25 + 0.3 * f)
    }

    static func writeVideo(to url: URL, size: CGSize, fps: Int32, duration: Double, draw: (CGContext, CGSize, Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw ScouterError.writerFailed("no pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ScouterError.writerFailed("no buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            // Flip so drawing code can use a top-left origin.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(context, size, Double(frame) / Double(fps))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed {
            throw ScouterError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    static func fill(_ context: CGContext, _ rect: CGRect, _ hex: UInt32, radius: CGFloat = 0) {
        let color = RGBA(hex: hex)
        context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    static func drawFakeApp(context: CGContext, size: CGSize, time: Double) {
        let w = size.width, h = size.height
        fill(context, CGRect(x: 0, y: 0, width: w, height: h), 0xF4F4F5)
        fill(context, CGRect(x: 0, y: 0, width: w, height: 56), 0xE4E4E7)
        for (i, color) in [0xEF4444, 0xF59E0B, 0x22C55E].enumerated() {
            fill(context, CGRect(x: 22 + CGFloat(i) * 26, y: 20, width: 16, height: 16), UInt32(color), radius: 8)
        }
        fill(context, CGRect(x: 0, y: 56, width: 300, height: h - 56), 0xFAFAFA)
        for row in 0..<12 {
            fill(context, CGRect(x: 28, y: 96 + CGFloat(row) * 44, width: 200 - CGFloat(row % 3) * 30, height: 14), 0xA1A1AA, radius: 7)
        }
        // Spreadsheet-like grid.
        for row in 0..<16 {
            for col in 0..<6 {
                let rect = CGRect(x: 340 + CGFloat(col) * 255, y: 110 + CGFloat(row) * 62, width: 240, height: 46)
                fill(context, rect, row == 0 ? 0xDBEAFE : 0xFFFFFF, radius: 6)
                fill(context, CGRect(x: rect.minX + 14, y: rect.midY - 6, width: 80 + CGFloat((row * 7 + col * 13) % 120), height: 12), row == 0 ? 0x1D4ED8 : 0x52525B, radius: 6)
            }
        }
        // A button that "gets clicked" at 1.0s and turns green.
        fill(context, CGRect(x: 0.28 * w - 90, y: 0.3 * h - 26, width: 180, height: 52), time >= 1.0 ? 0x16A34A : 0x4F46E5, radius: 12)
        // Cursor arrow.
        let p = cursorPosition(at: time)
        let x = p.x * w, y = p.y * h
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x, y: y + 34))
        context.addLine(to: CGPoint(x: x + 9, y: y + 26))
        context.addLine(to: CGPoint(x: x + 24, y: y + 26))
        context.closePath()
        context.fillPath()
    }

    static func drawFakeCamera(context: CGContext, size: CGSize, time: Double) {
        fill(context, CGRect(origin: .zero, size: size), 0x334155)
        fill(context, CGRect(x: size.width / 2 - 110, y: size.height / 2 - 150 + sin(time * 3) * 6, width: 220, height: 260), 0xF2C6A0, radius: 110)
        fill(context, CGRect(x: size.width / 2 - 170, y: size.height - 120, width: 340, height: 160), 0x0F172A, radius: 80)
    }

    static func writeTone(to url: URL, duration: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(duration * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000) * 0.2)
        }
        try file.write(from: buffer)
    }

    // MARK: - Stills

    static func renderStills(project: Project, media: LoadedMedia, to output: URL) async throws {
        var state = project.state
        state.style.motionBlur = 1
        let canvas = state.canvasSize(shortSide: 1080, sourceSize: project.info.sourceSize)
        let path = CameraPath(zooms: state.zooms, cursor: project.info.cursor, crop: state.crop, duration: project.info.duration)
        let snapshot = RenderSnapshot(state: state, sourceSize: project.info.sourceSize, canvas: canvas, cameraPath: path)

        let screenGenerator = AVAssetImageGenerator(asset: media.screen.asset)
        screenGenerator.requestedTimeToleranceBefore = .zero
        screenGenerator.requestedTimeToleranceAfter = .zero
        let cameraGenerator = AVAssetImageGenerator(asset: media.camera!.asset)

        var tiles: [CGImage] = []
        for time in [0.3, 0.75, 1.1, 2.0, 3.6] {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            let screen = try await screenGenerator.image(at: cmTime).image
            let camera = try await cameraGenerator.image(at: cmTime).image
            let image = FrameRenderer.render(snapshot: snapshot, outputTime: time, screen: CIImage(cgImage: screen), camera: CIImage(cgImage: camera))
            guard let cg = RenderContext.ci.createCGImage(image, from: CGRect(origin: .zero, size: canvas), format: .RGBA8, colorSpace: RenderContext.sRGB) else {
                expect(false, "render still at \(time)s")
                continue
            }
            expect(cg.width == Int(canvas.width) && cg.height == Int(canvas.height), "still at \(time)s is \(cg.width)×\(cg.height), zoom \(String(format: "%.2f", path.state(at: time).scale))×")
            try writeJPEG(cg, to: output.appendingPathComponent(String(format: "still-%.2fs.jpg", time)))
            tiles.append(cg)
        }

        // Variants: vertical canvas with a gradient, and a solid colour with large corners and no shadow.
        var vertical = state
        vertical.style.aspect = .vertical
        vertical.style.background = .gradient(from: RGBA(hex: 0x6366F1), to: RGBA(hex: 0xEC4899), angle: 45)
        vertical.camera.corner = .bottomRight
        try await renderVariant(vertical, name: "variant-vertical.jpg", project: project, media: media, output: output, time: 0.3)
        var solid = state
        solid.style.background = .color(RGBA(hex: 0x111827))
        solid.style.cornerRadius = 1
        solid.style.shadow = 0
        solid.style.padding = 0.15
        solid.camera.visible = false
        try await renderVariant(solid, name: "variant-solid.jpg", project: project, media: media, output: output, time: 0.3)

        // Contact sheet of the zoom sequence for quick review.
        let tileSize = CGSize(width: 640, height: 360)
        let sheet = CGContext(data: nil, width: Int(tileSize.width), height: Int(tileSize.height) * tiles.count, bitsPerComponent: 8, bytesPerRow: 0, space: RenderContext.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, tile) in tiles.enumerated() {
            sheet.draw(tile, in: CGRect(x: 0, y: CGFloat(tiles.count - 1 - i) * tileSize.height, width: tileSize.width, height: tileSize.height))
        }
        if let image = sheet.makeImage() {
            try writeJPEG(image, to: output.appendingPathComponent("contact-sheet.jpg"), quality: 0.6)
        }
    }

    static func renderVariant(_ state: EditState, name: String, project: Project, media: LoadedMedia, output: URL, time: Double) async throws {
        let canvas = state.canvasSize(shortSide: 1080, sourceSize: project.info.sourceSize)
        let path = CameraPath(zooms: state.zooms, cursor: project.info.cursor, crop: state.crop, duration: project.info.duration)
        let snapshot = RenderSnapshot(state: state, sourceSize: project.info.sourceSize, canvas: canvas, cameraPath: path)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        let screen = try await AVAssetImageGenerator(asset: media.screen.asset).image(at: cmTime).image
        let camera = try await AVAssetImageGenerator(asset: media.camera!.asset).image(at: cmTime).image
        let image = FrameRenderer.render(snapshot: snapshot, outputTime: time, screen: CIImage(cgImage: screen), camera: CIImage(cgImage: camera))
        if let cg = RenderContext.ci.createCGImage(image, from: CGRect(origin: .zero, size: canvas), format: .RGBA8, colorSpace: RenderContext.sRGB) {
            expect(cg.width == Int(canvas.width), "\(name) renders at \(cg.width)×\(cg.height)")
            try writeJPEG(cg, to: output.appendingPathComponent(name))
        }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Export

    static func checkExports(project: Project, media: LoadedMedia, to output: URL) async throws {
        let exporter = Exporter()

        let mp4 = output.appendingPathComponent("export-1080p.mp4")
        try await exporter.export(media: media, info: project.info, state: project.state, options: ExportOptions(format: .mp4, resolution: .p1080, fps: 60), to: mp4) { _ in }
        try await describeMovie(mp4, expectedSize: CGSize(width: 1920, height: 1080), expectedDuration: duration, expectAudio: true)

        var cut = project.state
        cut.segments = [ClipSegment(start: 0, end: 1.5), ClipSegment(start: 2.5, end: 4)]
        cut.audio.micEnabled = false
        let cutURL = output.appendingPathComponent("export-720p-cut-muted.mp4")
        try await Exporter().export(media: media, info: project.info, state: cut, options: ExportOptions(format: .mp4, resolution: .p720, fps: 30), to: cutURL) { _ in }
        try await describeMovie(cutURL, expectedSize: CGSize(width: 1280, height: 720), expectedDuration: 3, expectAudio: false)

        let gif = output.appendingPathComponent("export-720p.gif")
        try await Exporter().export(media: media, info: project.info, state: project.state, options: ExportOptions(format: .gif, resolution: .p720, fps: 15), to: gif) { _ in }
        if let source = CGImageSourceCreateWithURL(gif as CFURL, nil) {
            let count = CGImageSourceGetCount(source)
            expect(abs(count - Int(duration * 15)) <= 2, "GIF has \(count) frames at 15 fps")
            let size = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
            print("  · GIF size: \(size / 1024) KB")
        } else {
            expect(false, "GIF was written")
        }
    }

    static func describeMovie(_ url: URL, expectedSize: CGSize, expectedDuration: Double, expectAudio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video?.load(.naturalSize) ?? .zero
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        expect(size == expectedSize, "\(url.lastPathComponent) is \(Int(size.width))×\(Int(size.height))")
        expect(abs(duration - expectedDuration) < 0.15, "\(url.lastPathComponent) lasts \(String(format: "%.2f", duration))s")
        expect(audio.isEmpty != expectAudio, "\(url.lastPathComponent) \(expectAudio ? "has" : "has no") audio track")
        print("  · \(url.lastPathComponent): \(fileSize / 1024) KB")
    }
}
