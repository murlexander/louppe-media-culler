import Darwin
import CryptoKit
import Foundation

/// Filesystem-only Export implementation, CleanUpWorker's shape: it owns no
/// UI state and creates a fresh FileManager inside each call. Copy duplicates
/// files and never touches originals. Copy and Move both reserve one shared
/// collision suffix per photo, so RAW+JPEG partners keep matching basenames.
/// A partial pair failure is rolled back; the result reports if rollback
/// itself also failed.
enum ExportWorker {
    typealias Progress = CleanUpWorker.Progress
    /// Transfer progress is intentionally independent from the worker's
    /// per-file progress callback. The latter remains available to the
    /// file-operation safety tests and to callers that need physical-file
    /// boundaries; the export UI should reflect the amount of data moved.
    typealias ByteProgress = @Sendable (_ completedBytes: Int64, _ totalBytes: Int64) -> Void
    typealias FileCopier = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    struct CopyResult: Sendable {
        let copiedFiles: Int
        /// Photos for which at least one member could not be copied. Any
        /// members already copied for that photo were removed again.
        let failedPhotos: Int
        /// Photos whose partial destination copy could not be removed fully.
        let inconsistentPhotos: Int
        /// The photographer stopped Copy. Photos completed before cancellation
        /// remain at the destination; the in-progress photo is rolled back.
        let cancelled: Bool
        /// Why Copy stopped. A missing reason while `cancelled` is true is
        /// retained explicitly so the UI and diagnostic log never mislabel an
        /// unexplained interruption as an intentional photographer action.
        let cancellationReason: CopyCancellationReason?
        /// The operation was stopped because its durable recovery checkpoint
        /// could not be updated.
        let journalFailure: Bool
        /// An active journal remains and must reconcile the interrupted
        /// operation before another file operation starts. Verified staged or
        /// completed copies are preserved; Move still restores its source state.
        let requiresRecovery: Bool
        /// A concise, user-facing reason for the first failure in the batch.
        let failureMessage: String?
        let xmpSummary: XMPResultSummary?
    }

    enum CopyCancellationReason: Equatable, Sendable {
        /// The photographer confirmed the Stop Copying prompt.
        case userConfirmed
        /// A caller stopped the worker without recording a reason. This is an
        /// app defect worth surfacing, never an assumption about the card.
        case unrecorded

        var userMessage: String {
            switch self {
            case .userConfirmed:
                return L10n.text("You chose to stop copying.")
            case .unrecorded:
                return L10n.text("Copy stopped without a recorded reason. Send Alex the diagnostic log with this report.")
            }
        }

        var diagnosticValue: String {
            switch self {
            case .userConfirmed: return "user-confirmed"
            case .unrecorded: return "unrecorded"
            }
        }
    }

    struct MoveResult: Sendable {
        /// Photos whose files *all* reached the destination — SessionStore
        /// drops exactly these ids from the session.
        let movedItemIDs: [String]
        let movedFiles: Int
        /// Photos rolled back and left untouched in the source folder.
        let failedPhotos: Int
        /// Rollback also failed — a pair may be split across both folders.
        let inconsistentPhotos: Int
        let journalFailure: Bool
        let requiresRecovery: Bool
        let failureMessage: String?
        let xmpSummary: XMPResultSummary?
    }

    struct XMPResultSummary: Equatable, Sendable {
        var mediaFiles = 0
        var created = 0
        var updated = 0
        var alreadyCurrent = 0
        var copiedUnchanged = 0
        var unsupported = 0
        var skipped = 0
        var conflicts = 0
        var failed = 0

        init(plan: XMPExportPreparedPlan) {
            for family in plan.issueFamilies {
                if family.category == .unsupportedMedia {
                    unsupported += 1
                } else if family.category.isConflict {
                    conflicts += 1
                } else if family.category.isFailure {
                    failed += 1
                } else {
                    skipped += 1
                }
            }
        }

        mutating func record(_ file: PlannedFile) {
            switch file.role {
            case .media:
                mediaFiles += 1
            case .applicationXMP:
                copiedUnchanged += 1
            case .preparedXMP:
                switch file.xmpCategory {
                case .create: created += 1
                case .update: updated += 1
                case .alreadyCurrent: alreadyCurrent += 1
                default: skipped += 1
                }
            case .retiredXMPSource:
                break
            }
        }

        /// Families the collision planner could not name. Their media still
        /// exports; only the shared packet is left behind.
        mutating func recordUnplannedFamilies(_ count: Int) {
            skipped += count
        }

        mutating func recordFailures(in items: some Sequence<PlannedItem>) {
            failed += items.reduce(0) { count, item in
                count + item.files.count(where: {
                    $0.role == .preparedXMP
                        || $0.role == .applicationXMP
                })
            }
        }
    }

    struct PlannedFile: Sendable, Equatable {
        let source: URL
        let target: URL
        let scannedIdentity: FileOperationJournal.FileIdentity?
        /// Scan-time size used when an older identity omitted its logical
        /// size. It is display-only; filesystem identity remains the safety
        /// authority for every operation.
        let expectedByteCount: Int64
        let role: FileOperationJournal.PlannedFileRole
        let expectedSourceDigest: Data?
        let preparedContents: Data?
        let xmpCategory: XMPPublicationCategory?

        init(
            source: URL,
            target: URL,
            scannedIdentity: FileOperationJournal.FileIdentity?,
            expectedByteCount: Int64 = 0,
            role: FileOperationJournal.PlannedFileRole = .media,
            expectedSourceDigest: Data? = nil,
            preparedContents: Data? = nil,
            xmpCategory: XMPPublicationCategory? = nil
        ) {
            self.source = source
            self.target = target
            self.scannedIdentity = scannedIdentity
            self.expectedByteCount = max(0, expectedByteCount)
            self.role = role
            self.expectedSourceDigest = expectedSourceDigest
            self.preparedContents = preparedContents
            self.xmpCategory = xmpCategory
        }

        /// Bytes that reach the photographer's chosen destination. The
        /// retired source XMP packet is an internal Move safety step, not part
        /// of the requested export, so it must not distort visible progress.
        var transferByteCount: Int64 {
            guard role != .retiredXMPSource else { return 0 }
            if let preparedContents {
                return Int64(clamping: preparedContents.count)
            }
            if let logicalSize = scannedIdentity?.logicalSize {
                return max(0, logicalSize)
            }
            return expectedByteCount
        }
    }

    struct PlannedItem: Sendable, Equatable {
        let itemID: String
        let movedItemIDs: [String]
        let files: [PlannedFile]
    }

    struct Plan: Sendable, Equatable {
        let items: [PlannedItem]
        let destinationBindings: [DurableFileIO.DirectoryBinding]
        /// Sidecar families whose media is spread across more than one family
        /// — a RAW+JPEG pair matched across subfolders. One collision suffix
        /// cannot name a shared packet for two directories, so the media
        /// exports without it. The result reports these as skipped instead of
        /// quietly dropping packets the preflight already counted.
        let unplannedSidecarFamilyCount: Int

        init(items: [PlannedItem], unplannedSidecarFamilyCount: Int = 0,
             destinationBindings: [DurableFileIO.DirectoryBinding] = []) {
            self.destinationBindings = destinationBindings
            self.items = items
            self.unplannedSidecarFamilyCount = unplannedSidecarFamilyCount
        }

        var totalFiles: Int { items.reduce(0) { $0 + $1.files.count } }

        var totalTransferBytes: Int64 {
            items.reduce(into: Int64(0)) { total, item in
                for file in item.files {
                    let (sum, overflowed) = total.addingReportingOverflow(
                        file.transferByteCount
                    )
                    total = overflowed ? Int64.max : sum
                }
            }
        }

        func photoCount(from itemOffset: Int) -> Int {
            guard itemOffset < items.count else { return 0 }
            return items[itemOffset...].reduce(0) {
                $0 + $1.movedItemIDs.count
            }
        }
    }

