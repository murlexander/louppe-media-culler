import Foundation
import AppKit
import CoreImage

enum HistogramAnalysisSource: Equatable, Sendable {
    case renderedPreview
    case rawDecode

    var shortLabel: String {
        switch self {
        case .renderedPreview: return L10n.text("Preview")
        case .rawDecode: return "RAW"
        }
    }

    var detailLabel: String {
        switch self {
        case .renderedPreview: return L10n.text("Rendered image estimate")
        case .rawDecode: return L10n.text("RAW decode")
        }
    }

    var shadowBinUpperBound: Int {
        switch self {
        case .renderedPreview:
            return Int(HistogramAnalysis.nearBlackUpperBound)
        case .rawDecode:
            return Int(RawHistogramProcessor.shadowLuminanceUpperBound * 255)
        }
    }

    var highlightBinLowerBound: Int {
        switch self {
        case .renderedPreview:
            return Int(HistogramAnalysis.nearWhiteLowerBound)
        case .rawDecode:
            return Int(RawHistogramProcessor.highlightLuminanceLowerBound * 255)
        }
    }
}

/// Photo-wide luminance distribution plus the two warning-zone populations
/// used by both the Info panel and clipping-warning overlay.
struct HistogramAnalysis: Equatable, Sendable {
    static let nearBlackUpperBound: UInt8 = 5
    static let nearWhiteLowerBound: UInt8 = 250
    static let highPercentageThreshold = 10.0

    let bins: [Int]
    let sampleCount: Int
    let shadowCount: Int
    let highlightCount: Int

    var shadowPercentage: Double {
        percentage(for: shadowCount)
    }

    var highlightPercentage: Double {
        percentage(for: highlightCount)
    }

    static func isHighPercentage(_ value: Double) -> Bool {
        value > highPercentageThreshold
    }

    private func percentage(for count: Int) -> Double {
        guard sampleCount > 0 else { return 0 }
        return Double(count) * 100 / Double(sampleCount)
    }
}

/// Deterministic 8-bit sRGB pixel work shared by the histogram and overlay.
///
/// The threshold is deliberately luminance-based: the Info panel draws one
/// neutral histogram rather than RGB channels, and the photograph overlay
/// must mark exactly the same pixels its percentages describe.
enum ClippingWarningProcessor {
    static func luminance(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        // Integer Rec. 709 coefficients, summing to 256.
        let redContribution = 54 * Int(red)
        let greenContribution = 183 * Int(green)
        let blueContribution = 19 * Int(blue)
        let weighted =
            redContribution + greenContribution + blueContribution + 128
        return UInt8(min(weighted >> 8, 255))
    }

    static func isWarning(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let value = luminance(red: red, green: green, blue: blue)
        return value <= HistogramAnalysis.nearBlackUpperBound
            || value >= HistogramAnalysis.nearWhiteLowerBound
    }

