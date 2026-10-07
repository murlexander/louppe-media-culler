import Darwin
import Foundation

struct SourceOrganizationUndoRecord: Sendable {
    let sourceFolder: URL
    let sourceFolderIdentity: SessionPersistence.SourceFolderIdentity
    let storageSafety: SourceOrganizationStorageSafety
    let changeKind: SourceFileChangeKind
    let reversePlan: ExportWorker.Plan
    let affectedDestinationItemIDs: [String]
    let sourceItemIDByDestinationItemID: [String: String]
}

struct SourceOrganizationResult: Sendable {
    let movedItemIDs: [String]
    let movedFiles: Int
    let failedItems: Int
    let requiresRecovery: Bool
    let failureMessage: String?
    let undoRecord: SourceOrganizationUndoRecord?
}

enum SourceOrganizationWorker {
    typealias Progress = CleanUpWorker.Progress

    private enum WorkerError: LocalizedError {
        case sourceFolderChanged
        case unsafeDestination(URL)
        case destinationIsNotDirectory(URL)
        case couldNotCreateDirectory(URL, Int32)
        case collisionSafeRenameUnavailable
        case compatibilityProbeFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceFolderChanged:
                return L10n.text("The source folder changed after the preview. Review a fresh plan.")
            case .unsafeDestination(let url):
                return L10n.text("Louppe refused an unsafe destination path near \(url.lastPathComponent).")
            case .destinationIsNotDirectory(let url):
                return L10n.text("A destination component is not a normal folder: \(url.lastPathComponent).")
            case .couldNotCreateDirectory(let url, let code):
                return L10n.text("Louppe could not create \(url.lastPathComponent) (system error \(code)).")
            case .collisionSafeRenameUnavailable:
                return L10n.text("This ExFAT card does not support the collision-safe rename Louppe requires.")
            case .compatibilityProbeFailed(let detail):
                return L10n.text("Louppe could not complete its ExFAT safety check: \(detail)")
            }
        }
    }

    static func organize(
        _ plan: SourceOrganizationPlan,
        journalDirectory: URL? = nil,
        progress: @escaping Progress
    ) -> SourceOrganizationResult {
        let result = ExportWorker.move(
            plan.sourceItems,
            to: plan.sourceFolder,
            preparedPlan: plan.workerPlan,
            journalDirectory: journalDirectory,
            journalKind: plan.changeKind == .rename
                ? .renameSource
                : .organizeSource,
            directorySyncPolicy: plan.storageSafety.directorySyncPolicy,
            renameStrategy: plan.storageSafety.noOverwriteRenameStrategy,
            prepareDestinationDirectories: {
                try prepareDestinationDirectories(for: plan)
                try verifyMoveCompatibility(for: plan)
            },
            sourceFolderIdentity: plan.sourceFolderIdentity,
            progress: progress
        )
        let movedIDs = Set(result.movedItemIDs)
        let completedGroups = plan.workerPlan.items.filter {
            !$0.movedItemIDs.isEmpty
                && $0.movedItemIDs.allSatisfy(movedIDs.contains)
        }
        let reverseItems: [ExportWorker.PlannedItem] = completedGroups.compactMap {
            group in
            let files = group.files.compactMap { file -> ExportWorker.PlannedFile? in
                guard let identity = try? FileOperationJournal.captureIdentity(
                    at: file.target
                ) else { return nil }
                return ExportWorker.PlannedFile(
                    source: file.target,
                    target: file.source,
                    scannedIdentity: identity,
                    role: file.role
                )
            }
            guard files.count == group.files.count else { return nil }
            return ExportWorker.PlannedItem(
                itemID: "undo:\(group.itemID)",
                movedItemIDs: group.movedItemIDs,
                files: files
            )
        }
        let undo: SourceOrganizationUndoRecord?
        if !reverseItems.isEmpty,
           reverseItems.count == completedGroups.count {
            undo = SourceOrganizationUndoRecord(
                sourceFolder: plan.sourceFolder,
                sourceFolderIdentity: plan.sourceFolderIdentity,
                storageSafety: plan.storageSafety,
                changeKind: plan.changeKind,
                reversePlan: ExportWorker.Plan(items: reverseItems),
                affectedDestinationItemIDs: result.movedItemIDs.compactMap {
                    plan.destinationItemIDBySourceItemID[$0]
                },
                sourceItemIDByDestinationItemID: Dictionary(
                    uniqueKeysWithValues: result.movedItemIDs.compactMap {
                        sourceID in
                        plan.destinationItemIDBySourceItemID[sourceID].map {
                            ($0, sourceID)
                        }
                    }
                )
            )
        } else {
            undo = nil
        }
        return SourceOrganizationResult(
            movedItemIDs: result.movedItemIDs,
            movedFiles: result.movedFiles,
            failedItems: result.failedPhotos,
            requiresRecovery: result.requiresRecovery,
            failureMessage: result.failureMessage,
            undoRecord: undo
        )
    }

    static func undo(
        _ record: SourceOrganizationUndoRecord,
        currentItems: [PhotoItem],
        journalDirectory: URL? = nil,
        progress: @escaping Progress
    ) -> SourceOrganizationResult {
        let result = ExportWorker.move(
            currentItems,
            to: record.sourceFolder,
            preparedPlan: record.reversePlan,
            journalDirectory: journalDirectory,
            journalKind: record.changeKind == .rename
                ? .restoreRename
                : .restoreOrganization,
            directorySyncPolicy: record.storageSafety.directorySyncPolicy,
            renameStrategy: record.storageSafety.noOverwriteRenameStrategy,
            sourceFolderIdentity: record.sourceFolderIdentity,
            progress: progress
        )
        return SourceOrganizationResult(
            movedItemIDs: result.movedItemIDs,
            movedFiles: result.movedFiles,
            failedItems: result.failedPhotos,
            requiresRecovery: result.requiresRecovery,
            failureMessage: result.failureMessage,
            undoRecord: nil
        )
    }

    private static func prepareDestinationDirectories(
        for plan: SourceOrganizationPlan
    ) throws {
        guard plan.sourceFolderIdentity.matches(folder: plan.sourceFolder) else {
            throw WorkerError.sourceFolderChanged
        }
        let root = try XMPExactFileSystemPath(url: plan.sourceFolder)
        let directories = try plan.destinationDirectories.map {
            try XMPExactFileSystemPath(url: $0)
        }.sorted {
            componentCount($0.bytes) < componentCount($1.bytes)
        }
        for directory in directories {
            try createDirectoryChain(
                directory,
                under: root,
                syncPolicy: plan.storageSafety.directorySyncPolicy
            )
        }
    }

    private static func createDirectoryChain(
        _ directory: XMPExactFileSystemPath,
        under root: XMPExactFileSystemPath,
        syncPolicy: DurableFileIO.DirectorySyncPolicy
    ) throws {
        if directory == root { return }
        var prefix = root.bytes
        if prefix.last != UInt8(ascii: "/") {
            prefix.append(UInt8(ascii: "/"))
        }
        guard directory.bytes.starts(with: prefix) else {
            throw WorkerError.unsafeDestination(directory.url)
        }
        let relative = directory.bytes.dropFirst(prefix.count)
        let components = relative.split(separator: UInt8(ascii: "/"))
        var current = root
        for rawComponent in components {
            let component = Data(rawComponent)
            guard !component.isEmpty,
                  component != Data(".".utf8),
                  component != Data("..".utf8) else {
                throw WorkerError.unsafeDestination(directory.url)
            }
            let next = try current.appending(componentBytes: component)
            guard SourceOrganizationPlanner.isScannerVisibleFolderName(
                String(decoding: component, as: UTF8.self)
            ) else {
                throw WorkerError.unsafeDestination(next.url)
            }
            let status = lstat(next)
            if let status {
                guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                      (status.st_mode & mode_t(S_IFMT)) != mode_t(S_IFLNK) else {
                    throw WorkerError.destinationIsNotDirectory(next.url)
                }
            } else {
                var failure: Int32 = 0
                let created = next.withFileSystemRepresentation { pointer in
                    var result: Int32
                    repeat {
                        result = Darwin.mkdir(pointer, 0o755)
                    } while result != 0 && errno == EINTR
                    if result != 0 { failure = errno }
                    return result == 0
                }
                if !created {
                    guard failure == EEXIST, let raced = lstat(next),
                          (raced.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                        throw WorkerError.couldNotCreateDirectory(next.url, failure)
                    }
                } else {
                    try DurableFileIO.syncDirectory(
                        current.url,
                        fullSync: true,
                        policy: syncPolicy
                    )
                    guard let createdStatus = lstat(next),
                          (createdStatus.st_mode & mode_t(S_IFMT))
                            == mode_t(S_IFDIR) else {
                        throw WorkerError.destinationIsNotDirectory(next.url)
                    }
                }
            }
            let values = try next.url.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
            guard values.isHidden != true, values.isPackage != true else {
                throw WorkerError.unsafeDestination(next.url)
            }
            current = next
        }
    }

    /// ExFAT on macOS rejects RENAME_EXCL and directory fsync. Before touching
    /// a photograph, prove Foundation's documented no-overwrite move contract
    /// and require that its successful move preserves the physical identity.
    /// Failure leaves the active journal consistent and stops at zero.
    private static func verifyMoveCompatibility(
        for plan: SourceOrganizationPlan
    ) throws {
        try verifyMoveCompatibility(
            in: plan.sourceFolder,
            storageSafety: plan.storageSafety
        )
    }

    private static func verifyMoveCompatibility(
        in sourceFolder: URL,
        storageSafety: SourceOrganizationStorageSafety
    ) throws {
        guard storageSafety.usesReducedDirectoryDurability else { return }
        let identifier = UUID().uuidString.lowercased()
        let source = sourceFolder.appendingPathComponent(
            ".louppe-move-probe-\(identifier)-source"
        )
        let occupied = sourceFolder.appendingPathComponent(
            ".louppe-move-probe-\(identifier)-occupied"
        )
        let sourceContents = Data("Louppe ExFAT move probe".utf8)
        let occupiedContents = Data("Louppe collision guard".utf8)
        let policy = storageSafety.directorySyncPolicy
        let renameStrategy = storageSafety.noOverwriteRenameStrategy
        defer {
            try? DurableFileIO.unlinkRegularFile(at: source)
            try? DurableFileIO.unlinkRegularFile(at: occupied)
            _ = try? DurableFileIO.syncDirectory(
                sourceFolder,
                fullSync: false,
                policy: policy
            )
        }

        do {
            try DurableFileIO.writeCapabilityProbeFile(
                sourceContents,
                to: source
            )
            try DurableFileIO.writeCapabilityProbeFile(
                occupiedContents,
                to: occupied
            )
            let sourceIdentity = try FileOperationJournal.captureIdentity(
                at: source
            )

            do {
                try DurableFileIO.renameWithoutOverwrite(
                    from: source,
                    to: occupied,
                    strategy: renameStrategy
                )
                throw WorkerError.collisionSafeRenameUnavailable
            } catch {
                guard isExistingDestinationError(error),
                      (try? Data(contentsOf: source)) == sourceContents,
                      (try? Data(contentsOf: occupied)) == occupiedContents else {
                    if error is WorkerError { throw error }
                    throw WorkerError.collisionSafeRenameUnavailable
                }
            }

            try DurableFileIO.unlinkRegularFile(at: occupied)
            try DurableFileIO.syncRemoval(
                of: occupied,
                fullSync: true,
                policy: policy
            )
            try DurableFileIO.renameWithoutOverwrite(
                from: source,
                to: occupied,
                strategy: renameStrategy
            )
            try DurableFileIO.syncRenameDirectories(
                from: source,
                to: occupied,
                fullSync: true,
                policy: policy
            )
            let movedIdentity = try FileOperationJournal.captureIdentity(
                at: occupied
            )
            guard FileOperationJournal.identitiesMatch(
                    expected: sourceIdentity,
                    actual: movedIdentity,
                    includeStatusChange: false
                  ),
                  (try? Data(contentsOf: occupied)) == sourceContents else {
                throw WorkerError.collisionSafeRenameUnavailable
            }
            try DurableFileIO.unlinkRegularFile(at: occupied)
            try DurableFileIO.syncRemoval(
                of: occupied,
                fullSync: true,
                policy: policy
            )
        } catch let error as WorkerError {
            throw error
        } catch {
            throw WorkerError.compatibilityProbeFailed(
                error.localizedDescription
            )
        }
    }

#if DEBUG
    static func verifyExFATMoveCompatibilityForTesting(
        in sourceFolder: URL
    ) throws {
        try verifyMoveCompatibility(
            in: sourceFolder,
            storageSafety: SourceOrganizationStorageSafety(
                fileSystemName: "exfat"
            )
        )
    }
#endif

    private static func isExistingDestinationError(_ error: Error) -> Bool {
        let cocoa = error as NSError
        return cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(EEXIST)
            || cocoa.domain == NSCocoaErrorDomain
                && cocoa.code == NSFileWriteFileExistsError
    }

    private static func lstat(
        _ path: XMPExactFileSystemPath
    ) -> Darwin.stat? {
        var value = Darwin.stat()
        let result = path.withFileSystemRepresentation {
            Darwin.lstat($0, &value)
        }
        return result == 0 ? value : nil
    }

    private static func componentCount(_ path: Data) -> Int {
        path.count(where: { $0 == UInt8(ascii: "/") })
    }
}
