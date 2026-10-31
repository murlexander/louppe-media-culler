import Foundation

struct SessionOpeningPreparation: Sendable {
    let restoration: SessionOpeningRestoration
    let physicalPairs: [(raw: PhotoFile, jpeg: PhotoFile)]
    let facets: SessionOpeningFacets
    let persistenceResult: SessionPersistence.ReadResult
    let preparedIndex: PreparedSessionIndex
    let preparedSort: PhotoSort
    let folderIndex: ArchiveFolderIndex?
    /// Optional metadata-cache update, run after Ready. Nil for Photos.
    var metadataCommit: SessionOpeningMetadataCommit? = nil
    /// Repeats the final file, folder and root barrier. A caller that awaits
    /// any other work after `prepare` returns must run it again immediately
    /// before publication. Nil for Photos, which has no physical files.
    var repeatFinalBarrier: (@Sendable (_ isCancelled: @Sendable () -> Bool) throws -> Void)? = nil
}

/// The optional `ArchiveMetadataIndex` update from one validated opening.
/// Its entries carry the identities the final barrier verified, so a file
/// replaced afterwards can never hit them; no source barrier follows. Run it
/// off the main actor after Ready: it compares, encodes and writes the cache,
/// and never affects decisions, saving or file operations.
struct SessionOpeningMetadataCommit: Sendable {
    let index: ArchiveMetadataIndex
    let items: [PhotoItem]
    var willCommitForTesting: (@Sendable () -> Void)? = nil

    /// Returns true when cache I/O was attempted.
    @discardableResult
    func run(isCancelled: @Sendable () -> Bool) -> Bool {
        guard !isCancelled() else { return false }
        willCommitForTesting?()
        return index.prepareCommit(items, isCancelled: isCancelled)?.commit(isCancelled: isCancelled) ?? false
    }
}

