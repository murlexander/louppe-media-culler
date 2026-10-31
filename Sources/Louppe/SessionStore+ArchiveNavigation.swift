import Foundation
import CoreGraphics

enum ArchiveLeadingPane: String, CaseIterable {
    case browser, folders
}

/// Folders pane width bounds; the Browser keeps its fixed thumbnail column.
enum ArchiveFolderPaneWidth {
    static let standard: CGFloat = 220
    static let range: ClosedRange<CGFloat> = 180...420
    static func clamped(_ width: CGFloat) -> CGFloat { min(max(width, range.lowerBound), range.upperBound) }
}

/// Whether bulk expansion would change the visible tree. Collapse ignores
/// All Media and the current folder's ancestors, which always stay open.
struct ArchiveExpansionSummary: Equatable {
    let canExpand: Bool
    let canCollapse: Bool

#if DEBUG
    init(canExpandForTesting canExpand: Bool, canCollapse: Bool) {
        self.canExpand = canExpand
        self.canCollapse = canCollapse
    }
#endif

    init(index: ArchiveFolderIndex?, expanded: Set<String>, selectedFolderID: String) {
        guard let index, index.nodes.count > 1 else { canExpand = false; canCollapse = false; return }
        canExpand = index.expandableFolderIDs.contains { !expanded.contains($0) }
        // The outline always keeps the current folder's ancestors open.
        let path = Set(index.breadcrumbs(to: selectedFolderID).dropLast().map(\.id))
        // Only a visibly open folder counts: hidden expansions below a
        // collapsed parent do not make Collapse All meaningful.
        canCollapse = expanded.contains { id in
            guard !id.isEmpty, !path.contains(id), let node = index.node(for: id), !node.children.isEmpty else { return false }
            var parent = node.parentID
            while let current = parent {
                guard expanded.contains(current) || path.contains(current) else { return false }
                parent = index.node(for: current)?.parentID
            }
            return true
        }
    }
}

extension SessionStore {
    var hasArchiveFolders: Bool { (archiveFolderIndex?.nodes.count ?? 0) > 1 }
    var isLeadingPaneVisible: Bool {
        showBrowser && (viewMode == .gallery || archiveLeadingPane == .folders && hasArchiveFolders)
    }
    func toggleLeadingPane() {
        if viewMode == .grid {
            let wasVisible = isLeadingPaneVisible
            archiveLeadingPane = .folders
            showBrowser = !wasVisible
        } else { toggleBrowser() }
    }

    /// Shows the leading pane with this content in one step. Grid has no
    /// thumbnail Browser, so choosing Browser there returns to Gallery.
    func showLeadingPane(_ pane: ArchiveLeadingPane) {
        let target: ArchiveLeadingPane = pane == .folders && !hasArchiveFolders ? .browser : pane
        archiveLeadingPane = target
        if target == .browser, viewMode == .grid { viewMode = .gallery }
        showBrowser = true
    }

    /// What the leading pane actually shows. A remembered Folders choice
    /// still shows the Browser in a flat folder.
    var isArchiveFoldersVisible: Bool {
        isLeadingPaneVisible && archiveLeadingPane == .folders && hasArchiveFolders
    }
    var isArchiveBrowserVisible: Bool {
        isLeadingPaneVisible && viewMode == .gallery && !(archiveLeadingPane == .folders && hasArchiveFolders)
    }

    /// Q: hides the Browser when it is showing; otherwise shows it, replacing
    /// Folders in one step.
    func toggleArchiveBrowser() {
        if isArchiveBrowserVisible { showBrowser = false } else { showLeadingPane(.browser) }
    }

    /// Hides Folders when they are showing; otherwise shows them in either view.
    func toggleArchiveFolders() {
        guard hasArchiveFolders else { return }
        if isArchiveFoldersVisible {
            showBrowser = false
        } else {
            showLeadingPane(.folders)
        }
    }

    /// Built on first use by the visible tree, then kept current per decision.
    var archiveFolderProgress: ArchiveFolderProgress? {
        guard let index = archiveFolderIndex, hasArchiveFolders, index.indexedItemCount == items.count else { return nil }
        if let progress = archiveFolderProgressStorage, progress.generation == index.generation,
           progress.itemCount == items.count { return progress }
        let progress = ArchiveFolderProgress(index: index) { Self.isReviewed(self.items[$0]) }
        archiveFolderProgressStorage = progress
        return progress
    }

