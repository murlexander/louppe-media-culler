import AppKit
import CoreImage
import os

/// Focus peaking: marks crisp edges so the focused plane stands out without
/// zooming. Built only from Core Image's stock filters, so it runs on the GPU
/// and needs no custom kernels.
///
/// Edge strength alone would light up a soft high-contrast edge as brightly
/// as a crisp faint one. Instead, a pixel counts as in focus when its gradient
/// is steep relative to the local contrast around it, which measures edge
/// width independently of contrast: a sharp step or line passes, the same
/// edge blurred by about a pixel at display size does not. A gradient floor
/// keeps noise, grain and smooth gradients dark.
enum FocusPeakingProcessor {
    /// Luminance blur before differentiation, in pixels; suppresses noise.
    /// Kept light so 2-pixel texture (fabric, foliage, hair) still registers;
    /// the gradient floor, not this blur, keeps grain dark.
    static let noiseSigma = 0.6
    /// Local contrast window radius, in pixels; covers a soft edge's ramp.
    static let contrastRadius = 4.0
    /// Sobel magnitude on perceptual luminance an edge must reach.
    static let gradientFloor: CGFloat = 0.25
    /// High-ISO grain is largest in deep shadows once gamma-encoded, so the
    /// squared floor rises linearly as the local maximum luminance falls below
    /// `shadowLimit`, up to (1 + shadowFloorBoost)× at black. Using the local
    /// maximum keeps texture with any bright part at the normal floor.
    static let shadowLimit: CGFloat = 0.5
    static let shadowFloorBoost: CGFloat = 4
    /// Thin coherent lines (eyelashes, hair, wires) may pass a lower floor in
    /// any tone: grain rarely keeps one gradient orientation across a
    /// `coherenceSigma` window, so the structure tensor's coherence
    /// ((Jxx − Jyy)² + 4Jxy²) / (Jxx + Jyy)² must reach `coherence`.
    static let coherentLineFloor: CGFloat = 0.12
    static let coherenceSigma = 3.0
    static let coherence: CGFloat = 0.9
    /// Sobel magnitude ÷ local range for crisp edges and texture. Calibrated
    /// with the light blur above: sharp detail and 2-pixel texture pass, the
    /// same content blurred by 1.5 pixels at display size almost never does.
    static let crispness: CGFloat = 2.4

    /// Edge strength in 0...1 (gray RGB, opaque), same extent as `image`.
    static func strength(of image: CIImage) -> CIImage {
        let extent = image.extent
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        // Perceptual (sRGB-encoded) luminance, so shadows and highlights
        // weigh like they look. Crop before clamping: the matrix's opaque
        // bias would otherwise extend black beyond the edges.
        let luminance = matrix(
            image.applyingFilter("CILinearToSRGBToneCurve"),
            red: weights, green: weights, blue: weights
        )
        .cropped(to: extent)
        .clampedToExtent()
        .applyingGaussianBlur(sigma: noiseSigma)

        let horizontal = luminance.applyingFilter("CIConvolutionRGB3X3", parameters: [
            "inputWeights": CIVector(values: [-1, 0, 1, -2, 0, 2, -1, 0, 1], count: 9),
            "inputBias": 0,
        ])
        let vertical = luminance.applyingFilter("CIConvolutionRGB3X3", parameters: [
            "inputWeights": CIVector(values: [-1, -2, -1, 0, 0, 0, 1, 2, 1], count: 9),
            "inputBias": 0,
        ])
        let window = 2 * contrastRadius + 1
        let highest = luminance.applyingFilter("CIMorphologyRectangleMaximum",
                                               parameters: ["inputWidth": window, "inputHeight": window])
        let lowest = luminance.applyingFilter("CIMorphologyRectangleMinimum",
                                              parameters: ["inputWidth": window, "inputHeight": window])
        // Stock compositing adds alpha and blend modes clamp, so values are
        // packed into separate channels with an unclamped maximum and then
        // combined by one color matrix, keeping alpha at 1 throughout.
        let range = matrix(
            maximum(matrix(highest, red: Self.red), matrix(lowest, green: Self.red)),
            red: CIVector(x: 1, y: -1, z: 0, w: 0)
        )
        // red: gradient², green: range², blue: local maximum luminance.
        let gradients = maximum(matrix(squared(horizontal), red: Self.red), matrix(squared(vertical), green: Self.red))
        let packed = maximum(
            maximum(matrix(gradients, red: CIVector(x: 1, y: 1, z: 0, w: 0)), matrix(squared(range), green: Self.red)),
            matrix(highest, blue: Self.red)
        )
        // red: gradient² − crispness² · range²; green: gradient² − floor²;
        // blue: gradient² − floor² · (1 + boost · (1 − L / limit)), the shadow
        // floor, weaker than green above the limit. Each ramps to 1 over half
        // a floor². A mark is a crisp edge above both grain floors, or a crisp
        // coherent line above the lower line floor.
        let floor = gradientFloor * gradientFloor
        let scale = 2 / floor
        let edge = matrix(
            packed,
            red: CIVector(x: scale, y: -scale * crispness * crispness, z: 0, w: 0),
            green: CIVector(x: scale, y: 0, z: 0, w: 0),
            blue: CIVector(x: scale, y: 0, z: scale * floor * shadowFloorBoost / shadowLimit, w: 0),
            bias: CIVector(x: 0, y: -2, z: -2 * (1 + shadowFloorBoost), w: 1)
        )
        .applyingFilter("CIColorClamp")
        .applyingFilter("CIMinimumComponent")
        return maximum(edge, coherentLine(horizontal: horizontal, vertical: vertical, packed: packed))
            .cropped(to: extent)
    }

