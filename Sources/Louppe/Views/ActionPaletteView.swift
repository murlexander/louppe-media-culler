import SwiftUI

/// A searchable, keyboard-first route to Louppe's less-frequent actions.
/// Fast culling deliberately stays on its one-key shortcuts; this panel makes
/// newer metadata, folder, and presentation tools easy to discover without
/// crowding the review surface.
struct ActionPaletteView: View {
    @ObservedObject var store: SessionStore

    @State private var query = ""
    @State private var selectedActionID: String?
    @State private var selectionRevealGeneration = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            actionList
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .background(Color.appBackground)
        .onAppear {
            chooseFirstEnabledAction()
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: query) {
            chooseFirstEnabledAction()
            revealKeyboardSelection()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.text("Search actions"), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onSubmit { runSelectedAction() }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    store.dismissActionPalette()
                    return .handled
                }
            if !query.isEmpty {
                Button(L10n.text("Clear"), systemImage: "xmark.circle.fill") {
                    query = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.text("Clear action search"))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var actionList: some View {
        let visibleActions = filteredActions
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(visibleActions.enumerated()), id: \.element.id) {
                        index, action in
                        if query.isEmpty && (index == 0
                            || visibleActions[index - 1].category != action.category) {
                            Text(action.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 10 : 16)
                                .padding(.horizontal, 18)
                        }
                        actionRow(action)
                            .id(action.id)
                    }
                    if visibleActions.isEmpty {
                        ContentUnavailableView(
                            L10n.text("No matching actions"),
                            systemImage: "magnifyingglass",
                            description: Text(L10n.text("Try a different search term."))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 64)
                    }
                }
                .padding(.bottom, 10)
            }
            .accessibilityLabel(L10n.text("Command Palette actions"))
            .onChange(of: selectionRevealGeneration) {
                guard let selectedActionID else { return }
                proxy.scrollTo(selectedActionID, anchor: .center)
            }
        }
    }

    private func actionRow(_ action: ActionPaletteAction) -> some View {
        Button {
            run(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .frame(width: 20)
                    .foregroundStyle(action.isEnabled ? Color.louppeAccent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .foregroundStyle(.primary)
                    Text(action.isEnabled ? action.detail : unavailableReason(for: action))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let shortcut = action.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background {
                if selectedActionID == action.id {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.louppeAccent.opacity(0.14))
                        .padding(.horizontal, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.42)
        .onHover { isHovering in
            if isHovering, action.isEnabled {
                selectedActionID = action.id
            }
        }
        .accessibilityLabel(action.title)
        .accessibilityHint(action.isEnabled ? action.detail : unavailableReason(for: action))
    }

    func unavailableReason(for action: ActionPaletteAction) -> String {
        if action.id == "toggle-raw-jpeg-pairing",
           store.isChangingRawJPEGPairingMode {
            return L10n.text("Updating RAW + JPEG review")
        }
        if store.isFileOperationRunning { return L10n.text("Wait for the current file operation to finish") }
        switch action.id {
        case "toggle-raw-jpeg-pairing":
            if store.isXMPPublicationRunning {
                return L10n.text("Wait for XMP sidecar work to finish")
            }
            return L10n.text("No matching RAW + JPEG pairs in this folder")
        case "gallery", "grid": return L10n.text("This view is already selected")
        case "grid-zoom-in", "grid-zoom-out": return L10n.text("Switch to Grid first")
        case "actual-size", "phone-size": return L10n.text("Select a photo in Gallery first")
        case "browser": return L10n.text("Switch to Gallery first")
        case "seek-video-backward", "seek-video-forward",
             "seek-video-backward-large", "seek-video-forward-large":
            return L10n.text("Select a playable video in Gallery first")
        case "toggle-current-media", "decrease-playback-rate", "increase-playback-rate",
             "set-playback-rate-1x", "set-playback-rate-1-5x",
             "set-playback-rate-2x", "set-playback-rate-2-5x":
            return L10n.text("Select a playable video or audio recording first")
        case "reset-filter": return L10n.text("No filters are active")
        case "clear-selection": return L10n.text("No multi-selection is active")
        case "return-normal-review": return L10n.text("No review group is active")
        case "undo": return L10n.text("Nothing to undo")
        default: return L10n.text("Not available for the current media or selection")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("⌘K")
                .font(.caption.monospaced())
            Text(L10n.text("to open"))
            Spacer()
            Text("↑↓")
                .font(.caption.monospaced())
            Text("choose")
            Text("↵")
                .font(.caption.monospaced())
            Text("run")
            Text("Esc")
                .font(.caption.monospaced())
            Text("close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private var filteredActions: [ActionPaletteAction] {
        ActionPaletteSearch.results(for: query, in: actions)
    }

    var actions: [ActionPaletteAction] {
        [
            ActionPaletteAction(
                id: "export",
                category: L10n.text("Files"),
                title: L10n.text("Export…"),
                detail: L10n.text("Copy, move, or write Metadata (XMP)"),
                symbol: "square.and.arrow.up",
                shortcut: "E / ⌘E",
                keywords: ["copy", "move", "xmp", "metadata", "sidecar", L10n.text("export media")],
                isEnabled: store.canExport,
                perform: { store.presentExport() }
            ),
            ActionPaletteAction(
                id: "rename-files-from-metadata",
                category: L10n.text("Files"),
                title: L10n.text("Rename Files from Metadata…"),
                detail: L10n.text("Preview names built from date, time, camera, lens, and sequence"),
                symbol: "textformat",
                keywords: [
                    L10n.text("rename files"), "filename", L10n.text("batch rename"), L10n.text("bulk rename"),
                    L10n.text("metadata rename"), "date", "time", "camera", "lens", "sequence",
                ],
                isEnabled: store.canRenameSource,
                perform: { store.presentMetadataFileRenaming() }
            ),
            ActionPaletteAction(
                id: "organize",
                category: L10n.text("Files"),
                title: L10n.text("Organize Source Folder…"),
                detail: L10n.text("Preview a metadata-based folder layout"),
                symbol: "folder.badge.gearshape",
                keywords: [L10n.text("organize folder"), L10n.text("move into folders"), L10n.text("source hierarchy"), L10n.text("date folder"), L10n.text("camera folder")],
                isEnabled: store.canOrganizeSource,
                perform: { store.presentSourceOrganization() }
            ),
            ActionPaletteAction(
                id: "organize-date-taken-only",
                category: L10n.text("Files"),
                title: L10n.text("Organize by Date Taken Only…"),
                detail: L10n.text("Organize with Full date only"),
                symbol: "calendar.badge.clock",
                keywords: [
                    L10n.text("organize by date"), L10n.text("date taken"), L10n.text("capture date"),
                    L10n.text("chronological folders"),
                ],
                isEnabled: store.canOrganizeSource,
                perform: {
                    store.presentSourceOrganization(
                        configuration: .dateTakenOnly
                    )
                }
            ),
            ActionPaletteAction(
                id: "open-folder",
                category: L10n.text("Files"),
                title: L10n.text("Open Different Folder…"),
                detail: L10n.text("Save, then choose another media folder"),
                symbol: "folder",
                shortcut: "⌘O",
                keywords: [L10n.text("change folder"), L10n.text("open folder"), L10n.text("choose folder")],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.promptForSourceFolder() }
            ),
            ActionPaletteAction(
                id: "rescan",
                category: L10n.text("Files"),
                title: L10n.text("Rescan Folder"),
                detail: L10n.text("Find new or changed media in this folder"),
                symbol: "arrow.triangle.2.circlepath",
                shortcut: "⌘R",
                keywords: [L10n.text("refresh folder"), L10n.text("scan folder"), L10n.text("find new media")],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.rescan() }
            ),
            ActionPaletteAction(
                id: "close-session",
                category: L10n.text("Files"),
                title: L10n.text("Close Session"),
                detail: L10n.text("Save and return to the folder chooser"),
                symbol: "folder.badge.minus",
                keywords: [L10n.text("close folder"), L10n.text("leave folder"), L10n.text("save session")],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.closeSession() }
            ),
        ]
        + recentFolderActions()
        + [
            ActionPaletteAction(
                id: "filter",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Filter Media…"),
                detail: L10n.text("Filter by metadata, date, type, camera, lens, or video details"),
                symbol: "line.3.horizontal.decrease.circle",
                keywords: [L10n.text("filter media"), L10n.text("find by date"), L10n.text("filter camera"), L10n.text("filter lens"), L10n.text("filter color"), L10n.text("filter stars"), L10n.text("filter video"), L10n.text("filter codec"), L10n.text("filter resolution"), L10n.text("filter frame rate")],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.isFilterPresented = true }
            ),
            ActionPaletteAction(
                id: "filter-search",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Search Media…"),
                detail: L10n.text("Open Filter and focus Search"),
                symbol: "magnifyingglass",
                shortcut: "⌘F",
                keywords: [L10n.text("find media"), L10n.text("filter search"), "filename", L10n.text("metadata search")],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.presentFilterSearch() }
            ),
            ActionPaletteAction(
                id: "show-videos-only",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Show Videos Only"),
                detail: L10n.text("Show videos matching current criteria"),
                symbol: "film",
                keywords: [L10n.text("video filter"), L10n.text("filter videos"), L10n.text("movies only"), L10n.text("clips only")],
                isEnabled: store.availableMediaKinds.contains(.video)
                    && !store.isFileOperationRunning,
                perform: { store.showVideosOnly() }
            ),
            ActionPaletteAction(
                id: "reset-filter",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Reset Filters"),
                detail: L10n.text("Show the full folder again"),
                symbol: "line.3.horizontal.decrease.circle.fill",
                keywords: [L10n.text("clear filters"), L10n.text("show all media"), L10n.text("remove filters")],
                isEnabled: store.filterCanReset && !store.isFileOperationRunning,
                perform: { store.resetFilter() }
            ),
            ActionPaletteAction(
                id: "sort",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Sort Media…"),
                detail: L10n.text("Choose date, stars, color, camera, video details, and more"),
                symbol: "arrow.up.arrow.down",
                keywords: [
                    L10n.text("order media"), L10n.text("sort by date"), L10n.text("sort by name"), L10n.text("sort by decision"),
                    L10n.text("sort by stars"), L10n.text("sort by color"), L10n.text("sort by subfolder"),
                    L10n.text("sort by file type"), L10n.text("sort by media type"), L10n.text("sort by camera"),
                    L10n.text("sort by lens"), L10n.text("sort by aperture"), L10n.text("sort by shutter speed"),
                    L10n.text("sort by ISO"), L10n.text("sort by duration"), L10n.text("sort by video"),
                    "ascending", "descending", L10n.text("group media"), L10n.text("review group settings"),
                ],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.isSortPresented = true }
            ),
            ActionPaletteAction(
                id: "sort-by-video-resolution",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Sort by Video Resolution"),
                detail: L10n.text("Order videos by pixel dimensions"),
                symbol: "rectangle.on.rectangle",
                keywords: [L10n.text("sort video resolution"), L10n.text("video dimensions"), "4k", "hd"],
                isEnabled: store.availableVideoResolutions.count > 1
                    && !store.isFileOperationRunning,
                perform: { store.sort.key = .videoResolution }
            ),
            ActionPaletteAction(
                id: "sort-by-video-frame-rate",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Sort by Video Frame Rate"),
                detail: L10n.text("Order videos by frame rate"),
                symbol: "speedometer",
                keywords: [L10n.text("sort video frame rate"), L10n.text("video fps"), L10n.text("slow motion")],
                isEnabled: store.videoFrameRateRange != nil
                    && !store.isFileOperationRunning,
                perform: { store.sort.key = .videoFrameRate }
            ),
            ActionPaletteAction(
                id: "sort-by-video-codec",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Sort by Video Codec"),
                detail: L10n.text("Order videos by codec"),
                symbol: "film.stack",
                keywords: [L10n.text("sort video codec"), "h.264", "hevc", "prores"],
                isEnabled: store.availableVideoCodecs.count > 1
                    && !store.isFileOperationRunning,
                perform: { store.sort.key = .videoCodec }
            ),
            ActionPaletteAction(
                id: "analyze-duplicate-burst-groups",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Analyze Duplicate + Burst Groups"),
                detail: L10n.text("Analyze locally; files and ratings stay unchanged"),
                symbol: "rectangle.3.group",
                keywords: [L10n.text("analyze groups"), L10n.text("find duplicates"), L10n.text("find similar photos"), L10n.text("find bursts"), L10n.text("local analysis")],
                isEnabled: !store.items.isEmpty
                    && !store.isFileOperationRunning
                    && !store.isXMPPublicationRunning,
                perform: { store.analyzeDuplicateAndBurstGroups() }
            ),
            ActionPaletteAction(
                id: "review-exact-duplicates",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Review Exact Duplicates"),
                detail: L10n.text("Show verified byte-identical files as groups"),
                symbol: "doc.on.doc",
                keywords: [L10n.text("review duplicates"), L10n.text("identical files"), L10n.text("same bytes")],
                isEnabled: !store.items.isEmpty
                    && !store.isFileOperationRunning
                    && !store.isXMPPublicationRunning,
                perform: { store.enterGroupedReview(.exactDuplicates) }
            ),
            ActionPaletteAction(
                id: "review-likely-similar-photos",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Review Likely Similar Photos"),
                detail: L10n.text("Group local preview matches; inspect before deciding"),
                symbol: "photo.on.rectangle.angled",
                keywords: [L10n.text("review similar"), L10n.text("near duplicates"), L10n.text("similarity groups")],
                isEnabled: !store.items.isEmpty
                    && !store.isFileOperationRunning
                    && !store.isXMPPublicationRunning,
                perform: { store.enterGroupedReview(.likelySimilarPhotos) }
            ),
            ActionPaletteAction(
                id: "review-capture-bursts",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Review Capture Bursts"),
                detail: L10n.text("Group photos taken close together in time"),
                symbol: "rectangle.stack",
                keywords: [L10n.text("review bursts"), L10n.text("capture sequence"), L10n.text("time groups")],
                isEnabled: !store.items.isEmpty
                    && !store.isFileOperationRunning
                    && !store.isXMPPublicationRunning,
                perform: { store.enterGroupedReview(.captureBursts) }
            ),
            ActionPaletteAction(
                id: "return-normal-review",
                category: L10n.text("Find and arrange"),
                title: L10n.text("Return to Normal Review"),
                detail: L10n.text("Restore normal filtered order"),
                symbol: "arrow.uturn.backward.circle",
                keywords: [L10n.text("normal review"), L10n.text("leave groups"), L10n.text("exit grouped review")],
                isEnabled: store.isGroupedReviewActive && !store.isFileOperationRunning,
                perform: { store.exitGroupedReview() }
            ),
            ActionPaletteAction(
                id: "toggle-raw-jpeg-pairing",
                category: L10n.text("Find and arrange"),
                title: store.rawJPEGPairingMode == .together
                    ? L10n.text("Review RAW + JPEG Separately")
                    : RawJPEGPairingMode.togetherControlTitle,
                detail: store.rawJPEGPairingMode == .together
                    ? L10n.text("Currently together. Show each file separately.")
                    : L10n.text("Currently separate. Review matching files as one photo."),
                symbol: store.rawJPEGPairingMode == .together ? "link.badge.plus" : "link",
                keywords: [
                    L10n.text("treat raw jpeg as one"), L10n.text("pair raw jpeg"), L10n.text("raw jpeg together"),
                    L10n.text("separate raw jpeg"), L10n.text("raw jpeg separately"), L10n.text("split raw jpeg"),
                    L10n.text("independent files"), "pairing", L10n.text("review together"), L10n.text("review separately"),
                ],
                isEnabled: store.rawJPEGPairCount > 0
                    && !store.isFileOperationRunning
                    && !store.isXMPPublicationRunning
                    && !store.isChangingRawJPEGPairingMode,
                perform: {
                    store.setRawJPEGPairingMode(
                        store.rawJPEGPairingMode == .together ? .separate : .together
                    )
                }
            ),
            ActionPaletteAction(
                id: "mark-yes",
                category: L10n.text("Review metadata"),
                title: L10n.text("Mark Yes"),
                detail: L10n.text("Apply Yes; advance if enabled in Review settings"),
                symbol: "checkmark.circle",
                shortcut: "F",
                keywords: [L10n.text("keep photo"), L10n.text("accept photo"), L10n.text("yes decision")],
                isEnabled: store.canRate,
                perform: { store.rate(.yes) }
            ),
            ActionPaletteAction(
                id: "mark-no",
                category: L10n.text("Review metadata"),
                title: L10n.text("Mark No"),
                detail: L10n.text("Apply No; advance if enabled in Review settings"),
                symbol: "xmark.circle",
                shortcut: "D",
                keywords: [L10n.text("reject photo"), L10n.text("no decision")],
                isEnabled: store.canRate,
                perform: { store.rate(.no) }
            ),
            ActionPaletteAction(
                id: "clear-stars",
                category: L10n.text("Review metadata"),
                title: L10n.text("Clear Stars"),
                detail: L10n.text("Remove the star rating from the current photo or selection"),
                symbol: "star.slash",
                shortcut: "0",
                keywords: [L10n.text("zero stars"), "unrated", L10n.text("remove star rating")],
                isEnabled: store.canRate,
                perform: { store.setStarRating(nil) }
            ),
        ]
        + starActions()
        + [
            ActionPaletteAction(
                id: "clear-color-label",
                category: L10n.text("Review metadata"),
                title: L10n.text("Clear Color Label"),
                detail: L10n.text("Remove the color label from the current photo or selection"),
                symbol: "tag.slash",
                keywords: [L10n.text("remove color label"), L10n.text("no color"), "unlabel"],
                isEnabled: store.canRate,
                perform: { store.setColorLabel(nil) }
            ),
        ]
        + colorLabelActions()
        + [
            ActionPaletteAction(
                id: "select-previous-item",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Select Previous Item"),
                detail: L10n.text("Choose the previous visible item, including when reviewing a video"),
                symbol: "chevron.left",
                shortcut: store.viewMode == .gallery
                    ? (store.canSeekCurrentVideo ? "J / ↑"
                        : (store.currentItem?.isPlayableMedia == true
                            ? "J / ↑ / ←" : "J / ↑ / ← / ⌘←"))
                    : (store.currentItem?.isPlayableMedia == true
                        ? "J / ←" : "J / ← / ⌘←"),
                keywords: ["previous", "back", "left", "navigate", L10n.text("video"), "clip"],
                isEnabled: !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.goPrevious() }
            ),
            ActionPaletteAction(
                id: "select-next-item",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Select Next Item"),
                detail: L10n.text("Choose the next visible item, including when reviewing a video"),
                symbol: "chevron.right",
                shortcut: store.viewMode == .gallery
                    ? (store.canSeekCurrentVideo ? "L / ↓"
                        : (store.currentItem?.isPlayableMedia == true
                            ? "L / ↓ / →" : "L / ↓ / → / ⌘→ / Space"))
                    : (store.currentItem?.isPlayableMedia == true
                        ? "L / →" : "L / → / ⌘→ / Space"),
                keywords: ["next", "forward", "right", "navigate", L10n.text("video"), "clip"],
                isEnabled: !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.goNext() }
            ),
            ActionPaletteAction(
                id: "grid-item-above",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Select Grid Item Above"),
                detail: L10n.text("Move to the item in the row above"),
                symbol: "chevron.up",
                shortcut: "↑",
                keywords: [L10n.text("grid up"), L10n.text("previous row"), L10n.text("navigate grid")],
                isEnabled: store.viewMode == .grid
                    && !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.goVertical(-1) }
            ),
            ActionPaletteAction(
                id: "grid-item-below",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Select Grid Item Below"),
                detail: L10n.text("Move to the item in the row below"),
                symbol: "chevron.down",
                shortcut: "↓",
                keywords: [L10n.text("grid down"), L10n.text("next row"), L10n.text("navigate grid")],
                isEnabled: store.viewMode == .grid
                    && !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.goVertical(1) }
            ),
            ActionPaletteAction(
                id: "decrease-playback-rate",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Choose Slower Playback Speed"),
                detail: L10n.text("Step down through the available video or audio playback speeds"),
                symbol: "backward.end",
                shortcut: "⌘←",
                keywords: [L10n.text("video"), L10n.text("audio"), "playback", "speed", "slower"],
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate,
                perform: {
                    _ = store.adjustCurrentPlayableMediaPlaybackRate(
                        forward: false
                    )
                }
            ),
            ActionPaletteAction(
                id: "increase-playback-rate",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Choose Faster Playback Speed"),
                detail: L10n.text("Step up through the available video or audio playback speeds"),
                symbol: "forward.end",
                shortcut: "⌘→",
                keywords: [L10n.text("video"), L10n.text("audio"), "playback", "speed", "faster"],
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate,
                perform: {
                    _ = store.adjustCurrentPlayableMediaPlaybackRate(
                        forward: true
                    )
                }
            ),
            ActionPaletteAction(
                id: "seek-video-backward",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Seek Video Backward 0.5 Seconds"),
                detail: L10n.text("Inspect the current Gallery video half a second earlier"),
                symbol: "gobackward",
                shortcut: "←",
                keywords: [L10n.text("video"), "clip", "scrub", "rewind", "back", "left"],
                isEnabled: store.canSeekCurrentVideo,
                perform: { store.seekCurrentVideo(by: -0.5) }
            ),
            ActionPaletteAction(
                id: "seek-video-forward",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Seek Video Forward 0.5 Seconds"),
                detail: L10n.text("Inspect the current Gallery video half a second later"),
                symbol: "goforward",
                shortcut: "→",
                keywords: [L10n.text("video"), "clip", "scrub", "forward", "right"],
                isEnabled: store.canSeekCurrentVideo,
                perform: { store.seekCurrentVideo(by: 0.5) }
            ),
            ActionPaletteAction(
                id: "seek-video-backward-large",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Seek Video Backward 5 Seconds"),
                detail: L10n.text("Jump five seconds earlier in the current Gallery video"),
                symbol: "gobackward.5",
                shortcut: "⇧←",
                keywords: [L10n.text("video"), "clip", "scrub", "rewind", "back", "left", "jump"],
                isEnabled: store.canSeekCurrentVideo,
                perform: { store.seekCurrentVideo(by: -5) }
            ),
            ActionPaletteAction(
                id: "seek-video-forward-large",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Seek Video Forward 5 Seconds"),
                detail: L10n.text("Jump five seconds later in the current Gallery video"),
                symbol: "goforward.5",
                shortcut: "⇧→",
                keywords: [L10n.text("video"), "clip", "scrub", "forward", "right", "jump"],
                isEnabled: store.canSeekCurrentVideo,
                perform: { store.seekCurrentVideo(by: 5) }
            ),
            ActionPaletteAction(
                id: "toggle-current-media",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Play or Pause Current Media"),
                detail: L10n.text("Play or pause the current video or audio recording"),
                symbol: "playpause",
                shortcut: "Space / K",
                keywords: [L10n.text("video"), L10n.text("audio"), "clip", "recording", "play", "pause", "transport", "k"],
                isEnabled: store.canToggleCurrentPlayableMedia,
                perform: { _ = store.toggleCurrentPlayableMedia() }
            ),
            ActionPaletteAction(
                id: "set-playback-rate-1x",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Set Playback Speed to 1×"),
                detail: L10n.text("Review the current video or audio recording at normal speed"),
                symbol: "1.circle",
                shortcut: nil,
                keywords: [L10n.text("video"), L10n.text("audio"), "clip", "recording", "playback", "speed", "normal", "1x"],
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate,
                perform: { store.setCurrentPlayableMediaPlaybackRate(1) }
            ),
            ActionPaletteAction(
                id: "set-playback-rate-1-5x",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Set Playback Speed to 1.5×"),
                detail: L10n.text("Review the current video or audio recording at one and a half speed"),
                symbol: "1.circle",
                shortcut: nil,
                keywords: [L10n.text("video"), L10n.text("audio"), "clip", "recording", "playback", "speed", "1.5x"],
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate,
                perform: { store.setCurrentPlayableMediaPlaybackRate(1.5) }
            ),
            ActionPaletteAction(
                id: "set-playback-rate-2x",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Set Playback Speed to 2×"),
                detail: L10n.text("Review the current video or audio recording at double speed"),
                symbol: "2.circle",
                shortcut: nil,
                keywords: [L10n.text("video"), L10n.text("audio"), "clip", "recording", "playback", "speed", "double", "2x"],
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate,
                perform: { store.setCurrentPlayableMediaPlaybackRate(2) }
            ),
            ActionPaletteAction(
                id: "set-playback-rate-2-5x",
                category: L10n.text("Navigate and play"),
                title: L10n.text("Set Playback Speed to 2.5×"),
                detail: L10n.text("Review the current video or audio recording at two and a half speed"),
                symbol: "2.circle",
                shortcut: nil,
                keywords: [L10n.text("video"), L10n.text("audio"), "clip", "recording", "playback", "speed", "2.5x"],
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate,
                perform: { store.setCurrentPlayableMediaPlaybackRate(2.5) }
            ),
            ActionPaletteAction(
                id: "select-all",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Select All Visible Media"),
                detail: L10n.text("Select every item that passes the current filter"),
                symbol: "checklist",
                shortcut: "⌘A",
                keywords: ["selection", "filter"],
                isEnabled: !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.selectAllVisible() }
            ),
            ActionPaletteAction(
                id: "select-to-first",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Select to First Item"),
                detail: L10n.text("Extend the selection from the current item to the first visible item"),
                symbol: "arrow.up.to.line",
                shortcut: "⌘⇧←",
                keywords: [L10n.text("extend selection"), L10n.text("selection edge"), L10n.text("select previous")],
                isEnabled: !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.selectToEdge(forward: false) }
            ),
            ActionPaletteAction(
                id: "select-to-last",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Select to Last Item"),
                detail: L10n.text("Extend the selection from the current item to the last visible item"),
                symbol: "arrow.down.to.line",
                shortcut: "⌘⇧→",
                keywords: [L10n.text("extend selection"), L10n.text("selection edge"), L10n.text("select next")],
                isEnabled: !store.visibleIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.selectToEdge(forward: true) }
            ),
            ActionPaletteAction(
                id: "clear-selection",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Clear Selection"),
                detail: L10n.text("Return to reviewing the current photo"),
                symbol: "xmark.rectangle",
                shortcut: "Esc",
                keywords: ["deselect", "selection"],
                isEnabled: !store.selectedIndices.isEmpty && !store.isFileOperationRunning,
                perform: { store.clearSelection() }
            ),
            ActionPaletteAction(
                id: "trash-selection",
                category: L10n.text("Selection and clean up"),
                title: store.selectionCleanUpTitle,
                detail: L10n.text("Palette confirms; ⌘⌫ skips confirmation"),
                symbol: "trash",
                shortcut: "⌘⌫",
                keywords: [L10n.text("trash selection"), L10n.text("delete selected"), L10n.text("remove selected"), L10n.text("clean up selection")],
                isEnabled: store.canCleanUp && store.hasCleanUpTargets(for: .selection),
                perform: { store.requestCleanUp(.selection) }
            ),
            ActionPaletteAction(
                id: "trash-no",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Move “No” to Trash…"),
                detail: L10n.text("Use the current Clean Up scope and ask for confirmation"),
                symbol: "trash",
                keywords: [L10n.text("clean up"), "reject", "delete"],
                isEnabled: store.canCleanUp && store.hasCleanUpTargets(for: .trashNo),
                perform: { store.requestCleanUp(.trashNo) }
            ),
            ActionPaletteAction(
                id: "keep-only-yes",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Trash No + Undecided…"),
                detail: L10n.text("Use the current Clean Up scope and ask for confirmation"),
                symbol: "trash",
                keywords: [L10n.text("clean up"), "delete", "reject", L10n.text("keep only yes")],
                isEnabled: store.canCleanUp && store.hasCleanUpTargets(for: .keepOnlyYes),
                perform: { store.requestCleanUp(.keepOnlyYes) }
            ),
            ActionPaletteAction(
                id: "trash-paired-jpegs",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Move Paired JPEGs to Trash…"),
                detail: L10n.text("Keep the RAW file from each matching RAW + JPEG pair"),
                symbol: "photo.badge.minus",
                keywords: [L10n.text("clean up"), "archive", "pair", "raw", "jpeg", "jpg", L10n.text("keep raw"), "delete", "remove"],
                isEnabled: store.canCleanUp && store.hasCleanUpTargets(for: .pairedJPEGs),
                perform: { store.requestCleanUp(.pairedJPEGs) }
            ),
            ActionPaletteAction(
                id: "trash-paired-raws",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Move Paired RAWs to Trash…"),
                detail: L10n.text("Keep the JPEG file from each matching RAW + JPEG pair"),
                symbol: "photo.badge.minus",
                keywords: [L10n.text("clean up"), "archive", "pair", "raw", "jpeg", "jpg", L10n.text("keep jpeg"), "delete", "remove"],
                isEnabled: store.canCleanUp && store.hasCleanUpTargets(for: .pairedRAWs),
                perform: { store.requestCleanUp(.pairedRAWs) }
            ),
            ActionPaletteAction(
                id: "undo",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Undo Louppe Action"),
                detail: L10n.text("Restore the latest review, metadata, Trash, or organization action"),
                symbol: "arrow.uturn.backward",
                shortcut: "Z / ⌘Z",
                keywords: ["restore", "revert", L10n.text("undo action")],
                isEnabled: store.canUndo,
                perform: { store.undo() }
            ),
            ActionPaletteAction(
                id: "clear-decisions",
                category: L10n.text("Selection and clean up"),
                title: L10n.text("Clear All Decisions"),
                detail: L10n.text("Remove Yes and No decisions while keeping stars and color labels"),
                symbol: "eraser",
                shortcut: "R",
                keywords: [L10n.text("reset yes no"), L10n.text("clear yes no"), L10n.text("remove decisions")],
                isEnabled: store.ratedCount > 0 && !store.isFileOperationRunning,
                perform: { store.requestClearAllRatings() }
            ),
            ActionPaletteAction(
                id: "gallery",
                category: L10n.text("View"),
                title: L10n.text("Switch to Gallery"),
                detail: L10n.text("Review one photo, video, or audio file at a time"),
                symbol: "photo",
                shortcut: "Tab / G",
                keywords: ["view", "single"],
                isEnabled: store.viewMode != .gallery,
                perform: { store.toggleViewMode() }
            ),
            ActionPaletteAction(
                id: "grid",
                category: L10n.text("View"),
                title: L10n.text("Switch to Grid"),
                detail: L10n.text("Review a visual overview of the folder"),
                symbol: "square.grid.3x3",
                shortcut: "Tab / G",
                keywords: ["view", "thumbnails"],
                isEnabled: store.viewMode != .grid,
                perform: { store.toggleViewMode() }
            ),
            ActionPaletteAction(
                id: "grid-zoom-in",
                category: L10n.text("View"),
                title: L10n.text("Larger Grid Thumbnails"),
                detail: L10n.text("Increase thumbnail size in Grid"),
                symbol: "plus.magnifyingglass",
                shortcut: "⌘+",
                keywords: [L10n.text("zoom grid in"), L10n.text("bigger thumbnails"), L10n.text("increase grid size")],
                isEnabled: store.viewMode == .grid,
                perform: { store.zoomGrid(larger: true) }
            ),
            ActionPaletteAction(
                id: "grid-zoom-out",
                category: L10n.text("View"),
                title: L10n.text("Smaller Grid Thumbnails"),
                detail: L10n.text("Decrease thumbnail size in Grid"),
                symbol: "minus.magnifyingglass",
                shortcut: "⌘−",
                keywords: [L10n.text("zoom grid out"), L10n.text("smaller thumbnails"), L10n.text("decrease grid size")],
                isEnabled: store.viewMode == .grid,
                perform: { store.zoomGrid(larger: false) }
            ),
            ActionPaletteAction(
                id: "actual-size",
                category: L10n.text("View"),
                title: store.isAtActualSize ? L10n.text("Return to Fit from 100%") : L10n.text("View at 100%"),
                detail: L10n.text("Toggle source-pixel inspection in Gallery"),
                symbol: "1.magnifyingglass",
                shortcut: "S",
                keywords: [L10n.text("actual size"), "100 percent", L10n.text("zoom photo"), L10n.text("source pixels")],
                isEnabled: store.viewMode == .gallery
                    && store.currentItem?.mediaKind == .photo,
                perform: { store.toggleZoom(.actual) }
            ),
            ActionPaletteAction(
                id: "phone-size",
                category: L10n.text("View"),
                title: store.zoomMode == .small ? L10n.text("Return to Fit from Phone Size") : L10n.text("View Phone-Sized Preview"),
                detail: L10n.text("Toggle a smaller preview in Gallery"),
                symbol: "iphone",
                shortcut: "A",
                keywords: [L10n.text("phone size"), L10n.text("small preview"), L10n.text("zoom photo"), "fit"],
                isEnabled: store.viewMode == .gallery
                    && store.currentItem?.mediaKind == .photo,
                perform: { store.toggleZoom(.small) }
            ),
            ActionPaletteAction(
                id: "browser",
                category: L10n.text("View"),
                title: store.showBrowser ? L10n.text("Hide Browser") : L10n.text("Show Browser"),
                detail: L10n.text("Toggle the thumbnail browser in Gallery"),
                symbol: "sidebar.left",
                shortcut: "Q",
                keywords: ["thumbnails", "sidebar"],
                isEnabled: store.viewMode == .gallery,
                perform: { store.toggleBrowser() }
            ),
            ActionPaletteAction(
                id: "info",
                category: L10n.text("View"),
                title: store.showMetadataPanel ? L10n.text("Hide Media Information") : L10n.text("Show Media Information"),
                detail: L10n.text("Toggle the camera, histogram, and metadata panel"),
                symbol: "info.circle",
                shortcut: "W",
                keywords: ["metadata", "histogram", "camera"],
                isEnabled: true,
                perform: { store.showMetadataPanel.toggle() }
            ),
            ActionPaletteAction(
                id: "clipping",
                category: L10n.text("View"),
                title: store.showClippingWarnings ? L10n.text("Hide Preview Clipping Overlay") : L10n.text("Show Preview Clipping Overlay"),
                detail: L10n.text("Mark clipping estimated from the displayed preview"),
                symbol: "exclamationmark.triangle",
                shortcut: "X",
                keywords: ["preview", "histogram", "exposure", "highlights", "shadows"],
                isEnabled: store.canToggleClippingWarnings,
                perform: { _ = store.toggleClippingWarnings() }
            ),
        ]
    }

    private func chooseFirstEnabledAction() {
        selectedActionID = filteredActions.first(where: \.isEnabled)?.id
    }

    private func moveSelection(by offset: Int) {
        let enabled = filteredActions.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            selectedActionID = nil
            return
        }
        guard let currentID = selectedActionID,
              let index = enabled.firstIndex(where: { $0.id == currentID })
        else {
            self.selectedActionID = enabled[0].id
            revealKeyboardSelection()
            return
        }
        let next = (index + offset + enabled.count) % enabled.count
        selectedActionID = enabled[next].id
        revealKeyboardSelection()
    }

    private func revealKeyboardSelection() {
        selectionRevealGeneration &+= 1
    }

    private func runSelectedAction() {
        guard let action = filteredActions.first(where: { $0.id == selectedActionID }) else { return }
        run(action)
    }

    private func run(_ action: ActionPaletteAction) {
        guard action.isEnabled else { return }
        store.dismissActionPalette(then: action.perform)
    }

    private func starActions() -> [ActionPaletteAction] {
        StarRating.allCases.map { rating in
            let title = rating == .one
                ? L10n.text("Set 1 Star")
                : L10n.text("Set \(rating.count) Stars")
            return ActionPaletteAction(
                id: "stars-\(rating.count)",
                category: L10n.text("Review metadata"),
                title: title,
                detail: L10n.text("Apply a portable star rating to the current photo or selection"),
                symbol: "star",
                shortcut: "\(rating.count)",
                keywords: ["rating", "metadata", "xmp"],
                isEnabled: store.canRate,
                perform: { store.setStarRating(rating) }
            )
        }
    }

    private func colorLabelActions() -> [ActionPaletteAction] {
        PhotoColorLabel.allCases.map { label in
            let title = L10n.text("Set \(label.localizedDisplayName) Color Label")
            return ActionPaletteAction(
                id: "color-label-\(label.rawValue)",
                category: L10n.text("Review metadata"),
                title: title,
                detail: L10n.text("Apply a portable color label to the current photo or selection"),
                symbol: "tag",
                keywords: ["color", "label", "metadata", "xmp", label.rawValue],
                isEnabled: store.canRate,
                perform: { store.setColorLabel(label) }
            )
        }
    }

    private func recentFolderActions() -> [ActionPaletteAction] {
        store.recentFolders.map { folder in
            let name = folder.lastPathComponent.isEmpty
                ? folder.path
                : folder.lastPathComponent
            return ActionPaletteAction(
                id: "recent-folder-\(folder.path)",
                category: L10n.text("Files"),
                title: L10n.text("Open Recent Folder “\(name)”"),
                detail: folder.path,
                symbol: "clock.arrow.circlepath",
                keywords: ["recent", "open", "folder"],
                isEnabled: !store.isFileOperationRunning,
                perform: { store.openFolder(folder) }
            )
        }
    }
}

