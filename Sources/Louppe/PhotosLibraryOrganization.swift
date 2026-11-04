import Foundation
import Photos

/// Album membership only. A Photos folder contains albums, never assets.
enum PhotosOrganizationDestination: Equatable, Sendable {
    case existingAlbum(localIdentifier: String)
    case newAlbum(title: String, parentFolderIdentifier: String?)
}

struct PhotosOrganizationPlan: Equatable, Sendable {
    let assetIdentifiers: [String]
    let destination: PhotosOrganizationDestination
}

struct PhotosOrganizationCollection: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case album, folder }
    let id: String
    let title: String
    let parentIdentifier: String?
    let kind: Kind
    let canAddAssets: Bool
    let canCreateAlbum: Bool
}

enum PhotosOrganizationIssue: Error, Equatable, Sendable, LocalizedError {
    case emptySelection, invalidIdentifier, invalidTitle, busy, permissionDenied
    case collectionUnavailable(String), collectionNotWritable(String)
    case unsupportedAssets([String]), assetsUnavailable, requestUnavailable
    case changeFailed(String), verificationFailed(String), verificationMismatch
    case invalidLibraryResponse, hierarchyTooLarge

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "Choose photos to add to an album."
        case .invalidIdentifier, .invalidLibraryResponse: return "The Photos selection could not be validated."
        case .invalidTitle: return "Enter a name for the new album."
        case .busy: return "Another Photos organization operation is still running."
        case .permissionDenied: return "Allow read and write access to the Photos library, then try again."
        case .collectionUnavailable: return "The selected Photos album or folder is no longer available."
        case .collectionNotWritable: return "The selected Photos album or folder cannot be edited."
        case .unsupportedAssets: return "Some selected photos cannot be added to an album."
        case .assetsUnavailable: return "Some selected photos are no longer available."
        case .requestUnavailable: return "Photos could not prepare the album change."
        case .changeFailed(let message), .verificationFailed(let message): return message
        case .verificationMismatch: return "Photos did not confirm all requested album memberships or the album's folder."
        case .hierarchyTooLarge: return "The Photos album and folder list exceeds the supported limit."
        }
    }
}

/// Thread-safe cooperative cancellation, including while PhotoKit queues its change block.
/// A started transaction cannot be cancelled; its callback and fresh verification are awaited.
final class PhotosOrganizationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct PhotosOrganizationProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case preparing, committing, verifying, finished }
    let phase: Phase
    let requestedCount: Int
    let processedCount: Int
    let verifiedCount: Int
    let acknowledgedAddedCount: Int
    let alreadyPresentCount: Int
    let missingCount: Int
    let uncertainCount: Int
}

struct PhotosOrganizationResult: Equatable, Sendable {
    enum Completion: Equatable, Sendable { case completed, cancelled, stopped }
    var completion: Completion = .completed
    var issue: PhotosOrganizationIssue?
    var requestedCount = 0
    var duplicateCount = 0
    var destinationIdentifier: String?
    /// A creation placeholder's ID, even if the callback/verification failed. Not proof of creation.
    var createdAlbumIdentifier: String?
    var destinationVerified = false
    var placementVerified = false
    /// Desired memberships observed by fresh fetches, in requested order, at each batch's verification.
    /// Other applications may change them afterwards; this is not a whole-library atomic snapshot.
    var verifiedAssetIdentifiers: [String] = []
    /// Additions acknowledged by a successful PhotoKit callback; these may still fail verification.
    var acknowledgedAddedAssetIdentifiers: [String] = []
    /// A subset of verified IDs that needed no membership change.
    var alreadyPresentAssetIdentifiers: [String] = []
    var missingAssetIdentifiers: [String] = []
    /// Examined, available IDs whose desired membership could not be verified.
    var unverifiedAssetIdentifiers: [String] = []
    /// Submitted additions without verified membership. They may have committed before an external edit.
    var uncertainAssetIdentifiers: [String] = []
    var unprocessedAssetIdentifiers: [String] = []
    var acknowledgedTransactionCount = 0

    var verifiedCount: Int { verifiedAssetIdentifiers.count }
    var processedCount: Int { requestedCount - unprocessedAssetIdentifiers.count }
}

protocol PhotosLibraryOrganizationClient: Sendable {
    func hierarchy() async throws -> [PhotosOrganizationCollection]
    func execute(_ plan: PhotosOrganizationPlan, cancellation: PhotosOrganizationCancellation,
                 progress: @escaping @Sendable (PhotosOrganizationProgress) -> Void) async -> PhotosOrganizationResult
}