    static func analyze(_ image: CGImage) -> HistogramAnalysis? {
        guard let buffer = rgbaBuffer(for: image) else { return nil }
        var bins = Array(repeating: 0, count: 256)
        var sampleCount = 0
        var shadowCount = 0
        var highlightCount = 0
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let alpha = bytes[offset + 3]
                guard alpha > 0 else { continue }
                let value = luminance(
                    red: straight(bytes[offset], alpha: alpha),
                    green: straight(bytes[offset + 1], alpha: alpha),
                    blue: straight(bytes[offset + 2], alpha: alpha)
                )
                sampleCount += 1
                bins[Int(value)] += 1
                if value <= HistogramAnalysis.nearBlackUpperBound {
                    shadowCount += 1
                }
                if value >= HistogramAnalysis.nearWhiteLowerBound {
                    highlightCount += 1
                }
            }
        }

        return HistogramAnalysis(
            bins: bins,
            sampleCount: sampleCount,
            shadowCount: shadowCount,
            highlightCount: highlightCount
        )
    }

    static func overlay(on image: CGImage) -> CGImage? {
        guard var buffer = rgbaBuffer(for: image) else { return nil }
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeMutableBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let alpha = bytes[offset + 3]
                guard alpha > 0 else { continue }
                let red = straight(bytes[offset], alpha: alpha)
                let green = straight(bytes[offset + 1], alpha: alpha)
                let blue = straight(bytes[offset + 2], alpha: alpha)
                guard isWarning(red: red, green: green, blue: blue) else { continue }
                // Blend straight color, then restore valid premultiplied RGBA.
                // Transparent pixels and their alpha stay untouched.
                bytes[offset] = premultiplied(blend(red, with: 255), alpha: alpha)
                bytes[offset + 1] = premultiplied(blend(green, with: 0), alpha: alpha)
                bytes[offset + 2] = premultiplied(blend(blue, with: 0), alpha: alpha)
            }
        }

        return buffer.makeImage()
    }

    private static func straight(_ component: UInt8, alpha: UInt8) -> UInt8 {
        UInt8(min(255, (Int(component) * 255 + Int(alpha) / 2) / Int(alpha)))
    }

    private static func premultiplied(_ component: UInt8, alpha: UInt8) -> UInt8 {
        UInt8((Int(component) * Int(alpha) + 127) / 255)
    }

    private static func blend(_ original: UInt8, with warning: UInt8) -> UInt8 {
        let originalContribution = 28 * Int(original)
        let warningContribution = 72 * Int(warning)
        return UInt8(
            (originalContribution + warningContribution + 50) / 100
        )
    }

    private struct RGBABuffer {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        var bytes: [UInt8]

        func makeImage() -> CGImage? {
            bytes.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress,
                      let context = CGContext(
                        data: UnsafeMutableRawPointer(mutating: baseAddress),
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: Self.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { return nil }
                return context.makeImage()
            }
        }

        static let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func rgbaBuffer(for image: CGImage) -> RGBABuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var bytes = Array(
            repeating: UInt8(0),
            count: bytesPerRow * height
        )
        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: RGBABuffer.colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        return RGBABuffer(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }
}

/// Bounded, coalesced histogram work. At most two 1,024-pixel analysis
/// previews are decoded at once; the cache retains tiny value results, never
/// decoded bitmaps.
final class HistogramPipeline: @unchecked Sendable {
    static let shared = HistogramPipeline()
    static let analysisPixelSize: CGFloat = 1024
    static let resultCacheLimit = 256

    private final class PendingAnalysis {
        var waiters: [UUID: CheckedContinuation<HistogramAnalysis?, Never>]
        let operation: BlockOperation

