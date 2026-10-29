import SwiftUI

/// The Browser: an optional vertical column of thumbnails along the left edge
/// of the Gallery view, with a small gray group label above each sort group
/// (shooting day, camera, subfolder… depending on the active sort key).
struct BrowserView: View {
    /// Keep the original 122-point thumbnail column and add exactly enough
    /// room for a native non-overlay scrollbar beside it.
    static let width = 122 + PersistentVerticalScroller.gutterWidth

    @ObservedObject var store: SessionStore
    @Environment(\.locale) private var locale
    @State private var collectionController = ReviewCollectionController()
    @State private var suppressNextFollow = false
    var initialViewportReceipt: ReviewCollectionViewportReceipt? = nil
    var onViewportChange: ((ReviewCollectionViewportReceipt) -> Void)? = nil
    var onViewportRestored: ((ReviewCollectionViewportReceipt) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            BrowserCollectionContent(
                store: store,
                entries: store.browserEntries,
                viewportSize: geometry.size,
                locale: locale,
                onPlainClick: { index in
                    if index != store.currentIndex { suppressNextFollow = true }
                    store.setIndex(index)
                },
                controller: collectionController,
                groups: store.gridGroups
            )
            .equatable()
            .environment(\.mediaReadAccess, store.mediaReadAccess)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                collectionController.onViewportChange = { receipt in
                            store.recordPinnedViewport(physicalFileID: receipt.physicalFileID,
                                                       topOffset: Double(receipt.topOffset), surface: .browser)
                            onViewportChange?(receipt)
                        }
                collectionController.onViewportRestored = onViewportRestored
                if let initialViewportReceipt {
                    collectionController.restoreViewport(initialViewportReceipt)
                } else if let id = store.currentItem?.id {
                    collectionController.follow(id: id)
                }
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
}

/// Store publications update realized rows directly without reconstructing
/// the full lazy collection's identity map on each navigation or selection.
struct BrowserCollectionContent: View, Equatable {
    private struct ProjectionSource: Equatable {
        let owner: ObjectIdentifier
        let groups: [PreparedSessionIndex.VisibleGroup]
    }
    @State private var projectionCache = ReviewCollectionProjectionCache<ProjectionSource>()
    let store: SessionStore
    let entries: [PreparedSessionIndex.VisibleEntry]
    let viewportSize: CGSize
    let locale: Locale
    let onPlainClick: (Int) -> Void

    // Shared immutable storage takes Array equality's identity fast path for
    // current/selection publications. Headers still invalidate on regrouping.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store
            && lhs.viewportSize == rhs.viewportSize
            && lhs.locale == rhs.locale
            && lhs.entries == rhs.entries
            && lhs.groups == rhs.groups
    }

    var controller: ReviewCollectionController? = nil
    var groups: [PreparedSessionIndex.VisibleGroup]? = nil

    #if DEBUG
    static var didConstruct: (() -> Void)?
    static var didBuildProjection: (() -> Void)?
    static var didConstructSnapshot: ((Self) -> Void)?
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.didConstruct?()
        let _ = Self.didConstructSnapshot?(self)
        #endif
        let groups = groups ?? store.gridGroups
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
        ReviewCollection(projection: projection,
                         style: .browser, controller: controller) { entry in
            AnyView(BrowserRow(store: store, index: entry.index, id: entry.id) { onPlainClick(entry.index) })
        }
    }
}

/// One Browser strip row. It observes the store directly: the LazyVStack's
/// diff of already-created rows is not a reliable invalidation path on macOS
/// (rows froze their badges and current-photo frame until the view was
/// recreated, most visibly after Clear All Decisions), so a row must never
/// depend on the container to learn about store changes. Do not turn this
/// back into a plain value subtree.
private struct BrowserRow: View {
    @ObservedObject var store: SessionStore
    let index: Int
    let id: String
    /// Runs on an unmodified click; the parent supplies it so the
    /// suppress-follow flag stays BrowserView @State.
    let onPlainClick: () -> Void

    var body: some View {
        // The bounds check stays inside the row: it re-renders independently
        // of the parent, and visibleIndices must never outlive items.
        if store.items.indices.contains(index), store.items[index].id == id {
            let item = store.items[index]
            ThumbnailView(
                    item: item,
                    isCurrent: item.id == store.currentItem?.id,
                    isSelected: store.selectedIndices.contains(index),
                    // Read the decision in this observed row instead of
                    // hiding it inside a child whose PhotoItem storage
                    // identity does not change when the decision changes.
                    showsRatingBadge: false
                )
                .frame(width: 102, height: 102)
                .overlay(alignment: .topTrailing) {
                    RatingBadge(
                        rating: item.rating,
                        isMixed: item.hasMixedRatings,
                        size: TileBadgeLayout.height
                    )
                    .padding(TileBadgeLayout.inset)
                }
                .onTapGesture {
                    // ⇧-click: range · ⌘-click: add/remove · click: jump.
                    store.handleThumbnailClick(at: index, plainClick: onPlainClick)
                }
                .mediaTileAccessibility(
                    item: item,
                    isCurrent: item.id == store.currentItem?.id,
                    isSelected: store.selectedIndices.contains(index),
                    showActionTitle: L10n.text("Show in Gallery"),
                    show: onPlainClick,
                    open: onPlainClick,
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
                .overlay(alignment: .bottomLeading) {
                    QualityCueTileIcons(store: store, item: item)
                        .padding(TileBadgeLayout.inset)
                }
                // Stable ID also retires thumbnail state when a reuse host rebinds.
                .id(item.id)
                .contextMenu {
                    MediaTileContextMenu(store: store, index: index, revision: item.contentRevision, open: onPlainClick)
                }
        }
    }
}
