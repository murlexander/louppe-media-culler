import Foundation

/// The only saved-decision restoration policy. It runs against worker-owned
/// files before publication; a failed or cancelled opening cannot mutate a
/// previous session's shared decision stores or write an incomplete snapshot.
struct SessionOpeningRestoration: Sendable {
    let items: [PhotoItem]
    let sessionRecoveryEntries: [SessionRecoveryEntry]
    let sessionContentProofs: [String: SessionContentProof]
    let retainedMissingSessionEntries: [SessionEntry]
    let restoredOrganizationOrigins: [String: Data]
    let requiresNewSessionConfirmation: Bool
    let relocatedLegacySessionHasNoFilenameMatch: Bool
    let unmatchedLegacyPhysicalFileCount: Int
    let legacySessionNeedsConfirmation: Bool
    let hasIdentityConflicts: Bool

    func permitsPreview(persistenceResult: SessionPersistence.ReadResult) -> Bool {
        persistenceResult.blockingMessage == nil && persistenceResult.access != nil
            && !items.isEmpty && !requiresNewSessionConfirmation
            && !legacySessionNeedsConfirmation && !hasIdentityConflicts
    }

    /// Preserve the restoration bookkeeping; enrichment preserves each physical
    /// file's complete review metadata and does not run restoration again.
    func replacingItems(_ items: [PhotoItem]) -> Self {
        Self(items: items, sessionRecoveryEntries: sessionRecoveryEntries,
             sessionContentProofs: sessionContentProofs,
             retainedMissingSessionEntries: retainedMissingSessionEntries,
             restoredOrganizationOrigins: restoredOrganizationOrigins,
             requiresNewSessionConfirmation: requiresNewSessionConfirmation,
             relocatedLegacySessionHasNoFilenameMatch: relocatedLegacySessionHasNoFilenameMatch,
             unmatchedLegacyPhysicalFileCount: unmatchedLegacyPhysicalFileCount,
             legacySessionNeedsConfirmation: legacySessionNeedsConfirmation,
             hasIdentityConflicts: hasIdentityConflicts)
    }