        init(
            waiters: [UUID: CheckedContinuation<HistogramAnalysis?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.histogram"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var cache: [String: HistogramAnalysis] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: PendingAnalysis] = [:]

    private init() {}

    func analysis(for item: PhotoItem) async -> HistogramAnalysis? {
        guard item.mediaKind == .photo, item.isSupported else { return nil }
        let key = ImagePipeline.cacheKey(for: item)
        let revision = MediaSourceRevision(item)
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = cache[key] {
                    touch(key)
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                if let pending = inFlight[key] {
                    pending.waiters[requestID] = continuation
                    lock.unlock()
                    return
                }

                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled
                    else { return }
                    let result = autoreleasepool {
                        revision.read {
                            ImagePipeline.decodeImage(
                                url: revision.url,
                                maxPixel: Self.analysisPixelSize
                            ).flatMap(ClippingWarningProcessor.analyze)
                        }
                    }
                    self.finish(key: key, operation: operation, result: result)
                }
                operation.qualityOfService = .userInitiated
                inFlight[key] = PendingAnalysis(
                    waiters: [requestID: continuation],
                    operation: operation
                )
                lock.unlock()
                queue.addOperation(operation)
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(requestID, for: key)
        }
    }

    private func finish(key: String, operation: BlockOperation, result: HistogramAnalysis?) {
        lock.lock()
        guard let pending = inFlight[key], pending.operation === operation else {
            lock.unlock()
            return
        }
        inFlight.removeValue(forKey: key)
        if let result, !operation.isCancelled {
            cache[key] = result
            touch(key)
            while cacheOrder.count > Self.resultCacheLimit {
                let removed = cacheOrder.removeFirst()
                cache.removeValue(forKey: removed)
            }
        }
        let waiters = pending.waiters.values
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    /// Dropping the final waiter also drops the queued analysis. A running
    /// ImageIO decode is allowed to finish safely, but it cannot publish a
    /// stale result because its in-flight entry has already been removed.
    private func cancelWaiter(_ requestID: UUID, for key: String) {
        lock.lock()
        guard let pending = inFlight[key],
              let waiter = pending.waiters.removeValue(forKey: requestID)
        else {
            lock.unlock()
            return
        }
        if pending.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            pending.operation.cancel()
        }
        lock.unlock()
        waiter.resume(returning: nil)
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

/// Luminance measurement for a bounded, linear-response Core Image RAW
/// decode. The decode intentionally differs from ImagePipeline's fast
/// embedded-preview path and never produces a source-resolution bitmap.
enum RawHistogramProcessor {
    static let shadowLuminanceUpperBound: Float = 0.002
    static let highlightLuminanceLowerBound: Float = 0.995

    private static let outputColorSpace = CGColorSpace(
        name: CGColorSpace.extendedLinearSRGB
    )
    private static let context: CIContext? = {
        guard let outputColorSpace else { return nil }
        return CIContext(options: [
            .useSoftwareRenderer: true,
            .workingColorSpace: outputColorSpace,
            .workingFormat: CIFormat.RGBAh,
            .highQualityDownsample: false,
        ])
    }()

    static func analyze(
        rgba pixels: [Float],
        width: Int,
        height: Int
    ) -> HistogramAnalysis? {
        guard width > 0, height > 0,
              width <= Int.max / height,
              width * height <= Int.max / 4,
              pixels.count == width * height * 4
        else { return nil }

        var bins = Array(repeating: 0, count: 256)
        var sampleCount = 0
        var shadowCount = 0
        var highlightCount = 0

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            let alpha = pixels[offset + 3]
            guard alpha > 0,
                  red.isFinite, green.isFinite, blue.isFinite
            else { continue }

            // Core Image's default working space is linear-light. Rendering
            // to extended-linear sRGB keeps values outside 0...1 available;
            // only the chart bin is clamped, while clipping counts use the
            // actual decoded value.
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let chartValue = min(max(luminance, 0), 1)
            let bin = min(Int(chartValue * 255), 255)
            bins[bin] += 1
            sampleCount += 1
            if luminance <= shadowLuminanceUpperBound {
                shadowCount += 1
            }
            if luminance >= highlightLuminanceLowerBound {
                highlightCount += 1
            }
        }

        guard sampleCount > 0 else { return nil }
        return HistogramAnalysis(
            bins: bins,
            sampleCount: sampleCount,
            shadowCount: shadowCount,
            highlightCount: highlightCount
        )
    }

    static func analyze(url: URL) -> HistogramAnalysis? {
        guard let outputColorSpace, let context,
              let filter = RawImageRendering.filter(url: url)
        else { return nil }

        let nativeSize = filter.nativeSize
        let nativeMaximum = max(nativeSize.width, nativeSize.height)
        guard nativeMaximum.isFinite, nativeMaximum > 0 else { return nil }

        filter.isDraftModeEnabled = false
        filter.scaleFactor = Float(min(
            1,
            RawHistogramPipeline.analysisPixelSize / nativeMaximum
        ))
        // Disable the presentation-oriented tone curves. The result is still
        // a demosaiced, white-balanced Core Image RAW decode—not a proprietary
        // per-photosite camera histogram—but is substantially closer to the
        // RAW data than the embedded rendered preview.
        filter.boostAmount = 0
        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = 0
        }
        if #available(macOS 26.0, *),
           filter.isHighlightRecoverySupported {
            filter.isHighlightRecoveryEnabled = false
        }
        filter.extendedDynamicRangeAmount = 1
        filter.isGamutMappingEnabled = false

        guard var image = filter.outputImage else { return nil }
        var extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else { return nil }

        // Some decoders round their native scale. Apply one final lazy scale
        // if needed so the render allocation remains strictly bounded.
        let maximum = max(extent.width, extent.height)
        if maximum > RawHistogramPipeline.analysisPixelSize {
            let scale = RawHistogramPipeline.analysisPixelSize / maximum
            image = image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale),
                highQualityDownsample: false
            )
            extent = image.extent.integral
        }

