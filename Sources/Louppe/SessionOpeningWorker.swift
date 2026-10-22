import Foundation

struct SessionOpeningPreparation: Sendable {
    let restoration: SessionOpeningRestoration
    let physicalPairs: [(raw: PhotoFile, jpeg: PhotoFile)]
    let facets: SessionOpeningFacets
    let persistenceResult: SessionPersistence.ReadResult
    let preparedIndex: PreparedSessionIndex
    let preparedSort: PhotoSort
}

/// Whole-opening I/O boundary, also used for fault injection and profiling.
/// Only its complete result may enter the session's save/mutation authority.
enum SessionOpeningWorker {
    struct Hooks: Sendable {
        var willBeginStage: @Sendable (SessionOpeningStage) throws -> Void = { _ in }
        var beforeEnumeratingURL: (@Sendable (URL) throws -> Void)? = nil
        var metadataReader: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)? = nil
    }

    static func prepare(
        folder: URL,
        pairingMode: RawJPEGPairingMode,
        persistence: any SessionPersistenceClient,
        sort: PhotoSort = PhotoSort(),
        legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization? = nil,
        replaceSavedSession: Bool = false,
        recorder: SessionOpeningRecorder,
        allowsPreview: Bool = true,
        preview: (@Sendable (OpeningSessionSnapshot) async -> Void)? = nil,
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
            let inventory = try FolderScanner.discoverInventory(
                folder, pairingMode: pairingMode, isCancelled: { cancelFlag.isSet },
                recorder: recorder, beforeEnumeratingURLForTesting: hooks.beforeEnumeratingURL,
                stageWillBegin: checkpoint
            )
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
            if allowsPreview, let preview,
               pendingRestoration.permitsPreview(persistenceResult: saved) {
                try checkpoint(.previewIdentityValidation)
                try recorder.measure(.previewIdentityValidation) {
                    try FolderScanner.validateScannedIdentities(pendingRestoration.items,
                                                               isCancelled: { cancelFlag.isSet })
                    guard identity.matches(folder: folder) else {
                        throw FolderScanner.ScanError.filesChangedDuringScan
                    }
                }
                try checkpoint(.previewPublication)
                let started = ProcessInfo.processInfo.systemUptime
                await preview(OpeningSessionSnapshot(items: pendingRestoration.items))
                recorder.record(.previewPublication, seconds: ProcessInfo.processInfo.systemUptime - started)
                if cancelFlag.isSet { throw CancellationError() }
            }
            let restoredInventory = FolderScanner.Inventory(
                root: inventory.root, items: pendingRestoration.items,
                rawJPEGFileIDs: inventory.rawJPEGFileIDs
            )
            let scanned = try FolderScanner.prepareMetadata(
                in: restoredInventory, isCancelled: { cancelFlag.isSet }, recorder: recorder,
                stageWillBegin: checkpoint, metadataReaderForTesting: hooks.metadataReader
            )
            let restoration = pendingRestoration.replacingItems(scanned)
            try checkpoint(.derivedPreparation)
            let (pairs, facets, index) = recorder.measure(.derivedPreparation) {
                let pairs = inventory.physicalPairs(in: restoration.items)
                let facets = SessionOpeningFacets(items: restoration.items, isCancelled: { cancelFlag.isSet })
                var index = PreparedSessionIndex()
                if !cancelFlag.isSet { index.rebuildItems(restoration.items, sort: sort) }
                return (pairs, facets, index)
            }
            // This is deliberately last: replacements during persistence,
            // restoration or derived preparation cannot reach publication.
            try checkpoint(.finalIdentityValidation)
            try recorder.measure(.finalIdentityValidation) {
                try FolderScanner.validateScannedIdentities(restoration.items, isCancelled: { cancelFlag.isSet })
                guard identity.matches(folder: folder) else {
                    throw FolderScanner.ScanError.filesChangedDuringScan
                }
            }
            if cancelFlag.isSet { throw CancellationError() }
            try Task.checkCancellation()
            return SessionOpeningPreparation(restoration: restoration, physicalPairs: pairs,
                                             facets: facets, persistenceResult: saved,
                                             preparedIndex: index, preparedSort: sort)
        } onCancel: {
            cancelFlag.set()
        }
    }
}
