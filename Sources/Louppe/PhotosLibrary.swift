import Foundation
import Photos
import UniformTypeIdentifiers
import Darwin
import OSLog

struct PhotosLibraryQuery: Codable, Equatable, Sendable {
    var albumID: String?
    var startDate: Date?
    /// Exclusive upper bound, so a calendar day's final fraction is included.
    var endDate: Date?
    var newestFirst = true
}

enum PhotosRecentDateRange: CaseIterable, Hashable {
    case lastWeek
    case lastSevenDays

    var title: String {
        switch self {
        case .lastWeek: return L10n.text("Last Week")
        case .lastSevenDays: return L10n.text("Last 7 Days")
        }
    }

    func interval(relativeTo date: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .lastWeek:
            guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: date),
                  let previousDay = calendar.date(byAdding: .day, value: -1, to: currentWeek.start) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: previousDay)
        case .lastSevenDays:
            let today = calendar.startOfDay(for: date)
            guard let start = calendar.date(byAdding: .day, value: -6, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}

struct PhotosLibraryAlbum: Identifiable, Sendable {
    let id: String
    let title: String
}

struct PhotosLibrarySnapshot: Sendable {
    let id: UUID
    let count: Int
    let title: String
    let query: PhotosLibraryQuery
}

struct PhotosBatchRange: Equatable, Sendable {
    static let sizes = [50, 100, 200, 500, 1_000]
    let start: Int
    let end: Int
    let total: Int
    let size: Int
    let isEntireSelection: Bool
    var page: Int { start / size }
    var pageCount: Int { total == 0 ? 0 : (total - 1) / size + 1 }
    var hasPrevious: Bool { start > 0 }
    var hasNext: Bool { end < total }

    init(total: Int, page: Int, size: Int) {
        isEntireSelection = false
        self.total = max(0, total)
        self.size = Self.sizes.contains(size) ? size : 100
        let last = self.total == 0 ? 0 : (self.total - 1) / self.size
        self.start = min(max(0, page), last) * self.size
        self.end = self.start + min(self.size, self.total - self.start)
    }
    init(entireSelection total: Int) {
        self.total = max(0, total)
        start = 0
        end = self.total
        size = max(1, self.total)
        isEntireSelection = true
    }
    var indices: Range<Int> { start..<end }
}

enum PhotosReviewSelection: Equatable, Sendable {
    case entireSelection
    /// Compatibility for existing callers; normal review always opens everything.
    case batch(page: Int, size: Int)

    func range(total: Int) -> PhotosBatchRange {
        switch self {
        case .entireSelection: return PhotosBatchRange(entireSelection: total)
        case .batch(let page, let size): return PhotosBatchRange(total: total, page: page, size: size)
        }
    }
}

struct PhotosBatchProgress: Sendable {
    let completed: Int
    let total: Int
    let downloadFraction: Double
}

/// Small coalesced slot: Photos callbacks never queue a UI task per data chunk.
final class PhotosBatchProgressRecorder: Sendable {
    private let state = NSLock()
    nonisolated(unsafe) private var value: PhotosBatchProgress?
    func update(_ value: PhotosBatchProgress) { state.withLock { self.value = value } }
    func take() -> PhotosBatchProgress? { state.withLock { defer { value = nil }; return value } }
}

struct PhotosReviewBatch: Sendable {
    let folder: URL
    let snapshot: PhotosLibrarySnapshot
    let range: PhotosBatchRange
    /// Exact exported path -> Photos local identifier. Filenames never own decisions.
    let assetIDsByPath: [String: String]
    let decisions: [String: PhotosReviewDecision]
    let captureDatesByPath: [String: Date]
    /// Complete membership, with no original or representation files required.
    var reviewItems: [PhotoItem]? = nil
    var mediaSession: PhotosMediaSession? = nil
}

enum PhotosLibraryError: LocalizedError {
    case permissionDenied, staleSelection, empty, noResource(String), batchTooLarge, iCloudDownloadRequired
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L10n.text("Allow Louppe to access Photos in System Settings → Privacy & Security → Photos, then retry.")
        case .staleSelection:
            return L10n.text("The Photos selection changed. Choose the library or album again.")
        case .empty:
            return L10n.text("No photos or videos match this selection.")
        case .noResource(let name):
            return L10n.text("Photos couldn't provide a file for “\(name)”. Check it in Photos, then retry.")
        case .iCloudDownloadRequired:
            return L10n.text("This original needs iCloud access. Allow original downloads, then retry this item.")
        case .batchTooLarge:
            return L10n.text("Original staging exceeds the 5 GB limit. Close original detail or choose a smaller item, then retry.")
        }
    }
}

