import SwiftUI
import AppKit

/// The active culling session: hosts the Gallery and Grid views, the
/// toolbar, the export sheet, and all single-key hotkeys.
///
/// Hotkey map (README's table must stay in sync with `handleKey`):
///   F yes · D no · 0–5 stars · S 100% zoom · A phone-size zoom
///   R clear all decisions
///   Q browser · W info panel · X preview clipping overlay · E export
///   Space/K video or audio play/pause (photo: Space = next)
///   ←/→ prev/next (Gallery video: seek −/+ 0.5 seconds) · J/L always prev/next
///   ↑/↓ prev/next in the Gallery view · same-column photo in the Grid view
///   Tab/G switch view · Z/⌘Z undo · ⌘+/⌘− grid size
///   ⌘←/→ slower/faster media (photo: prev/next) · ⌘A select all
///   ⌘⇧←/→ select to first/last
///   Esc clear selection
///   ⌘F Filter search · ⌘K Command Palette
///   ⌘⌫ trash selection (no confirmation — ⌘Z restores)
///   (⇧-click range and ⌘-click add/remove live in the thumbnail views)
///
/// While a large folder opens (`store.openingSession != nil`, phase scanning)
/// the same view renders the read-only opening state so the toolbar and panes
/// stay put at Ready. During opening SessionView may only *read*
/// `store.openingSession` and the view preferences (view mode, Browser,
/// Info); toggling Browser/Info and Gallery/Grid are the only writes. Every
/// rating, file, sort, filter and save control stays disabled until final
/// validated publication; `store.items` stays empty meanwhile.
struct SessionView: View {
    @ObservedObject var store: SessionStore
    static let infoPanelWidth: CGFloat = 280
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("louppe.showQuickStart") private var showQuickStart = true
    @AppStorage(ReviewShortcutPreferences.preferenceKey) private var shortcutSettings = ""
    @AppStorage(CommandShortcutPreferences.preferenceKey) private var commandShortcutSettings = ""

    private var shortcuts: ReviewShortcutPreferences {
        ReviewShortcutPreferences.decode(shortcutSettings)
    }

    private var commandShortcuts: CommandShortcutPreferences {
        CommandShortcutPreferences.decode(commandShortcutSettings)
    }