/// Whole-opening I/O boundary, also used for fault injection and profiling.
/// Only its complete result may enter the session's save/mutation authority.
enum SessionOpeningWorker {
    struct Hooks: Sendable {
        var willBeginStage: @Sendable (SessionOpeningStage) throws -> Void = { _ in }
        var beforeEnumeratingURL: (@Sendable (URL) throws -> Void)? = nil
        var metadataReader: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)? = nil
        var metadataIndex: ArchiveMetadataIndex? = nil
        /// Replaces the volume lookup of every identity barrier pass.
        var volumeResolver: FileOperationJournal.VolumeLookup.Resolver? = nil
        /// Runs inside the post-Ready metadata-cache commit, before any work.
        var willCommitMetadataIndex: (@Sendable () -> Void)? = nil
        /// SessionStore runs this after loading pin positions and folder
        /// memory, which follow the worker's final barrier.
        var didLoadOpeningStateForTesting: (@Sendable () -> Void)? = nil
    }

    static func prepare(
        folder: URL,
        pairingMode: RawJPEGPairingMode,
        expectedPinnedIdentity: PinnedFolderIdentity? = nil,
        persistence: any SessionPersistenceClient,
        sort: PhotoSort = PhotoSort(),
        legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization? = nil,
        replaceSavedSession: Bool = false,
        recorder: SessionOpeningRecorder,
        allowsPreview: Bool = true,
        photosBatch: PhotosReviewBatch? = nil,
        preview: (@Sendable (OpeningSessionSnapshot) async -> Void)? = nil,
        metadataReady: (@Sendable (OpeningMetadataUpdate) -> Void)? = nil,
        metadataInterest: OpeningMetadataInterest? = nil,
        hooks: Hooks = Hooks()
    ) async throws -> SessionOpeningPreparation {
        let cancelFlag = FolderScanner.CancelFlag()
        return try await withTaskCancellationHandler {
            func checkpoint(_ stage: SessionOpeningStage) throws {
                if cancelFlag.isSet { throw CancellationError() }
                try hooks.willBeginStage(stage)
                if cancelFlag.isSet { throw CancellationError() }
                recorder.progress(stage, completed: 0)
            }
            try checkpoint(.folderIdentity)
            let identity = try recorder.measure(.folderIdentity) {
                try SessionPersistence.SourceFolderIdentity.capture(at: folder)
            }
            guard expectedPinnedIdentity?.matches(identity) != false else {
                throw FolderScanner.ScanError.filesChangedDuringScan
            }
            if let reviewItems = photosBatch?.reviewItems {
                recorder.setCounts(physical: 0, items: reviewItems.count)
                // Membership is complete even when every image is cloud-only.
                // No folder scan, EXIF read, physical identity or original request.
                let saved = await persistence.read(for: folder, folderIdentity: identity,
                    legacySidecarRelocationAuthorization: nil)
                let restoration = try SessionOpeningRestoration.prepare(scanned: reviewItems,
                    url: folder, persistenceResult: saved, replaceSavedSession: false,
                    isCancelled: { cancelFlag.isSet })
                let facets = SessionOpeningFacets(items: reviewItems, isCancelled: { cancelFlag.isSet })
                var index = PreparedSessionIndex()
                index.rebuildItems(reviewItems, sort: sort)
                try Task.checkCancellation()
                guard !cancelFlag.isSet, identity.matches(folder: folder) else {
                    throw CancellationError()
                }
                return SessionOpeningPreparation(restoration: restoration, physicalPairs: [],
                    facets: facets, persistenceResult: saved, preparedIndex: index, preparedSort: sort, folderIndex: nil)
            }
            let metadataIndex = hooks.metadataIndex ?? (hooks.metadataReader == nil
                ? ArchiveMetadataIndex(folder: folder, folderIdentity: identity, isCancelled: { cancelFlag.isSet }) : nil)
            var didPublishCachedPreview = false
            if allowsPreview, expectedPinnedIdentity != nil, let preview, let metadataIndex {
                let cached = try metadataIndex.openingItems(pairingMode: pairingMode, isCancelled: { cancelFlag.isSet })
                if !cached.isEmpty {
                    guard identity.matches(folder: folder) else { throw FolderScanner.ScanError.filesChangedDuringScan }
                    try checkpoint(.previewPublication)
                    let started = ProcessInfo.processInfo.systemUptime
                    await preview(OpeningSessionSnapshot(items: cached, isCached: true))
                    recorder.record(.previewPublication, seconds: ProcessInfo.processInfo.systemUptime - started)
                    didPublishCachedPreview = true
                    if cancelFlag.isSet { throw CancellationError() }
                }
            }
            let inventory = try FolderScanner.discoverInventory(
                folder, pairingMode: pairingMode, isCancelled: { cancelFlag.isSet },
                recorder: recorder, beforeEnumeratingURLForTesting: hooks.beforeEnumeratingURL,
                stageWillBegin: checkpoint
            )
            /// One complete identity pass: every physical file, every folder
            /// (empty ones included) and a fresh check of the opened folder.
            /// Each pass looks volumes up afresh, once per device number.
            func identityBarrier(_ items: [PhotoItem]) throws {
                let isCancelled: @Sendable () -> Bool = { cancelFlag.isSet }
                try FolderScanner.validateScannedIdentities(items, isCancelled: isCancelled,
                    volumes: .init(resolver: hooks.volumeResolver))
                try FolderScanner.validateDirectories(in: inventory, isCancelled: isCancelled,
                    volumes: .init(resolver: hooks.volumeResolver))
                guard identity.matches(folder: folder) else {
                    throw FolderScanner.ScanError.filesChangedDuringScan
                }
            }
            // Files and folders were captured during discovery; the preview
            // and final barriers recheck them. The opened folder itself is
            // rechecked here, before its sidecar is read.
            guard identity.matches(folder: folder) else {
                throw FolderScanner.ScanError.filesChangedDuringScan
            }
            try checkpoint(.persistenceRead)
            let readStart = ProcessInfo.processInfo.systemUptime
            let saved = await persistence.read(
                for: folder, folderIdentity: identity,
                legacySidecarRelocationAuthorization: legacySidecarRelocationAuthorization
            )
            recorder.record(.persistenceRead, seconds: ProcessInfo.processInfo.systemUptime - readStart)
            try checkpoint(.decisionRestoration)
            let pendingRestoration = try recorder.measure(.decisionRestoration) {
                try SessionOpeningRestoration.prepare(
                    scanned: inventory.items, url: folder, persistenceResult: saved,
                    replaceSavedSession: replaceSavedSession, isCancelled: { cancelFlag.isSet }
                )
            }
            var didPublishPreview = false
            if allowsPreview, !didPublishCachedPreview, let preview,
               pendingRestoration.permitsPreview(persistenceResult: saved) {
                // Read-only badges, folders and pixels must match the disk.
                try checkpoint(.previewIdentityValidation)
                try recorder.measure(.previewIdentityValidation) {
                    try identityBarrier(pendingRestoration.items)
                }
                try checkpoint(.previewPublication)
                let started = ProcessInfo.processInfo.systemUptime
                await preview(OpeningSessionSnapshot(items: pendingRestoration.items))
                didPublishPreview = true
                recorder.record(.previewPublication, seconds: ProcessInfo.processInfo.systemUptime - started)
                if cancelFlag.isSet { throw CancellationError() }
            }
            let restoredInventory = FolderScanner.Inventory(
                root: inventory.root, items: pendingRestoration.items,
                rawJPEGFileIDs: inventory.rawJPEGFileIDs, directories: inventory.directories
            )
            // Cache hits do no I/O and misses bracket their reads; the final
            // barrier below covers both, so no complete pass runs here.
            let scanned = try FolderScanner.prepareMetadata(
                in: restoredInventory, isCancelled: { cancelFlag.isSet }, recorder: recorder,
                stageWillBegin: checkpoint, metadataReaderForTesting: hooks.metadataReader,
                metadataIndex: metadataIndex, commitsMetadataIndex: false, validatesIdentities: false,
                metadataReady: didPublishPreview ? metadataReady : nil, metadataInterest: metadataInterest
            )
            let reviewItems: [PhotoItem]
            if let photosBatch {
                reviewItems = FolderScanner.sortItems(scanned.map { item in
                    PhotoItem(primaryFile: item.primaryFile.forPhotosReview(in: photosBatch),
                              pairedFile: item.pairedFile?.forPhotosReview(in: photosBatch))
                })
            } else { reviewItems = scanned }
            let restoration = pendingRestoration.replacingItems(reviewItems)
            try checkpoint(.derivedPreparation)
            let (pairs, facets, index, folderIndex) = recorder.measure(.derivedPreparation) {
                let pairs = inventory.physicalPairs(in: restoration.items)
                let facets = SessionOpeningFacets(items: restoration.items, isCancelled: { cancelFlag.isSet })
                var index = PreparedSessionIndex()
                if !cancelFlag.isSet { index.rebuildItems(restoration.items, sort: sort) }
                let folders = photosBatch == nil
                    ? ArchiveFolderIndex(root: folder, directories: inventory.directories, items: restoration.items) : nil
                return (pairs, facets, index, folders)
            }
            // This is deliberately last: replacements during discovery,
            // metadata, persistence, restoration or derived preparation
            // cannot reach publication. Nothing slow follows it.
            try checkpoint(.finalIdentityValidation)
            try recorder.measure(.finalIdentityValidation) {
                try identityBarrier(restoration.items)
            }
            if cancelFlag.isSet { throw CancellationError() }
            try Task.checkCancellation()
            return SessionOpeningPreparation(restoration: restoration, physicalPairs: pairs,
                                             facets: facets, persistenceResult: saved,
                                             preparedIndex: index, preparedSort: sort, folderIndex: folderIndex,
                                             metadataCommit: metadataIndex.map {
                                                 SessionOpeningMetadataCommit(index: $0, items: restoration.items,
                                                     willCommitForTesting: hooks.willCommitMetadataIndex)
                                             },
                                             repeatFinalBarrier: { [inventory, identity, items = restoration.items,
                                                                    resolver = hooks.volumeResolver] isCancelled in
                                                 try FolderScanner.validateScannedIdentities(items, isCancelled: isCancelled,
                                                     volumes: .init(resolver: resolver))
                                                 try FolderScanner.validateDirectories(in: inventory, isCancelled: isCancelled,
                                                     volumes: .init(resolver: resolver))
                                                 guard identity.matches(folder: folder) else {
                                                     throw FolderScanner.ScanError.filesChangedDuringScan
                                                 }
                                             })
        } onCancel: {
            cancelFlag.set()
        }
    }
}
