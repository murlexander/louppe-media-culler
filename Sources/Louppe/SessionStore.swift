import Foundation
import AppKit
import Combine

enum ViewMode: String, CaseIterable, Sendable {
    case gallery
    case grid
}

enum AppPhase {
    case welcome
    case scanning(found: Int)
    case ready
}

enum ZoomMode {
    case fit      // fill the pane
    case actual   // 100%, scrollable
    case small    // phone-sized preview
}

enum DuplicateBurstAnalysisState: Equatable, Sendable {
    case idle
    case analyzing
    case ready
}

/// One source of truth for filesystem operations that must not overlap or be
/// interrupted by Quit, folder replacement, or updater installation.
enum FileOperationKind: Equatable, Sendable {
    case cleanUp
    case exportCopy
    case exportMove
    case organizeSource
    case renameSource
}

enum SessionEmptyReason: Equatable, Sendable {
    case trashedUndoable
    case movedOut
    case unavailableAfterFailedRestore
}

enum XMPPublicationLifecycleState: Equatable, Sendable {
    case idle
    case preflighting(done: Int, total: Int)
    case awaitingConfirmation(XMPPublicationPlan)
    case publishing(done: Int, total: Int)
    case cancelling
    case finished(XMPPublicationResult)
    case failed(String)
}

enum XMPConflictResolutionChoice: String, Equatable, Hashable, Sendable {
    case skip
    case useRAW
    case useJPEG
}

/// Freeze mutable file metadata at the save boundary. The heavier entry and
/// retained-file reconciliation can then run without occupying the UI actor.
struct SessionSnapshotCapture: Sendable {
    struct File: Sendable {
        let metadata: PhotoFileMetadataSnapshot
        let identity: FileOperationJournal.FileIdentity?
    }

    let sourcePath: String
    let files: [File]
    let retainedEntries: [SessionEntry]
    let originPaths: [String: Data]
    let contentProofs: [String: SessionContentProof]
    let recoveryEntries: [SessionRecoveryEntry]

    @MainActor init(
        sourcePath: String,
        items: [PhotoItem],
        retainedEntries: [SessionEntry],
        originPaths: [String: Data],
        contentProofs: [String: SessionContentProof] = [:],
        recoveryEntries: [SessionRecoveryEntry] = []
    ) {
        var files = [File]()
        files.reserveCapacity(items.count)
        for item in items {
            files.append(File(
                metadata: item.primaryFile.metadataSnapshot,
                identity: item.primaryFile.scannedIdentity
            ))
            if let paired = item.pairedFile {
                files.append(File(
                    metadata: paired.metadataSnapshot,
                    identity: paired.scannedIdentity
                ))
            }
        }
        self.sourcePath = sourcePath
        self.files = files
        self.retainedEntries = retainedEntries
        self.originPaths = originPaths
        self.contentProofs = contentProofs
        self.recoveryEntries = recoveryEntries
    }

    func makeSession() -> SessionFile {
        var entries = [SessionEntry]()
        entries.reserveCapacity(files.count + retainedEntries.count)
        var currentIDs = Set<String>()
        currentIDs.reserveCapacity(files.count)
        for file in files {
            let metadata = file.metadata
            currentIDs.insert(metadata.fileID)
            entries.append(SessionEntry(
                filename: metadata.fileID,
                pairedFilename: nil,
                rating: metadata.rating.rawValue,
                ratedAt: metadata.ratedAt,
                stars: metadata.starRating,
                starsChangedAt: metadata.starsChangedAt,
                colorLabel: metadata.colorLabel,
                colorChangedAt: metadata.colorChangedAt,
                fileIdentity: file.identity,
                contentSHA256: contentProofs[metadata.fileID].flatMap {
                    $0.identity == file.identity ? $0.sha256 : nil
                },
                organizationOriginFolderPathBytes: originPaths[metadata.fileID]
            ))
        }
        for entry in retainedEntries where !currentIDs.contains(entry.filename) {
            entries.append(entry)
        }
        return SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: sourcePath,
            scannedAt: Date(),
            entries: entries,
            fileIDEncoding: .percentEncodedFileSystemPath,
            recoveryEntries: recoveryEntries.isEmpty ? nil : recoveryEntries
        )
    }
}

struct XMPConflictResolutionRequest: Equatable, Sendable {
    let conflict: XMPSameStemConflictDescriptor
    let choice: XMPConflictResolutionChoice
}

struct XMPConflictResolutionOutcome: Equatable, Sendable {
    let appliedConflictIDs: [String]
    let staleConflictIDs: [String]
    let ineligibleConflictIDs: [String]
    let skippedConflictIDs: [String]

    var appliedCount: Int { appliedConflictIDs.count }
    var hasRejectedChoices: Bool {
        !staleConflictIDs.isEmpty || !ineligibleConflictIDs.isEmpty
    }
}