enum PhotosOrganizationPlacement: Equatable, Sendable {
    case topLevel
    case folder(localIdentifier: String)
}

struct PhotosOrganizationVerification: Equatable, Sendable {
    let destinationIdentifier: String
    let destinationExists: Bool
    let placementMatches: Bool
    let presentAssetIdentifiers: Set<String>
}

struct PhotosOrganizationBatchResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case noChanges, committed, cancelled
        case rejected(PhotosOrganizationIssue), failed(PhotosOrganizationIssue)
    }
    var status: Status
    var destinationIdentifier: String?
    var createdAlbumIdentifier: String?
    var availableAssetIdentifiers: [String] = []
    var missingAssetIdentifiers: [String] = []
    var alreadyPresentAssetIdentifiers: [String] = []
    var submittedAssetIdentifiers: [String] = []
}

/// Injectable metadata-only transaction boundary. Implementations must re-fetch exact IDs and
/// collection capabilities inside each change block before constructing requests. They must await
/// the noncancellable callback, return only IDs from this batch, and never access representations.
protocol PhotosOrganizationLibrary: Sendable {
    func hierarchy() async throws -> [PhotosOrganizationCollection]
    func transact(assetIdentifiers: [String], destination: PhotosOrganizationDestination,
                  cancellation: PhotosOrganizationCancellation) async -> PhotosOrganizationBatchResult
    /// Must ignore task cancellation and fetch fresh metadata after the callback, including no-ops.
    func verify(assetIdentifiers: [String], destinationIdentifier: String,
                placement: PhotosOrganizationPlacement?) async throws -> PhotosOrganizationVerification
}

/// Shared pure pre-request policy, also used by the transactional test double.
enum PhotosOrganizationBatchPolicy {
    static let maximumBatchSize = 200

    static func validate(assetIdentifiers: [String], destination: PhotosOrganizationDestination,
                         album: PhotosOrganizationCollection?, folder: PhotosOrganizationCollection?,
                         unsupportedAssetIdentifiers: [String] = []) throws {
        guard !assetIdentifiers.isEmpty, assetIdentifiers.count <= maximumBatchSize,
              !assetIdentifiers.contains(where: \.isEmpty), Set(assetIdentifiers).count == assetIdentifiers.count else {
            throw PhotosOrganizationIssue.invalidIdentifier
        }
        switch destination {
        case .existingAlbum(let id):
            guard !id.isEmpty else { throw PhotosOrganizationIssue.invalidIdentifier }
            guard let album, album.id == id else { throw PhotosOrganizationIssue.collectionUnavailable(id) }
            guard album.kind == .album, album.canAddAssets else {
                throw PhotosOrganizationIssue.collectionNotWritable(id)
            }
        case .newAlbum(let title, let parent):
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PhotosOrganizationIssue.invalidTitle
            }
            if let parent {
                guard !parent.isEmpty else { throw PhotosOrganizationIssue.invalidIdentifier }
                guard let folder, folder.id == parent else {
                    throw PhotosOrganizationIssue.collectionUnavailable(parent)
                }
                guard folder.kind == .folder, folder.canCreateAlbum else {
                    throw PhotosOrganizationIssue.collectionNotWritable(parent)
                }
            }
        }
        guard unsupportedAssetIdentifiers.isEmpty else {
            throw PhotosOrganizationIssue.unsupportedAssets(unsupportedAssetIdentifiers)
        }
    }
}