    func updateArchiveFolderProgress(itemIndices: Set<Int>) {
        guard let index = archiveFolderIndex, let progress = archiveFolderProgressStorage,
              progress.generation == index.generation, progress.itemCount == items.count else {
            archiveFolderProgressStorage = nil
            archiveFolderProgressRevision &+= 1
            return
        }
        var changed = false
        for item in itemIndices where items.indices.contains(item) {
            if progress.set(item: item, reviewed: Self.isReviewed(items[item]), index: index) { changed = true }
        }
        if changed { archiveFolderProgressRevision &+= 1 }
    }

    /// Matches the status bar: Yes or No is reviewed; Mixed pairs are not.
    static func isReviewed(_ item: PhotoItem) -> Bool {
        let state = item.ratingState
        return state == .yes || state == .no
    }

    var canExpandAllArchiveFolders: Bool { archiveExpansionSummary.canExpand }
    var canCollapseAllArchiveFolders: Bool { archiveExpansionSummary.canCollapse }

    /// Cached per expansion/selection/index change, so the pane header does
    /// not walk thousands of folders on every rating or thumbnail update.
    var archiveExpansionSummary: ArchiveExpansionSummary {
        if let cached = archiveExpansionSummaryCache { return cached }
        let summary = ArchiveExpansionSummary(index: archiveFolderIndex,
            expanded: archiveExpandedFolderIDs, selectedFolderID: archiveSelectedFolderID)
        archiveExpansionSummaryCache = summary
        return summary
    }

    func expandAllArchiveFolders() {
        guard let index = archiveFolderIndex, hasArchiveFolders else { return }
        let all = Set(index.expandableFolderIDs).union([""])
        guard all != archiveExpandedFolderIDs else { return }
        archiveExpandedFolderIDs = all
        scheduleArchiveNavigationSave()
    }

    /// Collapses every folder except the path to the current folder, so a
    /// view-only command never changes which items are being reviewed.
    func collapseAllArchiveFolders() {
        guard hasArchiveFolders else { return }
        let path = Set(archiveBreadcrumbs.dropLast().map(\.id)).union([""])
        guard path != archiveExpandedFolderIDs else { return }
        archiveExpandedFolderIDs = path
        scheduleArchiveNavigationSave()
    }
    var archiveActionIndices: [Int] { archiveScopeIndices ?? Array(items.indices) }
    var archiveScopeCount: Int { archiveScopeIndices?.count ?? items.count }
    var archiveYesCount: Int { archiveScopeIndices == nil ? yesCount : archiveScopeReviewCounts.yes }
    var archiveNoCount: Int { archiveScopeIndices == nil ? noCount : archiveScopeReviewCounts.no }
    var archiveMixedCount: Int { archiveScopeIndices == nil ? mixedCount : archiveScopeReviewCounts.mixed }
    var archiveRatedCount: Int { archiveYesCount + archiveNoCount + archiveMixedCount }
    var archiveReviewedCount: Int { archiveYesCount + archiveNoCount }

    /// Only the active scope keeps decision snapshots. Normal rating updates
    /// touch their indexed items; toolbar enablement never walks an archive.
    func rebuildArchiveReviewCounts() {
        archiveScopeReviewStates.removeAll(keepingCapacity: true)
        archiveScopeReviewCounts = (0, 0, 0)
        guard let scope = archiveScopeIndices else { return }
        for index in scope { updateArchiveReviewCount(at: index) }
    }

    func updateArchiveReviewCount(at index: Int) {
        guard items.indices.contains(index) else { return }
        let new = items[index].ratingState
        let old = archiveScopeReviewStates.updateValue(new, forKey: index)
        guard old != new else { return }
        if old == .yes { archiveScopeReviewCounts.yes -= 1 }
        if old == .no { archiveScopeReviewCounts.no -= 1 }
        if old == .mixed { archiveScopeReviewCounts.mixed -= 1 }
        if new == .yes { archiveScopeReviewCounts.yes += 1 }
        if new == .no { archiveScopeReviewCounts.no += 1 }
        if new == .mixed { archiveScopeReviewCounts.mixed += 1 }
    }
    var archiveAllScopeLabel: String {
        guard let index = archiveFolderIndex, index.nodes.count > 1 else { return L10n.text("All Media") }
        return archiveSelectedFolderID.isEmpty && archiveIncludesDescendants
            ? L10n.text("Entire Archive") : L10n.text("Current Folder")
    }
    var archiveBreadcrumbs: [ArchiveFolderIndex.Node] {
        archiveFolderIndex?.breadcrumbs(to: archiveSelectedFolderID) ?? []
    }
    var archiveScopeDescription: String? {
        guard hasArchiveFolders, !archiveSelectedFolderID.isEmpty || !archiveIncludesDescendants else { return nil }
        let path = archiveSelectedFolderID.removingPercentEncoding ?? archiveSelectedFolderID
        let name = path.isEmpty ? archiveFolderIndex?.root.lastPathComponent ?? "" : path
        return archiveIncludesDescendants
            ? L10n.text("Folder: \(name), including subfolders")
            : L10n.text("Folder: \(name), direct items only")
    }

