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
struct SessionView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        mainContent
            .overlay { cleanUpProgressOverlay }
            .toolbar { toolbarContent }
            .navigationTitle("")
            .focusedSceneValue(\.louppeSessionStore, store)
            .background {
                SessionKeyEventMonitor { event, sessionWindow in
                    let context = liveKeyRoutingContext(
                        for: event,
                        sessionWindow: sessionWindow
                    )
                    return handleKey(event, context: context)
                }
            }
            .sheet(isPresented: $store.isExportPresented) {
                ExportView(store: store)
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
                Button(L10n.text("Move to Trash"), role: .destructive) {
                    store.performCleanUp(mode)
                }
                .keyboardShortcut(.defaultAction)
                Button(L10n.text("Cancel"), role: .cancel) {}
            } message: { mode in
                Text(cleanUpMessage(for: mode))
            }
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
        let count = store.ratedCount
        let items = count == 1 ? "1 item" : L10n.text("\(count) items")
        return L10n.text("Clear Yes/No decisions from \(items). Stars and color labels stay unchanged. Undo with ⌘Z.")
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
        case 1:
            return L10n.text("A Saved File Is Missing")
        default:
            return L10n.text("Saved Files Are Missing")
        }
    }

    private var legacyMissingFilesActionTitle: String {
        store.legacySessionMigrationMissingFileCount == 1
            ? L10n.text("Open Folder and Forget Missing Item")
            : L10n.text("Open Folder and Forget Missing Items")
    }

    private var legacyMigrationMessage: String {
        let count = store.legacySessionMigrationMissingFileCount
        guard count > 0 else {
            return L10n.text("These older decisions use filenames only. All saved filenames are present, but original files cannot be verified. Use Saved Decisions upgrades the session and binds decisions to current physical files. Close Folder changes nothing.")
        }
        var message = count == 1
            ? L10n.text("Older decisions refer to 1 file missing from this folder. Louppe cannot tell whether it was deleted intentionally or is temporarily unavailable. Open Folder and Forget Missing Item discards only that old saved decision, keeps present-file decisions, and upgrades the session. Close Folder changes nothing.")
            : L10n.text("Older decisions refer to \(count) files missing from this folder. Louppe cannot tell whether they were deleted intentionally or are temporarily unavailable. Open Folder and Forget Missing Items discards only those old saved decisions, keeps present-file decisions, and upgrades the session. Close Folder changes nothing.")
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
            return L10n.text("Move \(itemsPhrase(counts.photos)) to the Trash?")
        case .trashNo:
            return L10n.text("Move \(itemsPhrase(counts.photos)) marked “No” to the Trash?")
        case .keepOnlyYes:
            return L10n.text("Move \(itemsPhrase(counts.photos)) not marked “Yes” to the Trash?")
        case .pairedJPEGs:
            let noun = counts.photos == 1 ? L10n.text("JPEG from 1 RAW + JPEG pair") : L10n.text("JPEGs from \(counts.photos) RAW + JPEG pairs")
            return L10n.text("Move the \(noun) to the Trash?")
        case .pairedRAWs:
            let noun = counts.photos == 1 ? L10n.text("RAW from 1 RAW + JPEG pair") : L10n.text("RAWs from \(counts.photos) RAW + JPEG pairs")
            return L10n.text("Move the \(noun) to the Trash?")
        }
    }

    private func cleanUpMessage(for mode: CleanUpMode) -> String {
        let counts = store.cleanUpCounts(for: mode)
        let files = counts.files == 1 ? "1 file" : L10n.text("\(counts.files) files")
        let space = ByteCountFormatter.string(fromByteCount: counts.bytes, countStyle: .file)
        if mode == .pairedJPEGs || mode == .pairedRAWs {
            let removed = mode == .pairedJPEGs ? "JPEG" : "RAW"
            let retained = mode == .pairedJPEGs ? "RAW" : "JPEG"
            var parts = [
                L10n.text("\(files) (about \(space)) will be moved to the Trash. The matching \(retained) files will stay in the folder."),
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
            return parts.joined(separator: "\n")
        }
        var parts = [
            L10n.text("\(files) will be moved to the Trash (a RAW+JPEG pair counts as two), totaling about \(space). Undo with ⌘Z before closing this session, while files remain in Trash. Emptying Trash permanently deletes them and may free that space.")
        ]
        switch mode {
        case .selection:
            parts.append(L10n.text("Only selected items leave the folder."))
        case .trashNo:
            parts.append(L10n.text("Within this scope, Yes and unrated items stay in the folder."))
        case .keepOnlyYes:
            let decisions = store.cleanUpDecisionBreakdown(for: mode)
            parts.insert(L10n.text("Includes \(decisions.no) No and \(decisions.undecided) Undecided items. Stars and color labels do not protect these items. Mixed RAW + JPEG decisions stay in the folder."), at: 0)
        case .pairedJPEGs, .pairedRAWs:
            break // These modes return through their dedicated message above.
        }
        // Spell out the rating-based scope so nothing outside it is trashed
        // (or spared) by surprise. A direct selection is already explicit.
        if mode != .selection {
            switch store.cleanUpScope {
            case .all:
                if store.filter.isActive {
                    parts.append(L10n.text("All \(store.items.count) folder items are considered, even those hidden by filters."))
                }
            case .filtered:
                if store.filter.isActive {
                    let hidden = store.items.count - store.visibleIndices.count
                    parts.append(L10n.text("Only \(store.visibleIndices.count) visible items are considered; \(hidden) hidden items stay untouched."))
                }
            case .selected:
                let count = store.cleanUpScopeCount(for: .selected)
                let phrase = count == 1 ? L10n.text("1 selected item is") : L10n.text("\(count) selected items are")
                parts.append(L10n.text("Only \(phrase) considered — every unselected item stays in the folder."))
            }
        }
        return parts.joined(separator: "\n")
    }

    private func itemsPhrase(_ count: Int) -> String {
        count == 1 ? "1 item" : L10n.text("\(count) items")
    }

    private var subtitle: String {
        guard !store.items.isEmpty else { return "" }
        let position = store.visibleIndices.isEmpty
            ? 0
            : (store.currentVisiblePosition ?? 0) + 1
        var text = L10n.text("Item \(position) of \(store.visibleIndices.count)")
        if store.filter.isActive {
            text += L10n.text(" (of \(store.items.count) total)")
        }
        text += L10n.text("  ·  \(store.yesCount + store.noCount)/\(store.items.count) reviewed")
        if store.mixedCount > 0 {
            text += L10n.text("  ·  \(store.mixedCount) mixed")
        }
        if store.selectedIndices.count > 1 {
            text += L10n.text("  ·  \(store.selectedIndices.count) selected")
        }
        if store.isGroupedReviewActive {
            text += L10n.text("  ·  grouped review")
        }
        return text
    }

    private var statusText: some View {
        HStack(spacing: 8) {
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // Background-work spinner. Always present (just invisible when
            // idle) so the status text doesn't shift when it appears.
            ProgressView()
                .controlSize(.small)
                .opacity(
                    store.fullImageLoads > 0
                        || store.isChangingRawJPEGPairingMode
                        || store.isDuplicateBurstAnalysisRunning ? 1 : 0
                )
                .accessibilityLabel(
                    store.isDuplicateBurstAnalysisRunning
                        ? L10n.text("Analyzing duplicate and burst groups locally")
                        : store.isChangingRawJPEGPairingMode
                        ? L10n.text("Preparing separate JPEG metadata")
                        : L10n.text("Loading photo preview")
                )
                .accessibilityHidden(
                    store.fullImageLoads == 0
                        && !store.isChangingRawJPEGPairingMode
                        && !store.isDuplicateBurstAnalysisRunning
                )
        }
        .help(L10n.text("Review progress and decision totals"))
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if store.isGroupedReviewActive {
                groupedReviewBanner
                Divider()
            }
            HStack(spacing: 0) {
                Group {
                    switch store.viewMode {
                    case .gallery:
                        GalleryView(store: store)
                    case .grid:
                        GridView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // The Info panel is shared by both modes. Keeping it outside the
                // mode switch preserves its metadata/histogram tasks instead of
                // tearing them down and reopening the RAW on every toggle.
                if store.showMetadataPanel, let item = store.currentItem {
                    Divider()
                    MetadataPanel(store: store, item: item)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
            Divider()
            SessionReviewFooter(store: store)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var groupedReviewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: groupedReviewSymbol)
                .foregroundStyle(Color.louppeAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.groupedReviewMode.analysisTitle)
                    .font(.subheadline.weight(.semibold))
                Text(
                    store.groupedReviewGroupCount == 1
                        ? L10n.text("\(store.groupedReviewExplanation) 1 group is visible. Review only — nothing is changed automatically.")
                        : L10n.text("\(store.groupedReviewExplanation) \(store.groupedReviewGroupCount) groups are visible. Review only — nothing is changed automatically.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(L10n.text("Normal Review")) {
                store.exitGroupedReview()
            }
            .buttonStyle(.bordered)
            .accessibilityHint(L10n.text("Return to the normal filtered and sorted media list"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.appBackground)
        .accessibilityElement(children: .contain)
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
                    .accessibilityValue(L10n.text("\(progress.done) of \(progress.total) files"))
                    .frame(width: 280)
                Text(L10n.text("\(progress.done) of \(progress.total) files"))
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
                store.closeSession()
            } label: {
                Label(store.sourceFolder?.lastPathComponent ?? L10n.text("Folder"), systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
            }
            .disabled(store.isFileOperationRunning)
            .accessibilityLabel(L10n.text("Current folder: \(store.sourceFolder?.path ?? "none")"))
            .help(store.sourceFolder?.path ?? L10n.text("Choose another media folder (⌘O)"))
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .navigation)
        }

        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.isFilterPresented.toggle()
            } label: {
                Image(systemName: store.filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(store.filter.isActive ? Color.louppeAccent : Color.primary)
            }
            .popover(isPresented: $store.isFilterPresented, arrowEdge: .bottom) {
                FilterView(store: store)
            }
            .accessibilityLabel(L10n.text("Filter Media"))
            .accessibilityValue(store.filter.isActive ? L10n.text("Active") : L10n.text("Not active"))
            .help(L10n.text("Filter media by date, type, duration, subfolder, camera, or lens"))

            Button {
                store.isSortPresented.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .popover(isPresented: $store.isSortPresented, arrowEdge: .bottom) {
                SortView(store: store)
            }
            .accessibilityLabel(L10n.text("Sort Media"))
            .help(L10n.text("Sort media by date, name, type, duration, or metadata"))

            Picker(L10n.text("View"), selection: $store.viewMode) {
                Image(systemName: "photo")
                    .accessibilityLabel(L10n.text("Gallery"))
                    .tag(ViewMode.gallery)
                Image(systemName: "square.grid.3x3")
                    .accessibilityLabel(L10n.text("Grid"))
                    .tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help(L10n.text("Switch between Gallery and Grid views (Tab or G)"))
        }

        // Session status stays centered and opts out of a glass capsule.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                statusText
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                statusText
            }
        }

        ToolbarItemGroup {
            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(store.isFileOperationRunning || !store.canUndo)
            .accessibilityLabel(L10n.text("Undo"))
            .help(L10n.text("Undo the last decision, stars, color label, or clean-up (Z or ⌘Z)"))
            Button {
                store.requestClearAllRatings()
            } label: {
                Image(systemName: "eraser")
            }
            .disabled(store.isFileOperationRunning || store.ratedCount == 0)
            .accessibilityLabel(L10n.text("Clear All Decisions"))
            .help(L10n.text("Clear all Yes/No decisions (R)"))
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup {
            // The Browser toggle leaves the toolbar entirely while the Grid
            // is showing — the column it controls exists only in the Gallery.
            if store.viewMode == .gallery {
                Button {
                    withAnimation(reduceMotion ? nil : .default) { store.toggleBrowser() }
                } label: {
                    Image(systemName: store.showBrowser ? "sidebar.squares.left" : "sidebar.left")
                }
                .accessibilityLabel(store.showBrowser ? L10n.text("Hide Browser") : L10n.text("Show Browser"))
                .help(L10n.text("Show or hide the Browser in the Gallery view (Q)"))
            }

            Button {
                withAnimation(reduceMotion ? nil : .default) { store.showMetadataPanel.toggle() }
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel(
                store.showMetadataPanel ? L10n.text("Hide Media Information") : L10n.text("Show Media Information")
            )
            .help(L10n.text("Show or hide media information (W)"))
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
            .disabled(!store.canCleanUp)
            .menuIndicator(.hidden)
            .tint(Color.primary)
            .accessibilityLabel(L10n.text("Clean Up"))
            .help(L10n.text("Choose items to move to the Trash"))
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
            .disabled(!store.canExport)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(Color.louppeAccent)
            .accessibilityLabel(L10n.text("Export"))
            .help(L10n.text("Copy or move selected media, or write Metadata (XMP) sidecars (E or ⌘E)"))
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
        context: SessionKeyRoutingContext
    ) -> Bool {
        guard context.sessionOwnsEvent,
              !context.hasModalPresentation,
              !store.isSessionCommandPresentationActive,
              case .ready = store.phase
        else {
            return false
        }

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

        if store.isFileOperationRunning {
            // Only unmodified, explicitly safe view controls stay live. Every
            // other key passes through to AppKit, including VoiceOver chords
            // and unsupported Command combinations.
            guard context.acceptsReviewShortcuts else { return false }
            if event.keyCode == 48 {
                guard context.acceptsNavigationShortcuts,
                      acceptsNavigationModifiers else { return false }
                store.toggleViewMode()
                return true
            }
            guard acceptsReviewModifiers else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q": withAnimation(reduceMotion ? nil : .default) { store.toggleBrowser() }; return true
            case "w": withAnimation(reduceMotion ? nil : .default) { store.showMetadataPanel.toggle() }; return true
            case "x": return store.toggleClippingWarnings()
            case "g": store.toggleViewMode(); return true
            default: return false
            }
        }

        // App commands remain available when a Button, Picker, or Slider has
        // keyboard focus. A live text editor keeps every standard macOS
        // command instead (notably Undo, Select All, and Use Selection for
        // Find).
        let acceptsAppCommand = context.acceptsReviewShortcuts

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
            case "k":
                store.presentActionPalette()
                return store.isActionPalettePresented

            case "e":
                guard store.canExport else { return false }
                store.presentExport()
                return true
            case "r":
                store.rescan()
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

        // J/L are review letters, not native control-navigation keys. They
        // always move between items after an ordinary control or AVKit player
        // has focus; text editing and modal UI were excluded above.
        if acceptsReviewModifiers {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "j": store.goPrevious(); return true
            case "l": store.goNext(); return true
            default: break
            }
        }
        switch event.keyCode {
        case 123:
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            store.performHorizontalReviewAction(forward: false)
            return true                                      // ←
        case 124:
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            store.performHorizontalReviewAction(forward: true)
            return true                                      // →
        case 126:                                             // ↑
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            // Grid: same column, one row up. Gallery: previous photo, matching
            // the vertical Browser strip where the photo above is the previous one.
            if store.viewMode == .grid {
                store.goVertical(-1)
            } else {
                store.goPrevious()
            }
            return true
        case 125:                                             // ↓
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            if store.viewMode == .grid {
                store.goVertical(1)
            } else {
                store.goNext()
            }
            return true
        case 48:
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            store.toggleViewMode()
            return true                                      // Tab
        case 49:                                             // Space
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            if let item = store.currentItem, item.isPlayableMedia {
                store.videoPlayback.toggle(item)
            } else {
                store.goNext()
            }
            return true
        case 53:                                             // Esc: drop the selection
            guard context.acceptsNavigationShortcuts,
                  acceptsNavigationModifiers else { return false }
            guard !store.selectedIndices.isEmpty else { return false }
            store.clearSelection()
            return true
        default: break
        }

        // Unmodified 0–5 assign portable XMP stars without changing the
        // independent Yes/No decision or advancing the current item.
        if modifiers.isEmpty,
           let character = event.charactersIgnoringModifiers {
            switch character {
            case "0": store.setStarRating(nil); return true
            case "1": store.setStarRating(.one); return true
            case "2": store.setStarRating(.two); return true
            case "3": store.setStarRating(.three); return true
            case "4": store.setStarRating(.four); return true
            case "5": store.setStarRating(.five); return true
            default: break
            }
        }

        // The remaining shortcuts are letters. Shift and ordinary Caps Lock
        // may change their glyph but not their Louppe meaning; every other
        // modifier, including Fn/Globe and Help, remains native.
        guard acceptsReviewModifiers else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": store.rate(.yes); return true
        case "d": store.rate(.no); return true
        case "k": return store.toggleCurrentPlayableMedia()
        case "q": withAnimation(reduceMotion ? nil : .default) { store.toggleBrowser() }; return true
        case "w": withAnimation(reduceMotion ? nil : .default) { store.showMetadataPanel.toggle() }; return true
        case "x": return store.toggleClippingWarnings()
        case "g": store.toggleViewMode(); return true
        case "e":
            guard store.canExport else { return false }
            store.presentExport()
            return true
        case "r": store.requestClearAllRatings(); return true
        case "z": store.undo(); return true                  // bare Z = ⌘Z
        case "s":
            if store.viewMode == .gallery {
                store.toggleZoom(.actual)
                return true
            }
            return false
        case "a":
            if store.viewMode == .gallery {
                store.toggleZoom(.small)
                return true
            }
            return false
        default:
            return false
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
#if DEBUG
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

/// Inputs that must be true before a session-wide keyboard shortcut is even
/// interpreted. Keeping this value pure makes the dangerous boundary directly
/// regression-testable without synthesizing system-wide accessibility events.
struct SessionKeyRoutingContext: Equatable {
    let sessionOwnsEvent: Bool
    let hasModalPresentation: Bool
    let focusedResponderOwnsText: Bool
    let focusedResponderOwnsNavigation: Bool
    let isVoiceOverEnabled: Bool

    init(
        sessionOwnsEvent: Bool,
        hasModalPresentation: Bool,
        focusedResponderOwnsText: Bool = false,
        focusedResponderOwnsNavigation: Bool = false,
        isVoiceOverEnabled: Bool = false
    ) {
        self.sessionOwnsEvent = sessionOwnsEvent
        self.hasModalPresentation = hasModalPresentation
        self.focusedResponderOwnsText = focusedResponderOwnsText
        self.focusedResponderOwnsNavigation =
            focusedResponderOwnsNavigation
        self.isVoiceOverEnabled = isVoiceOverEnabled
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
            isVoiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled
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

#if DEBUG
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
#if DEBUG
            SessionKeyMonitorTestProbe.didInstall()
#endif
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
#if DEBUG
            SessionKeyMonitorTestProbe.didRemove()
#endif
        }

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
            cleanUpScopeLabel(L10n.text("All Media"), scope: .all)
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
        Button(L10n.text("Move Paired JPEGs to Trash…")) {
            store.requestCleanUp(.pairedJPEGs)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .pairedJPEGs))
        Button(L10n.text("Move Paired RAWs to Trash…")) {
            store.requestCleanUp(.pairedRAWs)
        }
        .disabled(store.isNewFileOperationBlocked || !store.hasCleanUpTargets(for: .pairedRAWs))
    }

    private func cleanUpScopeLabel(_ title: String, scope: CleanUpScope) -> Text {
        Text("\(title) (\(store.cleanUpScopeCount(for: scope)))")
    }
}