    /// 1 where a crisp gradient clears the line floor and its orientation is
    /// coherent over the window, else 0 (gray, opaque).
    private static func coherentLine(horizontal: CIImage, vertical: CIImage, packed: CIImage) -> CIImage {
        // gx·gy can be negative, so the tensor terms are summed rather than
        // packed with a maximum; three opaque layers give alpha 3, which the
        // blur keeps and the next color matrix divides out (hence the 3s).
        let terms = matrix(squared(horizontal), red: Self.red)
            .applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: matrix(squared(vertical), green: Self.red),
            ])
            .applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: matrix(
                    horizontal.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: vertical]),
                    blue: Self.red
                ),
            ])
            .applyingGaussianBlur(sigma: coherenceSigma)
        // red: Jxx − Jyy, green: 2Jxy, blue: Jxx + Jyy; squared per channel.
        let tensor = squared(matrix(
            terms,
            red: CIVector(x: 3, y: -3, z: 0, w: 0),
            green: CIVector(x: 0, y: 0, z: 6, w: 0),
            blue: CIVector(x: 3, y: 3, z: 0, w: 0)
        ))
        let lineFloor = coherentLineFloor * coherentLineFloor
        // The coherence test is steep; tensor values near the line floor are
        // about lineFloor², so 20 / lineFloor² saturates just past the limit.
        let steep = 20 / (lineFloor * lineFloor)
        let crispScale = 2 / (coherentLineFloor * gradientFloor)
        return matrix(
            maximum(
                matrix(tensor, red: CIVector(x: steep, y: steep, z: -steep * coherence * coherence, w: 0)),
                // green: gradient² − lineFloor²; blue: crispness, ramped over
                // lineFloor · gradientFloor so faint lines reach full opacity
                // while slightly soft ones stay below it.
                matrix(packed,
                       green: CIVector(x: 2 / lineFloor, y: 0, z: 0, w: 0),
                       blue: CIVector(x: crispScale, y: -crispScale * crispness * crispness, z: 0, w: 0),
                       bias: CIVector(x: 0, y: -2, z: 0, w: 1))
            ),
            red: Self.red, green: CIVector(x: 0, y: 1, z: 0, w: 0), blue: CIVector(x: 0, y: 0, z: 1, w: 0)
        )
        .applyingFilter("CIColorClamp")
        .applyingFilter("CIMinimumComponent")
    }

    /// Opaque peaking strokes over `background` (transparent by default).
    static func overlay(for image: CIImage, over background: CIImage = .empty()) -> CIImage {
        let extent = image.extent
        return CIImage(color: strokeColor)
            .cropped(to: extent)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: strength(of: image),
            ])
            .cropped(to: extent)
    }

    /// Renders the transparent stroke layer for a decoded display image.
    static func mask(for source: CGImage) -> CGImage? {
        let image = CIImage(cgImage: source)
        let overlay = overlay(for: image)
        let extent = image.extent
        // Render now, off the main actor; a deferred image would do this work
        // when SwiftUI first draws it.
        return context.createCGImage(overlay, from: extent, format: .RGBA8,
                                     colorSpace: outputColorSpace, deferred: false)
            ?? softwareContext.createCGImage(overlay, from: extent, format: .RGBA8,
                                             colorSpace: outputColorSpace, deferred: false)
    }

    /// #EB80FF: the accent's hue (#9853A6) at full saturation and high
    /// lightness, opaque, so thin strokes read on dark and bright photos.
    /// Like the clipping tint it is drawn into photo pixels, so it ignores
    /// the appearance; it is never green, red or blue.
    static let strokeColor = CIColor(red: 0xEB / 255, green: 0x80 / 255, blue: 0xFF / 255,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        ?? CIColor(red: 0xEB / 255, green: 0x80 / 255, blue: 0xFF / 255)

    // Created on first use, so peaking costs nothing until it is turned on.
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "louppe.focus-peaking"])
    /// Core Image's GPU service can be unavailable in restricted tests or
    /// after a transient graphics-process failure.
    private static let softwareContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let red = CIVector(x: 1, y: 0, z: 0, w: 0)
    private static let zero = CIVector(x: 0, y: 0, z: 0, w: 0)

    private static func matrix(
        _ image: CIImage,
        red: CIVector = zero, green: CIVector = zero, blue: CIVector = zero,
        bias: CIVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    ) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": red, "inputGVector": green, "inputBVector": blue,
            "inputAVector": zero, "inputBiasVector": bias,
        ])
    }

    private static func squared(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func maximum(_ first: CIImage, _ second: CIImage) -> CIImage {
        first.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: second])
    }
}

