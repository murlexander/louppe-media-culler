import Foundation
import CoreImage

/// A lazy, oriented Core Image recipe for one source file. Holding this object
/// does not allocate a full decoded bitmap; individual source-pixel tiles are
/// rendered on demand.
final class ZoomImageSource: @unchecked Sendable {
    let key: String
    let image: CIImage
    let pixelSize: CGSize
    let sourceRevision: MediaSourceRevision?
    let decoder: AppleRawDecoder
    let sourceAccess: MediaReadAccess?

    init(key: String, image: CIImage, pixelSize: CGSize, sourceRevision: MediaSourceRevision? = nil, decoder: AppleRawDecoder = .appleDefault, sourceAccess: MediaReadAccess? = nil) {
        self.key = key
        self.image = image
        self.pixelSize = pixelSize
        self.sourceRevision = sourceRevision
        self.decoder = decoder
        self.sourceAccess = sourceAccess
    }

    /// Cache recipes hold a capability, never a permanently open scope. Each
    /// later tile starts its own operation lease from this exact authority.
    func retainingSourceAccess(_ authority: MediaReadAccess?) -> ZoomImageSource {
        guard let authority else { return self }
        return ZoomImageSource(key: key, image: image, pixelSize: pixelSize,
                               sourceRevision: sourceRevision, decoder: decoder,
                               sourceAccess: authority)
    }
}

struct ZoomTileCoordinate: Hashable, Sendable {
    let column: Int
    let row: Int

    func pixelRect(
        sourceSize: CGSize,
        tilePixels: Int = HighResolutionImagePipeline.tilePixelSize
    ) -> CGRect? {
        guard column >= 0, row >= 0, tilePixels > 0 else { return nil }
        let x = CGFloat(column * tilePixels)
        let y = CGFloat(row * tilePixels)
        guard x < sourceSize.width, y < sourceSize.height else { return nil }
        return CGRect(
            x: x,
            y: y,
            width: min(CGFloat(tilePixels), sourceSize.width - x),
            height: min(CGFloat(tilePixels), sourceSize.height - y)
        )
    }
}

struct ZoomImageTile: @unchecked Sendable {
    let coordinate: ZoomTileCoordinate
    let pixelRect: CGRect
    let image: CGImage
}

/// Bounded source-region renderer used only by Gallery 100% mode.
///
/// Core Image keeps the source lazy. The operation queue limits expensive RAW
/// work to two tiles at a time, and the LRU stores at most 128 MiB of decoded
/// tile pixels. Requests for the same file/tile are coalesced.
final class HighResolutionImagePipeline: @unchecked Sendable {
    static let shared = HighResolutionImagePipeline()
    static let tilePixelSize = 1024
    static let tileCacheCostLimit = 128 * 1024 * 1024

    private struct TileKey: Hashable {
        let sourceKey: String
        let coordinate: ZoomTileCoordinate
        let showsClippingWarnings: Bool
    }

    private final class PendingSource {
        var waiters: [UUID: CheckedContinuation<ZoomImageSource?, Never>]
        let operation: BlockOperation
        let readAccess: MediaOperationReadAccess

        init(
            waiters: [UUID: CheckedContinuation<ZoomImageSource?, Never>],
            operation: BlockOperation,
            readAccess: MediaOperationReadAccess
        ) {
            self.waiters = waiters
            self.operation = operation
            self.readAccess = readAccess
        }
    }

    private final class PendingTile {
        var waiters: [CheckedContinuation<ZoomImageTile?, Never>]
        let operation: BlockOperation
        let readAccess: MediaOperationReadAccess

        init(
            waiters: [CheckedContinuation<ZoomImageTile?, Never>],
            operation: BlockOperation,
            readAccess: MediaOperationReadAccess
        ) {
            self.waiters = waiters
            self.operation = operation
            self.readAccess = readAccess
        }
    }

    private struct TileCacheEntry {
        let tile: ZoomImageTile
        let cost: Int
        var lastAccess: UInt64
    }

    private let renderQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.decode.actual-size"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let context = CIContext()
    /// Core Image's GPU service can be unavailable in restricted tests or
    /// after a transient graphics-process failure. The CPU context is a
    /// deterministic fallback rather than leaving 100% view blurry.
    private let softwareContext = CIContext(
        options: [.useSoftwareRenderer: true]
    )
    private let outputColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var sourceCache: [String: ZoomImageSource] = [:]
    private var sourceCacheOrder: [String] = []
    private var sourceInFlight: [String: PendingSource] = [:]
    private var tileCache: [TileKey: TileCacheEntry] = [:]
    private var tileCacheCost = 0
    private var tileAccessCounter: UInt64 = 0
    private var tileInFlight: [TileKey: PendingTile] = [:]
    private let testingSource: (@Sendable (MediaSourceRevision, String, AppleRawDecoder) -> ZoomImageSource?)?

