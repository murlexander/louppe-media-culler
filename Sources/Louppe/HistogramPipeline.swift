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
    let width: Int
    let height: Int

    init(bins: [Int], sampleCount: Int, shadowCount: Int, highlightCount: Int,
         width: Int = 0, height: Int = 0) {
        self.bins = bins
        self.sampleCount = sampleCount
        self.shadowCount = shadowCount
        self.highlightCount = highlightCount
        self.width = width
        self.height = height
    }

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
            highlightCount: highlightCount,
            width: buffer.width, height: buffer.height
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

private struct HistogramAnalysisWaiter {
    let continuation: CheckedContinuation<HistogramAnalysis?, Never>
    /// A session's folder-access lease must outlive native reads that cannot
    /// stop mid-decode. Info navigation can retire its own interest immediately.
    let waitsForWorkerExit: Bool
}

/// Bounded, coalesced histogram work. At most two 1,024-pixel analysis
/// previews are decoded at once; the cache retains tiny value results, never
/// decoded bitmaps. Whole-image formats measure the Fit preview instead, so
/// Info does not decode a photo that Gallery is already decoding.
final class HistogramPipeline: @unchecked Sendable {
    enum RequestPurpose: Sendable {
        case info, backgroundQuality

        var qualityOfService: QualityOfService {
            self == .info ? .userInitiated : .utility
        }

        var queuePriority: Operation.QueuePriority {
            self == .info ? .high : .low
        }
    }

    typealias Decoder = @Sendable (URL) -> HistogramAnalysis?

    static let shared = HistogramPipeline()
    static let analysisPixelSize: CGFloat = 1024
    static let resultCacheLimit = 256
    /// Result-key versions, also part of the persisted cue-evidence context.
    static let analysisVersion = "histogram-v1-srgb-1024"
    static let wholeImageAnalysisVersion = "histogram-v2-fit-srgb-1024"
    static let approximateAnalysisVersion = "histogram-approx-v1-thumbnail-320"

    /// The folder-wide cue walk's estimate. `noCheapSource`: a whole-image
    /// (JPEG XL) photo whose thumbnail is not cached yet.
    enum ApproximateResult: Sendable {
        case measured(HistogramAnalysis), failed, noCheapSource
    }

    private final class PendingAnalysis {
        var waiters: [UUID: HistogramAnalysisWaiter]
        let operation: BlockOperation
        let readAccess: MediaOperationReadAccess
        let completionID: UUID
        var admissionTask: Task<Void, Never>?
        var submitted = false

        init(
            waiters: [UUID: HistogramAnalysisWaiter],
            operation: BlockOperation,
            readAccess: MediaOperationReadAccess,
            completionID: UUID
        ) {
            self.waiters = waiters
            self.operation = operation
            self.readAccess = readAccess
            self.completionID = completionID
        }
    }