/// Cached peaking layers for Gallery's decoded Fit previews. The caller hands
/// over pixels it already shows; nothing is read from disk. One lane, two
/// cached layers, retired waiters drop queued pixels, like clipping previews.
final class FocusPeakingPipeline: @unchecked Sendable {
    static let shared = FocusPeakingPipeline()
    static let cacheCostLimit = 128 * 1024 * 1024
    private static let signposter = OSSignposter(subsystem: "com.alexandermarkin.louppe", category: "Focus Peaking")
    private static let logger = Logger(subsystem: "com.alexandermarkin.louppe", category: "Focus Peaking")

    /// Content revision and representation (`ImagePipeline.fullCacheKey`)
    /// plus the exact pixel size the layer was computed from.
    static func key(representation: String, source: CGImage) -> String {
        "\(representation)|focus-peaking-v1|\(source.width)x\(source.height)"
    }

    private final class PendingMask {
        var waiters: [UUID: CheckedContinuation<NSImage?, Never>]
        var source: CGImage?
        let operation: BlockOperation

        init(waiters: [UUID: CheckedContinuation<NSImage?, Never>], source: CGImage, operation: BlockOperation) {
            self.waiters = waiters
            self.source = source
            self.operation = operation
        }
    }

    /// Two layers and 128 MiB are targets: NSCache may evict earlier under
    /// memory pressure (the layer is then recomputed) and does not enforce
    /// the cost limit strictly.
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue
    private let transform: @Sendable (CGImage) -> CGImage?
    private let lock = NSLock()
    private var inFlight: [String: PendingMask] = [:]

    private convenience init() {
        self.init(operationQueue: OperationQueue(), transform: FocusPeakingProcessor.mask(for:))
    }

    init(operationQueue: OperationQueue, transform: @escaping @Sendable (CGImage) -> CGImage?) {
        queue = operationQueue
        queue.name = "louppe.focus-peaking"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        self.transform = transform
        cache.countLimit = 2
        cache.totalCostLimit = Self.cacheCostLimit
    }

    #if LOUPPE_TEST_SEAMS
    func waiterCountForTesting(key: String) -> Int {
        lock.withLock { inFlight[key]?.waiters.count ?? 0 }
    }

    func waitForWorkForTesting() async {
        await withCheckedContinuation { continuation in
            let barrier = BlockOperation { continuation.resume() }
            for operation in queue.operations { barrier.addDependency(operation) }
            queue.addOperation(barrier)
        }
    }
    #endif

    func cachedMask(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func mask(forKey key: String, source: CGImage) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = cache.object(forKey: key as NSString) {
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                if let pending = inFlight[key] {
                    pending.waiters[waiterID] = continuation
                    lock.unlock()
                    return
                }
                let operation = BlockOperation()
                // The pending request owns queued pixels; the block captures
                // only identity, so a retired request frees them at once.
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation,
                          let source = self.takeSource(key: key, operation: operation) else { return }
                    let state = Self.signposter.beginInterval("mask", "\(source.width)x\(source.height)")
                    let start = ContinuousClock.now
                    let mask = autoreleasepool { self.transform(source) }
                    Self.signposter.endInterval("mask", state)
                    let elapsed = ContinuousClock.now - start
                    Self.logger.debug("Peaking \(source.width)x\(source.height) in \(elapsed.milliseconds) ms")
                    self.finish(key: key, operation: operation,
                                image: mask.map { NSImage(cgImage: $0, size: .zero) },
                                cost: mask.map { $0.bytesPerRow * $0.height } ?? 0)
                }
                operation.qualityOfService = .userInitiated
                inFlight[key] = PendingMask(waiters: [waiterID: continuation], source: source, operation: operation)
                lock.unlock()
                queue.addOperation(operation)
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(waiterID, key: key)
        }
    }

    private func takeSource(key: String, operation: BlockOperation) -> CGImage? {
        lock.withLock {
            guard let pending = inFlight[key], pending.operation === operation,
                  !operation.isCancelled else { return nil }
            let source = pending.source
            pending.source = nil
            return source
        }
    }

    private func cancelWaiter(_ waiterID: UUID, key: String) {
        lock.lock()
        guard let pending = inFlight[key],
              let waiter = pending.waiters.removeValue(forKey: waiterID) else {
            lock.unlock()
            return
        }
        if pending.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            pending.source = nil
            // A running render still owns the lane until it exits.
            pending.operation.cancel()
        }
        lock.unlock()
        waiter.resume(returning: nil)
    }

    private func finish(key: String, operation: BlockOperation, image: NSImage?, cost: Int) {
        lock.lock()
        guard let pending = inFlight[key], pending.operation === operation else {
            lock.unlock()
            return
        }
        inFlight.removeValue(forKey: key)
        if let image, !operation.isCancelled {
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        let waiters = Array(pending.waiters.values)
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: image) }
    }
}

private extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}