    func toolbarShortcutHint(
        for action: ReviewShortcutAction,
        command: CommandShortcutAction? = nil,
        shortcutPreferences: ReviewShortcutPreferences? = nil,
        commandShortcutPreferences: CommandShortcutPreferences? = nil
    ) -> String {
        let reviewHint = (shortcutPreferences ?? shortcuts).hint(for: action, context: reviewShortcutContext)
        let commandHint = command.map { (commandShortcutPreferences ?? commandShortcuts).hint(for: $0) } ?? ""
        return [reviewHint, commandHint].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private var opening: OpeningSessionState? { store.openingSession }
    var isOpening: Bool { opening != nil }

    /// The opening state owns Gallery/Grid until Ready adopts it.
    private var effectiveViewMode: ViewMode { opening?.viewMode ?? store.viewMode }

    /// The archive folder index is published only at Ready.
    private var hasLeadingPaneFolders: Bool { !isOpening && store.hasArchiveFolders }

    private var isLeadingPaneVisible: Bool {
        guard let opening else { return store.isLeadingPaneVisible }
        return store.showBrowser && opening.viewMode == .gallery
    }

    /// Enablement for toolbar controls. During opening only Folder (cancel),
    /// the view picker, Browser and Info stay live; everything that could
    /// rate, sort, filter, save or touch files is disabled.
    var toolbarAvailability: SessionToolbarAvailability {
        let opening = isOpening
        return SessionToolbarAvailability(
            folder: !store.isFileOperationRunning,
            filter: !opening,
            sort: !opening,
            viewPicker: true,
            undo: !opening && !store.isFileOperationRunning && store.canUndo,
            clearAll: !opening && !store.isFileOperationRunning && store.archiveRatedCount > 0,
            leadingPaneToggle: effectiveViewMode == .gallery || hasLeadingPaneFolders,
            info: true,
            cleanUp: !opening && store.canCleanUp,
            export: !opening && store.canExport
        )
    }

    private var viewModeSelection: Binding<ViewMode> {
        guard let opening else { return $store.viewMode }
        return Binding(get: { opening.viewMode }, set: { opening.viewMode = $0 })
    }

    private var reviewShortcutContext: ReviewShortcutContext {
        if let opening {
            // No playback or seeking starts before Ready.
            return ReviewShortcutContext(viewMode: opening.viewMode,
                                         mediaKind: opening.currentItem?.mediaKind,
                                         isPlayable: false, canSeekVideo: false)
        }
        return ReviewShortcutContext(
            viewMode: store.viewMode,
            mediaKind: store.currentItem?.mediaKind,
            isPlayable: store.currentItem?.isPlayableMedia == true,
            canSeekVideo: store.canSeekCurrentVideo
        )
    }

    var body: some View {
        mainContent
            // Guards Ready itself; the phase change starts it after opening.
            .onAppear { store.startQualityCueAnalysis() }
            .overlay { cleanUpProgressOverlay }
            .toolbar { toolbarContent }
            .navigationTitle("")
            // Menu commands stay unavailable until Ready, as before this
            // view rendered the opening.
            .focusedSceneValue(\.louppeSessionStore, isOpening ? nil : store)
            .background {
                SessionKeyEventMonitor { event, sessionWindow in
                    let context = liveKeyRoutingContext(
                        for: event,
                        sessionWindow: sessionWindow
                    )
                    return handleKey(event, context: context)
                }
            }
            .sheet(isPresented: $store.isSessionRecoveryPresented) {
                SessionRecoveryView(store: store)
            }
            .sheet(isPresented: $store.isExportPresented, onDismiss: {
                #if APP_STORE
                store.appStoreReviewPrompt.exportDidDismiss(store: store)
                #endif
            }) {
                ExportView(store: store)
            }
            .sheet(isPresented: $store.isPhotosOrganizationPresented,
                   onDismiss: { store.dismissPhotosOrganization() }) {
                PhotosOrganizationView(
                    model: store.photosOrganizationModel,
                    onConfirm: { store.confirmPhotosOrganization($0) },
                    onCancelWork: { store.cancelPhotosOrganization() },
                    onDismiss: { store.dismissPhotosOrganization() },
                    onReload: { store.reloadPhotosOrganization() })
            }
            .sheet(isPresented: $store.isOrganizePresented) {
                OrganizeSourceView(store: store)
            }
            .sheet(isPresented: $store.isRenamePresented) {
                RenameFilesView(store: store)
            }
            .sheet(
                isPresented: $store.isActionPalettePresented,
                onDismiss: { store.finishActionPaletteDismissal() }
            ) {
                ActionPaletteView(store: store)
            }
            .alert(L10n.text("Clear All Decisions?"), isPresented: $store.isClearAllRatingsConfirmationPresented) {
                Button(L10n.text("Clear All Decisions"), role: .destructive) {
                    store.clearAllRatings()
                }
                .keyboardShortcut(.defaultAction)
                Button(L10n.text("Cancel"), role: .cancel) {}
            } message: {
                Text(clearAllRatingsMessage)
            }
            .alert(
                legacyMigrationTitle,
                isPresented: legacyMigrationConfirmationPresented
            ) {
                if store.legacySessionMigrationMissingFileCount > 0 {
                    Button(legacyMissingFilesActionTitle, role: .destructive) {
                        store.confirmLegacySessionMigration()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.text("Use Saved Decisions")) {
                        store.confirmLegacySessionMigration()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button(L10n.text("Close Folder"), role: .cancel) {
                    store.closeLegacySessionWithoutMigrating()
                }
            } message: {
                Text(legacyMigrationMessage)
            }
            .confirmationDialog(
                cleanUpTitle,
                isPresented: isCleanUpConfirmPresented,
                titleVisibility: .visible,
                presenting: store.pendingCleanUp
            ) { mode in
                Button(L10n.text("Trash"), role: .destructive) {
                    store.performCleanUp(mode)
                }
                .keyboardShortcut(.defaultAction)
                Button(L10n.text("Cancel"), role: .cancel) {}
            } message: { mode in
                Text(cleanUpMessage(for: mode))
            }
            .environment(\.mediaReadAccess, store.mediaReadAccess)
            .alert("RAW + JPEG", isPresented: isPairingMetadataErrorPresented) {
                Button(L10n.text("Rescan Folder")) {
                    store.pairingMetadataError = nil
                    store.rescan()
                }
                Button(L10n.text("Cancel"), role: .cancel) { store.pairingMetadataError = nil }
            } message: {
                Text(store.pairingMetadataError ?? "")
            }
            .alert(L10n.text("Clean Up"), isPresented: isCleanUpErrorPresented) {
                if !store.cleanUpStalePhotos.isEmpty {
                    Button(L10n.text("Rescan Folder")) {
                        store.rescanAfterCleanUpStaleScan()
                    }
                }
                Button(L10n.text("OK")) { store.dismissCleanUpError() }
            } message: {
                Text(store.cleanUpError ?? "")
            }
    }

    // MARK: - Clean up confirmation

    private var clearAllRatingsMessage: String {
        let count = store.archiveRatedCount
        return L10n.plural("Clear Yes/No decisions from %lld items. Stars and color labels stay unchanged. Undo with ⌘Z.", count)
    }

    private var isCleanUpConfirmPresented: Binding<Bool> {
        Binding(
            get: { store.pendingCleanUp != nil },
            set: { if !$0 { store.pendingCleanUp = nil } }
        )
    }

    private var legacyMigrationConfirmationPresented: Binding<Bool> {
        Binding(
            get: {
                store.isLegacySessionMigrationConfirmationPresented
            },
            // Only the two explicit alert actions may resolve this gate.
            set: { _ in }
        )
    }

    private var legacyMigrationTitle: String {
        switch store.legacySessionMigrationMissingFileCount {
        case 0:
            return L10n.text("Use Saved Decisions?")
        default:
            return L10n.plural("legacy-missing-files-title", store.legacySessionMigrationMissingFileCount)
        }
    }

    private var legacyMissingFilesActionTitle: String {
        L10n.plural("legacy-forget-missing-items", store.legacySessionMigrationMissingFileCount)
    }

    private var legacyMigrationMessage: String {
        let count = store.legacySessionMigrationMissingFileCount
        guard count > 0 else {
            return L10n.text("These older decisions use filenames only. All saved filenames are present, but original files cannot be verified. Use Saved Decisions upgrades the session and binds decisions to current physical files. Close Folder changes nothing.")
        }
        var message = L10n.plural("Older decisions refer to %lld files missing from this folder. Louppe cannot tell whether they were deleted intentionally or are temporarily unavailable. Open Folder and Forget Missing Items discards only those old saved decisions, keeps present-file decisions, and upgrades the session. Close Folder changes nothing.", count)
        if store.legacySessionMigrationUsesUnownedBackup {
            message += L10n.text(" These decisions came from an older local backup not tied to this folder. Opening binds surviving filenames to the files currently here.")
        }
        return message
    }

    private var isPairingMetadataErrorPresented: Binding<Bool> {
        Binding(
            get: { store.pairingMetadataError != nil },
            set: { if !$0 { store.pairingMetadataError = nil } }
        )
    }

    private var isCleanUpErrorPresented: Binding<Bool> {
        Binding(
            get: { store.cleanUpError != nil },
            set: { if !$0 { store.dismissCleanUpError() } }
        )
    }

    private var cleanUpTitle: String {
        guard let mode = store.pendingCleanUp else { return "" }
        let counts = store.cleanUpCounts(for: mode)
        switch mode {
        case .selection:
            return L10n.plural("Trash %lld items?", counts.photos)
        case .trashNo:
            return L10n.plural("Trash %lld items marked No?", counts.photos)
        case .keepOnlyYes:
            return L10n.plural("Trash %lld items marked No or Undecided?", counts.photos)
        case .pairedJPEGs:
            return L10n.plural("Trash JPEG from %lld RAW + JPEG pairs?", counts.photos)
        case .pairedRAWs:
            return L10n.plural("Trash RAW from %lld RAW + JPEG pairs?", counts.photos)
        }
    }

    private func cleanUpMessage(for mode: CleanUpMode) -> String {
        let counts = store.cleanUpCounts(for: mode)
        let space = ByteCountFormatter.string(fromByteCount: counts.bytes, countStyle: .file)
        if mode == .pairedJPEGs || mode == .pairedRAWs {
            let removed = mode == .pairedJPEGs ? "JPEG" : "RAW"
            let retained = mode == .pairedJPEGs ? "RAW" : "JPEG"
            var parts = [
                L10n.plural("%lld files (about %@) will be moved to the Trash. The matching %@ files will stay in the folder.", counts.files, arguments: [space, retained]),
                L10n.text("Undo with ⌘Z before closing this session, while files remain in Trash. Emptying Trash permanently deletes them and may free that space.")
            ]
            switch store.cleanUpScope {
            case .all:
                break
            case .filtered:
                parts.append(L10n.text("Only paired \(removed) files shown by the current filter are included."))
            case .selected:
                parts.append(L10n.text("Only paired \(removed) files in the current selection are included."))
            }
            if let context = store.archiveScopeDescription { parts.append(context) }
            return parts.joined(separator: "\n")
        }
        var parts = [
            L10n.plural("%lld files will be moved to the Trash (a RAW+JPEG pair counts as two), totaling about %@. Undo with ⌘Z before closing this session, while files remain in Trash. Emptying Trash permanently deletes them and may free that space.", counts.files, arguments: [space])
        ]
        switch mode {
        case .selection:
            parts.append(L10n.text("Only selected items leave the folder."))
        case .trashNo:
            parts.append(L10n.text("Within this scope, Yes and unrated items stay in the folder."))
        case .keepOnlyYes:
            let decisions = store.cleanUpDecisionBreakdown(for: mode)
            parts.insert(L10n.plural("Includes %lld No and %lld Undecided items. Stars and color labels do not protect these items. Mixed RAW + JPEG decisions stay in the folder.", counts: [decisions.no, decisions.undecided]), at: 0)
        case .pairedJPEGs, .pairedRAWs:
            break // These modes return through their dedicated message above.
        }
        // Spell out the rating-based scope so nothing outside it is trashed
        // (or spared) by surprise. A direct selection is already explicit.
        if mode != .selection {
            switch store.cleanUpScope {
            case .all:
                if store.isFilterActive {
                    parts.append(L10n.plural("All %lld folder items are considered, even those hidden by filters.", store.archiveScopeCount))
                }
            case .filtered:
                if store.isFilterActive {
                    let hidden = store.archiveScopeCount - store.visibleIndices.count
                    parts.append(L10n.plural("Only %lld visible items are considered; %lld hidden items stay untouched.", counts: [store.visibleIndices.count, hidden]))
                }
            case .selected:
                let count = store.cleanUpScopeCount(for: .selected)
                parts.append(L10n.plural("Only %lld selected items are considered — every unselected item stays in the folder.", count))
            }
        }
        if let context = store.archiveScopeDescription { parts.append(context) }
        return parts.joined(separator: "\n")
    }

    private var subtitle: String {
        guard !store.items.isEmpty else { return "" }
        let position = store.currentVisiblePosition.map { $0 + 1 } ?? 0
        var text = L10n.text("Item \(L10n.number(position)) of \(L10n.number(store.visibleIndices.count))")
        if store.isFilterActive {
            text += L10n.text(" (of \(L10n.number(store.archiveScopeCount)) total)")
        }
        text += L10n.text("  ·  \(L10n.number(store.archiveReviewedCount))/\(L10n.number(store.archiveScopeCount)) reviewed")
        if store.archiveMixedCount > 0 {
            text += L10n.text("  ·  \(L10n.number(store.archiveMixedCount)) mixed")
        }
        if store.selectedIndices.count > 1 {
            text += L10n.text("  ·  \(L10n.number(store.selectedIndices.count)) selected")
        }
        if store.isGroupedReviewActive {
            text += L10n.text("  ·  grouped review")
        }
        return text
    }

    private var hasReviewStatusDetails: Bool {
        showQuickStart
            || (store.isReviewComplete && !store.isGroupedReviewActive)
    }

    @ViewBuilder
    private var principalStatus: some View {
        if let opening { OpeningSessionStatus(state: opening) } else { statusText }
    }

    private var statusText: some View {
        Group {
            if hasReviewStatusDetails {
                Button { store.isReviewStatusPresented.toggle() } label: {
                    statusLabel
                }
                .buttonStyle(.plain)
                .popover(isPresented: $store.isReviewStatusPresented, arrowEdge: .bottom) {
                    SessionReviewStatus(store: store)
                        .louppePopoverSurface()
                }
                .accessibilityLabel(L10n.text("Review progress and decision totals"))
                .accessibilityValue("\(subtitle), \(store.sessionSaveStatus)")
            } else {
                statusLabel
                    .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: hasReviewStatusDetails) { _, hasDetails in
            if !hasDetails { store.isReviewStatusPresented = false }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(subtitle)
                    .font(.subheadline)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(store.sessionSaveStatus)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            // Background-work spinner. Always present (just invisible when
            // idle) so the status text doesn't shift when it appears.
            SessionActivitySpinner(activity: store.galleryActivity,
                                   isChangingRawJPEGPairingMode: store.isChangingRawJPEGPairingMode,
                                   isAnalyzingDuplicateBursts: store.isDuplicateBurstAnalysisRunning)
            if hasReviewStatusDetails {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var mainContent: some View {
        if let opening {
            OpeningSessionContent(state: opening,
                                  showsBrowser: isLeadingPaneVisible,
                                  showsInfo: store.showMetadataPanel,
                                  gridThumbnailSize: store.gridThumbSize)
        } else {
            readyContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            if store.isGroupedReviewActive {
                groupedReviewBanner
            }
            HStack(spacing: 0) {
                if store.isLeadingPaneVisible {
                    ArchiveLeadingPaneView(store: store)
                    Divider()
                }
                VStack(spacing: 0) {
                    if store.hasArchiveFolders, !store.archiveSelectedFolderID.isEmpty,
                       !(store.isLeadingPaneVisible && store.archiveLeadingPane == .folders) {
                        ArchiveBreadcrumbView(store: store)
                        Divider()
                    }
                    if store.archiveNavigationWarning != nil {
                        ArchiveNavigationWarningView(store: store)
                        Divider()
                    }
                    Group {
                        switch store.viewMode {
                        case .gallery:
                            GalleryView(store: store)
                        case .grid:
                            GridView(store: store,
                                initialViewportReceipt: store.pendingOpeningViewportReceipt(for: .grid).map {
                                    ReviewCollectionViewportReceipt(physicalFileID: $0.physicalFileID, topOffset: CGFloat($0.topOffset))
                                },
                                onViewportRestored: { _ in store.consumeOpeningViewportReceipt(for: .grid) })
                                .id(store.archiveViewportGeneration)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // The Info panel is shared by both modes. Keeping it outside the
                // mode switch preserves its metadata/histogram tasks instead of
                // tearing them down and reopening the RAW on every toggle.
                if store.showMetadataPanel, let item = store.currentItem {
                    Divider()
                    MetadataPanel(store: store, item: item)
                        .frame(width: Self.infoPanelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .overlay {
                if store.isArchiveFoldersVisible { ArchivePaneResizeOverlay(store: store) }
            }
        }
    }

    private var groupedReviewBanner: some View {
        StatusBanner(systemImage: groupedReviewSymbol) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.groupedReviewMode.analysisTitle)
                    .font(.subheadline.weight(.semibold))
                Group {
                    if store.groupedReviewMode == .captureBursts {
                        Text(L10n.plural("%lld groups", store.groupedReviewGroupCount))
                            .help(store.groupedReviewExplanation)
                    } else {
                        Text(
                            L10n.plural("%@ %lld groups are visible. Review only — nothing is changed automatically.", store.groupedReviewGroupCount, arguments: [store.groupedReviewExplanation])
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        } actions: {
            Button(L10n.text("Normal Review")) {
                store.exitGroupedReview()
            }
            .buttonStyle(.bordered)
            .accessibilityHint(L10n.text("Return to the normal filtered and sorted media list"))
        }
    }

    private var groupedReviewSymbol: String {
        switch store.groupedReviewMode {
        case .exactDuplicates: return "doc.on.doc"
        case .likelySimilarPhotos: return "photo.on.rectangle.angled"
        case .captureBursts: return "rectangle.stack"
        case .off: return "rectangle.3.group"
        }
    }

    @ViewBuilder
    private var cleanUpProgressOverlay: some View {
        if let progress = store.cleanUpProgress {
            VStack(spacing: 8) {
                Text(progress.title)
                    .font(.headline)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .accessibilityLabel(progress.title)
                    .accessibilityValue(L10n.plural("%@ of %lld files", progress.total, arguments: [L10n.number(progress.done)]))
                    .frame(width: 280)
                Text(L10n.plural("%@ of %lld files", progress.total, arguments: [L10n.number(progress.done)]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(18)
            .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(radius: 12)
            // The overlay reports progress without blocking scrolling or view
            // inspection. SessionStore separately guards unsafe mutations.
            .allowsHitTesting(false)
        }
    }

    // MARK: - Toolbar

    /// Toolbar order and Liquid Glass groups (2026-07-15):
    /// {folder} {filter · sort · view picker} = status =
    /// {undo · clear all} {browser · info} {clean up} {export}.
    /// On macOS 26, fixed ToolbarSpacers are Apple's native separator between
    /// neighbouring glass groups. Earlier systems keep the same control order.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Current folder: click it to return to the start screen and pick
            // another folder (the session is saved first).
            Button {
                if isOpening { store.cancelScan() } else { store.closeSession() }
            } label: {
                Label(store.photosBatch?.snapshot.title ?? store.sourceFolder?.lastPathComponent ?? L10n.text("Folder"),
                      systemImage: store.photosBatch == nil ? "folder" : "photo.on.rectangle")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
            }
            .disabled(!toolbarAvailability.folder)
            .accessibilityLabel(store.photosBatch?.snapshot.title ?? L10n.text("Current folder: \(store.sourceFolder?.path ?? "none")"))
            .help(isOpening
                ? L10n.text("Cancel scanning and return to the start screen (Esc)")
                : store.photosBatch == nil ? (store.sourceFolder?.path ?? L10n.text("Choose another media folder (⌘O)")) : L10n.text("Close Photos review"))

        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .navigation)
        }

        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.isFilterPresented.toggle()
            } label: {
                ToolbarStateIcon(
                    systemName: store.isFilterActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle",
                    isActive: store.isFilterActive)
            }
            .popover(isPresented: $store.isFilterPresented, arrowEdge: .bottom) {
                FilterView(store: store)
            }
            .accessibilityLabel(L10n.text("Filter Media"))
            .accessibilityValue(store.isFilterActive ? L10n.text("Active") : L10n.text("Not active"))
            .help(L10n.text("Filter media by date, type, duration, subfolder, camera, or lens"))
            .disabled(!toolbarAvailability.filter)

            Button {
                store.isSortPresented.toggle()
            } label: {
                ToolbarStateIcon(systemName: "arrow.up.arrow.down", isActive: store.isSortActive)
            }
            .popover(isPresented: $store.isSortPresented, arrowEdge: .bottom) {
                SortView(store: store)
            }
            .accessibilityLabel(L10n.text("Sort Media"))
            .accessibilityValue(store.isSortActive ? L10n.text("Active") : L10n.text("Not active"))
            .help(L10n.text("Sort media by date, name, type, duration, or metadata"))
            .disabled(!toolbarAvailability.sort)

            Picker(L10n.text("View"), selection: viewModeSelection) {
                Image(systemName: "photo")
                    .accessibilityLabel(L10n.text("Gallery"))
                    .tag(ViewMode.gallery)
                Image(systemName: "square.grid.3x3")
                    .accessibilityLabel(L10n.text("Grid"))
                    .tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .tint(Color.louppeFilledAccent)
            .help(L10n.text("Switch between Gallery and Grid views (\(toolbarShortcutHint(for: .grid)))"))
            .disabled(!toolbarAvailability.viewPicker)
        }

        // Session status stays centered and opts out of a glass capsule.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                principalStatus
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                principalStatus
            }
        }

        ToolbarItemGroup {
            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!toolbarAvailability.undo)
            .accessibilityLabel(L10n.text("Undo"))
            .help(L10n.text("Undo the last decision, stars, color label, or clean-up (\(toolbarShortcutHint(for: .undo, command: .undo)))"))
            Button {
                store.requestClearAllRatings()
            } label: {
                Image(systemName: "eraser")
            }
            .disabled(!toolbarAvailability.clearAll)
            .accessibilityLabel(L10n.text("Clear All Decisions"))
            .help(store.archiveScopeIndices == nil
                ? L10n.text("Clear all Yes/No decisions (\(toolbarShortcutHint(for: .clear)))")
                : L10n.text("Clear Yes/No decisions in this folder (\(toolbarShortcutHint(for: .clear)))"))
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup {
            // Grid exposes the folder tree; Gallery shares the pane with Browser.
            if toolbarAvailability.leadingPaneToggle {
                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        if isOpening { store.toggleOpeningBrowser() } else { store.toggleLeadingPane() }
                    }
                } label: {
                    Image(systemName: isLeadingPaneVisible ? "sidebar.squares.left" : "sidebar.left")
                }
                .accessibilityLabel((hasLeadingPaneFolders && store.archiveLeadingPane == .folders) || effectiveViewMode == .grid
                    ? (isLeadingPaneVisible ? L10n.text("Hide Folders") : L10n.text("Show Folders"))
                    : (store.showBrowser ? L10n.text("Hide Browser") : L10n.text("Show Browser")))
                .help((hasLeadingPaneFolders && store.archiveLeadingPane == .folders) || effectiveViewMode == .grid
                    ? L10n.text("Show or hide Folders (\(toolbarShortcutHint(for: .folders)))")
                    : L10n.text("Show or hide the Browser in the Gallery view (\(toolbarShortcutHint(for: .browser)))"))
            }

            Button {
                withAnimation(reduceMotion ? nil : .default) { store.showMetadataPanel.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel(
                store.showMetadataPanel ? L10n.text("Hide Info") : L10n.text("Show Info")
            )
            .help(L10n.text("Show or hide media information (\(toolbarShortcutHint(for: .info)))"))
            .disabled(!toolbarAvailability.info)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        cleanUpAndExportToolbarContent
    }

    /// Kept as a nested builder so the parent toolbar stays below Swift 5.9's
    /// result-builder arity limit while these remain two distinct capsules.
    @ToolbarContentBuilder
    private var cleanUpAndExportToolbarContent: some ToolbarContent {
        // Clean Up sits in its own capsule between inspection controls and
        // Export. The menu body is shared with the File menu. Clean Up is the
        // app's only Trash path; Export's explicit Move mode can instead move
        // originals to a photographer-chosen destination.
        ToolbarItem {
            Menu {
                CleanUpMenuItems(store: store)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(!toolbarAvailability.cleanUp)
            .menuIndicator(.hidden)
            .tint(Color.primary)
            .accessibilityLabel(L10n.text("Clean Up"))
            .help(L10n.text("Choose items to trash"))
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        // Export: its own prominent purple button. Use a bare Image (not a
        // Label with hidden text) so the icon centers in the circle instead
        // of being nudged aside by reserved label space.
        ToolbarItem {
            Button {
                store.presentExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    // Nudge up a touch to visually center the share glyph.
                    .offset(y: -1)
            }
            .disabled(!toolbarAvailability.export)
            .buttonStyle(.borderedProminent)
            .tint(Color.louppeFilledAccent)
            .buttonBorderShape(.circle)
            .tint(Color.louppeAccent)
            .accessibilityLabel(L10n.text("Export"))
            .help(store.photosBatch == nil
                  ? L10n.text("Copy or move selected media, or write Metadata (XMP) sidecars (\(toolbarShortcutHint(for: .export, command: .export)))")
                  : L10n.text("Copy selected Photos originals to another folder (\(toolbarShortcutHint(for: .export, command: .export)))"))
        }
    }

    // MARK: - Keyboard shortcuts

    /// Internal compatibility entry point for focused logic tests that use
    /// synthetic events without an AppKit window. The installed event monitor
    /// always calls the context-aware overload below.
    func handleKey(_ event: NSEvent) -> Bool {
        handleKey(event, context: .focusedSession)
    }

    /// Routes one event only after its window, presentation, and focus context
    /// has proved that the active session owns keyboard input.
    func handleKey(
        _ event: NSEvent,
        context: SessionKeyRoutingContext,
        shortcutPreferences: ReviewShortcutPreferences? = nil,
        commandShortcutPreferences: CommandShortcutPreferences? = nil
    ) -> Bool {
        guard context.sessionOwnsEvent,
              !context.hasModalPresentation,
              !store.isSessionCommandPresentationActive
        else {
            return false
        }
        let openingState: OpeningSessionState?
        switch store.phase {
        case .ready: openingState = nil
        case .scanning:
            guard let opening else { return false }
            openingState = opening
        case .welcome: return false
        }

        // With macOS Keyboard Navigation enabled, the first Tab must enter
        // the native key-view loop even before a control owns focus.
        if event.keyCode == 48, context.isKeyboardNavigationEnabled { return false }

        var modifiers = normalizedShortcutModifiers(for: event)
        // Caps Lock is harmless capitalization during ordinary culling, but
        // it can also be VoiceOver's command modifier. When VoiceOver is
        // running, preserve that ownership instead of interpreting the chord.
        if !context.isVoiceOverEnabled {
            modifiers.remove(.capsLock)
        }
        let unsupportedReviewModifiers: NSEvent.ModifierFlags = [
            .command,
            .option,
            .control,
            .function,
            .help,
            .numericPad,
            .capsLock,
        ]
        let acceptsReviewModifiers = modifiers
            .intersection(unsupportedReviewModifiers)
            .isEmpty
        // Shift is accepted for letter shortcuts so an uppercase F/D/G still
        // works, but Shift-Tab and Shift-arrow belong to native focus and
        // selection navigation rather than changing the photo session.
        let acceptsNavigationModifiers =
            acceptsReviewModifiers && !modifiers.contains(.shift)

        let shortcut = (shortcutPreferences ?? shortcuts).match(
            for: event, context: reviewShortcutContext
        )

        if let openingState {
            return handleOpeningKey(
                event, opening: openingState, context: context, shortcut: shortcut,
                acceptsReviewModifiers: acceptsReviewModifiers,
                acceptsNavigationModifiers: acceptsNavigationModifiers
            )
        }

        if store.isFileOperationRunning {
            // Only unmodified, explicitly safe view controls stay live. Every
            // other key passes through to AppKit, including VoiceOver chords
            // and unsupported Command combinations.
            guard context.acceptsReviewShortcuts else { return false }
            guard acceptsReviewModifiers else { return false }
            guard let shortcut, shortcut.action.isSafeDuringFileOperation else { return false }
            if shortcut.requiresNavigationFocus {
                guard context.acceptsNavigationShortcuts,
                      acceptsNavigationModifiers else { return false }
            }
            return performReviewShortcut(shortcut.action)
        }

        // App commands remain available when a Button, Picker, or Slider has
        // keyboard focus. A live text editor keeps every standard macOS
        // command instead (notably Undo, Select All, and Use Selection for
        // Find).
        let acceptsAppCommand = context.acceptsReviewShortcuts

        // Editable Command aliases share the session's ownership and operation
        // gates. Do not leave E/K/R fallbacks active after users remove them.
        if acceptsAppCommand,
           modifiers == [.command] || modifiers == [.command, .shift],
           let action = (commandShortcutPreferences ?? commandShortcuts).match(for: event, context: reviewShortcutContext),
           action.isEditable {
            switch action {
            case .export:
                guard store.canExport else { return false }
                store.presentExport()
                return true
            case .commandPalette:
                store.presentActionPalette()
                return store.isActionPalettePresented
            case .enclosingFolder:
                return store.selectEnclosingArchiveFolder()
            case .rescan:
                store.rescan()
                return true
            default: break
            }
        }

        // ⌘+ / ⌘− resize the Grid view.
        if acceptsAppCommand,
           modifiers == [.command],
           store.viewMode == .grid {
            switch event.charactersIgnoringModifiers {
            case "=", "+": store.zoomGrid(larger: true); return true
            case "-": store.zoomGrid(larger: false); return true
            default: break
            }
        }
        if acceptsAppCommand,
           modifiers == [.command, .shift],
           store.viewMode == .grid,
           event.characters == "+" {
            store.zoomGrid(larger: true)
            return true
        }

        // These menu-equivalent actions stay here rather than on global menu
        // key equivalents so another window or a focused editor owns its keys.
        if acceptsAppCommand, modifiers == [.command] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f":
                store.presentFilterSearch()
                return true
            default:
                break
            }
        }

        // ⌘Z — undo the last review-metadata action (or clean-up).
        if acceptsAppCommand,
           modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            store.undo()
            return true
        }

        // ⌘⌫ — move the selected photo(s) straight to the Trash, no dialog
        // (deliberate Finder parallel; ⌘Z brings everything back).
        if context.acceptsReviewShortcuts,
           modifiers == [.command],
           event.keyCode == 51 {
            guard store.canCleanUp,
                  store.hasCleanUpTargets(for: .selection) else {
                return false
            }
            store.performCleanUp(.selection)
            return true
        }

        // ⌘⇧← / ⌘⇧→ — select everything up to the first / last photo.
        if context.acceptsNavigationShortcuts,
           modifiers == [.command, .shift] {
            switch event.keyCode {
            case 123: store.selectToEdge(forward: false); return true   // ⌘⇧←
            case 124: store.selectToEdge(forward: true); return true    // ⌘⇧→
            default: break
            }
        }

        // ⌘← / ⌘→ — slower/faster playback for playable media. On a photo,
        // retain the adjacent-item shortcut. Native AVKit controls keep the
        // same chord when they own directional focus; the playback controller
        // observes their resulting rate so Info stays synchronized.
        if context.acceptsNavigationShortcuts,
           modifiers == [.command] {
            switch event.keyCode {
            case 123:
                if !store.adjustCurrentPlayableMediaPlaybackRate(
                    forward: false
                ) { store.goPrevious() }
                return true                                              // ⌘←
            case 124:
                if !store.adjustCurrentPlayableMediaPlaybackRate(
                    forward: true
                ) { store.goNext() }
                return true                                              // ⌘→
            default: break
            }
        }

        // ⇧← / ⇧→ — make a larger inspection jump without stealing Shift-
        // arrow range navigation from still media, Grid, or native controls.
        if context.acceptsNavigationShortcuts,
           modifiers == [.shift],
           store.canSeekCurrentVideo {
            switch event.keyCode {
            case 123: store.seekCurrentVideo(by: -5); return true       // ⇧←
            case 124: store.seekCurrentVideo(by: 5); return true        // ⇧→
            default: break
            }
        }

        // ⌘A — select all photos that pass the filter.
        if acceptsAppCommand,
           modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            store.selectAllVisible()
            return true
        }

        guard context.acceptsReviewShortcuts else { return false }

        if event.keyCode == 53 {                              // Esc: drop the selection
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            guard !store.selectedIndices.isEmpty else { return false }
            store.clearSelection()
            return true
        }

        // All configurable aliases share one context-aware authority. Native
        // controls retain directional/Space/Tab input; review letters still
        // work after an ordinary control has focus.
        guard acceptsReviewModifiers, let shortcut else { return false }
        if shortcut.requiresNavigationFocus {
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
        }
        return performReviewShortcut(shortcut.action)
    }

    /// While a folder opens, only read-only navigation, the view switch,
    /// Browser, Info and Esc route. Ratings, stars, Clear, Undo, Export,
    /// Command shortcuts and ⌘⌫ pass through untouched until Ready.
    private func handleOpeningKey(
        _ event: NSEvent,
        opening: OpeningSessionState,
        context: SessionKeyRoutingContext,
        shortcut: ReviewShortcutMatch?,
        acceptsReviewModifiers: Bool,
        acceptsNavigationModifiers: Bool
    ) -> Bool {
        guard context.acceptsReviewShortcuts, acceptsReviewModifiers else { return false }
        if event.keyCode == 53 {                              // Esc: selection, then Cancel
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            if !opening.clearSelection() { store.cancelScan() }
            return true
        }
        guard let shortcut else { return false }
        if shortcut.requiresNavigationFocus {
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
        }
        switch shortcut.action {
        case .previous: opening.moveCurrent(by: -1)
        case .next: opening.moveCurrent(by: 1)
        case .previousRow: opening.moveVertically(by: -1)
        case .nextRow: opening.moveVertically(by: 1)
        case .grid: opening.toggleViewMode()
        case .browser:
            withAnimation(reduceMotion ? nil : .default) { store.toggleOpeningBrowser() }
        case .info:
            withAnimation(reduceMotion ? nil : .default) { store.showMetadataPanel.toggle() }
        default: return false
        }
        return true
    }

    private func performReviewShortcut(_ shortcut: ReviewShortcutAction) -> Bool {
        switch shortcut {
        case .yes: store.rate(.yes); return true
        case .no: store.rate(.no); return true
        case .previous: store.goPrevious(); return true
        case .next: store.goNext(); return true
        case .previousRow: store.goVertical(-1); return true
        case .nextRow: store.goVertical(1); return true
        case .seekBackward: store.seekCurrentVideo(by: -0.5); return true
        case .seekForward: store.seekCurrentVideo(by: 0.5); return true
        case .playPause: return store.toggleCurrentPlayableMedia()
        case .browser:
            withAnimation(reduceMotion ? nil : .default) { store.toggleArchiveBrowser() }
            return true
        case .folders:
            guard store.hasArchiveFolders else { return false }
            withAnimation(reduceMotion ? nil : .default) { store.toggleArchiveFolders() }
            return true
        case .previousFolder: return store.selectPreviousArchiveFolder()
        case .nextFolder: return store.selectNextArchiveFolder()
        case .info: withAnimation(reduceMotion ? nil : .default) { store.showMetadataPanel.toggle() }; return true
        case .clipping: return store.toggleClippingWarnings()
        case .grid: store.toggleViewMode(); return true
        case .export:
            guard store.canExport else { return false }
            store.presentExport()
            return true
        case .clear: store.requestClearAllRatings(); return true
        case .undo: store.undo(); return true
        case .actualSize:
            guard store.viewMode == .gallery else { return false }
            store.toggleZoom(.actual)
            return true
        case .phoneSize:
            guard store.viewMode == .gallery else { return false }
            store.toggleZoom(.small)
            return true
        case .clearStars: store.setStarRating(nil); return true
        case .oneStar: store.setStarRating(.one); return true
        case .twoStars: store.setStarRating(.two); return true
        case .threeStars: store.setStarRating(.three); return true
        case .fourStars: store.setStarRating(.four); return true
        case .fiveStars: store.setStarRating(.five); return true
        }
    }

    private func normalizedShortcutModifiers(
        for event: NSEvent
    ) -> NSEvent.ModifierFlags {
        // Compare only documented, device-independent modifier meanings. Raw
        // event flags can contain unrelated bits, while AppKit marks ordinary
        // arrow-key events as both Numeric Pad and Function.
        let meaningfulMask: NSEvent.ModifierFlags = [
            .capsLock,
            .shift,
            .control,
            .option,
            .command,
            .numericPad,
            .help,
            .function,
        ]
        var modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(meaningfulMask)
        if 123...126 ~= event.keyCode {
            modifiers.subtract([.numericPad, .function])
        }
        return modifiers
    }

    private func liveKeyRoutingContext(
        for event: NSEvent,
        sessionWindow: NSWindow
    ) -> SessionKeyRoutingContext {
#if LOUPPE_TEST_SEAMS
        let keyWindow =
            SessionKeyMonitorTestProbe.keyWindowOverride ?? NSApp.keyWindow
#else
        let keyWindow = NSApp.keyWindow
#endif
        return SessionKeyRoutingContext(
            eventWindow: event.window,
            eventWindowNumber: event.windowNumber,
            sessionWindow: sessionWindow,
            keyWindow: keyWindow,
            modalWindow: NSApp.modalWindow,
            applicationIsActive: NSApp.isActive
        )
    }

}

/// Which toolbar controls accept input. Pure so tests can check the opening
/// contract without a live NSToolbar.
struct SessionToolbarAvailability: Equatable {
    let folder: Bool
    let filter: Bool
    let sort: Bool
    let viewPicker: Bool
    let undo: Bool
    let clearAll: Bool
    /// Visibility, not enablement: Grid shows it only with a folder tree.
    let leadingPaneToggle: Bool
    let info: Bool
    let cleanUp: Bool
    let export: Bool
}

/// Inputs that must be true before a session-wide keyboard shortcut is even
/// interpreted. Keeping this value pure makes the dangerous boundary directly
/// regression-testable without synthesizing system-wide accessibility events.
struct SessionKeyRoutingContext: Equatable {
    let sessionOwnsEvent: Bool
    let hasModalPresentation: Bool
    let focusedResponderOwnsText: Bool
    let focusedResponderOwnsNavigation: Bool
    let isVoiceOverEnabled: Bool
    let isKeyboardNavigationEnabled: Bool

    init(
        sessionOwnsEvent: Bool,
        hasModalPresentation: Bool,
        focusedResponderOwnsText: Bool = false,
        focusedResponderOwnsNavigation: Bool = false,
        isVoiceOverEnabled: Bool = false,
        isKeyboardNavigationEnabled: Bool = false
    ) {
        self.sessionOwnsEvent = sessionOwnsEvent
        self.hasModalPresentation = hasModalPresentation
        self.focusedResponderOwnsText = focusedResponderOwnsText
        self.focusedResponderOwnsNavigation =
            focusedResponderOwnsNavigation
        self.isVoiceOverEnabled = isVoiceOverEnabled
        self.isKeyboardNavigationEnabled = isKeyboardNavigationEnabled
    }

    var acceptsReviewShortcuts: Bool {
        sessionOwnsEvent
            && !hasModalPresentation
            && !focusedResponderOwnsText
    }

    var acceptsNavigationShortcuts: Bool {
        acceptsReviewShortcuts && !focusedResponderOwnsNavigation
    }

    static let focusedSession = SessionKeyRoutingContext(
        sessionOwnsEvent: true,
        hasModalPresentation: false,
        focusedResponderOwnsText: false,
        focusedResponderOwnsNavigation: false,
        isVoiceOverEnabled: false
    )

    static let blocked = SessionKeyRoutingContext(
        sessionOwnsEvent: false,
        hasModalPresentation: false,
        focusedResponderOwnsText: false,
        focusedResponderOwnsNavigation: false,
        isVoiceOverEnabled: false
    )

    @MainActor
    init(
        eventWindow: NSWindow?,
        eventWindowNumber: Int,
        sessionWindow: NSWindow?,
        keyWindow: NSWindow?,
        modalWindow: NSWindow?,
        applicationIsActive: Bool = true
    ) {
        guard let sessionWindow else {
            self = .blocked
            return
        }

        let eventCarriesExactSessionWindow = eventWindow === sessionWindow
        let eventCarriesSessionWindowNumber =
            eventWindow == nil
                && eventWindowNumber != 0
                && eventWindowNumber == sessionWindow.windowNumber
        let eventBelongsToSession =
            eventCarriesExactSessionWindow
                || eventCarriesSessionWindowNumber
        // AppKit can briefly clear NSApp.keyWindow while the same live window
        // is becoming key again after activation or a SwiftUI presentation or
        // rescan transition. It can also omit NSEvent.window while retaining
        // the event's exact, nonzero window number. A local monitor receives
        // only this active app's events, so accept either exact session
        // identity during that nil gap. Never accept the gap while Louppe is
        // inactive or while another window is actually key.
        let sessionIsConfirmedKeyWindow =
            keyWindow === sessionWindow
                || (
                    keyWindow == nil
                        && applicationIsActive
                        && eventBelongsToSession
                )
        let firstResponder = sessionWindow.firstResponder
        // SwiftUI makes its whole window-hosting content view first responder
        // after activation and some presentation transitions. That root may
        // contain selectable metadata many levels below it, but none of that
        // text is focused. Descendant inspection is only appropriate for an
        // actual SwiftUI focus proxy, never for the window's entire root.
        let focusedResponder: NSResponder? =
            (firstResponder as? NSView) === sessionWindow.contentView
                ? nil
                : firstResponder
        self.init(
            sessionOwnsEvent:
                eventBelongsToSession && sessionIsConfirmedKeyWindow,
            hasModalPresentation:
                modalWindow != nil || sessionWindow.attachedSheet != nil,
            focusedResponderOwnsText:
                Self.responderOwnsText(focusedResponder),
            focusedResponderOwnsNavigation:
                Self.responderOwnsNavigation(focusedResponder),
            isVoiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled,
            isKeyboardNavigationEnabled: NSApp.isFullKeyboardAccessEnabled
        )
    }

    @MainActor
    static func responderOwnsText(
        _ responder: NSResponder?
    ) -> Bool {
        if responder is NSTextView { return true }
        if let control = responder as? NSControl {
            if control.currentEditor() != nil { return true }
            if let field = control as? NSTextField {
                return field.isEditable || field.isSelectable
            }
        }
        guard let view = responder as? NSView else { return false }
        return viewContainsTextOwner(view)
    }

    @MainActor
    static func responderOwnsNavigation(
        _ responder: NSResponder?
    ) -> Bool {
        guard let responder else { return false }
        return !(responder is NSWindow)
    }

    /// SwiftUI selectable `Text` keeps a private hosting proxy first
    /// responder while its public `NSTextField` selection surface is nested
    /// below it. Inspecting public descendant types avoids depending on that
    /// private proxy's class name while preserving native Copy/Select All,
    /// Find-selection, Undo, and deletion commands.
    @MainActor
    private static func viewContainsTextOwner(_ view: NSView) -> Bool {
        if let textView = view as? NSTextView,
           textView.isEditable || textView.isSelectable {
            return true
        }
        if let textField = view as? NSTextField,
           textField.isEditable || textField.isSelectable {
            return true
        }
        return view.subviews.contains(where: viewContainsTextOwner)
    }
}

#if LOUPPE_TEST_SEAMS
/// Debug-only lifecycle accounting for the in-process event-monitor regression
/// test. Release builds carry no counter or synchronization work.
@MainActor
enum SessionKeyMonitorTestProbe {
    private(set) static var activeMonitorCount = 0
    private(set) static var keyWindowOverride: NSWindow?

    static func didInstall() {
        activeMonitorCount += 1
    }

    static func didRemove() {
        precondition(activeMonitorCount > 0)
        activeMonitorCount -= 1
    }

    static func overrideKeyWindow(with window: NSWindow?) {
        keyWindowOverride = window
    }
}
#endif

/// An inert AppKit marker that lets hosted-view tests distinguish Gallery,
/// Grid, and the shared Info panel without relying on implementation details
/// such as how many ScrollViews SwiftUI happens to create. It is excluded from
/// accessibility and pointer hit testing; the identifier is available to UI
/// diagnostics without changing the rendered app.
struct SessionRenderMarker: NSViewRepresentable {
    enum Kind: String {
        case gallery = "com.alexandermarkin.louppe.render.gallery"
        case grid = "com.alexandermarkin.louppe.render.grid"
        case metadata = "com.alexandermarkin.louppe.render.metadata"
    }

    let kind: Kind

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(kind: kind)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.kind = kind
    }

    final class MarkerView: NSView {
        var kind: Kind {
            didSet { setAccessibilityIdentifier(kind.rawValue) }
        }

        init(kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
            setAccessibilityElement(false)
            setAccessibilityIdentifier(kind.rawValue)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Owns the local keyboard monitor for exactly as long as SessionView's AppKit
/// bridge is attached to a window. Keeping the token here avoids SwiftUI
/// appearance callbacks and `@State` being replaced independently, which can
/// otherwise leave a visible session with an orphaned or missing monitor.
private struct SessionKeyEventMonitor: NSViewRepresentable {
    let route: (NSEvent, NSWindow) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.route = route
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.route = route
        nsView.installIfNeeded()
    }

    static func dismantleNSView(
        _ nsView: MonitorView,
        coordinator: Void
    ) {
        nsView.removeMonitor()
    }

    /// The two removal paths below are exhaustive, so this deliberately has no
    /// `deinit` safety net: a monitor is only ever installed while the view is
    /// in a window, a windowed view is retained by that window, and leaving
    /// the window always runs `viewDidMoveToWindow` with a nil window before
    /// the view can be released. (A nonisolated `deinit` also cannot read the
    /// non-Sendable monitor token without an unchecked-Sendable box, which
    /// would assert a guarantee for an unreachable case.)
    final class MonitorView: NSView {
        var route: (NSEvent, NSWindow) -> Bool = { _, _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard window != nil, monitor == nil else { return }
            guard let monitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown,
                handler: { [weak self] event in
                    guard let self, let window = self.window else {
                        return event
                    }
                    return self.route(event, window) ? nil : event
                }
            ) else { return }
            self.monitor = monitor
#if LOUPPE_TEST_SEAMS
            SessionKeyMonitorTestProbe.didInstall()
#endif
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
#if LOUPPE_TEST_SEAMS
            SessionKeyMonitorTestProbe.didRemove()
#endif
        }

    }
}

/// Gallery decodes change the spinner several times per step; observing them
/// here keeps those changes from redrawing the session window.
private struct SessionActivitySpinner: View {
    @ObservedObject var activity: GalleryActivity
    let isChangingRawJPEGPairingMode: Bool
    let isAnalyzingDuplicateBursts: Bool

    var body: some View {
        SessionActivityIndicator(isActive:
                activity.fullImageLoads > 0
                    || isChangingRawJPEGPairingMode
                    || isAnalyzingDuplicateBursts,
            label:
                isAnalyzingDuplicateBursts
                    ? L10n.text("Analyzing duplicate and burst groups locally")
                    : isChangingRawJPEGPairingMode
                    ? L10n.text("Preparing separate JPEG metadata")
                    : L10n.text("Loading photo preview")
            )
    }
}

/// The Clean Up menu body — the trash actions plus the inline scope —
/// shared by the toolbar menu and the File menu so the two never drift.
struct CleanUpMenuItems: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Button(store.selectionCleanUpTitle) {
            store.requestCleanUp(.selection)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .selection))
        Divider()
        Picker(L10n.text("Scope for Actions Below"), selection: $store.cleanUpScope) {
            cleanUpScopeLabel(store.archiveAllScopeLabel, scope: .all)
                .tag(CleanUpScope.all)
            cleanUpScopeLabel(L10n.text("Filtered"), scope: .filtered)
                .tag(CleanUpScope.filtered)
            cleanUpScopeLabel(L10n.text("Selected"), scope: .selected)
                .tag(CleanUpScope.selected)
        }
        .pickerStyle(.inline)
        .disabled(store.isNewFileOperationBlocked)
        Divider()
        Button(L10n.text("Trash No…")) {
            store.requestCleanUp(.trashNo)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .trashNo))
        Button(L10n.text("Trash No + Undecided…")) {
            store.requestCleanUp(.keepOnlyYes)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .keepOnlyYes))
        Divider()
        Button(L10n.text("Trash Paired JPEGs…")) {
            store.requestCleanUp(.pairedJPEGs)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .pairedJPEGs))
        Button(L10n.text("Trash Paired RAWs…")) {
            store.requestCleanUp(.pairedRAWs)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .pairedRAWs))
    }

    private func cleanUpScopeLabel(_ title: String, scope: CleanUpScope) -> Text {
        Text("\(title) (\(L10n.number(store.cleanUpScopeCount(for: scope))))")
    }
}

/// Filter/Sort toolbar glyph: accent when active. Inactive icons keep the
/// native style so `.disabled` dims them like the other toolbar buttons.
private struct ToolbarStateIcon: View {
    let systemName: String
    let isActive: Bool

    var body: some View {
        if isActive {
            Image(systemName: systemName).foregroundStyle(Color.louppeAccent)
        } else {
            Image(systemName: systemName)
        }
    }
}
