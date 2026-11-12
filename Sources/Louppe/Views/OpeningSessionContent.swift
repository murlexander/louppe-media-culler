import SwiftUI
import AppKit

/// SessionView's main content while a large folder opens: the Ready layout
/// (Browser, fitted photo or Grid, Info) over the immutable opening inventory.
/// It holds no store reference; SessionView passes in the view preferences.
/// Ratings, file work and Ready-only media pipelines wait for publication.
struct OpeningSessionContent: View {
    @ObservedObject var state: OpeningSessionState
    let showsBrowser: Bool
    let showsInfo: Bool
    let gridThumbnailSize: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if state.viewMode == .gallery, showsBrowser {
                OpeningCollection(state: state, surface: .browser, thumbnailSize: gridThumbnailSize)
                    .frame(width: BrowserView.width)
                Divider()
            }
            Group {
                if state.viewMode == .grid {
                    OpeningCollection(state: state, surface: .grid, thumbnailSize: gridThumbnailSize)
                } else if let item = state.currentItem {
                    OpeningPhotoView(item: item, sourceAccess: state.sourceAccess, fitted: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.displayName)
                        .accessibilityAddTraits(.isImage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if showsInfo, let item = state.currentItem {
                Divider()
                OpeningDetails(item: item, isReady: state.metadataIsReady(for: item.id))
                    .frame(width: SessionView.infoPanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.appBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openingSession")
    }
}

/// Ready's centered toolbar status, showing opening progress instead.
struct OpeningSessionStatus: View {
    @ObservedObject var state: OpeningSessionState

    private var title: String {
        L10n.text(state.isCached ? "Checking folder…" : "Loading photo details…")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                // Cached observations may omit files, so their count would mislead.
                if !state.isCached {
                    Text(verbatim: "\(L10n.number(state.readyMetadataCount)) / \(L10n.number(state.items.count))")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            SessionActivityIndicator(isActive: true, label: title)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The same fixed toolbar spinner used by photo loading and review work.
struct SessionActivityIndicator: View {
    let isActive: Bool
    let label: String

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isActive ? 1 : 0)
            .accessibilityLabel(label)
            .accessibilityHidden(!isActive)
    }
}

/// MetadataPanel's layout over scan-time fields only. MetadataPanel itself
/// is not mounted: its tasks start detail, histogram and audio reads.
/// Contents stay greyed (secondary/tertiary text) until Ready.
private struct OpeningDetails: View {
    let item: PhotoItem
    let isReady: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !isReady {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Loading photo details…"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Divider()
                    ForEach(MetadataExtractor.openingFields(for: item).filter { $0.label != "Filename" }) { field in
                        LabeledReadout(label: L10n.label(field.label), labelStyle: .tertiary) {
                            Text(verbatim: field.value)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Plain Text ignores `.disabled`; one step down the system
                // hierarchy (primary→secondary→tertiary) greys it until Ready.
                .disabled(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .accessibilityIdentifier("openingDetails")
    }
}

private struct OpeningCollection: View {
    @ObservedObject var state: OpeningSessionState
    let surface: OpeningViewportSurface
    let thumbnailSize: CGFloat
    @State private var controller = ReviewCollectionController()

    var body: some View {
        GeometryReader { geometry in
            OpeningCollectionContent(state: state, surface: surface, thumbnailSize: thumbnailSize,
                                     controller: controller)
            .equatable()
            .onAppear {
                controller.onViewportChange = { receipt in
                    state.recordViewport(OpeningViewportReceipt(surface: surface,
                        physicalFileID: receipt.physicalFileID, topOffset: Double(receipt.topOffset)), userInitiated: false)
                }
                controller.onUserViewportChange = { receipt in
                    state.recordViewport(OpeningViewportReceipt(surface: surface,
                        physicalFileID: receipt.physicalFileID, topOffset: Double(receipt.topOffset)))
                }
                if let id = state.currentItem?.id { controller.follow(id: id) }
                updateColumns(width: geometry.size.width)
            }
            .onChange(of: geometry.size.width) { _, width in updateColumns(width: width) }
            .onChange(of: thumbnailSize) { _, _ in updateColumns(width: geometry.size.width) }
            .onChange(of: state.currentItem?.id) { controller.currentID = state.currentItem?.id }
            .onChange(of: state.keyboardNavigationGeneration) {
                if let id = state.currentItem?.id { controller.follow(id: id) }
            }
        }
    }

    private func updateColumns(width: CGFloat) {
        guard surface == .grid else { return }
        state.setGridColumnCount(ReviewCollectionMetrics.gridColumnCount(
            paneWidth: width, thumbnailSize: thumbnailSize
        ))
    }
}

private struct OpeningCollectionContent: View, Equatable {
    let state: OpeningSessionState
    let surface: OpeningViewportSurface
    let thumbnailSize: CGFloat
    let controller: ReviewCollectionController

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state && lhs.surface == rhs.surface && lhs.thumbnailSize == rhs.thumbnailSize
    }

    var body: some View {
        let entries = state.items.enumerated().map { index, item in
            ReviewCollectionEntry(id: item.id, index: index, physicalFileIDs: item.individualFiles.map(\.id))
        }
        let projection = ReviewCollectionProjection(sections: [ReviewCollectionSection(id: "opening", title: nil, entries: entries)])
        ReviewCollection(projection: projection,
                         style: surface == .browser ? .browser : .grid(thumbnailSize: thumbnailSize),
                         controller: controller) { entry in
            if state.items.indices.contains(entry.index) {
                AnyView(OpeningCell(state: state, item: state.items[entry.index], surface: surface))
            } else {
                AnyView(EmptyView())
            }
        }
    }
}

private struct OpeningCell: View {
    @ObservedObject var state: OpeningSessionState
    let item: PhotoItem
    let surface: OpeningViewportSurface

    var body: some View {
        let isSelected = state.selectedIDs.contains(item.id)
        VStack(spacing: ReviewCollectionMetrics.captionSpacing) {
            OpeningPhotoView(item: item, sourceAccess: state.sourceAccess, fitted: false,
                             isCurrent: state.currentItem?.id == item.id, isSelected: isSelected,
                             mediaAlignment: surface == .grid ? .bottom : .center,
                             showsRatingBadge: true)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
            if surface == .grid { ReviewGridCaption(title: item.displayName) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.select(item.id); state.viewMode = .gallery }
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            state.select(item.id, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        }
        .mediaTileAccessibility(
            item: item,
            isCurrent: state.currentItem?.id == item.id,
            isSelected: isSelected,
            showActionTitle: surface == .grid ? L10n.text("Make Current") : L10n.text("Show in Gallery"),
            show: { state.select(item.id) },
            open: { state.select(item.id); state.viewMode = .gallery },
            canRate: false,
            rate: { _ in },
            setStars: { _ in },
            setColor: { _ in },
            toggleSelection: { state.select(item.id, toggling: true) }
        )
    }
}

/// Independent thumbnail and Fit requests use bounded existing queues. No
/// dimensions, RAW recipe, 100% tiles, playback or text I/O starts here.
private struct OpeningPhotoView: View {
    let item: PhotoItem
    let sourceAccess: MediaReadAccess?
    let fitted: Bool
    var isCurrent = false
    var isSelected = false
    let mediaAlignment: TileMediaAlignment
    let showsRatingBadge: Bool
    @State private var thumbnail: ThumbnailImageState
    @State private var full: ThumbnailImageState
    @State private var didFinish = false

    init(item: PhotoItem, sourceAccess: MediaReadAccess?, fitted: Bool,
         isCurrent: Bool = false, isSelected: Bool = false,
         mediaAlignment: TileMediaAlignment = .center, showsRatingBadge: Bool = false) {
        self.item = item
        self.sourceAccess = sourceAccess
        self.fitted = fitted
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.mediaAlignment = mediaAlignment
        self.showsRatingBadge = showsRatingBadge
        _thumbnail = State(initialValue: .init(revision: item.contentRevision,
                                               image: ImagePipeline.shared.cachedThumbnail(for: item)))
        _full = State(initialValue: .init(revision: item.contentRevision,
                                          image: fitted ? ImagePipeline.shared.cachedFullImage(for: item) : nil))
    }

    private var canDecode: Bool { item.mediaKind == .photo && item.isSupported }
    private var image: NSImage? {
        if fitted, full.revision == item.contentRevision, let image = full.image { return image }
        return thumbnail.revision == item.contentRevision ? thumbnail.image : nil
    }

    private var media: some View {
        ZStack {
            if !fitted, image == nil {
                RoundedRectangle(cornerRadius: ReviewTileMetrics.mediaCornerRadius)
                    .fill(Color(nsColor: .quaternaryLabelColor))
            } else {
                Color.appBackground
            }
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: item.mediaKind == .photo ? "photo" : "doc")
                        .font(.title2).foregroundStyle(.secondary)
                    if fitted {
                        Text(L10n.text(canDecode && didFinish ? "Preview unavailable" : "Loading photo details…"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: fitted ? 0 : ReviewTileMetrics.mediaCornerRadius))
    }

    var body: some View {
        Group {
            if fitted {
                media
            } else {
                // Ready's tile placement and outline: around the fitted media.
                TilePhotoLayout(imageSize: TileMediaGeometry.imageSize(for: item, loadedImage: image),
                                alignment: mediaAlignment) {
                    media
                        .reviewTileSelectionOutline(isCurrent: isCurrent, isSelected: isSelected)
                        .overlay(alignment: .topTrailing) {
                            if showsRatingBadge {
                                // Informational saved decision, never an interactive control.
                                RatingBadge(rating: item.rating, isMixed: item.hasMixedRatings,
                                            size: TileBadgeLayout.height)
                                    .padding(TileBadgeLayout.inset)
                            }
                        }
                }
            }
        }
        .background {
            #if LOUPPE_TEST_SEAMS
            ThumbnailRenderMarker(revision: item.contentRevision, hasImage: image != nil)
            #endif
        }
        .task(id: item.contentRevision) {
            let revision = item.contentRevision
            guard canDecode else { return }
            let image = await ImagePipeline.shared.thumbnail(for: item, sourceAccess: sourceAccess)
            guard !Task.isCancelled else { return }
            _ = thumbnail.prepare(revision: revision, cached: nil, hasVisualPreview: true)
            thumbnail.accept(image, revision: revision)
            if !fitted { didFinish = true }
        }
        .task(id: item.contentRevision) {
            let revision = item.contentRevision
            guard fitted, canDecode else { return }
            let image = await ImagePipeline.shared.fullImage(for: item, sourceAccess: sourceAccess)
            guard !Task.isCancelled else { return }
            _ = full.prepare(revision: revision, cached: nil, hasVisualPreview: true)
            full.accept(image, revision: revision)
            didFinish = true
        }
    }
}