    func refreshArchiveScope() {
        defer { rebuildArchiveReviewCounts() }
        guard let index = archiveFolderIndex else { archiveScopeIndices = nil; return }
        archiveScopeIndices = archiveSelectedFolderID.isEmpty && archiveIncludesDescendants ? nil
            : index.itemIndices(in: archiveSelectedFolderID, includingDescendants: archiveIncludesDescendants)
    }

    func selectArchiveFolder(_ id: String) {
        guard case .ready = phase, let index = archiveFolderIndex, index.node(for: id) != nil,
              id != archiveSelectedFolderID, !isFileOperationRunning, !isSessionTransitioning,
              !isPreparingForTermination, !isSessionCommandPresentationActive else { return }
        captureArchivePosition()
        let previousItemID = currentItem?.id
        archiveIsRestoringPosition = true
        archiveSelectedFolderID = id
        if id.isEmpty { archiveIncludesDescendants = true }
        archiveViewportGeneration = UUID()
        clearArchiveViewportReceipts()
        refreshArchiveScope()
        flushPendingFilter()
        applyFilter()
        settleArchiveCurrentItem(previousItemID: previousItemID, restored: restoreArchivePosition())
        archiveIsRestoringPosition = false
        captureArchivePosition()
        scheduleArchiveNavigationSave()
        ForegroundWorkCoordinator.shared.noteInteraction()
    }

    func setArchiveIncludesDescendants(_ included: Bool) {
        guard !archiveSelectedFolderID.isEmpty, included != archiveIncludesDescendants, case .ready = phase,
              !isFileOperationRunning, !isSessionTransitioning, !isPreparingForTermination,
              !isSessionCommandPresentationActive else { return }
        captureArchivePosition()
        let previousItemID = currentItem?.id
        archiveIsRestoringPosition = true
        archiveIncludesDescendants = included
        archiveViewportGeneration = UUID()
        clearArchiveViewportReceipts()
        refreshArchiveScope()
        flushPendingFilter()
        applyFilter()
        settleArchiveCurrentItem(previousItemID: previousItemID, restored: restoreArchivePosition())
        archiveIsRestoringPosition = false
        captureArchivePosition()
        scheduleArchiveNavigationSave()
    }

    /// The open tree keeps every expansion; only persisted memory is bounded
    /// (shallowest first). Truncating here would collapse visible rows.
    func setArchiveExpandedFolders(_ ids: Set<String>) {
        guard let index = archiveFolderIndex else { return }
        let valid = ids.filter { $0.isEmpty || index.node(for: $0)?.children.isEmpty == false }
        guard valid != archiveExpandedFolderIDs else { return }
        archiveExpandedFolderIDs = valid
        scheduleArchiveNavigationSave()
    }

    func replaceArchiveFolderIndex(_ index: ArchiveFolderIndex) {
        let memory = currentArchiveMemory()?.reconciled(with: index)
        // Reprojection keeps the scanned directories, so live expansions
        // beyond the persisted bound remain valid for this open tree.
        let retained = archiveExpandedFolderIDs.filter { index.node(for: $0)?.children.isEmpty == false }
        archiveFolderIndex = index
        archiveNavigationMemory = memory
        archiveSelectedFolderID = memory?.selectedFolderID ?? ""
        archiveExpandedFolderIDs = (memory?.expandedFolderIDs ?? [""]).union(retained)
        archiveViewportGeneration = UUID()
        clearArchiveViewportReceipts()
        refreshArchiveScope()
    }

    func captureArchivePosition() {
        guard case .ready = phase, !archiveIsRestoringPosition, let index = archiveFolderIndex else { return }
        var memory = currentArchiveMemory() ?? ArchiveNavigationMemory(index: index)
        if let item = currentItem, let identity = item.primaryFile.scannedIdentity {
            memory = memory.remembering(PinnedFolderPosition(
                current: .init(physicalFileID: item.primaryFile.id, identity: identity),
                browser: archiveRecordedViewport(for: .browser), grid: archiveRecordedViewport(for: .grid)),
                for: archiveSelectedFolderID, in: index)
        }
        archiveNavigationMemory = memory
    }