    private let testingTile: (@Sendable (ZoomImageSource, ZoomTileCoordinate) -> ZoomImageTile?)?

    private init() { testingSource = nil; testingTile = nil }

    /// Fault-injected source construction still passes through revision checks,
    /// waiter ownership and the real operation queue (shared with tile work).
    init(
        testingSourceConcurrency: Int,
        tileRenderer: (@Sendable (ZoomImageSource, ZoomTileCoordinate) -> ZoomImageTile?)? = nil,
        source: @escaping @Sendable (MediaSourceRevision, String, AppleRawDecoder) -> ZoomImageSource?
    ) {
        testingSource = source
        testingTile = tileRenderer
        renderQueue.maxConcurrentOperationCount = max(1, testingSourceConcurrency)
    }

    func source(for item: PhotoItem, decoder: AppleRawDecoder = .appleDefault, sourceAccess: MediaReadAccess? = nil) async -> ZoomImageSource? {
        let result = await source(
            for: item,
            decoder: decoder,
            qualityOfService: .userInitiated,
            queuePriority: .veryHigh,
            sourceAccess: sourceAccess
        )
        // A reconnect may provide a fresh exact grant for the same revision.
        // Rewrap immutably; existing readers retain their original authority.
        return result?.retainingSourceAccess(sourceAccess)
    }