/// The app's single source of truth: the loaded session (photos + ratings),
/// navigation, undo, view state, and persistence to the sidecar file.
@MainActor
final class SessionStore: ObservableObject {
    @Published var phase: AppPhase = .welcome {
        didSet { if sourceFolder != nil { startQualityCueAnalysis() } }
    }
    @Published var items: [PhotoItem] = [] {
        didSet {
            cachedSelectionSummary = nil
            preparedIndex.invalidateItemOrder()
            itemStructureNeedsRebuild = true
            invalidateQualityCueAnalysis()
        }
    }
    @Published var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                videoPlayback.stop()
                if needsQualityCueMeasurement(at: currentIndex) { wakeQualityCueRest() }
            }
        }
    }
    @Published var viewMode: ViewMode = .gallery
    @Published var showMetadataPanel = true
    @Published var showBrowser = true
    @Published var zoomMode: ZoomMode = .fit
    @Published private(set) var photoZoomScale: CGFloat = 1
    @Published private(set) var fittedPhotoZoomScale: CGFloat?
    private var fittedPhotoZoomRevision: PhotoContentRevision?
    private var fittedPhotoZoomMode: ZoomMode?
    private var lastGestureZoomPublication: CFAbsoluteTime = 0
    @Published var showClippingWarnings = false
    let actualSizeViewport = ActualSizeViewport()
    @Published var gridThumbSize: CGFloat = 170
    /// Number of adaptive columns currently visible in the Grid view.
    /// GridView updates this from the actual available window width.
    // Navigation reads this value, but no view renders it. Publishing it would
    // force a redundant second grid redraw after every resize/thumbnail zoom.
    private(set) var gridColumnCount = 1
    @Published var isExportPresented = false
    @Published var exportKeepersRequested = false
    @Published var isOrganizePresented = false
    @Published var isRenamePresented = false
    @Published private(set) var fileRenamingPresentationMode:
        FileRenamingPresentationMode = .metadata
    @Published private(set) var sourceOrganizationLaunchConfiguration:
        SourceOrganizationConfiguration?
    /// The searchable Command Palette. Its modal text field owns normal
    /// typing while the photo session remains unchanged behind it.
    @Published var isActionPalettePresented = false
    @Published var isEarlyUserFeedbackPresented = false
    @Published var isFilterPresented = false
    @Published var isSortPresented = false
    @Published var isReviewStatusPresented = false
    private var filterSearchFocusRequestGeneration: UInt64 = 0
    private var fulfilledFilterSearchFocusRequestGeneration: UInt64 = 0
    /// Whether same-named RAW and JPEG files are reviewed and acted on as one
    /// photo item. A fresh store starts with the safer per-file projection;
    /// the photographer can opt into pair-wide actions for this app lifetime.
    @Published private(set) var rawJPEGPairingMode: RawJPEGPairingMode = .separate
    @Published var pairingMetadataError: String?
    /// The first transition to separate review may read metadata from hidden
    /// JPEG partners. The current session remains visible while this is true.
    @Published private(set) var isChangingRawJPEGPairingMode = false
    /// The "Divide into groups" switch at the end of the sort popover. One
    /// global setting: off hides every divider whatever the sort key is.
    @Published var isGroupingEnabled = true {
        didSet {
            if isGroupingEnabled != oldValue { applyFilter() }
        }
    }
    /// An opt-in review-only projection over the ordinary filtered session.
    /// It is intentionally separate from sort grouping: the photographer can
    /// always leave it and return to the exact normal order in one action.
    @Published private(set) var groupedReviewMode: DuplicateBurstAnalysis.ReviewMode = .off
    @Published private(set) var duplicateBurstAnalysisState: DuplicateBurstAnalysisState = .idle
    /// A perceptual hash distance. Lower values are stricter; a match is
    /// always labelled as likely rather than certain in the interface.
    @Published private(set) var visualSimilarityDistance = 8
    /// Consecutive still-photo capture times at or below this gap form one
    /// burst. Videos can still be found as exact byte duplicates, but are not
    /// inferred as still-photo bursts.
    static let burstGroupingIntervalKey = "review.burstGroupingInterval"
    @Published private(set) var burstGroupingInterval: TimeInterval = 2
    @Published private(set) var qualityCuePreferences = CameraQualityWarningPreferences()
    // Publish coherent batches through objectWillChange, avoiding the measured
    // quadratic insertion cost of a growing @Published evidence dictionary.
    private(set) var qualityCueEvidence: [String: QualityCueEvidence] = [:]
    private(set) var qualityCueCheckingIDs: Set<String> = []
    @Published private(set) var isQualityCueAnalysisPaused = false
    private let qualityCueMeasurement: @Sendable (PhotoItem) async -> QualityCueEvidence
    private var qualityCueTask: Task<Void, Never>?
    private var qualityCueTaskID: UUID?
    private var qualityCueRestartRequested = false
    private var qualityCueFilterNeedsRefresh = false
    // One byte per item, aligned to physical item order rather than sort order.
    // The prepared index borrows this only during a synchronous projection;
    // retaining another copy would make each accepted evidence edit copy it.
    private var qualityCueMatchCache: [QualityCueMatch]?
    private var qualityCueUserPaused = false
    private var qualityCueRestTask: Task<Void, Never>?
    private var qualityCueInterestGeneration: UInt64 = 0
    private var qualityCueSelectionOrder: [Int]?
    private var qualityCueSelectionCursor = 0
    private let qualityCueResources: @Sendable () -> QualityCueWorkPolicy.Resources
    private let qualityCueRest: @Sendable (Duration) async -> Void
    #if DEBUG
    private(set) var qualityCueSelectionProbesForTesting = 0
    private(set) var qualityCueMatchBuildsForTesting = 0
    private(set) var qualityCueMatchUpdatesForTesting = 0
    #endif
    private var qualityCueGeneration: UInt64 = 0
    private var qualityCueCursor = 0
    private var qualityCuePhotoCount = 0
    private var qualityCueMeasuredCount = 0
    private var qualityCueInterestIDs: [String] = []
    private var qualityCuePreferencesObserver: AnyCancellable?

    /// In-flight big-photo decodes (a count, so overlapping loads during fast
    /// arrow-key navigation can't blank the spinner early). The toolbar shows
    /// a small spinner while it's above zero.
    @Published var fullImageLoads = 0
    @Published private(set) var photoRepresentation: PhotoRepresentation = .preview
    private var photoRepresentationRevision: PhotoContentRevision?

    var currentPhotoRepresentation: PhotoRepresentation? {
        photoRepresentationRevision == currentItem?.contentRevision ? photoRepresentation : nil
    }

    func reportPhotoRepresentation(_ representation: PhotoRepresentation, revision: PhotoContentRevision) {
        guard currentItem?.contentRevision == revision else { return }
        let changed = photoRepresentationRevision != revision || photoRepresentation != representation
        photoRepresentationRevision = revision
        if changed { photoRepresentation = representation }
    }
    @Published var scanError: String?
    /// A legacy folder-path mismatch can be acknowledged only for the exact
    /// sidecar revision that produced the current welcome-screen message.
    @Published private(set) var canOpenMismatchedSessionAnyway = false
    private var pendingLegacySidecarRelocationAuthorization:
        SessionPersistence.LegacySidecarRelocationAuthorization?
    /// A current-schema session can safely refuse same-path replacement
    /// ratings while still letting the photographer explicitly start over.
    @Published private(set) var canOpenIdentityConflictAsNewSession = false
    @Published private(set) var emptySessionReason: SessionEmptyReason?
    /// A non-blocking warning when ratings are safe only in Louppe's backup,
    /// or are not currently persisted anywhere. A successful sidecar write
    /// clears it automatically.
    @Published private(set) var persistenceWarning: String?
    private var persistenceRejectedInvalidSnapshot = false
    /// Filename-only schema 1–3 ratings migrate automatically when every
    /// saved filename is still present in its original folder. Missing or
    /// unowned legacy entries require an explicit choice before anything is
    /// saved.
    @Published private(set) var isLegacySessionMigrationConfirmationPresented = false
    @Published private(set) var legacySessionMigrationMissingFileCount = 0
    @Published private(set) var legacySessionMigrationUsesUnownedBackup = false
    /// Schema-4 ratings whose physical files were absent during the latest
    /// scan. They remain in subsequent snapshots until the exact file returns
    /// or Louppe itself explicitly removes that file from a live session.
    /// This prevents a temporarily disconnected/moved original from losing
    /// its decision merely because another photo triggered an automatic save.
    private var retainedMissingSessionEntries: [SessionEntry] = []
    @Published private(set) var sessionRecoveryEntries: [SessionRecoveryEntry] = []
    @Published var isSessionRecoveryPresented = false
    @Published private(set) var isSessionRecoveryNoticeDismissed = false
    @Published private(set) var sessionContentCheck: SessionContentCheckState = .idle
    @Published private(set) var automaticallyRestoredSessionFiles = 0
    private var sessionContentProofs: [String: SessionContentProof] = [:]
    private var sessionContentCapturedProofs: [String: SessionContentProof] = [:]
    private var sessionContentFailures = Set<String>()
    private var sessionRecoveryConfirmations = Set<UUID>()
    private var sessionRecoveryAttemptedIDs = Set<UUID>()
    private var sessionRecoveryFileIDs: [UUID: String] = [:]
    private var sessionRecoveryRecordIndicesByFileID: [String: [Int]] = [:]
    private var sessionContentPendingFileIDs = Set<String>()
    private let sessionContentVerification: @Sendable (PhotoFile, SessionContentProof?) async throws -> SessionContentProof
    private var sessionContentTask: Task<Void, Never>?
    private var sessionContentGeneration: UInt64 = 0
    private var sessionContentChecksPaused = false
    var canRetryPersistence: Bool {
        let hasLiveSession: Bool
        if sourceFolder != nil,
           persistenceAccess != nil,
           case .ready = phase,
           !isLegacySessionMigrationConfirmationPresented {
            hasLiveSession = true
        } else {
            hasLiveSession = false
        }
        return persistenceWarning != nil
            && !persistenceRejectedInvalidSnapshot
            && activePersistenceSaveCount == 0
            && (hasLiveSession || retrySaveRequest != nil)
    }
    @Published var recentFolders: [URL] = []
    let videoPlayback = VideoPlaybackController()

    /// The toolbar filter. Views only render `visibleIndices`; `items` stays
    /// the full list so ratings and the sidecar are never affected by filtering.
    @Published var filter = PhotoFilter() {
        didSet {
            guard filter != oldValue else { return }
            var newNonSearch = filter
            var oldNonSearch = oldValue
            newNonSearch.searchText = ""
            oldNonSearch.searchText = ""
            if newNonSearch == oldNonSearch {
                scheduleSearchFilter()
            } else {
                filterDebounce?.cancel()
                filterDebounce = nil
                applyFilter()
            }
        }
    }
    /// The toolbar sort menu. Reorders `visibleIndices` only — `items` keeps
    /// its scan order, so undo indices and the sidecar are unaffected.
    @Published var sort = PhotoSort() {
        didSet {
            if sort != oldValue {
                filterDebounce?.cancel()
                filterDebounce = nil
                if itemStructureNeedsRebuild { rebuildStructuralIndices() }
                else { preparedIndex.rebuildPreparedSort(items, sort: sort) }
                applyFilter()
            }
        }
    }
    /// Indices into `items` that pass the current filter, in the chosen sort order.
    @Published private(set) var visibleIndices: [Int] = []
    /// Same visible order, split into runs of the active sort key's value
    /// (days, cameras, subfolders…) for the Grid view. Rebuilt only when
    /// filter/sort/session structure changes, not on selection drag.
    @Published private(set) var visibleGroups: [PhotoGroup] = []
    /// Item index → header title for the Browser strip, covering every group
    /// start (including the first). Empty when division is off.
    @Published private(set) var visibleGroupTitles: [Int: String] = [:]

    /// The multi-selection (absolute indices into `items`). Empty is the
    /// normal single-photo state: the selection is just `currentIndex`.
    /// Selection gestures keep `currentIndex` inside the set as the anchor.
    @Published private(set) var selectedIndices: Set<Int> = [] {
        didSet {
            cachedSelectionSummary = nil
            if selectedIndices != oldValue {
                qualityCueSelectionOrder = nil
                qualityCueSelectionCursor = 0
                if selectedIndices.contains(where: { needsQualityCueMeasurement(at: $0) }) {
                    wakeQualityCueRest()
                }
            }
        }
    }
    /// Scan metadata is immutable between item generations. Rating, playback,
    /// and other UI publications do not change this potentially large summary.
    private var cachedSelectionSummary: PhotoSelectionSummary?
    /// Stable authority for the multi-selection. `selectedIndices` is its
    /// render-facing projection into the current `items` generation.
    private var selectionState = SelectionState()

    private(set) var sourceFolder: URL?
    private let reviewDefaults: UserDefaults
    @Published private(set) var activeFileOperation: FileOperationKind? {
        didSet {
            updateFileOperationPowerActivity()
            if activeFileOperation != nil {
                if activeFileOperation == .exportCopy {
                    pauseQualityCueAnalysis()
                } else {
                    // Rollback may refresh shared file identity without an
                    // items assignment. Retire evidence before that mutation.
                    invalidateQualityCueAnalysis(keepingPaused: true)
                    if !filter.selectedQualityCues.isEmpty { applyFilter(preservingCurrent: true) }
                }
                pauseSessionContentChecks()
                invalidateDuplicateBurstAnalysis(rebuildLayout: true)
            } else {
                startQualityCueAnalysis()
                startSessionContentChecks()
            }
        }
    }
    @Published private(set) var xmpPublicationState:
        XMPPublicationLifecycleState = .idle {
        didSet { updateFileOperationPowerActivity() }
    }
    @Published private(set) var isSessionTransitioning = false {
        didSet {
            if isSessionTransitioning {
                pauseQualityCueAnalysis()
                pauseSessionContentChecks()
            } else if sourceFolder != nil {
                startQualityCueAnalysis()
                startSessionContentChecks()
            }
        }
    }
    @Published private(set) var isPreparingForTermination = false
    @Published private(set) var isRecoveringInterruptedOperations = false {
        didSet {
            updateFileOperationPowerActivity()
            if isRecoveringInterruptedOperations {
                invalidateQualityCueAnalysis(keepingPaused: true)
                if !filter.selectedQualityCues.isEmpty { applyFilter(preservingCurrent: true) }
                pauseSessionContentChecks()
            } else {
                startQualityCueAnalysis()
                startSessionContentChecks()
            }
        }
    }
    @Published private(set) var operationRecoveryReport:
        FileOperationJournal.RecoveryReport?
    /// The worker's concrete reason for entering recovery. Launch recovery
    /// cannot always know why a previous process stopped, but an in-process
    /// I/O failure must not be reduced to a generic "interrupted" notice.
    @Published private(set) var operationRecoveryCause: String?
    @Published private(set) var recoveryNeedsAttention = false
    /// True only while Louppe is actively changing state or checking an
    /// interrupted operation. A persistent recovery warning is deliberately
    /// not part of this gate: review and session management stay usable.
    var isFileOperationRunning: Bool {
        activeFileOperation != nil
            || isSessionTransitioning
            || isPreparingForTermination
            || isRecoveringInterruptedOperations
    }
    /// An unresolved journal reserves filesystem mutations for Recovery. It
    /// does not reserve ordinary review, ratings, navigation, or persistence.
    var isNewFileOperationBlocked: Bool {
        isFileOperationRunning || isXMPPublicationRunning
            || recoveryNeedsAttention
    }
    /// Successful recovery only needs acknowledgement when it did something
    /// visible. Merely verifying and retiring a stale record is silent.
    var operationRecoveryReportRequiresAcknowledgement: Bool {
        guard let report = operationRecoveryReport,
              !Self.recoveryReportNeedsAttention(report) else { return false }
        return report.preservedCopies > 0
            || report.preservedMoves > 0
            || report.restoredFiles > 0
            || report.removedPartialCopies > 0
    }
    /// One concise explanation for the nonmodal warning. Reconnecting a
    /// drive is suggested only when Recovery actually found an unavailable
    /// volume; identity mismatches and lock contention need different advice.
    var recoveryAttentionMessage: String? {
        guard recoveryNeedsAttention,
              let report = operationRecoveryReport else { return nil }

        if report.operationLockUnavailable {
            return L10n.text("Another Louppe window is recovering files. Close it, then retry recovery. Reviewing remains available.")
        }

        let interruptionPrefix = operationRecoveryCause.map {
            $0.hasSuffix(".") ? "\($0) " : "\($0). "
        } ?? ""
        let completedNotice = report.preservedCopies > 0
                || report.preservedMoves > 0
                || report.restoredFiles > 0
                || report.removedPartialCopies > 0
            ? L10n.text("Other files were handled safely. ")
            : ""
        if !report.unavailableVolumes.isEmpty {
            let driveNames = report.unavailableVolumes.map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return name.isEmpty ? path : name
            }
            let drives = driveNames.count == 1
                ? "“\(driveNames[0])”"
                : driveNames.map { "“\($0)”" }.joined(separator: ", ")
            return interruptionPrefix + completedNotice
                + (driveNames.count == 1
                    ? L10n.text("Some interrupted files are still untouched because a drive is unavailable. ")
                    : L10n.text("Some interrupted files are still untouched because drives are unavailable. "))
                + L10n.text("Reconnect \(drives), then retry recovery. Reviewing remains available.")
        }

        let count = max(report.unresolvedFiles, 1)
        let message = interruptionPrefix + completedNotice
            + (count == 1
                ? L10n.text("Louppe couldn't finish checking 1 interrupted file. ")
                : L10n.text("Louppe couldn't finish checking \(count) interrupted files. "))
            + L10n.text("Uncertain files remain untouched. Reviewing stays available; Copy, Move, Rename, Organize, and Clean Up are paused until recovery finishes.")
        return message
    }
    /// A sheet, popover, confirmation, or recovery alert owns keyboard/menu
    /// input until it is dismissed. All session command surfaces share this
    /// definition so one route cannot mutate state behind another.
    var isSessionCommandPresentationActive: Bool {
        isExportPresented
            || isOrganizePresented
            || isRenamePresented
            || isActionPalettePresented
            || isEarlyUserFeedbackPresented
            || isFilterPresented
            || isSortPresented
            || isReviewStatusPresented
            || isClearAllRatingsConfirmationPresented
            || isLegacySessionMigrationConfirmationPresented
            || isSessionRecoveryPresented
            || pendingCleanUp != nil
            || cleanUpError != nil
            || pairingMetadataError != nil
            || isRecoveringInterruptedOperations
            || operationRecoveryReportRequiresAcknowledgement
    }

    /// Opens Filter for Command-F and lets its search field claim focus once.
    /// Keeping the request in the store bridges the toolbar popover's delayed
    /// creation without making ordinary toolbar clicks steal keyboard focus.
    func presentFilterSearch() {
        filterSearchFocusRequestGeneration &+= 1
        isFilterPresented = true
    }

    func takeFilterSearchFocusRequest() -> Bool {
        guard fulfilledFilterSearchFocusRequestGeneration
                != filterSearchFocusRequestGeneration else { return false }
        fulfilledFilterSearchFocusRequestGeneration =
            filterSearchFocusRequestGeneration
        return true
    }
    var isCleaningUp: Bool { activeFileOperation == .cleanUp }
    var isCopyingExport: Bool { activeFileOperation == .exportCopy }
    var isMovingExport: Bool { activeFileOperation == .exportMove }
    var isOrganizingSource: Bool { activeFileOperation == .organizeSource }
    var isRenamingSource: Bool { activeFileOperation == .renameSource }
    var isChangingSourceFiles: Bool {
        isOrganizingSource || isRenamingSource
    }
    var isXMPPublicationRunning: Bool {
        switch xmpPublicationState {
        case .preflighting, .publishing, .cancelling:
            return true
        default:
            return false
        }
    }
    private var hasXMPPublicationSessionState: Bool {
        xmpPublicationState != .idle
    }
    var canRate: Bool {
        return !items.isEmpty
            && !isFileOperationRunning
            && !isLegacySessionMigrationConfirmationPresented
    }
    var canExport: Bool {
        !items.isEmpty
            && !isNewFileOperationBlocked
            && !isLegacySessionMigrationConfirmationPresented
    }
    var canCleanUp: Bool {
        !items.isEmpty
            && !isNewFileOperationBlocked
            && !isLegacySessionMigrationConfirmationPresented
    }
    var canOrganizeSource: Bool {
        !items.isEmpty
            && !isNewFileOperationBlocked
            && !isLegacySessionMigrationConfirmationPresented
    }
    var canRenameSource: Bool { canOrganizeSource }
    var isExporting: Bool { isCopyingExport || isMovingExport }

    /// Retained for the complete filesystem transaction. This prevents idle
    /// system sleep while Copy, Move, Trash, restore, or recovery is active.
    /// macOS still sleeps when a MacBook lid is explicitly closed, so Copy's
    /// worker separately tolerates a removable source remount after wake.
    private var fileOperationPowerActivity: NSObjectProtocol?
    /// Held only after choosing a palette action and before the native sheet
    /// has fully dismissed. The follow-up always invokes an existing,
    /// separately guarded SessionStore action.
    private var actionPaletteFollowUp: (@MainActor () -> Void)?
    var isPreventingIdleSystemSleep: Bool {
        fileOperationPowerActivity != nil
    }

    private func updateFileOperationPowerActivity() {
        let shouldPreventSleep = activeFileOperation != nil
            || isXMPPublicationRunning
            || isRecoveringInterruptedOperations
        if shouldPreventSleep, fileOperationPowerActivity == nil {
            fileOperationPowerActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: L10n.text("Louppe is safely transferring files or writing metadata")
            )
        } else if !shouldPreventSleep,
                  let activity = fileOperationPowerActivity {
            ProcessInfo.processInfo.endActivity(activity)
            fileOperationPowerActivity = nil
        }
    }

    /// One undo step can hold several photo changes (e.g. "clear all"),
    /// so a single ⌘Z restores the whole batch.
    private enum MetadataDimension {
        case decision
        case stars
        case color
        case all
    }
    private struct MetadataChange {
        /// A complete before-image keeps every physical file's metadata
        /// coherent, while `dimension` makes undo restore only the attribute
        /// changed by that action.
        let previous: PhotoFileMetadataSnapshot
    }
    /// A photo removed by Clean Up, with everything needed to bring it back:
    /// its former position in `items` and where each file landed in the Trash.
    private struct RemovedPhoto: Sendable {
        let index: Int
        let item: PhotoItem
        let trashedFiles: [TrashedFile]
    }
    private enum UndoStep {
        case metadata(
            MetadataDimension,
            [MetadataChange],
            previousFileID: String?
        )
        case cleanUp(
            [RemovedPhoto],
            previousItemID: String?,
            previousIndex: Int,
            pairComponents: Bool
        )
        case organization(SourceOrganizationUndoRecord)
    }
    private var undoStack: [UndoStep] = []
    private var saveDebounce: DispatchWorkItem?
    private var saveDeadline: DispatchWorkItem?
    private var saveTrailingGeneration: UInt64 = 0
    private var saveCycleGeneration: UInt64 = 0
    private var pendingPersistenceTask: Task<SaveOutcome, Never>?
    private var retrySaveRequest: SaveRequest?
    /// A backup-only success stays manually retryable so its folder sidecar
    /// can be repaired later, but it must never turn Close or Quit into a
    /// requirement: the captured ratings are already durable.
    private var retrySaveIsOptionalSidecarRepair = false
    /// Monotonic within one opened-folder access. A completed older save can
    /// advance durability only through the generation it actually captured;
    /// it can never make a newer rating look clean.
    private var sessionChangeGeneration: UInt64 = 0
    private var durableSessionChangeGeneration: UInt64?
    private var persistenceGenerationAccessID: UUID?
    @Published private(set) var activePersistenceSaveCount = 0
    private var saveRequestedWhilePersistenceBusy = false
    /// Inspectable by focused concurrency tests; production uses the flag only
    /// to coalesce repeated maximum-age checkpoints behind one active write.
    var hasDeferredPersistenceSave: Bool {
        saveRequestedWhilePersistenceBusy
    }

    /// Deterministic test barrier for completion observers that run separately
    /// from a caller awaiting one specific persistence task.
    @discardableResult
    func waitForPersistenceIdleForTesting(
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while activePersistenceSaveCount > 0
            || saveRequestedWhilePersistenceBusy {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }
    private var filterDebounce: DispatchWorkItem?
    private var prefetchDebounce: DispatchWorkItem?
    private var scanTask: Task<Void, Never>?
    private var duplicateBurstAnalysisTask: Task<Void, Never>?
    private let duplicateBurstGrouping: @Sendable (DuplicateBurstAnalysis.Result, DuplicateBurstAnalysis.ReviewMode, Int, TimeInterval) async throws -> [DuplicateBurstAnalysis.Group]
    private var duplicateBurstAnalysisGeneration: UInt64 = 0
    private var duplicateBurstRequestedCurrentID: String?
    private var duplicateBurstRequestedSelectionIDs: Set<String> = []
    private var duplicateBurstAnalysisResult: DuplicateBurstAnalysis.Result?
    /// Membership depends on analysis and sensitivity, never ratings, sorting,
    /// or the ordinary filter. Keep one layout so those changes only project
    /// existing groups instead of repeating the near-hash search on main.
    private var duplicateBurstGroupCache: (
        mode: DuplicateBurstAnalysis.ReviewMode,
        distance: Int,
        interval: TimeInterval,
        groups: [DuplicateBurstAnalysis.Group]
    )?
    /// Stable content revisions captured when local analysis began. A result
    /// cannot appear after a same-path replacement, rescan, or RAW+JPEG
    /// projection change, even if its detached task reaches completion late.
    private var duplicateBurstAnalysisRevisions: [String: PhotoContentRevision] = [:]
    private let persistence: any SessionPersistenceClient
    private let saveTrailingDelay: TimeInterval
    private let saveMaximumDelay: TimeInterval
    /// Nil selects the production Application Support journal directory.
    /// Tests can inject a disposable root and must explicitly opt into launch
    /// recovery, so constructing a view-model can never touch live user files.
    private let operationJournalDirectory: URL?
    /// The selected source folder remains accessible for the entire open
    /// session. This is a no-op in the normal unsigned development build and
    /// a balanced security-scope token in the App Store build.
    private var sourceFolderAccess: SecurityScopedFolderAccess?
    /// Stored export-destination bookmarks are opened only while the durable
    /// recovery worker is reconciling its own operation journal.
    private var recoveryDestinationAccesses: [SecurityScopedFolderAccess] = []
    private var saveSequence: UInt64 = 0
    private var latestReportedSaveSequence: UInt64 = 0
    private var persistenceAccess: SessionPersistence.AccessContext?
    private var scanGeneration: UInt64 = 0
    private var folderOpenGeneration: UInt64 = 0
    private var cleanUpGeneration: UInt64 = 0
    private var xmpPublicationGeneration: UInt64 = 0
    private var xmpPublicationCancelFlag: XMPPublicationCancelFlag?
    private var xmpPublicationTask: Task<Void, Never>?
    private struct XMPPublicationSessionToken: Equatable {
        let generation: UInt64
        let scanGeneration: UInt64
        let folder: URL?
    }
    private var xmpPublicationSessionToken: XMPPublicationSessionToken?
    private var deferredFolderOpen: URL?
    /// The session affected by an interrupted mutation. Both the exact path
    /// bytes and stable directory identity must still match before a delayed
    /// rescan can touch the current session.
    private struct RecoveryRescanTarget {
        let folder: URL
        let identity: SessionPersistence.SourceFolderIdentity
    }
    private var recoveryRescanTarget: RecoveryRescanTarget?
    private var preparedIndex = PreparedSessionIndex()
    private var itemStructureNeedsRebuild = true
#if DEBUG
    private(set) var structuralIndexGenerationForTesting: UInt64 = 0
    var pendingContentFileIDsForTesting: Set<String> { sessionContentPendingFileIDs }
#endif
    private struct ScanResumeIdentity {
        let folder: URL
        let currentItemID: String?
        let selectedItemIDs: Set<String>
    }
    private var scanResumeIdentity: ScanResumeIdentity?
    private var nextScanResumeIdentityOverride: ScanResumeIdentity?
    private var deferredOrganizationUndo: SourceOrganizationUndoRecord?
    /// Current file ID -> byte-exact parent path as it existed before Louppe
    /// first organized that physical file. Identity-based session restore
    /// remaps these keys after every organizer rescan.
    private var organizationOriginFolderPathBytesByFileID: [String: Data] = [:]
    private var organizationGeneration: UInt64 = 0
    @Published private(set) var organizationProgress:
        SourceOrganizationProgress?
    @Published private(set) var organizationOutcome:
        SourceOrganizationOutcome?
    @Published var organizationError: String?
    private var ratingTally = (yes: 0, no: 0, undecided: 0)
    private var mixedRatingCount = 0
    private var starTally: [StarRating: Int] = [:]
    private var unratedStarCountStorage = 0
    private var mixedStarCountStorage = 0
    private var colorTally: [PhotoColorLabel: Int] = [:]
    private var noColorCountStorage = 0
    private var mixedColorCountStorage = 0
    /// Physical ids include hidden JPEG partners, so rating undo remains
    /// stable across an in-memory pairing projection.
    private var itemIndexByFileID: [String: Int] = [:]
    /// Exact unambiguous RAW+JPEG relationships, cached at the same structural
    /// boundary as the item/file index so menu enablement stays O(1).
    private var rawJPEGPairs: [(raw: PhotoFile, jpeg: PhotoFile)] = []
    var rawJPEGPairCount: Int { rawJPEGPairs.count }

    @Published private(set) var availableTypes: [String] = []
    @Published private(set) var availableMediaKinds: [MediaKind] = []
    @Published private(set) var availableCameras: [String] = []
    @Published private(set) var availableLenses: [String] = []
    @Published private(set) var availableSubfolders: [String] = []
    @Published private(set) var availableCaptureDates: [Date] = []
    @Published private(set) var captureDateRange: ClosedRange<Date>?
    @Published private(set) var apertureRange: ClosedRange<Double>?
    @Published private(set) var shutterRange: ClosedRange<Double>?
    @Published private(set) var isoRange: ClosedRange<Double>?
    @Published private(set) var durationRange: ClosedRange<Double>?
    @Published private(set) var videoFrameRateRange: ClosedRange<Double>?
    @Published private(set) var typeCounts: [String: Int] = [:]
    @Published private(set) var mediaKindCounts: [MediaKind: Int] = [:]
    @Published private(set) var cameraCounts: [String: Int] = [:]
    @Published private(set) var lensCounts: [String: Int] = [:]
    @Published private(set) var videoResolutionCounts: [String: Int] = [:]
    @Published private(set) var videoCodecCounts: [String: Int] = [:]
    @Published private(set) var subfolderCounts: [String: Int] = [:]
    @Published private(set) var captureDateCounts: [Date: Int] = [:]
    @Published private(set) var unknownDateCount = 0

    var availableVideoResolutions: [String] {
        videoResolutionCounts.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var availableVideoCodecs: [String] {
        videoCodecCounts.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    nonisolated static let sidecarName = SessionConstants.sidecarName

    init(
        persistence: any SessionPersistenceClient = SessionPersistence(),
        saveTrailingDelay: TimeInterval = 0.5,
        saveMaximumDelay: TimeInterval = 5,
        operationJournalDirectory: URL? = nil,
        automaticallyRecoversInterruptedOperations: Bool = false,
        reviewDefaults: UserDefaults = .standard,
        sessionContentVerification: @escaping @Sendable (PhotoFile, SessionContentProof?) async throws -> SessionContentProof = {
            try await SessionContentVerificationLane.shared.verify($0, knownProof: $1)
        },
        qualityCueMeasurement: @escaping @Sendable (PhotoItem) async -> QualityCueEvidence = {
            await QualityCueEvidence.measure($0)
        },
        qualityCueResources: @escaping @Sendable () -> QualityCueWorkPolicy.Resources = {
            .current
        },
        qualityCueRest: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        },
        duplicateBurstGrouping: @escaping @Sendable (DuplicateBurstAnalysis.Result, DuplicateBurstAnalysis.ReviewMode, Int, TimeInterval) async throws -> [DuplicateBurstAnalysis.Group] = {
            try $0.groupsCancellable(for: $1, visualDistance: $2, burstInterval: $3)
        }
    ) {
        self.persistence = persistence
        self.sessionContentVerification = sessionContentVerification
        self.qualityCueMeasurement = qualityCueMeasurement
        self.qualityCueResources = qualityCueResources
        self.qualityCueRest = qualityCueRest
        self.duplicateBurstGrouping = duplicateBurstGrouping
        self.reviewDefaults = reviewDefaults
        if let saved = reviewDefaults.object(forKey: Self.burstGroupingIntervalKey) as? Double,
           saved.isFinite {
            burstGroupingInterval = min(max(saved, CaptureBurstIntervalInput.range.lowerBound), CaptureBurstIntervalInput.range.upperBound)
        }
        qualityCuePreferences = CameraQualityWarningPreferences.load(from: reviewDefaults)
        let preferences = ReviewPreferences.load(from: reviewDefaults)
        viewMode = preferences.defaultView
        sort = preferences.defaultSort
        isGroupingEnabled = preferences.isGroupingEnabled
        self.saveTrailingDelay = max(0, saveTrailingDelay)
        // These clocks are independent: production normally uses a longer
        // maximum dirty age, while tests deliberately put the hard deadline
        // first to prove it is not just the trailing debounce firing.
        self.saveMaximumDelay = max(0, saveMaximumDelay)
        self.operationJournalDirectory = operationJournalDirectory
        // ImageIO's RAW reader can register defaults on a metadata worker.
        // Combine does not move notification delivery to the owner's actor.
        qualityCuePreferencesObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reloadQualityCuePreferences() }
            }
        loadRecents()
        if automaticallyRecoversInterruptedOperations,
           FileOperationJournal.hasPendingOperations(
            directory: operationJournalDirectory
           ) {
            beginInterruptedOperationRecovery()
        }
    }

    // MARK: - Interrupted file-operation recovery

    /// Retries every still-active journal. Existing files are never
    /// overwritten; an unavailable volume or identity mismatch remains
    /// visible for another retry instead of being guessed around.
    var canRetryInterruptedOperationRecovery: Bool {
        recoveryNeedsAttention && !isFileOperationRunning
    }
    var canKeepInterruptedFilesAsTheyAre: Bool {
        recoveryNeedsAttention && !isFileOperationRunning
    }

    func retryInterruptedOperationRecovery() {
        guard canRetryInterruptedOperationRecovery else { return }
        // The user may have opened the affected folder while the warning was
        // nonmodal. Capture its exact identity so any files restored by this
        // retry become visible through a safe same-folder rescan.
        beginInterruptedOperationRecovery(rescanOnSuccess: sourceFolder != nil)
    }

    /// Explicitly discard only Louppe's recovery bookkeeping. Media stays at
    /// its current paths, so a permanently ambiguous record cannot disable
    /// future Copy, Move, Rename, Organize, or Clean Up actions forever.
    func keepInterruptedFilesAsTheyAre() {
        guard canKeepInterruptedFilesAsTheyAre else { return }
        captureRecoveryRescanTargetForCurrentFolder()
        operationRecoveryReport = nil
        recoveryNeedsAttention = false
        isRecoveringInterruptedOperations = true

        let journalDirectory = operationJournalDirectory
        let worker = Task.detached(priority: .userInitiated) {
            FileOperationJournal.keepFilesAsTheyAreAndForgetPendingOperations(
                directory: journalDirectory
            )
        }
        Task { @MainActor [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.isRecoveringInterruptedOperations = false
            let needsAttention = Self.recoveryReportNeedsAttention(report)
            self.recoveryNeedsAttention = needsAttention
            self.finishRecoveryDestinationAccesses(retaining: needsAttention)
            self.operationRecoveryReport = needsAttention ? report : nil
            let rescanTarget = self.recoveryRescanTarget
            if !needsAttention {
                self.operationRecoveryCause = nil
                self.recoveryRescanTarget = nil
            }

            let deferredFolder = self.deferredFolderOpen
            self.deferredFolderOpen = nil
            if let deferredFolder {
                self.openFolder(deferredFolder)
            } else if let rescanTarget,
                      self.recoveryRescanTargetMatchesCurrentSession(
                        rescanTarget
                      ) {
                self.rescan()
            }
        }
    }

    func dismissOperationRecoveryReport() {
        operationRecoveryReport = nil
        operationRecoveryCause = nil
    }

    private func beginInterruptedOperationRecovery(
        rescanOnSuccess: Bool = false
    ) {
        guard !isFileOperationRunning else { return }
        if recoveryDestinationAccesses.isEmpty {
            recoveryDestinationAccesses = SecurityScopedFolderBookmarks
                .beginRecoveryDestinationAccesses()
        }
        if rescanOnSuccess {
            captureRecoveryRescanTargetForCurrentFolder()
        }
        operationRecoveryReport = nil
        recoveryNeedsAttention = false
        isRecoveringInterruptedOperations = true

        let journalDirectory = operationJournalDirectory
        let worker = Task.detached(priority: .userInitiated) {
            FileOperationJournal.recoverPendingOperations(
                directory: journalDirectory
            )
        }
        Task { @MainActor [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.isRecoveringInterruptedOperations = false
            let needsAttention = Self.recoveryReportNeedsAttention(report)
            self.recoveryNeedsAttention = needsAttention
            self.finishRecoveryDestinationAccesses(retaining: needsAttention)
            let changedFiles = report.preservedCopies > 0
                || report.preservedMoves > 0
                || report.restoredFiles > 0
                || report.removedPartialCopies > 0
            self.operationRecoveryReport = needsAttention || changedFiles
                ? report
                : nil
            if !needsAttention, !changedFiles {
                self.operationRecoveryCause = nil
            }

            let deferredFolder = self.deferredFolderOpen
            self.deferredFolderOpen = nil
            let rescanTarget = self.recoveryRescanTarget
            if !needsAttention {
                self.recoveryRescanTarget = nil
            }
            if let deferredFolder {
                self.openFolder(deferredFolder)
            } else if let rescanTarget,
                      self.recoveryRescanTargetMatchesCurrentSession(
                        rescanTarget
                      ) {
                self.rescan()
            }
        }
    }

    private func finishRecoveryDestinationAccesses(retaining needsAttention: Bool) {
        guard !needsAttention else { return }
        recoveryDestinationAccesses.forEach { $0.stop() }
        recoveryDestinationAccesses = []
        SecurityScopedFolderBookmarks.clearRecoveryDestinations()
    }

    private func captureRecoveryRescanTargetForCurrentFolder() {
        // A retry can happen after the user switches folders. Never retain a
        // target captured for an earlier session when the current folder has
        // gone away or can no longer be identified.
        recoveryRescanTarget = nil
        guard let folder = sourceFolder,
           let identity = persistenceAccess?.folderIdentity
                ?? (try? SessionPersistence.SourceFolderIdentity.capture(
                    at: folder
                )) else {
            return
        }
        recoveryRescanTarget = RecoveryRescanTarget(
            folder: folder,
            identity: identity
        )
    }

    private static func recoveryReportNeedsAttention(
        _ report: FileOperationJournal.RecoveryReport
    ) -> Bool {
        report.operationLockUnavailable || report.hasUnresolvedFiles
    }

    private func recoveryRescanTargetMatchesCurrentSession(
        _ target: RecoveryRescanTarget
    ) -> Bool {
        guard let folder = sourceFolder,
              FileOperationJournal.exactPathsEqual(folder, target.folder)
        else { return false }
        return target.identity.matches(folder: folder)
    }

#if DEBUG
    var qualityCueCoverageCountsForTesting: (measured: Int, total: Int) {
        (qualityCueMeasuredCount, qualityCuePhotoCount)
    }

    /// Gives model-focused tests the same derived-data boundary as a completed
    /// folder scan without requiring filesystem setup.
    func rebuildDerivedDataForTesting(sourceFolder: URL? = nil) {
        if let sourceFolder { self.sourceFolder = sourceFolder }
        rebuildDerivedData()
        applyFilter()
    }

    /// Apply an already-completed disposable worker outcome without touching
    /// the user's Trash or journal during model-focused regression tests.
    func finishCleanUpForTesting(
        _ result: TrashBatchResult,
        mode: CleanUpMode,
        preparedSurvivors: [PhotoItem],
        survivorMetadataError: String? = nil
    ) {
        activeFileOperation = .cleanUp
        finishCleanUp(
            result,
            mode: mode,
            preparedSurvivors: preparedSurvivors,
            survivorMetadataError: survivorMetadataError,
            previousItemID: currentItemID,
            previousIndex: currentIndex,
            generation: cleanUpGeneration
        )
    }

    /// Deterministic recovery-state setup for command-gating tests. Production
    /// reaches the same state only through the journal worker above.
    func presentOperationRecoveryReportForTesting(
        _ report: FileOperationJournal.RecoveryReport?,
        cause: String? = nil
    ) {
        operationRecoveryReport = report
        operationRecoveryCause = cause
        recoveryNeedsAttention = report.map(Self.recoveryReportNeedsAttention)
            ?? false
    }

    /// Places a Clean Up restore below later rating steps so tests can prove
    /// an unavailable restore is retained instead of accidentally popped.
    func pushCleanUpUndoForTesting() {
        pushUndo(.cleanUp(
            [],
            previousItemID: currentItemID,
            previousIndex: currentIndex,
            pairComponents: false
        ))
    }
#endif

    // MARK: - Counts

    var yesCount: Int { ratingTally.yes }
    var noCount: Int { ratingTally.no }
    var undecidedCount: Int { ratingTally.undecided }
    /// Mixed decisions remain part of the legacy/export Undecided total, but
    /// the normal Filter exposes both buckets independently.
    var plainUndecidedCount: Int { max(0, ratingTally.undecided - mixedRatingCount) }
    var mixedCount: Int { mixedRatingCount }
    var ratedCount: Int { ratingTally.yes + ratingTally.no + mixedRatingCount }
    func starCount(_ rating: StarRating) -> Int { starTally[rating, default: 0] }
    var unratedStarCount: Int { unratedStarCountStorage }
    var mixedStarCount: Int { mixedStarCountStorage }
    func colorCount(_ label: PhotoColorLabel) -> Int { colorTally[label, default: 0] }
    var noColorCount: Int { noColorCountStorage }
    var mixedColorCount: Int { mixedColorCountStorage }

    /// Reset remains available when the date UI is in its non-default mode or
    /// retains hidden day exclusions, even if those choices currently show all
    /// photos and therefore do not light the toolbar's active-filter glyph.
    var filterCanReset: Bool {
        filter.isActive
            || filter.dateMode != .range
            || !filter.excludedDates.isEmpty
            || filter.excludesUnknownDate
    }

    var currentItem: PhotoItem? {
        // When a filter matches nothing there is deliberately no current
        // photo; returning the previously current hidden item would expose it
        // in the Info panel and make keyboard actions target it invisibly.
        guard !visibleIndices.isEmpty, items.indices.contains(currentIndex),
              preparedIndex.location(forItemIndex: currentIndex) != nil else { return nil }
        return items[currentIndex]
    }

    var canToggleClippingWarnings: Bool {
        guard viewMode == .gallery,
              selectedIndices.count <= 1,
              let currentItem
        else { return false }
        return currentItem.mediaKind == .photo && currentItem.isSupported
    }

    private var currentItemID: String? {
        items.indices.contains(currentIndex) ? items[currentIndex].id : nil
    }

    var currentVisiblePosition: Int? {
        preparedIndex.location(forItemIndex: currentIndex)?.position
    }

    var isFilterActive: Bool {
        filter.isActive || groupedReviewMode == .captureBursts
    }

    var isGroupedReviewActive: Bool {
        groupedReviewMode != .off
    }

    var isDuplicateBurstAnalysisRunning: Bool {
        duplicateBurstAnalysisState == .analyzing
    }

    var groupedReviewExplanation: String {
        groupedReviewMode.shortDescription
    }

    var groupedReviewGroupCount: Int {
        visibleGroups.count
    }

    var groupedReviewEmptyTitle: String {
        switch groupedReviewMode {
        case .exactDuplicates:
            return L10n.text("No exact duplicates in this view")
        case .likelySimilarPhotos:
            return L10n.text("No likely similar photos in this view")
        case .captureBursts:
            return L10n.text("No capture bursts in this view")
        case .off:
            return ""
        }
    }

    var groupedReviewEmptyDescription: String {
        let filterNote = filter.isActive
            ? L10n.text(" Try adjusting the normal filter to include more media.")
            : ""
        switch groupedReviewMode {
        case .exactDuplicates:
            return L10n.text("Louppe found no verified byte-identical files to group.")
                + filterNote
        case .likelySimilarPhotos:
            return L10n.text("No likely preview matches found. Similarity is a review aid, not proof.")
                + filterNote
        case .captureBursts:
            return L10n.text("No still-photo capture times were within the selected burst interval.")
                + filterNote
        case .off:
            return ""
        }
    }

    var captureBurstCoverageSummary: String {
        let photos = items.filter { $0.mediaKind == .photo }
        let dated = photos.filter { $0.captureDate != nil }
        let inferred = dated.filter { $0.captureDateEvidence?.isInferred ?? true }.count
        return L10n.text("Photo dates: \(dated.count) of \(photos.count); \(inferred) inferred. Missing dates are excluded.")
    }

    var duplicateBurstAnalysisSummary: String {
        guard let result = duplicateBurstAnalysisResult else {
            return L10n.text("Analyze this folder locally to find exact duplicates, likely similar photos, and capture bursts.")
        }
        if result.analysisMode == .captureBursts { return captureBurstCoverageSummary }
        let exact = result.analyzedExactFileCount == 1
            ? L10n.text("1 possible duplicate file checked")
            : L10n.text("\(result.analyzedExactFileCount) possible duplicate files checked")
        let visual = result.analyzedVisualPhotoCount == 1
            ? L10n.text("1 photo preview compared")
            : L10n.text("\(result.analyzedVisualPhotoCount) photo previews compared")
        return L10n.text("Local analysis complete: \(exact); \(visual).")
    }

    /// Stable Browser row identities are rebuilt with the prepared visibility
    /// generation, not on every unrelated `SessionStore` publication.
    var browserEntries: [PreparedSessionIndex.VisibleEntry] {
        preparedIndex.visibleEntries
    }

    private func setSelectionIndices(_ indices: Set<Int>) {
        let changed = selectionState.replace(with: indices, items: items)
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    private func restoreSelection(
        itemIDs: Set<String>,
        visibleOnly: Bool
    ) {
        let previousIndices = selectionState.indices
        let replacementCurrent = selectionState.restore(
            itemIDs: itemIDs,
            items: items,
            preparedIndex: preparedIndex,
            visibleOnly: visibleOnly,
            currentIndex: currentIndex
        )
        if selectionState.indices != previousIndices {
            selectedIndices = selectionState.indices
        }
        if let replacementCurrent {
            currentIndex = replacementCurrent
        }
    }

    private func restoreCurrentItem(
        itemID: String?,
        fallbackIndex: Int
    ) {
        guard !items.isEmpty else {
            currentIndex = 0
            return
        }
        if let itemID, let index = preparedIndex.itemIndex(forID: itemID) {
            currentIndex = index
        } else {
            currentIndex = min(max(fallbackIndex, 0), items.count - 1)
        }
    }

    private func restoreCurrentFile(
        fileID: String?,
        fallbackIndex: Int
    ) {
        guard !items.isEmpty else {
            currentIndex = 0
            return
        }
        if let fileID, let index = itemIndexByFileID[fileID] {
            currentIndex = index
        } else {
            currentIndex = min(max(fallbackIndex, 0), items.count - 1)
        }
    }

    // MARK: - Quality cues

    func qualityEvidence(for item: PhotoItem) -> QualityCueEvidence? {
        guard let evidence = qualityCueEvidence[item.id],
              evidence.revision == item.contentRevision else { return nil }
        return evidence
    }

    func qualityCues(for item: PhotoItem) -> [CameraQualityWarning] {
        let evidence = qualityEvidence(for: item)
        return CameraQualityWarning.warnings(
            for: item, analysis: evidence?.analysis,
            analysisSource: evidence?.source ?? .renderedPreview,
            preferences: qualityCuePreferences
        )
    }

    private func qualityCueMatch(
        for item: PhotoItem,
        preferences: CameraQualityWarningPreferences
    ) -> QualityCueMatch {
        guard preferences.hasEnabledRules, item.mediaKind == .photo else { return [] }
        // This private index contains only revision-accepted evidence. Item
        // replacement and source-identity changes invalidate it and the masks
        // together; do not reconstruct every file revision on each rebuild.
        return CameraQualityWarning.matchingKinds(
            for: item, analysis: preferences.needsHistogram ? qualityCueEvidence[item.id]?.analysis : nil,
            preferences: preferences
        )
    }

    private func preparedQualityCueMatches() -> [QualityCueMatch] {
        if let qualityCueMatchCache { return qualityCueMatchCache }
        // Read observable preferences once, outside the per-photo loop.
        let preferences = qualityCuePreferences
        let matches = items.map { qualityCueMatch(for: $0, preferences: preferences) }
        qualityCueMatchCache = matches
        #if DEBUG
        qualityCueMatchBuildsForTesting += 1
        #endif
        return matches
    }

    func qualityCueStatus(for item: PhotoItem) -> QualityCueStatus {
        let preferences = qualityCuePreferences
        guard preferences.hasEnabledRules else { return .disabled }
        guard item.mediaKind == .photo, item.isSupported else { return .unavailable }
        if preferences.needsHistogram {
            guard let evidence = qualityEvidence(for: item) else {
                return qualityCueCheckingIDs.contains(item.id) ? .checking : .unchecked
            }
            if evidence.sampleCount == 0 {
                return (MediaNumeric.iso(item.iso) != nil || MediaNumeric.shutterSpeed(item.shutterSpeed) != nil)
                    ? .partial : .unavailable
            }
            if evidence.rawFallback { return .partial }
        }
        if (preferences.isHighISOEnabled && MediaNumeric.iso(item.iso) == nil)
            || (preferences.isSlowShutterEnabled && MediaNumeric.shutterSpeed(item.shutterSpeed) == nil) {
            return .partial
        }
        return .checked
    }

    var qualityCueCoverageSummary: String {
        return L10n.text("Image checks: \(qualityCueMeasuredCount) of \(qualityCuePhotoCount) photos. Some cues may be unavailable.")
    }

    func updateQualityCuePreferences(_ value: CameraQualityWarningPreferences) {
        guard value != qualityCuePreferences else { return }
        qualityCueMatchCache = nil
        qualityCuePreferences = value
        value.save(to: reviewDefaults)
        if !filter.selectedQualityCues.isEmpty { applyFilter() }
        if value.needsHistogram { startQualityCueAnalysis() }
        else { pauseQualityCueAnalysis() }
    }

    private func reloadQualityCuePreferences() {
        let value = CameraQualityWarningPreferences.load(from: reviewDefaults)
        guard value != qualityCuePreferences else { return }
        qualityCueMatchCache = nil
        qualityCuePreferences = value
        if !filter.selectedQualityCues.isEmpty { applyFilter() }
        if value.needsHistogram { startQualityCueAnalysis() }
        else { pauseQualityCueAnalysis() }
    }

    /// Tile appearance changes priority without creating a task per tile.
    func prioritizeQualityCues(for item: PhotoItem) {
        qualityCueInterestIDs.removeAll { $0 == item.id }
        qualityCueInterestIDs.insert(item.id, at: 0)
        if qualityCueInterestIDs.count > 64 { qualityCueInterestIDs.removeLast() }
        if qualityEvidence(for: item) == nil { wakeQualityCueRest() }
    }

    private func needsQualityCueMeasurement(at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        let item = items[index]
        return item.mediaKind == .photo && item.isSupported
            && qualityEvidence(for: item) == nil && !qualityCueCheckingIDs.contains(item.id)
    }

    private func wakeQualityCueRest() {
        qualityCueInterestGeneration &+= 1
        qualityCueRestTask?.cancel()
    }

    /// Automatic suspension preserves the user's separate Pause choice.
    func pauseQualityCueAnalysis(userInitiated: Bool = false) {
        if userInitiated { qualityCueUserPaused = true }
        qualityCueGeneration &+= 1
        qualityCueRestartRequested = false
        qualityCueTask?.cancel()
        qualityCueRestTask?.cancel()
        // Keep the task/lease until its group exits: immediate Resume cannot
        // admit another pair while cancelled measurements are still retiring.
        if !qualityCueCheckingIDs.isEmpty {
            objectWillChange.send()
            qualityCueCheckingIDs.removeAll(keepingCapacity: true)
        }
        qualityCueCursor = 0
        qualityCueSelectionOrder = nil
        qualityCueSelectionCursor = 0
        if qualityCueFilterNeedsRefresh, case .ready = phase, !itemStructureNeedsRebuild {
            applyFilter(preservingCurrent: true)
        }
        if !isQualityCueAnalysisPaused { isQualityCueAnalysisPaused = true }
    }

    func resumeQualityCueAnalysis() {
        qualityCueUserPaused = false
        startQualityCueAnalysis()
    }

    private func invalidateQualityCueAnalysis(keepingPaused: Bool = false) {
        qualityCueFilterNeedsRefresh = false
        pauseQualityCueAnalysis()
        objectWillChange.send()
        qualityCueEvidence.removeAll()
        qualityCueMatchCache = nil
        qualityCueMeasuredCount = 0
        qualityCuePhotoCount = items.reduce(0) { $0 + ($1.mediaKind == .photo ? 1 : 0) }
        qualityCueInterestIDs = []
        isQualityCueAnalysisPaused = keepingPaused || qualityCueUserPaused
    }

    /// Two interested items at a time, followed by adaptive rest. Selection
    /// priority has a retained frontier; Select All never restarts an O(N) walk
    /// for each pair. New current/tile/selection interest can interrupt rest.
    func startQualityCueAnalysis() {
        guard case .ready = phase, !isFileOperationRunning,
              qualityCuePreferences.needsHistogram, !qualityCueUserPaused else { return }
        if let task = qualityCueTask {
            if task.isCancelled { qualityCueRestartRequested = true }
            return
        }
        if isQualityCueAnalysisPaused { isQualityCueAnalysisPaused = false }
        let generation = qualityCueGeneration
        let taskID = UUID()
        qualityCueTaskID = taskID
        let measure = qualityCueMeasurement
        let rest = qualityCueRest
        let lease = sourceFolderAccess?.makeIndependentAccess()
        qualityCueTask = Task { @MainActor [weak self] in
            defer {
                lease?.stop()
                self?.finishQualityCueTask(taskID)
            }
            var lastFilterRefresh = ContinuousClock.now
            while !Task.isCancelled {
                guard let self,
                      let batch = self.nextQualityCueBatch(generation: generation), !batch.isEmpty else { break }
                let interestGeneration = self.qualityCueInterestGeneration
                let workStart = ContinuousClock.now
                let results = await withTaskGroup(of: (String, QualityCueEvidence).self) { group in
                    for item in batch {
                        group.addTask(priority: .utility) { (item.id, await measure(item)) }
                    }
                    var results: [(String, QualityCueEvidence)] = []
                    for await result in group { results.append(result) }
                    return results
                }
                guard !Task.isCancelled, self.qualityCueGeneration == generation else { return }
                self.objectWillChange.send()
                for (id, evidence) in results {
                    self.qualityCueCheckingIDs.remove(id)
                    guard let index = self.preparedIndex.itemIndex(forID: id),
                          self.items[index].contentRevision == evidence.revision else { continue }
                    let selectedCues = QualityCueMatch(self.filter.selectedQualityCues)
                    let previouslyMatched = !selectedCues.isEmpty
                        && !(self.qualityCueMatchCache?[index] ?? self.qualityCueMatch(for: self.items[index], preferences: self.qualityCuePreferences))
                            .intersection(selectedCues).isEmpty
                    let wasMeasured = (self.qualityCueEvidence[id]?.sampleCount ?? 0) > 0
                    let isMeasured = evidence.sampleCount > 0
                    if self.items[index].mediaKind == .photo, wasMeasured != isMeasured {
                        self.qualityCueMeasuredCount += isMeasured ? 1 : -1
                    }
                    self.qualityCueEvidence[id] = evidence
                    if self.qualityCueMatchCache != nil || !selectedCues.isEmpty {
                        let matches = self.qualityCueMatch(for: self.items[index], preferences: self.qualityCuePreferences)
                        if self.qualityCueMatchCache != nil {
                            self.qualityCueMatchCache?[index] = matches
                            #if DEBUG
                            self.qualityCueMatchUpdatesForTesting += 1
                            #endif
                        }
                        let currentlyMatches = !matches.intersection(selectedCues).isEmpty
                        if !selectedCues.isEmpty, previouslyMatched != currentlyMatches {
                            self.qualityCueFilterNeedsRefresh = true
                        }
                    }
                }
                // Visibility uses any selected cue. Another cue on an already
                // matching item cannot require a complete filter projection.
                if self.qualityCueFilterNeedsRefresh, lastFilterRefresh.duration(to: .now) >= .milliseconds(100) {
                    self.applyFilter(preservingCurrent: true)
                    lastFilterRefresh = .now
                }
                if self.qualityCueInterestGeneration == interestGeneration {
                    // Publish accepted visibility before a potentially long rest
                    // or next RAW batch; pacing must not delay known matches.
                    if self.qualityCueFilterNeedsRefresh {
                        self.applyFilter(preservingCurrent: true)
                        lastFilterRefresh = .now
                    }
                    let duration = QualityCueWorkPolicy.rest(
                        after: workStart.duration(to: .now), resources: self.qualityCueResources())
                    let sleeper = Task { await rest(duration) }
                    self.qualityCueRestTask = sleeper
                    await withTaskCancellationHandler {
                        await sleeper.value
                    } onCancel: {
                        sleeper.cancel()
                    }
                    self.qualityCueRestTask = nil
                }
            }
            guard let self, !Task.isCancelled, self.qualityCueGeneration == generation else { return }
            if self.qualityCueFilterNeedsRefresh { self.applyFilter(preservingCurrent: true) }
        }
    }

    private func finishQualityCueTask(_ taskID: UUID) {
        guard qualityCueTaskID == taskID else { return }
        qualityCueTask = nil
        qualityCueTaskID = nil
        qualityCueRestTask = nil
        let restart = qualityCueRestartRequested
        qualityCueRestartRequested = false
        if restart { startQualityCueAnalysis() }
    }

    private func nextQualityCueBatch(generation: UInt64) -> [PhotoItem]? {
        guard qualityCueGeneration == generation else { return nil }
        var batch: [PhotoItem] = []
        func append(_ index: Int) {
            guard batch.count < 2, items.indices.contains(index) else { return }
            let item = items[index]
            guard item.mediaKind == .photo, item.isSupported,
                  qualityEvidence(for: item) == nil,
                  !qualityCueCheckingIDs.contains(item.id),
                  !batch.contains(where: { $0.id == item.id }) else { return }
            batch.append(item)
        }
        append(currentIndex)
        if qualityCueSelectionOrder == nil {
            qualityCueSelectionOrder = Array(selectedIndices)
            qualityCueSelectionCursor = 0
        }
        while batch.count < 2, let order = qualityCueSelectionOrder,
              qualityCueSelectionCursor < order.count {
            let index = order[qualityCueSelectionCursor]
            qualityCueSelectionCursor += 1
            #if DEBUG
            qualityCueSelectionProbesForTesting += 1
            #endif
            append(index)
        }
        for id in qualityCueInterestIDs {
            if let index = preparedIndex.itemIndex(forID: id) { append(index) }
            if batch.count == 2 { break }
        }
        for offset in [1, -1, 2, -2, 3] { append(currentIndex + offset) }
        while batch.count < 2, qualityCueCursor < items.count {
            append(qualityCueCursor)
            qualityCueCursor += 1
        }
        if !batch.isEmpty {
            objectWillChange.send()
            for item in batch { qualityCueCheckingIDs.insert(item.id) }
        }
        return batch
    }

    // MARK: - Filtering

    private func applyFilter(preservingCurrent: Bool = false) {
        qualityCueFilterNeedsRefresh = false
        let cueMatches = filter.selectedQualityCues.isEmpty ? nil : preparedQualityCueMatches()
        preparedIndex.applyFilter(
            filter,
            to: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled,
            qualityCueMatches: cueMatches
        )
        applyGroupedReviewLayoutIfNeeded()
        publishPreparedVisibility()
        // Photos that just got filtered out must leave the selection too —
        // an invisible photo shouldn't silently receive a rating.
        if !selectedIndices.isEmpty {
            let changed = selectionState.retainVisible(
                items: items,
                preparedIndex: preparedIndex
            )
            if changed {
                selectedIndices = selectionState.indices
            }
        }
        if !preservingCurrent, let replacementCurrent = selectionState.replacementCurrentIndex(
            currentIndex: currentIndex,
            preparedIndex: preparedIndex
        ) {
            currentIndex = replacementCurrent
        }
        // Keep the current photo visible: snap to the nearest photo that
        // passes the filter (forward first, else the last visible one).
        if !preservingCurrent, !visibleIndices.isEmpty,
           preparedIndex.location(forItemIndex: currentIndex) == nil {
            currentIndex = visibleIndices.first(where: { $0 >= currentIndex }) ?? visibleIndices.last!
        }
        prefetchAroundCurrent()
    }

    private func scheduleSearchFilter() {
        filterDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.filterDebounce = nil
            self.applyFilter()
        }
        filterDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Destructive actions must use the filter text currently on screen, not
    /// the results from up to 150 ms ago while search typing is debounced.
    private func flushPendingFilter() {
        guard filterDebounce != nil else { return }
        filterDebounce?.cancel()
        filterDebounce = nil
        applyFilter()
    }

    private func rebuildStructuralIndices() {
        rebuildFileItemIndex()
        preparedIndex.rebuildItems(items, sort: sort)
        itemStructureNeedsRebuild = false
#if DEBUG
        structuralIndexGenerationForTesting &+= 1
#endif
    }

    private func rebuildFileItemIndex() {
        var indexByFileID: [String: Int] = [:]
        indexByFileID.reserveCapacity(
            items.reduce(0) { $0 + $1.individualFiles.count }
        )
        for (index, item) in items.enumerated() {
            for file in item.individualFiles {
                indexByFileID[file.id] = index
            }
        }
        itemIndexByFileID = indexByFileID
        rebuildSessionRecoveryIndex()
    }

    /// Resolve history once per structural generation. Prefer a unique exact
    /// physical original; content-only recovery remains at the recorded path.
    private func rebuildSessionRecoveryIndex() {
        var filesByIdentity: [SessionRatingIndex.PersistedIdentityKey: [String]] = [:]
        if !sessionRecoveryEntries.isEmpty {
            for item in items {
                for file in item.individualFiles {
                    if let identity = file.scannedIdentity {
                        filesByIdentity[.init(identity), default: []].append(file.id)
                    }
                }
            }
        }
        sessionRecoveryFileIDs = [:]
        sessionRecoveryRecordIndicesByFileID = [:]
        for (index, record) in sessionRecoveryEntries.enumerated() {
            let physicalIDs = record.entry.fileIdentity.flatMap { filesByIdentity[.init($0)] } ?? []
            let fileID = physicalIDs.count == 1 ? physicalIDs[0] : record.entry.filename
            guard itemIndexByFileID[fileID] != nil else { continue }
            sessionRecoveryFileIDs[record.id] = fileID
            sessionRecoveryRecordIndicesByFileID[fileID, default: []].append(index)
            if record.resolvedFileID == nil { sessionContentPendingFileIDs.insert(fileID) }
        }
        for item in items {
            for file in item.individualFiles where !SessionRecoveryPolicy.isUntouched(file.metadataSnapshot)
                && sessionContentProofs[file.id]?.identity != file.scannedIdentity {
                sessionContentPendingFileIDs.insert(file.id)
            }
        }
    }

    private func sessionFile(forID id: String) -> PhotoFile? {
        guard let index = itemIndexByFileID[id], items.indices.contains(index) else { return nil }
        return items[index].individualFiles.first { $0.id == id }
    }

    private func applyGroupedReviewLayoutIfNeeded() {
        // Membership is computed by the detached analysis owner. While a new
        // sensitivity or mode is pending, retain the completed projection.
        guard groupedReviewMode != .off,
              let cached = duplicateBurstGroupCache,
              cached.mode == groupedReviewMode else { return }
        preparedIndex.applyGroupedReview(cached.groups, to: items)
    }

    private func hasCompletedGroupedReview(_ mode: DuplicateBurstAnalysis.ReviewMode) -> Bool {
        guard let cached = duplicateBurstGroupCache, cached.mode == mode else { return false }
        switch mode {
        case .captureBursts: return cached.interval == burstGroupingInterval
        case .likelySimilarPhotos: return cached.distance == visualSimilarityDistance
        case .exactDuplicates: return true
        case .off: return false
        }
    }

    // MARK: - Duplicate + burst grouped review

    /// Starts one local, cancellable pass without changing the current layout.
    /// A later request for a review mode reuses this in-memory result until the
    /// session structure or a scanned content identity changes.
    func analyzeDuplicateAndBurstGroups() {
        guard case .ready = phase,
              !items.isEmpty,
              !isFileOperationRunning,
              !isXMPPublicationRunning else { return }
        beginDuplicateBurstAnalysis(entering: groupedReviewMode == .off ? nil : groupedReviewMode)
    }

    /// Enters a specific, separately explained grouped layout. Exact-file,
    /// visual, and capture-time evidence intentionally do not mix in one
    /// ambiguous list. If needed, analysis happens first and then applies only
    /// to the unchanged session generation that requested it.
    func enterGroupedReview(_ mode: DuplicateBurstAnalysis.ReviewMode) {
        guard mode != .off else {
            exitGroupedReview()
            return
        }
        guard case .ready = phase,
              !isFileOperationRunning,
              !isXMPPublicationRunning else { return }
        if let result = duplicateBurstAnalysisResult, result.supports(mode),
           duplicateBurstAnalysisMatchesCurrentItems() {
            if !hasCompletedGroupedReview(mode) {
                beginDuplicateBurstGrouping(result, mode: mode)
                return
            }
            // A cached explicit request supersedes an outstanding request too.
            cancelDuplicateBurstAnalysis()
            groupedReviewMode = mode
            applyFilter()
        } else {
            beginDuplicateBurstAnalysis(entering: mode)
        }
    }

    func exitGroupedReview() {
        cancelDuplicateBurstAnalysis()
        guard groupedReviewMode != .off else { return }
        groupedReviewMode = .off
        applyFilter()
    }

    func cancelDuplicateBurstAnalysis() {
        guard isDuplicateBurstAnalysisRunning else { return }
        duplicateBurstAnalysisGeneration &+= 1
        duplicateBurstAnalysisTask?.cancel()
        duplicateBurstAnalysisTask = nil
        if let cached = duplicateBurstGroupCache, cached.mode == groupedReviewMode {
            if groupedReviewMode == .captureBursts {
                burstGroupingInterval = cached.interval
                reviewDefaults.set(cached.interval, forKey: Self.burstGroupingIntervalKey)
            } else if groupedReviewMode == .likelySimilarPhotos {
                visualSimilarityDistance = cached.distance
            }
        }
        duplicateBurstAnalysisState = duplicateBurstAnalysisResult == nil
            ? .idle
            : .ready
    }

    func setVisualSimilarityDistance(_ distance: Int) {
        let clamped = min(max(distance, 3), 16)
        guard visualSimilarityDistance != clamped else { return }
        visualSimilarityDistance = clamped
        guard groupedReviewMode == .likelySimilarPhotos,
              let result = duplicateBurstAnalysisResult else { return }
        beginDuplicateBurstGrouping(result, mode: .likelySimilarPhotos)
    }

    func setBurstGroupingInterval(_ interval: TimeInterval) {
        guard interval.isFinite else { return }
        let clamped = min(max(interval, CaptureBurstIntervalInput.range.lowerBound), CaptureBurstIntervalInput.range.upperBound)
        guard burstGroupingInterval != clamped else { return }
        burstGroupingInterval = clamped
        reviewDefaults.set(clamped, forKey: Self.burstGroupingIntervalKey)
        guard groupedReviewMode == .captureBursts,
              let result = duplicateBurstAnalysisResult else { return }
        beginDuplicateBurstGrouping(result, mode: .captureBursts)
    }

    private func beginDuplicateBurstGrouping(
        _ result: DuplicateBurstAnalysis.Result,
        mode: DuplicateBurstAnalysis.ReviewMode
    ) {
        duplicateBurstAnalysisTask?.cancel()
        duplicateBurstAnalysisGeneration &+= 1
        let generation = duplicateBurstAnalysisGeneration
        let interval = burstGroupingInterval
        let distance = visualSimilarityDistance
        let revisions = duplicateBurstAnalysisRevisions
        let group = duplicateBurstGrouping
        duplicateBurstRequestedCurrentID = currentItemID
        duplicateBurstRequestedSelectionIDs = selectionState.itemIDs
        duplicateBurstAnalysisState = .analyzing
        duplicateBurstAnalysisTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()
                let groups = try await group(result, mode, distance, interval)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.finishDuplicateBurstAnalysis(result, generation: generation,
                        requestedMode: mode, revisions: revisions,
                        groups: groups, distance: distance, interval: interval)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishDuplicateBurstAnalysisCancellation(generation: generation)
                }
            }
        }
    }

    private func beginDuplicateBurstAnalysis(
        entering requestedMode: DuplicateBurstAnalysis.ReviewMode?
    ) {
        duplicateBurstAnalysisTask?.cancel()
        duplicateBurstAnalysisGeneration &+= 1
        let generation = duplicateBurstAnalysisGeneration
        let inputs = DuplicateBurstAnalysis.inputs(from: items,
            mode: requestedMode == .captureBursts ? .captureBursts : .all)
        let revisions = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0.contentRevision) }
        )
        duplicateBurstAnalysisRevisions = revisions
        duplicateBurstRequestedCurrentID = currentItemID
        duplicateBurstRequestedSelectionIDs = selectionState.itemIDs
        duplicateBurstAnalysisState = .analyzing
        let interval = burstGroupingInterval
        let distance = visualSimilarityDistance
        let group = duplicateBurstGrouping
        duplicateBurstAnalysisTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try DuplicateBurstAnalysis.analyze(
                    inputs, mode: requestedMode == .captureBursts ? .captureBursts : .all
                )
                try Task.checkCancellation()
                let groups: [DuplicateBurstAnalysis.Group]?
                if let requestedMode {
                    groups = try await group(result, requestedMode, distance, interval)
                } else {
                    groups = nil
                }
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.finishDuplicateBurstAnalysis(
                        result, generation: generation, requestedMode: requestedMode,
                        revisions: revisions, groups: groups, distance: distance, interval: interval
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishDuplicateBurstAnalysisCancellation(generation: generation)
                }
            }
        }
    }

    private func finishDuplicateBurstAnalysis(
        _ result: DuplicateBurstAnalysis.Result,
        generation: UInt64,
        requestedMode: DuplicateBurstAnalysis.ReviewMode?,
        revisions: [String: PhotoContentRevision],
        groups: [DuplicateBurstAnalysis.Group]?,
        distance: Int,
        interval: TimeInterval
    ) {
        guard generation == duplicateBurstAnalysisGeneration else { return }
        guard duplicateBurstAnalysisMatchesCurrentItems(revisions) else {
            invalidateDuplicateBurstAnalysis(rebuildLayout: true)
            return
        }
        duplicateBurstAnalysisTask = nil
        duplicateBurstAnalysisResult = result
        duplicateBurstAnalysisRevisions = revisions
        let selectionUnchanged = duplicateBurstRequestedCurrentID == currentItemID
            && duplicateBurstRequestedSelectionIDs == selectionState.itemIDs
        if let requestedMode, let groups {
            let sensitivityChanged = (requestedMode == .captureBursts && interval != burstGroupingInterval)
                || (requestedMode == .likelySimilarPhotos && distance != visualSimilarityDistance)
            if sensitivityChanged {
                if selectionUnchanged || groupedReviewMode == requestedMode {
                    beginDuplicateBurstGrouping(result, mode: requestedMode)
                } else {
                    duplicateBurstAnalysisState = .ready
                }
                return
            }
            if selectionUnchanged || groupedReviewMode == .off || groupedReviewMode == requestedMode {
                duplicateBurstGroupCache = (requestedMode, distance, interval, groups)
            }
        } else {
            duplicateBurstGroupCache = nil
        }
        duplicateBurstAnalysisState = .ready
        if let requestedMode, selectionUnchanged { groupedReviewMode = requestedMode }
        if groupedReviewMode != .off { applyFilter(preservingCurrent: true) }
    }

    private func finishDuplicateBurstAnalysisCancellation(generation: UInt64) {
        guard generation == duplicateBurstAnalysisGeneration else { return }
        duplicateBurstAnalysisTask = nil
        duplicateBurstAnalysisState = duplicateBurstAnalysisResult == nil
            ? .idle
            : .ready
    }

    private func duplicateBurstAnalysisMatchesCurrentItems(
        _ expected: [String: PhotoContentRevision]? = nil
    ) -> Bool {
        let revisions = expected ?? duplicateBurstAnalysisRevisions
        guard revisions.count == items.count else { return false }
        return items.allSatisfy { revisions[$0.id] == $0.contentRevision }
    }

    /// Structural session changes must not let an old detached read appear as
    /// a current result. This does not touch media and keeps the normal review
    /// layout immediately usable.
    private func invalidateDuplicateBurstAnalysis(rebuildLayout: Bool) {
        duplicateBurstAnalysisGeneration &+= 1
        duplicateBurstAnalysisTask?.cancel()
        duplicateBurstAnalysisTask = nil
        duplicateBurstAnalysisResult = nil
        duplicateBurstGroupCache = nil
        duplicateBurstAnalysisRevisions = [:]
        duplicateBurstAnalysisState = .idle
        let wasGrouped = groupedReviewMode != .off
        groupedReviewMode = .off
        if rebuildLayout, wasGrouped, !items.isEmpty {
            applyFilter()
        }
    }

    /// Review metadata is lock-backed and therefore does not replace the
    /// `PhotoItem` value. Refresh only a prepared sort/filter that depends on
    /// the changed dimension, then publish the new scalar snapshot to tiles.
    private func publishMetadataMutation(
        _ dimension: MetadataDimension,
        affectedFileIDs: [String],
        preservingCurrent: Bool = false
    ) {
        sessionContentPendingFileIDs.formUnion(affectedFileIDs)
        let changesSort: Bool
        let changesFilter: Bool
        switch dimension {
        case .decision:
            changesSort = sort.key == .decision
            changesFilter = !filter.excludedDecisionStates.isEmpty
        case .stars:
            changesSort = sort.key == .starRating
            changesFilter = !filter.excludedStarStates.isEmpty
        case .color:
            changesSort = sort.key == .colorLabel
            changesFilter = !filter.excludedColorStates.isEmpty
        case .all:
            changesSort = sort.key == .decision
                || sort.key == .starRating
                || sort.key == .colorLabel
            changesFilter = !filter.excludedDecisionStates.isEmpty
                || !filter.excludedStarStates.isEmpty
                || !filter.excludedColorStates.isEmpty
        }
        if changesSort {
            preparedIndex.rebuildPreparedSort(items, sort: sort)
        }
        if changesSort || changesFilter {
            applyFilter(preservingCurrent: preservingCurrent)
        }
        objectWillChange.send()
    }

    private func publishPreparedVisibility() {
        visibleIndices = preparedIndex.visibleIndices
        visibleGroups = preparedIndex.visibleGroups
        visibleGroupTitles = preparedIndex.visibleGroupTitles
    }

    /// Rebuild all values derived from session structure in one pass. Ratings
    /// use incremental updates during normal culling; structural operations are
    /// rare enough that a single complete rebuild is clearer and safer.
    private func rebuildDerivedData() {
        var tally = (yes: 0, no: 0, undecided: 0)
        var mixed = 0
        var stars: [StarRating: Int] = [:]
        var unratedStars = 0
        var mixedStars = 0
        var colors: [PhotoColorLabel: Int] = [:]
        var noColor = 0
        var mixedColors = 0
        var types: [String: Int] = [:]
        var mediaKinds: [MediaKind: Int] = [:]
        var cameras: [String: Int] = [:]
        var lenses: [String: Int] = [:]
        var videoResolutions: [String: Int] = [:]
        var videoCodecs: [String: Int] = [:]
        var subfolders: [String: Int] = [:]
        var dates: [Date: Int] = [:]
        var unknownDates = 0
        var minimumAperture: Double?
        var maximumAperture: Double?
        var minimumShutter: Double?
        var maximumShutter: Double?
        var minimumISO: Double?
        var maximumISO: Double?
        var minimumDuration: Double?
        var maximumDuration: Double?
        var minimumVideoFrameRate: Double?
        var maximumVideoFrameRate: Double?
        for item in items {
            let metadata = item.metadataState
            // Keep the three public counts exhaustive: mixed pairs are
            // unresolved and therefore included in `undecidedCount`.
            switch metadata.decision {
            case .yes:
                tally.yes += 1
            case .no:
                tally.no += 1
            case .undecided:
                tally.undecided += 1
            case .mixed:
                tally.undecided += 1
                mixed += 1
            }
            switch metadata.stars {
            case .unrated: unratedStars += 1
            case .stars(let rating): stars[rating, default: 0] += 1
            case .mixed: mixedStars += 1
            }
            switch metadata.color {
            case .none: noColor += 1
            case .label(let label): colors[label, default: 0] += 1
            case .mixed: mixedColors += 1
            }
            types[item.fileTypeLabel, default: 0] += 1
            mediaKinds[item.mediaKind, default: 0] += 1
            cameras[item.cameraLabel, default: 0] += 1
            lenses[item.lensLabel, default: 0] += 1
            subfolders[item.subfolderLabel, default: 0] += 1
            if let day = item.captureDay {
                dates[day, default: 0] += 1
            } else {
                unknownDates += 1
            }
            if let aperture = item.aperture {
                minimumAperture = minimumAperture.map { min($0, aperture) } ?? aperture
                maximumAperture = maximumAperture.map { max($0, aperture) } ?? aperture
            }
            if let shutter = item.shutterSpeed {
                minimumShutter = minimumShutter.map { min($0, shutter) } ?? shutter
                maximumShutter = maximumShutter.map { max($0, shutter) } ?? shutter
            }
            if let iso = item.iso {
                minimumISO = minimumISO.map { min($0, iso) } ?? iso
                maximumISO = maximumISO.map { max($0, iso) } ?? iso
            }
            if let duration = item.duration, duration.isFinite, duration >= 0 {
                minimumDuration = minimumDuration.map { min($0, duration) } ?? duration
                maximumDuration = maximumDuration.map { max($0, duration) } ?? duration
            }
            if item.isVideo {
                videoResolutions[
                    item.videoResolutionLabel ?? "Unknown resolution",
                    default: 0
                ] += 1
                videoCodecs[item.videoCodec ?? "Unknown video codec", default: 0] += 1
                if let frameRate = item.videoFrameRate,
                   frameRate.isFinite,
                   frameRate > 0 {
                    minimumVideoFrameRate = minimumVideoFrameRate.map {
                        min($0, frameRate)
                    } ?? frameRate
                    maximumVideoFrameRate = maximumVideoFrameRate.map {
                        max($0, frameRate)
                    } ?? frameRate
                }
            }
        }
        ratingTally = tally
        mixedRatingCount = mixed
        starTally = stars
        unratedStarCountStorage = unratedStars
        mixedStarCountStorage = mixedStars
        colorTally = colors
        noColorCountStorage = noColor
        mixedColorCountStorage = mixedColors
        typeCounts = types
        mediaKindCounts = mediaKinds
        cameraCounts = cameras
        lensCounts = lenses
        videoResolutionCounts = videoResolutions
        videoCodecCounts = videoCodecs
        subfolderCounts = subfolders
        availableTypes = types.keys.sorted()
        availableMediaKinds = [.photo, .video, .audio, .text].filter {
            mediaKinds[$0] != nil
        }
        availableCameras = cameras.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        availableLenses = lenses.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // "None" (the folder root) always lists last, like the date list's
        // "Unknown date" entry.
        var subfolderLabels = subfolders.keys
            .filter { $0 != "None" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if subfolders["None"] != nil { subfolderLabels.append("None") }
        availableSubfolders = subfolderLabels
        availableCaptureDates = dates.keys.sorted()
        captureDateCounts = dates
        unknownDateCount = unknownDates
        captureDateRange = availableCaptureDates.first.flatMap { first in
            availableCaptureDates.last.map { first...$0 }
        }
        apertureRange = Self.closedRange(minimum: minimumAperture, maximum: maximumAperture)
        shutterRange = Self.closedRange(minimum: minimumShutter, maximum: maximumShutter)
        isoRange = Self.closedRange(minimum: minimumISO, maximum: maximumISO)
        durationRange = Self.closedRange(minimum: minimumDuration, maximum: maximumDuration)
        videoFrameRateRange = Self.closedRange(
            minimum: minimumVideoFrameRate,
            maximum: maximumVideoFrameRate
        )
        if let activeID = videoPlayback.itemID,
           let activeItem = items.first(where: { $0.id == activeID }) {
            if !videoPlayback.represents(activeItem) {
                videoPlayback.stop()
            }
        } else if videoPlayback.itemID != nil {
            videoPlayback.stop()
        }
        rebuildStructuralIndices()
        if sourceFolder != nil { startQualityCueAnalysis() }
        if let sourceFolder {
            rawJPEGPairs = FolderScanner.rawJPEGPairs(
                from: items,
                root: sourceFolder
            )
        } else {
            rawJPEGPairs = []
        }
    }

    private static func closedRange(minimum: Double?, maximum: Double?) -> ClosedRange<Double>? {
        guard let minimum, let maximum else { return nil }
        return minimum...maximum
    }

    /// Folder-wide ranges are the neutral filter state. Existing narrowed
    /// ranges survive a re-scan and are clamped to the newly discovered span;
    /// untouched ranges expand to the new full span automatically.
    /// Returns true when assigning the synchronized filter already caused its
    /// `didSet` observer to run `applyFilter()`.
    @discardableResult
    private func synchronizeFilterRangesWithAvailableData() -> Bool {
        var updated = filter
        updated.excludedTypes.formIntersection(availableTypes)
        updated.excludedMediaKinds.formIntersection(availableMediaKinds)
        updated.excludedCameras.formIntersection(availableCameras)
        updated.excludedLenses.formIntersection(availableLenses)
        updated.excludedVideoResolutions.formIntersection(availableVideoResolutions)
        updated.excludedVideoCodecs.formIntersection(availableVideoCodecs)
        updated.excludedSubfolders.formIntersection(availableSubfolders)
        updated.excludedDates.formIntersection(availableCaptureDates)

        if let available = captureDateRange {
            if updated.dateMode == .range, updated.dateEnabled {
                updated.dateFrom = Self.clamp(updated.dateFrom, to: available)
                updated.dateTo = Self.clamp(updated.dateTo, to: available)
            } else {
                updated.dateFrom = available.lowerBound
                updated.dateTo = available.upperBound
            }
        }
        updated.dateEnabled = dateFilterHasEffect(updated)

        let aperture = Self.synchronizedNumericRange(
            from: updated.apertureFrom,
            to: updated.apertureTo,
            wasActive: updated.apertureEnabled,
            available: apertureRange
        )
        updated.apertureFrom = aperture.from
        updated.apertureTo = aperture.to
        updated.apertureEnabled = aperture.isActive

        let shutter = Self.synchronizedNumericRange(
            from: updated.shutterFrom,
            to: updated.shutterTo,
            wasActive: updated.shutterEnabled,
            available: shutterRange
        )
        updated.shutterFrom = shutter.from
        updated.shutterTo = shutter.to
        updated.shutterEnabled = shutter.isActive

        let iso = Self.synchronizedNumericRange(
            from: updated.isoFrom,
            to: updated.isoTo,
            wasActive: updated.isoEnabled,
            available: isoRange
        )
        updated.isoFrom = iso.from
        updated.isoTo = iso.to
        updated.isoEnabled = iso.isActive

        let duration = Self.synchronizedNumericRange(
            from: updated.durationFrom,
            to: updated.durationTo,
            wasActive: updated.durationEnabled,
            available: durationRange
        )
        updated.durationFrom = duration.from
        updated.durationTo = duration.to
        updated.durationEnabled = duration.isActive

        let videoFrameRate = Self.synchronizedNumericRange(
            from: updated.videoFrameRateFrom,
            to: updated.videoFrameRateTo,
            wasActive: updated.videoFrameRateEnabled,
            available: videoFrameRateRange
        )
        updated.videoFrameRateFrom = videoFrameRate.from
        updated.videoFrameRateTo = videoFrameRate.to
        updated.videoFrameRateEnabled = videoFrameRate.isActive

        guard updated != filter else { return false }
        filter = updated
        return true
    }

    /// Restores the visible controls to their folder-wide defaults. This is
    /// deliberately different from a bare `PhotoFilter()` because DatePicker
    /// selections must already lie inside the current folder's limits.
    func resetFilter(keepersOnly: Bool = false) {
        var reset = PhotoFilter()
        if keepersOnly { reset.excludedDecisionStates = [.no, .undecided, .mixed] }
        if let available = captureDateRange {
            reset.dateFrom = available.lowerBound
            reset.dateTo = available.upperBound
        }
        if let available = apertureRange {
            reset.apertureFrom = available.lowerBound
            reset.apertureTo = available.upperBound
        }
        if let available = shutterRange {
            reset.shutterFrom = available.lowerBound
            reset.shutterTo = available.upperBound
        }
        if let available = isoRange {
            reset.isoFrom = available.lowerBound
            reset.isoTo = available.upperBound
        }
        if let available = durationRange {
            reset.durationFrom = available.lowerBound
            reset.durationTo = available.upperBound
        }
        if let available = videoFrameRateRange {
            reset.videoFrameRateFrom = available.lowerBound
            reset.videoFrameRateTo = available.upperBound
        }
        filter = reset
    }

    /// Keeps any other active criteria, but makes the Media facet show videos
    /// only. The Command Palette uses this as a quick route into the cached
    /// video-detail filters.
    func showVideosOnly() {
        guard availableMediaKinds.contains(.video), !isFileOperationRunning
        else { return }
        var updated = filter
        updated.excludedMediaKinds = Set(
            availableMediaKinds.filter { $0 != .video }
        )
        filter = updated
    }

    private func dateFilterHasEffect(_ candidate: PhotoFilter) -> Bool {
        switch candidate.dateMode {
        case .range:
            guard let available = captureDateRange else { return false }
            return candidate.dateFrom != available.lowerBound || candidate.dateTo != available.upperBound
        case .specificDates:
            return !candidate.excludedDates.isEmpty
                || (unknownDateCount > 0 && candidate.excludesUnknownDate)
        }
    }

    private static func synchronizedNumericRange(
        from: Double,
        to: Double,
        wasActive: Bool,
        available: ClosedRange<Double>?
    ) -> (from: Double, to: Double, isActive: Bool) {
        guard let available else { return (0, 0, false) }
        guard wasActive else { return (available.lowerBound, available.upperBound, false) }
        let from = clamp(from, to: available)
        let to = clamp(to, to: available)
        return (
            from,
            to,
            from != available.lowerBound || to != available.upperBound
        )
    }

    private static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func resetDerivedData() {
        preparedIndex.reset()
        publishPreparedVisibility()
        ratingTally = (0, 0, 0)
        mixedRatingCount = 0
        starTally = [:]
        unratedStarCountStorage = 0
        mixedStarCountStorage = 0
        colorTally = [:]
        noColorCountStorage = 0
        mixedColorCountStorage = 0
        itemIndexByFileID = [:]
        rawJPEGPairs = []
        availableTypes = []
        availableMediaKinds = []
        availableCameras = []
        availableLenses = []
        availableSubfolders = []
        availableCaptureDates = []
        captureDateRange = nil
        apertureRange = nil
        shutterRange = nil
        isoRange = nil
        durationRange = nil
        videoFrameRateRange = nil
        typeCounts = [:]
        mediaKindCounts = [:]
        cameraCounts = [:]
        lensCounts = [:]
        videoResolutionCounts = [:]
        videoCodecCounts = [:]
        subfolderCounts = [:]
        captureDateCounts = [:]
        unknownDateCount = 0
    }

    // MARK: - Opening a folder

    func promptForSourceFolder(initialDirectory: URL? = nil) {
        guard !isFileOperationRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        panel.message = L10n.text("Choose a media folder or external drive to review.")
        panel.prompt = L10n.text("Open Folder")
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        if isRecoveringInterruptedOperations {
            deferredFolderOpen = url
            return
        }
        if hasXMPPublicationSessionState {
            guard !isSessionTransitioning,
                  activeFileOperation == nil,
                  !isPreparingForTermination else { return }
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelAndAwaitXMPPublication()
                self.isExportPresented = false
                self.isSessionTransitioning = false
                self.openFolder(url)
            }
            return
        }
        guard !isFileOperationRunning else { return }
        folderOpenGeneration &+= 1
        let openGeneration = folderOpenGeneration
        if let currentFolder = sourceFolder,
           case .ready = phase {
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self
                    .persistCurrentSessionIfNeededBeforeDiscard()
                guard self.folderOpenGeneration == openGeneration else { return }
                self.isSessionTransitioning = false
                guard result?.canDiscardInMemoryState != false,
                      self.sourceFolder?.standardizedFileURL
                        == currentFolder.standardizedFileURL else { return }
                self.beginOpeningFolder(url)
            }
            return
        }
        beginOpeningFolder(url)
    }

    private func beginOpeningFolder(
        _ url: URL,
        legacySidecarRelocationAuthorization:
            SessionPersistence.LegacySidecarRelocationAuthorization? = nil,
        replaceSavedSession: Bool = false
    ) {
        let standardizedURL = url.standardizedFileURL
        if sourceFolderAccess?.url != standardizedURL {
            let nextAccess = SecurityScopedFolderAccess(url: url)
            sourceFolderAccess?.stop()
            sourceFolderAccess = nextAccess
        }
        #if APP_STORE
        // App Sandbox cannot safely repair a journal before the photographer
        // grants access to its source folder. Once selected, also reopen only
        // the short-lived destinations recorded for that journaled operation.
        if !isRecoveringInterruptedOperations,
           !recoveryNeedsAttention,
           FileOperationJournal.hasPendingOperations(
            directory: operationJournalDirectory
           ) {
            deferredFolderOpen = url
            beginInterruptedOperationRecovery()
            return
        }
        #endif
        resetSessionRecovery()
        cancelScheduledSave()
        persistenceGenerationAccessID = nil
        durableSessionChangeGeneration = nil
        sessionChangeGeneration = 0
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        pendingLegacySidecarRelocationAuthorization = nil
        canOpenMismatchedSessionAnyway = false
        canOpenIdentityConflictAsNewSession = false
        videoPlayback.resetRememberedPositions()
        let isSameFolder =
            sourceFolder?.standardizedFileURL == standardizedURL
        if !isSameFolder {
            actualSizeViewport.reset()
            photoZoomScale = 1
            showClippingWarnings = false
        }
        let preservesCurrentFilter = isSameFolder && !items.isEmpty
        if let override = nextScanResumeIdentityOverride,
            override.folder == standardizedURL {
            scanResumeIdentity = override
            nextScanResumeIdentityOverride = nil
        } else if preservesCurrentFilter {
            nextScanResumeIdentityOverride = nil
            scanResumeIdentity = ScanResumeIdentity(
                folder: standardizedURL,
                currentItemID: currentItemID,
                selectedItemIDs: selectionState.itemIDs
            )
        } else {
            nextScanResumeIdentityOverride = nil
            scanResumeIdentity = nil
        }
        // Every scan establishes a fresh identity/revision access. A retained
        // backup-only Retry belongs to the access being replaced; keeping it
        // through a failed same-folder rescan leaves a visible button whose
        // result can no longer be applied. The new scan/save will recreate a
        // current warning and Retry if the sidecar still needs repair.
        persistenceWarning = nil
        persistenceRejectedInvalidSnapshot = false
        retrySaveRequest = nil
        retrySaveIsOptionalSidecarRepair = false
        persistenceAccess = nil
        if !isSameFolder {
            retainedMissingSessionEntries = []
            organizationOriginFolderPathBytesByFileID = [:]
            deferredOrganizationUndo = nil
        }
        invalidateDuplicateBurstAnalysis(rebuildLayout: false)
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        cleanUpGeneration &+= 1
        sourceFolder = standardizedURL
        scanError = nil
        pairingMetadataError = nil
        phase = .scanning(found: 0)
        // visibleIndices must be cleared in the same turn items is emptied —
        // stale indices into a shrunk array crash any view that renders first.
        visibleIndices = []
        filterDebounce?.cancel()
        filterDebounce = nil
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        setSelectionIndices([])
        items = []
        emptySessionReason = nil
        resetDerivedData()
        if !preservesCurrentFilter {
            filter = PhotoFilter()
            applyReviewDefaults()
        }
        undoStack = []
        isClearAllRatingsConfirmationPresented = false
        pendingCleanUp = nil
        addToRecents(url)
        let pairingMode = rawJPEGPairingMode

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let folderIdentity = try SessionPersistence.SourceFolderIdentity
                    .capture(at: standardizedURL)
                // The scan polls cancellation from parallel metadata workers
                // on GCD threads, where `Task.isCancelled` has no task context
                // and silently reads false. Bridge this task's cancellation
                // into a flag that is valid on any thread.
                let cancelFlag = FolderScanner.CancelFlag()
                let (scanned, savedSession) = try await withTaskCancellationHandler {
                    let scanned = try FolderScanner.scan(
                        standardizedURL,
                        pairingMode: pairingMode,
                        isCancelled: { cancelFlag.isSet }
                    ) { count in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.scanGeneration == generation,
                                  self.sourceFolder == standardizedURL else { return }
                            if case .scanning = self.phase {
                                self.phase = .scanning(found: count)
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard folderIdentity.matches(folder: standardizedURL) else {
                        throw FolderScanner.ScanError.filesChangedDuringScan
                    }
                    let savedSession = await self.persistence.read(
                        for: standardizedURL,
                        folderIdentity: folderIdentity,
                        legacySidecarRelocationAuthorization:
                            legacySidecarRelocationAuthorization
                    )
                    try Task.checkCancellation()
                    try FolderScanner.validateScannedIdentities(
                        scanned,
                        isCancelled: { cancelFlag.isSet }
                    )
                    guard folderIdentity.matches(folder: standardizedURL) else {
                        throw FolderScanner.ScanError.filesChangedDuringScan
                    }
                    try Task.checkCancellation()
                    return (scanned, savedSession)
                } onCancel: {
                    cancelFlag.set()
                }
                await MainActor.run {
                    guard self.scanGeneration == generation else { return }
                    self.scanTask = nil
                    self.finishScan(
                        url: standardizedURL,
                        generation: generation,
                        scanned: scanned,
                        persistenceResult: savedSession,
                        legacySidecarRelocationAuthorization:
                            legacySidecarRelocationAuthorization,
                        replaceSavedSession: replaceSavedSession
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.scanGeneration == generation,
                          self.sourceFolder == standardizedURL else { return }
                    self.scanTask = nil
                    guard !(error is CancellationError) else { return }
                    self.scanError = error.localizedDescription
                    self.phase = .welcome
                }
            }
        }
    }

    func setRawJPEGPairingMode(_ mode: RawJPEGPairingMode) {
        guard mode != rawJPEGPairingMode,
              !isFileOperationRunning,
              !isXMPPublicationRunning else { return }
        invalidateDuplicateBurstAnalysis(rebuildLayout: false)
        let previousMode = rawJPEGPairingMode
        pairingMetadataError = nil
        rawJPEGPairingMode = mode
        guard let folder = sourceFolder, case .ready = phase, !items.isEmpty else { return }

        flushPendingFilter()

        let sourceItems = items
        let currentFileID = items.indices.contains(currentIndex)
            ? items[currentIndex].primaryFile.id
            : nil
        let selectedFileIDs = Set(
            selectedIndices.flatMap { index in
                items.indices.contains(index)
                    ? items[index].individualFiles.map(\.id)
                    : []
            }
        )
        isSessionTransitioning = true
        isChangingRawJPEGPairingMode = true
        let requestedMode = mode
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let projection = try FolderScanner.projectPairingMode(
                    requestedMode,
                    from: sourceItems,
                    root: folder
                )
                await self?.finishPairingModeChange(
                    projection,
                    requestedMode: requestedMode,
                    folder: folder,
                    currentFileID: currentFileID,
                    selectedFileIDs: selectedFileIDs
                )
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.rawJPEGPairingMode == requestedMode,
                          self.sourceFolder == folder,
                          case .ready = self.phase else { return }
                    self.rawJPEGPairingMode = previousMode
                    self.isChangingRawJPEGPairingMode = false
                    self.isSessionTransitioning = false
                    if !(error is CancellationError) {
                        self.pairingMetadataError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func finishPairingModeChange(
        _ projection: FolderScanner.PairingProjection,
        requestedMode: RawJPEGPairingMode,
        folder: URL,
        currentFileID: String?,
        selectedFileIDs: Set<String>
    ) {
        guard rawJPEGPairingMode == requestedMode,
              sourceFolder?.standardizedFileURL == folder.standardizedFileURL,
              case .ready = phase else {
            isChangingRawJPEGPairingMode = false
            isSessionTransitioning = false
            return
        }

        // Change the type facet only after enrichment succeeds, so a failed
        // split leaves the existing review layout and filter untouched.
        var updatedFilter = filter
        updatedFilter.excludedTypes = []
        filter = updatedFilter
        setSelectionIndices([])
        items = projection.items
        emptySessionReason = nil
        rebuildDerivedData()
        let currentItemID = currentFileID.flatMap {
            projection.itemIDByFileID[$0]
        }
        restoreCurrentItem(itemID: currentItemID, fallbackIndex: currentIndex)
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        let selectedItemIDs = Set(
            selectedFileIDs.compactMap { projection.itemIDByFileID[$0] }
        )
        restoreSelection(
            itemIDs: selectedItemIDs,
            visibleOnly: true
        )
        prefetchAroundCurrent()
        isChangingRawJPEGPairingMode = false
        isSessionTransitioning = false
        saveSession()
    }

    /// Stops the active folder walk and returns immediately to the welcome
    /// screen. `closeSession` also advances `scanGeneration`, so any detached
    /// work that finishes after cancellation cannot apply partial results.
    func cancelScan() {
        guard case .scanning = phase else { return }
        closeSession()
    }

    /// Re-read and re-scan after the photographer acknowledges that the exact
    /// legacy sidecar shown on the welcome screen belongs with this folder.
    /// SessionPersistence rejects the authorization if those bytes changed.
    func openMismatchedSessionAnyway() {
        guard case .welcome = phase,
              let folder = sourceFolder,
              let authorization =
                pendingLegacySidecarRelocationAuthorization else { return }
        beginOpeningFolder(
            folder,
            legacySidecarRelocationAuthorization: authorization
        )
    }

    /// Replace stale decisions only after an explicit welcome-screen choice.
    /// The fresh read still establishes the exact sidecar CAS boundary, so an
    /// external edit cannot be overwritten unnoticed while the folder opens.
    func openIdentityConflictAsNewSession() {
        guard case .welcome = phase,
              canOpenIdentityConflictAsNewSession,
              let folder = sourceFolder else { return }
        beginOpeningFolder(
            folder,
            legacySidecarRelocationAuthorization:
                pendingLegacySidecarRelocationAuthorization,
            replaceSavedSession: true
        )
    }

    private func finishScan(
        url: URL,
        generation: UInt64,
        scanned: [PhotoItem],
        persistenceResult: SessionPersistence.ReadResult,
        legacySidecarRelocationAuthorization:
            SessionPersistence.LegacySidecarRelocationAuthorization?,
        replaceSavedSession: Bool
    ) {
        guard sourceFolder == url, scanGeneration == generation else { return }
        if let blockingMessage = persistenceResult.blockingMessage {
            pendingLegacySidecarRelocationAuthorization =
                persistenceResult.legacySidecarRelocationAuthorization
            canOpenMismatchedSessionAnyway =
                pendingLegacySidecarRelocationAuthorization != nil
            scanResumeIdentity = nil
            retainedMissingSessionEntries = []
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            scanError = blockingMessage
            return
        }
        pendingLegacySidecarRelocationAuthorization = nil
        canOpenMismatchedSessionAnyway = false
        let resumeIdentity = scanResumeIdentity.flatMap {
            $0.folder == url.standardizedFileURL ? $0 : nil
        }
        scanResumeIdentity = nil
        nextScanResumeIdentityOverride = nil
        organizationOriginFolderPathBytesByFileID = [:]
        organizationGeneration &+= 1
        organizationProgress = nil
        persistenceRejectedInvalidSnapshot = false
        guard let access = persistenceResult.access else {
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            scanError = L10n.text("Couldn't prepare safe saving for this folder. Nothing was saved; open it again.")
            return
        }
        persistenceAccess = access
        persistenceGenerationAccessID = access.id
        // The freshly read/scanned state is the discard-safe baseline. Its
        // automatic sidecar creation, repair, or schema refresh is optional;
        // only later user/session changes advance beyond this generation.
        durableSessionChangeGeneration = 0
        sessionChangeGeneration = 0
        let loaded = scanned
        sessionRecoveryEntries = replaceSavedSession ? []
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
        if relocatedSessionNeedsIdentityProof && sessionRecoveryEntries.isEmpty {
            items = []
            resetDerivedData()
            visibleIndices = []
            phase = .welcome
            pendingLegacySidecarRelocationAuthorization =
                legacySidecarRelocationAuthorization
            canOpenIdentityConflictAsNewSession = true
            if relocatedLegacySessionHasNoFilenameMatch {
                scanError = L10n.text("No saved filenames match this folder. Saved decisions remain untouched. Open as New Session replaces them and starts current files unrated.")
            } else {
                scanError = L10n.text("This session came from another location; no exact originals could be verified here. Saved decisions remain untouched. Open as New Session replaces them and starts current files unrated.")
            }
            return
        }
        items = loaded
        organizationOriginFolderPathBytesByFileID =
            restoredOrganizationOrigins
        emptySessionReason = nil
        rebuildDerivedData()
        let firstUndecided =
            loaded.firstIndex(where: { $0.rating == .undecided }) ?? 0
        restoreCurrentItem(
            itemID: resumeIdentity?.currentItemID,
            fallbackIndex: firstUndecided
        )
        let filterAlreadyApplied = synchronizeFilterRangesWithAvailableData()
        // Recompute visibility (a re-scan keeps the active filter; it may
        // also snap currentIndex onto a visible photo).
        if !filterAlreadyApplied { applyFilter() }
        if let resumeIdentity {
            restoreSelection(
                itemIDs: resumeIdentity.selectedItemIDs,
                visibleOnly: true
            )
            prefetchAroundCurrent()
        } else if let first = visibleIndices.first(where: {
            items[$0].rating == .undecided
        }) ?? visibleIndices.first {
            // A new folder starts at the first pending item in its chosen
            // default order, rather than the scanner's chronological order.
            currentIndex = first
            prefetchAroundCurrent()
        }
        phase = loaded.isEmpty ? .welcome : .ready
        startSessionContentChecks()
        if !loaded.isEmpty, let organizationUndo = deferredOrganizationUndo {
            deferredOrganizationUndo = nil
            pushUndo(.organization(organizationUndo))
        }
        if loaded.isEmpty {
            scanError = L10n.text("No recognised media was found in “\(url.lastPathComponent)”. Choose another folder or check Supported Formats.")
        } else if replaceSavedSession {
            // Replacing the old snapshot is an explicit user change, not
            // optional maintenance of the just-opened baseline.
            persistenceWarning = nil
            markSessionChanged()
            saveSession()
        } else if legacySessionNeedsConfirmation {
            persistenceWarning = persistenceResult.recoveryMessage
            legacySessionMigrationMissingFileCount =
                unmatchedLegacyPhysicalFileCount
            legacySessionMigrationUsesUnownedBackup =
                persistenceResult.requiresPhysicalIdentityProof
            isLegacySessionMigrationConfirmationPresented = true
        } else {
            persistenceWarning = persistenceResult.recoveryMessage
            saveSession()
        }
    }

    /// Accept the exact filename matches from a legacy snapshot and persist
    /// their first physical-identity-bound schema-4 checkpoint.
    func confirmLegacySessionMigration() {
        guard isLegacySessionMigrationConfirmationPresented,
              case .ready = phase,
              sourceFolder != nil else { return }
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        // Forgetting absent legacy entries is an explicit session change, not
        // optional maintenance of the just-opened baseline.
        markSessionChanged()
        saveSession()
    }

    /// Leave the legacy sidecar and backup byte-for-byte untouched.
    func closeLegacySessionWithoutMigrating() {
        guard isLegacySessionMigrationConfirmationPresented else { return }
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        finishClosingSession()
    }

#if DEBUG
    /// Focused key-routing tests use an ordinary in-memory ready session and
    /// need to exercise the same modal command gate as the real scan flow.
    func presentLegacySessionMigrationConfirmationForTesting() {
        guard case .ready = phase else { return }
        isLegacySessionMigrationConfirmationPresented = true
    }
#endif

    /// Re-scan the current folder to pick up newly added photos.
    /// Existing ratings survive: they're saved to the sidecar first,
    /// and the scan restores them by filename.
    func rescan() {
        if hasXMPPublicationSessionState {
            guard !isSessionTransitioning,
                  activeFileOperation == nil,
                  !isPreparingForTermination else { return }
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelAndAwaitXMPPublication()
                self.isExportPresented = false
                self.isSessionTransitioning = false
                self.rescan()
            }
            return
        }
        guard !isFileOperationRunning, let folder = sourceFolder else { return }
        isSessionTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self
                .persistCurrentSessionIfNeededBeforeDiscard()
            self.isSessionTransitioning = false
            guard result?.canDiscardInMemoryState != false else { return }
            guard self.sourceFolder == folder else { return }
            self.beginOpeningFolder(folder)
        }
    }

    // MARK: - Multi-selection

    /// What a rating (F/D) applies to: the multi-selection when one is
    /// active, otherwise just the current photo.
    var effectiveSelection: Set<Int> {
        if selectedIndices.isEmpty, preparedIndex.location(forItemIndex: currentIndex) == nil { return [] }
        return selectionState.effectiveSelection(
            currentIndex: currentIndex,
            visibleIndices: visibleIndices,
            itemCount: items.count
        )
    }

    var effectiveDecisionState: PhotoItemRatingState {
        commonSelectionValue(\.ratingState, empty: .undecided, mixed: .mixed)
    }

    var effectiveStarRatingState: PhotoItemStarRatingState {
        commonSelectionValue(\.starRatingState, empty: .unrated, mixed: .mixed)
    }

    var effectiveColorLabelState: PhotoItemColorLabelState {
        commonSelectionValue(\.colorLabelState, empty: .none, mixed: .mixed)
    }

    private func commonSelectionValue<Value: Equatable>(
        _ keyPath: KeyPath<PhotoItem, Value>,
        empty: Value,
        mixed: Value
    ) -> Value {
        var first: Value?
        for index in effectiveSelection where items.indices.contains(index) {
            let value = items[index][keyPath: keyPath]
            if let first {
                if value != first { return mixed }
            } else {
                first = value
            }
        }
        return first ?? empty
    }

    var multiSelectionSummary: PhotoSelectionSummary? {
        guard selectedIndices.count > 1 else { return nil }
        if let cachedSelectionSummary { return cachedSelectionSummary }
        let selectedItems = selectedIndices.compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
        guard selectedItems.count > 1 else { return nil }
        let summary = PhotoSelectionSummary(items: selectedItems)
        cachedSelectionSummary = summary
        return summary
    }

    func clearSelection() {
        setSelectionIndices([])
    }

    /// Routes a thumbnail click by modifier key — shared by the Browser and
    /// Grid views so both respond identically. `plainClick` runs when no
    /// modifier is held; both views use it to make the clicked photo current.
    func handleThumbnailClick(
        at index: Int,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
        plainClick: () -> Void
    ) {
        guard !isFileOperationRunning else { return }
        if modifiers.contains(.shift) {
            selectRange(to: index)
        } else if modifiers.contains(.command) {
            toggleSelection(of: index)
        } else {
            plainClick()
        }
    }

    /// ⇧-click: select every visible photo between the current one (the
    /// anchor) and the clicked one, both included. The anchor stays current,
    /// so another ⇧-click re-ranges from the same photo.
    func selectRange(to index: Int) {
        guard !isFileOperationRunning else { return }
        let changed = selectionState.selectRange(
            from: currentIndex,
            to: index,
            visibleIndices: visibleIndices,
            items: items,
            preparedIndex: preparedIndex
        )
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// ⌘-click: add or remove a single photo.
    func toggleSelection(of index: Int) {
        guard !isFileOperationRunning else { return }
        let previousIndices = selectionState.indices
        let replacementCurrent = selectionState.toggle(
            index,
            currentIndex: currentIndex,
            visibleIndices: visibleIndices,
            items: items
        )
        if selectionState.indices != previousIndices {
            selectedIndices = selectionState.indices
        }
        // Keep the current photo inside the selection so F/D act where expected.
        if let replacementCurrent {
            currentIndex = replacementCurrent
            prefetchAroundCurrent()
        }
    }

    /// ⌘⇧← / ⌘⇧→: select from the current photo to the first or last
    /// visible photo, current one included.
    func selectToEdge(forward: Bool) {
        guard !isFileOperationRunning else { return }
        let changed = selectionState.selectToEdge(
            from: currentIndex,
            forward: forward,
            visibleIndices: visibleIndices,
            items: items,
            preparedIndex: preparedIndex
        )
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// ⌘A: select every photo that passes the current filter.
    func selectAllVisible() {
        guard !isFileOperationRunning else { return }
        let changed = selectionState.selectAllVisible(
            visibleIndices,
            items: items
        )
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// Rubber-band drag in the Grid view: the selection follows the
    /// rectangle live. `currentIndex` is deliberately left alone here —
    /// moving it mid-drag would auto-scroll the grid under the cursor.
    func setSelection(_ indices: Set<Int>) {
        guard !isFileOperationRunning else { return }
        // Called on every drag tick; the pure state skips publication (and the
        // grid/toolbar rebuilds it triggers) when the hit-tested set is equal.
        let changed = selectionState.updateRubberBand(indices, items: items)
        if changed {
            selectedIndices = selectionState.indices
        }
    }

    /// After a rubber-band drag ends, park the current photo on a selected
    /// one so the keyboard rates what the user just outlined.
    func commitSelectionAnchor() {
        guard !isFileOperationRunning else { return }
        guard let anchor =
                selectionState.committedAnchor(currentIndex: currentIndex)
        else { return }
        currentIndex = anchor
        prefetchAroundCurrent()
    }

    // MARK: - Rating

    /// Rates the current photo or selection as one undoable decision. The
    /// preference applies to this review command; individual tile controls,
    /// stars, and colors keep their existing non-advancing behavior.
    func rate(_ rating: Rating) {
        guard canRate else { return }
        flushPendingFilter()
        let targets = effectiveSelection.sorted()
        guard !targets.isEmpty else { return }
        // Retain the displayed order before a decision can change its filter
        // membership or sort position. Advancing from the post-filter current
        // photo would skip the next undecided item.
        let previousOrder = visibleIndices
        let previousIndex = currentIndex
        let previousPosition = preparedIndex.location(forItemIndex: currentIndex)?.position
        applyRating(rating, to: targets)
        if ReviewPreferences.load(from: reviewDefaults).advancesAfterDecision {
            setSelectionIndices([])
            advanceAfterDecision(
                position: previousPosition,
                in: previousOrder
            )
        } else if preparedIndex.location(forItemIndex: previousIndex) == nil {
            // Staying cannot retain a hidden photo. Choose the nearest
            // surviving selection, then the nearest item in the old order.
            restoreVisibleCurrentAfterDecision(
                position: previousPosition,
                in: previousOrder
            )
        }
    }

    /// Grid rating-control click: cycle the clicked photo's rating. Using the
    /// control on a photo that's part of a multi-selection gives the whole
    /// selection the clicked photo's next rating in one undoable step; the
    /// selection stays so the user can keep cycling.
    func toggleRating(at index: Int) {
        guard canRate else { return }
        guard items.indices.contains(index) else { return }
        let next: Rating
        switch items[index].rating {
        case .undecided: next = .yes
        case .yes: next = .no
        case .no: next = .undecided
        }
        if selectedIndices.count > 1, selectedIndices.contains(index) {
            applyRating(next, to: selectedIndices.sorted())
        } else {
            setIndex(index)
            setRating(next, atIndex: index, recordUndo: true)
        }
    }

    /// An explicit rating action for VoiceOver media tiles. Unlike the F/D
    /// review flow this does not advance afterward, because the accessible
    /// action menu belongs to one stable tile. If that tile is part of a
    /// multi-selection, the action follows Grid click behavior and rates the
    /// whole selection in one undoable step.
    func rate(_ rating: Rating, at index: Int) {
        guard canRate else { return }
        guard items.indices.contains(index) else { return }
        if selectedIndices.count > 1, selectedIndices.contains(index) {
            applyRating(rating, to: selectedIndices.sorted())
        } else {
            setIndex(index)
            setRating(rating, atIndex: index, recordUndo: true)
        }
    }

    /// Applies one rating to several photos as a single undoable step.
    private func applyRating(_ rating: Rating, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.flatMap { index in
            items[index].metadataSnapshots.map { MetadataChange(previous: $0) }
        }
        pushUndo(.metadata(.decision, changes, previousFileID: currentItemID))
        let now = Date()
        // Ratings live in shared lock-backed storage whose reference identity
        // does not change. Update it first, then publish once so lazy Browser
        // and Grid rows cannot redraw the old snapshot and miss the mutation.
        for index in valid {
            let previousState = items[index].ratingState
            items[index].setRating(rating, ratedAt: now)
            transitionRatingCount(
                from: previousState,
                to: items[index].ratingState
            )
        }
        publishMetadataMutation(.decision, affectedFileIDs: changes.map { $0.previous.fileID })
        scheduleSave()
    }

    private func setRating(_ rating: Rating, atIndex index: Int, recordUndo: Bool) {
        guard items.indices.contains(index) else { return }
        if recordUndo {
            let changes = items[index].metadataSnapshots.map {
                MetadataChange(previous: $0)
            }
            pushUndo(.metadata(.decision, changes, previousFileID: currentItemID))
        }
        let previousState = items[index].ratingState
        items[index].setRating(rating, ratedAt: Date())
        transitionRatingCount(
            from: previousState,
            to: items[index].ratingState
        )
        publishMetadataMutation(.decision, affectedFileIDs: items[index].individualFiles.map(\.id))
        scheduleSave()
    }

    /// Applies stars independently of the Yes/No decision. Numeric shortcuts
    /// and the Info panel use this batch-aware entry point and never advance.
    func setStarRating(_ rating: StarRating?) {
        guard canRate else { return }
        applyStarRating(rating, to: effectiveSelection.sorted())
    }

    func setStarRating(_ rating: StarRating?, at index: Int) {
        guard canRate, items.indices.contains(index) else { return }
        let targets = selectedIndices.count > 1 && selectedIndices.contains(index)
            ? selectedIndices.sorted()
            : [index]
        applyStarRating(rating, to: targets)
    }

    private func applyStarRating(_ rating: StarRating?, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.flatMap { index in
            items[index].metadataSnapshots.map { MetadataChange(previous: $0) }
        }
        pushUndo(.metadata(.stars, changes, previousFileID: currentItemID))
        let now = Date()
        for index in valid {
            let previousState = items[index].starRatingState
            items[index].setStars(rating, changedAt: now)
            transitionStarCount(from: previousState, to: items[index].starRatingState)
        }
        publishMetadataMutation(.stars, affectedFileIDs: changes.map { $0.previous.fileID })
        scheduleSave()
    }

    /// Applies a color label independently of decision and stars.
    func setColorLabel(_ label: PhotoColorLabel?) {
        guard canRate else { return }
        applyColorLabel(label, to: effectiveSelection.sorted())
    }

    func setColorLabel(_ label: PhotoColorLabel?, at index: Int) {
        guard canRate, items.indices.contains(index) else { return }
        let targets = selectedIndices.count > 1 && selectedIndices.contains(index)
            ? selectedIndices.sorted()
            : [index]
        applyColorLabel(label, to: targets)
    }

    private func applyColorLabel(_ label: PhotoColorLabel?, to targets: [Int]) {
        let valid = targets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let changes = valid.flatMap { index in
            items[index].metadataSnapshots.map { MetadataChange(previous: $0) }
        }
        pushUndo(.metadata(.color, changes, previousFileID: currentItemID))
        let now = Date()
        for index in valid {
            let previousState = items[index].colorLabelState
            items[index].setColor(label, changedAt: now)
            transitionColorCount(from: previousState, to: items[index].colorLabelState)
        }
        publishMetadataMutation(.color, affectedFileIDs: changes.map { $0.previous.fileID })
        scheduleSave()
    }

    /// Whether clearing every rating is awaiting confirmation in SessionView.
    @Published var isClearAllRatingsConfirmationPresented = false

    /// Ask before resetting a larger rated set to undecided. Toolbar, menu,
    /// and the bare R shortcut all come through here so the threshold is
    /// consistent: 1–15 ratings clear immediately, while 16+ need approval.
    func requestClearAllRatings() {
        guard !isFileOperationRunning, ratedCount > 0 else { return }
        if ratedCount > 15 {
            isClearAllRatingsConfirmationPresented = true
        } else {
            clearAllRatings()
        }
    }

    /// Reset every photo to undecided — one undo step brings all ratings back.
    func clearAllRatings() {
        guard !isFileOperationRunning else { return }
        isClearAllRatingsConfirmationPresented = false
        let changes = items.flatMap { item -> [MetadataChange] in
            guard item.hasAnyRating else { return [] }
            return item.metadataSnapshots.compactMap {
                guard $0.rating != .undecided else { return nil }
                return MetadataChange(previous: $0)
            }
        }
        guard !changes.isEmpty else { return }
        pushUndo(.metadata(.decision, changes, previousFileID: currentItemID))
        let now = Date()
        // A deliberate clear is newer review work, including after reopen.
        // Leave already-undecided RAW/JPEG components and their dates alone.
        for item in items {
            for file in item.individualFiles where file.rating != .undecided {
                file.setRating(.undecided, ratedAt: now)
            }
        }
        ratingTally = (0, 0, items.count)
        mixedRatingCount = 0
        publishMetadataMutation(.decision, affectedFileIDs: changes.map { $0.previous.fileID })
        scheduleSave()
    }

    private func transitionRatingCount(
        from old: PhotoItemRatingState,
        to new: PhotoItemRatingState
    ) {
        guard old != new else { return }
        switch old {
        case .yes: ratingTally.yes -= 1
        case .no: ratingTally.no -= 1
        case .undecided: ratingTally.undecided -= 1
        case .mixed:
            ratingTally.undecided -= 1
            mixedRatingCount -= 1
        }
        switch new {
        case .yes: ratingTally.yes += 1
        case .no: ratingTally.no += 1
        case .undecided: ratingTally.undecided += 1
        case .mixed:
            ratingTally.undecided += 1
            mixedRatingCount += 1
        }
    }

    private func transitionStarCount(
        from old: PhotoItemStarRatingState,
        to new: PhotoItemStarRatingState
    ) {
        guard old != new else { return }
        adjustStarCount(for: old, by: -1)
        adjustStarCount(for: new, by: 1)
    }

    private func adjustStarCount(for state: PhotoItemStarRatingState, by amount: Int) {
        switch state {
        case .unrated: unratedStarCountStorage += amount
        case .stars(let rating): starTally[rating, default: 0] += amount
        case .mixed: mixedStarCountStorage += amount
        }
    }

    private func transitionColorCount(
        from old: PhotoItemColorLabelState,
        to new: PhotoItemColorLabelState
    ) {
        guard old != new else { return }
        adjustColorCount(for: old, by: -1)
        adjustColorCount(for: new, by: 1)
    }

    private func adjustColorCount(for state: PhotoItemColorLabelState, by amount: Int) {
        switch state {
        case .none: noColorCountStorage += amount
        case .label(let label): colorTally[label, default: 0] += amount
        case .mixed: mixedColorCountStorage += amount
        }
    }

    /// Whether ⌘Z has anything to undo — drives the toolbar button's state.
    /// (Not @Published, but every undo-stack change happens alongside a
    /// published mutation, so views re-evaluate it at the right moments.)
    var canUndo: Bool {
        guard !isFileOperationRunning,
              let step = undoStack.last else { return false }
        if case .cleanUp = step {
            return !recoveryNeedsAttention
        }
        if case .organization = step {
            return !recoveryNeedsAttention
        }
        return true
    }

    private func pushUndo(_ step: UndoStep) {
        undoStack.append(step)
        if undoStack.count > 500 { undoStack.removeFirst() }
    }

    func undo() {
        guard canUndo, let step = undoStack.last else { return }
        // Inspect before popping: unresolved recovery blocks only a Clean Up
        // restore. The step must remain available for a later retry, while a
        // newer rating step above it can still be undone immediately.
        if case .cleanUp = step, recoveryNeedsAttention { return }
        if case .organization = step, recoveryNeedsAttention { return }
        _ = undoStack.popLast()
        // Undo moves the session back in time; a live selection would no
        // longer mean what the user built it for.
        setSelectionIndices([])
        switch step {
        case .metadata(let dimension, let changes, let previousFileID):
            let indexedChanges: [(index: Int, change: MetadataChange)] =
                changes.compactMap { change in
                    guard let index = itemIndexByFileID[change.previous.fileID],
                          items.indices.contains(index) else { return nil }
                    return (index: index, change: change)
                }
            var previousDecisionStates: [Int: PhotoItemRatingState] = [:]
            var previousStarStates: [Int: PhotoItemStarRatingState] = [:]
            var previousColorStates: [Int: PhotoItemColorLabelState] = [:]
            for (index, _) in indexedChanges {
                previousDecisionStates[index] = items[index].ratingState
                previousStarStates[index] = items[index].starRatingState
                previousColorStates[index] = items[index].colorLabelState
            }
            for (index, change) in indexedChanges {
                switch dimension {
                case .decision: items[index].restoreRating(change.previous)
                case .stars: items[index].restoreStars(change.previous)
                case .color: items[index].restoreColor(change.previous)
                case .all: items[index].restoreMetadata(change.previous)
                }
            }
            for (index, previousState) in previousDecisionStates {
                switch dimension {
                case .decision:
                    transitionRatingCount(from: previousState, to: items[index].ratingState)
                case .stars:
                    if let old = previousStarStates[index] {
                        transitionStarCount(from: old, to: items[index].starRatingState)
                    }
                case .color:
                    if let old = previousColorStates[index] {
                        transitionColorCount(from: old, to: items[index].colorLabelState)
                    }
                case .all:
                    transitionRatingCount(
                        from: previousState,
                        to: items[index].ratingState
                    )
                    if let old = previousStarStates[index] {
                        transitionStarCount(
                            from: old,
                            to: items[index].starRatingState
                        )
                    }
                    if let old = previousColorStates[index] {
                        transitionColorCount(
                            from: old,
                            to: items[index].colorLabelState
                        )
                    }
                }
            }
            restoreCurrentFile(
                fileID: previousFileID,
                fallbackIndex: currentIndex
            )
            if !indexedChanges.isEmpty {
                let changedIDs = indexedChanges.map { $0.change.previous.fileID }
                for id in changedIDs {
                    guard let file = sessionFile(forID: id),
                          SessionRecoveryPolicy.isUntouched(file.metadataSnapshot) else { continue }
                    // Undo intentionally returned this file to an empty current
                    // decision. Retain older decisions as history, rather than
                    // letting a pending check reverse the user's Undo.
                    for index in sessionRecoveryRecordIndicesByFileID[id] ?? []
                        where sessionRecoveryEntries[index].resolvedFileID == nil {
                        sessionRecoveryEntries[index].resolvedFileID = id
                        sessionRecoveryConfirmations.remove(sessionRecoveryEntries[index].id)
                    }
                }
                publishMetadataMutation(dimension, affectedFileIDs: changedIDs)
            }
            scheduleSave()
        case .cleanUp(
            let removed,
            let previousItemID,
            let previousIndex,
            let pairComponents
        ):
            undoCleanUp(
                removed,
                previousItemID: previousItemID,
                previousIndex: previousIndex,
                pairComponents: pairComponents
            )
        case .organization(let record):
            undoSourceOrganization(record)
        }
    }

    // MARK: - Clean up (move rejected files to the Trash)

    /// Which clean-up action is awaiting the user's confirmation (drives the
    /// confirmation dialog in SessionView; set from the toolbar or menu bar).
    @Published var pendingCleanUp: CleanUpMode?
    /// A problem to report after a clean-up or its undo (some file couldn't
    /// be moved). Nil means the last operation went through completely.
    @Published var cleanUpError: String?
    /// A stale scan is safe to recover through the normal save-then-rescan
    /// path. It never retries the destructive action automatically.
    @Published private(set) var cleanUpStalePhotos: [StaleCleanUpPhoto] = []
    /// Which photos the scoped Clean Up actions consider. Filtered is the safe
    /// default; the direct "Move Selected" action ignores this and always
    /// targets the effective selection.
    @Published var cleanUpScope: CleanUpScope = .filtered
    @Published private(set) var cleanUpProgress: CleanUpProgress?

    /// The photos a scoped clean-up would consider. The direct selection
    /// action bypasses this property in `cleanUpTargets`.
    private var cleanUpCandidates: [Int] {
        cleanUpScope.candidateIndices(
            all: items.indices,
            filtered: visibleIndices,
            selected: effectiveSelection
        )
    }

    /// Menu enablement only needs to know whether one target exists. Avoid
    /// materializing the entire all-photo candidate array on every toolbar
    /// refresh; the action itself still resolves an exact ordered snapshot.
    private func cleanUpCandidatesContain(_ predicate: (Int) -> Bool) -> Bool {
        switch cleanUpScope {
        case .all:
            return items.indices.contains(where: predicate)
        case .filtered:
            return visibleIndices.contains(where: predicate)
        case .selected:
            return effectiveSelection.contains(where: predicate)
        }
    }

    /// Live candidate totals shown beside the three inline scope choices.
    func cleanUpScopeCount(for scope: CleanUpScope) -> Int {
        switch scope {
        case .all: return items.count
        case .filtered: return visibleIndices.count
        case .selected: return effectiveSelection.count
        }
    }

    /// Exactly which photos a clean-up mode would remove.
    private func cleanUpTargets(for mode: CleanUpMode) -> [Int] {
        switch mode {
        case .selection:
            return effectiveSelection.sorted()
        case .trashNo:
            return cleanUpCandidates.filter { items[$0].rating == .no }
        case .keepOnlyYes:
            return cleanUpCandidates.filter {
                !items[$0].hasMixedRatings && items[$0].rating != .yes
            }
        case .pairedJPEGs, .pairedRAWs:
            return []
        }
    }

    /// One single-file worker snapshot per qualifying pair. Pair discovery is
    /// independent of whether the review UI currently shows both files as one
    /// item or separately; scope membership follows the member being removed.
    private func pairComponentCleanUpTargets(
        for mode: CleanUpMode
    ) -> [CleanUpPhotoSnapshot] {
        guard mode == .pairedJPEGs || mode == .pairedRAWs else { return [] }
        let candidateIndices = Set(cleanUpCandidates)
        return rawJPEGPairs.compactMap { pair in
            let target = mode == .pairedJPEGs ? pair.jpeg : pair.raw
            guard let index = itemIndexByFileID[target.id],
                  candidateIndices.contains(index)
            else { return nil }
            return CleanUpPhotoSnapshot(
                index: index,
                item: PhotoItem(primaryFile: target),
                validationFiles: [pair.raw, pair.jpeg]
            )
        }
    }

    private func cleanUpSnapshots(for mode: CleanUpMode) -> [CleanUpPhotoSnapshot] {
        switch mode {
        case .pairedJPEGs, .pairedRAWs:
            return pairComponentCleanUpTargets(for: mode)
        case .selection, .trashNo, .keepOnlyYes:
            return cleanUpTargets(for: mode).compactMap { index in
                items.indices.contains(index)
                    ? CleanUpPhotoSnapshot(index: index, item: items[index])
                    : nil
            }
        }
    }

    /// Whether a clean-up mode has anything to remove — drives the menu
    /// items' enabled state. Short-circuits instead of building and counting
    /// the whole target list on every toolbar render.
    func hasCleanUpTargets(for mode: CleanUpMode) -> Bool {
        switch mode {
        case .selection:
            return !effectiveSelection.isEmpty
        case .trashNo:
            return cleanUpCandidatesContain { items[$0].rating == .no }
        case .keepOnlyYes:
            return cleanUpCandidatesContain {
                !items[$0].hasMixedRatings && items[$0].rating != .yes
            }
        case .pairedJPEGs, .pairedRAWs:
            let candidateIndices = Set(cleanUpCandidates)
            return rawJPEGPairs.contains { pair in
                let target = mode == .pairedJPEGs ? pair.jpeg : pair.raw
                guard let index = itemIndexByFileID[target.id] else {
                    return false
                }
                return candidateIndices.contains(index)
            }
        }
    }

    /// How many photos (and actual files, counting RAW+JPEG pairs as two)
    /// a clean-up mode would move to the Trash, respecting the chosen scope.
    /// Only needed once, when the confirmation dialog opens.
    func cleanUpCounts(for mode: CleanUpMode) -> (photos: Int, files: Int, bytes: Int64) {
        if mode == .pairedJPEGs || mode == .pairedRAWs {
            let targets = pairComponentCleanUpTargets(for: mode)
            return (
                targets.count,
                targets.count,
                targets.reduce(0) { $0 + $1.item.fileSize }
            )
        }
        let doomed = cleanUpTargets(for: mode).map { items[$0] }
        return (
            doomed.count,
            doomed.reduce(0) { $0 + $1.allURLs.count },
            doomed.reduce(0) { $0 + $1.totalFileSize }
        )
    }

    /// Menu label for trashing the selection, with a live count. Lives on the
    /// store so the toolbar menu and the File menu share one source of truth.
    var selectionCleanUpTitle: String {
        let count = effectiveSelection.count
        return count > 1 ? L10n.text("Move \(count) Selected to Trash…") : L10n.text("Move Selected to Trash…")
    }

    func presentExport(keepersOnly: Bool = false) {
        guard canExport else { return }
        exportKeepersRequested = keepersOnly
        isExportPresented = true
    }

    /// Computed from the same generation authority used by Close and Quit.
    /// A completed older write must never make a newer decision look saved.
    var sessionSaveStatus: String {
        if isLegacySessionMigrationConfirmationPresented { return L10n.text("Not saved") }
        if persistenceWarning != nil {
            if sessionChangeGeneration == 0 { return L10n.text("Check saving") }
            return currentSessionIsDurable ? L10n.text("Saved · see notice") : L10n.text("Not saved")
        }
        if activePersistenceSaveCount > 0 { return L10n.text("Saving…") }
        if sessionChangeGeneration == 0 { return L10n.text("Saved") }
        return currentSessionIsDurable ? L10n.text("Saved") : L10n.text("Saving…")
    }

    var isReviewComplete: Bool { !items.isEmpty && undecidedCount == 0 }

    /// Resolve counts only when a confirmation is requested, not per tile.
    func cleanUpDecisionBreakdown(for mode: CleanUpMode) -> (no: Int, undecided: Int) {
        let targets = cleanUpTargets(for: mode)
        return (
            targets.reduce(0) { $0 + (items[$1].rating == .no ? 1 : 0) },
            targets.reduce(0) { $0 + (items[$1].rating == .undecided ? 1 : 0) }
        )
    }

    // MARK: - Command Palette

    /// Opens the searchable action panel only from a settled review session.
    /// `SessionView` owns its ⌘K routing, so this intentionally has no menu
    /// key equivalent that could bypass text-focus and window checks.
    func presentActionPalette() {
        guard case .ready = phase,
              !isFileOperationRunning,
              !isSessionCommandPresentationActive else { return }
        isActionPalettePresented = true
    }

    /// Close without running a palette action (Escape or the system Cancel
    /// command).
    func dismissActionPalette() {
        actionPaletteFollowUp = nil
        isActionPalettePresented = false
    }

    /// Native sheets must finish dismissing before they present a Filter
    /// popover, Export sheet, confirmation, or folder picker. Queue the
    /// existing action for the sheet's `onDismiss` rather than overlap two
    /// modal presentations.
    func dismissActionPalette(then action: @escaping @MainActor () -> Void) {
        guard isActionPalettePresented else { return }
        actionPaletteFollowUp = action
        isActionPalettePresented = false
    }

    func finishActionPaletteDismissal() {
        guard !isActionPalettePresented else { return }
        let action = actionPaletteFollowUp
        actionPaletteFollowUp = nil
        action?()
    }

    /// Flushes a pending search debounce before presenting counts, ensuring
    /// the confirmation describes the exact set that will be moved.
    func requestCleanUp(_ mode: CleanUpMode) {
        guard canCleanUp else { return }
        cleanUpStalePhotos = []
        flushPendingFilter()
        guard hasCleanUpTargets(for: mode) else { return }
        pendingCleanUp = mode
    }

    /// Moves every photo the mode rejects within the chosen scope to the
    /// macOS Trash — never a permanent delete. One ⌘Z brings the whole batch
    /// back. A photo is only removed if *all* its files could be trashed; on a
    /// partial failure its already-trashed files are put back. If that
    /// rollback also fails, the app reports the inconsistent pair explicitly.
    func performCleanUp(_ mode: CleanUpMode) {
        guard !isNewFileOperationBlocked else { return }
        flushPendingFilter()
        // Resolve targets first — .selection reads the live selection —
        // then drop it: indices are about to shift.
        let snapshots = cleanUpSnapshots(for: mode)
        guard !snapshots.isEmpty else { return }
        let previousIndex = currentIndex
        let previousItemID = currentItemID
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        pendingCleanUp = nil
        setSelectionIndices([])
        videoPlayback.stop()
        activeFileOperation = .cleanUp
        let total = snapshots.reduce(0) { $0 + $1.item.allURLs.count }
        cleanUpProgress = CleanUpProgress(action: .movingToTrash, done: 0, total: total)
        let progressReporter = makeCleanUpProgressReporter(action: .movingToTrash, generation: generation)
        let jpegSurvivorByRawID = Dictionary(
            uniqueKeysWithValues: rawJPEGPairs.map { ($0.raw.id, $0.jpeg) }
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanUpWorker.moveToTrash(snapshots, progress: progressReporter)
            var preparedSurvivors: [PhotoItem] = []
            var survivorMetadataError: String?
            if mode == .pairedRAWs {
                let removedRAWIDs = Set(
                    result.succeeded.flatMap {
                        $0.item.individualFiles.map(\.id)
                    }
                )
                let jpegFiles = removedRAWIDs.compactMap {
                    jpegSurvivorByRawID[$0]
                }
                do {
                    let prepared = try FolderScanner.prepareStandaloneFiles(jpegFiles)
                    preparedSurvivors = prepared.map { PhotoItem(primaryFile: $0) }
                } catch {
                    // Keep the old physical-file records as identity-bound
                    // placeholders. Never adopt replacement metadata, and do
                    // not undo or hide RAW moves that already completed.
                    preparedSurvivors = jpegFiles.map { PhotoItem(primaryFile: $0) }
                    survivorMetadataError = error.localizedDescription
                }
            }
            await self?.finishCleanUp(
                result,
                mode: mode,
                preparedSurvivors: preparedSurvivors,
                survivorMetadataError: survivorMetadataError,
                previousItemID: previousItemID,
                previousIndex: previousIndex,
                generation: generation
            )
        }
    }

    private func finishCleanUp(
        _ result: TrashBatchResult,
        mode: CleanUpMode,
        preparedSurvivors: [PhotoItem],
        survivorMetadataError: String?,
        previousItemID: String?,
        previousIndex: Int,
        generation: UInt64
    ) {
        guard generation == cleanUpGeneration, isCleaningUp else { return }
        if result.requiresRecovery {
            activeFileOperation = nil
            cleanUpProgress = nil
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
        if !result.stalePhotos.isEmpty {
            activeFileOperation = nil
            cleanUpProgress = nil
            cleanUpStalePhotos = result.stalePhotos
            cleanUpError = Self.cleanUpStaleScanMessage(
                for: result.stalePhotos,
                mode: mode
            )
            return
        }
        let removed = result.succeeded.map {
            RemovedPhoto(index: $0.index, item: $0.item, trashedFiles: $0.files)
        }
        if !removed.isEmpty {
            let isPairComponentCleanUp = mode == .pairedJPEGs
                || mode == .pairedRAWs
            let removedIndices = Set(removed.map(\.index))
            if isPairComponentCleanUp {
                let removedFileIDs = Set(
                    removed.flatMap { $0.item.individualFiles.map(\.id) }
                )
                if let projection = reprojectItems(
                    adding: preparedSurvivors,
                    removingFileIDs: removedFileIDs,
                    loadMissingMetadata: survivorMetadataError == nil
                ) {
                    items = projection.items
                }
            } else {
                items = items.enumerated()
                    .filter { !removedIndices.contains($0.offset) }
                    .map(\.element)
            }
            emptySessionReason = items.isEmpty ? .trashedUndoable : nil
            let removedBefore = isPairComponentCleanUp
                ? 0
                : removed.filter { $0.index < previousIndex }.count
            rebuildDerivedData()
            restoreCurrentItem(
                itemID: previousItemID,
                fallbackIndex: previousIndex - removedBefore
            )
            pushUndo(.cleanUp(
                removed,
                previousItemID: previousItemID,
                previousIndex: previousIndex,
                pairComponents: isPairComponentCleanUp
            ))
            if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
            markSessionChanged()
            saveSession()
        }
        activeFileOperation = nil
        cleanUpProgress = nil
        cleanUpStalePhotos = []
        if let survivorMetadataError {
            pairingMetadataError = L10n.text("The completed moves to Trash were preserved. ")
                + survivorMetadataError
        }
        if result.failedPhotos > 0 {
            var message: String
            if result.inconsistentPhotos > 0 {
                message = (result.failedPhotos == 1 ? L10n.text("\(result.failedPhotos) item couldn't be moved completely. ") : L10n.text("\(result.failedPhotos) items couldn't be moved completely. "))
                    + L10n.text("For \(result.inconsistentPhotos), rollback also failed; check both the source folder and Trash.")
            } else {
                message = result.failedPhotos == 1
                    ? L10n.text("1 item couldn't be moved to the Trash and stayed in the folder.")
                    : L10n.text("\(result.failedPhotos) items couldn't be moved to the Trash and stayed in the folder.")
            }
            if result.journalFailure {
                message += L10n.text(" Louppe's file-safety checks stopped the operation before another file was touched.")
            }
            cleanUpError = message
        }
    }

    /// Rebuilds the current together/separate presentation from physical-file
    /// records after one member of a pair leaves or returns. The scanner's
    /// pairing policy remains the single authority for ambiguity and filename
    /// case handling.
    private func reprojectItems(
        adding addedItems: [PhotoItem],
        removingFileIDs: Set<String> = [],
        loadMissingMetadata: Bool = true
    ) -> FolderScanner.PairingProjection? {
        guard let sourceFolder else { return nil }
        let physicalItems = (items + addedItems).flatMap { item in
            item.individualFiles.compactMap { file in
                removingFileIDs.contains(file.id)
                    ? nil
                    : PhotoItem(primaryFile: file)
            }
        }
        return try? FolderScanner.projectPairingMode(
            rawJPEGPairingMode,
            from: physicalItems,
            root: sourceFolder,
            loadMissingMetadata: loadMissingMetadata
        )
    }

    static func cleanUpStaleScanMessage(
        for stalePhotos: [StaleCleanUpPhoto],
        mode: CleanUpMode = .keepOnlyYes
    ) -> String {
        let count = stalePhotos.count
        let items = count == 1 ? L10n.text("1 item has") : L10n.text("\(count) items have")
        let examples = stalePhotos.prefix(3).map { "“\($0.displayName)”" }
        let names: String
        switch examples.count {
        case 0:
            names = ""
        case 1:
            names = " (\(examples[0]))"
        case 2:
            names = L10n.text(" (\(examples[0]) and \(examples[1]))")
        default:
            names = L10n.text(" (including \(examples.joined(separator: ", ")))")
        }
        let action: String
        switch mode {
        case .selection: action = L10n.text("Move Selected to Trash")
        case .trashNo: action = L10n.text("Move “No” to Trash")
        case .keepOnlyYes: action = L10n.text("Trash No + Undecided")
        case .pairedJPEGs: action = L10n.text("Move Paired JPEGs to Trash")
        case .pairedRAWs: action = L10n.text("Move Paired RAWs to Trash")
        }
        return L10n.text("\(items) changed after this folder was scanned\(names). ")
            + L10n.text("No files were moved. Use Rescan Folder, then choose \(action) and confirm the updated count.")
    }

    /// Dismisses the stale-scan notice and uses the existing save-first
    /// rescan. The photographer must explicitly start Clean Up again later.
    func rescanAfterCleanUpStaleScan() {
        dismissCleanUpError()
        rescan()
    }

    func dismissCleanUpError() {
        cleanUpError = nil
        cleanUpStalePhotos = []
    }

    /// Brings a cleaned-up batch back: moves each file out of the Trash and
    /// reinserts the photos at their original positions (ascending index
    /// order, so every photo lands exactly where it was).
    private func undoCleanUp(
        _ removed: [RemovedPhoto],
        previousItemID: String?,
        previousIndex: Int,
        pairComponents: Bool
    ) {
        guard !isNewFileOperationBlocked else { return }
        let snapshots = removed.map {
            TrashedPhotoSnapshot(index: $0.index, item: $0.item, files: $0.trashedFiles)
        }
        cleanUpGeneration &+= 1
        let generation = cleanUpGeneration
        videoPlayback.stop()
        activeFileOperation = .cleanUp
        let total = snapshots.reduce(0) { $0 + $1.files.count }
        cleanUpProgress = CleanUpProgress(action: .restoring, done: 0, total: total)
        let progressReporter = makeCleanUpProgressReporter(action: .restoring, generation: generation)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CleanUpWorker.restore(snapshots, progress: progressReporter)
            await self?.finishUndoCleanUp(
                result,
                allRemovedIndices: Set(removed.map(\.index)),
                previousItemID: previousItemID,
                previousIndex: previousIndex,
                pairComponents: pairComponents,
                generation: generation
            )
        }
    }

    private func makeCleanUpProgressReporter(
        action: CleanUpProgress.Action,
        generation: UInt64
    ) -> CleanUpWorker.Progress {
        { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, self.cleanUpGeneration == generation, self.isCleaningUp else { return }
                self.cleanUpProgress = CleanUpProgress(action: action, done: done, total: total)
            }
        }
    }

    private func finishUndoCleanUp(
        _ result: RestoreBatchResult,
        allRemovedIndices: Set<Int>,
        previousItemID: String?,
        previousIndex: Int,
        pairComponents: Bool,
        generation: UInt64
    ) {
        guard generation == cleanUpGeneration, isCleaningUp else { return }
        if result.requiresRecovery {
            activeFileOperation = nil
            cleanUpProgress = nil
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
        if pairComponents,
           let projection = reprojectItems(
               adding: result.restored.map(\.item)
           ) {
            items = projection.items
        } else {
            items = CleanUpWorker.mergeRestoredItems(
                survivors: items,
                allRemovedIndices: allRemovedIndices,
                restored: result.restored
            )
        }
        emptySessionReason = items.isEmpty
            ? .unavailableAfterFailedRestore
            : nil
        if result.lostPhotos > 0 {
            // Some photos are gone for good (Trash emptied?). Older undo steps'
            // indices no longer line up with `items`, so drop them rather than
            // risk restoring a rating onto the wrong photo.
            undoStack.removeAll()
            cleanUpError = result.lostPhotos == 1
                ? L10n.text("1 item couldn't be restored from the Trash — it may have been deleted there.")
                : L10n.text("\(result.lostPhotos) items couldn't be restored from the Trash — they may have been deleted there.")
            if result.inconsistentPhotos > 0 {
                cleanUpError? += L10n.text(" For \(result.inconsistentPhotos), rollback also failed; check both the source folder and Trash.")
            }
            if result.journalFailure {
                cleanUpError? += L10n.text(" Louppe's file-safety checks stopped the operation before another file was touched.")
            }
        }
        rebuildDerivedData()
        restoreCurrentItem(
            itemID: previousItemID,
            fallbackIndex: previousIndex
        )
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        markSessionChanged()
        saveSession()
        activeFileOperation = nil
        cleanUpProgress = nil
    }

    // MARK: - Source organization

    func organizationScopeCount(for scope: SourceOrganizationScope) -> Int {
        switch scope {
        case .all: return items.count
        case .filtered: return visibleIndices.count
        case .selected: return effectiveSelection.count
        }
    }

    var hasMultipleOrganizationTopLevelFolders: Bool {
        var names = Set<String>()
        var hasRootFiles = false
        for file in items.flatMap(\.individualFiles) {
            if let origin = organizationOriginFolderPathBytesByFileID[file.id] {
                let components = origin.split(separator: UInt8(ascii: "/"))
                if let first = components.first {
                    names.insert(String(decoding: first, as: UTF8.self))
                } else {
                    hasRootFiles = true
                }
            } else if file.legacyPersistenceID.contains("/"),
                      let first = file.legacyPersistenceID.split(
                        separator: "/",
                        omittingEmptySubsequences: true
                      ).first {
                names.insert(String(first))
            } else {
                hasRootFiles = true
            }
            if names.count + (hasRootFiles ? 1 : 0) > 1 { return true }
        }
        return false
    }

    func presentSourceOrganization(
        configuration: SourceOrganizationConfiguration? = nil
    ) {
        guard canOrganizeSource else { return }
        flushPendingFilter()
        sourceOrganizationLaunchConfiguration = configuration
        organizationOutcome = nil
        organizationError = nil
        isOrganizePresented = true
    }

    func presentSingleFileRenaming(itemID: String) {
        guard canRenameSource,
              selectedIndices.count <= 1,
              items.contains(where: { $0.id == itemID }) else { return }
        flushPendingFilter()
        fileRenamingPresentationMode = .single(itemID: itemID)
        organizationOutcome = nil
        organizationError = nil
        isRenamePresented = true
    }

    func presentMetadataFileRenaming() {
        guard canRenameSource else { return }
        flushPendingFilter()
        fileRenamingPresentationMode = .metadata
        organizationOutcome = nil
        organizationError = nil
        isRenamePresented = true
    }

    func sourceOrganizationPlanningSnapshot(
        scope: SourceOrganizationScope
    ) -> SourceOrganizationPlanningSnapshot? {
        guard let sourceFolder, case .ready = phase else { return nil }
        flushPendingFilter()
        let indices: [Int]
        switch scope {
        case .all: indices = Array(items.indices)
        case .filtered: indices = visibleIndices
        case .selected: indices = effectiveSelection.sorted()
        }
        let selected = indices.compactMap {
            items.indices.contains($0) ? items[$0] : nil
        }
        return SourceOrganizationPlanningSnapshot(
            sourceFolder: sourceFolder,
            selectedItems: selected,
            familyContextItems: items,
            pairedFiles: sourceOrganizationPairedFiles,
            knownOriginFolderPathBytesByFileID:
                organizationOriginFolderPathBytesByFileID
        )
    }

    func sourceFileRenamingPlanningSnapshot(
        scope: SourceOrganizationScope
    ) -> SourceOrganizationPlanningSnapshot? {
        sourceFileRenamingPlanningSnapshot(
            scope: scope, mode: fileRenamingPresentationMode
        )
    }

    /// Inline editing always targets the displayed filename, independent of
    /// the batch sheet's last mode or a rubber-band selection elsewhere.
    func sourceFileRenamingPlanningSnapshot(
        itemID: String
    ) -> SourceOrganizationPlanningSnapshot? {
        sourceFileRenamingPlanningSnapshot(
            scope: .selected, mode: .single(itemID: itemID)
        )
    }

    private func sourceFileRenamingPlanningSnapshot(
        scope: SourceOrganizationScope,
        mode: FileRenamingPresentationMode
    ) -> SourceOrganizationPlanningSnapshot? {
        guard let sourceFolder, case .ready = phase else { return nil }
        flushPendingFilter()
        let selected: [PhotoItem]
        switch mode {
        case .metadata:
            let indices: [Int]
            switch scope {
            case .all: indices = Array(items.indices)
            case .filtered: indices = visibleIndices
            case .selected: indices = effectiveSelection.sorted()
            }
            let scopedItems = indices.compactMap {
                items.indices.contains($0) ? items[$0] : nil
            }
            selected = expandingRAWJPEGPairMembers(in: scopedItems)
        case .single(let itemID):
            guard let target = items.first(where: { $0.id == itemID }) else {
                return nil
            }
            selected = expandingRAWJPEGPairMembers(in: [target])
        }
        return SourceOrganizationPlanningSnapshot(
            sourceFolder: sourceFolder,
            selectedItems: selected,
            familyContextItems: items,
            pairedFiles: sourceOrganizationPairedFiles,
            knownOriginFolderPathBytesByFileID:
                organizationOriginFolderPathBytesByFileID
        )
    }

    private var sourceOrganizationPairedFiles:
        [SourceOrganizationPairedFiles] {
        rawJPEGPairs.map {
            SourceOrganizationPairedFiles(
                rawFileID: $0.raw.id,
                jpegFileID: $0.jpeg.id
            )
        }
    }

    /// A file rename always includes the complete physical RAW+JPEG family,
    /// even when filtering or the default review mode exposes just one member.
    private func expandingRAWJPEGPairMembers(
        in scopedItems: [PhotoItem]
    ) -> [PhotoItem] {
        var selectedItemIDs = Set(scopedItems.map(\.id))
        let scopedFileIDs = Set(scopedItems.flatMap(\.individualFiles).map(\.id))
        for pair in rawJPEGPairs
        where scopedFileIDs.contains(pair.raw.id)
            || scopedFileIDs.contains(pair.jpeg.id) {
            if let index = itemIndexByFileID[pair.raw.id],
               items.indices.contains(index) {
                selectedItemIDs.insert(items[index].id)
            }
            if let index = itemIndexByFileID[pair.jpeg.id],
               items.indices.contains(index) {
                selectedItemIDs.insert(items[index].id)
            }
        }
        return items.filter { selectedItemIDs.contains($0.id) }
    }

    func startSourceOrganization(_ plan: SourceOrganizationPlan) {
        guard plan.changeKind == .organization else { return }
        startSourceFileChange(plan)
    }

    func startSourceRename(
        _ plan: SourceOrganizationPlan,
        presentsSheet: Bool = true
    ) {
        guard plan.changeKind == .rename else { return }
        startSourceFileChange(plan, presentsSheet: presentsSheet)
    }

    private func startSourceFileChange(
        _ plan: SourceOrganizationPlan,
        presentsSheet: Bool = true
    ) {
        guard canOrganizeSource,
              plan.canExecute,
              let folder = sourceFolder,
              folder.standardizedFileURL
                == plan.sourceFolder.standardizedFileURL else { return }

        if plan.changeKind == .organization {
            var capturedNewOrigin = false
            for (fileID, origin) in plan.originFolderPathBytesByFileID {
                if organizationOriginFolderPathBytesByFileID[fileID] == nil {
                    organizationOriginFolderPathBytesByFileID[fileID] = origin
                    capturedNewOrigin = true
                }
            }
            if capturedNewOrigin { markSessionChanged() }
        }

        organizationGeneration &+= 1
        let generation = organizationGeneration
        if plan.changeKind == .organization {
            isOrganizePresented = true
        } else if presentsSheet {
            isRenamePresented = true
        }
        organizationOutcome = nil
        organizationError = nil
        videoPlayback.stop()
        activeFileOperation = plan.changeKind == .rename
            ? .renameSource
            : .organizeSource
        organizationProgress = SourceOrganizationProgress(
            action: .organizing,
            done: 0,
            total: plan.workerPlan.totalFiles
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.persistCurrentSessionIfNeededBeforeDiscard()
            guard self.organizationGeneration == generation,
                  self.isChangingSourceFiles else { return }
            guard self.currentSessionIsDurable else {
                self.activeFileOperation = nil
                self.organizationProgress = nil
                self.organizationError = plan.changeKind == .rename
                    ? L10n.text("Louppe could not save the current ratings safely. Retry Saving before renaming files.")
                    : L10n.text("Louppe could not save the current ratings safely. Retry Saving before organizing the source folder.")
                return
            }
            let reporter: SourceOrganizationWorker.Progress = {
                [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.organizationGeneration == generation,
                          self.isChangingSourceFiles else { return }
                    self.organizationProgress = SourceOrganizationProgress(
                        action: .organizing,
                        done: done,
                        total: total
                    )
                }
            }
            let journalDirectory = self.operationJournalDirectory
            let task = Task.detached(priority: .userInitiated) {
                SourceOrganizationWorker.organize(
                    plan,
                    journalDirectory: journalDirectory,
                    progress: reporter
                )
            }
            let result = await task.value
            self.finishSourceOrganization(
                result,
                plan: plan,
                generation: generation
            )
        }
    }

    private func finishSourceOrganization(
        _ result: SourceOrganizationResult,
        plan: SourceOrganizationPlan,
        generation: UInt64
    ) {
        guard organizationGeneration == generation,
              isChangingSourceFiles else { return }
        activeFileOperation = nil
        organizationProgress = nil
        organizationOutcome = SourceOrganizationOutcome(
            movedFiles: result.movedFiles,
            failedItems: result.failedItems,
            message: result.failureMessage,
            wasUndo: false
        )
        if result.requiresRecovery {
            organizationError = result.failureMessage
                ?? (plan.changeKind == .rename
                    ? L10n.text("The interrupted rename needs recovery before another file operation.")
                    : L10n.text("The interrupted organization needs recovery before another file operation."))
            operationRecoveryCause = organizationError
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
        guard !result.movedItemIDs.isEmpty,
              let folder = sourceFolder else {
            if result.failedItems > 0 {
                organizationError = result.failureMessage
                    ?? (plan.changeKind == .rename
                        ? L10n.text("Some items could not be renamed and kept their previous names.")
                        : L10n.text("Some items could not be organized and stayed in their original folders."))
            }
            return
        }

        let movedItemIDs = Set(result.movedItemIDs)
        let currentDestinationID = currentItemID.flatMap {
            movedItemIDs.contains($0)
                ? (plan.destinationItemIDBySourceItemID[$0] ?? $0)
                : $0
        }
        let selectedDestinationIDs = Set(selectionState.itemIDs.map {
            movedItemIDs.contains($0)
                ? (plan.destinationItemIDBySourceItemID[$0] ?? $0)
                : $0
        })
        nextScanResumeIdentityOverride = ScanResumeIdentity(
            folder: folder.standardizedFileURL,
            currentItemID: currentDestinationID,
            selectedItemIDs: selectedDestinationIDs
        )
        deferredOrganizationUndo = result.undoRecord
        beginOpeningFolder(folder)
    }

    private func undoSourceOrganization(
        _ record: SourceOrganizationUndoRecord
    ) {
        guard !isNewFileOperationBlocked,
              let folder = sourceFolder,
              folder.standardizedFileURL
                == record.sourceFolder.standardizedFileURL else { return }
        organizationGeneration &+= 1
        let generation = organizationGeneration
        if record.changeKind == .rename {
            isRenamePresented = true
        } else {
            isOrganizePresented = true
        }
        organizationOutcome = nil
        organizationError = nil
        videoPlayback.stop()
        activeFileOperation = record.changeKind == .rename
            ? .renameSource
            : .organizeSource
        organizationProgress = SourceOrganizationProgress(
            action: .restoring,
            done: 0,
            total: record.reversePlan.totalFiles
        )
        let reporter: SourceOrganizationWorker.Progress = {
            [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self,
                      self.organizationGeneration == generation,
                      self.isChangingSourceFiles else { return }
                self.organizationProgress = SourceOrganizationProgress(
                    action: .restoring,
                    done: done,
                    total: total
                )
            }
        }
        let currentItems = items
        let journalDirectory = operationJournalDirectory
        let resumeIdentity = ScanResumeIdentity(
            folder: folder.standardizedFileURL,
            currentItemID: currentItemID.map {
                record.sourceItemIDByDestinationItemID[$0] ?? $0
            },
            selectedItemIDs: Set(selectionState.itemIDs.map {
                record.sourceItemIDByDestinationItemID[$0] ?? $0
            })
        )
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SourceOrganizationWorker.undo(
                record,
                currentItems: currentItems,
                journalDirectory: journalDirectory,
                progress: reporter
            )
            await self?.finishUndoSourceOrganization(
                result,
                record: record,
                resumeIdentity: resumeIdentity,
                generation: generation
            )
        }
    }

    private func finishUndoSourceOrganization(
        _ result: SourceOrganizationResult,
        record: SourceOrganizationUndoRecord,
        resumeIdentity: ScanResumeIdentity,
        generation: UInt64
    ) {
        guard organizationGeneration == generation,
              isChangingSourceFiles else { return }
        activeFileOperation = nil
        organizationProgress = nil
        organizationOutcome = SourceOrganizationOutcome(
            movedFiles: result.movedFiles,
            failedItems: result.failedItems,
            message: result.failureMessage,
            wasUndo: true
        )
        if result.requiresRecovery {
            organizationError = result.failureMessage
                ?? L10n.text("The interrupted restore needs recovery before another file operation.")
            operationRecoveryCause = organizationError
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
        guard result.movedFiles > 0, let folder = sourceFolder else {
            organizationError = result.failureMessage
                ?? (record.changeKind == .rename
                    ? L10n.text("The previous filenames could not be restored.")
                    : L10n.text("The previous folder layout could not be restored."))
            return
        }
        // Session persistence follows each physical file back to its previous
        // ID. A normal same-folder scan is enough; no organizer undo is placed
        // back on the new undo stack.
        nextScanResumeIdentityOverride = resumeIdentity
        beginOpeningFolder(folder)
    }

    // MARK: - Export

    /// Generation captured by XMP preflight descriptors. It changes whenever
    /// a folder scan/session identity changes, but not for ordinary ratings.
    /// Ordinary metadata edits are protected separately by exact snapshots.
    var xmpConflictSessionGeneration: UInt64 { scanGeneration }

    func applyXMPConflictResolutions(
        _ requests: [XMPConflictResolutionRequest]
    ) -> XMPConflictResolutionOutcome {
        struct PendingMutation {
            let conflictID: String
            let itemIndex: Int
            let destination: PhotoFile
            let previous: PhotoFileMetadataSnapshot
            let source: PhotoFileMetadataSnapshot
        }

        guard case .ready = phase,
              !isFileOperationRunning,
              !isXMPPublicationRunning else {
            return XMPConflictResolutionOutcome(
                appliedConflictIDs: [],
                staleConflictIDs: requests.filter { $0.choice != .skip }
                    .map(\.conflict.id),
                ineligibleConflictIDs: [],
                skippedConflictIDs: requests.filter { $0.choice == .skip }
                    .map(\.conflict.id)
            )
        }

        var pending: [PendingMutation] = []
        var stale: [String] = []
        var ineligible: [String] = []
        var skipped: [String] = []

        // A real planner emits one disjoint row per sidecar family. Reject the
        // whole affected row if malformed internal input repeats a conflict or
        // makes two conflict IDs claim either physical file. Prevalidating all
        // requests prevents order-dependent partial application or an
        // opposite-winner pair from swapping metadata.
        let duplicateConflictIDs = Set(
            Dictionary(grouping: requests, by: { $0.conflict.id })
                .compactMap { $0.value.count > 1 ? $0.key : nil }
        )
        var conflictIDsByMemberID: [String: Set<String>] = [:]
        for request in requests where request.choice != .skip
            && request.conflict.isStructurallyResolvable {
            for member in request.conflict.members {
                conflictIDsByMemberID[member.id, default: []]
                    .insert(request.conflict.id)
            }
        }
        let overlappingConflictIDs = Set(
            conflictIDsByMemberID.values
                .filter { $0.count > 1 }
                .flatMap { $0 }
        )
        let ambiguousRequestIDs = duplicateConflictIDs
            .union(overlappingConflictIDs)
        var reportedIneligibleIDs = Set<String>()

        for request in requests {
            let conflict = request.conflict
            if ambiguousRequestIDs.contains(conflict.id) {
                if reportedIneligibleIDs.insert(conflict.id).inserted {
                    ineligible.append(conflict.id)
                }
                continue
            }
            guard request.choice != .skip else {
                skipped.append(conflict.id)
                continue
            }
            guard conflict.isStructurallyResolvable,
                  let raw = conflict.rawMember,
                  let jpeg = conflict.jpegMember else {
                if reportedIneligibleIDs.insert(conflict.id).inserted {
                    ineligible.append(conflict.id)
                }
                continue
            }
            guard conflict.sessionGeneration == scanGeneration else {
                stale.append(conflict.id)
                continue
            }
            let sourceMember = request.choice == .useRAW ? raw : jpeg
            let destinationMember = request.choice == .useRAW ? jpeg : raw
            guard let sourceIndex = itemIndexByFileID[sourceMember.id],
                  let destinationIndex = itemIndexByFileID[destinationMember.id],
                  items.indices.contains(sourceIndex),
                  items.indices.contains(destinationIndex),
                  let sourceFile = items[sourceIndex].individualFiles.first(
                    where: { $0.id == sourceMember.id }
                  ),
                  let destinationFile = items[destinationIndex].individualFiles.first(
                    where: { $0.id == destinationMember.id }
                  ) else {
                stale.append(conflict.id)
                continue
            }
            let currentSource = sourceFile.metadataSnapshot
            let currentDestination = destinationFile.metadataSnapshot
            guard let currentSourcePath = try? XMPExactFileSystemPath(
                    url: sourceFile.url
                  ),
                  let currentDestinationPath = try? XMPExactFileSystemPath(
                    url: destinationFile.url
                  ),
                  currentSourcePath == sourceMember.exactPath,
                  currentDestinationPath == destinationMember.exactPath,
                  currentSource == sourceMember.metadata,
                  currentDestination == destinationMember.metadata,
                  sourceFile.scannedIdentity == sourceMember.scannedIdentity,
                  destinationFile.scannedIdentity
                    == destinationMember.scannedIdentity else {
                stale.append(conflict.id)
                continue
            }
            guard currentSource.rating != currentDestination.rating
                    || currentSource.starRating
                        != currentDestination.starRating
                    || currentSource.colorLabel
                        != currentDestination.colorLabel else {
                stale.append(conflict.id)
                continue
            }
            pending.append(PendingMutation(
                conflictID: conflict.id,
                itemIndex: destinationIndex,
                destination: destinationFile,
                previous: currentDestination,
                source: currentSource
            ))
        }

        guard !pending.isEmpty else {
            return XMPConflictResolutionOutcome(
                appliedConflictIDs: [],
                staleConflictIDs: stale,
                ineligibleConflictIDs: ineligible,
                skippedConflictIDs: skipped
            )
        }

        let previousFileID = currentItemID
        pushUndo(.metadata(
            .all,
            pending.map { MetadataChange(previous: $0.previous) },
            previousFileID: previousFileID
        ))
        let affectedIndices = Set(pending.map(\.itemIndex))
        var oldDecision: [Int: PhotoItemRatingState] = [:]
        var oldStars: [Int: PhotoItemStarRatingState] = [:]
        var oldColors: [Int: PhotoItemColorLabelState] = [:]
        for index in affectedIndices {
            oldDecision[index] = items[index].ratingState
            oldStars[index] = items[index].starRatingState
            oldColors[index] = items[index].colorLabelState
        }

        let changedAt = Date()
        for mutation in pending {
            if mutation.previous.rating != mutation.source.rating {
                mutation.destination.setRating(
                    mutation.source.rating,
                    ratedAt: changedAt
                )
            }
            if mutation.previous.starRating != mutation.source.starRating {
                mutation.destination.setStars(
                    mutation.source.starRating,
                    changedAt: changedAt
                )
            }
            if mutation.previous.colorLabel != mutation.source.colorLabel {
                mutation.destination.setColor(
                    mutation.source.colorLabel,
                    changedAt: changedAt
                )
            }
        }
        for index in affectedIndices {
            if let oldDecision = oldDecision[index] {
                transitionRatingCount(
                    from: oldDecision,
                    to: items[index].ratingState
                )
            }
            if let oldStars = oldStars[index] {
                transitionStarCount(
                    from: oldStars,
                    to: items[index].starRatingState
                )
            }
            if let oldColors = oldColors[index] {
                transitionColorCount(
                    from: oldColors,
                    to: items[index].colorLabelState
                )
            }
        }
        publishMetadataMutation(.all, affectedFileIDs: pending.map { $0.destination.id })
        scheduleSave()

        // A resolution changes the authoritative session. The immutable plan
        // that described the conflict must never remain executable.
        if case .awaitingConfirmation = xmpPublicationState {
            finishXMPPublicationLifecycle()
        }
        return XMPConflictResolutionOutcome(
            appliedConflictIDs: pending.map(\.conflictID),
            staleConflictIDs: stale,
            ineligibleConflictIDs: ineligible,
            skippedConflictIDs: skipped
        )
    }

    func prepareXMPPublication(
        selected: [PhotoItem],
        profile: XMPApplicationProfile,
        visibleDecisionKeywords: Bool,
        allowExternalLabelReplacement: Bool = false
    ) {
        guard !selected.isEmpty,
              !isNewFileOperationBlocked,
              case .idle = xmpPublicationState,
              case .ready = phase else { return }
        let input: XMPPublicationInput
        do {
            // Capture every physical file's complete metadata once on the
            // session actor. Later rating changes cannot alter this plan.
            input = try XMPPublicationInput(
                items: selected,
                familyContextItems: items,
                sessionGeneration: scanGeneration,
                sourceFolder: sourceFolder,
                sourceFolderIdentity: persistenceAccess?.folderIdentity,
                profile: profile,
                visibleDecisionKeywords: visibleDecisionKeywords,
                allowExternalLabelReplacement: allowExternalLabelReplacement
            )
        } catch {
            xmpPublicationState = .failed(error.localizedDescription)
            return
        }

        xmpPublicationGeneration &+= 1
        let token = XMPPublicationSessionToken(
            generation: xmpPublicationGeneration,
            scanGeneration: scanGeneration,
            folder: sourceFolder
        )
        let cancelFlag = XMPPublicationCancelFlag()
        xmpPublicationSessionToken = token
        xmpPublicationCancelFlag = cancelFlag
        // The planner reports progress in sidecar families, and a RAW+JPEG
        // pair is one family with two paths. Seeding the physical-file count
        // here made the displayed total drop on the first callback.
        xmpPublicationState = .preflighting(done: 0, total: 0)
        let progress: XMPPublicationPlanner.Progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self,
                      self.xmpPublicationSessionToken == token,
                      case .preflighting = self.xmpPublicationState else { return }
                self.xmpPublicationState = .preflighting(done: done, total: total)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            await XMPPublicationPlanner.preflight(
                input,
                isCancelled: { cancelFlag.isSet },
                progress: progress
            )
        }
        xmpPublicationTask = Task { @MainActor [weak self] in
            let plan = await worker.value
            guard let self,
                  self.xmpPublicationSessionToken == token else { return }
            self.xmpPublicationTask = nil
            self.xmpPublicationCancelFlag = nil
            guard self.matchesCurrentSession(token) else {
                self.finishXMPPublicationLifecycle()
                return
            }
            if let plan {
                self.xmpPublicationState = .awaitingConfirmation(plan)
            } else {
                self.finishXMPPublicationLifecycle()
            }
        }
    }

    func startXMPPublication(planID: UUID) {
        guard !isNewFileOperationBlocked,
              case .awaitingConfirmation(let plan) = xmpPublicationState,
              plan.id == planID,
              case .ready = phase else { return }
        xmpPublicationGeneration &+= 1
        let token = XMPPublicationSessionToken(
            generation: xmpPublicationGeneration,
            scanGeneration: scanGeneration,
            folder: sourceFolder
        )
        let cancelFlag = XMPPublicationCancelFlag()
        xmpPublicationSessionToken = token
        xmpPublicationCancelFlag = cancelFlag
        xmpPublicationState = .publishing(done: 0, total: plan.publishableCount)
        let progress: XMPPublicationWorker.Progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self,
                      self.xmpPublicationSessionToken == token,
                      case .publishing = self.xmpPublicationState else { return }
                self.xmpPublicationState = .publishing(done: done, total: total)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            await XMPPublicationWorker.publish(
                plan,
                cancelFlag: cancelFlag,
                progress: progress
            )
        }
        xmpPublicationTask = Task { @MainActor [weak self] in
            let result = await worker.value
            guard let self,
                  self.xmpPublicationSessionToken == token else { return }
            self.xmpPublicationTask = nil
            self.xmpPublicationCancelFlag = nil
            guard self.matchesCurrentSession(token) else {
                self.finishXMPPublicationLifecycle()
                return
            }
            self.xmpPublicationState = .finished(result)
        }
    }

    func cancelXMPPublication() {
        switch xmpPublicationState {
        case .preflighting, .publishing:
            xmpPublicationCancelFlag?.set()
            xmpPublicationState = .cancelling
        case .awaitingConfirmation, .finished, .failed:
            finishXMPPublicationLifecycle()
        case .idle, .cancelling:
            break
        }
    }

    func resetXMPPublication() {
        guard !isXMPPublicationRunning else { return }
        finishXMPPublicationLifecycle()
    }

    /// Folder transitions and Quit call this before changing session
    /// identity. A requested cancellation waits until an in-progress atomic
    /// replacement has either committed or rolled back its private temporary.
    func cancelAndAwaitXMPPublication() async {
        xmpPublicationCancelFlag?.set()
        if isXMPPublicationRunning {
            xmpPublicationState = .cancelling
        }
        let task = xmpPublicationTask
        await task?.value
        finishXMPPublicationLifecycle()
    }

    private func matchesCurrentSession(
        _ token: XMPPublicationSessionToken
    ) -> Bool {
        token.scanGeneration == scanGeneration
            && token.folder?.standardizedFileURL
                == sourceFolder?.standardizedFileURL
    }

    private func finishXMPPublicationLifecycle() {
        xmpPublicationGeneration &+= 1
        xmpPublicationCancelFlag = nil
        xmpPublicationTask = nil
        xmpPublicationSessionToken = nil
        xmpPublicationState = .idle
    }

    /// The folder the export started from. Completion refuses to apply moved
    /// IDs to a different session even though the active-operation guards
    /// already prevent folder replacement.
    private var activeExportFolder: URL?

    /// Raises the shared file-operation state before Copy or Move touches the
    /// destination. Copy now receives the same Quit/update/folder-switch
    /// protection as operations that move originals.
    func exportWillStart(mode: ExportMode) -> Bool {
        guard !isNewFileOperationBlocked else { return false }
        guard mode != .metadataXMP else { return false }
        videoPlayback.stop()
        operationRecoveryCause = nil
        activeFileOperation = mode == .copy ? .exportCopy : .exportMove
        activeExportFolder = sourceFolder
        return true
    }

    /// Clears the export state and, for Move, drops photos whose files fully
    /// transferred. A Move is not undoable: its files are gone from the
    /// source folder, so the undo stack is cleared.
    func finishExport(
        mode: ExportMode,
        movedIDs: [String],
        requiresRecovery: Bool,
        interruptionMessage: String? = nil
    ) {
        guard mode != .metadataXMP else { return }
        let expectedOperation: FileOperationKind = mode == .copy ? .exportCopy : .exportMove
        guard activeFileOperation == expectedOperation else { return }
        let expectedFolder = activeExportFolder
        activeExportFolder = nil
        activeFileOperation = nil
        if mode == .move, !movedIDs.isEmpty {
            removeCompletedMovedItems(
                movedIDs,
                expectedFolder: expectedFolder
            )
        }
        if requiresRecovery {
            operationRecoveryCause = interruptionMessage
            beginInterruptedOperationRecovery(rescanOnSuccess: true)
            return
        }
    }

    /// Applies only worker-confirmed, pair-complete moves. An interrupted
    /// operation can still need recovery for a later pair or for retiring an
    /// old XMP source packet; those completed media must leave the live
    /// session immediately even when that recovery remains nonblocking.
    private func removeCompletedMovedItems(
        _ movedIDs: [String],
        expectedFolder: URL?
    ) {
        // Belt over braces: the in-flight guards make a mid-move session swap
        // impossible, but never remove ids from an unrelated session.
        if let expectedFolder,
           sourceFolder?.standardizedFileURL != expectedFolder.standardizedFileURL {
            return
        }
        let ids = Set(movedIDs)
        let previousIndex = currentIndex
        let previousItemID = currentItemID
        let removedBefore = items.prefix(min(previousIndex, items.count)).filter { ids.contains($0.id) }.count
        setSelectionIndices([])
        items = items.filter { !ids.contains($0.id) }
        emptySessionReason = items.isEmpty ? .movedOut : nil
        undoStack.removeAll()
        rebuildDerivedData()
        restoreCurrentItem(
            itemID: previousItemID,
            fallbackIndex: previousIndex - removedBefore
        )
        if !synchronizeFilterRangesWithAvailableData() { applyFilter() }
        markSessionChanged()
        saveSession()
    }

    // MARK: - Navigation (moves through *visible* photos only)

    func goNext() { stepVisible(1) }
    func goPrevious() { stepVisible(-1) }

    /// Gallery video transport reserves the horizontal arrow keys for clip
    /// inspection. Grid keeps its ordinary item-navigation behavior so arrow
    /// keys continue to follow the visible thumbnail layout there.
    var canSeekCurrentVideo: Bool {
        !isFileOperationRunning
            && viewMode == .gallery
            && currentItem?.isVideo == true
            && currentItem?.videoIsPlayable == true
    }

    func seekCurrentVideo(by offset: TimeInterval) {
        guard canSeekCurrentVideo, let item = currentItem else { return }
        videoPlayback.seek(item, by: offset)
    }

    var canToggleCurrentPlayableMedia: Bool {
        !isFileOperationRunning && currentItem?.isPlayableMedia == true
    }

    var canSetCurrentPlayableMediaPlaybackRate: Bool {
        !isFileOperationRunning
            && currentItem?.isPlayableMedia == true
    }

    func setCurrentPlayableMediaPlaybackRate(_ rate: Double) {
        guard canSetCurrentPlayableMediaPlaybackRate else { return }
        videoPlayback.setPlaybackRate(rate)
    }

    @discardableResult
    func adjustCurrentPlayableMediaPlaybackRate(forward: Bool) -> Bool {
        guard canSetCurrentPlayableMediaPlaybackRate else { return false }
        return videoPlayback.adjustPlaybackRate(forward: forward)
    }

    @discardableResult
    func toggleCurrentPlayableMedia() -> Bool {
        guard canToggleCurrentPlayableMedia, let item = currentItem else {
            return false
        }
        videoPlayback.toggle(item)
        return true
    }

    /// Bare horizontal arrows navigate still media and Grid. In a Gallery
    /// video they become half-second culling seeks; Shift-arrows make a
    /// larger five-second jump. J/L and Command-left/right always choose the
    /// adjacent review item.
    func performHorizontalReviewAction(forward: Bool) {
        if canSeekCurrentVideo {
            seekCurrentVideo(by: forward ? 0.5 : -0.5)
        } else if forward {
            goNext()
        } else {
            goPrevious()
        }
    }

    /// Moves to the photo in the same grid column on the row above or below.
    /// Each group starts a new grid, so crossing a group boundary lands in
    /// the nearest matching column of the adjacent group's first/last row.
    func goVertical(_ delta: Int) {
        guard !visibleGroups.isEmpty else { return }
        guard let location = preparedIndex.location(forItemIndex: currentIndex) else {
            setIndex(visibleIndices[0])
            return
        }
        let groupIndex = location.groupIndex
        let group = visibleGroups[groupIndex].indices
        let position = location.positionInGroup

        let columns = max(gridColumnCount, 1)
        let row = position / columns
        let column = position % columns
        let target: Int?

        if delta < 0 {
            if row > 0 {
                target = group[min((row - 1) * columns + column, group.count - 1)]
            } else if groupIndex > 0 {
                let previous = visibleGroups[groupIndex - 1].indices
                let lastRowStart = (previous.count - 1) / columns * columns
                target = previous[min(lastRowStart + column, previous.count - 1)]
            } else {
                target = nil
            }
        } else if delta > 0 {
            let nextRowStart = (row + 1) * columns
            if nextRowStart < group.count {
                target = group[min(nextRowStart + column, group.count - 1)]
            } else if groupIndex + 1 < visibleGroups.count {
                let next = visibleGroups[groupIndex + 1].indices
                target = next[min(column, next.count - 1)]
            } else {
                target = nil
            }
        } else {
            target = nil
        }

        if let target {
            setIndex(target)
        }
    }

    /// Receives the number of columns calculated by the rendered Grid view.
    func setGridColumnCount(_ count: Int) {
        let count = max(count, 1)
        guard gridColumnCount != count else { return }
        gridColumnCount = count
    }

    private func stepVisible(_ delta: Int) {
        guard !visibleIndices.isEmpty else { return }
        guard let pos = preparedIndex.location(forItemIndex: currentIndex)?.position else {
            setIndex(visibleIndices[0])
            return
        }
        let newPos = min(max(pos + delta, 0), visibleIndices.count - 1)
        setIndex(visibleIndices[newPos])
    }

    func setIndex(_ index: Int) {
        guard !isFileOperationRunning, !items.isEmpty else { return }
        // Plain navigation (click, arrow key) collapses any multi-selection.
        setSelectionIndices([])
        let clamped = min(max(index, 0), items.count - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        prefetchAroundCurrent()
    }

    private func advanceAfterDecision(
        position: Int?,
        in previousOrder: [Int]
    ) {
        guard !visibleIndices.isEmpty, !previousOrder.isEmpty else { return }
        let position = position ?? 0
        // Search the order the photographer was reviewing, wrapping once.
        // Decision sorting may have moved the rated item to another group.
        for offset in 1...previousOrder.count {
            let candidate = previousOrder[(position + offset) % previousOrder.count]
            if preparedIndex.location(forItemIndex: candidate) != nil,
               items[candidate].rating == .undecided {
                currentIndex = candidate
                prefetchAroundCurrent()
                return
            }
        }
        // With every visible item decided, step forward if possible and
        // stay at the last item instead of wrapping the completed review.
        restoreVisibleCurrentAfterDecision(
            position: position,
            in: previousOrder,
            advances: true
        )
    }

    private func restoreVisibleCurrentAfterDecision(
        position: Int?,
        in previousOrder: [Int],
        advances: Bool = false
    ) {
        guard !visibleIndices.isEmpty else { return }
        let position = position ?? 0
        let start = min(position + (advances ? 1 : 0), previousOrder.count)
        func eligible(_ index: Int) -> Bool {
            preparedIndex.location(forItemIndex: index) != nil
                && (selectedIndices.isEmpty || selectedIndices.contains(index))
        }
        let next = previousOrder.dropFirst(start).first(where: eligible)
            ?? previousOrder.prefix(start).last(where: eligible)
            ?? visibleIndices.first
        if let next {
            currentIndex = next
            prefetchAroundCurrent()
        }
    }

    /// Starting layout is applied only to a new folder or a closed session;
    /// changing Settings never reorders an in-progress review or its rescan.
    private func applyReviewDefaults() {
        let preferences = ReviewPreferences.load(from: reviewDefaults)
        sort = preferences.defaultSort
        isGroupingEnabled = preferences.isGroupingEnabled
        viewMode = preferences.defaultView
    }

    func toggleViewMode() {
        viewMode = (viewMode == .gallery) ? .grid : .gallery
    }

    /// The Browser column exists only in the Gallery view, so its toolbar
    /// button and the Q hotkey both come through this guard — the Grid must
    /// not change the Gallery's layout invisibly.
    func toggleBrowser() {
        guard viewMode == .gallery else { return }
        showBrowser.toggle()
    }

    func toggleZoom(_ mode: ZoomMode) {
        if mode == .actual {
            // S defines one inspection run. Enter centered; pressing S again
            // returns to Fit and clears the position carried across photos.
            let returnsToFit = isAtActualSize
            actualSizeViewport.reset()
            photoZoomScale = 1
            zoomMode = returnsToFit ? .fit : .actual
            return
        }
        zoomMode = (zoomMode == mode) ? .fit : mode
    }

    var isAtActualSize: Bool {
        zoomMode == .actual && abs(photoZoomScale - 1) < 0.001
    }

    /// The slider follows the currently displayed photo, not the last custom
    /// zoom from a different file. Fit/Phone is unavailable until the current
    /// source dimensions and viewport have been measured.
    var displayedPhotoZoomScale: CGFloat? {
        if zoomMode == .actual { return photoZoomScale }
        guard fittedPhotoZoomRevision == currentItem?.contentRevision,
              fittedPhotoZoomMode == zoomMode else { return nil }
        return fittedPhotoZoomScale
    }

    func reportFittedPhotoZoomScale(
        _ scale: CGFloat,
        revision: PhotoContentRevision,
        mode: ZoomMode
    ) {
        guard mode != .actual,
              zoomMode == mode,
              currentItem?.contentRevision == revision,
              scale.isFinite, scale > 0 else { return }
        let scale = ActualSizeGeometry.clampedZoom(scale)
        if fittedPhotoZoomRevision == revision,
           fittedPhotoZoomMode == mode,
           let fittedPhotoZoomScale,
           abs(fittedPhotoZoomScale - scale) < 0.001 { return }
        fittedPhotoZoomRevision = revision
        fittedPhotoZoomMode = mode
        fittedPhotoZoomScale = scale
    }

    /// Gallery double-click enters 100% with the clicked image point under the
    /// viewport center. Unlike S, it deliberately does not reset to center.
    func zoomToActual(at position: NormalizedImagePosition) {
        actualSizeViewport.request(position: position)
        photoZoomScale = 1
        zoomMode = .actual
    }

    func setPhotoZoomScale(
        _ scale: CGFloat,
        at position: NormalizedImagePosition? = nil,
        viewportAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) {
        let scale = ActualSizeGeometry.clampedZoom(scale)
        if let position {
            actualSizeViewport.request(
                position: position,
                viewportAnchor: viewportAnchor
            )
        }
        photoZoomScale = scale
        zoomMode = .actual
    }

    /// Native AppKit pinch is already smooth; publish only occasional values
    /// for the footer readout so Browser and Info do not redraw at gesture FPS.
    func reportPhotoZoomScaleFromGesture(_ scale: CGFloat, ended: Bool) {
        let scale = ActualSizeGeometry.clampedZoom(scale)
        let now = CFAbsoluteTimeGetCurrent()
        guard ended || now - lastGestureZoomPublication >= 0.05 else { return }
        lastGestureZoomPublication = now
        if abs(photoZoomScale - scale) >= 0.001 { photoZoomScale = scale }
    }

    /// A second Gallery double-click leaves the saved inspection point intact
    /// but returns the presentation to Fit. S remains the centered reset.
    func zoomToFit() {
        zoomMode = .fit
    }

    @discardableResult
    func toggleClippingWarnings() -> Bool {
        guard canToggleClippingWarnings else { return false }
        showClippingWarnings.toggle()
        return true
    }

    /// ⌘+ / ⌘− in the Grid view: bigger thumbnails mean fewer per row.
    func zoomGrid(larger: Bool) {
        let next = larger ? gridThumbSize * 1.25 : gridThumbSize / 1.25
        gridThumbSize = min(max(next, 90), 400)
    }

    private func prefetchAroundCurrent() {
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        // Prefetch the neighbouring *visible* photos, so filtered-out files
        // in between don't waste the warm-up window.
        guard let pos = preparedIndex.location(forItemIndex: currentIndex)?.position else { return }
        let windowOffsets = [1, 2, 3, -1]
        let photos = windowOffsets.compactMap { offset -> PhotoItem? in
            let p = pos + offset
            guard visibleIndices.indices.contains(p) else { return nil }
            let item = items[visibleIndices[p]]
            return item.mediaKind == .photo && item.isSupported ? item : nil
        }
        // Collapse repeated navigation/filter updates into one neighbourhood
        // warm-up. The visible image itself still starts immediately.
        let work = DispatchWorkItem {
            ImagePipeline.shared.prefetchFullImages(items: photos)
            HighResolutionImagePipeline.shared.prefetchSources(items: photos)
        }
        prefetchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: - Saved decision recovery

    var pendingSessionRecoveryEntries: [SessionRecoveryEntry] {
        sessionRecoveryEntries.filter { $0.resolvedFileID == nil }
    }

    var showsSessionRecoveryNotice: Bool {
        !isSessionRecoveryNoticeDismissed
            && (!pendingSessionRecoveryEntries.isEmpty || automaticallyRestoredSessionFiles > 0)
    }

    func dismissSessionRecoveryNotice() {
        isSessionRecoveryNoticeDismissed = true
    }

    var sessionRecoveryNotice: String {
        let count = pendingSessionRecoveryEntries.count
        if count > 0 {
            return L10n.text("Saved decisions for \(count) files need checking. You can keep reviewing; previous decisions are preserved.")
        }
        return L10n.text("Restored saved decisions for \(automaticallyRestoredSessionFiles) identical files.")
    }

    func recoveryFile(for record: SessionRecoveryEntry) -> PhotoFile? {
        sessionRecoveryFileIDs[record.id].flatMap { sessionFile(forID: $0) }
    }

    func canRestoreSessionRecoveryEntry(_ record: SessionRecoveryEntry) -> Bool {
        guard record.resolvedFileID == nil,
              let file = recoveryFile(for: record),
              file.scannedIdentity != nil else { return false }
        return SessionRecoveryPolicy.isUntouched(file.metadataSnapshot)
    }

    func sessionRecoveryStatus(_ record: SessionRecoveryEntry) -> String {
        guard let file = recoveryFile(for: record) else { return L10n.text("File unavailable") }
        guard SessionRecoveryPolicy.isUntouched(file.metadataSnapshot) else {
            return L10n.text("Current decisions kept")
        }
        if sessionContentFailures.contains(file.id) { return L10n.text("Could not check file") }
        guard let oldDigest = record.entry.contentSHA256 else {
            return L10n.text("Older session: confirmation needed")
        }
        guard let proof = sessionContentProofs[file.id] else { return L10n.text("Waiting for content check") }
        return proof.sha256 == oldDigest
            ? L10n.text("Identical contents") : L10n.text("File contents changed")
    }

    /// Confirmation belongs only to the current scanned files and selected
    /// records. A fresh descriptor/identity check still precedes restoration.
    func restoreSessionRecoveryEntries(_ ids: Set<UUID>) {
        guard !isFileOperationRunning, !isPreparingForTermination else { return }
        let eligible = pendingSessionRecoveryEntries.filter {
            ids.contains($0.id) && canRestoreSessionRecoveryEntry($0)
        }
        guard !eligible.isEmpty else { return }
        pauseSessionContentChecks()
        sessionRecoveryConfirmations.formUnion(eligible.map(\.id))
        for record in eligible {
            if let id = sessionRecoveryFileIDs[record.id] {
                sessionContentFailures.remove(id)
                sessionContentPendingFileIDs.insert(id)
            }
        }
        sessionContentChecksPaused = false
        startSessionContentChecks()
    }

    func keepCurrentSessionDecisions(_ ids: Set<UUID>) {
        guard !isFileOperationRunning, !isPreparingForTermination else { return }
        for index in sessionRecoveryEntries.indices where ids.contains(sessionRecoveryEntries[index].id) {
            sessionRecoveryEntries[index].resolvedFileID = sessionRecoveryEntries[index].entry.filename
            sessionRecoveryConfirmations.remove(sessionRecoveryEntries[index].id)
        }
        // History remains in the sidecar. This only dismisses pending attention.
        scheduleSave()
    }

    func toggleSessionContentChecks() {
        sessionContentChecksPaused.toggle()
        if sessionContentChecksPaused { pauseSessionContentChecks() }
        else { startSessionContentChecks() }
    }

    private func pauseSessionContentChecks() {
        sessionContentGeneration &+= 1
        sessionContentTask?.cancel()
        sessionContentTask = nil
        if case .checking = sessionContentCheck { sessionContentCheck = .paused }
    }

    private func resetSessionRecovery() {
        pauseSessionContentChecks()
        sessionRecoveryEntries = []
        isSessionRecoveryPresented = false
        isSessionRecoveryNoticeDismissed = false
        sessionContentProofs = [:]
        sessionContentCapturedProofs = [:]
        sessionContentFailures = []
        sessionRecoveryConfirmations = []
        sessionRecoveryAttemptedIDs = []
        sessionRecoveryFileIDs = [:]
        sessionRecoveryRecordIndicesByFileID = [:]
        sessionContentPendingFileIDs = []
        sessionContentCheck = .idle
        sessionContentChecksPaused = false
        automaticallyRestoredSessionFiles = 0
    }

    func startSessionContentChecks() {
        guard case .ready = phase, !isFileOperationRunning,
              !isPreparingForTermination, !sessionContentChecksPaused,
              !isLegacySessionMigrationConfirmationPresented,
              sessionContentTask == nil else { return }
        var todo: [PhotoFile] = []
        for id in sessionContentPendingFileIDs {
            guard let file = sessionFile(forID: id), file.scannedIdentity != nil,
                  !sessionContentFailures.contains(id) else {
                sessionContentPendingFileIDs.remove(id)
                continue
            }
            let records = (sessionRecoveryRecordIndicesByFileID[id] ?? []).filter {
                sessionRecoveryEntries[$0].resolvedFileID == nil
            }
            let needsRecovery = records.contains { index in
                let record = sessionRecoveryEntries[index]
                if sessionRecoveryConfirmations.contains(record.id) { return true }
                guard !sessionRecoveryAttemptedIDs.contains(record.id) else { return false }
                return record.entry.contentSHA256 != nil || record.entry.fileIdentity.map {
                    SessionRatingIndex.persistedIdentityMatches(expected: $0, actual: file.scannedIdentity!)
                } == true
            }
            if needsRecovery || (!SessionRecoveryPolicy.isUntouched(file.metadataSnapshot)
                && sessionContentProofs[id]?.identity != file.scannedIdentity) {
                todo.append(file)
            } else {
                sessionContentPendingFileIDs.remove(id)
            }
        }
        todo.sort {
            let left = sessionRecoveryRecordIndicesByFileID[$0.id] != nil
            let right = sessionRecoveryRecordIndicesByFileID[$1.id] != nil
            return left == right ? $0.id < $1.id : left
        }
        guard !todo.isEmpty else { sessionContentCheck = .finished; return }
        let generation = sessionContentGeneration
        let scan = scanGeneration
        let lease = sourceFolderAccess?.makeIndependentAccess()
        sessionContentCheck = .checking(done: 0, total: todo.count)
        sessionContentTask = Task { @MainActor [weak self] in
            defer { lease?.stop() }
            var needsCheckpoint = false
            for (offset, file) in todo.enumerated() {
                guard let self, !Task.isCancelled,
                      self.scanGeneration == scan,
                      self.sessionContentGeneration == generation else { return }
                let cached = self.sessionContentProofs[file.id]
                let verify = self.sessionContentVerification
                let recordIndices = self.sessionRecoveryRecordIndicesByFileID[file.id] ?? []
                let isConfirmed = recordIndices.contains {
                    let record = self.sessionRecoveryEntries[$0]
                    return record.resolvedFileID == nil && self.sessionRecoveryConfirmations.contains(record.id)
                }
                let isPhysicalOriginal = recordIndices.contains {
                    let record = self.sessionRecoveryEntries[$0]
                    return record.resolvedFileID == nil && record.entry.fileIdentity.map {
                        SessionRatingIndex.persistedIdentityMatches(expected: $0, actual: file.scannedIdentity!)
                    } == true
                }
                let worker = Task.detached(priority: .utility) {
                    if isConfirmed || isPhysicalOriginal {
                        return SessionVerifiedFile.identity(try SessionContentVerifier.validateIdentity(file))
                    }
                    return SessionVerifiedFile.content(try await verify(file, cached))
                }
                let result = await withTaskCancellationHandler {
                    await worker.result
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled,
                      self.scanGeneration == scan,
                      self.sessionContentGeneration == generation,
                      !self.isFileOperationRunning,
                      !self.isPreparingForTermination,
                      case .ready = self.phase else { return }
                switch result {
                case .success(let verified):
                    if let proof = verified.proof { self.sessionContentProofs[file.id] = proof }
                    self.sessionRecoveryAttemptedIDs.formUnion(recordIndices.map { self.sessionRecoveryEntries[$0].id })
                    self.applySessionRecovery(to: file, verified: verified, recordIndices: recordIndices)
                    self.sessionRecoveryConfirmations.subtract(recordIndices.map { self.sessionRecoveryEntries[$0].id })
                    if let proof = verified.proof,
                       let current = self.sessionFile(forID: file.id),
                       !SessionRecoveryPolicy.isUntouched(current.metadataSnapshot),
                       self.sessionContentCapturedProofs[file.id]?.identity != proof.identity {
                        needsCheckpoint = true
                    }
                case .failure:
                    self.sessionContentFailures.insert(file.id)
                }
                self.sessionContentPendingFileIDs.remove(file.id)
                // Identity-only restoration queues its portable proof afterward.
                if case .success(.identity) = result,
                   let current = self.sessionFile(forID: file.id),
                   !SessionRecoveryPolicy.isUntouched(current.metadataSnapshot),
                   self.sessionContentProofs[file.id]?.identity != current.scannedIdentity {
                    self.sessionContentPendingFileIDs.insert(file.id)
                }
                self.sessionContentCheck = .checking(done: offset + 1, total: todo.count)
            }
            guard let self, self.sessionContentGeneration == generation else { return }
            self.sessionContentTask = nil
            self.sessionContentCheck = .finished
            // Unrated fingerprints ride the next real save. Only newly proven
            // reviewed files need a checkpoint; never duplicate an optional
            // initial save or replace the existing coalescing authority.
            if needsCheckpoint { self.scheduleSave(markChanged: false) }
            // An explicit restoration is immediate; prepare its portable
            // fingerprint afterward, while normal reviewing remains available.
            self.startSessionContentChecks()
        }
    }

    private func applySessionRecovery(
        to scannedFile: PhotoFile, verified: SessionVerifiedFile, recordIndices: [Int]
    ) {
        guard !sessionRecoveryEntries.isEmpty,
              let itemIndex = itemIndexByFileID[scannedFile.id],
              items.indices.contains(itemIndex),
              let file = items[itemIndex].individualFiles.first(where: { $0.id == scannedFile.id }),
              file.scannedIdentity == verified.identity,
              SessionRecoveryPolicy.isUntouched(file.metadataSnapshot) else { return }
        let candidates = recordIndices.filter { sessionRecoveryEntries[$0].resolvedFileID == nil }
        // Multiple generations at one path require selecting the intended one.
        let confirmed = candidates.filter { sessionRecoveryConfirmations.contains(sessionRecoveryEntries[$0].id) }
        let physical = candidates.filter { index in
            sessionRecoveryEntries[index].entry.fileIdentity.map {
                SessionRatingIndex.persistedIdentityMatches(expected: $0, actual: verified.identity)
            } == true
        }
        let automatic = candidates.filter {
            guard let digest = sessionRecoveryEntries[$0].entry.contentSHA256 else { return false }
            return digest == verified.proof?.sha256
        }
        let choices = !confirmed.isEmpty ? confirmed : (!physical.isEmpty ? physical : automatic)
        guard choices.count == 1, let index = choices.first else { return }
        let entry = sessionRecoveryEntries[index].entry
        let oldDecision = items[itemIndex].ratingState
        let oldStars = items[itemIndex].starRatingState
        let oldColor = items[itemIndex].colorLabelState
        file.restoreMetadata(PhotoFileMetadataSnapshot(
            fileID: file.id, rating: Rating(rawValue: entry.rating) ?? .undecided,
            ratedAt: entry.ratedAt, starRating: entry.stars,
            starsChangedAt: entry.starsChangedAt, colorLabel: entry.colorLabel,
            colorChangedAt: entry.colorChangedAt
        ))
        // Organization origins describe the old physical file's location and
        // are deliberately not inherited by a copied/restored file.
        sessionRecoveryConfirmations.remove(sessionRecoveryEntries[index].id)
        sessionRecoveryEntries[index].resolvedFileID = file.id
        if confirmed.isEmpty { automaticallyRestoredSessionFiles += 1 }
        transitionRatingCount(from: oldDecision, to: items[itemIndex].ratingState)
        transitionStarCount(from: oldStars, to: items[itemIndex].starRatingState)
        transitionColorCount(from: oldColor, to: items[itemIndex].colorLabelState)
        publishMetadataMutation(.all, affectedFileIDs: [file.id], preservingCurrent: true)
        scheduleSave()
    }

    // MARK: - Session persistence

    private func markSessionChanged() {
        if sessionChangeGeneration < UInt64.max {
            sessionChangeGeneration += 1
        }
        // A sidecar-repair warning may truthfully describe the previous
        // durable generation, but it becomes misleading the instant the
        // photographer makes a new change. The scheduled save will publish a
        // fresh warning only if that newer snapshot actually fails.
        if retrySaveIsOptionalSidecarRepair {
            persistenceWarning = nil
        }
    }

    private func scheduleSave(markChanged: Bool = true) {
        if markChanged { markSessionChanged() }
        startSessionContentChecks()
        saveDebounce?.cancel()
        saveTrailingGeneration &+= 1
        let trailingGeneration = saveTrailingGeneration
        let trailingWork = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.saveTrailingGeneration == trailingGeneration,
                      self.saveDebounce != nil else { return }
                self.performScheduledSave()
            }
        }
        saveDebounce = trailingWork
        DispatchQueue.main.asyncAfter(
            deadline: .now() + saveTrailingDelay,
            execute: trailingWork
        )

        // A trailing debounce alone can postpone persistence forever while a
        // photographer rates continuously. Arm one fixed deadline for this
        // dirty cycle; later ratings replace only the trailing save.
        if saveDeadline == nil {
            saveCycleGeneration &+= 1
            let cycleGeneration = saveCycleGeneration
            let deadlineWork = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self,
                          self.saveCycleGeneration == cycleGeneration,
                          self.saveDeadline != nil else { return }
                    self.performScheduledSave()
                }
            }
            saveDeadline = deadlineWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + saveMaximumDelay,
                execute: deadlineWork
            )
        }
    }

    private func cancelScheduledSave() {
        saveDebounce?.cancel()
        saveDeadline?.cancel()
        saveDebounce = nil
        saveDeadline = nil
        saveTrailingGeneration &+= 1
        saveCycleGeneration &+= 1
    }

    private func performScheduledSave() {
        cancelScheduledSave()
        guard activePersistenceSaveCount == 0 else {
            // Keep only the fact that a newer snapshot is needed. When slow or
            // removable storage finishes the current write, capture one fresh
            // latest snapshot instead of queueing an unbounded series of
            // intermediate 100,000-item payloads.
            saveRequestedWhilePersistenceBusy = true
            return
        }
        saveSession()
    }

    func saveSession() {
        cancelScheduledSave()
        guard let request = makeSaveRequest() else { return }
        saveRequestedWhilePersistenceBusy = false
        enqueuePersistenceSave(request)
    }

    /// Wait for any active checkpoint, then save only when the live session is
    /// newer than its last durable sidecar/backup snapshot. The app delegate
    /// uses this with AppKit's asynchronous termination handshake, so clean
    /// sessions start no redundant write and a last-second rating still
    /// reaches disk. An already-active checkpoint is always awaited.
    func saveSessionForTermination() async -> SessionPersistence.SaveResult? {
        // Quitting while the legacy decision is visible is equivalent to
        // Close Folder: preserve the old snapshot and write nothing.
        guard !isLegacySessionMigrationConfirmationPresented else {
            return nil
        }
        return await persistCurrentSessionIfNeededBeforeDiscard()
    }

    /// Shared Close/Open/Rescan/Quit barrier. The caller first raises either
    /// `isSessionTransitioning` or `isPreparingForTermination`, so no mutation
    /// can arrive after the generation checked here.
    private func persistCurrentSessionIfNeededBeforeDiscard() async
        -> SessionPersistence.SaveResult? {
        cancelScheduledSave()

        // A checkpoint already in flight may contain the complete live
        // session. Await it before deciding whether another write is needed;
        // otherwise a transition duplicates slow removable-volume work and can show
        // a false failure after an identical snapshot was already secured.
        var awaitedResult: SessionPersistence.SaveResult?
        if activePersistenceSaveCount > 0,
           let task = pendingPersistenceTask {
            // This transition owns the final coalescing decision from here. The
            // completion observer must not enqueue a third write while this
            // method is suspended awaiting the current one.
            saveRequestedWhilePersistenceBusy = false
            let outcome = await task.value
            applyPersistenceResult(outcome.result, request: outcome.request)
            awaitedResult = outcome.result
        }

        if persistenceRejectedInvalidSnapshot {
            return .rejectedInvalidSnapshot
        }

        if currentSessionIsDurable {
            return awaitedResult?.canDiscardInMemoryState == true
                ? awaitedResult
                : nil
        }

        if let request = makeSaveRequest() {
            let outcome = await enqueuePersistenceSave(request).value
            applyPersistenceResult(outcome.result, request: outcome.request)
            return outcome.result
        }

        if let awaitedResult {
            if awaitedResult.canDiscardInMemoryState
                || awaitedResult == .rejectedInvalidSnapshot {
                return awaitedResult
            }
        }

        if let request = retrySaveRequest,
           !retrySaveIsOptionalSidecarRepair {
            let retry = refreshedSaveRequest(from: request)
            let outcome = await enqueuePersistenceSave(retry).value
            applyPersistenceResult(outcome.result, request: outcome.request)
            return outcome.result
        }
        return nil
    }

    /// AppKit remains interactive while `.terminateLater` awaits persistence.
    /// Hold this barrier before the final snapshot so no rating can arrive
    /// after the snapshot that authorizes Quit.
    func beginTerminationPreparation() {
        pauseQualityCueAnalysis()
        pauseSessionContentChecks()
        isPreparingForTermination = true
    }

    /// Called only when the photographer cancels Quit after a failed save.
    func cancelTerminationPreparation() {
        isPreparingForTermination = false
        startQualityCueAnalysis()
        startSessionContentChecks()
    }

    /// Retry the newest live snapshot, or the exact snapshot retained after a
    /// failed Close Session. Success clears the warning automatically.
    func retryPersistence() {
        guard canRetryPersistence else { return }
        cancelScheduledSave()
        if let request = makeSaveRequest() {
            enqueuePersistenceSave(request)
        } else if let request = retrySaveRequest {
            enqueuePersistenceSave(refreshedSaveRequest(from: request))
        }
    }

    private struct SaveRequest: Sendable {
        let folder: URL
        let payload: SavePayload
        let sequence: UInt64
        let access: SessionPersistence.AccessContext
        let changeGeneration: UInt64

        func materialized() -> SaveRequest {
            guard case .capture(let capture) = payload else { return self }
            return SaveRequest(
                folder: folder,
                payload: .session(capture.makeSession()),
                sequence: sequence,
                access: access,
                changeGeneration: changeGeneration
            )
        }
    }

    private enum SavePayload: Sendable {
        case capture(SessionSnapshotCapture)
        case session(SessionFile)
    }

    private struct SaveOutcome: Sendable {
        let request: SaveRequest
        let result: SessionPersistence.SaveResult
    }

    @discardableResult
    private func enqueuePersistenceSave(
        _ request: SaveRequest
    ) -> Task<SaveOutcome, Never> {
        // Any explicitly enqueued snapshot is at least as fresh as the
        // coalesced request from the live store. It therefore satisfies that
        // marker; leaving it set could start an unawaited redundant write
        // after Open, Close, or Quit has already crossed its save barrier.
        saveRequestedWhilePersistenceBusy = false
        activePersistenceSaveCount += 1
        let task = Task.detached { [persistence] in
            let prepared = request.materialized()
            guard case .session(let session) = prepared.payload else {
                preconditionFailure("materialized save request has no session")
            }
            let result = await persistence.save(
                session,
                for: request.folder,
                sequence: request.sequence,
                access: request.access
            )
            return SaveOutcome(request: prepared, result: result)
        }
        pendingPersistenceTask = task
        Task { @MainActor [weak self] in
            let outcome = await task.value
            self?.persistenceSaveDidComplete(
                outcome.result,
                request: outcome.request
            )
        }
        return task
    }

    private func persistenceSaveDidComplete(
        _ result: SessionPersistence.SaveResult,
        request: SaveRequest
    ) {
        activePersistenceSaveCount = max(0, activePersistenceSaveCount - 1)
        if activePersistenceSaveCount == 0 {
            pendingPersistenceTask = nil
        }
        applyPersistenceResult(result, request: request)
        guard activePersistenceSaveCount == 0,
              saveRequestedWhilePersistenceBusy else { return }
        saveRequestedWhilePersistenceBusy = false
        saveSession()
    }

    private func applyPersistenceResult(
        _ result: SessionPersistence.SaveResult,
        request: SaveRequest
    ) {
        guard request.sequence >= latestReportedSaveSequence else { return }
        if let folder = sourceFolder,
           folder.standardizedFileURL != request.folder.standardizedFileURL {
            return
        }
        let appliesToLiveSession =
            persistenceGenerationAccessID == request.access.id
        let appliesToRetainedRetry = persistenceGenerationAccessID == nil
            && sourceFolder == nil
            && retrySaveRequest?.access.id == request.access.id
        guard appliesToLiveSession || appliesToRetainedRetry else { return }
        guard result != .superseded else { return }
        latestReportedSaveSequence = request.sequence
        let liveRequestWasAlreadyDurable = appliesToLiveSession
            && durableSessionChangeGeneration.map {
                $0 >= request.changeGeneration
            } == true
        let requestWasAlreadyDurable = liveRequestWasAlreadyDurable || (
            appliesToRetainedRetry && retrySaveIsOptionalSidecarRepair
        )
        let liveSessionHasNewerChanges = appliesToLiveSession
            && sessionChangeGeneration > request.changeGeneration

        switch result {
        case .savedToSidecar:
            recordDurableGeneration(for: request)
            retrySaveRequest = nil
            retrySaveIsOptionalSidecarRepair = false
            persistenceWarning = nil
            persistenceRejectedInvalidSnapshot = false
        case .savedToBackup(let sidecarFailure):
            recordDurableGeneration(for: request)
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = true
            persistenceRejectedInvalidSnapshot = false
            guard !liveSessionHasNewerChanges else {
                persistenceWarning = nil
                return
            }
            switch sidecarFailure {
            case .permissionDenied:
                persistenceWarning = L10n.text("This folder is read-only. Your ratings are safe in Louppe's backup, but not beside the photos. Restore write access, then retry.")
            case .outOfSpace:
                persistenceWarning = L10n.text("The media volume is out of space. Your ratings are safe in Louppe's backup, but not beside the photos. Free some space, then retry.")
            case .volumeUnavailable:
                persistenceWarning = L10n.text("The media volume is unavailable. Your ratings are safe in Louppe's backup. Reconnect it, then retry.")
            case .busy:
                persistenceWarning = L10n.text("Another Louppe window is saving this folder. Your ratings are safe in Louppe's backup. Retry in a moment.")
            case .encoding, .snapshotTooLarge, .other:
                persistenceWarning = L10n.text("Your ratings are safe in Louppe's backup, but the folder session file couldn't be updated. Retry when the folder is available.")
            }
        case .failed(let failure):
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = requestWasAlreadyDurable
            persistenceRejectedInvalidSnapshot = false
            if requestWasAlreadyDurable && liveSessionHasNewerChanges {
                persistenceWarning = nil
            } else if requestWasAlreadyDurable {
                persistenceWarning = optionalSidecarRepairWarning(
                    sidecarFailure: failure.sidecar
                )
            } else if failure.sidecar == .snapshotTooLarge
                        || failure.backup == .snapshotTooLarge {
                persistenceWarning = L10n.text("Your latest ratings are not saved: the session is too large to reopen. Both saved copies remain untouched. Keep this session open and contact Alex.")
            } else if failure.sidecar == .busy || failure.backup == .busy {
                persistenceWarning = L10n.text("Another Louppe window is saving this folder. Your latest ratings are not saved yet. Retry in a moment.")
            } else if failure.sidecar == .outOfSpace || failure.backup == .outOfSpace {
                persistenceWarning = L10n.text("Your latest ratings are not saved because the disk is full. Free some space and retry before closing Louppe.")
            } else if failure.sidecar == .permissionDenied
                        && failure.backup == .permissionDenied {
                persistenceWarning = L10n.text("Your latest ratings are not saved because Louppe cannot write to the folder or its backup location. Fix the permissions and retry.")
            } else if failure.sidecar == .volumeUnavailable
                        && failure.backup == .volumeUnavailable {
                persistenceWarning = L10n.text("Your latest ratings are not saved because the storage volume is unavailable. Reconnect it and retry before closing Louppe.")
            } else {
                persistenceWarning = L10n.text("Your latest ratings are not saved. Retry before closing Louppe.")
            }
        case .rejectedInvalidSnapshot:
            retrySaveRequest = nil
            retrySaveIsOptionalSidecarRepair = false
            persistenceRejectedInvalidSnapshot = true
            persistenceWarning = L10n.text("Louppe rejected an inconsistent snapshot before it could replace either saved copy. Keep this session open and report the problem.")
        case .sourceFolderChanged:
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = requestWasAlreadyDurable
            persistenceRejectedInvalidSnapshot = false
            if requestWasAlreadyDurable {
                persistenceWarning = liveSessionHasNewerChanges
                    ? nil
                    : L10n.text("No new ratings are waiting to be saved. The folder or card changed; its session file remains untouched. Reconnect the original to repair it.")
            } else {
                persistenceWarning = L10n.text("The folder or card changed before saving. Both saved copies remain untouched. Reconnect the original, then retry saving.")
            }
        case .sidecarChanged:
            retrySaveRequest = request
            retrySaveIsOptionalSidecarRepair = requestWasAlreadyDurable
            persistenceRejectedInvalidSnapshot = false
            if requestWasAlreadyDurable {
                persistenceWarning = liveSessionHasNewerChanges
                    ? nil
                    : L10n.text("No new ratings are waiting to be saved. The session file changed outside Louppe and remains untouched. Restore the version you want before repair.")
            } else {
                persistenceWarning = L10n.text("The session file changed outside Louppe. Both versions remain untouched. Restore the version you want, then retry saving.")
            }
        case .superseded:
            break
        }
    }

    private func optionalSidecarRepairWarning(
        sidecarFailure: SessionPersistence.FailureReason
    ) -> String {
        switch sidecarFailure {
        case .permissionDenied:
            return L10n.text("No new ratings are waiting to be saved. The folder session file is still read-only; restore write access to repair it.")
        case .outOfSpace:
            return L10n.text("No new ratings are waiting to be saved. The folder session file couldn't be repaired because the media volume is full.")
        case .volumeUnavailable:
            return L10n.text("No new ratings are waiting to be saved. Reconnect the media volume to repair its folder session file.")
        case .busy:
            return L10n.text("No new ratings are waiting to be saved. Another Louppe window is using this folder; retry the sidecar repair in a moment.")
        case .encoding, .snapshotTooLarge, .other:
            return L10n.text("No new ratings are waiting to be saved. The folder session file still couldn't be repaired.")
        }
    }

    private func recordDurableGeneration(for request: SaveRequest) {
        guard persistenceGenerationAccessID == request.access.id else { return }
        durableSessionChangeGeneration = max(
            durableSessionChangeGeneration ?? 0,
            request.changeGeneration
        )
    }

    private var currentSessionIsDurable: Bool {
        guard let access = persistenceAccess,
              persistenceGenerationAccessID == access.id,
              let durableSessionChangeGeneration else { return false }
        return durableSessionChangeGeneration >= sessionChangeGeneration
    }

    private func refreshedSaveRequest(from request: SaveRequest) -> SaveRequest {
        guard case .session(var session) = request.payload else {
            preconditionFailure("retry request has no completed session")
        }
        session.scannedAt = Date()
        saveSequence &+= 1
        return SaveRequest(
            folder: request.folder,
            payload: .session(session),
            sequence: saveSequence,
            access: request.access,
            changeGeneration: request.changeGeneration
        )
    }

    /// Freeze only the shared mutable metadata at the generation boundary.
    /// Entry construction, missing-file reconciliation, encoding, and I/O run
    /// outside the main actor while this exact captured generation is retained
    /// for failures and retry.
    private func makeSaveRequest() -> SaveRequest? {
        guard let folder = sourceFolder,
              let access = persistenceAccess,
              !isLegacySessionMigrationConfirmationPresented,
              case .ready = phase else { return nil }
        let capture = SessionSnapshotCapture(
            sourcePath: folder.path,
            items: items,
            retainedEntries: retainedMissingSessionEntries,
            originPaths: organizationOriginFolderPathBytesByFileID,
            contentProofs: sessionContentProofs,
            recoveryEntries: sessionRecoveryEntries
        )
        sessionContentCapturedProofs = sessionContentProofs
        saveSequence &+= 1
        return SaveRequest(
            folder: folder,
            payload: .capture(capture),
            sequence: saveSequence,
            access: access,
            changeGeneration: sessionChangeGeneration
        )
    }

    // MARK: - Recent folders

    private func loadRecents() {
        recentFolders = SecurityScopedFolderBookmarks.load()
    }

    private func addToRecents(_ url: URL) {
        var folders = recentFolders
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        folders.insert(url, at: 0)
        if folders.count > 8 { folders = Array(folders.prefix(8)) }
        SecurityScopedFolderBookmarks.save(folders)
        recentFolders = folders
    }

    // MARK: - Going back to the welcome screen

    func closeSession() {
        if hasXMPPublicationSessionState {
            guard !isSessionTransitioning,
                  activeFileOperation == nil,
                  !isPreparingForTermination else { return }
            isSessionTransitioning = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.cancelAndAwaitXMPPublication()
                self.isExportPresented = false
                self.isSessionTransitioning = false
                self.closeSession()
            }
            return
        }
        guard !isFileOperationRunning else { return }
        if isLegacySessionMigrationConfirmationPresented {
            closeLegacySessionWithoutMigrating()
            return
        }
        isSessionTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self
                .persistCurrentSessionIfNeededBeforeDiscard()
            self.isSessionTransitioning = false
            guard result?.canDiscardInMemoryState != false else { return }
            self.finishClosingSession()
        }
    }

    private func finishClosingSession() {
        resetSessionRecovery()
        finishXMPPublicationLifecycle()
        invalidateDuplicateBurstAnalysis(rebuildLayout: false)
        cancelScheduledSave()
        videoPlayback.resetRememberedPositions()
        zoomMode = .fit
        photoZoomScale = 1
        showClippingWarnings = false
        actualSizeViewport.reset()
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        cleanUpGeneration &+= 1
        filterDebounce?.cancel()
        filterDebounce = nil
        prefetchDebounce?.cancel()
        prefetchDebounce = nil
        scanResumeIdentity = nil
        retainedMissingSessionEntries = []
        pendingLegacySidecarRelocationAuthorization = nil
        canOpenMismatchedSessionAnyway = false
        canOpenIdentityConflictAsNewSession = false
        if retrySaveRequest == nil {
            persistenceWarning = nil
            persistenceRejectedInvalidSnapshot = false
        }
        persistenceAccess = nil
        persistenceGenerationAccessID = nil
        durableSessionChangeGeneration = nil
        sessionChangeGeneration = 0
        isLegacySessionMigrationConfirmationPresented = false
        legacySessionMigrationMissingFileCount = 0
        legacySessionMigrationUsesUnownedBackup = false
        items = []
        emptySessionReason = nil
        resetDerivedData()
        sourceFolderAccess?.stop()
        sourceFolderAccess = nil
        sourceFolder = nil
        undoStack = []
        setSelectionIndices([])
        isClearAllRatingsConfirmationPresented = false
        pendingCleanUp = nil
        dismissCleanUpError()
        pairingMetadataError = nil
        currentIndex = 0
        filter = PhotoFilter()
        applyReviewDefaults()
        visibleIndices = []
        isFilterPresented = false
        isSortPresented = false
        isReviewStatusPresented = false
        isOrganizePresented = false
        isRenamePresented = false
        isActionPalettePresented = false
        actionPaletteFollowUp = nil
        phase = .welcome
    }
}
