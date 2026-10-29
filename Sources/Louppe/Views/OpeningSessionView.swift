import SwiftUI
import AppKit

/// Temporary browse surface: immutable inventory, fitted photos and local
/// selection only. SessionView and its mutation/shortcut machinery mount at Ready.
struct OpeningSessionView: View {
    @ObservedObject var state: OpeningSessionState
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.text("Loading photo details…"))
                    .font(.callout)
                Text("\(state.readyMetadataCount)/\(state.items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Picker(L10n.text("View"), selection: $state.viewMode) {
                    Text(L10n.text("Gallery")).tag(ViewMode.gallery)
                    Text(L10n.text("Grid")).tag(ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button(L10n.text("Cancel"), action: cancel)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                if state.viewMode == .grid {
                    OpeningCollection(state: state, surface: .grid)
                } else {
                    HStack(spacing: 0) {
                        OpeningCollection(state: state, surface: .browser)
                            .frame(width: BrowserView.width)
                        Divider()
                        if let item = state.currentItem {
                            VStack(spacing: 8) {
                                OpeningPhotoView(item: item, sourceAccess: state.sourceAccess, fitted: true)
                                Text(item.displayName).font(.callout).lineLimit(1)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                if let item = state.currentItem {
                    Divider()
                    OpeningDetails(item: item, isReady: state.metadataIsReady(for: item.id))
                        .frame(width: 250)
                }
            }
        }
        .background(Color.appBackground)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: state.moveCurrent(by: -1)
            case .right: state.moveCurrent(by: 1)
            case .up: state.moveCurrent(by: state.viewMode == .grid ? -state.gridColumnCount : -1)
            case .down: state.moveCurrent(by: state.viewMode == .grid ? state.gridColumnCount : 1)
            @unknown default: break
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: "Louppe").font(.headline)
            }
        }
        .accessibilityIdentifier("openingSession")
    }
}

private struct OpeningDetails: View {
    let item: PhotoItem
    let isReady: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                if !isReady {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Loading photo details…")).font(.callout)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(MetadataExtractor.openingFields(for: item)) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.label(field.label)).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: field.value).font(.callout).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityIdentifier("openingDetails")
    }
}

private struct OpeningCollection: View {
    @ObservedObject var state: OpeningSessionState
    let surface: OpeningViewportSurface
    @State private var controller = ReviewCollectionController()

    var body: some View {
        GeometryReader { geometry in
            OpeningCollectionContent(state: state, surface: surface, controller: controller)
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
            .onChange(of: state.keyboardNavigationGeneration) {
                if let id = state.currentItem?.id { controller.follow(id: id) }
            }
        }
    }

    private func updateColumns(width: CGFloat) {
        guard surface == .grid else { return }
        let content = max(1, width - PersistentVerticalScroller.gutterWidth - 18)
        state.setGridColumnCount(max(1, Int((content + 10) / 180)))
    }
}

private struct OpeningCollectionContent: View, Equatable {
    let state: OpeningSessionState
    let surface: OpeningViewportSurface
    let controller: ReviewCollectionController

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state === rhs.state && lhs.surface == rhs.surface
    }

    var body: some View {
        let entries = state.items.enumerated().map { index, item in
            ReviewCollectionEntry(id: item.id, index: index, physicalFileIDs: item.individualFiles.map(\.id))
        }
        let projection = ReviewCollectionProjection(sections: [ReviewCollectionSection(id: "opening", title: nil, entries: entries)])
        ReviewCollection(projection: projection,
                         style: surface == .browser ? .browser : .grid(thumbnailSize: 170),
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
        VStack(spacing: 3) {
            OpeningPhotoView(item: item, sourceAccess: state.sourceAccess, fitted: false)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    // Informational saved decision, never an interactive control.
                    RatingBadge(rating: item.rating, isMixed: item.hasMixedRatings,
                                size: TileBadgeLayout.height)
                        .padding(TileBadgeLayout.inset)
                }
            if surface == .grid { ReviewGridCaption(title: item.displayName) }
        }
        .background(state.selectedIDs.contains(item.id) ? Color.louppeAccent.opacity(0.12) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(state.currentItem?.id == item.id ? Color.louppeAccent : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.select(item.id); state.viewMode = .gallery }
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            state.select(item.id, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state.selectedIDs.contains(item.id) ? .isSelected : [])
    }
}

/// Independent thumbnail and Fit requests use bounded existing queues. No
/// dimensions, RAW recipe, 100% tiles, playback or text I/O starts here.
private struct OpeningPhotoView: View {
    let item: PhotoItem
    let sourceAccess: MediaReadAccess?
    let fitted: Bool
    @State private var thumbnail: ThumbnailImageState
    @State private var full: ThumbnailImageState
    @State private var didFinish = false

    init(item: PhotoItem, sourceAccess: MediaReadAccess?, fitted: Bool) {
        self.item = item
        self.sourceAccess = sourceAccess
        self.fitted = fitted
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

    var body: some View {
        ZStack {
            Color.appBackground
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .background {
            #if DEBUG
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