    private func source(
        for item: PhotoItem,
        decoder: AppleRawDecoder,
        qualityOfService: QualityOfService,
        queuePriority: Operation.QueuePriority,
        sourceAccess: MediaReadAccess?
    ) async -> ZoomImageSource? {
        guard !Task.isCancelled else { return nil }
        let key = Self.sourceKey(for: item, decoder: decoder)
        let revision = MediaSourceRevision(item)
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = sourceCache[key] {
                    let cached = cached.retainingSourceAccess(sourceAccess)
                    sourceCache[key] = cached
                    touchSource(key)
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                if let pending = sourceInFlight[key] {
                    pending.readAccess.retainIfNeeded(sourceAccess)
                    pending.waiters[waiterID] = continuation
                    if queuePriority == .veryHigh {
                        pending.operation.queuePriority = .veryHigh
                        pending.operation.qualityOfService = .userInitiated
                    }
                    lock.unlock()
                    return
                }

                let readAccess = MediaOperationReadAccess(sourceAccess)
                let operation = BlockOperation()
                operation.completionBlock = { readAccess.finish() }
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { return }
                    defer { readAccess.finish() }
                    let source = autoreleasepool {
                        revision.read {
                            if let testingSource = self.testingSource {
                                return testingSource(revision, key, decoder)
                            }
                            return self.makeSource(revision: revision, key: key, decoder: decoder)
                        }
                    }
                    self.finishSource(key: key, operation: operation, source: source)
                }
                operation.qualityOfService = qualityOfService
                operation.queuePriority = queuePriority
                sourceInFlight[key] = PendingSource(waiters: [waiterID: continuation], operation: operation, readAccess: readAccess)
                lock.unlock()
                renderQueue.addOperation(operation)
            }
        } onCancel: { [weak self] in
            self?.cancelSourceWaiter(waiterID, key: key)
        }
    }

    /// Retain and replace this handle with the session's neighbour window.
    /// Four recipes match the existing source cache; each child owns one waiter.
    @discardableResult
    func prefetchSources(items: [PhotoItem], decoder: AppleRawDecoder = AppleRawDecoder.load(), sourceAccess: MediaReadAccess? = nil) -> Task<Void, Never> {
        guard !Task.isCancelled else { return Task {} }
        var keys = Set<String>()
        var neighbours: [PhotoItem] = []
        for item in items where item.mediaKind == .photo && item.isSupported {
            guard keys.insert(Self.sourceKey(for: item, decoder: decoder)).inserted else { continue }
            neighbours.append(item)
            if neighbours.count == ImagePipeline.neighbourPrefetchLimit { break }
        }
        return Task.detached(priority: .utility) { [self, neighbours] in
            await withTaskGroup(of: Void.self) { group in
                for item in neighbours {
                    guard !Task.isCancelled else { break }
                    group.addTask { [self] in
                        _ = await source(for: item, decoder: decoder, qualityOfService: .utility, queuePriority: .low, sourceAccess: sourceAccess)
                    }
                }
            }
        }
    }

    private func cancelSourceWaiter(_ waiterID: UUID, key: String) {
        lock.lock()
        guard let pending = sourceInFlight[key], let waiter = pending.waiters.removeValue(forKey: waiterID) else {
            lock.unlock()
            return
        }
        if pending.waiters.isEmpty {
            sourceInFlight.removeValue(forKey: key)
            // Cancellation cannot release a running synchronous recipe's lane.
            pending.operation.cancel()
        }
        lock.unlock()
        waiter.resume(returning: nil)
    }

    #if DEBUG
    func sourceWaiterCountForTesting(for item: PhotoItem, decoder: AppleRawDecoder = .appleDefault) -> Int {
        withStateLock { sourceInFlight[Self.sourceKey(for: item, decoder: decoder)]?.waiters.count ?? 0 }
    }

    func sourceIsCachedForTesting(for item: PhotoItem, decoder: AppleRawDecoder = .appleDefault) -> Bool {
        withStateLock { sourceCache[Self.sourceKey(for: item, decoder: decoder)] != nil }
    }

    func waitForSourceWorkForTesting() async {
        await withCheckedContinuation { continuation in
            let barrier = BlockOperation { continuation.resume() }
            for operation in renderQueue.operations { barrier.addDependency(operation) }
            renderQueue.addOperation(barrier)
        }
    }
    #endif

    func tile(
        for source: ZoomImageSource,
        coordinate: ZoomTileCoordinate,
        showsClippingWarnings: Bool = false
    ) async -> ZoomImageTile? {
        guard coordinate.pixelRect(sourceSize: source.pixelSize) != nil else {
            return nil
        }
        let key = TileKey(
            sourceKey: source.key,
            coordinate: coordinate,
            showsClippingWarnings: showsClippingWarnings
        )
        return await withCheckedContinuation { continuation in
            lock.lock()
            if var cached = tileCache[key] {
                tileAccessCounter &+= 1
                cached.lastAccess = tileAccessCounter
                tileCache[key] = cached
                lock.unlock()
                continuation.resume(returning: cached.tile)
                return
            }
            if let pending = tileInFlight[key] {
                pending.readAccess.retainIfNeeded(source.sourceAccess)
                pending.waiters.append(continuation)
                pending.operation.queuePriority = .veryHigh
                lock.unlock()
                return
            }

            let readAccess = MediaOperationReadAccess(source.sourceAccess)
            let operation = BlockOperation()
            operation.completionBlock = { readAccess.finish() }
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, let operation, !operation.isCancelled else { return }
                defer { readAccess.finish() }
                let tile = autoreleasepool {
                    self.validatedTile(
                        source: source,
                        coordinate: coordinate,
                        showsClippingWarnings: showsClippingWarnings
                    )
                }
                self.finishTile(key: key, operation: operation, tile: tile)
            }
            operation.qualityOfService = .userInitiated
            operation.queuePriority = .veryHigh
            tileInFlight[key] = PendingTile(
                waiters: [continuation],
                operation: operation,
                readAccess: readAccess
            )
            lock.unlock()
            renderQueue.addOperation(operation)
        }
    }

    /// Cancels queued work the current viewport no longer needs. A tile that
    /// is already inside Core Image may finish, but its removed request has no
    /// waiter and cannot be displayed over a newer photo.
    func retainTileRequests(
        sourceKey: String,
        coordinates: Set<ZoomTileCoordinate>,
        showsClippingWarnings: Bool = false
    ) {
        cancelTileRequests { key in
            key.sourceKey != sourceKey
                || key.showsClippingWarnings != showsClippingWarnings
                || !coordinates.contains(key.coordinate)
        }
    }

    func cancelTileRequests(exceptSourceKey sourceKey: String?) {
        cancelTileRequests { key in
            sourceKey == nil || key.sourceKey != sourceKey
        }
    }

    var cachedTileCost: Int {
        withStateLock { tileCacheCost }
    }

    var cachedTileCount: Int {
        withStateLock { tileCache.count }
    }

    func removeAllTiles() {
        withStateLock {
            tileCache.removeAll(keepingCapacity: false)
            tileCacheCost = 0
        }
        context.clearCaches()
        softwareContext.clearCaches()
    }

    static func sourceKey(for item: PhotoItem, decoder: AppleRawDecoder) -> String {
        let key = ImagePipeline.cacheKey(for: item)
        return item.isRaw ? "\(key)|apple-raw-source-v2|\(decoder.rawValue)" : key
    }

    private func makeSource(revision: MediaSourceRevision, key: String, decoder: AppleRawDecoder) -> ZoomImageSource? {
        let url = revision.url
        let ext = url.pathExtension.lowercased()
        let original: CIImage?
        if FolderScanner.rawExtensions.contains(ext) {
            original = RawImageRendering.image(url: url, decoder: decoder)
        } else {
            original = CIImage(
                contentsOf: url,
                options: [.applyOrientationProperty: true]
            )
        }
        guard let original else { return nil }
        let extent = original.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        let normalized = original.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        return ZoomImageSource(
            key: key,
            image: normalized,
            pixelSize: extent.size,
            sourceRevision: revision,
            decoder: FolderScanner.rawExtensions.contains(ext) ? decoder : .appleDefault
        )
    }

    private func validatedTile(
        source: ZoomImageSource,
        coordinate: ZoomTileCoordinate,
        showsClippingWarnings: Bool
    ) -> ZoomImageTile? {
        // A cached CIImage recipe can open the URL lazily on its first render.
        // Validate each new tile, not just the original recipe construction.
        let render = {
            if let testingTile = self.testingTile { return testingTile(source, coordinate) }
            return self.renderTile(source: source, coordinate: coordinate,
                                   showsClippingWarnings: showsClippingWarnings)
        }
        if let revision = source.sourceRevision { return revision.read(render) }
        return render()
    }

    private func renderTile(
        source: ZoomImageSource,
        coordinate: ZoomTileCoordinate,
        showsClippingWarnings: Bool
    ) -> ZoomImageTile? {
        guard let topLeftRect = coordinate.pixelRect(
            sourceSize: source.pixelSize
        ) else { return nil }
        // Core Image uses a lower-left origin; the document view and retained
        // viewport use a photographer-friendly upper-left origin.
        let coreImageRect = CGRect(
            x: topLeftRect.minX,
            y: source.pixelSize.height - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        guard let rendered =
                context.createCGImage(
                    source.image,
                    from: coreImageRect,
                    format: .RGBA8,
                    colorSpace: outputColorSpace
                )
                ?? (source.decoder == .appleDefault ? softwareContext.createCGImage(
                    source.image,
                    from: coreImageRect,
                    format: .RGBA8,
                    colorSpace: outputColorSpace
                ) : nil)
        else { return nil }
        let image: CGImage
        if showsClippingWarnings {
            guard let warned =
                    ClippingWarningProcessor.overlay(on: rendered)
            else { return nil }
            image = warned
        } else {
            image = rendered
        }
        return ZoomImageTile(
            coordinate: coordinate,
            pixelRect: topLeftRect,
            image: image
        )
    }

    private func finishSource(
        key: String,
        operation: BlockOperation,
        source: ZoomImageSource?
    ) {
        lock.lock()
        guard let pending = sourceInFlight[key], pending.operation === operation else {
            lock.unlock()
            return
        }
        sourceInFlight.removeValue(forKey: key)
        let source = source?.retainingSourceAccess(pending.readAccess.sourceAccess)
        if let source, !operation.isCancelled {
            sourceCache[key] = source
            touchSource(key)
            while sourceCacheOrder.count > 4 {
                let removed = sourceCacheOrder.removeFirst()
                sourceCache.removeValue(forKey: removed)
            }
        }
        let waiters = Array(pending.waiters.values)
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: source)
        }
    }

    private func finishTile(
        key: TileKey,
        operation: BlockOperation,
        tile: ZoomImageTile?
    ) {
        lock.lock()
        guard let pending = tileInFlight[key], pending.operation === operation else {
            lock.unlock()
            return
        }
        tileInFlight.removeValue(forKey: key)
        if let tile, !operation.isCancelled {
            tileAccessCounter &+= 1
            let cost = tile.image.bytesPerRow * tile.image.height
            tileCache[key] = TileCacheEntry(
                tile: tile,
                cost: cost,
                lastAccess: tileAccessCounter
            )
            tileCacheCost += cost
            evictTilesIfNeeded()
        }
        let waiters = pending.waiters
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: tile)
        }
    }

    private func touchSource(_ key: String) {
        sourceCacheOrder.removeAll { $0 == key }
        sourceCacheOrder.append(key)
    }

    private func evictTilesIfNeeded() {
        while tileCacheCost > Self.tileCacheCostLimit,
              let oldest = tileCache.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              }) {
            tileCacheCost -= oldest.value.cost
            tileCache.removeValue(forKey: oldest.key)
        }
    }

    private func cancelTileRequests(
        matching shouldCancel: (TileKey) -> Bool
    ) {
        lock.lock()
        let keys = tileInFlight.keys.filter(shouldCancel)
        let cancelled = keys.compactMap { key -> PendingTile? in
            let pending = tileInFlight.removeValue(forKey: key)
            pending?.operation.cancel()
            return pending
        }
        lock.unlock()
        for pending in cancelled {
            for waiter in pending.waiters {
                waiter.resume(returning: nil)
            }
        }
    }

    private func withStateLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