    func currentArchiveMemory() -> ArchiveNavigationMemory? {
        guard let index = archiveFolderIndex else { return nil }
        return ArchiveNavigationMemory(index: index, selectedFolderID: archiveSelectedFolderID,
            includesDescendants: archiveIncludesDescendants, expandedFolderIDs: archiveExpandedFolderIDs,
            entries: archiveNavigationMemory?.entries ?? [])
    }

    /// Entering a folder without a usable remembered position keeps a current
    /// item that belongs to it; otherwise it starts at the first undecided
    /// item, as opening a folder does, instead of a filter-snapped edge.
    func settleArchiveCurrentItem(previousItemID: PhotoItem.ID?, restored: Bool) {
        guard !restored, currentItem?.id != previousItemID || previousItemID == nil else { return }
        if let target = visibleIndices.first(where: { items[$0].rating == .undecided }) ?? visibleIndices.first {
            setIndex(target)
        }
    }

    /// Returns true when a remembered current item was restored.
    @discardableResult
    func restoreArchivePosition() -> Bool {
        guard let saved = archiveNavigationMemory?.position(for: archiveSelectedFolderID) else { return false }
        guard let restored = restoredArchivePosition(saved) else { return false }
        archiveIsRestoringPosition = true
        defer { archiveIsRestoringPosition = false }
        var restoredCurrent = false
        if let id = restored.currentPhysicalFileID,
           let index = archiveVisibleIndex(for: id) { setIndex(index); restoredCurrent = true }
        for (surface, receipt) in [(OpeningViewportSurface.browser, restored.browser), (.grid, restored.grid)] {
            guard let receipt else { continue }
            installArchiveViewportReceipt(surface: surface, physicalFileID: receipt.physicalFileID, topOffset: receipt.topOffset)
        }
        return restoredCurrent
    }

    func scheduleArchiveNavigationSave() {
        guard !archiveIsRestoringPosition, archiveFolderIndex != nil else { return }
        archiveNavigationSequence &+= 1
        guard archiveNavigationSaveTask == nil else { return }
        archiveNavigationSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.flushArchiveNavigation()
        }
    }

    func flushArchiveNavigation() async {
        archiveNavigationSaveTask?.cancel()
        archiveNavigationSaveTask = nil
        captureArchivePosition()
        guard let identity = archiveNavigationRootIdentity, let memory = currentArchiveMemory() else { return }
        let previous = archiveNavigationWriteTask
        let writeID = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.archiveNavigationPersistence.save(memory, for: identity)
                if self.archiveNavigationRootIdentity == identity {
                    self.archiveNavigationWarning = nil
                    self.archiveNavigationCanReset = false
                }
            } catch {
                if self.archiveNavigationRootIdentity == identity {
                    self.archiveNavigationWarning = error.localizedDescription
                    self.archiveNavigationCanReset = error as? ArchiveNavigationError == .invalidStorage
                }
            }
        }
        archiveNavigationWriteTask = task
        archiveNavigationWriteID = writeID
        await task.value
        if archiveNavigationWriteID == writeID {
            archiveNavigationWriteTask = nil
            archiveNavigationWriteID = nil
        }
    }

    /// This resets optional browsing memory only. Old bytes are moved intact
    /// beside the state file before new memory can be written.
    func resetArchiveNavigationStorage() async {
        guard archiveNavigationCanReset else { return }
        let identity = archiveNavigationRootIdentity
        archiveNavigationSaveTask?.cancel()
        archiveNavigationSaveTask = nil
        await archiveNavigationWriteTask?.value
        guard archiveNavigationRootIdentity == identity else { return }
        do {
            try await archiveNavigationPersistence.resetPreservingEvidence()
            guard archiveNavigationRootIdentity == identity else { return }
            await flushArchiveNavigation()
        } catch {
            guard archiveNavigationRootIdentity == identity else { return }
            archiveNavigationWarning = error.localizedDescription
        }
    }

    func resetArchiveNavigation() {
        archiveNavigationSaveTask?.cancel()
        archiveNavigationSaveTask = nil
        archiveFolderIndex = nil
        archiveFolderProgressStorage = nil
        archiveScopeIndices = nil
        rebuildArchiveReviewCounts()
        archiveNavigationMemory = nil
        archiveNavigationRootIdentity = nil
        archiveSelectedFolderID = ""
        archiveIncludesDescendants = true
        archiveExpandedFolderIDs = [""]
        archiveNavigationWarning = nil
        archiveNavigationCanReset = false
        archiveViewportGeneration = UUID()
    }
}