struct ActionPaletteAction: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String
    let symbol: String
    let shortcut: String?
    let keywords: [String]
    let isEnabled: Bool
    let perform: @MainActor () -> Void

    init(
        id: String,
        category: String,
        title: String,
        detail: String,
        symbol: String,
        shortcut: String? = nil,
        keywords: [String],
        isEnabled: Bool,
        perform: @escaping @MainActor () -> Void
    ) {
        self.id = id
        switch category {
        case L10n.text("Files"): self.category = L10n.text("Files & folders")
        case L10n.text("Find and arrange"): self.category = L10n.text("Find & arrange")
        case L10n.text("Review metadata"): self.category = L10n.text("Rate & label")
        case L10n.text("Navigate and play"): self.category = L10n.text("Navigate & play")
        case L10n.text("Selection and clean up"): self.category = L10n.text("Select & clean up")
        case L10n.text("View"): self.category = L10n.text("View & inspect")
        default: self.category = category
        }
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.shortcut = shortcut
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.perform = perform
    }

    var searchText: String {
        ([title, detail, category] + keywords).joined(separator: " ").lowercased()
    }
}

/// Titles and intentional aliases outrank incidental words in descriptions.
enum ActionPaletteSearch {
    static func results(
        for query: String,
        in actions: [ActionPaletteAction]
    ) -> [ActionPaletteAction] {
        let words = tokens(query)
        guard !words.isEmpty else { return actions }
        return actions.enumerated().compactMap { index, action -> (Int, Int, ActionPaletteAction)? in
            guard let score = score(action, words: words) else { return nil }
            return (score, index, action)
        }
        .sorted { left, right in
            left.0 == right.0 ? left.1 < right.1 : left.0 > right.0
        }
        .map { $0.2 }
    }