protocol PhotosLibraryClient: Sendable {
    func authorize() async throws
    func albums() async throws -> [PhotosLibraryAlbum]
    func select(_ query: PhotosLibraryQuery) async throws -> PhotosLibrarySnapshot
    func prepare(snapshot: PhotosLibrarySnapshot, page: Int, size: Int, allowNetwork: Bool,
                 recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch
    func prepareSelection(snapshot: PhotosLibrarySnapshot, allowNetwork: Bool,
                          recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch
    func remove(_ batch: PhotosReviewBatch) async
}

extension PhotosLibraryClient {
    /// Older staged fixtures cannot safely implement full membership by passing
    /// an oversized batch size: that API intentionally clamps to 50–1,000.
    func prepareSelection(snapshot: PhotosLibrarySnapshot, allowNetwork: Bool,
                          recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        throw CocoaError(.featureUnsupported)
    }
}

/// Retain lazy PhotoKit snapshots and lightweight review membership. Never
/// retain a Swift array/dictionary of every PHAsset or inspect every resource.
actor PhotosLibraryService: PhotosLibraryClient {
    static let shared = PhotosLibraryService()
    static let maximumBatchBytes: Int64 = 5_000_000_000
    private static let logger = Logger(subsystem: "com.alexandermarkin.louppe", category: "PhotosOpening")
    private var result: PHFetchResult<PHAsset>?
    private var snapshotID: UUID?
    // Cache-folder ownership pins both the active and preparing snapshots.
    // A cancelled new selection cannot evict the outgoing review's snapshot.
    private var retainedSnapshots: [URL: (id: UUID, result: PHFetchResult<PHAsset>)] = [:]
    private let cacheRoot: URL
    private let decisionsStore: PhotosReviewDecisions
    private var retainedFolders: Set<URL> = []

    init(cacheRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.alexandermarkin.louppe/PhotosReview", isDirectory: true),
         decisionsStore: PhotosReviewDecisions = .shared) {
        self.cacheRoot = cacheRoot
        self.decisionsStore = decisionsStore
    }

    func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else { throw PhotosLibraryError.permissionDenied }
    }

    func albums() throws -> [PhotosLibraryAlbum] {
        try requireAuthorization()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var values: [PhotosLibraryAlbum] = []
        albums.enumerateObjects { collection, _, _ in
            values.append(PhotosLibraryAlbum(id: collection.localIdentifier,
                                            title: collection.localizedTitle ?? L10n.text("Album")))
        }
        return values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func select(_ query: PhotosLibraryQuery) throws -> PhotosLibrarySnapshot {
        try requireAuthorization()
        let options = PHFetchOptions()
        var predicates = [NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)]
        if let date = query.startDate { predicates.append(NSPredicate(format: "creationDate >= %@", date as NSDate)) }
        if let date = query.endDate { predicates.append(NSPredicate(format: "creationDate < %@", date as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !query.newestFirst)]
        options.wantsIncrementalChangeDetails = false
        var title = L10n.text("Apple Photos")
        if let id = query.albumID {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw PhotosLibraryError.staleSelection
            }
            result = PHAsset.fetchAssets(in: album, options: options)
            title = album.localizedTitle ?? title
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        let id = UUID()
        snapshotID = id
        return PhotosLibrarySnapshot(id: id, count: result?.count ?? 0, title: title, query: query)
    }

    func prepare(snapshot: PhotosLibrarySnapshot, page: Int, size: Int, allowNetwork: Bool,
                 recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        try await prepare(snapshot: snapshot, selection: .batch(page: page, size: size),
                          allowNetwork: allowNetwork, recorder: recorder)
    }

    func prepareSelection(snapshot: PhotosLibrarySnapshot, allowNetwork: Bool,
                          recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        try await prepare(snapshot: snapshot, selection: .entireSelection,
                          allowNetwork: allowNetwork, recorder: recorder)
    }

    private func prepare(snapshot: PhotosLibrarySnapshot, selection: PhotosReviewSelection,
                         allowNetwork: Bool, recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        let preparationStart = ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        try requireAuthorization()
        let selectedResult = snapshotID == snapshot.id ? result
            : retainedSnapshots.values.first(where: { $0.id == snapshot.id })?.result
        guard let result = selectedResult, result.count == snapshot.count else { throw PhotosLibraryError.staleSelection }
        let range = selection.range(total: result.count)
        guard !range.indices.isEmpty else { throw PhotosLibraryError.empty }
        recorder.update(PhotosBatchProgress(completed: 0, total: range.indices.count, downloadFraction: 0))
        let decisionsStart = ProcessInfo.processInfo.systemUptime
        let saved = try await decisionsStore.load()
        let decisionsMilliseconds = (ProcessInfo.processInfo.systemUptime - decisionsStart) * 1_000
        try Task.checkCancellation()
        try pruneAbandonedBatches()
        let folder = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        try Data("louppe-photos-review-v1".utf8).write(to: folder.appendingPathComponent(".louppe-photos-batch"))
        let inventory = ApplePhotosReviewInventory(result: result)
        let membershipStart = ProcessInfo.processInfo.systemUptime
        let membership = try PhotosReviewMembership.read(inventory: inventory, range: range, recorder: recorder)
        let membershipMilliseconds = (ProcessInfo.processInfo.systemUptime - membershipStart) * 1_000
        let mediaSession = PhotosMediaSession(provider: ApplePhotosMediaProvider(
            inventory: inventory, indicesByAssetID: membership.indicesByAssetID), folder: folder, allowNetwork: allowNetwork)
        let itemsStart = ProcessInfo.processInfo.systemUptime
        let batch = try PhotosReviewBatch.prepared(folder: folder, snapshot: snapshot, range: range,
            assets: membership.assets, decisions: saved, mediaSession: mediaSession)
        let itemsMilliseconds = (ProcessInfo.processInfo.systemUptime - itemsStart) * 1_000
        try Task.checkCancellation()
        try requireAuthorization()
        retainedSnapshots[folder] = (snapshot.id, result)
        retainedFolders.insert(folder)
        recorder.update(PhotosBatchProgress(completed: membership.assets.count,
                                           total: membership.assets.count, downloadFraction: 0))
        let totalMilliseconds = (ProcessInfo.processInfo.systemUptime - preparationStart) * 1_000
        Self.logger.notice("Photos preparation: membership=\(membership.assets.count, privacy: .public) decisionsReadMs=\(decisionsMilliseconds, privacy: .public) membershipMs=\(membershipMilliseconds, privacy: .public) reviewItemsMs=\(itemsMilliseconds, privacy: .public) totalPreparationMs=\(totalMilliseconds, privacy: .public)")
        completed = true
        return batch
    }

    func remove(_ batch: PhotosReviewBatch) async {
        await batch.mediaSession?.stop()
        guard batch.folder.deletingLastPathComponent().standardizedFileURL == cacheRoot.standardizedFileURL,
              UUID(uuidString: batch.folder.lastPathComponent) != nil else { return }
        // This is disposable app-owned media. Decisions live in Application Support.
        retainedFolders.remove(batch.folder)
        retainedSnapshots[batch.folder] = nil
        try? FileManager.default.removeItem(at: batch.folder)
    }

    private func pruneAbandonedBatches() throws {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for folder in folders where !retainedFolders.contains(folder) {
            try Task.checkCancellation()
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  (try? Data(contentsOf: folder.appendingPathComponent(".louppe-photos-batch")))
                    == Data("louppe-photos-review-v1".utf8) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func safeFilename(_ name: String, type: String) -> String {
        let leaf = (name as NSString).lastPathComponent
        if !leaf.isEmpty, !leaf.hasPrefix("."), !leaf.contains("\0"),
           leaf.utf8.count < 240, FolderScanner.recognizedExtensions.contains((leaf as NSString).pathExtension.lowercased()) { return leaf }
        let ext = UTType(type)?.preferredFilenameExtension ?? "dat"
        return "Photo.\(ext)"
    }

    private func requireAuthorization() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotosLibraryError.permissionDenied }
    }
}

/// Streams directly to a private file, with a byte budget and real PhotoKit
/// cancellation. The lock covers callbacks and cancellation, including a cancel
/// racing request-ID assignment or the final chunk. No whole-file Data buffer.
final class PhotosResourceTransfer: @unchecked Sendable {
    typealias Start = (@escaping @Sendable (Data) -> Void,
                                @escaping @Sendable ((any Error)?) -> Void) -> PHAssetResourceDataRequestID
    private let cancelRequest: @Sendable (PHAssetResourceDataRequestID) -> Void
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int64
    private var bytes: Int64 = 0
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Int64, any Error>?
    private var finished = false
    private var cancelled = false

    init(destination: URL, maximumBytes: Int64,
         cancelRequest: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void = {
             PHAssetResourceManager.default().cancelDataRequest($0)
         }) throws {
        self.maximumBytes = maximumBytes
        self.cancelRequest = cancelRequest
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func read(resource: PHAssetResource, allowNetwork: Bool,
              progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.progressHandler = { value in progress(value) }
        do {
            return try await read { receive, complete in
                PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: receive, completionHandler: complete)
            }
        } catch {
            let failure = error as NSError
            if failure.domain == PHPhotosErrorDomain,
               failure.code == PHPhotosError.Code.networkAccessRequired.rawValue {
                throw PhotosLibraryError.iCloudDownloadRequired
            }
            throw error
        }
    }

    func read(start: @escaping Start) async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock {
                    self.continuation = continuation
                    return !cancelled
                }
                guard shouldStart else { finish(CancellationError()); return }
                let id = start({ [self] data in receive(data) }, { [self] error in finish(error) })
                let shouldCancel = lock.withLock { requestID = id; return cancelled }
                if shouldCancel { cancelRequest(id) }
            }
        } onCancel: { self.cancel() }
    }

    private func receive(_ data: Data) {
        let error: (any Error)? = lock.withLock {
            guard !finished else { return nil }
            guard Int64(data.count) <= maximumBytes - bytes else { return PhotosLibraryError.batchTooLarge }
            do { try handle.write(contentsOf: data); bytes += Int64(data.count); return nil }
            catch { return error }
        }
        if let error { finish(error); cancel() }
    }

    private func finish(_ error: (any Error)?) {
        let result: (CheckedContinuation<Int64, any Error>, Result<Int64, any Error>)? = lock.withLock {
            guard !finished, let continuation else { return nil }
            finished = true
            self.continuation = nil
            do {
                try handle.close()
                return (continuation, error.map { .failure($0) } ?? .success(bytes))
            } catch { return (continuation, .failure(error)) }
        }
        if let (continuation, outcome) = result { continuation.resume(with: outcome) }
    }

    private func cancel() {
        let id = lock.withLock { cancelled = true; return requestID }
        if let id { cancelRequest(id) }
        finish(CancellationError())
    }
}