    /// A cross-thread cancellation signal owned by ExportManager. It is used
    /// only for Copy: Move must finish or roll back before session state can
    /// safely change.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storedReason: CopyCancellationReason?

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedReason != nil
        }

        var reason: CopyCancellationReason? {
            lock.lock()
            defer { lock.unlock() }
            return storedReason
        }

        /// The first request is the immutable cancellation authority. Keeping
        /// it immutable lets the result identify exactly what stopped Copy.
        @discardableResult
        func request(_ reason: CopyCancellationReason) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard storedReason == nil else { return false }
            storedReason = reason
            return true
        }

        /// Compatibility for worker callers that predate reasoned
        /// cancellation. Production UI must call `request(_:)`; this path is
        /// intentionally surfaced as an unexplained stop in diagnostics.
        func set() {
            _ = request(.unrecorded)
        }
    }

    enum PlanningError: LocalizedError {
        case conflictingFamilyNames
        case collisionSearchExhausted

        var errorDescription: String? {
            switch self {
            case .conflictingFamilyNames:
                return L10n.text("One media/XMP family has equivalent destination names. Export separately without XMP, or rename the files first.")
            case .collisionSearchExhausted:
                return L10n.text("Louppe could not reserve a distinct destination name. Choose another folder and retry.")
            }
        }
    }

    /// Reserves every destination name before file I/O. If any member of a
    /// photo collides, all members receive the same numeric suffix. The
    /// reservation set also prevents two same-named photos from different
    /// source subfolders colliding with each other in the same export batch.
    static func makePlan(
        for items: [PhotoItem],
        in destination: URL,
        xmpPlan: XMPExportPreparedPlan? = nil,
        mode: ExportMode = .copy,
        destinationBinding: DurableFileIO.DirectoryBinding? = nil,
        isCancelled: @Sendable () -> Bool = { false },
        destinationEntryExists: (URL) -> Bool = pathEntryExists
    ) throws -> Plan {
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
        let binding = try destinationBinding ?? DurableFileIO.DirectoryBinding(url: destination)
        try binding.requireCurrentPath()
        var reservedPaths: Set<String> = []
        // The complete unsuffixed family is the key: a JPEG-only group must
        // still try zero even if a previous RAW+JPEG group needed a suffix
        // solely because its RAW collided. Repeated identical families resume
        // after their last reservation instead of rescanning all prior names.
        var nextSuffixByFamily: [[String]: Int] = [:]
        var plannedItems: [PlannedItem] = []
        plannedItems.reserveCapacity(items.count)

        let familyByMediaPath = xmpPlan?.familyByMediaPath ?? [:]
        let familiesByID = Dictionary(
            uniqueKeysWithValues: (xmpPlan?.families ?? []).map { ($0.id, $0) }
        )
        var groupedItems: [(key: String, items: [PhotoItem])] = []
        var groupIndex: [String: Int] = [:]
        var unplannedFamilyIDs: Set<String> = []
        for item in items {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            let familyIDs = Set(item.individualFiles.compactMap { file in
                (try? XMPExactFileSystemPath(url: file.url))
                    .flatMap { familyByMediaPath[$0]?.id }
            })
            if familyIDs.count > 1 {
                // A pair matched across subfolders belongs to one sidecar
                // family per directory. Keep the media atomic in one planned
                // item and record the packets Louppe will not write.
                unplannedFamilyIDs.formUnion(familyIDs)
            }
            let key = familyIDs.count == 1
                ? "xmp:\(familyIDs.first!)"
                : "item:\(item.id)"
            if let index = groupIndex[key] {
                groupedItems[index].items.append(item)
            } else {
                groupIndex[key] = groupedItems.count
                groupedItems.append((key, [item]))
            }
        }

        for group in groupedItems {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            let sourceFiles = group.items.flatMap(\.individualFiles)
            let family = group.key.hasPrefix("xmp:")
                ? familiesByID[String(group.key.dropFirst(4))]
                : nil
            func candidateNames(suffix: Int) -> [String] {
                let mediaNames = sourceFiles.map {
                    suffixedFilename(
                        $0.url.lastPathComponent,
                        suffix: suffix
                    )
                }
                var targetNames = mediaNames
                if let family, let firstMediaName = mediaNames.first {
                    if family.finalPacket != nil {
                        targetNames.append(canonicalXMPFilename(
                            for: firstMediaName,
                            existing: family.canonicalSource
                        ))
                    }
                    for packet in family.applicationPackets {
                        guard let ownerIndex = sourceFiles.firstIndex(where: {
                            (try? XMPExactFileSystemPath(url: $0.url))
                                == packet.ownerMediaPath
                        }) else { continue }
                        targetNames.append(
                            mediaNames[ownerIndex]
                                + xmpExtension(of: packet.source)
                        )
                    }
                }
                return targetNames
            }
            let originalNames = candidateNames(suffix: 0)
            let familyKey = originalNames.map(normalizedReservationName).sorted()
            guard Set(familyKey).count == familyKey.count else {
                // A shared suffix cannot separate equivalent names *inside*
                // one family. Refuse before I/O instead of looping forever.
                throw PlanningError.conflictingFamilyNames
            }
            var suffix = nextSuffixByFamily[familyKey, default: 0]
            while true {
                try Task.checkCancellation()
                if isCancelled() { throw CancellationError() }
                let targetNames = suffix == 0
                    ? originalNames : candidateNames(suffix: suffix)
                let normalizedPaths = targetNames.map(normalizedReservationName)
                guard Set(normalizedPaths).count == normalizedPaths.count else {
                    throw PlanningError.conflictingFamilyNames
                }
                // Avoid path construction and filesystem probes for names we
                // already reserved in this same immutable batch.
                if normalizedPaths.contains(where: reservedPaths.contains) {
                    guard suffix < Int.max else {
                        throw PlanningError.collisionSearchExhausted
                    }
                    suffix += 1
                    continue
                }
                let targets = try targetNames.map {
                    try FileOperationJournal.appendingPathComponentExactly(
                        $0,
                        to: destination
                    )
                }
                let areAvailable = targets.allSatisfy { !destinationEntryExists($0) }
                if areAvailable {
                    reservedPaths.formUnion(normalizedPaths)
                    nextSuffixByFamily[familyKey] = suffix < Int.max ? suffix + 1 : suffix
                    let mediaTargets = Array(targets.prefix(sourceFiles.count))
                    var files = zip(sourceFiles, mediaTargets).map {
                        PlannedFile(
                            source: $0.0.url,
                            target: $0.1,
                            scannedIdentity: $0.0.scannedIdentity,
                            expectedByteCount: $0.0.fileSize
                        )
                    }
                    if let family {
                        var nextTargetIndex = sourceFiles.count
                        if let finalPacket = family.finalPacket,
                           targets.indices.contains(nextTargetIndex) {
                            let canonicalTarget = targets[nextTargetIndex]
                            nextTargetIndex += 1
                            let anchorFile = sourceFiles[0]
                            let preparedSource = family.canonicalSource?.url
                                ?? anchorFile.url
                            let preparedIdentity = family.canonicalSourceIdentity
                                ?? anchorFile.scannedIdentity
                            files.append(PlannedFile(
                                source: preparedSource,
                                target: canonicalTarget,
                                scannedIdentity: preparedIdentity,
                                role: .preparedXMP,
                                expectedSourceDigest:
                                    family.canonicalSourceDigest,
                                preparedContents: finalPacket,
                                xmpCategory: family.category
                            ))
                        }

                        for packet in family.applicationPackets {
                            guard targets.indices.contains(nextTargetIndex) else {
                                break
                            }
                            files.append(PlannedFile(
                                source: packet.source.url,
                                target: targets[nextTargetIndex],
                                scannedIdentity: packet.identity,
                                role: .applicationXMP,
                                expectedSourceDigest: packet.sourceDigest
                            ))
                            nextTargetIndex += 1
                        }

                        let retiresCanonical = mode == .move
                            && family.finalPacket != nil
                            && family.allFamilyMediaSelected
                            && family.canonicalSource != nil
                        if retiresCanonical,
                           let source = family.canonicalSource,
                           let identity = family.canonicalSourceIdentity {
                            files.append(PlannedFile(
                                source: source.url,
                                target: try retirementURL(beside: source.url),
                                scannedIdentity: identity,
                                role: .retiredXMPSource,
                                expectedSourceDigest: family.canonicalSourceDigest
                            ))
                        }
                    }
                    plannedItems.append(PlannedItem(
                        itemID: group.key,
                        movedItemIDs: group.items.map(\.id),
                        files: files
                    ))
                    break
                }
                guard suffix < Int.max else {
                    throw PlanningError.collisionSearchExhausted
                }
                suffix += 1
            }
        }
        // A family claimed by a single-family group is planned normally even
        // if another item also touched it, so only families no group planned
        // are reported.
        let plannedFamilyIDs = Set(
            plannedItems.map(\.itemID)
                .filter { $0.hasPrefix("xmp:") }
                .map { String($0.dropFirst(4)) }
        )
        return Plan(
            items: plannedItems,
            unplannedSidecarFamilyCount:
                unplannedFamilyIDs.subtracting(plannedFamilyIDs).count,
            destinationBindings: [binding]
        )
    }

    static func copy(
        _ items: [PhotoItem],
        to destination: URL,
        xmpPlan: XMPExportPreparedPlan? = nil,
        preparedPlan: Plan? = nil,
        destinationBinding: DurableFileIO.DirectoryBinding? = nil,
        journalDirectory: URL? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        cancellationReason: @escaping @Sendable () -> CopyCancellationReason? = { nil },
        fileCopier: FileCopier? = nil,
        afterStagedFile: (Int) -> Void = { _ in },
        progress: @escaping Progress,
        byteProgress: @escaping ByteProgress = { _, _ in }
    ) -> CopyResult {
        let fm = FileManager()
        var xmpSummary = xmpPlan.map(XMPResultSummary.init(plan:))
        let plan: Plan
        do {
            plan = try preparedPlan ?? makePlan(
                    for: items,
                    in: destination,
                    xmpPlan: xmpPlan,
                    mode: .copy,
                    destinationBinding: destinationBinding,
                    isCancelled: isCancelled
                )
        } catch is CancellationError {
            return CopyResult(
                copiedFiles: 0, failedPhotos: 0, inconsistentPhotos: 0,
                cancelled: true,
                cancellationReason: cancellationReason() ?? .unrecorded,
                journalFailure: false, requiresRecovery: false,
                failureMessage: nil, xmpSummary: xmpSummary
            )
        } catch {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                cancellationReason: nil,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .planning
                ),
                xmpSummary: xmpSummary
            )
        }
        if preparedPlan != nil,
           !confirmedPlanTargetsRemainAvailable(plan) {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                cancellationReason: nil,
                journalFailure: false,
                requiresRecovery: false,
                failureMessage: L10n.text("A destination name was claimed after confirmation. Review and confirm a fresh export plan."),
                xmpSummary: xmpSummary
            )
        }
        xmpSummary?.recordUnplannedFamilies(plan.unplannedSidecarFamilyCount)
        guard plan.items.allSatisfy({ item in
            item.files.allSatisfy { $0.scannedIdentity != nil }
        }) else {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                cancellationReason: nil,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: L10n.text("One or more source files could not be verified before copying"),
                xmpSummary: xmpSummary
            )
        }
        let boundDirectories: [Data: DurableFileIO.BoundDirectory]
        do {
            var directories: [Data: DurableFileIO.BoundDirectory] = [:]
            for file in plan.items.flatMap(\.files) {
                let parentPath = try XMPExactFileSystemPath(url: file.target).parent
                let parent = parentPath.url
                let key = parentPath.bytes
                if directories[key] != nil { continue }
                let binding = try plan.destinationBindings.first {
                    FileOperationJournal.exactPathsEqual($0.url, parent)
                } ?? DurableFileIO.DirectoryBinding(url: parent)
                try ExportDestinationValidator.requireCollisionSafePublication(at: binding)
                directories[key] = try DurableFileIO.BoundDirectory(binding)
            }
            boundDirectories = directories
        } catch {
            return CopyResult(copiedFiles: 0, failedPhotos: items.count,
                inconsistentPhotos: 0, cancelled: false, cancellationReason: nil,
                journalFailure: false, requiresRecovery: false,
                failureMessage: error.localizedDescription, xmpSummary: xmpSummary)
        }
        let protectedCopier: FileCopier = { source, temporary in
            let key = try XMPExactFileSystemPath(url: temporary).parent.bytes
            guard let directory = boundDirectories[key] else {
                throw DurableFileIO.DestinationChanged()
            }
            try directory.binding.requireCurrentPath()
            if let fileCopier { // Fault injection for the existing worker tests.
                try fileCopier(source, temporary)
                try directory.binding.requireCurrentPath()
            } else {
                try directory.copy(from: source, to: temporary)
            }
        }
        let writer: FileOperationJournal.Writer
        do {
            writer = try FileOperationJournal.start(
                kind: .exportCopy,
                seeds: plan.items.flatMap { item in
                    item.files.map {
                        FileOperationJournal.Seed(
                            itemID: item.itemID,
                            source: $0.source,
                            destination: $0.target,
                            expectedIdentity: $0.scannedIdentity,
                            role: $0.role,
                            expectedSourceDigest: $0.expectedSourceDigest,
                            preparedContentDigest: $0.preparedContents.map {
                                Data(SHA256.hash(data: $0))
                            }
                        )
                    }
                },
                directory: journalDirectory
            )
        } catch {
            return CopyResult(
                copiedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                cancelled: false,
                cancellationReason: nil,
                journalFailure: true,
                requiresRecovery:
                    FileOperationJournal.errorRequiresRecovery(error),
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .safetyRecord
                ),
                xmpSummary: xmpSummary
            )
        }
        var reporter = ThrottledProgress(total: plan.totalFiles, callback: progress)
        var byteReporter = ThrottledByteProgress(
            total: plan.totalTransferBytes,
            callback: byteProgress
        )
        var copied = 0
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var cancelled = false
        var observedCancellationReason: CopyCancellationReason?
        var journalFailure = false
        var failureMessage: String?
        var sourceUnavailable = false
        var globalFileIndex = 0

        func requestedCancellation() -> CopyCancellationReason? {
            guard isCancelled() else { return nil }
            return cancellationReason() ?? .unrecorded
        }

        itemLoop: for (itemOffset, item) in plan.items.enumerated() {
            let itemFileIndex = globalFileIndex
            globalFileIndex += item.files.count
            if let reason = requestedCancellation() {
                cancelled = true
                observedCancellationReason = reason
                break
            }
            var touchedForItem: [TouchedExportFile] = []
            var failed = false
            var attempted = 0
            for (localFileIndex, file) in item.files.enumerated() {
                let fileIndex = itemFileIndex + localFileIndex
                if let reason = requestedCancellation() {
                    cancelled = true
                    observedCancellationReason = reason
                    failed = true
                    break
                }
                attempted += 1
                var touched = TouchedExportFile(
                    file: file,
                    index: fileIndex,
                    location: .none,
                    identity: nil
                )
                guard let temporary = writer.temporaryURL(at: fileIndex) else {
                    journalFailure = true
                    failed = true
                    failureMessage = failureMessage
                        ?? L10n.text("Louppe could not resolve its protected temporary copy path")
                    touchedForItem.append(touched)
                    reporter.advance()
                    break
                }
                guard let key = try? XMPExactFileSystemPath(url: file.target).parent.bytes,
                      let directory = boundDirectories[key] else {
                    failed = true
                    failureMessage = DurableFileIO.DestinationChanged().localizedDescription
                    touchedForItem.append(touched)
                    reporter.advance()
                    break
                }
                do {
                    try directory.binding.requireCurrentPath()
                    try writer.mark(.started, fileAt: fileIndex)
                } catch {
                    journalFailure = true
                    failed = true
                    failureMessage = failureMessage ?? copyFailureMessage(
                        for: error,
                        phase: .safetyRecord
                    )
                }
                if !failed {
                    do {
                        if let preparedContents = file.preparedContents {
                            try writer.requireUnchangedSource(at: fileIndex)
                            try directory.write(preparedContents, to: temporary)
                        } else {
                            try copySourceWithReconnectRetry(
                                writer: writer,
                                fileIndex: fileIndex,
                                source: file.source,
                                temporary: temporary,
                                isCancelled: isCancelled,
                                fileCopier: protectedCopier
                            )
                        }
                        touched.location = .temporary(temporary)
                        touched.identity = try FileOperationJournal
                            .captureIdentity(at: temporary)
                        try DurableFileIO.syncFile(
                            at: temporary,
                            fullSync: true
                        )
                        try DurableFileIO.syncDirectory(
                            temporary.deletingLastPathComponent(),
                            fullSync: true
                        )
                        if file.preparedContents != nil {
                            try writer.requirePreparedContent(
                                at: fileIndex,
                                fileURL: temporary
                            )
                        } else {
                            // Detect an in-place source rewrite that raced with
                            // the copy. Rollback removes a duplicate only after
                            // proving both files remain byte-for-byte equal.
                            try requireSourceAfterReconnect(
                                writer: writer,
                                fileIndex: fileIndex,
                                source: file.source,
                                allowCancellation: false,
                                isCancelled: isCancelled
                            )
                        }
                    } catch {
                        if case SourceReconnectError.cancelled = error {
                            cancelled = true
                            observedCancellationReason = cancellationReason()
                                ?? .unrecorded
                        }
                        if !cancelled, failureMessage == nil {
                            failureMessage = copyFailureMessage(
                                for: error,
                                phase: .readingSource
                            )
                        }
                        if isUnavailableSourceError(error) {
                            sourceUnavailable = true
                        }
                        if (try? directory.binding.requireCurrentPath()) == nil {
                            // A pathname can no longer identify our created file.
                            // Preserve the record; never adopt a replacement.
                            touched.location = .ambiguous
                        } else if case .none = touched.location,
                           pathEntryExists(temporary) {
                            // `copyItem` may leave a partial regular file when
                            // it throws. Record that exact inode before doing
                            // anything else so rollback can remove only the
                            // operation-created artifact, never a late file
                            // that merely appears at the same pathname.
                            do {
                                let partialIdentity = try FileOperationJournal
                                    .captureIdentity(at: temporary)
                                try writer.mark(
                                    .started,
                                    fileAt: fileIndex,
                                    identityAt: temporary,
                                    expectedIdentity: partialIdentity,
                                    includeStatusChange: false
                                )
                                touched.location = .temporary(temporary)
                                touched.identity = partialIdentity
                                touched.isIncompleteCopy = true
                            } catch {
                                journalFailure = true
                                touched.location = .ambiguous
                            }
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: false
                        )
                        if file.preparedContents != nil {
                            try writer.requirePreparedContent(
                                at: fileIndex,
                                fileURL: temporary
                            )
                        }
                        try writer.mark(
                            .staged,
                            fileAt: fileIndex,
                            identityAt: temporary,
                            expectedIdentity: identity,
                            includeStatusChange: false
                        )
                        afterStagedFile(fileIndex)
                    } catch {
                        journalFailure = true
                        failed = true
                        failureMessage = failureMessage ?? copyFailureMessage(
                            for: error,
                            phase: .safetyRecord
                        )
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: false
                        )
                        try directory.publish(from: temporary, to: file.target)
                        touched.location = .destination
                        try DurableFileIO.syncRenameDirectories(
                            from: temporary,
                            to: file.target,
                            fullSync: true
                        )
                        touched.identity = try verifiedIdentity(
                            matching: identity,
                            at: file.target
                        )
                        if file.preparedContents != nil {
                            try writer.requirePreparedContent(
                                at: fileIndex,
                                fileURL: file.target
                            )
                        }
                    } catch {
                        failureMessage = failureMessage ?? copyFailureMessage(
                            for: error,
                            phase: .publishingDestination
                        )
                        if let identity = touched.identity {
                            let reconciled = reconcileExportRename(
                                expectedIdentity: identity,
                                source: temporary,
                                destination: file.target,
                                sourceLocation: .temporary(temporary),
                                destinationLocation: .destination
                            )
                            touched.location = reconciled.location
                            touched.identity = reconciled.identity
                        } else {
                            touched.location = .ambiguous
                        }
                        failed = true
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        // The source was revalidated after copyItem and before
                        // the durable staged checkpoint. Do not consult it again:
                        // an HDD can be ejected after a valid copy has completed,
                        // and that must not turn success into destructive rollback.
                        try requireIdentity(
                            identity,
                            at: file.target,
                            includeStatusChange: false
                        )
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.target,
                            expectedIdentity: identity,
                            includeStatusChange: false
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                        failureMessage = failureMessage ?? copyFailureMessage(
                            for: error,
                            phase: .safetyRecord
                        )
                    }
                }
                touchedForItem.append(touched)
                if case .destination = touched.location {
                    byteReporter.advance(by: file.transferByteCount)
                }
                reporter.advance()
                if failed { break }
            }
            if attempted < item.files.count {
                reporter.advance(by: item.files.count - attempted)
            }

            if failed {
                if !cancelled {
                    xmpSummary?.recordFailures(in: [item])
                }
                var rollbackFailed = false
                for touched in touchedForItem.reversed() {
                    if !rollbackCopy(
                        touched,
                        temporary: writer.temporaryURL(at: touched.index),
                        fileManager: fm
                    ) {
                        rollbackFailed = true
                    } else {
                        if case .destination = touched.location {
                            byteReporter.retract(by: touched.file.transferByteCount)
                        }
                        if (try? writer.mark(.rolledBack, fileAt: touched.index)) == nil {
                            journalFailure = true
                        }
                    }
                }
                if !cancelled {
                    failedPhotos += item.movedItemIDs.count
                }
                if rollbackFailed { inconsistentPhotos += 1 }
                if cancelled { break }
                if sourceUnavailable {
                    xmpSummary?.recordFailures(
                        in: plan.items.suffix(from: itemOffset + 1)
                    )
                    failedPhotos += plan.photoCount(from: itemOffset + 1)
                    break itemLoop
                }
                if rollbackFailed || journalFailure {
                    xmpSummary?.recordFailures(
                        in: plan.items.suffix(from: itemOffset + 1)
                    )
                    failedPhotos += plan.photoCount(from: itemOffset + 1)
                    break itemLoop
                }
            } else {
                copied += touchedForItem.count
                for touched in touchedForItem {
                    xmpSummary?.record(touched.file)
                }
            }
        }
        if !cancelled { reporter.finish() }
        if !cancelled, failedPhotos == 0, inconsistentPhotos == 0,
           !journalFailure {
            byteReporter.finish()
        }
        let journalFinalized = FileOperationJournal.finalize(
            writer,
            operationIsConsistent: inconsistentPhotos == 0
        )
        if !journalFinalized {
            journalFailure = true
            failureMessage = failureMessage
                ?? L10n.text("Louppe could not seal the completed file-safety record")
        }
        return CopyResult(
            copiedFiles: copied,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos,
            cancelled: cancelled,
            cancellationReason: observedCancellationReason,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized,
            failureMessage: failureMessage,
            xmpSummary: xmpSummary
        )
    }

    static func move(
        _ items: [PhotoItem],
        to destination: URL,
        xmpPlan: XMPExportPreparedPlan? = nil,
        preparedPlan: Plan? = nil,
        destinationBinding: DurableFileIO.DirectoryBinding? = nil,
        journalDirectory: URL? = nil,
        journalKind: FileOperationJournal.Kind = .exportMove,
        directorySyncPolicy: DurableFileIO.DirectorySyncPolicy = .required,
        renameStrategy: DurableFileIO.NoOverwriteRenameStrategy =
            .exclusivePOSIX,
        prepareDestinationDirectories: @escaping () throws -> Void = {},
        sourceFolderIdentity: SessionPersistence.SourceFolderIdentity? = nil,
        afterMoveDirectoriesOpened: () -> Void = {},
        progress: @escaping Progress,
        byteProgress: @escaping ByteProgress = { _, _ in }
    ) -> MoveResult {
        var xmpSummary = xmpPlan.map(XMPResultSummary.init(plan:))
        // Defense in depth: the dialog preflight explains this limitation,
        // while the worker independently refuses any caller that would make
        // FileManager perform an implicit, uncheckpointed copy/delete move.
        guard journalKind != .exportMove
                || ExportDestinationValidator.moveCanUseAtomicRename(
                    items: items,
                    destination: destination
                ) else {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: false,
                requiresRecovery: false,
                failureMessage: L10n.text("Move requires the source and destination to be on the same storage volume"),
                xmpSummary: xmpSummary
            )
        }
        let fm = FileManager()
        let sourceFiles = items.flatMap(\.individualFiles)
        let sourcePathPairs = sourceFiles.compactMap { file in
            FileOperationJournal.exactPathBytes(for: file.url).map {
                ($0, file)
            }
        }
        let sourceFilesByPath = Dictionary(
            sourcePathPairs,
            uniquingKeysWith: { first, _ in first }
        )
        guard sourcePathPairs.count == sourceFiles.count,
              sourceFilesByPath.count == sourceFiles.count else {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: L10n.text("Louppe could not preserve the exact source paths safely"),
                xmpSummary: xmpSummary
            )
        }
        let plan: Plan
        do {
            plan = try preparedPlan ?? makePlan(
                    for: items,
                    in: destination,
                    xmpPlan: xmpPlan,
                    mode: .move,
                    destinationBinding: destinationBinding
                )
        } catch {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .planning
                ),
                xmpSummary: xmpSummary
            )
        }
        if preparedPlan != nil,
           !confirmedPlanTargetsRemainAvailable(plan) {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: false,
                requiresRecovery: false,
                failureMessage: L10n.text("A destination name was claimed after confirmation. Review and confirm a fresh export plan."),
                xmpSummary: xmpSummary
            )
        }
        xmpSummary?.recordUnplannedFamilies(plan.unplannedSidecarFamilyCount)
        guard plan.items.allSatisfy({ item in
            item.files.allSatisfy { $0.scannedIdentity != nil }
        }) else {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery: false,
                failureMessage: L10n.text("One or more source files could not be verified before moving"),
                xmpSummary: xmpSummary
            )
        }
        // Source Organization/Rename owns its separately probed ExFAT
        // fallback. Ordinary Export Move needs the same exclusive publication
        // contract as Copy and must refuse unsupported folders before journaling.
        if journalKind == .exportMove {
            do {
                var checkedParents = Set<Data>()
                for file in plan.items.flatMap(\.files) {
                    let parent = try XMPExactFileSystemPath(url: file.target).parent
                    guard checkedParents.insert(parent.bytes).inserted else { continue }
                    let binding = try plan.destinationBindings.first {
                        FileOperationJournal.exactPathsEqual($0.url, parent.url)
                    } ?? DurableFileIO.DirectoryBinding(url: parent.url)
                    try ExportDestinationValidator.requireCollisionSafePublication(at: binding)
                }
            } catch {
                return MoveResult(
                    movedItemIDs: [], movedFiles: 0, failedPhotos: items.count,
                    inconsistentPhotos: 0, journalFailure: false,
                    requiresRecovery: false, failureMessage: error.localizedDescription,
                    xmpSummary: xmpSummary
                )
            }
        }
        let writer: FileOperationJournal.Writer
        do {
            for binding in plan.destinationBindings { try binding.requireCurrentPath() }
            writer = try FileOperationJournal.start(
                kind: journalKind,
                seeds: plan.items.flatMap { item in
                    item.files.map {
                        FileOperationJournal.Seed(
                            itemID: item.itemID,
                            source: $0.source,
                            destination: $0.target,
                            expectedIdentity: $0.scannedIdentity,
                            role: $0.role,
                            expectedSourceDigest: $0.expectedSourceDigest,
                            preparedContentDigest: $0.preparedContents.map {
                                Data(SHA256.hash(data: $0))
                            }
                        )
                    }
                },
                directory: journalDirectory
            )
        } catch {
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: true,
                requiresRecovery:
                    FileOperationJournal.errorRequiresRecovery(error),
                failureMessage: copyFailureMessage(
                    for: error,
                    phase: .safetyRecord
                ),
                xmpSummary: xmpSummary
            )
        }
        do {
            try prepareDestinationDirectories()
            for binding in plan.destinationBindings {
                try binding.requireCurrentPath()
            }
            if let sourceFolderIdentity,
               !sourceFolderIdentity.matches(folder: destination) {
                throw DurableFileIO.DestinationChanged()
            }
        } catch {
            let journalFinalized = FileOperationJournal.finalize(
                writer,
                operationIsConsistent: true
            )
            return MoveResult(
                movedItemIDs: [],
                movedFiles: 0,
                failedPhotos: items.count,
                inconsistentPhotos: 0,
                journalFailure: !journalFinalized,
                requiresRecovery: !journalFinalized,
                failureMessage: L10n.text("No photos were moved. \(error.localizedDescription)"),
                xmpSummary: xmpSummary
            )
        }
        var reporter = ThrottledProgress(total: plan.totalFiles, callback: progress)
        var byteReporter = ThrottledByteProgress(
            total: plan.totalTransferBytes,
            callback: byteProgress
        )
        var movedItemIDs: [String] = []
        var movedFiles = 0
        var failedPhotos = 0
        var inconsistentPhotos = 0
        var journalFailure = false
        var failureMessage: String?
        var globalFileIndex = 0

        var didOpenMoveDirectories = false

        itemLoop: for (itemOffset, item) in plan.items.enumerated() {
            let itemFileIndex = globalFileIndex
            globalFileIndex += item.files.count
            var touchedForItem: [TouchedExportFile] = []
            var failed = false
            var attempted = 0
            for (localFileIndex, file) in item.files.enumerated() {
                let fileIndex = itemFileIndex + localFileIndex
                attempted += 1
                var touched = TouchedExportFile(
                    file: file,
                    index: fileIndex,
                    location: .none,
                    identity: nil
                )
                var moveDirectories: (
                    source: DurableFileIO.BoundDirectory,
                    temporary: DurableFileIO.BoundDirectory,
                    target: DurableFileIO.BoundDirectory
                )?
                // "Moving" a file into the folder it already lives in would
                // only rename the original with a collision suffix.
                if journalKind == .exportMove,
                   ExportDestinationValidator.directoriesReferToSameEntry(
                       file.source.deletingLastPathComponent(),
                       destination
                   ) {
                    failed = true
                    reporter.advance()
                    touchedForItem.append(touched)
                    break
                }
                guard let temporary = writer.temporaryURL(at: fileIndex) else {
                    journalFailure = true
                    failed = true
                    failureMessage = failureMessage
                        ?? L10n.text("Louppe could not reserve a safe temporary path for \(file.source.lastPathComponent).")
                    touchedForItem.append(touched)
                    reporter.advance()
                    break
                }
                do {
                    try writer.mark(.started, fileAt: fileIndex)
                } catch {
                    journalFailure = true
                    failed = true
                    failureMessage = failureMessage ?? moveFailureMessage(
                        for: error,
                        phase: .safetyRecord,
                        filename: file.source.lastPathComponent
                    )
                }
                if !failed {
                    do {
                        // The journal currently puts the temporary beside its
                        // target. Bind all exact parents independently so no
                        // plan-format change can redirect either rename.
                        moveDirectories = try (
                            DurableFileIO.BoundDirectory(
                                .init(url: XMPExactFileSystemPath(url: file.source).parent.url)
                            ),
                            DurableFileIO.BoundDirectory(
                                .init(url: XMPExactFileSystemPath(url: temporary).parent.url)
                            ),
                            DurableFileIO.BoundDirectory(
                                .init(url: XMPExactFileSystemPath(url: file.target).parent.url)
                            )
                        )
                        if !didOpenMoveDirectories {
                            didOpenMoveDirectories = true
                            afterMoveDirectoriesOpened()
                        }
                        for binding in plan.destinationBindings {
                            try binding.requireCurrentPath()
                        }
                        if let sourceFolderIdentity,
                           !sourceFolderIdentity.matches(folder: destination) {
                            throw DurableFileIO.DestinationChanged()
                        }
                    } catch {
                        failed = true
                        failureMessage = failureMessage ?? moveFailureMessage(
                            for: error,
                            phase: .staging,
                            filename: file.source.lastPathComponent
                        )
                    }
                }
                if !failed {
                    if let preparedContents = file.preparedContents {
                        do {
                            if pathEntryExists(file.source) {
                                try writer.requireUnchangedSource(at: fileIndex)
                            } else if file.expectedSourceDigest != nil {
                                throw ExportWorkerError.copiedFileChanged
                            }
                            guard let moveDirectories else {
                                throw DurableFileIO.DestinationChanged()
                            }
                            try moveDirectories.temporary.write(
                                preparedContents, to: temporary
                            )
                            touched.location = .temporary(temporary)
                            touched.identity = try FileOperationJournal
                                .captureIdentity(at: temporary)
                            try writer.requirePreparedContent(
                                at: fileIndex,
                                fileURL: temporary
                            )
                        } catch {
                            if case .none = touched.location {
                                do {
                                    guard let moveDirectories else {
                                        throw DurableFileIO.DestinationChanged()
                                    }
                                    try moveDirectories.temporary.binding
                                        .requireCurrentPath()
                                    if pathEntryExists(temporary) {
                                        let partialIdentity = try FileOperationJournal
                                            .captureIdentity(at: temporary)
                                        try writer.mark(
                                            .started,
                                            fileAt: fileIndex,
                                            identityAt: temporary,
                                            expectedIdentity: partialIdentity,
                                            includeStatusChange: false
                                        )
                                        touched.location = .temporary(temporary)
                                        touched.identity = partialIdentity
                                        touched.isIncompleteCopy = true
                                    }
                                } catch {
                                    journalFailure = true
                                    touched.location = .ambiguous
                                }
                            }
                            failed = true
                            failureMessage = failureMessage
                                ?? moveFailureMessage(
                                    for: error,
                                    phase: .staging,
                                    filename: file.source.lastPathComponent
                                )
                        }
                    } else {
                        var renamedToTemporary = false
                        do {
                            guard let moveDirectories else {
                                throw DurableFileIO.DestinationChanged()
                            }
                            try writer.requireUnchangedSource(at: fileIndex)
                            try moveDirectories.source.move(
                                file.source, to: temporary,
                                in: moveDirectories.temporary,
                                strategy: renameStrategy
                            )
                            renamedToTemporary = true
                            touched.location = .temporary(temporary)
                            try moveDirectories.source.syncRename(
                                to: moveDirectories.temporary,
                                policy: directorySyncPolicy
                            )
                            try moveDirectories.source.binding.requireCurrentPath()
                            try moveDirectories.temporary.binding.requireCurrentPath()
                            touched.identity = try verifiedIdentity(
                                matching: writer.plannedIdentity(at: fileIndex),
                                at: temporary
                            )
                        } catch {
                            if renamedToTemporary {
                                let reconciled = reconcileFirstMoveRename(
                                    writer: writer,
                                    fileIndex: fileIndex,
                                    source: file.source,
                                    temporary: temporary
                                )
                                touched.location = reconciled.location
                                touched.identity = reconciled.identity
                            }
                            failed = true
                            failureMessage = failureMessage
                                ?? moveFailureMessage(
                                    for: error,
                                    phase: .staging,
                                    filename: file.source.lastPathComponent
                                )
                        }
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: file.role != .preparedXMP
                        )
                        if file.role == .preparedXMP {
                            try writer.requirePreparedContent(
                                at: fileIndex,
                                fileURL: temporary
                            )
                        }
                        try writer.mark(
                            .staged,
                            fileAt: fileIndex,
                            identityAt: temporary,
                            expectedIdentity: identity,
                            includeStatusChange: file.role != .preparedXMP
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                        failureMessage = failureMessage ?? moveFailureMessage(
                            for: error,
                            phase: .safetyRecord,
                            filename: file.source.lastPathComponent
                        )
                    }
                }
                if !failed {
                    var renamedToDestination = false
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: temporary,
                            includeStatusChange: file.role != .preparedXMP
                        )
                        guard let moveDirectories else {
                            throw DurableFileIO.DestinationChanged()
                        }
                        try moveDirectories.temporary.move(
                            temporary, to: file.target,
                            in: moveDirectories.target,
                            strategy: renameStrategy
                        )
                        renamedToDestination = true
                        touched.location = .destination
                        try moveDirectories.temporary.syncRename(
                            to: moveDirectories.target,
                            policy: directorySyncPolicy
                        )
                        try moveDirectories.temporary.binding.requireCurrentPath()
                        try moveDirectories.target.binding.requireCurrentPath()
                        touched.identity = try verifiedIdentity(
                            matching: identity,
                            at: file.target
                        )
                        if file.role == .preparedXMP {
                            try writer.requirePreparedContent(
                                at: fileIndex,
                                fileURL: file.target
                            )
                        }
                    } catch {
                        if renamedToDestination,
                           let identity = touched.identity {
                            let reconciled = reconcileExportRename(
                                expectedIdentity: identity,
                                source: temporary,
                                destination: file.target,
                                sourceLocation: .temporary(temporary),
                                destinationLocation: .destination
                            )
                            touched.location = reconciled.location
                            touched.identity = reconciled.identity
                        } else if touched.identity == nil {
                            touched.location = .ambiguous
                        }
                        failed = true
                        failureMessage = failureMessage ?? moveFailureMessage(
                            for: error,
                            phase: .publishing,
                            filename: file.source.lastPathComponent
                        )
                    }
                }
                if !failed {
                    do {
                        guard let identity = touched.identity else {
                            throw ExportWorkerError.missingTouchedIdentity
                        }
                        try requireIdentity(
                            identity,
                            at: file.target,
                            includeStatusChange: file.role != .preparedXMP
                        )
                        try writer.mark(
                            .completed,
                            fileAt: fileIndex,
                            identityAt: file.target,
                            expectedIdentity: identity,
                            includeStatusChange: file.role != .preparedXMP
                        )
                    } catch {
                        journalFailure = true
                        failed = true
                        failureMessage = failureMessage ?? moveFailureMessage(
                            for: error,
                            phase: .safetyRecord,
                            filename: file.source.lastPathComponent
                        )
                    }
                }
                touchedForItem.append(touched)
                if case .destination = touched.location {
                    byteReporter.advance(by: file.transferByteCount)
                }
                reporter.advance()
                if failed { break }
            }
            if attempted < item.files.count {
                reporter.advance(by: item.files.count - attempted)
            }

            if failed {
                xmpSummary?.recordFailures(in: [item])
                // Put a partially moved pair back exactly where it came from.
                var rollbackFailed = false
                for touched in touchedForItem.reversed() {
                    let rolledBack = touched.file.role == .preparedXMP
                        ? rollbackCopy(
                            touched,
                            temporary: writer.temporaryURL(at: touched.index),
                            fileManager: fm
                        )
                        : rollbackMove(
                            touched,
                            fileManager: fm,
                            directorySyncPolicy: directorySyncPolicy,
                            renameStrategy: renameStrategy
                        )
                    if !rolledBack {
                        rollbackFailed = true
                    } else {
                        if case .destination = touched.location {
                            byteReporter.retract(by: touched.file.transferByteCount)
                        }
                        if touched.needsSourceIdentityRefresh {
                            guard let sourcePath = FileOperationJournal
                                .exactPathBytes(for: touched.file.source),
                            let sourceFile = sourceFilesByPath[sourcePath],
                            (try? sourceFile.refreshScannedIdentityFromDisk()) != nil else {
                                rollbackFailed = true
                                continue
                            }
                        }
                        if (try? writer.mark(
                            .rolledBack,
                            fileAt: touched.index
                        )) == nil {
                            journalFailure = true
                        }
                    }
                }
                failedPhotos += item.movedItemIDs.count
                if rollbackFailed { inconsistentPhotos += 1 }
                if rollbackFailed || journalFailure {
                    xmpSummary?.recordFailures(
                        in: plan.items.suffix(from: itemOffset + 1)
                    )
                    failedPhotos += plan.photoCount(from: itemOffset + 1)
                    break itemLoop
                }
            } else {
                let retirementCleanupFailed = touchedForItem
                    .filter { $0.file.role == .retiredXMPSource }
                    .contains { touched in
                        !removeRetiredXMPSource(
                            touched,
                            temporary: writer.temporaryURL(at: touched.index)
                        )
                    }
                // Every media file in this item already reached the
                // destination with a durable completed checkpoint, and
                // recovery preserves a completed Move. Report the photos as
                // moved even when only the old source packet could not be
                // retired: withholding their ids would leave the session
                // holding items whose files are gone from the source folder.
                // The stale packet is exactly what launch recovery re-runs.
                movedItemIDs.append(contentsOf: item.movedItemIDs)
                movedFiles += touchedForItem.count(where: {
                    $0.file.role != .retiredXMPSource
                })
                for touched in touchedForItem {
                    xmpSummary?.record(touched.file)
                }
                if retirementCleanupFailed {
                    inconsistentPhotos += 1
                    journalFailure = true
                    failedPhotos += plan.photoCount(from: itemOffset + 1)
                    break itemLoop
                }
            }
        }
        reporter.finish()
        if failedPhotos == 0, inconsistentPhotos == 0, !journalFailure {
            byteReporter.finish()
        }
        let journalFinalized = FileOperationJournal.finalize(
            writer,
            operationIsConsistent: inconsistentPhotos == 0
        )
        if !journalFinalized {
            journalFailure = true
        }
        return MoveResult(
            movedItemIDs: movedItemIDs,
            movedFiles: movedFiles,
            failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos,
            journalFailure: journalFailure,
            requiresRecovery: inconsistentPhotos > 0 || !journalFinalized,
            failureMessage: failedPhotos > 0 || journalFailure
                ? failureMessage
                    ?? L10n.text("A source, destination, or file-safety checkpoint became unavailable during the move")
                : nil,
            xmpSummary: xmpSummary
        )
    }

    private enum ExportFileLocation {
        case none
        case temporary(URL)
        case destination
        case ambiguous
    }

    private struct TouchedExportFile {
        let file: PlannedFile
        let index: Int
        var location: ExportFileLocation
        var identity: FileOperationJournal.FileIdentity?
        var isIncompleteCopy = false

        var needsSourceIdentityRefresh: Bool {
            guard file.role == .media else { return false }
            switch location {
            case .none, .ambiguous:
                return false
            case .temporary, .destination:
                return true
            }
        }
    }

    /// Once every member in a Move family has a durable completed checkpoint,
    /// retire the old canonical source packet. Its merged replacement is
    /// already at the export destination. The journal's other reserved path
    /// closes the unlink race, and launch recovery repeats this exact cleanup
    /// if the process stops at any point.
    private static func removeRetiredXMPSource(
        _ touched: TouchedExportFile,
        temporary: URL?
    ) -> Bool {
        guard touched.file.role == .retiredXMPSource,
              case .destination = touched.location,
              let temporary,
              let identity = touched.identity else {
            return false
        }
        return removeRecordedPartialCopy(
            artifact: touched.file.target,
            quarantine: temporary,
            artifactIdentity: identity
        )
    }

    private static func rollbackCopy(
        _ touched: TouchedExportFile,
        temporary: URL?,
        fileManager: FileManager
    ) -> Bool {
        let artifact: URL?
        let quarantine: URL?
        switch touched.location {
        case .none:
            artifact = nil
            quarantine = nil
        case .temporary(let url):
            artifact = url
            quarantine = touched.file.target
        case .destination:
            artifact = touched.file.target
            quarantine = temporary
        case .ambiguous:
            return false
        }
        guard let artifact else { return true }
        guard let quarantine,
              let artifactIdentity = touched.identity,
              let sourceIdentity = touched.file.scannedIdentity else {
            return false
        }
        if touched.isIncompleteCopy || touched.file.role == .preparedXMP {
            return removeRecordedPartialCopy(
                artifact: artifact,
                quarantine: quarantine,
                artifactIdentity: artifactIdentity
            )
        }
        return removeVerifiedCopy(
            source: touched.file.source,
            artifact: artifact,
            quarantine: quarantine,
            sourceIdentity: sourceIdentity,
            artifactIdentity: artifactIdentity,
            fileManager: fileManager
        )
    }

    /// A Copy rollback first transfers the candidate between the two paths
    /// already reserved by the immutable journal plan. Re-verifying after that
    /// exclusive rename means a late replacement is preserved, while a crash
    /// still leaves the copy at a pathname recovery already understands.
    private static func removeVerifiedCopy(
        source: URL,
        artifact: URL,
        quarantine: URL,
        sourceIdentity: FileOperationJournal.FileIdentity,
        artifactIdentity: FileOperationJournal.FileIdentity,
        fileManager: FileManager,
        afterComparison: () -> Void = {}
    ) -> Bool {
        guard !FileOperationJournal.exactPathsEqual(
                artifact,
                quarantine
              ),
              pathEntryExists(artifact),
              pathEntryExists(source),
              !pathEntryExists(quarantine) else {
            return false
        }
        do {
            try requireIdentity(
                sourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                artifactIdentity,
                at: artifact,
                includeStatusChange: false
            )
            guard FileOperationJournal.contentsEqual(
                source,
                artifact
            ) else { return false }
            afterComparison()
            // Both halves of the safety proof may have changed during the
            // potentially long byte comparison. The original must still be
            // exact before its duplicate can be removed.
            try requireIdentity(
                sourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                artifactIdentity,
                at: artifact,
                includeStatusChange: false
            )
            try atomicExclusiveRename(from: artifact, to: quarantine)
            try DurableFileIO.syncRenameDirectories(
                from: artifact,
                to: quarantine,
                fullSync: true
            )
            // Rename changes ctime. Capture that new value, prove the
            // remaining stable fields still identify the owned copy, then
            // repeat the potentially long byte comparison. The exact fresh
            // identities must still hold after that second comparison.
            let quarantinedIdentity = try FileOperationJournal
                .captureIdentity(at: quarantine)
            guard FileOperationJournal.identitiesMatch(
                expected: artifactIdentity,
                actual: quarantinedIdentity,
                includeStatusChange: false
            ) else { return false }
            guard FileOperationJournal.contentsEqual(
                source,
                quarantine
            ) else { return false }
            try requireIdentity(
                sourceIdentity,
                at: source,
                includeStatusChange: true
            )
            try requireIdentity(
                quarantinedIdentity,
                at: quarantine,
                includeStatusChange: false
            )
            try DurableFileIO.unlinkRegularFile(at: quarantine)
            try DurableFileIO.syncRemoval(of: quarantine, fullSync: true)
            return !pathEntryExists(artifact) && !pathEntryExists(quarantine)
        } catch {
            return false
        }
    }

    /// Removes a failed `copyItem` artifact only after the `.started`
    /// checkpoint has captured its physical identity. The exclusive rename
    /// closes the replacement race: if another entry appears at the reserved
    /// path, both files are preserved and recovery remains retryable.
    private static func removeRecordedPartialCopy(
        artifact: URL,
        quarantine: URL,
        artifactIdentity: FileOperationJournal.FileIdentity
    ) -> Bool {
        guard !FileOperationJournal.exactPathsEqual(artifact, quarantine),
              pathEntryExists(artifact),
              !pathEntryExists(quarantine) else {
            return false
        }
        do {
            try requireIdentity(
                artifactIdentity,
                at: artifact,
                includeStatusChange: false
            )
            try atomicExclusiveRename(from: artifact, to: quarantine)
            try DurableFileIO.syncRenameDirectories(
                from: artifact,
                to: quarantine,
                fullSync: true
            )
            let quarantinedIdentity = try FileOperationJournal
                .captureIdentity(at: quarantine)
            guard FileOperationJournal.identitiesMatch(
                expected: artifactIdentity,
                actual: quarantinedIdentity,
                includeStatusChange: false
            ) else { return false }
            try requireIdentity(
                quarantinedIdentity,
                at: quarantine,
                includeStatusChange: false
            )
            try DurableFileIO.unlinkRegularFile(at: quarantine)
            try DurableFileIO.syncRemoval(of: quarantine, fullSync: true)
            return !pathEntryExists(artifact) && !pathEntryExists(quarantine)
        } catch {
            return false
        }
    }