        let width = Int(ceil(extent.width))
        let height = Int(ceil(extent.height))
        guard width > 0, height > 0,
              width <= Int(RawHistogramPipeline.analysisPixelSize) + 1,
              height <= Int(RawHistogramPipeline.analysisPixelSize) + 1,
              width <= Int.max / height,
              width * height <= Int.max / 4
        else { return nil }

        var pixels = Array(repeating: Float(0), count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                image,
                toBitmap: baseAddress,
                rowBytes: width * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(
                    x: extent.minX,
                    y: extent.minY,
                    width: CGFloat(width),
                    height: CGFloat(height)
                ),
                format: .RGBAf,
                colorSpace: outputColorSpace
            )
        }
        return analyze(rgba: pixels, width: width, height: height)
    }
}

/// Delayed, cancellable RAW-only analysis. One utility operation can run at a
/// time, duplicate requests share it, and only small content-revision-keyed
/// histogram values survive in the LRU cache.
final class RawHistogramPipeline: @unchecked Sendable {
    typealias Decoder = @Sendable (URL) -> HistogramAnalysis?

    static let shared = RawHistogramPipeline()
    static let analysisPixelSize: CGFloat = 1024
    static let analysisDelayNanoseconds: UInt64 = 700_000_000
    static let resultCacheLimit = 128

    private final class PendingAnalysis {
        var waiters: [UUID: CheckedContinuation<HistogramAnalysis?, Never>]
        let operation: BlockOperation

        init(
            waiters: [UUID: CheckedContinuation<HistogramAnalysis?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private let queue: OperationQueue
    private let delayNanoseconds: UInt64
    private let cacheLimit: Int
    private let decoder: Decoder
    private let lock = NSLock()
    private var cache: [String: HistogramAnalysis] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: PendingAnalysis] = [:]

    init(
        delayNanoseconds: UInt64 = analysisDelayNanoseconds,
        resultCacheLimit: Int = resultCacheLimit,
        decoder: @escaping Decoder = { url in
            RawHistogramProcessor.analyze(url: url)
        }
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.cacheLimit = max(resultCacheLimit, 1)
        self.decoder = decoder
        let queue = OperationQueue()
        queue.name = "louppe.histogram.raw"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.queue = queue
    }

    static func supportsAnalysis(for item: PhotoItem) -> Bool {
        item.mediaKind == .photo && item.isSupported && item.isRaw
    }

    func cachedAnalysis(for item: PhotoItem) -> HistogramAnalysis? {
        guard Self.supportsAnalysis(for: item) else { return nil }
        let key = ImagePipeline.cacheKey(for: item)
        lock.lock()
        let result = cache[key]
        if result != nil { touch(key) }
        lock.unlock()
        return result
    }

    func analysis(for item: PhotoItem) async -> HistogramAnalysis? {
        guard Self.supportsAnalysis(for: item), !Task.isCancelled else {
            return nil
        }
        if let cached = cachedAnalysis(for: item) { return cached }

        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        if let cached = cachedAnalysis(for: item) { return cached }

        let key = ImagePipeline.cacheKey(for: item)
        let revision = MediaSourceRevision(item)
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = cache[key] {
                    touch(key)
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                if let pending = inFlight[key] {
                    pending.waiters[requestID] = continuation
                    lock.unlock()
                    return
                }

                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled
                    else { return }
                    let result = autoreleasepool {
                        revision.read { self.decoder(revision.url) }
                    }
                    self.finish(key: key, operation: operation, result: result)
                }
                operation.qualityOfService = .utility
                operation.queuePriority = .low
                inFlight[key] = PendingAnalysis(
                    waiters: [requestID: continuation],
                    operation: operation
                )
                lock.unlock()
                queue.addOperation(operation)
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(requestID, for: key)
        }
    }

