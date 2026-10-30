import AVFoundation
import CoreImage

/// Carries the render snapshot to the compositor. One instruction spans the whole timeline.
final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let snapshot: RenderSnapshot
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID

    init(timeRange: CMTimeRange, snapshot: RenderSnapshot, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID) {
        self.timeRange = timeRange
        self.snapshot = snapshot
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        var ids: [NSValue] = [NSNumber(value: screenTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid {
            ids.append(NSNumber(value: cameraTrackID))
        }
        requiredSourceTrackIDs = ids
        super.init()
    }
}

/// Custom AVFoundation compositor that draws every frame with `FrameRenderer`.
/// Used for both the live editor preview and export, so what you see is what you get.
final class ScouterCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "app.scouter.compositor", qos: .userInteractive)

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            autoreleasepool {
                Self.render(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private static func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CompositionInstruction else {
            request.finish(with: ScouterError.exportFailed("Unexpected composition instruction"))
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: ScouterError.exportFailed("Couldn't allocate a frame"))
            return
        }

        let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
        var camera: CIImage?
        if instruction.cameraTrackID != kCMPersistentTrackID_Invalid,
           let buffer = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
            camera = CIImage(cvPixelBuffer: buffer)
        }

        let snapshot = instruction.snapshot
        let image = FrameRenderer.render(
            snapshot: snapshot,
            outputTime: request.compositionTime.seconds,
            screen: screen,
            camera: camera
        )
        RenderContext.ci.render(image, to: output, bounds: CGRect(origin: .zero, size: snapshot.canvas), colorSpace: RenderContext.sRGB)
        request.finish(withComposedVideoFrame: output)
    }
}