    private static func score(_ action: ActionPaletteAction, words: [String]) -> Int? {
        let title = tokens(action.title)
        let aliases = action.keywords.map(tokens)
        let detail = tokens(action.detail)
        let category = tokens(action.category)
        let sources = [title] + aliases + [detail, category]
        guard words.allSatisfy({ word in
            sources.contains { source in source.contains { $0.hasPrefix(word) } }
        }) else { return nil }

        if title == words { return 1_000 }
        if aliases.contains(words) { return 900 }
        if containsSequence(title, words) { return 800 }
        if aliases.contains(where: { containsSequence($0, words) }) { return 700 }
        if words.allSatisfy({ word in title.contains { $0.hasPrefix(word) } }) { return 600 }
        if aliases.contains(where: { alias in
            words.allSatisfy { word in alias.contains { $0.hasPrefix(word) } }
        }) { return 500 }
        if words.allSatisfy({ word in
            ([title] + aliases).contains { $0.contains { $0.hasPrefix(word) } }
        }) { return 400 }
        if words.allSatisfy({ word in detail.contains { $0.hasPrefix(word) } }) { return 200 }
        if words.allSatisfy({ word in category.contains { $0.hasPrefix(word) } }) { return 100 }
        return 50
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { offset in
            zip(needle, haystack[offset..<(offset + needle.count)])
                .allSatisfy { pair in pair.1.hasPrefix(pair.0) }
        }
    }

    private static func tokens(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