    private func finish(key: String, operation: BlockOperation, result: HistogramAnalysis?) {
        lock.lock()
        guard let pending = inFlight[key], pending.operation === operation else {
            lock.unlock()
            return
        }
        inFlight.removeValue(forKey: key)
        if let result, !operation.isCancelled {
            cache[key] = result
            touch(key)
            while cacheOrder.count > cacheLimit {
                let removed = cacheOrder.removeFirst()
                cache.removeValue(forKey: removed)
            }
        }
        let waiters = pending.waiters.values
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func cancelWaiter(_ requestID: UUID, for key: String) {
        lock.lock()
        guard let pending = inFlight[key],
              let waiter = pending.waiters.removeValue(forKey: requestID)
        else {
            lock.unlock()
            return
        }
        if pending.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            pending.operation.cancel()
        }
        lock.unlock()
        waiter.resume(returning: nil)
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

/// Cached clipping-warning counterparts for the existing 4,096-pixel Gallery
/// previews. Source decoding stays coalesced in ImagePipeline; only the pixel
/// transform has its own two-operation lane and 128 MiB cache.
final class ClippingPreviewPipeline: @unchecked Sendable {
    static let shared = ClippingPreviewPipeline()
    static let cacheCostLimit = 128 * 1024 * 1024

    private final class PendingImage {
        var waiters: [CheckedContinuation<NSImage?, Never>]
        let operation: BlockOperation

        init(
            waiters: [CheckedContinuation<NSImage?, Never>],
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.operation = operation
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.clipping-preview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private var inFlight: [String: PendingImage] = [:]

    private init() {
        cache.countLimit = 2
        cache.totalCostLimit = Self.cacheCostLimit
    }

    func cachedImage(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault) -> NSImage? {
        cache.object(
            forKey: ImagePipeline.fullCacheKey(for: item, mode: mode, decoder: decoder) as NSString
        )
    }

    func image(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault) async -> NSImage? {
        guard item.mediaKind == .photo, item.isSupported else { return nil }
        let key = ImagePipeline.fullCacheKey(for: item, mode: mode, decoder: decoder)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let source = await ImagePipeline.shared.fullImage(for: item, mode: mode, decoder: decoder),
              let cgImage = source.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              )
        else { return nil }

        return await withCheckedContinuation { continuation in
            lock.lock()
            if let cached = cache.object(forKey: key as NSString) {
                lock.unlock()
                continuation.resume(returning: cached)
                return
            }
            if let pending = inFlight[key] {
                pending.waiters.append(continuation)
                lock.unlock()
                return
            }
            let operation = BlockOperation { [weak self] in
                guard let self else { return }
                let processed = autoreleasepool {
                    ClippingWarningProcessor.overlay(on: cgImage).map {
                        NSImage(cgImage: $0, size: .zero)
                    }
                }
                self.finish(
                    key: key,
                    image: processed,
                    cost: processed.map {
                        Int($0.size.width * $0.size.height * 4)
                    } ?? 0
                )
            }
            operation.qualityOfService = .userInitiated
            inFlight[key] = PendingImage(
                waiters: [continuation],
                operation: operation
            )
            lock.unlock()
            queue.addOperation(operation)
        }
    }

    private func finish(key: String, image: NSImage?, cost: Int) {
        lock.lock()
        guard let pending = inFlight.removeValue(forKey: key) else {
            lock.unlock()
            return
        }
        if let image {
            cache.setObject(
                image,
                forKey: key as NSString,
                cost: cost
            )
        }
        let waiters = pending.waiters
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: image)
        }
    }
}
