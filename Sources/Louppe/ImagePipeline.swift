import Foundation
import AppKit
import ImageIO
import AVFoundation

/// One operation owns this lease from registration through synchronous worker
/// exit. A coalescing join may supply missing authority, but never clears it.
/// Neither cache identity nor a normalized source URL can create authority.
final class MediaOperationReadAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var token: MediaReadAccess.Token?
    private var authority: MediaReadAccess?
    private var finished = false

    init(_ authority: MediaReadAccess?) { retainIfNeeded(authority) }

    func retainIfNeeded(_ authority: MediaReadAccess?) {
        lock.withLock {
            guard !finished, token == nil, let authority else { return }
            self.authority = authority
            token = authority.begin()
        }
    }

    var sourceAccess: MediaReadAccess? { lock.withLock { authority } }

    func finish() {
        let released = lock.withLock {
            finished = true
            let released = token
            token = nil
            return released
        }
        withExtendedLifetime(released) {}
    }
}

/// Decodes images with ImageIO (extracting embedded previews for RAW files),
/// caches thumbnails in memory + on disk, and prefetches around the current photo.
// @unchecked Sendable: safe to share across threads — NSCache and the queues
// are thread-safe; the only mutable dictionary is protected by `inFlightLock`.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let foregroundWork: ForegroundWorkCoordinator
    private let thumbCache = NSCache<NSString, NSImage>()
    private let fullCache = NSCache<NSString, NSImage>()
    private let fullDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.full"
        // Two large decodes keep navigation responsive without allowing fast
        // key-repeat to saturate every CPU core and multiply peak memory.
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let thumbnailDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.thumbnail"
        // Thumbnails are small (320 px, ~0.4 MB decoded), so a wider lane
        // fills a fresh Grid noticeably faster without the peak-memory risk
        // that keeps the full-size queue at two. A separate queue also means
        // the current photo's full decode never waits behind tile backlog.
        queue.maxConcurrentOperationCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let diskQueue = DispatchQueue(label: "louppe.thumbnail-disk-cache", qos: .utility)
    private let diskCacheRoot: URL
    // Optional writes retain at most 1/32 of the thumbnail cache's byte budget.
    // Count also bounds tiny images/queue bookkeeping; the active write counts.
    static let pendingDiskWriteByteLimit = 8 * 1024 * 1024
    static let pendingDiskWriteCountLimit = 32
    static let neighbourPrefetchLimit = 4 // Existing [+1, +2, +3, -1] window.
    private let diskWriteLock = NSLock()
    private var diskWrites: [URL: CGImage] = [:]
    private var diskWriteOrder: [URL] = []
    private var diskWriteBytes = 0
    private var diskDrainScheduled = false
    private var diskWriteWaiters: [CheckedContinuation<Void, Never>] = []

    private enum DecodeKind: Hashable { case thumbnail, full }
    private struct DecodeRequest: Hashable {
        let kind: DecodeKind
        let key: String
    }
    private final class PendingDecode {
        var waiters: [UUID: CheckedContinuation<NSImage?, Never>]
        let operation: BlockOperation
        let readAccess: MediaOperationReadAccess
        var admissionTask: Task<Void, Never>?
        var submitted = false

        init(waiters: [UUID: CheckedContinuation<NSImage?, Never>], operation: BlockOperation, readAccess: MediaOperationReadAccess) {
            self.waiters = waiters
            self.operation = operation
            self.readAccess = readAccess
        }
    }
    private struct DecodedImage {
        let image: NSImage
        let cost: Int
        let diskWrite: (image: CGImage, url: URL)?

        init(_ image: CGImage, diskURL: URL? = nil) {
            self.image = NSImage(cgImage: image, size: .zero)
            cost = ImagePipeline.cost(of: image)
            diskWrite = diskURL.map { (image, $0) }
        }
    }
    private let testingDecoder: (@Sendable (URL, CGFloat) -> CGImage?)?
    private let testingDiskWriter: (@Sendable (CGImage, URL) -> Void)?

    private final class GeneratedImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?

        func store(_ image: CGImage?) {
            lock.lock()
            self.image = image
            lock.unlock()
        }

        func load() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }
    private let inFlightLock = NSLock()
    private var inFlight: [DecodeRequest: PendingDecode] = [:]
    private static let lastDiskPruneDefaultsKey =
        "LouppeThumbnailCacheLastPrune"

    static let thumbPixelSize: CGFloat = 320
    static let fullPixelSize: CGFloat = 4096

    private convenience init() {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(
            diskCacheRoot: caches.appendingPathComponent(
                "Louppe/Thumbnails",
                isDirectory: true
            ),
            schedulesMaintenance: true
        )
    }

    /// Isolated cache instance for focused tests. Production code always uses
    /// `shared`; this initializer deliberately skips UserDefaults and pruning.
    convenience init(
        testingDiskCacheRoot: URL,
        thumbnailConcurrency: Int? = nil,
        fullConcurrency: Int? = nil,
        foregroundWork: ForegroundWorkCoordinator = .shared,
        decoder: (@Sendable (URL, CGFloat) -> CGImage?)? = nil
    ) {
        self.init(
            diskCacheRoot: testingDiskCacheRoot,
            schedulesMaintenance: false,
            foregroundWork: foregroundWork,
            testingDecoder: decoder
        )
        if let thumbnailConcurrency {
            thumbnailDecodeQueue.maxConcurrentOperationCount = max(1, thumbnailConcurrency)
        }
        if let fullConcurrency {
            fullDecodeQueue.maxConcurrentOperationCount = max(1, fullConcurrency)
        }
    }

    convenience init(
        testingDiskCacheRoot: URL,
        thumbnailConcurrency: Int? = nil,
        fullConcurrency: Int? = nil,
        foregroundWork: ForegroundWorkCoordinator = .shared,
        testingDiskWriter: @escaping @Sendable (CGImage, URL) -> Void,
        decoder: (@Sendable (URL, CGFloat) -> CGImage?)? = nil
    ) {
        self.init(
            diskCacheRoot: testingDiskCacheRoot,
            schedulesMaintenance: false,
            foregroundWork: foregroundWork,
            testingDiskWriter: testingDiskWriter,
            testingDecoder: decoder
        )
        if let thumbnailConcurrency { thumbnailDecodeQueue.maxConcurrentOperationCount = max(1, thumbnailConcurrency) }
        if let fullConcurrency { fullDecodeQueue.maxConcurrentOperationCount = max(1, fullConcurrency) }
    }

    private init(
        diskCacheRoot: URL,
        schedulesMaintenance: Bool,
        foregroundWork: ForegroundWorkCoordinator = .shared,
        testingDiskWriter: (@Sendable (CGImage, URL) -> Void)? = nil,
        testingDecoder: (@Sendable (URL, CGFloat) -> CGImage?)? = nil
    ) {
        self.foregroundWork = foregroundWork
        self.diskCacheRoot = diskCacheRoot
        self.testingDecoder = testingDecoder
        self.testingDiskWriter = testingDiskWriter
        thumbCache.countLimit = 1200
        thumbCache.totalCostLimit = 256 * 1024 * 1024
        fullCache.countLimit = 8
        fullCache.totalCostLimit = 384 * 1024 * 1024
        try? FileManager.default.createDirectory(at: diskCacheRoot, withIntermediateDirectories: true)
        guard schedulesMaintenance else { return }
        let lastPrunedAt = UserDefaults.standard.object(
            forKey: Self.lastDiskPruneDefaultsKey
        ) as? Date
        if Self.shouldPruneDiskCache(
            lastPrunedAt: lastPrunedAt,
            now: Date()
        ) {
            // Cache maintenance can stat thousands of files. Give launch,
            // Gallery rendering, and the first Grid switch uncontested I/O;
            // one delayed daily pass is sufficient for a 90-day cache.
            diskQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                Task.detached(priority: .utility) {
                    if await self.pruneDiskCacheWithAdmission() {
                        UserDefaults.standard.set(Date(), forKey: Self.lastDiskPruneDefaultsKey)
                    }
                }
            }
        }
    }

    // MARK: - Public API

    /// Synchronous memory-cache-only lookups — cheap enough to call during
    /// view construction. They let the Gallery view show *something* the very
    /// frame the photo changes (the prefetched full image, or the Browser
    /// thumbnail as a low-res preview) instead of flashing an empty pane.
    func cachedFullImage(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault) -> NSImage? {
        fullCache.object(forKey: Self.fullCacheKey(for: item, mode: mode, decoder: decoder) as NSString)
    }

    func cachedThumbnail(for item: PhotoItem) -> NSImage? {
        thumbCache.object(forKey: Self.cacheKey(for: item) as NSString)
    }

    /// Test synchronization boundary for best-effort cache promotions/writes.
    func waitForPendingDiskWrites() async {
        await withCheckedContinuation { continuation in
            diskWriteLock.lock()
            if diskDrainScheduled {
                diskWriteWaiters.append(continuation)
                diskWriteLock.unlock()
            } else {
                diskWriteLock.unlock()
                continuation.resume()
            }
        }
    }

    func thumbnail(for item: PhotoItem, sourceAccess: MediaReadAccess? = nil) async -> NSImage? {
        guard !item.isAudio && !item.isText, !Task.isCancelled else { return nil }
        let key = Self.cacheKey(for: item)
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }
        let revision = MediaSourceRevision(item)
        return await decodeOnce(
            kind: .thumbnail,
            key: key,
            qualityOfService: .userInitiated,
            queuePriority: .normal,
            sourceAccess: sourceAccess
        ) { [self] in
            loadThumbnailSync(item: item, revision: revision, key: key)
        }
    }

    func fullImage(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault, sourceAccess: MediaReadAccess? = nil) async -> NSImage? {
        guard !item.isAudio && !item.isText, !Task.isCancelled else { return nil }
        let key = Self.fullCacheKey(for: item, mode: mode, decoder: decoder)
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        return await fullImage(
            for: MediaSourceRevision(item),
            key: key,
            qualityOfService: .userInitiated,
            queuePriority: .veryHigh,
            rendersRAW: mode.rendersRAW(for: item),
            decoder: decoder,
            sourceAccess: sourceAccess
        )
    }

    private func fullImage(
        for revision: MediaSourceRevision,
        key: String,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority,
        rendersRAW: Bool = false,
        decoder: AppleRawDecoder = .appleDefault,
        sourceAccess: MediaReadAccess? = nil
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        return await decodeOnce(
            kind: .full,
            key: key,
            qualityOfService: qualityOfService,
            queuePriority: queuePriority,
            sourceAccess: sourceAccess
        ) { [self] in
            loadFullSync(revision: revision, key: key, rendersRAW: rendersRAW, decoder: decoder)
        }
    }

    /// The session retains this handle and cancels it on navigation, folder,
    /// projection or decoder changes. Cancellation propagates to each neighbour
    /// waiter without cancelling a foreground caller sharing the same decode.
    @discardableResult
    func prefetchFullImages(
        items: [PhotoItem],
        mode: RawDisplayMode = .fast,
        decoder: AppleRawDecoder = .appleDefault,
        sourceAccess: MediaReadAccess? = nil
    ) -> Task<Void, Never> {
        guard !Task.isCancelled else { return Task {} }
        var keys = Set<String>()
        var neighbours: [PhotoItem] = []
        for item in items where item.mediaKind == .photo && item.isSupported {
            let key = Self.fullCacheKey(for: item, mode: mode, decoder: decoder)
            guard keys.insert(key).inserted else { continue }
            if fullCache.object(forKey: key as NSString) == nil { neighbours.append(item) }
            if keys.count == Self.neighbourPrefetchLimit { break }
        }
        return Task.detached(priority: .utility) { [self, neighbours] in
            await withTaskGroup(of: Void.self) { group in
                for item in neighbours {
                    guard !Task.isCancelled else { break }
                    group.addTask { [self] in
                        _ = await fullImage(
                            for: MediaSourceRevision(item),
                            key: Self.fullCacheKey(for: item, mode: mode, decoder: decoder),
                            qualityOfService: .utility,
                            queuePriority: .low,
                            rendersRAW: mode.rendersRAW(for: item),
                            decoder: decoder,
                            sourceAccess: sourceAccess
                        )
                    }
                }
            }
        }
    }

    /// Each caller owns a cancellable waiter, while live callers still share
    /// one bounded operation. Retiring the last waiter removes queued work;
    /// an uncancellable ImageIO call retains its queue slot until it exits.
    private func decodeOnce(
        kind: DecodeKind,
        key: String,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority,
        sourceAccess: MediaReadAccess? = nil,
        work: @escaping @Sendable () -> DecodedImage?
    ) async -> NSImage? {
        let demand = queuePriority == .low ? nil : foregroundWork.beginForegroundDemand()
        defer { demand?.finish() }
        let request = DecodeRequest(kind: kind, key: key)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inFlightLock.lock()
                guard !Task.isCancelled else {
                    inFlightLock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                let cached: NSImage?
                switch kind {
                case .thumbnail: cached = thumbCache.object(forKey: key as NSString)
                case .full: cached = fullCache.object(forKey: key as NSString)
                }
                if let cached {
                    inFlightLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                if let pending = inFlight[request] {
                    pending.readAccess.retainIfNeeded(sourceAccess)
                    pending.waiters[waiterID] = continuation
                    // Visible work can promote an existing neighbour prefetch.
                    if queuePriority == .veryHigh {
                        pending.operation.queuePriority = .veryHigh
                        pending.operation.qualityOfService = .userInitiated
                        pending.admissionTask?.cancel()
                        pending.admissionTask = nil
                    }
                    let operation = pending.operation
                    inFlightLock.unlock()
                    if queuePriority == .veryHigh { submit(request, operation: operation) }
                    return
                }

                let readAccess = MediaOperationReadAccess(sourceAccess)
                let operation = BlockOperation()
                // Queued cancellation may skip the execution block entirely.
                operation.completionBlock = { readAccess.finish() }
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { return }
                    // Waiter cancellation can return before native decoding.
                    // The executing block, rather than its view/task, owns I/O.
                    defer { readAccess.finish() }
                    let result = autoreleasepool { work() }
                    self.finish(request, operation: operation, result: result)
                }
                operation.qualityOfService = qualityOfService
                operation.queuePriority = queuePriority
                let pending = PendingDecode(waiters: [waiterID: continuation], operation: operation, readAccess: readAccess)
                inFlight[request] = pending
                if queuePriority == .low {
                    pending.admissionTask = Task.detached(priority: .utility) { [weak self, weak operation, foregroundWork] in
                        guard await foregroundWork.waitForBackgroundAdmission(), !Task.isCancelled,
                              let self, let operation else { return }
                        self.submit(request, operation: operation)
                    }
                }
                inFlightLock.unlock()
                if queuePriority != .low { submit(request, operation: operation) }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(waiterID, for: request)
        }
    }

    /// Submission is identity-checked under the same lock as coalescing and
    /// retirement. A visible join can bypass admission without a second decode.
    private func submit(_ request: DecodeRequest, operation: BlockOperation) {
        let admitted = inFlightLock.withLock {
            guard let pending = inFlight[request], pending.operation === operation,
                  !pending.submitted, !operation.isCancelled else { return false }
            pending.submitted = true
            pending.admissionTask = nil
            return true
        }
        guard admitted else { return }
        switch request.kind {
        case .thumbnail: thumbnailDecodeQueue.addOperation(operation)
        case .full: fullDecodeQueue.addOperation(operation)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for request: DecodeRequest) {
        inFlightLock.lock()
        guard let pending = inFlight[request],
              let waiter = pending.waiters.removeValue(forKey: waiterID)
        else {
            inFlightLock.unlock()
            return
        }
        if pending.waiters.isEmpty {
            inFlight.removeValue(forKey: request)
            pending.admissionTask?.cancel()
            // BlockOperation cancellation never releases an executing lane:
            // its synchronous block must return before the next worker starts.
            pending.operation.cancel()
            if !pending.submitted { pending.readAccess.finish() }
        }
        inFlightLock.unlock()
        waiter.resume(returning: nil)
    }

    private func finish(_ request: DecodeRequest, operation: BlockOperation, result: DecodedImage?) {
        inFlightLock.lock()
        guard let pending = inFlight[request], pending.operation === operation else {
            inFlightLock.unlock()
            return
        }
        inFlight.removeValue(forKey: request)
        if let result, !operation.isCancelled {
            switch request.kind {
            case .thumbnail: thumbCache.setObject(result.image, forKey: request.key as NSString, cost: result.cost)
            case .full: fullCache.setObject(result.image, forKey: request.key as NSString, cost: result.cost)
            }
            if let write = result.diskWrite {
                // Only a live operation may warm memory or schedule disk I/O.
                enqueueDiskWrite(image: write.image, url: write.url)
            }
        }
        let waiters = Array(pending.waiters.values)
        inFlightLock.unlock()
        for waiter in waiters { waiter.resume(returning: result?.image) }
    }

    private func enqueueDiskWrite(image: CGImage, url: URL) {
        diskWriteLock.lock()
        let cost = Self.cost(of: image)
        guard diskWrites[url] == nil,
              diskWrites.count < Self.pendingDiskWriteCountLimit,
              cost <= Self.pendingDiskWriteByteLimit - diskWriteBytes else {
            diskWriteLock.unlock()
            return // Cache output is optional; visible pixels have priority.
        }
        let startsDrain = !diskDrainScheduled
        diskDrainScheduled = true
        diskWrites[url] = image
        diskWriteOrder.append(url)
        diskWriteBytes += cost
        diskWriteLock.unlock()
        if startsDrain {
            // One task owns the drain, with one queued write at a time. Waiting
            // for admission occupies neither the disk queue nor a decode lane.
            Task.detached(priority: .utility) { [self] in await drainDiskWrites() }
        }
    }

    private func drainDiskWrites() async {
        while true {
            let state: ((url: URL, image: CGImage)?, [CheckedContinuation<Void, Never>]) = diskWriteLock.withLock {
                guard let url = diskWriteOrder.first, let image = diskWrites[url] else {
                    diskDrainScheduled = false
                    let waiters = diskWriteWaiters
                    diskWriteWaiters.removeAll()
                    return (nil, waiters)
                }
                return ((url, image), [])
            }
            guard let write = state.0 else {
                for waiter in state.1 { waiter.resume() }
                return
            }
            // The active candidate stays charged to the byte/count limits while
            // suspended. These optional cache bytes never delay visible pixels.
            _ = await foregroundWork.waitForBackgroundAdmission()
            await withCheckedContinuation { continuation in
                diskQueue.async { [self] in
                    autoreleasepool {
                        if let testingDiskWriter {
                            testingDiskWriter(write.image, write.url)
                        } else {
                            let rep = NSBitmapImageRep(cgImage: write.image)
                            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                                try? jpeg.write(to: write.url, options: .atomic)
                            }
                        }
                    }
                    diskWriteLock.withLock {
                        diskWriteBytes -= Self.cost(of: write.image)
                        diskWrites.removeValue(forKey: write.url)
                        diskWriteOrder.removeFirst()
                    }
                    continuation.resume()
                }
            }
        }
    }

    #if DEBUG
    var pendingDiskWritesForTesting: (count: Int, bytes: Int) {
        diskWriteLock.withLock { (diskWrites.count, diskWriteBytes) }
    }

    func evictThumbnailForTesting(for item: PhotoItem) {
        thumbCache.removeObject(forKey: Self.cacheKey(for: item) as NSString)
    }

    func waitForFullWorkForTesting() async {
        await withCheckedContinuation { continuation in
            let barrier = BlockOperation { continuation.resume() }
            for operation in fullDecodeQueue.operations { barrier.addDependency(operation) }
            fullDecodeQueue.addOperation(barrier)
        }
    }

    func decodeWaiterCountForTesting(for item: PhotoItem, full: Bool = false) -> Int {
        let request = DecodeRequest(kind: full ? .full : .thumbnail, key: Self.cacheKey(for: item))
        return inFlightLock.withLock { inFlight[request]?.waiters.count ?? 0 }
    }
    #endif

    // MARK: - Decoding

    private func loadThumbnailSync(item: PhotoItem, revision: MediaSourceRevision, key: String) -> DecodedImage? {
        guard !item.isAudio && !item.isText else { return nil }
        // Try the on-disk thumbnail cache first.
        let diskURL = diskCacheRoot.appendingPathComponent(
            Self.diskFileName(for: key)
        )
        if let cgImage = Self.decodeImage(url: diskURL, maxPixel: Self.thumbPixelSize) {
            return DecodedImage(cgImage)
        }

        // v5 binds the cache to scan-time physical identity. Identity-less
        // v4/v3 thumbnails are only candidates for synthetic/legacy items
        // that have no scanned identity of their own. Once identity is known,
        // no timestamp comparison can prove which inode produced old cache
        // bytes on every supported filesystem, so production scans take the
        // one-time cold migration and fail closed.
        for legacyKey in Self.compatibilityThumbnailCacheKeys(for: item) {
            let legacyURL = diskCacheRoot.appendingPathComponent(
                Self.diskFileName(for: legacyKey)
            )
            guard Self.compatibilityThumbnailIsSafe(
                at: legacyURL,
                for: item
            ), let cgImage = Self.decodeImage(
                url: legacyURL,
                maxPixel: Self.thumbPixelSize
            ) else { continue }

            // Re-encode validated compatibility pixels only if the operation
            // still owns live waiters when it finishes.
            return DecodedImage(cgImage, diskURL: diskURL)
        }

        let cgImage = revision.read {
            if let testingDecoder { return testingDecoder(revision.url, Self.thumbPixelSize) }
            return item.isVideo
                ? decodeFirstVideoFrame(url: revision.url, maxPixel: Self.thumbPixelSize)
                : Self.decodeImage(url: revision.url, maxPixel: Self.thumbPixelSize)
        }
        guard let cgImage else { return nil }
        return DecodedImage(cgImage, diskURL: diskURL)
    }

    private func loadFullSync(revision: MediaSourceRevision, key: String, rendersRAW: Bool, decoder: AppleRawDecoder) -> DecodedImage? {
        guard let cgImage = revision.read({
            if let testingDecoder { return testingDecoder(revision.url, Self.fullPixelSize) }
            return rendersRAW
                ? RawImageRendering.preview(url: revision.url, maximumPixelSize: Self.fullPixelSize, decoder: decoder)
                : Self.decodeImage(url: revision.url, maxPixel: Self.fullPixelSize)
        }) else { return nil }
        return DecodedImage(cgImage)
    }

    /// Exact first displayable movie frame. This runs on the existing bounded
    /// thumbnail queue, never the main actor, and shares image thumbnails'
    /// memory/disk caching and request coalescing.
    private func decodeFirstVideoFrame(url: URL, maxPixel: CGFloat) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let box = GeneratedImageBox()
        let semaphore = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            box.store(image)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return box.load()
    }

    /// ImageIO decode. For RAW files this pulls the embedded preview rather than
    /// doing a full demosaic, which is what keeps the app fast.
    ///
    /// Many JPEGs carry a tiny embedded thumbnail (~160px). Asking ImageIO to
    /// reuse it would return that tiny image upscaled — visibly pixelated. So:
    /// try the fast embedded path first, and if the result is much smaller than
    /// what we asked for, fall back to a real decode of the full image.
    static func decodeImage(url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        // The size we actually want: no bigger than the photo itself.
        var target = maxPixel
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat {
            target = min(maxPixel, max(width, height))
        }

        let fastOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let fast = CGImageSourceCreateThumbnailAtIndex(source, 0, fastOptions as CFDictionary)
        if let fast, CGFloat(max(fast.width, fast.height)) >= target * 0.9 {
            return fast
        }

        // Embedded preview was too small — decode the real image at full quality.
        let fullOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, fullOptions as CFDictionary) ?? fast
    }

    static func fullCacheKey(for item: PhotoItem, mode: RawDisplayMode, decoder: AppleRawDecoder = .appleDefault) -> String {
        let key = cacheKey(for: item)
        return mode.rendersRAW(for: item) ? "\(key)|apple-raw-presentation-v2|\(decoder.rawValue)" : key
    }

    // MARK: - Cache keys

    /// Internal so the performance checks can enforce that cache lookup stays
    /// independent of the live filesystem after scanning.
    static func cacheKey(for item: PhotoItem) -> String {
        // Relative IDs repeat across folders and survive same-folder rescans.
        // v5 adds the scan-time physical identity to byte-exact path, content
        // timestamps, size, and kind so a replacement cannot share pixels.
        "\(item.contentRevision.cacheIdentity)|v5"
    }

    /// Immediately previous key. It is only a compatibility candidate after
    /// its cache-file creation date proves it cannot predate the scanned file.
    static func previousThumbnailCacheKey(for item: PhotoItem) -> String {
        let mtime = item.primaryModificationDate?.timeIntervalSince1970 ?? 0
        let absoluteIdentity = FolderScanner.fileSystemIdentityPath(
            for: item.primaryURL
        )
        return "\(absoluteIdentity)|\(mtime)|\(item.mediaKind.rawValue)|v4"
    }

    /// Previous thumbnail key, used only as a one-way compatibility read for
    /// ASCII filesystem paths where decoded and byte identity cannot diverge.
    static func legacyThumbnailCacheKey(for item: PhotoItem) -> String? {
        let path = item.primaryURL.path
        guard path.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let mtime = item.primaryModificationDate?.timeIntervalSince1970 ?? 0
        return "\(path)|\(mtime)|\(item.mediaKind.rawValue)|v3"
    }

    private static func compatibilityThumbnailCacheKeys(
        for item: PhotoItem
    ) -> [String] {
        var keys = [previousThumbnailCacheKey(for: item)]
        if let v3 = legacyThumbnailCacheKey(for: item) {
            keys.append(v3)
        }
        return keys
    }

    static func compatibilityThumbnailIsSafe(
        at cacheURL: URL,
        for item: PhotoItem
    ) -> Bool {
        let revision = item.contentRevision
        guard revision.stableFileIdentity == nil,
              let sourceFloor = revision.compatibilityCacheFloorDate,
              let values = try? cacheURL.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
              ),
              values.isRegularFile == true,
              let cacheDate = values.contentModificationDate
        else {
            return false
        }
        return cacheDate >= sourceFloor
    }

    static func diskFileName(for key: String) -> String {
        // Stable, filesystem-safe name derived from the cache key.
        var hash: UInt64 = 14695981039346656037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx.jpg", hash)
    }

    private static func cost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    static func shouldPruneDiskCache(
        lastPrunedAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastPrunedAt else { return true }
        let elapsed = now.timeIntervalSince(lastPrunedAt)
        // A clock correction or corrupt future timestamp must not suppress
        // maintenance until wall time eventually catches up.
        guard elapsed >= 0 else { return true }
        return elapsed >= 24 * 60 * 60
    }

    /// One utility task and one serial-queue batch at a time. Admission has a
    /// fixed maximum deferral, so repeated interaction cannot starve pruning.
    private func pruneDiskCacheWithAdmission(
        onBatch: (@Sendable (Int) -> Void)? = nil
    ) async -> Bool {
        let pass = DiskCachePrunePass(root: diskCacheRoot)
        while await foregroundWork.waitForBackgroundAdmission() {
            let done = await withCheckedContinuation { continuation in
                diskQueue.async {
                    let done = autoreleasepool { pass.processBatch() }
                    onBatch?(pass.lastBatchCount)
                    continuation.resume(returning: done)
                }
            }
            if done { return pass.succeeded }
        }
        return false
    }

    #if DEBUG
    func pruneDiskCacheForTesting(onBatch: (@Sendable (Int) -> Void)? = nil) async -> Bool {
        await pruneDiskCacheWithAdmission(onBatch: onBatch)
    }
    #endif

    /// Synchronous compatibility boundary for cache-policy tests. Production
    /// always uses the admitted, bounded batches above, off the main actor.
    @discardableResult
    static func pruneDiskCache(at root: URL) -> Bool {
        let pass = DiskCachePrunePass(root: root)
        while !pass.processBatch() {}
        return pass.succeeded
    }

    /// Accessed serially by the disk queue (or the synchronous test boundary).
    /// Directory enumeration does not prefetch resource values for all entries.
    private final class DiskCachePrunePass: @unchecked Sendable {
        static let batchLimit = 64
        private let root: URL
        private let fm = FileManager()
        private let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        private let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        private var enumerator: FileManager.DirectoryEnumerator?
        private var started = false
        private var enumerated = false
        private var files: [(url: URL, size: Int64, date: Date)] = []
        private var total: Int64 = 0
        private var evictionIndex = 0
        private(set) var succeeded = true
        private(set) var lastBatchCount = 0

        init(root: URL) { self.root = root }

        func processBatch() -> Bool {
            lastBatchCount = 0
            if !started {
                started = true
                enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                           options: [.skipsSubdirectoryDescendants],
                                           errorHandler: { [weak self] _, _ in
                    self?.succeeded = false
                    return false
                })
                guard enumerator != nil else { succeeded = false; return true }
            }
            if !enumerated {
                for _ in 0..<Self.batchLimit {
                    guard let url = enumerator?.nextObject() as? URL else {
                        enumerated = true
                        enumerator = nil
                        files.sort { $0.date < $1.date }
                        return total <= 512 * 1024 * 1024 || !succeeded
                    }
                    lastBatchCount += 1
                    guard let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { continue }
                    let date = values.contentModificationDate ?? .distantPast
                    if date < cutoff {
                        try? fm.removeItem(at: url)
                    } else {
                        let size = Int64(values.fileSize ?? 0)
                        files.append((url, size, date))
                        total += size
                    }
                }
                return false
            }
            while evictionIndex < files.count && total > 512 * 1024 * 1024
                    && lastBatchCount < Self.batchLimit {
                let file = files[evictionIndex]
                evictionIndex += 1
                lastBatchCount += 1
                if (try? fm.removeItem(at: file.url)) != nil { total -= file.size }
            }
            return total <= 512 * 1024 * 1024 || evictionIndex == files.count
        }
    }
}
