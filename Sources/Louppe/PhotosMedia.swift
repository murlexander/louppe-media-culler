import AppKit
import Photos
import Combine

/// Identity and media access exist before any local original does. The URL on
/// PhotoFile is only a stable display/cache key until an original lease exists.
struct PhotosMediaReference: Sendable {
    let assetID: String
    let session: PhotosMediaSession
}

struct PhotosReviewImage: @unchecked Sendable {
    let image: NSImage
    let pixels: CGSize
    var cost: Int { Int(pixels.width) * Int(pixels.height) * 4 }
}

enum PhotosRepresentationError: LocalizedError {
    case cloud, unavailable, busy, retired
    var errorDescription: String? {
        switch self {
        case .cloud: return L10n.text("Review image is in iCloud. Allow review downloads or retry when online.")
        case .unavailable: return L10n.text("Photos couldn't provide this review image. Check access or retry.")
        case .busy: return L10n.text("Photos is busy. Retry this item.")
        case .retired: return L10n.text("This Photos selection is closed. Open it again.")
        }
    }
}

/// Injectable PhotoKit boundary. No implementation may edit the library.
protocol PhotosMediaProvider: Sendable {
    func image(assetID: String, pixels: Int, network: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PhotosReviewImage
    func original(assetID: String, destination: URL, maximumBytes: Int64, network: Bool,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> Int64
    /// Resource metadata is resolved only on an explicit original request.
    func originalFilename(assetID: String) async throws -> String?
    func preheat(assetIDs: [String]) async
    func stop() async
}

extension PhotosMediaProvider {
    func originalFilename(assetID: String) async throws -> String? { nil }
}

/// Cancellation-aware admission, including a bounded pending queue. A cancelled
/// executing worker owns its lane until it exits; queued work never calls PhotoKit.
actor PhotosRequestGate {
    private let limit: Int
    private let pendingLimit: Int
    private var running = 0
    private var pending: [(UUID, CheckedContinuation<Void, any Error>)] = []
    init(limit: Int, pendingLimit: Int) { self.limit = limit; self.pendingLimit = pendingLimit }
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit { running += 1; return }
        guard pending.count < pendingLimit else { throw PhotosRepresentationError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append((id, continuation))
            }
            if Task.isCancelled { release(); throw CancellationError() }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if pending.isEmpty { running -= 1 }
        else { pending.removeFirst().1.resume() }
    }
}

/// The file remains owned while a renderer or Copy worker holds this lease.
/// Review pixels never enter the original-file path.
final class PhotosOriginalLease: @unchecked Sendable {
    let item: PhotoItem
    private let cleanup: @Sendable () async -> Void
    private let lock = NSLock()
    private var closed = false
    init(item: PhotoItem, cleanup: @escaping @Sendable () async -> Void) {
        self.item = item; self.cleanup = cleanup
    }
    func close() async {
        if lock.withLock({ if closed { return false }; closed = true; return true }) { await cleanup() }
    }
    func preserveForRecovery() { lock.withLock { closed = true } }
    deinit {
        if !closed { let cleanup = cleanup; Task { await cleanup() } }
    }
}

@MainActor
final class PhotosMediaAccess: ObservableObject {
    @Published private(set) var generation: UInt64 = 0
    nonisolated init() {}
    func changed() { generation &+= 1 }
}

actor PhotosMediaSession {
    nonisolated let access = PhotosMediaAccess()
    static let memoryLimit = 96 * 1024 * 1024
    static let thumbnailPixels = 384
    static let maximumPreviewPixels = 2048
    let id = UUID()
    private let provider: any PhotosMediaProvider
    nonisolated let folder: URL
    private let imageGate = PhotosRequestGate(limit: 4, pendingLimit: 64)
    private let originalGate = PhotosRequestGate(limit: 1, pendingLimit: 8)
    private var stopped = false
    private var imageNetwork: Bool
    private var originalNetwork = false
    private var cancellation: [UUID: @Sendable () -> Void] = [:]
    private struct ImageKey: Hashable { let assetID: String; let pixels: Int }
    private var cache: [ImageKey: (PhotosReviewImage, UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var cachedBytes = 0
    private(set) var originalBytes: Int64 = 0

    init(provider: any PhotosMediaProvider, folder: URL, allowNetwork: Bool = false) {
        self.provider = provider; self.folder = folder; self.imageNetwork = allowNetwork
    }
    func setImageNetwork(_ allowed: Bool) async {
        if allowed && !imageNetwork {
            // A local low-quality fallback must not mask a newly authorized
            // request for a larger representation.
            let keys = cache.compactMap { key, value in
                max(value.0.pixels.width, value.0.pixels.height) < CGFloat(key.pixels) ? key : nil
            }
            for key in keys { if let value = cache.removeValue(forKey: key) { cachedBytes -= value.0.cost } }
        }
        imageNetwork = allowed
        await access.changed()
    }
    func setOriginalNetwork(_ allowed: Bool) async {
        originalNetwork = allowed
        await access.changed()
    }

    func image(assetID: String, pixels: Int,
               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> PhotosReviewImage {
        guard !stopped else { throw PhotosRepresentationError.retired }
        try Task.checkCancellation()
        let size = pixels <= Self.thumbnailPixels ? Self.thumbnailPixels
            : min(Self.maximumPreviewPixels, max(512, ((pixels + 255) / 256) * 256))
        let key = ImageKey(assetID: assetID, pixels: size)
        clock &+= 1
        if let hit = cache[key] { cache[key] = (hit.0, clock); return hit.0 }
        // A realized view owns each waiter; cancellation doesn't cancel other
        // views of the same item. The small gate bounds even rapid scrolling.
        guard cancellation.count < 76 else { throw PhotosRepresentationError.busy }
        let token = UUID(), network = imageNetwork
        let task = Task { [provider, imageGate] in
            try await imageGate.acquire()
            do {
                let value = try await provider.image(assetID: assetID, pixels: size, network: network, progress: progress)
                try Task.checkCancellation()
                await imageGate.release()
                return value
            } catch { await imageGate.release(); throw error }
        }
        cancellation[token] = { task.cancel() }
        defer { cancellation[token] = nil }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !stopped else { throw PhotosRepresentationError.retired }
        try Task.checkCancellation()
        guard value.cost <= Self.memoryLimit else { throw PhotosRepresentationError.unavailable }
        if let previous = cache.removeValue(forKey: key) { cachedBytes -= previous.0.cost }
        while cachedBytes + value.cost > Self.memoryLimit, let oldest = cache.min(by: { $0.value.1 < $1.value.1 }) {
            cachedBytes -= oldest.value.0.cost; cache[oldest.key] = nil
        }
        clock &+= 1
        cache[key] = (value, clock); cachedBytes += value.cost
        return value
    }

    /// Preheat is always local-only and limited to eight thumbnails, regardless
    /// of the selection size or representation-network choice.
    func preheat(assetIDs: [String]) async {
        guard !stopped else { return }
        await provider.preheat(assetIDs: Array(assetIDs.prefix(8)))
    }

    func original(for item: PhotoItem,
                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> PhotosOriginalLease {
        guard !stopped, let reference = item.primaryFile.photosMedia else { throw PhotosRepresentationError.retired }
        guard cancellation.count < 76 else { throw PhotosRepresentationError.busy }
        let token = UUID(), network = originalNetwork
        let task = Task { [originalGate] in
            try await originalGate.acquire()
            do {
                let value = try await self.stageOriginal(item, assetID: reference.assetID, network: network, progress: progress)
                await originalGate.release()
                return value
            } catch { await originalGate.release(); throw error }
        }
        cancellation[token] = { task.cancel() }
        defer { cancellation[token] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func stageOriginal(_ item: PhotoItem, assetID: String, network: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> PhotosOriginalLease {
        try Task.checkCancellation()
        guard !stopped else { throw PhotosRepresentationError.retired }
        let directory = folder.appendingPathComponent("Originals/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let filename = try await provider.originalFilename(assetID: assetID) ?? item.displayName
            try Task.checkCancellation()
            guard !stopped else { throw PhotosRepresentationError.retired }
            // A provider cannot redirect staging outside its private directory.
            guard !filename.isEmpty, filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\0") else {
                throw PhotosRepresentationError.unavailable
            }
            let url = directory.appendingPathComponent(filename)
            let bytes = try await provider.original(assetID: assetID, destination: url,
                maximumBytes: PhotosLibraryService.maximumBatchBytes - originalBytes,
                network: network, progress: progress)
            try Task.checkCancellation()
            guard !stopped else { throw PhotosRepresentationError.retired }
            let identity = try FileOperationJournal.captureIdentity(at: url)
            let metadata = item.primaryFile.metadataSnapshot
            let file = PhotoFile(id: item.id, url: url, displayRelativePath: filename,
                captureDate: item.captureDate, captureDateEvidence: item.captureDateEvidence,
                cameraModel: nil, lensModel: nil, mediaKind: item.mediaKind, duration: item.duration,
                videoIsPlayable: item.isVideo, fileSize: bytes, scannedIdentity: identity,
                rating: metadata.rating, ratedAt: metadata.ratedAt, starRating: metadata.starRating,
                starsChangedAt: metadata.starsChangedAt, colorLabel: metadata.colorLabel, colorChangedAt: metadata.colorChangedAt)
            originalBytes += bytes
            return PhotosOriginalLease(item: PhotoItem(primaryFile: file, pairedFile: nil)) { [weak self] in
                await self?.releaseOriginal(directory: directory, bytes: bytes)
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private func releaseOriginal(directory: URL, bytes: Int64) {
        do { try FileManager.default.removeItem(at: directory); originalBytes -= bytes }
        catch { /* Keep bytes charged if disposable cleanup failed. */ }
    }
    func stop() async {
        stopped = true
        for cancel in cancellation.values { cancel() }
        cache.removeAll(); cachedBytes = 0
        await provider.stop()
    }
}

/// PhotoKit owns the lazy, immutable fetch cache. Louppe retains only an ID →
/// index map and resolves assets from that exact snapshot as views request them.
final class ApplePhotosMediaProvider: PhotosMediaProvider, @unchecked Sendable {
    private let inventory: ApplePhotosReviewInventory
    private let indicesByAssetID: [String: Int]
    private let manager = PHCachingImageManager()
    init(inventory: ApplePhotosReviewInventory, indicesByAssetID: [String: Int]) {
        self.inventory = inventory
        self.indicesByAssetID = indicesByAssetID
        manager.allowsCachingHighQualityImages = false
    }
    private func asset(_ assetID: String) throws -> PHAsset {
        guard let index = indicesByAssetID[assetID] else { throw PhotosLibraryError.staleSelection }
        return try inventory.asset(at: index, expectedID: assetID)
    }
    static func options(network: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.version = .unadjusted
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = network
        return options
    }
    func image(assetID: String, pixels: Int, network: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PhotosReviewImage {
        try authorize()
        let asset = try asset(assetID)
        let image = try await reviewImage(asset: asset, pixels: pixels, network: network, progress: progress)
        // PhotoKit may return a larger cached image. Normalize before admitting
        // it to our explicitly byte-bounded cache.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PhotosRepresentationError.unavailable
        }
        let scale = min(1, Double(pixels) / Double(max(cg.width, cg.height)))
        let width = max(1, Int(Double(cg.width) * scale)), height = max(1, Int(Double(cg.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PhotosRepresentationError.unavailable
        }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bounded = context.makeImage() else { throw PhotosRepresentationError.unavailable }
        return PhotosReviewImage(image: NSImage(cgImage: bounded, size: .zero), pixels: CGSize(width: width, height: height))
    }
    private func reviewImage(asset: PHAsset, pixels: Int, network: Bool,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> NSImage {
        do {
            // Always consult on-device representations before using consent.
            return try await request(asset: asset, pixels: pixels, network: false, progress: progress)
        } catch {
            try Task.checkCancellation()
            let localFailure = error
            if network {
                do { return try await request(asset: asset, pixels: pixels, network: true, progress: progress) }
                catch {
                    try Task.checkCancellation()
                    let networkFailure = error
                    do { return try await request(asset: asset, pixels: pixels, network: false, fast: true, progress: progress) }
                    catch { try Task.checkCancellation(); throw networkFailure }
                }
            }
            do { return try await request(asset: asset, pixels: pixels, network: false, fast: true, progress: progress) }
            catch { try Task.checkCancellation(); throw localFailure }
        }
    }

    private func request(asset: PHAsset, pixels: Int, network: Bool, fast: Bool = false,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> NSImage {
        let options = Self.options(network: network)
        if fast { options.deliveryMode = .fastFormat }
        options.progressHandler = { fraction, _, _, _ in progress(fraction) }
        let request = PhotosImageRequest(cancel: { [manager] in manager.cancelImageRequest($0) })
        return try await request.read(acceptDegraded: fast) { [manager] result in
            manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                contentMode: .aspectFit, options: options, resultHandler: result)
        }
    }

    func original(assetID: String, destination: URL, maximumBytes: Int64, network: Bool,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        try authorize()
        try Task.checkCancellation()
        let resource = try originalResource(assetID: assetID)
        let transfer = try PhotosResourceTransfer(destination: destination, maximumBytes: maximumBytes)
        return try await transfer.read(resource: resource, allowNetwork: network, progress: progress)
    }
    func originalFilename(assetID: String) async throws -> String? {
        try authorize()
        try Task.checkCancellation()
        let resource = try originalResource(assetID: assetID)
        return PhotosLibraryService.safeFilename(resource.originalFilename, type: resource.uniformTypeIdentifier)
    }
    private func originalResource(assetID: String) throws -> PHAssetResource {
        let asset = try asset(assetID)
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
            $0.type == (asset.mediaType == .video ? .video : .photo)
        }) else { throw PhotosLibraryError.noResource(assetID) }
        return resource
    }
    func preheat(assetIDs: [String]) async {
        guard !Task.isCancelled else { return }
        manager.stopCachingImagesForAllAssets()
        let options = Self.options(network: false)
        manager.startCachingImages(for: assetIDs.prefix(8).compactMap { try? asset($0) },
            targetSize: CGSize(width: PhotosMediaSession.thumbnailPixels, height: PhotosMediaSession.thumbnailPixels),
            contentMode: .aspectFit, options: options)
    }
    func stop() async { manager.stopCachingImagesForAllAssets() }
    private func authorize() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotosLibraryError.permissionDenied }
    }
}

/// Handles synchronous first callbacks and cancellation before ID assignment.
/// A cancellation resumes independently: PhotoKit need not callback on cancel.
final class PhotosImageRequest: @unchecked Sendable {
    typealias Reply = @Sendable (NSImage?, [AnyHashable: Any]?) -> Void
    typealias Start = (@escaping Reply) -> PHImageRequestID
    private let lock = NSLock()
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void
    private var id: PHImageRequestID?
    private var continuation: CheckedContinuation<NSImage, any Error>?
    private var cancelled = false
    private var finished = false
    init(cancel: @escaping @Sendable (PHImageRequestID) -> Void) { cancelRequest = cancel }
    func read(acceptDegraded: Bool = false, start: Start) async throws -> NSImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock { self.continuation = continuation; return !cancelled }
                guard shouldStart else { finish(.failure(CancellationError())); return }
                let id = start { [self] image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { finish(.failure(CancellationError())) }
                    else if let error = info?[PHImageErrorKey] as? any Error {
                        let failure = error as NSError
                        if failure.domain == PHPhotosErrorDomain,
                           failure.code == PHPhotosError.Code.networkAccessRequired.rawValue {
                            finish(.failure(PhotosRepresentationError.cloud))
                        } else { finish(.failure(error)) }
                    }
                    else if (info?[PHImageResultIsDegradedKey] as? Bool) == true && !acceptDegraded { return }
                    else if let image { finish(.success(image)) }
                    else if (info?[PHImageResultIsInCloudKey] as? Bool) == true { finish(.failure(PhotosRepresentationError.cloud)) }
                    else { finish(.failure(PhotosRepresentationError.unavailable)) }
                }
                let cancel = lock.withLock { self.id = id; return cancelled }
                if cancel { cancelRequest(id) }
            }
        } onCancel: { cancel() }
    }
    private func finish(_ result: Result<NSImage, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<NSImage, any Error>? in
            guard !finished, let continuation else { return nil }
            finished = true; self.continuation = nil; return continuation
        }
        continuation?.resume(with: result)
    }
    private func cancel() {
        let id = lock.withLock { cancelled = true; return id }
        if let id { cancelRequest(id) }
        finish(.failure(CancellationError()))
    }
}

/// Values available without image, original, EXIF, or resource inspection.
struct PhotosReviewAsset: Sendable {
    let id: String
    let filename: String
    let captureDate: Date?
    var modificationDate: Date? = nil
    var mediaKind: MediaKind = .photo
    var duration: TimeInterval? = nil
}

/// Synchronous metadata access keeps preparation serial and cancellable without
/// creating one task per asset. The service invokes it off the main actor.
protocol PhotosReviewInventory: Sendable {
    var count: Int { get }
    func reviewAsset(at index: Int) throws -> PhotosReviewAsset
}

final class ApplePhotosReviewInventory: PhotosReviewInventory, @unchecked Sendable {
    private let result: PHFetchResult<PHAsset>
    private let photoLabel = L10n.text("Photo")
    private let videoLabel = L10n.text("Video")
    var count: Int { result.count }
    init(result: PHFetchResult<PHAsset>) { self.result = result }

    func asset(at index: Int, expectedID: String) throws -> PHAsset {
        guard (0..<count).contains(index) else { throw PhotosLibraryError.staleSelection }
        let asset = result.object(at: index)
        guard asset.localIdentifier == expectedID else { throw PhotosLibraryError.staleSelection }
        return asset
    }

    func reviewAsset(at index: Int) throws -> PhotosReviewAsset {
        guard (0..<count).contains(index) else { throw PhotosLibraryError.staleSelection }
        return autoreleasepool {
            let asset = result.object(at: index)
            let video = asset.mediaType == .video
            // PHAsset has no public filename. Do not inspect 80,000 resources
            // just to label review items, or invent a codec/RAW extension. The
            // primary original's real name is resolved for detail/playback/Copy.
            let name = video ? videoLabel : photoLabel
            return PhotosReviewAsset(id: asset.localIdentifier, filename: "\(name) \(index + 1)",
                captureDate: asset.creationDate, modificationDate: asset.modificationDate,
                mediaKind: video ? .video : .photo, duration: video ? asset.duration : nil)
        }
    }
}

struct PhotosReviewMembership: Sendable {
    let assets: [PhotosReviewAsset]
    let indicesByAssetID: [String: Int]

    static func read(inventory: any PhotosReviewInventory, range: PhotosBatchRange,
                     recorder: PhotosBatchProgressRecorder) throws -> PhotosReviewMembership {
        try Task.checkCancellation()
        guard inventory.count == range.total else { throw PhotosLibraryError.staleSelection }
        var assets: [PhotosReviewAsset] = []
        var indices: [String: Int] = [:]
        assets.reserveCapacity(range.indices.count)
        indices.reserveCapacity(range.indices.count)
        for index in range.indices {
            try Task.checkCancellation()
            let asset = try inventory.reviewAsset(at: index)
            guard indices.updateValue(index, forKey: asset.id) == nil else { throw PhotosLibraryError.staleSelection }
            assets.append(asset)
            if assets.count.isMultiple(of: 128) {
                recorder.update(PhotosBatchProgress(completed: assets.count, total: range.indices.count, downloadFraction: 0))
            }
        }
        try Task.checkCancellation()
        return PhotosReviewMembership(assets: assets, indicesByAssetID: indices)
    }
}

extension PhotosReviewBatch {
    /// Production path checks both metadata enumeration and item projection;
    /// cancellation can never publish a partial or late complete inventory.
    static func prepared(folder: URL, snapshot: PhotosLibrarySnapshot, range: PhotosBatchRange,
                         assets: [PhotosReviewAsset], decisions: [String: PhotosReviewDecision],
                         mediaSession: PhotosMediaSession) throws -> PhotosReviewBatch {
        try Task.checkCancellation()
        guard snapshot.count == range.total, assets.count == range.indices.count else { throw PhotosLibraryError.staleSelection }
        var builder = PhotosReviewBatchBuilder(folder: folder, decisions: decisions, mediaSession: mediaSession, capacity: assets.count)
        for asset in assets {
            try Task.checkCancellation()
            autoreleasepool { builder.append(asset) }
        }
        try Task.checkCancellation()
        return builder.finish(snapshot: snapshot, range: range)
    }

    /// Compatibility for existing in-memory fixtures.
    static func lazy(folder: URL, snapshot: PhotosLibrarySnapshot, range: PhotosBatchRange,
                     assets: [PhotosReviewAsset], decisions: [String: PhotosReviewDecision],
                     mediaSession: PhotosMediaSession) -> PhotosReviewBatch {
        var builder = PhotosReviewBatchBuilder(folder: folder, decisions: decisions, mediaSession: mediaSession, capacity: assets.count)
        for asset in assets { builder.append(asset) }
        return builder.finish(snapshot: snapshot, range: range)
    }
}

private struct PhotosReviewBatchBuilder {
    let folder: URL
    let decisions: [String: PhotosReviewDecision]
    let mediaSession: PhotosMediaSession
    private var mapping: [String: String] = [:]
    private var dates: [String: Date] = [:]
    private var selectedDecisions: [String: PhotosReviewDecision] = [:]
    private var items: [PhotoItem] = []

    init(folder: URL, decisions: [String: PhotosReviewDecision], mediaSession: PhotosMediaSession, capacity: Int) {
        self.folder = folder; self.decisions = decisions; self.mediaSession = mediaSession
        items.reserveCapacity(capacity)
        mapping.reserveCapacity(capacity)
        dates.reserveCapacity(capacity)
        selectedDecisions.reserveCapacity(min(capacity, decisions.count))
    }
    mutating func append(_ asset: PhotosReviewAsset) {
        let url = folder.appendingPathComponent(String(items.count + 1)).appendingPathComponent(asset.filename)
        mapping[url.path] = asset.id
        if let date = asset.captureDate { dates[url.path] = date }
        if let decision = decisions[asset.id] { selectedDecisions[asset.id] = decision }
        let metadata = decisions[asset.id]?.metadata(fileID: asset.id)
        let file = PhotoFile(id: "photos:" + asset.id, url: url, displayRelativePath: asset.filename,
            captureDate: asset.captureDate,
            captureDateEvidence: asset.captureDate.map { CaptureDateEvidence(date: $0, source: .photosLibrary) },
            cameraModel: nil, lensModel: nil, mediaKind: asset.mediaKind, duration: asset.duration,
            modificationDate: asset.modificationDate, fileSize: 0, metadataIsLoaded: false,
            rating: metadata?.rating ?? .undecided, ratedAt: metadata?.ratedAt,
            starRating: metadata?.starRating, starsChangedAt: metadata?.starsChangedAt,
            colorLabel: metadata?.colorLabel, colorChangedAt: metadata?.colorChangedAt,
            photosMedia: PhotosMediaReference(assetID: asset.id, session: mediaSession))
        items.append(PhotoItem(primaryFile: file, pairedFile: nil))
    }
    func finish(snapshot: PhotosLibrarySnapshot, range: PhotosBatchRange) -> PhotosReviewBatch {
        return PhotosReviewBatch(folder: folder, snapshot: snapshot, range: range,
            assetIDsByPath: mapping, decisions: selectedDecisions,
            captureDatesByPath: dates, reviewItems: items, mediaSession: mediaSession)
    }
}
