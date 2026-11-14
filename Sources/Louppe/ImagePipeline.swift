import Foundation
import AppKit
import ImageIO
import AVFoundation
import OSLog

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

/// How a Fit preview that is not a RAW render is requested. Only formats
/// with a measured gain leave `.bounded`: HEIC, JPEG XL, NEF previews and
/// the rest decode no faster at native or exact scales.
enum FitDecodeSizing: Hashable, Sendable {
    /// The original request: long edge at most 4,096 pixels.
    case bounded
    /// JPEG decoder scales sized to cover this display tier.
    case exactScale(coverage: CGSize)
    /// RAF camera previews are about 4,416 pixels; resampling them to 4,096
    /// more than doubled the decode.
    case embeddedPreview

    init(item: PhotoItem, mode: RawDisplayMode, coverage: CGSize?) {
        guard !mode.rendersRAW(for: item) else { self = .bounded; return }
        switch item.primaryURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            if let coverage, coverage.width > 0, coverage.height > 0 {
                self = .exactScale(coverage: coverage)
            } else {
                self = .bounded
            }
        case "raf": self = .embeddedPreview
        default: self = .bounded
        }
    }

    /// The size tier in full-preview cache keys; `.bounded` keeps old keys.
    var keySuffix: String {
        switch self {
        case .bounded: return ""
        case .exactScale(let coverage): return "|fit-scaled-\(Int(coverage.width))x\(Int(coverage.height))"
        case .embeddedPreview: return "|fit-embedded"
        }
    }
}

/// One decode lane for unpromoted neighbour work. Callers guard it with their
/// own lock. The owner stays referenced until it exits, so its identifier
/// cannot be reused; parked work runs in arrival order once admitted.
struct PrefetchLane<Request> {
    private var owner: BlockOperation?
    private var parked: [(request: Request, operation: BlockOperation)] = []

    /// True when `operation` holds the lane; otherwise it is parked.
    mutating func claim(_ request: Request, _ operation: BlockOperation) -> Bool {
        if owner == nil || owner === operation {
            owner = operation
            return true
        }
        if !parked.contains(where: { $0.operation === operation }) { parked.append((request, operation)) }
        return false
    }

    /// Retires `operation` from the lane or the parked list. Freeing the
    /// lane hands it to the oldest parked work that is still live.
    mutating func release(
        _ operation: ObjectIdentifier,
        isLive: (Request, BlockOperation) -> Bool
    ) -> (Request, BlockOperation)? {
        guard let current = owner, ObjectIdentifier(current) == operation else {
            parked.removeAll { ObjectIdentifier($0.operation) == operation }
            return nil
        }
        owner = nil
        while !parked.isEmpty {
            let next = parked.removeFirst()
            if isLive(next.request, next.operation) {
                owner = next.operation
                return next
            }
        }
        return nil
    }

    var isHeld: Bool { owner != nil }
    var parkedCount: Int { parked.count }
}