#if DEBUG
    static func removeVerifiedCopyForTesting(
        source: URL,
        artifact: URL,
        quarantine: URL,
        sourceIdentity: FileOperationJournal.FileIdentity,
        artifactIdentity: FileOperationJournal.FileIdentity,
        afterComparison: () -> Void
    ) -> Bool {
        removeVerifiedCopy(
            source: source,
            artifact: artifact,
            quarantine: quarantine,
            sourceIdentity: sourceIdentity,
            artifactIdentity: artifactIdentity,
            fileManager: .default,
            afterComparison: afterComparison
        )
    }
#endif

    private static func rollbackMove(
        _ touched: TouchedExportFile,
        fileManager: FileManager,
        directorySyncPolicy: DurableFileIO.DirectorySyncPolicy = .required,
        renameStrategy: DurableFileIO.NoOverwriteRenameStrategy =
            .exclusivePOSIX
    ) -> Bool {
        let movedURL: URL?
        switch touched.location {
        case .none:
            movedURL = nil
        case .temporary(let url):
            movedURL = url
        case .destination:
            movedURL = touched.file.target
        case .ambiguous:
            return false
        }
        guard let movedURL else { return true }
        guard let identity = touched.identity else { return false }
        return restoreMovedFile(
            from: movedURL,
            to: touched.file.source,
            expectedIdentity: identity,
            fileManager: fileManager,
            directorySyncPolicy: directorySyncPolicy,
            renameStrategy: renameStrategy
        )
    }

    /// A touched Move file disappearing from its expected path is
    /// inconsistent, not a successful rollback. Retaining the journal is the
    /// only safe response when a destination directory was renamed/swapped.
    static func restoreMovedFile(
        from movedURL: URL,
        to source: URL,
        expectedIdentity: FileOperationJournal.FileIdentity? = nil,
        fileManager: FileManager = .default,
        directorySyncPolicy: DurableFileIO.DirectorySyncPolicy = .required,
        renameStrategy: DurableFileIO.NoOverwriteRenameStrategy =
            .exclusivePOSIX
    ) -> Bool {
        guard pathEntryExists(movedURL),
              !pathEntryExists(source) else {
            return false
        }
        do {
            if let expectedIdentity {
                try requireIdentity(
                    expectedIdentity,
                    at: movedURL,
                    includeStatusChange: true
                )
            }
            try DurableFileIO.renameWithoutOverwrite(
                from: movedURL,
                to: source,
                strategy: renameStrategy
            )
            try DurableFileIO.syncRenameDirectories(
                from: movedURL,
                to: source,
                fullSync: true,
                policy: directorySyncPolicy
            )
            if let expectedIdentity {
                try requireIdentity(
                    expectedIdentity,
                    at: source,
                    includeStatusChange: false
                )
            }
            return !pathEntryExists(movedURL)
        } catch {
            return false
        }
    }

    private struct ReconciledLocation {
        let location: ExportFileLocation
        let identity: FileOperationJournal.FileIdentity?
    }

    /// Determines where an inode-preserving rename landed after an error. An
    /// unrelated file racing into the other path is preserved; only the path
    /// that still carries the exact operation-owned identity is rolled back.
    private static func reconcileExportRename(
        expectedIdentity: FileOperationJournal.FileIdentity,
        source: URL,
        destination: URL,
        sourceLocation: ExportFileLocation,
        destinationLocation: ExportFileLocation
    ) -> ReconciledLocation {
        let sourceIdentity = matchingIdentity(
            expectedIdentity,
            at: source,
            includeStatusChange: true
        )
        let destinationIdentity = matchingIdentity(
            expectedIdentity,
            at: destination,
            includeStatusChange: false
        )
        switch (sourceIdentity, destinationIdentity) {
        case (.some(let identity), .none):
            return ReconciledLocation(
                location: sourceLocation,
                identity: identity
            )
        case (.none, .some(let identity)):
            return ReconciledLocation(
                location: destinationLocation,
                identity: identity
            )
        default:
            return ReconciledLocation(location: .ambiguous, identity: nil)
        }
    }

    private static func reconcileFirstMoveRename(
        writer: FileOperationJournal.Writer,
        fileIndex: Int,
        source: URL,
        temporary: URL
    ) -> ReconciledLocation {
        guard let planned = try? writer.plannedIdentity(at: fileIndex) else {
            return ReconciledLocation(location: .ambiguous, identity: nil)
        }
        let sourceIdentity = matchingIdentity(
            planned,
            at: source,
            includeStatusChange: true
        )
        let temporaryIdentity = matchingIdentity(
            planned,
            at: temporary,
            includeStatusChange: false
        )
        switch (sourceIdentity, temporaryIdentity) {
        case (.some, .none):
            return ReconciledLocation(location: .none, identity: nil)
        case (.none, .some(let identity)):
            return ReconciledLocation(
                location: .temporary(temporary),
                identity: identity
            )
        default:
            return ReconciledLocation(location: .ambiguous, identity: nil)
        }
    }

    private static func verifiedIdentity(
        matching expected: FileOperationJournal.FileIdentity,
        at url: URL
    ) throws -> FileOperationJournal.FileIdentity {
        let actual = try FileOperationJournal.captureIdentity(at: url)
        guard FileOperationJournal.identitiesMatch(
            expected: expected,
            actual: actual,
            includeStatusChange: false
        ) else {
            throw ExportWorkerError.copiedFileChanged
        }
        return actual
    }

    private static func matchingIdentity(
        _ expected: FileOperationJournal.FileIdentity,
        at url: URL,
        includeStatusChange: Bool
    ) -> FileOperationJournal.FileIdentity? {
        guard let actual = try? FileOperationJournal.captureIdentity(at: url),
              FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: actual,
                includeStatusChange: includeStatusChange
              ) else {
            return nil
        }
        return actual
    }

    private static func requireIdentity(
        _ expected: FileOperationJournal.FileIdentity,
        at url: URL,
        includeStatusChange: Bool
    ) throws {
        try FileOperationJournal.requireIdentity(
            expected,
            at: url,
            includeStatusChange: includeStatusChange
        )
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        var info = Darwin.stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.lstat(path, &info) == 0
        }
    }

    /// The photographer confirmed these exact names. Replanning here would
    /// execute a different operation than the one shown; beginning file work
    /// would also create an avoidable rollback boundary. A later race remains
    /// protected by every exclusive publish rename.
    private static func confirmedPlanTargetsRemainAvailable(
        _ plan: Plan
    ) -> Bool {
        plan.items.allSatisfy { item in
            item.files.allSatisfy { !pathEntryExists($0.target) }
        }
    }

    /// `FileManager.copyItem` can return as soon as a sleeping Mac wakes,
    /// several seconds before an external source volume has mounted again.
    /// Retry one untouched temporary copy after the exact scanned source
    /// identity reappears. A partial temporary artifact is never guessed away:
    /// it stays under the journal's conservative recovery rules.
    private static func copySourceWithReconnectRetry(
        writer: FileOperationJournal.Writer,
        fileIndex: Int,
        source: URL,
        temporary: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        fileCopier: @escaping FileCopier
    ) throws {
        do {
            try writer.requireUnchangedSource(at: fileIndex)
            try fileCopier(source, temporary)
            return
        } catch {
            guard isTransientSourceError(error),
                  !pathEntryExists(temporary) else {
                throw error
            }
            // A missing individual file on a still-mounted volume is not a
            // remount delay (it may have been moved or replaced). Only wait
            // when the planned volume root itself disappeared. A source that
            // is still present may retry one transient read/I/O error now.
            if !pathEntryExists(source),
               !plannedSourceVolumeIsUnavailable(
                    writer: writer,
                    fileIndex: fileIndex
               ) {
                throw error
            }
        }

        try requireSourceAfterReconnect(
            writer: writer,
            fileIndex: fileIndex,
            source: source,
            allowCancellation: true,
            isCancelled: isCancelled
        )
        do {
            try fileCopier(source, temporary)
        } catch {
            if isTransientSourceError(error) {
                throw SourceReconnectError.unavailable(error)
            }
            throw error
        }
    }

    /// Waits for at most one minute of *awake* polling. `Thread.sleep` pauses
    /// with the process during system sleep, so closing the lid for a long time
    /// does not consume the remount grace period before the Mac wakes.
    private static func requireSourceAfterReconnect(
        writer: FileOperationJournal.Writer,
        fileIndex: Int,
        source: URL,
        allowCancellation: Bool,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        var lastError: Error?
        for attempt in 0..<240 {
            do {
                try writer.requireUnchangedSource(at: fileIndex)
                return
            } catch {
                lastError = error
                // A file exists but does not match the scan identity. This is
                // a replacement, not a slow removable-volume remount.
                if pathEntryExists(source) { throw error }
                // Likewise, a missing individual path on an otherwise mounted
                // volume is a real session change, not a reconnect window.
                if !plannedSourceVolumeIsUnavailable(
                    writer: writer,
                    fileIndex: fileIndex
                ) {
                    throw error
                }
            }
            if allowCancellation, isCancelled() {
                throw SourceReconnectError.cancelled
            }
            if attempt < 239 {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw SourceReconnectError.unavailable(
            lastError ?? ExportWorkerError.missingTouchedIdentity
        )
    }

    private static func plannedSourceVolumeIsUnavailable(
        writer: FileOperationJournal.Writer,
        fileIndex: Int
    ) -> Bool {
        guard let identity = try? writer.plannedIdentity(at: fileIndex) else {
            return false
        }
        return !pathEntryExists(
            URL(fileURLWithPath: identity.volumeRootPath, isDirectory: true)
        )
    }

    private static func isUnavailableSourceError(_ error: Error) -> Bool {
        if case SourceReconnectError.unavailable = error { return true }
        return false
    }

    private static func isTransientSourceError(_ error: Error) -> Bool {
        if let journalError = error as? FileOperationJournal.JournalError,
           case .missingFileIdentity = journalError {
            return true
        }
        for candidate in errorChain(error) {
            if candidate.domain == NSPOSIXErrorDomain,
               [ENOENT, EIO, ENXIO, ENODEV, ESTALE, ETIMEDOUT]
                .contains(Int32(candidate.code)) {
                return true
            }
            if candidate.domain == NSCocoaErrorDomain,
               [NSFileReadUnknownError, NSFileReadNoSuchFileError]
                .contains(candidate.code) {
                return true
            }
        }
        return false
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let candidate = current,
              seen.insert(ObjectIdentifier(candidate)).inserted {
            result.append(candidate)
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private enum CopyFailurePhase {
        case planning
        case readingSource
        case publishingDestination
        case safetyRecord
    }

    private enum MoveFailurePhase {
        case staging
        case publishing
        case safetyRecord
    }

    private static func moveFailureMessage(
        for error: Error,
        phase: MoveFailurePhase,
        filename: String
    ) -> String {
        let chain = errorChain(error)
        let posixCodes = Set(chain.compactMap { candidate -> Int? in
            candidate.domain == NSPOSIXErrorDomain ? candidate.code : nil
        })
        if posixCodes.contains(Int(EEXIST)) {
            return L10n.text("The destination for \(filename) was claimed after confirmation. Louppe stopped without overwriting it.")
        }
        if !posixCodes.isDisjoint(with: [Int(ENOTSUP), Int(EOPNOTSUPP)]) {
            return L10n.text("This storage does not support the collision-safe rename needed to move \(filename).")
        }
        if posixCodes.contains(Int(ENOSPC)) {
            return L10n.text("The storage ran out of free space while moving \(filename).")
        }
        if !posixCodes.isDisjoint(with: [Int(EACCES), Int(EPERM), Int(EROFS)]) {
            return L10n.text("The storage stopped allowing changes while Louppe was moving \(filename).")
        }
        switch phase {
        case .staging:
            return L10n.text("Louppe could not safely begin moving \(filename): \(error.localizedDescription)")
        case .publishing:
            return L10n.text("Louppe could not place \(filename) at its confirmed destination: \(error.localizedDescription)")
        case .safetyRecord:
            return L10n.text("Louppe could not update the file-safety record for \(filename): \(error.localizedDescription)")
        }
    }

    private static func copyFailureMessage(
        for error: Error,
        phase: CopyFailurePhase
    ) -> String {
        if isUnavailableSourceError(error) {
            return L10n.text("The source drive disconnected and did not remount in time")
        }
        let chain = errorChain(error)
        if chain.contains(where: {
            $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)
        }) || chain.contains(where: {
            $0.domain == NSCocoaErrorDomain
                && $0.code == NSFileWriteOutOfSpaceError
        }) {
            return L10n.text("The destination ran out of free space")
        }
        if chain.contains(where: {
            $0.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EPERM), Int(EROFS)].contains($0.code)
        }) {
            return phase == .readingSource
                ? L10n.text("The source file could no longer be read")
                : L10n.text("The destination could no longer be written")
        }
        switch phase {
        case .planning:
            return L10n.text("Louppe could not create a safe export plan: \(error.localizedDescription)")
        case .readingSource:
            return L10n.text("A source file could not be copied: \(error.localizedDescription)")
        case .publishingDestination:
            return L10n.text("A completed copy could not be published at the destination: \(error.localizedDescription)")
        case .safetyRecord:
            return L10n.text("Louppe could not advance its durable file-safety record: \(error.localizedDescription)")
        }
    }

    private enum SourceReconnectError: Error {
        case cancelled
        case unavailable(Error)
    }

    private enum ExportWorkerError: Error {
        case missingTouchedIdentity
        case copiedFileChanged
        case couldNotReserveRetirementPath
    }

    /// Exclusive POSIX rename is the Move correctness boundary: unlike
    /// `FileManager.moveItem`, it can never fall back to copy-then-delete.
    /// `RENAME_EXCL` also closes the collision-plan race: if anything appears
    /// at the target (including a rollback source), both files stay intact.
    /// A changed mount fails with `EXDEV`.
    static func atomicExclusiveRename(
        from source: URL,
        to destination: URL
    ) throws {
        try DurableFileIO.atomicExclusiveRename(
            from: source,
            to: destination
        )
    }

    /// `DSC_0001.NEF` → `DSC_0001 (1).NEF` when the name is already taken.
    static func collisionFreeURL(for filename: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var counter = 0
        while true {
            let candidateName = suffixedFilename(filename, suffix: counter)
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    private static func canonicalXMPFilename(
        for mediaFilename: String,
        existing: XMPExactFileSystemPath?
    ) -> String {
        let stem = (mediaFilename as NSString).deletingPathExtension
        let extensionText = existing.map(xmpExtension(of:)) ?? ".xmp"
        return stem + extensionText
    }

    private static func xmpExtension(
        of path: XMPExactFileSystemPath
    ) -> String {
        path.url.lastPathComponent.hasSuffix(".XMP") ? ".XMP" : ".xmp"
    }

    private static func retirementURL(beside source: URL) throws -> URL {
        for _ in 0..<16 {
            let name = ".louppe-xmp-\(UUID().uuidString.lowercased()).retired"
            let candidate = try FileOperationJournal
                .appendingPathComponentExactly(
                    name,
                    to: source.deletingLastPathComponent()
                )
            if !pathEntryExists(candidate) { return candidate }
        }
        throw ExportWorkerError.couldNotReserveRetirementPath
    }

    private static func suffixedFilename(_ filename: String, suffix: Int) -> String {
        guard suffix > 0 else { return filename }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
    }

    /// A conservative case-fold prevents in-batch collisions on normal
    /// case-insensitive macOS volumes. On a case-sensitive destination this
    /// may choose an unnecessary suffix, but never an unsafe duplicate.
    private static func normalizedReservationName(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

/// Coalesces transfer-byte progress for Export without changing the existing
/// physical-file progress contract shared with Clean Up. A rollback reports
/// immediately so the visible amount never claims a safely removed copy.
private struct ThrottledByteProgress {
    let total: Int64
    let callback: ExportWorker.ByteProgress
    private(set) var completed: Int64 = 0
    private var lastReport = Date.distantPast

    init(total: Int64, callback: @escaping ExportWorker.ByteProgress) {
        self.total = max(0, total)
        self.callback = callback
    }

    mutating func advance(by amount: Int64) {
        let amount = max(0, amount)
        let (sum, overflowed) = completed.addingReportingOverflow(amount)
        completed = min(overflowed ? Int64.max : sum, total)
        reportIfNeeded(force: completed == total)
    }

    mutating func retract(by amount: Int64) {
        completed = max(0, completed - max(0, amount))
        reportIfNeeded(force: true)
    }

    mutating func finish() {
        guard completed != total else { return }
        completed = total
        reportIfNeeded(force: true)
    }

    private mutating func reportIfNeeded(force: Bool) {
        guard total > 0 else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.1 else { return }
        callback(completed, total)
        lastReport = now
    }
}
