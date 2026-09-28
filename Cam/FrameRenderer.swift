import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation

enum FrameRenderer {
    private final class Masks {
        let outer: CIImage
        let inner: CIImage
        init(outer: CIImage, inner: CIImage) { self.outer = outer; self.inner = inner }
    }
    private static let masks: NSCache<NSString, Masks> = {
        let cache = NSCache<NSString, Masks>(); cache.countLimit = 8; return cache
    }()

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let extent = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: rect.minX + (rect.width - scaled.extent.width) / 2,
            y: rect.minY + (rect.height - scaled.extent.height) / 2)).cropped(to: rect)
    }

    static func compose(rear: CIImage, front: CIImage, layout: CameraLayout, size: CGSize,
                        mode: AlbumSaveMode = .dual) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let main = aspectFill(layout.frontIsPrimary ? front : rear, into: bounds)
        guard mode == .dual, layout.isDual else { return main }
        let uiRect = layout.pipRect(in: size)
        let pip = CGRect(x: uiRect.minX, y: size.height - uiRect.maxY, width: uiRect.width, height: uiRect.height)
        let radius = size.width * 0.028
        let border = size.width * 0.004

        let key = "\(pip)-\(radius)-\(border)-\(bounds)" as NSString
        let pair: Masks
        if let cached = masks.object(forKey: key) { pair = cached }
        else {
            let outer = CIFilter.roundedRectangleGenerator()
            outer.extent = pip; outer.radius = Float(radius); outer.color = .white
            let inner = CIFilter.roundedRectangleGenerator()
            inner.extent = pip.insetBy(dx: border, dy: border)
            inner.radius = Float(max(0, radius - border)); inner.color = .white
            pair = Masks(outer: outer.outputImage!, inner: inner.outputImage!.cropped(to: bounds))
            masks.setObject(pair, forKey: key)
        }
        let background = pair.outer.composited(over: main)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = aspectFill(layout.frontIsPrimary ? rear : front, into: pip)
        blend.backgroundImage = background
        blend.maskImage = pair.inner
        return blend.outputImage!.cropped(to: bounds)
    }
}

final class PairCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = false
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let rearTrackID: CMPersistentTrackID
    let frontTrackID: CMPersistentTrackID
    let rearTransform: CGAffineTransform
    let frontTransform: CGAffineTransform
    let memory: MemoryItem
    let mode: AlbumSaveMode
    private let layoutLock = NSLock()
    private var previewOverride: CameraLayout?

    func setPreviewLayout(_ layout: CameraLayout?) {
        layoutLock.lock()
        previewOverride = layout
        layoutLock.unlock()
    }

    func layout(at time: Double) -> CameraLayout {
        layoutLock.lock()
        let override = previewOverride
        layoutLock.unlock()
        return override ?? memory.layout(at: time)
    }

    init(timeRange: CMTimeRange, rearID: CMPersistentTrackID, frontID: CMPersistentTrackID,
         rearTransform: CGAffineTransform, frontTransform: CGAffineTransform, memory: MemoryItem,
         mode: AlbumSaveMode = .dual) {
        self.timeRange = timeRange
        rearTrackID = rearID
        frontTrackID = frontID
        self.rearTransform = rearTransform
        self.frontTransform = frontTransform
        self.memory = memory
        self.mode = mode
        requiredSourceTrackIDs = Array(Set([rearID, frontID])).map { NSNumber(value: $0) }
        super.init()
    }
}

final class PairVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]
    }
    private let queue = DispatchQueue(label: "cam.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var renderContext: AVVideoCompositionRenderContext?
    private let cancellationLock = NSLock()
    private var generation = 0
    private var currentGeneration: Int {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; return generation
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let token = currentGeneration
        queue.async { [self] in
            guard token == currentGeneration else { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? PairCompositionInstruction,
                  let rear = request.sourceFrame(byTrackID: instruction.rearTrackID),
                  let front = request.sourceFrame(byTrackID: instruction.frontTrackID),
                  let renderContext,
                  let buffer = renderContext.newPixelBuffer() else {
                request.finish(with: CamError.message("视频的一路画面无法读取，合成已停止。"))
                return
            }
            let image = FrameRenderer.compose(
                rear: CIImage(cvPixelBuffer: rear).transformed(by: instruction.rearTransform),
                front: CIImage(cvPixelBuffer: front).transformed(by: instruction.frontTransform),
                layout: instruction.layout(at: request.compositionTime.seconds),
                size: renderContext.size, mode: instruction.mode)
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: renderContext.size),
                           colorSpace: FrameRenderer.colorSpace)
            if token == currentGeneration { request.finish(withComposedVideoFrame: buffer) }
            else { request.finishCancelledRequest() }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock(); generation += 1; cancellationLock.unlock()
    }
}