    private let foregroundWork: ForegroundWorkCoordinator
    private let imagePipeline: ImagePipeline
    private let queue: OperationQueue
    private let decoder: Decoder
    private let lock = NSLock()
    private var cache: [String: HistogramAnalysis] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: PendingAnalysis] = [:]
    /// Retired requests cannot publish/cache or be confused with a renewed key.
    private var retiredWaiters: [UUID: [CheckedContinuation<HistogramAnalysis?, Never>]] = [:]
    #if LOUPPE_TEST_SEAMS
    private var sourceDecodes = 0
    private var approximateThumbnailReuses = 0
    private var approximateSourceDecodes = 0
    #endif

    /// Isolated workers/queues make resource and cancellation contracts testable;
    /// production uses the shared instance with the same two-operation ceiling.
    init(
        decoder: @escaping Decoder = { url in
            ImagePipeline.decodeImage(url: url, maxPixel: HistogramPipeline.analysisPixelSize)
                .flatMap(ClippingWarningProcessor.analyze)
        },
        operationQueue: OperationQueue? = nil,
        foregroundWork: ForegroundWorkCoordinator = .shared,
        imagePipeline: ImagePipeline = .shared
    ) {
        self.foregroundWork = foregroundWork
        self.imagePipeline = imagePipeline
        self.decoder = decoder
        let queue = operationQueue ?? OperationQueue()
        queue.name = "louppe.histogram"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        self.queue = queue
    }

    func analysis(for item: PhotoItem, purpose: RequestPurpose = .info, sourceAccess: MediaReadAccess? = nil) async -> HistogramAnalysis? {
        guard item.mediaKind == .photo, item.isSupported else { return nil }
        let key = Self.cacheKey(for: item)
        let measuresFit = ImagePipeline.decodesWholeImage(item)
        if measuresFit {
            let cached = lock.withLock { cache[key] }
            // Let a Fit that is already decoding finish; the worker then
            // finds it cached. Joining starts none, so Info in Grid decodes.
            if cached == nil { _ = await imagePipeline.fullImageIfCachedOrInFlight(for: item, sourceAccess: sourceAccess) }
        }
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
                    pending.readAccess.retainIfNeeded(sourceAccess)
                    pending.waiters[requestID] = HistogramAnalysisWaiter(
                        continuation: continuation,
                        waitsForWorkerExit: purpose == .backgroundQuality
                    )
                    if purpose == .info {
                        pending.operation.queuePriority = .high
                        pending.operation.qualityOfService = .userInitiated
                        pending.admissionTask?.cancel()
                        pending.admissionTask = nil
                    }
                    let operation = pending.operation
                    lock.unlock()
                    if purpose == .info { submit(key: key, operation: operation) }
                    return
                }

                let completionID = UUID()
                let readAccess = MediaOperationReadAccess(sourceAccess)
                let operation = BlockOperation()
                operation.completionBlock = { [weak self] in
                    readAccess.finish()
                    self?.completeOperation(completionID)
                }
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled
                    else { return }
                    defer { readAccess.finish() }
                    let result = autoreleasepool {
                        measuresFit
                            ? self.fitAnalysis(for: item, revision: revision)
                            : self.decodedAnalysis(revision) { self.decoder($0) }
                    }
                    self.finish(key: key, operation: operation, result: result)
                }
                operation.qualityOfService = purpose.qualityOfService
                operation.queuePriority = purpose.queuePriority
                let pending = PendingAnalysis(
                    waiters: [requestID: HistogramAnalysisWaiter(
                        continuation: continuation,
                        waitsForWorkerExit: purpose == .backgroundQuality
                    )],
                    operation: operation,
                    readAccess: readAccess,
                    completionID: completionID
                )
                inFlight[key] = pending
                if purpose == .backgroundQuality {
                    pending.admissionTask = Task.detached(priority: .utility) { [weak self, weak operation, foregroundWork] in
                        guard await foregroundWork.waitForBackgroundAdmission(), !Task.isCancelled,
                              let self, let operation else { return }
                        self.submit(key: key, operation: operation)
                    }
                }
                lock.unlock()
                if purpose == .info { submit(key: key, operation: operation) }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(requestID, for: key)
        }
    }

    private func submit(key: String, operation: BlockOperation) {
        let admitted = lock.withLock {
            guard let pending = inFlight[key], pending.operation === operation,
                  !pending.submitted, !operation.isCancelled else { return false }
            pending.submitted = true
            pending.admissionTask = nil
            return true
        }
        if admitted { queue.addOperation(operation) }
    }

    /// Whole-image formats moved to v2 when their input became the Fit preview.
    private static func cacheKey(for item: PhotoItem) -> String {
        ImagePipeline.cacheKey(for: item)
            + "|" + (ImagePipeline.decodesWholeImage(item) ? wholeImageAnalysisVersion : analysisVersion)
    }

    /// The cached Fit preview, else the same bounded decode on this lane,
    /// uncached. Both pass through `analysisPreview`, so Info and the
    /// background walk count identical samples whichever one ran.
    private func fitAnalysis(for item: PhotoItem, revision: MediaSourceRevision) -> HistogramAnalysis? {
        // Cached pixels were revision-checked by the decode that produced them.
        if let fit = imagePipeline.cachedFullImage(for: item)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return Self.analysisPreview(ofFit: fit).flatMap(ClippingWarningProcessor.analyze)
        }
        return decodedAnalysis(revision) { url in
            ImagePipeline.decodeFitImage(url: url, sizing: .bounded)
                .flatMap(Self.analysisPreview(ofFit:))
                .flatMap(ClippingWarningProcessor.analyze)
        }
    }

    private func decodedAnalysis(_ revision: MediaSourceRevision, _ decode: (URL) -> HistogramAnalysis?) -> HistogramAnalysis? {
        #if LOUPPE_TEST_SEAMS
        lock.withLock { sourceDecodes += 1 }
        #endif
        return revision.read { decode(revision.url) }
    }

    /// The one 4,096 → 1,024 reduction for histograms measured from a Fit
    /// preview. A preview within the analysis size is measured as it is.
    static func analysisPreview(ofFit image: CGImage) -> CGImage? {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > analysisPixelSize else { return image }
        let scale = analysisPixelSize / longEdge
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Clipping counts from the 320 px thumbnail: the memory cache, else the
    /// disk cache, else the same small decode (a RAW file's embedded preview).
    /// Never a Fit-size decode or a RAW render, and nothing is cached here:
    /// the caller keeps the counts. A whole-image photo without a cached
    /// thumbnail is not decoded. The waiter settles after the worker exits,
    /// so a session's folder lease outlives the native read.
    func approximateAnalysis(for item: PhotoItem, sourceAccess: MediaReadAccess? = nil) async -> ApproximateResult {
        guard item.mediaKind == .photo, item.isSupported, !Task.isCancelled else { return .failed }
        if let image = imagePipeline.cachedThumbnail(for: item)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            #if LOUPPE_TEST_SEAMS
            lock.withLock { approximateThumbnailReuses += 1 }
            #endif
            return ClippingWarningProcessor.analyze(image).map(ApproximateResult.measured) ?? .failed
        }
        guard await foregroundWork.waitForBackgroundAdmission(), !Task.isCancelled else { return .failed }
        let diskURL = thumbnailDiskRoot.appendingPathComponent(
            ImagePipeline.diskFileName(for: ImagePipeline.cacheKey(for: item)))
        let decodesSource = !ImagePipeline.decodesWholeImage(item)
        let revision = MediaSourceRevision(item)
        let readAccess = MediaOperationReadAccess(sourceAccess)
        let cancellation = ApproximateCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let operation = BlockOperation { [weak self] in
                    defer { readAccess.finish() }
                    guard let self, !cancellation.isCancelled else {
                        continuation.resume(returning: .failed)
                        return
                    }
                    let result: ApproximateResult = autoreleasepool {
                        // The key binds the file to this revision's identity.
                        if let thumbnail = ImagePipeline.decodeImage(url: diskURL, maxPixel: ImagePipeline.thumbPixelSize) {
                            #if LOUPPE_TEST_SEAMS
                            self.lock.withLock { self.approximateThumbnailReuses += 1 }
                            #endif
                            return ClippingWarningProcessor.analyze(thumbnail).map(ApproximateResult.measured) ?? .failed
                        }
                        guard decodesSource else { return .noCheapSource }
                        guard !cancellation.isCancelled else { return .failed }
                        #if LOUPPE_TEST_SEAMS
                        self.lock.withLock { self.approximateSourceDecodes += 1 }
                        #endif
                        return revision.read {
                            ImagePipeline.decodeImage(url: revision.url, maxPixel: ImagePipeline.thumbPixelSize)
                                .flatMap(ClippingWarningProcessor.analyze)
                        }.map(ApproximateResult.measured) ?? .failed
                    }
                    continuation.resume(returning: result)
                }
                operation.qualityOfService = RequestPurpose.backgroundQuality.qualityOfService
                operation.queuePriority = RequestPurpose.backgroundQuality.queuePriority
                queue.addOperation(operation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class ApproximateCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    /// The shared pipeline's thumbnails live under the rebuildable cache root.
    private var thumbnailDiskRoot: URL {
        #if LOUPPE_TEST_SEAMS
        imagePipeline.diskCacheRootForTesting
        #else
        ImagePipeline.sharedDiskCacheRoot
        #endif
    }

    #if LOUPPE_TEST_SEAMS
    func waiterCountForTesting(for item: PhotoItem) -> Int {
        let key = Self.cacheKey(for: item)
        return lock.withLock { inFlight[key]?.waiters.count ?? 0 }
    }

    /// Source decodes this pipeline started for its own analysis previews.
    var sourceDecodesForTesting: Int { lock.withLock { sourceDecodes } }

    /// Estimates served by a cached thumbnail, and thumbnail-size decodes of
    /// originals for those without one.
    var approximateWorkForTesting: (thumbnailReuses: Int, sourceDecodes: Int) {
        lock.withLock { (approximateThumbnailReuses, approximateSourceDecodes) }
    }
    #endif

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
        let waiters = pending.waiters.values.map(\.continuation)
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    /// Dropping the final waiter also drops the queued analysis. A running
    /// ImageIO decode is allowed to finish safely, but it cannot publish a
    /// stale result because its in-flight entry has already been removed.
    /// Cancelled background waiters settle after native worker exit so their
    /// scheduler retains folder access; Info waiters remain immediate.
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
            pending.admissionTask?.cancel()
            // Cancel before checking execution: a queued operation that starts
            // concurrently must either skip its block or own the running lane.
            pending.operation.cancel()
            if !pending.submitted { pending.readAccess.finish() }
        }
        if waiter.waitsForWorkerExit, pending.operation.isExecuting {
            retiredWaiters[pending.completionID, default: []].append(waiter.continuation)
            lock.unlock()
            return
        }
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }

    private func completeOperation(_ completionID: UUID) {
        lock.lock()
        let waiters = retiredWaiters.removeValue(forKey: completionID) ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: nil) }
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
            highlightCount: highlightCount,
            width: width, height: height
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
    enum RequestPurpose: Sendable {
        case info, backgroundQuality
    }

    typealias Decoder = @Sendable (URL) -> HistogramAnalysis?

    static let shared = RawHistogramPipeline()
    static let analysisPixelSize: CGFloat = 1024
    static let analysisDelayNanoseconds: UInt64 = 700_000_000
    static let resultCacheLimit = 128
    /// Result-key version, also part of the persisted cue-evidence context.
    static let analysisVersion = "raw-histogram-v1-appleDefault-linear-1024"

    private final class PendingAnalysis {
        var waiters: [UUID: HistogramAnalysisWaiter]
        let operation: BlockOperation
        let readAccess: MediaOperationReadAccess
        let completionID: UUID
        var admissionTask: Task<Void, Never>?
        var submitted = false

        init(
            waiters: [UUID: HistogramAnalysisWaiter],
            operation: BlockOperation,
            readAccess: MediaOperationReadAccess,
            completionID: UUID
        ) {
            self.waiters = waiters
            self.operation = operation
            self.readAccess = readAccess
            self.completionID = completionID
        }
    }

    private let foregroundWork: ForegroundWorkCoordinator
    private let queue: OperationQueue
    private let delayNanoseconds: UInt64
    private let cacheLimit: Int
    private let decoder: Decoder
    private let lock = NSLock()
    private var cache: [String: HistogramAnalysis] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: PendingAnalysis] = [:]
    /// Retired requests cannot publish/cache or be confused with a renewed key.
    private var retiredWaiters: [UUID: [CheckedContinuation<HistogramAnalysis?, Never>]] = [:]
    #if LOUPPE_TEST_SEAMS
    private var sourceDecodes = 0
    #endif

    init(
        delayNanoseconds: UInt64 = analysisDelayNanoseconds,
        resultCacheLimit: Int = resultCacheLimit,
        foregroundWork: ForegroundWorkCoordinator = .shared,
        decoder: @escaping Decoder = { url in
            RawHistogramProcessor.analyze(url: url)
        }
    ) {
        self.foregroundWork = foregroundWork
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
        let key = ImagePipeline.cacheKey(for: item) + "|" + Self.analysisVersion
        lock.lock()
        let result = cache[key]
        if result != nil { touch(key) }
        lock.unlock()
        return result
    }

    func analysis(for item: PhotoItem, purpose: RequestPurpose = .info, sourceAccess: MediaReadAccess? = nil) async -> HistogramAnalysis? {
        guard Self.supportsAnalysis(for: item), !Task.isCancelled else {
            return nil
        }
        if let cached = cachedAnalysis(for: item) { return cached }

        // Info defers expensive sensor decoding while the user navigates.
        // Bounded background quality batches already own their scheduling.
        if purpose == .info {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return nil
            }
        }
        guard !Task.isCancelled else { return nil }
        if let cached = cachedAnalysis(for: item) { return cached }

        let key = ImagePipeline.cacheKey(for: item) + "|" + Self.analysisVersion
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
                    pending.readAccess.retainIfNeeded(sourceAccess)
                    pending.waiters[requestID] = HistogramAnalysisWaiter(
                        continuation: continuation,
                        waitsForWorkerExit: purpose == .backgroundQuality
                    )
                    if purpose == .info {
                        pending.operation.queuePriority = .high
                        pending.operation.qualityOfService = .userInitiated
                        pending.admissionTask?.cancel()
                        pending.admissionTask = nil
                    }
                    let operation = pending.operation
                    lock.unlock()
                    if purpose == .info { submit(key: key, operation: operation) }
                    return
                }

                let completionID = UUID()
                let readAccess = MediaOperationReadAccess(sourceAccess)
                let operation = BlockOperation()
                operation.completionBlock = { [weak self] in
                    readAccess.finish()
                    self?.completeOperation(completionID)
                }
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled
                    else { return }
                    defer { readAccess.finish() }
                    #if LOUPPE_TEST_SEAMS
                    self.lock.withLock { self.sourceDecodes += 1 }
                    #endif
                    let result = autoreleasepool {
                        revision.read { self.decoder(revision.url) }
                    }
                    self.finish(key: key, operation: operation, result: result)
                }
                operation.qualityOfService = purpose == .info ? .userInitiated : .utility
                operation.queuePriority = purpose == .info ? .high : .low
                let pending = PendingAnalysis(
                    waiters: [requestID: HistogramAnalysisWaiter(
                        continuation: continuation,
                        waitsForWorkerExit: purpose == .backgroundQuality
                    )],
                    operation: operation,
                    readAccess: readAccess,
                    completionID: completionID
                )
                inFlight[key] = pending
                if purpose == .backgroundQuality {
                    pending.admissionTask = Task.detached(priority: .utility) { [weak self, weak operation, foregroundWork] in
                        guard await foregroundWork.waitForBackgroundAdmission(), !Task.isCancelled,
                              let self, let operation else { return }
                        self.submit(key: key, operation: operation)
                    }
                }
                lock.unlock()
                if purpose == .info { submit(key: key, operation: operation) }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(requestID, for: key)
        }
    }

    private func submit(key: String, operation: BlockOperation) {
        let admitted = lock.withLock {
            guard let pending = inFlight[key], pending.operation === operation,
                  !pending.submitted, !operation.isCancelled else { return false }
            pending.submitted = true
            pending.admissionTask = nil
            return true
        }
        if admitted { queue.addOperation(operation) }
    }

    #if LOUPPE_TEST_SEAMS
    func waiterCountForTesting(for item: PhotoItem) -> Int {
        let key = ImagePipeline.cacheKey(for: item) + "|" + Self.analysisVersion
        return lock.withLock { inFlight[key]?.waiters.count ?? 0 }
    }

    /// RAW renders this pipeline started; cached results do not count.
    var sourceDecodesForTesting: Int { lock.withLock { sourceDecodes } }
    #endif

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
        let waiters = pending.waiters.values.map(\.continuation)
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
            pending.admissionTask?.cancel()
            // Cancel before checking execution: a queued operation that starts
            // concurrently must either skip its block or own the running lane.
            pending.operation.cancel()
            if !pending.submitted { pending.readAccess.finish() }
        }
        if waiter.waitsForWorkerExit, pending.operation.isExecuting {
            retiredWaiters[pending.completionID, default: []].append(waiter.continuation)
            lock.unlock()
            return
        }
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }

    private func completeOperation(_ completionID: UUID) {
        lock.lock()
        let waiters = retiredWaiters.removeValue(forKey: completionID) ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: nil) }
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
        var waiters: [UUID: CheckedContinuation<NSImage?, Never>]
        var source: CGImage?
        let operation: BlockOperation

        init(
            waiters: [UUID: CheckedContinuation<NSImage?, Never>],
            source: CGImage,
            operation: BlockOperation
        ) {
            self.waiters = waiters
            self.source = source
            self.operation = operation
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue
    private let testingSource: (@Sendable (PhotoItem) async -> CGImage?)?
    private let testingTransform: (@Sendable (CGImage) -> CGImage?)?
    private let lock = NSLock()
    private var inFlight: [String: PendingImage] = [:]

    private init() {
        queue = OperationQueue()
        queue.name = "louppe.clipping-preview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        testingSource = nil
        testingTransform = nil
        cache.countLimit = 2
        cache.totalCostLimit = Self.cacheCostLimit
    }

    #if LOUPPE_TEST_SEAMS
    init(operationQueue: OperationQueue,
         source: @escaping @Sendable (PhotoItem) async -> CGImage?,
         transform: @escaping @Sendable (CGImage) -> CGImage?) {
        queue = operationQueue
        queue.name = "louppe.clipping-preview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        testingSource = source
        testingTransform = transform
        cache.countLimit = 2
        cache.totalCostLimit = Self.cacheCostLimit
    }

    func waiterCountForTesting(for item: PhotoItem) -> Int {
        lock.withLock { inFlight[ImagePipeline.fullCacheKey(for: item, mode: .fast)]?.waiters.count ?? 0 }
    }

    func waitForWorkForTesting() async {
        await withCheckedContinuation { continuation in
            let barrier = BlockOperation { continuation.resume() }
            for operation in queue.operations { barrier.addDependency(operation) }
            queue.addOperation(barrier)
        }
    }
    #endif

    private func sourceImage(for item: PhotoItem, mode: RawDisplayMode,
                             decoder: AppleRawDecoder, sourceAccess: MediaReadAccess?) async -> CGImage? {
        if let testingSource { return await testingSource(item) }
        let source = await ImagePipeline.shared.fullImage(for: item, mode: mode, decoder: decoder, sourceAccess: sourceAccess)
        return source?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func cachedImage(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault) -> NSImage? {
        cache.object(
            forKey: ImagePipeline.fullCacheKey(for: item, mode: mode, decoder: decoder) as NSString
        )
    }

    func image(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault, sourceAccess: MediaReadAccess? = nil) async -> NSImage? {
        guard !Task.isCancelled, item.mediaKind == .photo, item.isSupported else { return nil }
        let key = ImagePipeline.fullCacheKey(for: item, mode: mode, decoder: decoder)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let cgImage = await sourceImage(for: item, mode: mode, decoder: decoder, sourceAccess: sourceAccess),
              !Task.isCancelled else { return nil }

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
                // The pending request owns queued pixels. This block captures
                // only identity, so cancellation can release them immediately
                // even if OperationQueue retains the cancelled block.
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation,
                          let source = self.takeSource(key: key, operation: operation) else { return }
                    let processed = autoreleasepool {
                        if let transform = self.testingTransform { return transform(source) }
                        return ClippingWarningProcessor.overlay(on: source)
                    }
                    self.finish(
                        key: key, operation: operation,
                        image: processed.map { NSImage(cgImage: $0, size: .zero) },
                        cost: processed.map { $0.bytesPerRow * $0.height } ?? 0
                    )
                }
                operation.qualityOfService = .userInitiated
                inFlight[key] = PendingImage(
                    waiters: [waiterID: continuation], source: cgImage, operation: operation
                )
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
            // A running synchronous transform still owns its lane until exit.
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
        for waiter in waiters {
            waiter.resume(returning: image)
        }
    }
}