/// Decodes images with ImageIO (extracting embedded previews for RAW files),
/// caches thumbnails in memory + on disk, and prefetches around the current photo.
// @unchecked Sendable: safe to share across threads — NSCache and the queues
// are thread-safe; the only mutable dictionary is protected by `inFlightLock`.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let foregroundWork: ForegroundWorkCoordinator
    /// Visible full-preview decodes only; no interaction quiet window. It keeps
    /// the shared coordinator's 750 ms per-wait escape.
    private let visibleFullDecodes = ForegroundWorkCoordinator(quietInterval: .zero)
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
        queue.maxConcurrentOperationCount = ImagePipeline.thumbnailLaneWidth
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// JPEG XL has no embedded preview: each thumbnail decodes the whole image
    /// on many threads. On the shared lane four at once help a cold Grid, but in
    /// Gallery they made the visible photo's Fit decode about five times
    /// slower. After Gallery navigation to an uncached photo, JPEG XL thumbnails
    /// requested until that photo's full preview finishes (at most one second)
    /// use this lane one at a time; its backlog then drains at full width.
    private let wholeImageThumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.thumbnail.whole-image"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    static let wholeImageThumbnailExtensions: Set<String> = ["jxl"]
    /// The same rule for the other consumers: without an embedded preview or
    /// a reduced-size decode, a histogram or 100% recipe also costs the whole image.
    static func decodesWholeImage(_ item: PhotoItem) -> Bool {
        item.mediaKind == .photo && wholeImageThumbnailExtensions.contains(item.primaryURL.pathExtension.lowercased())
    }
    static let thumbnailLaneWidth = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    // Guarded by inFlightLock.
    private var visibleFullDecodeCount = 0
    private var wholeImageYield: (generation: UInt64, since: ContinuousClock.Instant)?
    private var wholeImageYieldGeneration: UInt64 = 0
    private let diskQueue = DispatchQueue(label: "louppe.thumbnail-disk-cache", qos: .utility)
    private let diskCacheRoot: URL
    // Optional writes retain at most 1/32 of the thumbnail cache's byte budget.
    // Count also bounds tiny images/queue bookkeeping; the active write counts.
    // The cue walk may reserve one more thumbnail and drains before its next build.
    static let pendingDiskWriteByteLimit = 8 * 1024 * 1024
    static let pendingDiskWriteCountLimit = 32
    static let neighbourPrefetchLimit = 4 // Existing [+1, +2, +3, -1] window.
    private let diskWriteLock = NSLock()
    private var diskWrites: [URL: CGImage] = [:]
    private var diskWriteOrder: [URL] = []
    private var diskWriteBytes = 0
    private var diskDrainScheduled = false
    /// Optional writes refused at the byte/count limit (not coalesced keys);
    /// evidence for whether bursts lose disk thumbnails.
    private var droppedDiskWrites = 0
    private var diskWriteWaiters: [CheckedContinuation<Void, Never>] = []
    /// The 512 MiB disk ceiling. A pass that finds more evicts the oldest
    /// entries down to the ceiling minus one live-maintenance interval.
    static let diskCacheByteLimit: Int64 = 512 * 1024 * 1024
    /// Live enforcement between daily passes: bytes this process may write
    /// before its first pass, and the eviction hysteresis below the ceiling.
    static let liveMaintenanceWriteInterval: Int64 = 64 * 1024 * 1024
    private let diskByteLimit: Int64
    private let liveMaintenanceInterval: Int64?
    private let maintenanceRecordsDefaults: Bool
    // Guarded by diskWriteLock. One maintenance pass at a time; later passes
    // start from completed writes, never from per-thumbnail directory walks.
    private var maintenanceRunning = false
    private var knownDiskBytes: Int64?
    private var diskBytesSinceMaintenance: Int64 = 0
    private var maintenanceFailureStreak = 0
    private var maintenancePassCount = 0
    private var maintenanceStartCount = 0
    private var activeMaintenancePasses = 0
    private var peakMaintenancePasses = 0

    private enum DecodeKind: Hashable { case thumbnail, wholeImageThumbnail, full }
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
        /// Neighbour work that has not been promoted by a visible caller.
        var isPrefetch = false
        /// Admitted after visible full decodes only, not shared demand.
        var leadsNeighbours = false
        /// A thumbnail only background work has asked for (the cue walk):
        /// its pixels go to the disk cache, not the memory cache.
        var isBackgroundThumbnail = false
        /// A cue waiter requires disk output even if a tile joins/promotes it.
        var needsThumbnailDiskWrite = false

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
    private let testingDiskRemover: (@Sendable (URL) throws -> Void)?
    private static let maintenanceLogger = Logger(subsystem: "com.alexandermarkin.louppe",
                                                  category: "ThumbnailCacheMaintenance")

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
    // Guarded by inFlightLock. Unpromoted neighbour work occupies at most one
    // full-decode lane, so the current photo always has the other.
    private var prefetchLane = PrefetchLane<DecodeRequest>()
    #if LOUPPE_TEST_SEAMS
    // Configure before starting workers; pauses after lane ownership transfers.
    var beforePrefetchHandoffSubmissionForTesting: (@Sendable () -> Void)?
    // Guarded by inFlightLock. Source files decoded after every cache missed.
    private var thumbnailSourceDecodes = 0
    private var fullSourceDecodes = 0
    #endif
    private static let lastDiskPruneDefaultsKey =
        "LouppeThumbnailCacheLastPrune"

    static let thumbPixelSize: CGFloat = 320
    static let fullPixelSize: CGFloat = 4096

    private convenience init() {
        // Test hosts get a disposable per-process root and no daily pruning,
        // so hidden test decodes cannot fill or evict a person's thumbnails.
        self.init(
            diskCacheRoot: Self.sharedDiskCacheRoot,
            schedulesMaintenance: !RebuildableCacheLocation.isTestHost
        )
    }

    static var sharedDiskCacheRoot: URL {
        (RebuildableCacheLocation.root ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Louppe/Thumbnails", isDirectory: true)
    }

    /// Isolated cache instance for focused tests. Production code always uses
    /// `shared`; this initializer deliberately skips UserDefaults and pruning.
    convenience init(
        testingDiskCacheRoot: URL,
        thumbnailConcurrency: Int? = nil,
        fullConcurrency: Int? = nil,
        foregroundWork: ForegroundWorkCoordinator = .shared,
        diskCacheByteLimit: Int64 = ImagePipeline.diskCacheByteLimit,
        liveMaintenanceWriteInterval: Int64? = nil,
        decoder: (@Sendable (URL, CGFloat) -> CGImage?)? = nil,
        // After `decoder`, so existing trailing decoder closures still bind to it.
        diskCacheRemover: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.init(
            diskCacheRoot: testingDiskCacheRoot,
            schedulesMaintenance: false,
            foregroundWork: foregroundWork,
            diskCacheByteLimit: diskCacheByteLimit,
            liveMaintenanceWriteInterval: liveMaintenanceWriteInterval,
            testingDiskRemover: diskCacheRemover,
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
        diskCacheByteLimit: Int64 = ImagePipeline.diskCacheByteLimit,
        liveMaintenanceWriteInterval: Int64? = nil,
        testingDiskWriter: (@Sendable (CGImage, URL) -> Void)? = nil,
        testingDiskRemover: (@Sendable (URL) throws -> Void)? = nil,
        testingDecoder: (@Sendable (URL, CGFloat) -> CGImage?)? = nil
    ) {
        self.foregroundWork = foregroundWork
        self.diskCacheRoot = diskCacheRoot
        self.testingDecoder = testingDecoder
        self.testingDiskWriter = testingDiskWriter
        self.testingDiskRemover = testingDiskRemover
        diskByteLimit = max(1, diskCacheByteLimit)
        // Test hosts never prune unless a focused test injects small limits.
        liveMaintenanceInterval = schedulesMaintenance
            ? Self.liveMaintenanceWriteInterval
            : liveMaintenanceWriteInterval.map { max(1, $0) }
        maintenanceRecordsDefaults = schedulesMaintenance
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
                self?.startMaintenanceIfIdle()
            }
        }
    }

    // MARK: - Public API

    /// Synchronous memory-cache-only lookups — cheap enough to call during
    /// view construction. They let the Gallery view show *something* the very
    /// frame the photo changes (the prefetched full image, or the Browser
    /// thumbnail as a low-res preview) instead of flashing an empty pane.
    func cachedFullImage(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault, sizing: FitDecodeSizing? = nil) -> NSImage? {
        let sizing = sizing ?? FitDecodeSizing(item: item, mode: mode, coverage: Self.displayCoverage)
        return fullCache.object(forKey: Self.fullCacheKey(for: item, mode: mode, decoder: decoder, sizing: sizing) as NSString)
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

    /// `background`: the cue walk building a thumbnail nobody is looking at.
    /// Same key, coalescing and disk cache as a tile's request, but it waits
    /// for background admission like neighbour prefetch and is no foreground
    /// demand, and its pixels are written to disk and left out of the memory
    /// cache, so they evict no tile on screen. A tile that asks meanwhile
    /// joins, starts the decode at once and caches the result as usual.
    func thumbnail(for item: PhotoItem, sourceAccess: MediaReadAccess? = nil, background: Bool = false) async -> NSImage? {
        guard !item.isAudio && !item.isText, !Task.isCancelled else { return nil }
        let key = Self.cacheKey(for: item)
        if let cached = thumbCache.object(forKey: key as NSString) { return cached }
        let revision = MediaSourceRevision(item)
        let wholeImage = Self.wholeImageThumbnailExtensions.contains(item.primaryURL.pathExtension.lowercased())
        return await decodeOnce(
            kind: wholeImage ? .wholeImageThumbnail : .thumbnail,
            key: key,
            qualityOfService: background ? .utility : .userInitiated,
            queuePriority: background ? .low : .normal,
            sourceAccess: sourceAccess
        ) { [self] in
            loadThumbnailSync(item: item, revision: revision, key: key)
        }
    }

    func fullImage(for item: PhotoItem, mode: RawDisplayMode = .fast, decoder: AppleRawDecoder = .appleDefault, sizing: FitDecodeSizing? = nil, sourceAccess: MediaReadAccess? = nil) async -> NSImage? {
        guard !item.isAudio && !item.isText, !Task.isCancelled else { return nil }
        // One coverage snapshot sizes both the key and the decode.
        let sizing = sizing ?? FitDecodeSizing(item: item, mode: mode, coverage: Self.displayCoverage)
        let key = Self.fullCacheKey(for: item, mode: mode, decoder: decoder, sizing: sizing)
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        return await fullImage(
            for: MediaSourceRevision(item),
            key: key,
            qualityOfService: .userInitiated,
            queuePriority: .veryHigh,
            rendersRAW: mode.rendersRAW(for: item),
            sizing: sizing,
            decoder: decoder,
            sourceAccess: sourceAccess
        )
    }

    /// The cached Fast-mode Fit preview, or the result of one already in
    /// flight; never starts a decode. The joined waiter is cancellable like
    /// any other, but neither promotes the work nor counts as foreground demand.
    func fullImageIfCachedOrInFlight(for item: PhotoItem, sourceAccess: MediaReadAccess? = nil) async -> NSImage? {
        guard !item.isAudio && !item.isText, !Task.isCancelled else { return nil }
        let key = Self.fullCacheKey(for: item, mode: .fast)
        if let cached = fullCache.object(forKey: key as NSString) { return cached }
        let request = DecodeRequest(kind: .full, key: key)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inFlightLock.lock()
                let cancelled = Task.isCancelled
                let cached = cancelled ? nil : fullCache.object(forKey: key as NSString)
                guard !cancelled, cached == nil, let pending = inFlight[request] else {
                    inFlightLock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                pending.readAccess.retainIfNeeded(sourceAccess)
                pending.waiters[waiterID] = continuation
                inFlightLock.unlock()
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(waiterID, for: request)
        }
    }

    private func fullImage(
        for revision: MediaSourceRevision,
        key: String,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority,
        rendersRAW: Bool = false,
        sizing: FitDecodeSizing,
        decoder: AppleRawDecoder = .appleDefault,
        sourceAccess: MediaReadAccess? = nil,
        leadsNeighbours: Bool = false,
        onRegistered: (@Sendable () -> Void)? = nil
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        return await decodeOnce(
            kind: .full,
            key: key,
            qualityOfService: qualityOfService,
            queuePriority: queuePriority,
            sourceAccess: sourceAccess,
            leadsNeighbours: leadsNeighbours,
            onRegistered: onRegistered
        ) { [self] in
            loadFullSync(revision: revision, key: key, rendersRAW: rendersRAW, sizing: sizing, decoder: decoder)
        }
    }

    /// The session retains this handle and cancels it on navigation, folder,
    /// projection or decoder changes. Cancellation propagates to each neighbour
    /// waiter without cancelling a foreground caller sharing the same decode.
    @discardableResult
    func prefetchFullImages(
        items: [PhotoItem],
        after current: PhotoItem? = nil,
        mode: RawDisplayMode = .fast,
        decoder: AppleRawDecoder = .appleDefault,
        sourceAccess: MediaReadAccess? = nil,
        replacing previous: Task<Void, Never>? = nil,
        nearestWaitsForVisibleDecodeOnly: Bool = true
    ) -> Task<Void, Never> {
        guard !Task.isCancelled else {
            previous?.cancel()
            return Task {}
        }
        let coverage = Self.displayCoverage
        var keys = Set<String>()
        var neighbours: [(item: PhotoItem, key: String, sizing: FitDecodeSizing)] = []
        // The visible photo first: its view joins or promotes this waiter, and
        // no neighbour can race ahead of the view's debounced request.
        var leading = nearestWaitsForVisibleDecodeOnly ? 1 : 0
        if let current, current.mediaKind == .photo, current.isSupported {
            let sizing = FitDecodeSizing(item: current, mode: mode, coverage: coverage)
            let key = Self.fullCacheKey(for: current, mode: mode, decoder: decoder, sizing: sizing)
            if fullCache.object(forKey: key as NSString) == nil {
                neighbours.append((current, key, sizing))
                leading += 1
            }
        }
        for item in items where item.mediaKind == .photo && item.isSupported {
            let sizing = FitDecodeSizing(item: item, mode: mode, coverage: coverage)
            let key = Self.fullCacheKey(for: item, mode: mode, decoder: decoder, sizing: sizing)
            guard keys.insert(key).inserted else { continue }
            if fullCache.object(forKey: key as NSString) == nil { neighbours.append((item, key, sizing)) }
            if keys.count == Self.neighbourPrefetchLimit { break }
        }
        // In the caller's order (direction of travel first), one at a time:
        // each neighbour waits for admission only after the previous decode.
        // The nearest uncached one starts as soon as the visible decode ends.
        return Task.detached(priority: .utility) { [self, neighbours, leading] in
            // `previous` may own the only waiter of a decode this window needs:
            // cancel it after the first waiter here is registered.
            defer { previous?.cancel() }
            let releasePrevious: @Sendable () -> Void = { previous?.cancel() }
            for (index, neighbour) in neighbours.enumerated() {
                guard !Task.isCancelled else { break }
                _ = await fullImage(
                    for: MediaSourceRevision(neighbour.item),
                    key: neighbour.key,
                    qualityOfService: .utility,
                    queuePriority: .low,
                    rendersRAW: mode.rendersRAW(for: neighbour.item),
                    sizing: neighbour.sizing,
                    decoder: decoder,
                    sourceAccess: sourceAccess,
                    leadsNeighbours: index < leading,
                    onRegistered: index == 0 ? releasePrevious : nil
                )
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
        leadsNeighbours: Bool = false,
        onRegistered: (@Sendable () -> Void)? = nil,
        work: @escaping @Sendable () -> DecodedImage?
    ) async -> NSImage? {
        let demand = queuePriority == .low ? nil : foregroundWork.beginForegroundDemand()
        defer { demand?.finish() }
        let isVisibleFull = kind == .full && queuePriority == .veryHigh
        let fitDemand = isVisibleFull ? visibleFullDecodes.beginForegroundDemand() : nil
        if isVisibleFull { inFlightLock.withLock { visibleFullDecodeCount += 1 } }
        defer {
            fitDemand?.finish()
            if isVisibleFull {
                inFlightLock.withLock { visibleFullDecodeCount -= 1 }
                endWholeImageYield(generation: nil)
            }
        }
        let request = DecodeRequest(kind: kind, key: key)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Every path below unlocks first: the waiter is registered or answered.
                defer { onRegistered?() }
                inFlightLock.lock()
                guard !Task.isCancelled else {
                    inFlightLock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                let cached: NSImage?
                switch kind {
                case .thumbnail, .wholeImageThumbnail: cached = thumbCache.object(forKey: key as NSString)
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
                    if queuePriority == .low, kind != .full { pending.needsThumbnailDiskWrite = true }
                    // Visible work can promote an existing neighbour prefetch,
                    // and a tile the cue walk's thumbnail build.
                    var next: (DecodeRequest, BlockOperation)?
                    let promotes = queuePriority == .veryHigh
                        || (pending.isBackgroundThumbnail && queuePriority != .low)
                    if promotes {
                        pending.operation.queuePriority = queuePriority
                        pending.operation.qualityOfService = qualityOfService
                        pending.admissionTask?.cancel()
                        pending.admissionTask = nil
                        pending.isBackgroundThumbnail = false
                        // Promoted work no longer counts against the neighbour lane.
                        if pending.isPrefetch {
                            pending.isPrefetch = false
                            next = prefetchLane.release(ObjectIdentifier(pending.operation), isLive: isLivePrefetchLocked)
                        }
                    }
                    // The nearest neighbour may join work an older window queued
                    // farther out; it no longer waits on shared demand.
                    if leadsNeighbours, pending.isPrefetch, !pending.submitted, !pending.leadsNeighbours {
                        pending.admissionTask?.cancel()
                        pending.leadsNeighbours = true
                        pending.admissionTask = admissionTask(for: request, operation: pending.operation, leads: true)
                    }
                    let operation = pending.operation
                    inFlightLock.unlock()
                    if promotes { submit(request, operation: operation) }
                    if let next { submit(next.0, operation: next.1) }
                    return
                }

                let readAccess = MediaOperationReadAccess(sourceAccess)
                let operation = BlockOperation()
                // Queued cancellation may skip the execution block entirely.
                let operationID = ObjectIdentifier(operation)
                operation.completionBlock = { [weak self] in
                    readAccess.finish()
                    self?.prefetchOperationExited(operationID)
                }
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
                // The neighbour lane is one of the two full-decode lanes;
                // thumbnails have their own queue.
                pending.isPrefetch = queuePriority == .low && kind == .full
                pending.isBackgroundThumbnail = queuePriority == .low && kind != .full
                pending.needsThumbnailDiskWrite = pending.isBackgroundThumbnail
                inFlight[request] = pending
                if queuePriority == .low {
                    pending.leadsNeighbours = leadsNeighbours
                    pending.admissionTask = admissionTask(for: request, operation: operation, leads: leadsNeighbours)
                }
                inFlightLock.unlock()
                if queuePriority != .low { submit(request, operation: operation) }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(waiterID, for: request)
        }
    }

    /// Gallery navigation: let the new photo's full preview decode without
    /// several whole-image thumbnails competing for the CPU.
    func yieldWholeImageThumbnails(to item: PhotoItem, mode: RawDisplayMode, decoder: AppleRawDecoder) {
        guard item.mediaKind == .photo, item.isSupported,
              cachedFullImage(for: item, mode: mode, decoder: decoder) == nil else { return }
        let generation: UInt64 = inFlightLock.withLock {
            wholeImageYieldGeneration &+= 1
            wholeImageYield = (wholeImageYieldGeneration, .now)
            wholeImageThumbnailQueue.maxConcurrentOperationCount = 1
            return wholeImageYieldGeneration
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.endWholeImageYield(generation: generation)
        }
    }

    /// A finished visible decode ends the yield unless navigation just began
    /// one whose view has not requested its decode yet (40 ms debounce).
    private func endWholeImageYield(generation: UInt64?) {
        inFlightLock.withLock {
            guard let yield = wholeImageYield else { return }
            if let generation {
                // The deadline is a hard cap, even if Fit is still decoding.
                guard generation == yield.generation else { return }
            } else {
                guard visibleFullDecodeCount == 0,
                      ContinuousClock.now - yield.since >= .milliseconds(150) else { return }
            }
            wholeImageYield = nil
            wholeImageThumbnailQueue.maxConcurrentOperationCount = Self.thumbnailLaneWidth
        }
    }

    /// Leaving Gallery or retiring a session also widens any existing backlog.
    func cancelWholeImageThumbnailYield() {
        inFlightLock.withLock {
            wholeImageYield = nil
            wholeImageThumbnailQueue.maxConcurrentOperationCount = Self.thumbnailLaneWidth
        }
    }

    /// The nearest neighbour waits only for the visible photo's full decode,
    /// not for Browser thumbnails or other demand; both keep the 750 ms escape.
    private func admissionTask(for request: DecodeRequest, operation: BlockOperation, leads: Bool) -> Task<Void, Never> {
        let admission = leads ? visibleFullDecodes : foregroundWork
        return Task.detached(priority: .utility) { [weak self, weak operation, admission] in
            // A cue thumbnail has no visible consumer and needs a whole-image
            // decode. Keep yielding while demand is held, including beyond
            // the coordinator's per-wait escape; visible joins bypass this.
            while true {
                guard await admission.waitForBackgroundAdmission(), !Task.isCancelled else { return }
                if request.kind == .full || admission.shouldAdmitBackgroundWork(deferredSince: .now) { break }
                // Overflow can bypass the admission hint; never spin there.
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self, let operation else { return }
            self.submit(request, operation: operation)
        }
    }

    /// Submission is identity-checked under the same lock as coalescing and
    /// retirement. A visible join can bypass admission without a second decode.
    private func submit(_ request: DecodeRequest, operation: BlockOperation) {
        let (admitted, yielding) = inFlightLock.withLock {
            guard let pending = inFlight[request], pending.operation === operation,
                  !pending.submitted, !operation.isCancelled else { return (false, false) }
            pending.admissionTask = nil
            // An admitted neighbour waits here while another holds the lane.
            if pending.isPrefetch, !prefetchLane.claim(request, operation) { return (false, false) }
            pending.submitted = true
            return (true, wholeImageYield != nil)
        }
        guard admitted else { return }
        switch request.kind {
        case .thumbnail: thumbnailDecodeQueue.addOperation(operation)
        case .wholeImageThumbnail:
            (yielding ? wholeImageThumbnailQueue : thumbnailDecodeQueue).addOperation(operation)
        case .full: fullDecodeQueue.addOperation(operation)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for request: DecodeRequest) {
        var next: (DecodeRequest, BlockOperation)?
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
            if !pending.submitted {
                pending.readAccess.finish()
                next = prefetchLane.release(ObjectIdentifier(pending.operation), isLive: isLivePrefetchLocked)
            }
        }
        inFlightLock.unlock()
        waiter.resume(returning: nil)
        if let next { submit(next.0, operation: next.1) }
    }

    private func isLivePrefetchLocked(_ request: DecodeRequest, _ operation: BlockOperation) -> Bool {
        guard let pending = inFlight[request] else { return false }
        return pending.operation === operation && pending.isPrefetch && !pending.submitted && !operation.isCancelled
    }

    /// Called after an operation's block exits or its queued cancellation
    /// completes; only then can the next neighbour take the lane.
    private func prefetchOperationExited(_ operation: ObjectIdentifier) {
        let next = inFlightLock.withLock { prefetchLane.release(operation, isLive: isLivePrefetchLocked) }
        if let next {
            #if LOUPPE_TEST_SEAMS
            beforePrefetchHandoffSubmissionForTesting?()
            #endif
            submit(next.0, operation: next.1)
        }
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
            case .thumbnail, .wholeImageThumbnail:
                if !pending.isBackgroundThumbnail {
                    thumbCache.setObject(result.image, forKey: request.key as NSString, cost: result.cost)
                }
            case .full: fullCache.setObject(result.image, forKey: request.key as NSString, cost: result.cost)
            }
            if let write = result.diskWrite {
                // Only a live operation may warm memory or schedule disk I/O.
                enqueueDiskWrite(image: write.image, url: write.url, builtForDisk: pending.needsThumbnailDiskWrite)
            }
        }
        let waiters = Array(pending.waiters.values)
        inFlightLock.unlock()
        for waiter in waiters { waiter.resume(returning: result?.image) }
    }

    /// `builtForDisk`: a background thumbnail, decoded for this write and
    /// held nowhere else. Reserve one extra thumbnail slot against a tile
    /// burst; the cue walk drains writes before building the next thumbnail.
    private func enqueueDiskWrite(image: CGImage, url: URL, builtForDisk: Bool = false) {
        diskWriteLock.lock()
        let cost = Self.cost(of: image)
        guard diskWrites[url] == nil else {
            diskWriteLock.unlock()
            return // Already queued for this key.
        }
        let reservedCount = builtForDisk ? 1 : 0
        let reservedBytes = builtForDisk ? cost : 0
        guard diskWrites.count < Self.pendingDiskWriteCountLimit + reservedCount,
              cost <= Self.pendingDiskWriteByteLimit + reservedBytes - diskWriteBytes else {
            droppedDiskWrites += 1
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
                    let written: Int64 = autoreleasepool {
                        if let testingDiskWriter {
                            testingDiskWriter(write.image, write.url)
                            return Int64((try? write.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        }
                        let rep = NSBitmapImageRep(cgImage: write.image)
                        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
                              (try? jpeg.write(to: write.url, options: .atomic)) != nil else { return 0 }
                        return Int64(jpeg.count)
                    }
                    let startsMaintenance = diskWriteLock.withLock {
                        diskWriteBytes -= Self.cost(of: write.image)
                        diskWrites.removeValue(forKey: write.url)
                        diskWriteOrder.removeFirst()
                        diskBytesSinceMaintenance += written
                        return claimLiveMaintenanceLocked()
                    }
                    if startsMaintenance { runClaimedMaintenance() }
                    continuation.resume()
                }
            }
        }
    }

    #if LOUPPE_TEST_SEAMS
    var pendingDiskWritesForTesting: (count: Int, bytes: Int) {
        diskWriteLock.withLock { (diskWrites.count, diskWriteBytes) }
    }

    var droppedDiskWritesForTesting: Int { diskWriteLock.withLock { droppedDiskWrites } }

    func evictThumbnailForTesting(for item: PhotoItem) {
        thumbCache.removeObject(forKey: Self.cacheKey(for: item) as NSString)
    }

    var diskCacheRootForTesting: URL { diskCacheRoot }

    func waitForFullWorkForTesting() async {
        await withCheckedContinuation { continuation in
            let barrier = BlockOperation { continuation.resume() }
            for operation in fullDecodeQueue.operations { barrier.addDependency(operation) }
            fullDecodeQueue.addOperation(barrier)
        }
    }

    var wholeImageYieldForTesting: (generation: UInt64?, width: Int) {
        inFlightLock.withLock { (wholeImageYield?.generation, wholeImageThumbnailQueue.maxConcurrentOperationCount) }
    }

    func expireWholeImageYieldForTesting(generation: UInt64) { endWholeImageYield(generation: generation) }

    var visibleAdmissionWaitingForTesting: Int { visibleFullDecodes.waitingCountForTesting }

    var prefetchLaneForTesting: (held: Bool, parked: Int) {
        inFlightLock.withLock { (prefetchLane.isHeld, prefetchLane.parkedCount) }
    }

    func decodeWaiterCountForTesting(for item: PhotoItem, full: Bool = false) -> Int {
        let key = full ? Self.fullCacheKey(for: item, mode: .fast) : Self.cacheKey(for: item)
        let request = DecodeRequest(kind: full ? .full : (Self.decodesWholeImage(item) ? .wholeImageThumbnail : .thumbnail), key: key)
        return inFlightLock.withLock { inFlight[request]?.waiters.count ?? 0 }
    }

    /// Source decodes started so far; memory and disk-cache hits do not count.
    var sourceDecodesForTesting: (thumbnail: Int, full: Int) {
        inFlightLock.withLock { (thumbnailSourceDecodes, fullSourceDecodes) }
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
        // A background build's pixels wait here until their write lands.
        if let unwritten = diskWriteLock.withLock({ diskWrites[diskURL] }) {
            return DecodedImage(unwritten)
        }
        if let promoted = promoteV5Thumbnail(for: item, to: diskURL) {
            return promoted
        }

        // v6/v5 bind the cache to scan-time physical identity. Identity-less
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

        #if LOUPPE_TEST_SEAMS
        inFlightLock.withLock { thumbnailSourceDecodes += 1 }
        #endif
        let cgImage = revision.read {
            if let testingDecoder { return testingDecoder(revision.url, Self.thumbPixelSize) }
            return item.isVideo
                ? decodeFirstVideoFrame(url: revision.url, maxPixel: Self.thumbPixelSize)
                : Self.decodeImage(url: revision.url, maxPixel: Self.thumbPixelSize)
        }
        guard let cgImage else { return nil }
        return DecodedImage(cgImage, diskURL: diskURL)
    }

    /// v5 keys add the mount root and device number to every v6 field, so a
    /// v5 entry for the current identity holds valid v6 pixels. One atomic
    /// rename moves it without re-encoding and removes the v5 name. If a
    /// racing operation already moved it, read the v6 file that it left.
    /// A corrupt promoted file falls through to a fresh source decode, whose
    /// atomic write replaces it.
    private func promoteV5Thumbnail(for item: PhotoItem, to diskURL: URL) -> DecodedImage? {
        let v5URL = diskCacheRoot.appendingPathComponent(
            Self.diskFileName(for: Self.v5ThumbnailCacheKey(for: item))
        )
        guard v5URL != diskURL else { return nil }
        let renamed = v5URL.withUnsafeFileSystemRepresentation { source in
            diskURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return false }
                return Darwin.rename(source, destination) == 0
            }
        }
        guard renamed || FileManager.default.fileExists(atPath: diskURL.path),
              let cgImage = Self.decodeImage(url: diskURL, maxPixel: Self.thumbPixelSize)
        else { return nil }
        return DecodedImage(cgImage)
    }

    private func loadFullSync(revision: MediaSourceRevision, key: String, rendersRAW: Bool, sizing: FitDecodeSizing, decoder: AppleRawDecoder) -> DecodedImage? {
        #if LOUPPE_TEST_SEAMS
        inFlightLock.withLock { fullSourceDecodes += 1 }
        #endif
        guard let cgImage = revision.read({
            if let testingDecoder { return testingDecoder(revision.url, Self.fullPixelSize) }
            return rendersRAW
                ? RawImageRendering.preview(url: revision.url, maximumPixelSize: Self.fullPixelSize, decoder: decoder)
                : Self.decodeFitImage(url: revision.url, sizing: sizing)
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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        return decodeImage(source: source, pixelSize: storedPixelSize(of: source), maxPixel: maxPixel)
    }

    private static var sourceOptions: [CFString: Any] { [kCGImageSourceShouldCache: false] }

    private static func storedPixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Fit preview decode. `.bounded` is the original 4,096-pixel request;
    /// the other cases request a size ImageIO produces without resampling.
    static func decodeFitImage(url: URL, sizing: FitDecodeSizing) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let pixelSize = storedPixelSize(of: source)
        switch sizing {
        case .bounded:
            return decodeImage(source: source, pixelSize: pixelSize, maxPixel: fullPixelSize)
        case .embeddedPreview:
            // A camera preview up to the hard bound returns as stored; the
            // undersized check and full fallback still use the usual bound.
            return decodeImage(source: source, pixelSize: pixelSize, maxPixel: fullPixelSize,
                               embeddedMaxPixel: fitOutputPixelBound)
        case .exactScale(let coverage):
            let request = pixelSize.map { exactScalePixelSize(orientedSize: $0, coverage: coverage) } ?? fullPixelSize
            return decodeImage(source: source, pixelSize: pixelSize, maxPixel: request,
                               embeddedAcceptancePixelSize: fullPixelSize)
        }
    }

    /// The smallest JPEG decoder scale (1/8, 1/4, 1/2) whose output still
    /// covers the photo fitted to `coverage` and the 3,840-pixel custom-zoom
    /// floor, else native size within the
    /// hard bound, else the original bounded request. Never more than
    /// `fitOutputPixelBound` pixels on the long edge.
    static func exactScalePixelSize(orientedSize: CGSize, coverage: CGSize) -> CGFloat {
        let long = max(orientedSize.width, orientedSize.height)
        guard long > fullPixelSize, orientedSize.width > 0, orientedSize.height > 0,
              coverage.width > 0, coverage.height > 0 else { return fullPixelSize }
        let fitted = min(1, coverage.width / orientedSize.width, coverage.height / orientedSize.height)
        // Keep enough detail for custom zoom below 100%, even on small displays.
        let required = max(min(long, 3840), min(fullPixelSize, (long * fitted).rounded(.up)))
        for divisor: CGFloat in [8, 4, 2] {
            // libjpeg rounds scaled dimensions up.
            let scaled = (long / divisor).rounded(.up)
            if scaled >= required && scaled <= fitOutputPixelBound { return scaled }
        }
        return long <= fitOutputPixelBound ? long : fullPixelSize
    }

    private static func decodeImage(
        source: CGImageSource,
        pixelSize: CGSize?,
        maxPixel: CGFloat,
        embeddedMaxPixel: CGFloat? = nil,
        embeddedAcceptancePixelSize: CGFloat? = nil
    ) -> CGImage? {
        // Exact-scale Fit requests must not lower the old embedded-preview
        // acceptance threshold. The fallback still decodes at the exact scale.
        var target = max(maxPixel, embeddedAcceptancePixelSize ?? maxPixel)
        if let pixelSize {
            target = min(target, max(pixelSize.width, pixelSize.height))
        }

        let fastOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: embeddedMaxPixel ?? maxPixel,
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
        fullCacheKey(for: item, mode: mode, decoder: decoder,
                     sizing: FitDecodeSizing(item: item, mode: mode, coverage: displayCoverage))
    }

    static func fullCacheKey(for item: PhotoItem, mode: RawDisplayMode, decoder: AppleRawDecoder, sizing: FitDecodeSizing) -> String {
        let key = cacheKey(for: item)
        return mode.rendersRAW(for: item) ? "\(key)|apple-raw-presentation-v2|\(decoder.rawValue)" : key + sizing.keySuffix
    }

    // MARK: - Fit sizing

    /// Hard long-edge limit for Fit outputs that skip resampling: 12.5% over
    /// the 4,096-pixel bound, about 7 MiB more per decoded 3:2 image.
    static let fitOutputPixelBound: CGFloat = 4608

    /// Largest active display in backing pixels. No Fit viewport can show
    /// more, and window resizing never changes it, so it is the size tier.
    /// nil (no display) keeps the bounded request.
    static var displayCoverage: CGSize? { DisplayCoverage.shared.current }
    static let displayCoverageDidChange = Notification.Name("louppe.display-coverage-changed")

    #if LOUPPE_TEST_SEAMS
    static func setDisplayCoverageForTesting(_ value: CGSize?) { DisplayCoverage.shared.update(value) }
    #endif

    private final class DisplayCoverage: @unchecked Sendable {
        static let shared = DisplayCoverage()
        private let lock = NSLock()
        private var value: CGSize?
        private var observer: NSObjectProtocol?

        private init() {
            value = Self.measure()
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.update(Self.measure())
            }
        }

        var current: CGSize? { lock.withLock { value } }

        func update(_ newValue: CGSize?) {
            let changed = lock.withLock {
                guard value != newValue else { return false }
                value = newValue
                return true
            }
            if changed { NotificationCenter.default.post(name: ImagePipeline.displayCoverageDidChange, object: nil) }
        }

        /// CoreGraphics display modes are safe off the main thread.
        private static func measure() -> CGSize? {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
            var width = 0, height = 0
            for display in displays.prefix(Int(count)) {
                guard let mode = CGDisplayCopyDisplayMode(display) else { continue }
                let rotated = Int(CGDisplayRotation(display).rounded()) % 180 == 90
                width = max(width, rotated ? mode.pixelHeight : mode.pixelWidth)
                height = max(height, rotated ? mode.pixelWidth : mode.pixelHeight)
            }
            return width > 0 && height > 0 ? CGSize(width: width, height: height) : nil
        }
    }

    // MARK: - Cache keys

    /// Internal so the performance checks can enforce that cache lookup stays
    /// independent of the live filesystem after scanning.
    static func cacheKey(for item: PhotoItem) -> String {
        // Relative IDs repeat across folders and survive same-folder rescans.
        // v5 added the scan-time physical identity to byte-exact path, content
        // timestamps, size, and kind so a replacement cannot share pixels.
        // v6 lets a volume UUID replace the transient device number and mount
        // root, so a remounted drive keeps its thumbnails.
        "\(item.contentRevision.cacheIdentity)|v6"
    }

    /// Exact v5 key for the current identity: a promotion source only.
    static func v5ThumbnailCacheKey(for item: PhotoItem) -> String {
        "\(item.contentRevision.v5CacheIdentity)|v5"
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

    /// Called under diskWriteLock after a completed write. Before this process
    /// knows the cache total, one interval of writes starts a pass; afterwards
    /// a pass starts only when the known total plus later writes exceeds the
    /// ceiling. The flag prevents overlapping launch and live passes.
    private func claimLiveMaintenanceLocked() -> Bool {
        guard let interval = liveMaintenanceInterval, !maintenanceRunning,
              diskBytesSinceMaintenance >= Self.maintenanceBackoffBytes(
                interval: interval, consecutiveFailures: maintenanceFailureStreak)
        else { return false }
        let due = knownDiskBytes.map { $0 + diskBytesSinceMaintenance > diskByteLimit }
            ?? (diskBytesSinceMaintenance >= interval)
        if due { maintenanceRunning = true }
        return due
    }

    /// Writes required before a live pass retries after failed passes: one
    /// interval, doubling per consecutive failure up to eight. A successful
    /// pass resets the streak; the daily launch pass ignores it.
    static func maintenanceBackoffBytes(interval: Int64, consecutiveFailures: Int) -> Int64 {
        guard consecutiveFailures > 0 else { return 0 }
        let factor = Int64(1) << min(consecutiveFailures - 1, 3)
        let (bytes, overflow) = interval.multipliedReportingOverflow(by: factor)
        return overflow ? .max : bytes
    }

    private func startMaintenanceIfIdle() {
        let claimed = diskWriteLock.withLock {
            guard !maintenanceRunning else { return false }
            maintenanceRunning = true
            return true
        }
        if claimed { runClaimedMaintenance() }
    }

    private func runClaimedMaintenance() {
        Task.detached(priority: .utility) { [self] in
            diskWriteLock.withLock {
                diskBytesSinceMaintenance = 0
                maintenanceStartCount += 1
                activeMaintenancePasses += 1
                peakMaintenancePasses = max(peakMaintenancePasses, activeMaintenancePasses)
            }
            let result = await pruneDiskCacheWithAdmission()
            let (continues, failures) = diskWriteLock.withLock {
                activeMaintenancePasses -= 1
                maintenanceRunning = false
                maintenancePassCount += 1
                // Writes during the pass may already be in the walked total;
                // counting them again only makes the next pass earlier.
                // Undeleted files remain in a fully listed total.
                knownDiskBytes = result.totalIsKnown ? result.remainingBytes : nil
                maintenanceFailureStreak = result.succeeded ? 0 : maintenanceFailureStreak + 1
                // Writes that finished during the pass could not claim it; chain
                // one more pass now rather than waiting for a later write.
                return (result.succeeded && claimLiveMaintenanceLocked(), maintenanceFailureStreak)
            }
            if result.succeeded {
                if maintenanceRecordsDefaults {
                    UserDefaults.standard.set(Date(), forKey: Self.lastDiskPruneDefaultsKey)
                }
            } else {
                // Counts and error codes only; cache paths stay out of logs.
                let error = result.firstDeletionError.map { "\($0.domain):\($0.code)" } ?? "none"
                Self.maintenanceLogger.error("""
                    Thumbnail cache maintenance failed: listed=\(result.totalIsKnown, privacy: .public) \
                    failedDeletions=\(result.failedDeletions, privacy: .public) \
                    failedBytes=\(result.failedDeletionBytes, privacy: .public) \
                    error=\(error, privacy: .public) consecutiveFailures=\(failures, privacy: .public)
                    """)
            }
            if continues { runClaimedMaintenance() }
        }
    }

    /// One utility task and one serial-queue batch at a time. Admission has a
    /// fixed maximum deferral, so repeated interaction cannot starve pruning.
    private func pruneDiskCacheWithAdmission(
        onBatch: (@Sendable (Int) -> Void)? = nil
    ) async -> DiskPruneResult {
        let pass = DiskCachePrunePass(root: diskCacheRoot, limit: diskByteLimit,
                                      target: Self.evictionTarget(limit: diskByteLimit,
                                                                  interval: liveMaintenanceInterval),
                                      remover: testingDiskRemover)
        while await foregroundWork.waitForBackgroundAdmission() {
            let done = await withCheckedContinuation { continuation in
                diskQueue.async {
                    let done = autoreleasepool { pass.processBatch() }
                    onBatch?(pass.lastBatchCount)
                    continuation.resume(returning: done)
                }
            }
            if done { return pass.result(completed: true) }
        }
        return pass.result(completed: false)
    }

    /// Hysteresis keeps a full cache from walking its directory after every
    /// few writes; tiny injected limits keep at least half of the ceiling.
    static func evictionTarget(limit: Int64, interval: Int64?) -> Int64 {
        max(limit / 2, limit - (interval ?? liveMaintenanceWriteInterval))
    }

    #if LOUPPE_TEST_SEAMS
    func pruneDiskCacheForTesting(onBatch: (@Sendable (Int) -> Void)? = nil) async -> Bool {
        await pruneDiskCacheWithAdmission(onBatch: onBatch).succeeded
    }

    var diskMaintenanceForTesting: (running: Bool, passes: Int, knownBytes: Int64?, consecutiveFailures: Int) {
        diskWriteLock.withLock { (maintenanceRunning, maintenancePassCount, knownDiskBytes, maintenanceFailureStreak) }
    }

    func startDiskMaintenanceForTesting() { startMaintenanceIfIdle() }

    /// Claimed passes, including any not yet running their first batch.
    var diskMaintenanceStartsForTesting: Int {
        diskWriteLock.withLock { maintenanceStartCount + (maintenanceRunning && activeMaintenancePasses == 0 ? 1 : 0) }
    }

    var diskMaintenancePeakConcurrencyForTesting: Int { diskWriteLock.withLock { peakMaintenancePasses } }
    #endif

    /// Synchronous compatibility boundary for cache-policy tests. Production
    /// always uses the admitted, bounded batches above, off the main actor.
    @discardableResult
    static func pruneDiskCache(at root: URL) -> Bool {
        let pass = DiskCachePrunePass(root: root, limit: diskCacheByteLimit,
                                      target: evictionTarget(limit: diskCacheByteLimit, interval: nil))
        while !pass.processBatch() {}
        return pass.succeeded
    }

    /// Outcome of one maintenance pass. Files that could not be deleted stay
    /// in `remainingBytes`; any failed deletion makes the pass a failure.
    struct DiskPruneResult: Sendable {
        /// The whole directory was listed, so `remainingBytes` is the total.
        var totalIsKnown: Bool
        var failedDeletions: Int
        var failedDeletionBytes: Int64
        var firstDeletionError: (domain: String, code: Int)?
        var remainingBytes: Int64
        var succeeded: Bool { totalIsKnown && failedDeletions == 0 }
    }

    /// Accessed serially by the disk queue (or the synchronous test boundary).
    /// Directory enumeration does not prefetch resource values for all entries.
    private final class DiskCachePrunePass: @unchecked Sendable {
        static let batchLimit = 64
        private let root: URL
        private let limit: Int64
        private let target: Int64
        private let fm: FileManager
        private let remove:(URL) throws -> Void
        private let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        private let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        private var enumerator: FileManager.DirectoryEnumerator?
        private var started = false
        private var enumerated = false
        private var files: [(url: URL, size: Int64, date: Date)] = []
        private var total: Int64 = 0
        private var evictionIndex = 0
        private var listingSucceeded = true
        private var failedDeletions = 0
        private var failedDeletionBytes: Int64 = 0
        private var firstDeletionError: (domain: String, code: Int)?
        private(set) var lastBatchCount = 0

        init(root: URL, limit: Int64, target: Int64,
             remover: (@Sendable (URL) throws -> Void)? = nil) {
            self.root = root
            self.limit = limit
            self.target = min(limit, max(0, target))
            let fm = FileManager()
            self.fm = fm
            if let remover { remove = remover } else { remove = { try fm.removeItem(at: $0) } }
        }

        var remainingBytes: Int64 { total }
        var succeeded: Bool { listingSucceeded && failedDeletions == 0 }

        /// `completed` is false when admission ended the pass early.
        func result(completed: Bool) -> DiskPruneResult {
            DiskPruneResult(totalIsKnown: completed && enumerated && listingSucceeded,
                            failedDeletions: failedDeletions, failedDeletionBytes: failedDeletionBytes,
                            firstDeletionError: firstDeletionError, remainingBytes: total)
        }

        /// An undeleted file is still on disk: callers keep it in `total`.
        private func delete(_ url: URL, size: Int64) -> Bool {
            do {
                try remove(url)
                return true
            } catch {
                failedDeletions += 1
                failedDeletionBytes += size
                if firstDeletionError == nil {
                    let error = error as NSError
                    firstDeletionError = (error.domain, error.code)
                }
                return false
            }
        }

        func processBatch() -> Bool {
            lastBatchCount = 0
            if !started {
                started = true
                enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                           options: [.skipsSubdirectoryDescendants],
                                           errorHandler: { [weak self] _, _ in
                    self?.listingSucceeded = false
                    return false
                })
                guard enumerator != nil else { listingSucceeded = false; return true }
            }
            if !enumerated {
                for _ in 0..<Self.batchLimit {
                    guard let url = enumerator?.nextObject() as? URL else {
                        enumerated = true
                        enumerator = nil
                        files.sort { $0.date < $1.date }
                        return total <= limit || !listingSucceeded
                    }
                    lastBatchCount += 1
                    guard let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { continue }
                    let date = values.contentModificationDate ?? .distantPast
                    let size = Int64(values.fileSize ?? 0)
                    if date < cutoff {
                        // Not an eviction candidate: one attempt per pass.
                        if !delete(url, size: size) { total += size }
                    } else {
                        files.append((url, size, date))
                        total += size
                    }
                }
                return false
            }
            // Only an over-limit total reaches eviction. Evicting to the lower
            // target means the next live pass needs another interval of writes.
            while evictionIndex < files.count && total > target
                    && lastBatchCount < Self.batchLimit {
                let file = files[evictionIndex]
                evictionIndex += 1
                lastBatchCount += 1
                if delete(file.url, size: file.size) { total -= file.size }
            }
            return total <= target || evictionIndex == files.count
        }
    }
}