    static func prepare(
        scanned: [PhotoItem],
        url: URL,
        persistenceResult: SessionPersistence.ReadResult,
        replaceSavedSession: Bool,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Self {
        if isCancelled() { throw CancellationError() }
        let loaded = scanned
        var sessionContentProofs: [String: SessionContentProof] = [:]
        var retainedMissingSessionEntries: [SessionEntry] = []
        var sessionRecoveryEntries = replaceSavedSession ? []
            : persistenceResult.session?.recoveryEntries ?? []
        // Restore prior ratings from the sidecar file, if present.
        var pendingConflictEntries: [SessionEntry] = []
        var consumedPersistedFileIDs = Set<Data>()
        var restoredOrganizationOrigins: [String: Data] = [:]
        var relocatedSessionNeedsIdentityProof = false
        var relocatedLegacySessionHasNoFilenameMatch = false
        var unmatchedLegacyPhysicalFileCount = 0
        var legacySessionNeedsConfirmation = false
        if !replaceSavedSession, let session = persistenceResult.session {
            let ratingIndex = SessionRatingIndex(session: session)
            let savedEntries = Dictionary(uniqueKeysWithValues: session.entries.map {
                (Data($0.filename.utf8), $0)
            })
            for i in loaded.indices {
                if isCancelled() { throw CancellationError() }
                for file in loaded[i].individualFiles {
                    switch ratingIndex.lookup(for: file) {
                    case .match(let match):
                        if let digest = savedEntries[match.persistedFileIDBytes]?.contentSHA256,
                           let identity = file.scannedIdentity {
                            sessionContentProofs[file.id] = SessionContentProof(
                                identity: identity, sha256: digest
                            )
                        }
                        consumedPersistedFileIDs.insert(
                            match.persistedFileIDBytes
                        )
                        loaded[i].restoreMetadata(
                            PhotoFileMetadataSnapshot(
                                fileID: file.id,
                                rating: match.value.rating,
                                ratedAt: match.value.ratedAt,
                                starRating: match.value.starRating,
                                starsChangedAt: match.value.starsChangedAt,
                                colorLabel: match.value.colorLabel,
                                colorChangedAt: match.value.colorChangedAt
                            )
                        )
                        if let origin = match.value
                            .organizationOriginFolderPathBytes {
                            restoredOrganizationOrigins[file.id] = origin
                        }
                    case .identityConflict(let conflict):
                        if let old = savedEntries[conflict.persistedFileIDBytes] {
                            pendingConflictEntries.append(old)
                        }
                    case .absent:
                        break
                    }
                }
            }
            for old in pendingConflictEntries where !consumedPersistedFileIDs.contains(Data(old.filename.utf8)) {
                if isCancelled() { throw CancellationError() }
                consumedPersistedFileIDs.insert(Data(old.filename.utf8))
                if SessionRecoveryPolicy.hasSavedMetadata(old) {
                    sessionRecoveryEntries.append(SessionRecoveryEntry(entry: old))
                }
            }
            if session.version >= 4,
               session.fileIDEncoding == .percentEncodedFileSystemPath {
                retainedMissingSessionEntries = session.entries.filter {
                    !consumedPersistedFileIDs.contains(
                        Data($0.filename.utf8)
                    )
                }
            } else {
                retainedMissingSessionEntries = []
                unmatchedLegacyPhysicalFileCount = ratingIndex
                    .persistedPhysicalFileIDBytes
                    .subtracting(consumedPersistedFileIDs)
                    .count
            }
            legacySessionNeedsConfirmation = session.version < 4
                && (unmatchedLegacyPhysicalFileCount > 0
                    || persistenceResult.requiresPhysicalIdentityProof)
            let recordedFolder = URL(fileURLWithPath: session.sourcePath)
                .resolvingSymlinksInPath().standardizedFileURL
            let openedFolder = url.resolvingSymlinksInPath()
                .standardizedFileURL
            relocatedSessionNeedsIdentityProof =
                (recordedFolder.path != openedFolder.path
                    || (persistenceResult.requiresPhysicalIdentityProof
                        && session.version >= 4))
                && !session.entries.isEmpty
                && consumedPersistedFileIDs.isEmpty
            relocatedLegacySessionHasNoFilenameMatch =
                session.version < 4
                && recordedFolder.path != openedFolder.path
                && !session.entries.isEmpty
                && consumedPersistedFileIDs.isEmpty
        } else {
            retainedMissingSessionEntries = []
        }
        if relocatedSessionNeedsIdentityProof, let session = persistenceResult.session,
           session.version >= 4 {
            sessionRecoveryEntries += retainedMissingSessionEntries
                .filter(SessionRecoveryPolicy.hasSavedMetadata)
                .map { SessionRecoveryEntry(entry: $0) }
            retainedMissingSessionEntries = []
            relocatedSessionNeedsIdentityProof = false
        }
        if isCancelled() { throw CancellationError() }
        return Self(
            items: loaded,
            sessionRecoveryEntries: sessionRecoveryEntries,
            sessionContentProofs: sessionContentProofs,
            retainedMissingSessionEntries: retainedMissingSessionEntries,
            restoredOrganizationOrigins: restoredOrganizationOrigins,
            requiresNewSessionConfirmation: relocatedSessionNeedsIdentityProof && sessionRecoveryEntries.isEmpty,
            relocatedLegacySessionHasNoFilenameMatch: relocatedLegacySessionHasNoFilenameMatch,
            unmatchedLegacyPhysicalFileCount: unmatchedLegacyPhysicalFileCount,
            legacySessionNeedsConfirmation: legacySessionNeedsConfirmation,
            hasIdentityConflicts: !pendingConflictEntries.isEmpty
        )
    }
}