/// The caller owns the shared operation gate, save barrier, confirmation and Quit coordination.
/// This actor rejects overlapping executions but does not introduce a second application gate.
actor PhotosLibraryOrganizationService: PhotosLibraryOrganizationClient {
    static let shared = PhotosLibraryOrganizationService()
    private let library: any PhotosOrganizationLibrary
    private let batchSize: Int
    private var executing = false

    init(library: any PhotosOrganizationLibrary = NativePhotosOrganizationLibrary(), batchSize: Int = 200) {
        self.library = library
        self.batchSize = min(max(1, batchSize), PhotosOrganizationBatchPolicy.maximumBatchSize)
    }

    func hierarchy() async throws -> [PhotosOrganizationCollection] { try await library.hierarchy() }

    func execute(_ plan: PhotosOrganizationPlan,
                 cancellation: PhotosOrganizationCancellation = PhotosOrganizationCancellation(),
                 progress: @escaping @Sendable (PhotosOrganizationProgress) -> Void = { _ in }) async -> PhotosOrganizationResult {
        var seen = Set<String>()
        let ids = plan.assetIdentifiers.filter { seen.insert($0).inserted }
        var initial = PhotosOrganizationResult()
        initial.requestedCount = ids.count
        initial.duplicateCount = plan.assetIdentifiers.count - ids.count
        initial.unprocessedAssetIdentifiers = ids
        guard !executing else {
            initial.completion = .stopped; initial.issue = .busy
            return initial
        }
        executing = true
        defer { executing = false }
        return await withTaskCancellationHandler {
            await run(ids: ids, destination: plan.destination, initial: initial,
                      cancellation: cancellation, progress: progress)
        } onCancel: { cancellation.cancel() }
    }

    private func run(ids: [String], destination: PhotosOrganizationDestination,
                     initial: PhotosOrganizationResult, cancellation: PhotosOrganizationCancellation,
                     progress: @escaping @Sendable (PhotosOrganizationProgress) -> Void) async -> PhotosOrganizationResult {
        var result = initial
        var offset = 0
        func publish(_ phase: PhotosOrganizationProgress.Phase) {
            progress(PhotosOrganizationProgress(phase: phase, requestedCount: result.requestedCount,
                processedCount: offset, verifiedCount: result.verifiedCount,
                acknowledgedAddedCount: result.acknowledgedAddedAssetIdentifiers.count,
                alreadyPresentCount: result.alreadyPresentAssetIdentifiers.count,
                missingCount: result.missingAssetIdentifiers.count, uncertainCount: result.uncertainAssetIdentifiers.count))
        }
        publish(.preparing)
        let placement: PhotosOrganizationPlacement?
        var target = destination
        switch destination {
        case .existingAlbum(let id):
            placement = nil
            result.destinationIdentifier = id
            if id.isEmpty { result.issue = .invalidIdentifier }
        case .newAlbum(let title, let parent):
            placement = parent.map { .folder(localIdentifier: $0) } ?? .topLevel
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.issue = .invalidTitle }
            if parent == "" { result.issue = .invalidIdentifier }
        }
        if ids.isEmpty { result.issue = .emptySelection }
        if ids.contains(where: \.isEmpty) { result.issue = .invalidIdentifier }
        while offset < ids.count, result.issue == nil, !cancellation.isCancelled {
            let chunk = Array(ids[offset..<min(ids.count, offset + batchSize)])
            publish(.committing)
            // Await even when the Task or cooperative flag is cancelled during the transaction.
            let batch = await library.transact(assetIdentifiers: chunk, destination: target, cancellation: cancellation)
            if case .cancelled = batch.status { cancellation.cancel(); break }
            if case .rejected(let issue) = batch.status {
                result.destinationVerified = false; result.placementVerified = false
                result.issue = issue
                break
            }
            guard valid(batch, requested: chunk, target: target) else {
                result.destinationVerified = false; result.placementVerified = false
                result.issue = .invalidLibraryResponse
                // A malformed boundary response cannot establish which requested changes committed.
                result.unverifiedAssetIdentifiers += chunk
                result.uncertainAssetIdentifiers += chunk
                offset += chunk.count
                break
            }
            result.missingAssetIdentifiers += batch.missingAssetIdentifiers
            result.destinationIdentifier = batch.destinationIdentifier ?? result.destinationIdentifier
            result.createdAlbumIdentifier = batch.createdAlbumIdentifier ?? result.createdAlbumIdentifier
            if case .committed = batch.status {
                result.acknowledgedTransactionCount += 1
                result.acknowledgedAddedAssetIdentifiers += batch.submittedAssetIdentifiers
            }
            if case .failed(let issue) = batch.status { result.issue = issue }
            let available = batch.availableAssetIdentifiers
            if let id = batch.destinationIdentifier {
                publish(.verifying)
                do {
                    let check = try await library.verify(assetIdentifiers: chunk, destinationIdentifier: id, placement: placement)
                    guard check.destinationIdentifier == id,
                          check.presentAssetIdentifiers.isSubset(of: Set(chunk)) else {
                        throw PhotosOrganizationIssue.invalidLibraryResponse
                    }
                    result.destinationVerified = check.destinationExists
                    result.placementVerified = check.destinationExists && check.placementMatches
                    let verified = check.destinationExists ? check.presentAssetIdentifiers : []
                    result.verifiedAssetIdentifiers += available.filter { verified.contains($0) }
                    result.alreadyPresentAssetIdentifiers += batch.alreadyPresentAssetIdentifiers.filter { verified.contains($0) }
                    result.unverifiedAssetIdentifiers += available.filter { !verified.contains($0) }
                    result.uncertainAssetIdentifiers += batch.submittedAssetIdentifiers.filter { !verified.contains($0) }
                    if !check.destinationExists || !check.placementMatches || !Set(available).isSubset(of: verified) {
                        result.issue = result.issue ?? .verificationMismatch
                    }
                } catch {
                    result.destinationVerified = false; result.placementVerified = false
                    result.unverifiedAssetIdentifiers += available
                    result.uncertainAssetIdentifiers += batch.submittedAssetIdentifiers
                    result.issue = result.issue ?? (error as? PhotosOrganizationIssue) ?? .verificationFailed(error.localizedDescription)
                }
                target = .existingAlbum(localIdentifier: id)
            }
            offset += chunk.count
        }
        result.unprocessedAssetIdentifiers = Array(ids.dropFirst(offset))
        // A failed transaction/verification stays visible even when cancellation raced its callback.
        if result.issue != nil { result.completion = .stopped }
        else if cancellation.isCancelled { result.completion = .cancelled }
        else if !result.missingAssetIdentifiers.isEmpty {
            result.completion = .stopped; result.issue = .assetsUnavailable
        }
        publish(.finished)
        return result
    }

    private func valid(_ batch: PhotosOrganizationBatchResult, requested: [String],
                       target: PhotosOrganizationDestination) -> Bool {
        let available = Set(batch.availableAssetIdentifiers), missing = Set(batch.missingAssetIdentifiers)
        let already = Set(batch.alreadyPresentAssetIdentifiers), submitted = Set(batch.submittedAssetIdentifiers)
        guard available.count == batch.availableAssetIdentifiers.count, missing.count == batch.missingAssetIdentifiers.count,
              already.count == batch.alreadyPresentAssetIdentifiers.count, submitted.count == batch.submittedAssetIdentifiers.count,
              available.isDisjoint(with: missing), available.union(missing) == Set(requested),
              already.isDisjoint(with: submitted), already.union(submitted) == available else { return false }
        if case .existingAlbum(let id) = target {
            guard batch.destinationIdentifier == id, batch.createdAlbumIdentifier == nil else { return false }
        } else {
            if available.isEmpty {
                guard batch.destinationIdentifier == nil, batch.createdAlbumIdentifier == nil else { return false }
            } else {
                guard let id = batch.createdAlbumIdentifier, !id.isEmpty, batch.destinationIdentifier == id,
                      already.isEmpty else { return false }
            }
        }
        if !available.isEmpty && batch.destinationIdentifier == nil { return false }
        if case .noChanges = batch.status { return submitted.isEmpty && batch.createdAlbumIdentifier == nil }
        if case .committed = batch.status { return !submitted.isEmpty }
        return true
    }
}

