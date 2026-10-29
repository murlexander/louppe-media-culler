import AppKit
import SwiftUI

/// The Grid view: click a photo to make it current, use its rating control to
/// cycle the decision, double-click to open it in the Gallery view, and
/// click-and-drag to rubber-band-select several photos at once. Days are
/// separated by a horizontal line and each day starts on a fresh row.
/// ⌘+/⌘− resize the tiles; W toggles photo info.
struct GridView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.locale) private var locale
    @State private var collectionController = ReviewCollectionController()
    @State private var suppressNextFollow = false
    var initialViewportReceipt: ReviewCollectionViewportReceipt? = nil
    var onViewportChange: ((ReviewCollectionViewportReceipt) -> Void)? = nil
    var onViewportRestored: ((ReviewCollectionViewportReceipt) -> Void)? = nil

    var body: some View {
        grid
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SessionRenderMarker(kind: .grid))
    }

    private var grid: some View {
        GeometryReader { geometry in
            Group {
                if store.items.isEmpty {
                    SessionEmptyView(
                        reason: store.emptySessionReason,
                        canUndo: store.canUndo
                    )
                    .padding(.top, 80)
                } else if store.visibleIndices.isEmpty
                            && store.isGroupedReviewActive {
                    ContentUnavailableView(
                        store.groupedReviewEmptyTitle,
                        systemImage: "rectangle.3.group",
                        description: Text(store.groupedReviewEmptyDescription)
                    )
                    .padding(.top, 80)
                } else if store.visibleIndices.isEmpty
                            && store.filter.isActive {
                    ContentUnavailableView {
                        Label(L10n.text("No items match the filter"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("Change or clear filters to show media."))
                    } actions: {
                        Button(L10n.text("Clear Filters")) { store.resetFilter() }
                    }
                    .padding(.top, 80)
                } else {
                    GridCollectionContent(
                        store: store,
                        groups: store.gridGroups,
                        thumbnailSize: store.gridThumbSize,
                        viewportSize: geometry.size,
                        locale: locale,
                        onPointerCurrentChange: suppressFollowForPointerAction,
                        controller: collectionController
                    )
                    .equatable()
                    .environment(\.mediaReadAccess, store.mediaReadAccess)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.appBackground)
                    .onAppear {
                        collectionController.onViewportChange = { receipt in
                            store.recordPinnedViewport(physicalFileID: receipt.physicalFileID,
                                                       topOffset: Double(receipt.topOffset), surface: .grid)
                            onViewportChange?(receipt)
                        }
                        collectionController.onViewportRestored = onViewportRestored
                        updateColumnCount(for: geometry.size.width)
                        if let initialViewportReceipt {
                            collectionController.restoreViewport(initialViewportReceipt)
                        } else if let id = store.currentItem?.id {
                            collectionController.follow(id: id)
                        }
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        updateColumnCount(for: width)
                    }
                    .onChange(of: store.gridThumbSize) { _, _ in
                        updateColumnCount(for: geometry.size.width)
                    }
                    .onChange(of: initialViewportReceipt) { _, receipt in
                        if let receipt { collectionController.restoreViewport(receipt) }
                    }
                    .onChange(of: store.currentItem?.id) {
                        if suppressNextFollow {
                            suppressNextFollow = false
                        } else if let id = store.currentItem?.id {
                            collectionController.follow(id: id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func updateColumnCount(for width: CGFloat) {
        // The legacy vertical scroller owns a real gutter inside the Grid's
        // width. Exclude it so arrow-key columns match the rendered grid.
        let contentWidth = max(
            width
                - 12
                - 6
                - PersistentVerticalScroller.gutterWidth,
            1
        )
        let spacing: CGFloat = 10
        let count = max(1, Int((contentWidth + spacing) / (store.gridThumbSize + spacing)))
        store.setGridColumnCount(count)
    }

    private func suppressFollowForPointerAction() {
        suppressNextFollow = true
    }
}

/// Only structural/layout inputs invalidate the collection. Realized cells
/// observe live review state themselves; the host still owns follow and gestures.
struct GridCollectionContent: View, Equatable {
    private struct ProjectionSource: Equatable {
        let owner: ObjectIdentifier
        let groups: [PreparedSessionIndex.VisibleGroup]
    }
    @State private var projectionCache = ReviewCollectionProjectionCache<ProjectionSource>()
    @Environment(\.layoutDirection) private var layoutDirection
    let store: SessionStore
    let groups: [PreparedSessionIndex.VisibleGroup]
    let thumbnailSize: CGFloat
    let viewportSize: CGSize
    let locale: Locale
    let onPointerCurrentChange: () -> Void

    // The callback targets the host's persistent State, so it does not change
    // while the store and collection identity stay the same. Array equality
    // fast-paths shared immutable storage on ordinary store publications.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store
            && lhs.thumbnailSize == rhs.thumbnailSize
            && lhs.viewportSize == rhs.viewportSize
            && lhs.locale == rhs.locale
            && lhs.groups == rhs.groups
    }

    var controller: ReviewCollectionController? = nil

    #if DEBUG
    static var didConstruct: (() -> Void)?
    static var didBuildProjection: (() -> Void)?
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.didConstruct?()
        #endif
        let source = ProjectionSource(owner: ObjectIdentifier(store), groups: groups)
        let projection = projectionCache.resolve(for: source) {
            #if DEBUG
            Self.didBuildProjection?()
            #endif
            return ReviewCollectionProjection(sections: groups.map { group in
                ReviewCollectionSection(
                    id: String(describing: group.id), title: group.title,
                    entries: group.entries.compactMap { entry in
                        guard store.items.indices.contains(entry.index) else { return nil }
                        return ReviewCollectionEntry(id: entry.id, index: entry.index,
                            physicalFileIDs: store.items[entry.index].individualFiles.map(\.id))
                    }
                )
            })
        }
        ReviewCollection(
            projection: projection,
            style: .grid(thumbnailSize: thumbnailSize),
            controller: controller,
            rubberBand: ReviewCollectionRubberBand(
                shouldBegin: { point, frames in
                    let playable = Set(frames.keys.filter {
                        store.items.indices.contains($0) && store.items[$0].isPlayableMedia
                    })
                    return GridRubberBandHitTest.shouldTrackCanvasDrag(
                        startingAt: point, tileFrames: frames, playableVideoIndices: playable,
                        rightToLeft: layoutDirection == .rightToLeft)
                },
                changed: { rect, frames in
                    store.setSelection(Set(frames.filter { $0.value.intersects(rect) }.map(\.key)))
                },
                ended: { store.commitSelectionAnchor() }
            )
        ) { entry in
            AnyView(GridCell(store: store, index: entry.index, id: entry.id,
                             onPointerCurrentChange: onPointerCurrentChange))
        }
    }
}

/// One live Grid tile. Like BrowserRow, it observes the store directly because
/// macOS lazy containers can retain an already-created value subtree after the
/// shared per-file rating storage changes. Keeping the observation here makes
/// the badge, selection frame, and accessibility value update immediately.
private struct GridCell: View {
    @ObservedObject var store: SessionStore
    let index: Int
    let id: String
    let onPointerCurrentChange: () -> Void

    var body: some View {
        if store.items.indices.contains(index), store.items[index].id == id {
            let item = store.items[index]
            let actions = GridCellActions(
                store: store,
                index: index,
                onPointerCurrentChange: onPointerCurrentChange
            )
            VStack(spacing: 3) {
                ZStack {
                    ThumbnailView(
                        item: item,
                        isCurrent: index == store.currentIndex,
                        isSelected: store.selectedIndices.contains(index),
                        showsRatingBadge: false,
                        videoPlayback: store.videoPlayback
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    // A representable has a 100x100 default ideal size. Keep
                    // it in an overlay so it receives the media square's real
                    // size without participating in the Grid cell's layout.
                    Color.clear
                        .overlay {
                            GridImmediateClickSurface(
                                onSingleClick: actions.selectPhoto,
                                onDoubleClick: actions.openInGallery
                            )
                            .mediaTileAccessibility(
                                item: item,
                                isCurrent: index == store.currentIndex,
                                isSelected: store.selectedIndices.contains(index),
                                showActionTitle: L10n.text("Make Current"),
                                show: {
                                    actions.makeCurrent()
                                },
                                open: {
                                    actions.openInGallery()
                                },
                                canRate: store.canRate,
                                rate: { rating in
                                    store.rate(rating, at: index)
                                },
                                setStars: { stars in
                                    store.setStarRating(stars, at: index)
                                },
                                setColor: { label in
                                    store.setColorLabel(label, at: index)
                                },
                                toggleSelection: {
                                    store.toggleSelection(of: index)
                                }
                            )
                        }

                    if item.isPlayableMedia {
                        Button {
                            if index != store.currentIndex {
                                onPointerCurrentChange()
                                store.setIndex(index)
                            }
                            store.videoPlayback.toggle(item)
                        } label: {
                            Image(systemName: store.videoPlayback.isActive(item) && store.videoPlayback.isPlaying
                                ? "pause.fill"
                                : "play.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.louppeFilledAccent)
                        .buttonBorderShape(.circle)
                        .tint(.black.opacity(0.62))
                        .foregroundStyle(.white)
                        .controlSize(.large)
                        .help(store.videoPlayback.isActive(item) && store.videoPlayback.isPlaying
                            ? L10n.text("Pause \(L10n.label(item.mediaKind.singularLabel))")
                            : L10n.text("Play \(L10n.label(item.mediaKind.singularLabel))"))
                        .accessibilityLabel(store.videoPlayback.isActive(item) && store.videoPlayback.isPlaying
                            ? L10n.text("Pause \(L10n.label(item.mediaKind.singularLabel))")
                            : L10n.text("Play \(L10n.label(item.mediaKind.singularLabel))"))
                    }
                }
                // Keep the rating control above the photo's selection gesture
                // so its click never falls through and changes two things.
                .overlay(alignment: .topTrailing) {
                    Button {
                        actions.cycleRating()
                    } label: {
                        RatingBadge(
                            rating: item.rating,
                            isMixed: item.hasMixedRatings,
                            size: TileBadgeLayout.height
                        )
                        .frame(
                            width: TileBadgeLayout.decisionTargetSize,
                            height: TileBadgeLayout.decisionTargetSize,
                            alignment: .topTrailing
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canRate)
                    .padding(TileBadgeLayout.inset)
                    .help(L10n.text("Change Yes/No decision"))
                    .accessibilityLabel(L10n.text("Change decision for \(item.displayName)"))
                    .accessibilityValue(
                        MediaTileAccessibility.ratingDescription(
                            for: item.ratingState
                        )
                    )
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    QualityCueTileIcons(store: store, item: item)
                        .padding(TileBadgeLayout.inset)
                }

                ReviewGridCaption(title: item.displayName)
                    .accessibilityHidden(true)
                    .overlay {
                        GridImmediateClickSurface(
                            onSingleClick: actions.selectPhoto,
                            onDoubleClick: actions.openInGallery
                        )
                        .accessibilityHidden(true)
                    }
            }
            .frame(maxWidth: .infinity)
            .contextMenu {
                MediaTileContextMenu(store: store, index: index, revision: item.contentRevision, open: actions.openInGallery)
            }
        }
    }
}

/// A native pointer surface that commits a single click on mouse-up without
/// waiting for AppKit's double-click interval. The former exclusive pair of
/// SwiftUI TapGestures deliberately delayed selection until the double-click
/// recognizer failed. Here the first click selects immediately; a second click
/// arrives with `clickCount == 2` and opens the already-selected item.
struct GridImmediateClickSurface: NSViewRepresentable {
    let onSingleClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView(
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick
        )
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class ClickView: NSView {
        private static let dragThresholdSquared: CGFloat = 8 * 8

        var onSingleClick: (NSEvent.ModifierFlags) -> Void
        var onDoubleClick: () -> Void
        private var mouseDownLocation: CGPoint?
        private var exceededDragThreshold = false
        private let touchActions = DirectTouchClickActions()

        init(
            onSingleClick: @escaping (NSEvent.ModifierFlags) -> Void,
            onDoubleClick: @escaping () -> Void
        ) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
            touchActions.singleTap = { [weak self] _, modifiers in
                guard let self else { return }
                self.window?.makeFirstResponder(nil)
                self.onSingleClick(modifiers)
            }
            touchActions.doubleTap = { [weak self] _ in self?.onDoubleClick() }
            touchActions.install(on: self, includesSingleTap: true)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            // A photo click returns keyboard navigation to the session instead
            // of leaving Space/arrows owned by the last toolbar control.
            window?.makeFirstResponder(nil)
            mouseDownLocation = convert(event.locationInWindow, from: nil)
            exceededDragThreshold = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownLocation else { return }
            let current = convert(event.locationInWindow, from: nil)
            let dx = current.x - start.x
            let dy = current.y - start.y
            if dx * dx + dy * dy >= Self.dragThresholdSquared {
                exceededDragThreshold = true
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownLocation = nil
                exceededDragThreshold = false
            }
            guard let start = mouseDownLocation else { return }
            let end = convert(event.locationInWindow, from: nil)
            let dx = end.x - start.x
            let dy = end.y - start.y
            guard !exceededDragThreshold,
                  dx * dx + dy * dy < Self.dragThresholdSquared else {
                return
            }
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onSingleClick(event.modifierFlags)
            }
        }
    }
}

/// The actions shared by the Grid's pointer and accessibility entry points.
/// Keeping them separate from the view makes the hit-target behavior directly
/// regression-testable without duplicating SessionStore mutations in tests.
@MainActor
struct GridCellActions {
    let store: SessionStore
    let index: Int
    var onPointerCurrentChange: () -> Void = {}

    func makeCurrent() {
        store.setIndex(index)
    }

    func selectPhoto(
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        store.handleThumbnailClick(at: index, modifiers: modifiers) {
            if index != store.currentIndex {
                onPointerCurrentChange()
            }
            makeCurrent()
        }
    }

    func openInGallery() {
        makeCurrent()
        store.viewMode = .gallery
    }

    /// One native Button activation always advances the rating exactly once.
    /// AppKit's click count is deliberately irrelevant: photographers often
    /// cycle rapidly, and a second/third click is still an intentional input.
    func cycleRating() {
        guard store.canRate,
              store.items.indices.contains(index)
        else {
            return
        }
        let ratesExistingSelection =
            store.selectedIndices.count > 1
            && store.selectedIndices.contains(index)
        if !ratesExistingSelection, index != store.currentIndex {
            onPointerCurrentChange()
        }
        store.toggleRating(at: index)
    }
}

/// Classifies the starting point of a Grid drag from the tile geometry already
/// needed for selection. Control locations are deterministic within each
/// square media tile, so this avoids one GeometryReader and preference value
/// per rendered control while keeping native Button drags out of rubber-band
/// selection.
enum GridRubberBandHitTest {
    /// Include the decision target and its shared corner inset.
    private static let ratingControlRegionSize = TileBadgeLayout.decisionTargetSize + TileBadgeLayout.inset
    /// Conservatively covers the native large circular Play button without
    /// making the surrounding photo difficult to use as a drag origin.
    private static let playbackControlRegionSize: CGFloat = 48

    static func shouldTrackCanvasDrag(
        startingAt point: CGPoint,
        tileFrames: [Int: CGRect],
        playableVideoIndices: Set<Int>,
        rightToLeft: Bool = false
    ) -> Bool {
        guard let (index, tileFrame) = tileFrames.first(where: {
            $0.value.contains(point)
        }) else {
            // Gaps and padding are intentional selection-canvas origins.
            return true
        }

        // GridCell's media area is a square at the top of the cell; the
        // filename beneath it remains an ordinary selection-canvas target.
        let mediaFrame = CGRect(
            x: tileFrame.minX,
            y: tileFrame.minY,
            width: tileFrame.width,
            height: tileFrame.width
        )
        guard mediaFrame.contains(point) else { return true }

        let ratingFrame = CGRect(
            x: rightToLeft ? mediaFrame.minX : mediaFrame.maxX - ratingControlRegionSize,
            y: mediaFrame.minY,
            width: ratingControlRegionSize,
            height: ratingControlRegionSize
        )
        if ratingFrame.contains(point) { return false }
        if !playableVideoIndices.contains(index) {
            let cueRegionHeight = TileBadgeLayout.cueTargetHeight + TileBadgeLayout.inset
            let cueFrame = CGRect(
                x: rightToLeft
                    ? mediaFrame.maxX - min(TileBadgeLayout.maximumCueRowWidth + TileBadgeLayout.inset, mediaFrame.width)
                    : mediaFrame.minX,
                y: mediaFrame.maxY - cueRegionHeight,
                width: min(TileBadgeLayout.maximumCueRowWidth + TileBadgeLayout.inset, mediaFrame.width),
                height: cueRegionHeight
            )
            if cueFrame.contains(point) { return false }
        }

        if playableVideoIndices.contains(index) {
            let halfPlaybackSize = playbackControlRegionSize / 2
            let playbackFrame = CGRect(
                x: mediaFrame.midX - halfPlaybackSize,
                y: mediaFrame.midY - halfPlaybackSize,
                width: playbackControlRegionSize,
                height: playbackControlRegionSize
            )
            if playbackFrame.contains(point) { return false }
        }

        return true
    }
}