extension PhotoFile {
    /// Photos' capture date (including changes made there) owns chronology.
    /// Hide disposable cache subfolders from the user's metadata and filters.
    func forPhotosReview(in batch: PhotosReviewBatch) -> PhotoFile {
        let assetID = batch.assetIDsByPath[url.path]
        let metadata = assetID.flatMap { batch.decisions[$0] }?.metadata(fileID: id) ?? metadataSnapshot
        let date = batch.captureDatesByPath[url.path] ?? captureDate
        return PhotoFile(id: id, url: url, displayRelativePath: displayName,
            captureDate: date,
            captureDateEvidence: batch.captureDatesByPath[url.path].map { CaptureDateEvidence(date: $0, source: .photosLibrary) }
                ?? captureDateEvidence,
            cameraModel: cameraModel, lensModel: lensModel, filmSimulation: filmSimulation,
            aperture: aperture, shutterSpeed: shutterSpeed, iso: iso, mediaKind: mediaKind,
            duration: duration, videoDimensions: videoDimensions, videoCodec: videoCodec,
            videoFrameRate: videoFrameRate, videoIsPlayable: videoIsPlayable,
            audioCodec: audioCodec, audioIsPlayable: audioIsPlayable,
            modificationDate: modificationDate, fileSize: fileSize, scannedIdentity: scannedIdentity,
            metadataIsLoaded: metadataIsLoaded,
            rating: metadata.rating, ratedAt: metadata.ratedAt, starRating: metadata.starRating,
            starsChangedAt: metadata.starsChangedAt, colorLabel: metadata.colorLabel, colorChangedAt: metadata.colorChangedAt)
    }
}