/// PhotoKit is the only I/O boundary. No PHAsset/image/resource survives a bounded transaction.
private actor NativePhotosOrganizationLibrary: PhotosOrganizationLibrary {
    private static let hierarchyLimit = 50_000

    func hierarchy() async throws -> [PhotosOrganizationCollection] {
        try Self.requireAuthorization()
        var nodes: [PhotosOrganizationCollection] = []
        var pending: [String?] = [nil]
        var visited = Set<String>()
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            try Self.requireAuthorization()
            let collections: PHFetchResult<PHCollection>
            if let parent {
                guard let folder = Self.folder(parent) else { throw PhotosOrganizationIssue.collectionUnavailable(parent) }
                collections = PHCollection.fetchCollections(in: folder, options: nil)
            } else {
                collections = PHCollection.fetchTopLevelUserCollections(with: nil)
            }
            var folders: [String] = []
            for index in 0..<collections.count {
                try Task.checkCancellation()
                let collection = collections.object(at: index)
                guard visited.insert(collection.localIdentifier).inserted else { continue }
                guard visited.count <= Self.hierarchyLimit else { throw PhotosOrganizationIssue.hierarchyTooLarge }
                if let album = collection as? PHAssetCollection, album.assetCollectionType == .album {
                    nodes.append(Self.node(album, parent: parent))
                } else if let folder = collection as? PHCollectionList, folder.collectionListType == .folder {
                    nodes.append(Self.node(folder, parent: parent))
                    folders.append(folder.localIdentifier)
                }
            }
            pending += folders.reversed().map(Optional.some)
        }
        try Self.requireAuthorization()
        return nodes
    }

    func transact(assetIdentifiers ids: [String], destination: PhotosOrganizationDestination,
                  cancellation: PhotosOrganizationCancellation) async -> PhotosOrganizationBatchResult {
        if cancellation.isCancelled { return .init(status: .cancelled) }
        // Refuse before submitting to PhotoKit as well as inside its queued block; never prompt here.
        do { try Self.requireAuthorization() }
        catch { return .init(status: .rejected(.permissionDenied)) }
        let state = PhotosOrganizationTransactionState()
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let report: PhotosOrganizationBatchResult
                do {
                    try Self.requireAuthorization()
                    if cancellation.isCancelled { state.set(.init(status: .cancelled)); return }
                    report = try autoreleasepool {
                        // Everything is fetched again inside this transaction. Titles are never identities.
                        let album: PHAssetCollection?
                        let folder: PHCollectionList?
                        switch destination {
                        case .existingAlbum(let id): album = Self.album(id); folder = nil
                        case .newAlbum(_, let parent): album = nil; folder = parent.flatMap(Self.folder)
                        }
                        // Validate bounds and collections before fetching or constructing any request.
                        try PhotosOrganizationBatchPolicy.validate(assetIdentifiers: ids, destination: destination,
                            album: album.map { Self.node($0, parent: nil) }, folder: folder.map { Self.node($0, parent: nil) })
                        let assets = Self.assets(ids)
                        let membership = album.map { PHAsset.fetchAssets(in: $0, options: Self.membershipOptions()) }
                        let available = ids.filter { assets[$0] != nil }
                        let already = available.filter { id in assets[id].map { membership?.contains($0) == true } ?? false }
                        let alreadySet = Set(already)
                        let additions = available.filter { !alreadySet.contains($0) }
                        let unsupported = additions.filter { assets[$0]?.sourceType.contains(.typeUserLibrary) != true }
                        try PhotosOrganizationBatchPolicy.validate(assetIdentifiers: ids, destination: destination,
                            album: album.map { Self.node($0, parent: nil) }, folder: folder.map { Self.node($0, parent: nil) },
                            unsupportedAssetIdentifiers: unsupported)
                        try Self.requireAuthorization()
                        if cancellation.isCancelled { return .init(status: .cancelled) }
                        var batch = PhotosOrganizationBatchResult(status: .noChanges,
                            destinationIdentifier: album?.localIdentifier, availableAssetIdentifiers: available,
                            missingAssetIdentifiers: ids.filter { assets[$0] == nil }, alreadyPresentAssetIdentifiers: already)
                        guard !additions.isEmpty else { return batch }
                        let request: PHAssetCollectionChangeRequest
                        if let album {
                            // Recheck immediately before the exception-raising request constructor.
                            guard album.canPerform(.addContent) else {
                                throw PhotosOrganizationIssue.collectionNotWritable(album.localIdentifier)
                            }
                            guard let change = PHAssetCollectionChangeRequest(for: album) else {
                                throw PhotosOrganizationIssue.requestUnavailable
                            }
                            request = change
                        } else {
                            let parentRequest: PHCollectionListChangeRequest?
                            if let folder {
                                guard folder.canPerform(.addContent) else {
                                    throw PhotosOrganizationIssue.collectionNotWritable(folder.localIdentifier)
                                }
                                guard let change = PHCollectionListChangeRequest(for: folder) else {
                                    throw PhotosOrganizationIssue.requestUnavailable
                                }
                                parentRequest = change
                            } else { parentRequest = nil }
                            guard case .newAlbum(let title, _) = destination else {
                                throw PhotosOrganizationIssue.invalidLibraryResponse
                            }
                            request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                            let placeholder = request.placeholderForCreatedAssetCollection
                            batch.destinationIdentifier = placeholder.localIdentifier
                            batch.createdAlbumIdentifier = placeholder.localIdentifier
                            parentRequest?.addChildCollections([placeholder] as NSArray)
                        }
                        request.addAssets(additions.compactMap { assets[$0] } as NSArray)
                        batch.submittedAssetIdentifiers = additions
                        batch.status = .committed // Proposed only; completion below decides acknowledgement.
                        return batch
                    }
                } catch {
                    report = .init(status: .rejected((error as? PhotosOrganizationIssue) ?? .changeFailed(error.localizedDescription)))
                }
                state.set(report)
            } completionHandler: { success, error in
                var report = state.get()
                if !success {
                    let failure: PhotosOrganizationIssue
                    do {
                        try Self.requireAuthorization()
                        failure = .changeFailed(error?.localizedDescription ?? "Photos did not confirm the album change.")
                    } catch { failure = .permissionDenied }
                    switch report.status {
                    case .committed, .noChanges: report.status = .failed(failure)
                    // PhotoKit can refuse submission without invoking its change block at all.
                    case .rejected(.requestUnavailable): report.status = .rejected(failure)
                    case .cancelled, .rejected, .failed: break
                    }
                }
                continuation.resume(returning: report)
            }
        }
    }

    func verify(assetIdentifiers ids: [String], destinationIdentifier: String,
                placement: PhotosOrganizationPlacement?) async throws -> PhotosOrganizationVerification {
        // Deliberately no Task.checkCancellation: verification must follow a started transaction.
        try Self.requireAuthorization()
        guard ids.count <= PhotosOrganizationBatchPolicy.maximumBatchSize else { throw PhotosOrganizationIssue.invalidIdentifier }
        return try autoreleasepool {
            guard let album = Self.album(destinationIdentifier) else {
                try Self.requireAuthorization()
                return .init(destinationIdentifier: destinationIdentifier, destinationExists: false,
                             placementMatches: false, presentAssetIdentifiers: [])
            }
            let assets = Self.assets(ids)
            let membership = PHAsset.fetchAssets(in: album, options: Self.membershipOptions())
            let present = Set(ids.filter { id in assets[id].map { membership.contains($0) } ?? false })
            let placementMatches: Bool
            switch placement {
            case nil: placementMatches = true
            case .some(.topLevel):
                placementMatches = PHCollection.fetchTopLevelUserCollections(with: nil).contains(album)
            case .some(.folder(let id)):
                placementMatches = Self.folder(id).map { PHCollection.fetchCollections(in: $0, options: nil).contains(album) } ?? false
            }
            try Self.requireAuthorization()
            return .init(destinationIdentifier: destinationIdentifier, destinationExists: true,
                         placementMatches: placementMatches, presentAssetIdentifiers: present)
        }
    }

    private static func requireAuthorization() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotosOrganizationIssue.permissionDenied }
    }

    private static func album(_ id: String) -> PHAssetCollection? {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
              album.localIdentifier == id, album.assetCollectionType == .album else { return nil }
        return album
    }

    private static func folder(_ id: String) -> PHCollectionList? {
        guard let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject,
              folder.localIdentifier == id, folder.collectionListType == .folder else { return nil }
        return folder
    }

    private static func assets(_ ids: [String]) -> [String: PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: membershipOptions())
        let requested = Set(ids)
        var assets: [String: PHAsset] = [:]
        for index in 0..<result.count {
            let asset = result.object(at: index)
            if requested.contains(asset.localIdentifier) { assets[asset.localIdentifier] = asset }
        }
        return assets
    }

    private static func membershipOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }

    private static func node(_ album: PHAssetCollection, parent: String?) -> PhotosOrganizationCollection {
        .init(id: album.localIdentifier, title: album.localizedTitle ?? "", parentIdentifier: parent, kind: .album,
              canAddAssets: album.assetCollectionType == .album && album.canContainAssets && album.canPerform(.addContent),
              canCreateAlbum: false)
    }

    private static func node(_ folder: PHCollectionList, parent: String?) -> PhotosOrganizationCollection {
        .init(id: folder.localIdentifier, title: folder.localizedTitle ?? "", parentIdentifier: parent, kind: .folder,
              canAddAssets: false, canCreateAlbum: folder.collectionListType == .folder && folder.canContainCollections && folder.canPerform(.addContent))
    }
}

/// PhotoKit's change block and completion execute on framework-owned queues.
private final class PhotosOrganizationTransactionState: @unchecked Sendable {
    private let lock = NSLock()
    private var report = PhotosOrganizationBatchResult(status: .rejected(.requestUnavailable))
    func set(_ value: PhotosOrganizationBatchResult) { lock.withLock { report = value } }
    func get() -> PhotosOrganizationBatchResult { lock.withLock { report } }
}
