import SwiftUI
import AppKit

private let thumbnailCornerRadius = ReviewTileMetrics.mediaCornerRadius

/// Shared visible geometry for badges in Browser and Grid tiles.
enum TileBadgeLayout {
    static let height: CGFloat = 20
    static let inset: CGFloat = 6
    static let spacing: CGFloat = 3
    static let iconSize: CGFloat = 11
    static let decisionTargetSize: CGFloat = 40
    static let cueTargetHeight: CGFloat = 36
    static let maximumCueRowWidth: CGFloat = 4 * height + 3 * spacing

    /// The Grid decision target in a photo's local, leading-to-trailing frame.
    /// It sits at the photo's top trailing corner, and on short photos (wide
    /// panoramas) it grows upward instead of below the photo, where the
    /// filename caption owns the clicks.
    static func decisionTarget(inPhoto photo: CGRect) -> CGRect {
        let bottom = min(photo.minY + inset + decisionTargetSize, photo.maxY)
        return CGRect(x: photo.maxX - inset - decisionTargetSize, y: bottom - decisionTargetSize,
                      width: decisionTargetSize, height: decisionTargetSize)
    }

    /// The visible decision badge: the photo's top trailing corner, raised
    /// above a photo too short to hold it, never over the caption below.
    static func decisionBadge(inPhoto photo: CGRect) -> CGRect {
        let top = min(photo.minY + inset, photo.maxY - height - 2)
        return CGRect(x: photo.maxX - inset - height, y: top, width: height, height: height)
    }

    /// One Browser metadata badge (stars or color label): its natural size,
    /// and the size of the form it takes when offered a narrower width.
    struct BrowserBadgeSizing {
        let ideal: CGSize
        let fitting: (CGFloat) -> CGSize
    }

    struct BrowserBadgePlan: Equatable {
        var decision: CGRect?
        var metadata: [CGRect]
        var duration: CGRect?
        /// The quality-cue button: icons and their whole 36-point target.
        var cues: CGRect?
    }

    /// Browser badge rectangles in a slot's leading-to-trailing frame.
    /// Fixed first: the decision at the media's top trailing corner, the
    /// measured duration at bottom trailing, and the measured cue button at
    /// bottom leading, its icons wrapped to stay inside the slot. With a
    /// bottom row the top row rises above a short photo (and on a very short
    /// one the bottom row drops below it), so the rows never meet. Stars and
    /// color label, in order, then avoid all of those:
    /// 1. beside the decision on the top row when both fit;
    /// 2. otherwise in a column beside a narrow portrait (leading side, then
    ///    trailing), stars stacked upright if the capsule is too wide; up to
    ///    `overhang` points past the slot if the slot's spare width is short;
    /// 3. otherwise wrapped onto the media, first full forms, then compact
    ///    ones (a color name falls back to its swatch).
    /// Nothing overlaps unless even the compact forms can't fit (last resort).
    static func browserBadges(slot: CGRect, media: CGRect, showsDecision: Bool,
                              metadata: [BrowserBadgeSizing], durationWidth: CGFloat?,
                              cues: ((CGFloat) -> CGSize)? = nil, reservesBottomRow: Bool,
                              overhang: CGFloat = 0) -> BrowserBadgePlan {
        let bottomY = media.maxY - inset - height
        var cueRect = cues.flatMap { fit -> CGRect? in
            // Up to the selection outline, but always room for two icons.
            let end = min(slot.maxX, max(media.minX + inset + 2 * height + spacing + 0.5,
                                         media.maxX - ReviewTileMetrics.selectionLineWidth))
            let size = fit(end - media.minX - inset)
            guard size.width >= 1, size.height >= 1 else { return nil }
            return CGRect(x: media.minX + inset, y: media.maxY - inset - size.height,
                          width: size.width, height: size.height)
        }
        var duration = durationWidth.map {
            CGRect(x: media.maxX - inset - $0, y: bottomY, width: $0, height: height)
        }
        let hasBottomRow = duration != nil || cueRect != nil || reservesBottomRow
        let bottomTop = min(bottomY, cueRect?.minY ?? bottomY)
        let topY = max(slot.minY, hasBottomRow
            ? min(media.minY + inset, bottomTop - spacing - height)
            : min(media.minY + inset, media.maxY - height - 2))
        // A photo too short for both rows: the bottom row drops below the top one.
        let floor = topY + height + spacing
        if let rect = cueRect, rect.minY < floor { cueRect?.origin.y = floor }
        if let rect = duration, rect.minY < floor { duration?.origin.y = floor }
        let decision = showsDecision
            ? CGRect(x: media.maxX - inset - height, y: topY, width: height, height: height) : nil
        let obstacles = [decision, duration, cueRect].compactMap { $0 }
        func isClear(_ rect: CGRect) -> Bool {
            !obstacles.contains { rect.insetBy(dx: 0.25, dy: 0.25).intersects($0) }
        }
        let start = media.minX + inset
        let rowsEnd = hasBottomRow ? bottomTop - spacing : media.maxY
        func rowY(_ row: Int) -> CGFloat { topY + CGFloat(row) * (height + spacing) }
        func rowEnd(_ row: Int) -> CGFloat {
            row == 0 ? (decision.map { $0.minX - spacing } ?? media.maxX - inset) : media.maxX - inset
        }
        func onMedia(rows: Int, compact: Bool, bounded: Bool) -> [CGRect]? {
            var ends: [CGFloat] = []
            var rects: [CGRect] = []
            for badge in metadata {
                var row = 0
                while true {
                    guard row < rows else { return nil }
                    if bounded, row > 0, rowY(row) + height > rowsEnd { return nil }
                    if row == ends.count { ends.append(start) }
                    let x = ends[row] == start ? start : ends[row] + spacing
                    var rect = CGRect(origin: CGPoint(x: x, y: rowY(row)), size: badge.ideal)
                    // Step past the cue button, duration or a badge already placed.
                    func stepPastObstacles() {
                        while let obstacle = (obstacles + rects).first(where: { rect.insetBy(dx: 0.25, dy: 0.25).intersects($0) }) {
                            rect.origin.x = obstacle.maxX + spacing
                        }
                    }
                    func compactIfNeeded() {
                        if compact, rect.maxX > rowEnd(row) { rect.size = badge.fitting(rowEnd(row) - rect.minX) }
                    }
                    compactIfNeeded()
                    stepPastObstacles()
                    compactIfNeeded()
                    stepPastObstacles()
                    let fits = rect.height <= height + 0.5 && rect.maxX <= rowEnd(row) + 0.5
                    let inColumn = rect.maxX <= slot.maxX + overhang + 0.5
                    if fits || (!bounded && row > 0 && ends[row] == start && inColumn) {
                        rects.append(rect)
                        ends[row] = rect.maxX
                        break
                    }
                    row += 1
                }
            }
            return rects
        }
        func besideMedia(trailing: Bool, overhang: CGFloat) -> [CGRect]? {
            let gutter = trailing ? slot.maxX - media.maxX : media.minX - slot.minX
            let available = gutter + overhang - spacing - (overhang > 0 ? 0 : 1)
            guard available >= height else { return nil }
            var y = topY
            var rects: [CGRect] = []
            for badge in metadata {
                let size = badge.ideal.width <= available ? badge.ideal : badge.fitting(available)
                guard size.width <= available + 0.5 else { return nil }
                var rect = CGRect(x: trailing ? media.maxX + spacing : media.minX - spacing - size.width,
                                  y: y, width: size.width, height: size.height)
                // Start below a decision wider than a very narrow photo.
                while let obstacle = obstacles.first(where: { rect.insetBy(dx: 0.25, dy: 0.25).intersects($0) }) {
                    rect.origin.y = obstacle.maxY + spacing
                }
                rects.append(rect)
                y = rect.maxY + spacing
            }
            return y - spacing <= slot.maxY + 0.5 ? rects : nil
        }
        let rects = onMedia(rows: 1, compact: false, bounded: true)
            ?? besideMedia(trailing: false, overhang: 0)
            ?? besideMedia(trailing: true, overhang: 0)
            ?? (overhang > 0 ? besideMedia(trailing: false, overhang: overhang) : nil)
            ?? (overhang > 0 ? besideMedia(trailing: true, overhang: overhang) : nil)
            ?? onMedia(rows: .max, compact: false, bounded: true)
            ?? onMedia(rows: .max, compact: true, bounded: true)
            ?? onMedia(rows: .max, compact: true, bounded: false) ?? []
        return BrowserBadgePlan(decision: decision, metadata: rects, duration: duration, cues: cueRect)
    }
}

/// Where a tile draws its badges. Grid keeps one row on the photo (the
/// contact-sheet look); Browser's short slots use `BrowserTileBadges`.
enum TileBadgePlacement: Equatable {
    case grid
    /// `reservesCueRow`: quality cues may occupy the photo's bottom leading corner.
    case browser(reservesCueRow: Bool)

    var isBrowser: Bool { self != .grid }
}

enum BrowserBadgeRole: Equatable {
    case decision, stars, label, duration, cues
}

private struct BrowserBadgeRoleKey: LayoutValueKey {
    static let defaultValue = BrowserBadgeRole.decision
}

/// Places Browser badges over the whole slot (`TileBadgeLayout.browserBadges`),
/// sharing the fitted media rectangle with `TilePhotoLayout`.
struct BrowserTileBadgeLayout: Layout {
    let imageSize: CGSize?
    let alignment: TileMediaAlignment
    let reservesBottomRow: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: ReviewCollectionMetrics.browserTileWidth,
                                                            height: ReviewCollectionMetrics.browserTileHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let media = TileMediaGeometry.fittedRect(in: bounds, imageSize: imageSize, alignment: alignment)
        let roles = subviews.map { $0[BrowserBadgeRoleKey.self] }
        let metadata = subviews.indices.filter { roles[$0] == .stars || roles[$0] == .label }
        let cueIndex = roles.firstIndex(of: .cues)
        let plan = TileBadgeLayout.browserBadges(
            slot: bounds, media: media, showsDecision: roles.contains(.decision),
            metadata: metadata.map { index in
                TileBadgeLayout.BrowserBadgeSizing(ideal: subviews[index].sizeThatFits(.unspecified)) {
                    subviews[index].sizeThatFits(ProposedViewSize(width: $0, height: nil))
                }
            },
            durationWidth: roles.firstIndex(of: .duration).map { subviews[$0].sizeThatFits(.unspecified).width },
            cues: cueIndex.map { index in { subviews[index].sizeThatFits(ProposedViewSize(width: $0, height: nil)) } },
            reservesBottomRow: reservesBottomRow,
            // Up to 4 points short of the 122-point column's edge.
            overhang: ReviewCollectionMetrics.browserHorizontalInset - 4)
        var rects: [Int: CGRect] = [:]
        for (index, rect) in zip(metadata, plan.metadata) { rects[index] = rect }
        if let index = roles.firstIndex(of: .decision) { rects[index] = plan.decision }
        if let index = roles.firstIndex(of: .duration) { rects[index] = plan.duration }
        if let cueIndex {
            rects[cueIndex] = plan.cues ?? CGRect(x: media.minX + TileBadgeLayout.inset,
                                                  y: media.maxY - TileBadgeLayout.inset, width: 0, height: 0)
        }
        for (index, subview) in subviews.enumerated() {
            guard let rect = rects[index] else { continue }
            subview.place(at: rect.origin, anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

/// Browser's decision, stars, color label, duration and quality cues, laid
/// out together so none covers another or the cues' 36-point target. Only the
/// cue button takes clicks; drags and selection belong to the media beneath.
struct BrowserTileBadges: View {
    let imageSize: CGSize?
    let alignment: TileMediaAlignment
    let reservesCueRow: Bool
    let showsDecision: Bool
    let ratingState: PhotoItemRatingState
    let starRatingState: PhotoItemStarRatingState
    let colorLabelState: PhotoItemColorLabelState
    let showsColorNames: Bool
    let duration: (TimeInterval?, MediaKind)?
    /// Interactive quality-cue icons; every other badge ignores clicks.
    var cues: AnyView?

    var body: some View {
        BrowserTileBadgeLayout(imageSize: imageSize, alignment: alignment,
                               reservesBottomRow: reservesCueRow) {
            if showsDecision {
                RatingBadge(rating: ratingState.effectiveRating, isMixed: ratingState == .mixed,
                            size: TileBadgeLayout.height)
                    .allowsHitTesting(false)
                    .browserBadgeRole(.decision)
            }
            if starRatingState != .unrated {
                ViewThatFits(in: .horizontal) {
                    TileStarBadge(state: starRatingState)
                    TileStarBadge(state: starRatingState, isVertical: true)
                }
                .foregroundStyle(.white)
                .shadow(radius: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .browserBadgeRole(.stars)
            }
            if colorLabelState != .none {
                // A long color name falls back to the swatch; VoiceOver reads
                // the label from the tile itself.
                ViewThatFits(in: .horizontal) {
                    TileColorLabelBadge(state: colorLabelState, showsName: showsColorNames)
                    TileColorLabelBadge(state: colorLabelState)
                }
                .foregroundStyle(.white)
                .shadow(radius: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .browserBadgeRole(.label)
            }
            if let duration {
                MediaDurationBadge(duration: duration.0, mediaKind: duration.1)
                    .allowsHitTesting(false)
                    .browserBadgeRole(.duration)
            }
            if let cues {
                cues.browserBadgeRole(.cues)
            }
        }
    }
}

private extension View {
    func browserBadgeRole(_ role: BrowserBadgeRole) -> some View {
        #if LOUPPE_TEST_SEAMS
        background { BrowserBadgeMarker(role: role).allowsHitTesting(false) }
            .layoutValue(key: BrowserBadgeRoleKey.self, value: role)
        #else
        layoutValue(key: BrowserBadgeRoleKey.self, value: role)
        #endif
    }
}

#if LOUPPE_TEST_SEAMS
/// Placed-badge evidence for Browser geometry tests; no release view.
struct BrowserBadgeMarker: NSViewRepresentable {
    let role: BrowserBadgeRole

    func makeNSView(context: Context) -> MarkerView { MarkerView(role: role) }
    func updateNSView(_ nsView: MarkerView, context: Context) { nsView.role = role }

    final class MarkerView: NSView {
        var role: BrowserBadgeRole
        init(role: BrowserBadgeRole) {
            self.role = role
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

/// Places the Grid decision target (first subview) and its badge (second)
/// from `TileBadgeLayout`, so layout and drag hit testing share one rule.
struct DecisionBadgeLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rects = [TileBadgeLayout.decisionTarget(inPhoto: bounds), TileBadgeLayout.decisionBadge(inPhoto: bounds)]
        for (subview, rect) in zip(subviews, rects) {
            subview.place(at: rect.origin, anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

/// A realized cell owns validated pixels even after the shared NSCache evicts
/// its entry. Only a content revision change retires those retained pixels.
struct ThumbnailImageState {
    private(set) var revision: PhotoContentRevision
    private(set) var image: NSImage?

    /// Returns whether a decode is needed. Cache misses never erase matching
    /// retained pixels, including when a lazy cell's task restarts on re-entry.
    mutating func prepare(revision: PhotoContentRevision, cached: NSImage?, hasVisualPreview: Bool) -> Bool {
        if self.revision != revision {
            self.revision = revision
            image = cached
        } else if let cached {
            image = cached
        }
        if !hasVisualPreview { image = nil }
        return hasVisualPreview && image == nil
    }

    mutating func accept(_ image: NSImage?, revision: PhotoContentRevision) {
        guard self.revision == revision else { return }
        self.image = image
    }
}

#if LOUPPE_TEST_SEAMS
/// Mounted-pixel evidence for the large-folder benchmark; no release view or
/// per-render counters. Background geometry follows the actual thumbnail tile.
struct ThumbnailRenderMarker: NSViewRepresentable {
    let revision: PhotoContentRevision
    let hasImage: Bool

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(revision: revision, hasImage: hasImage)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.revision = revision
        nsView.hasImage = hasImage
    }

    final class MarkerView: NSView {
        var revision: PhotoContentRevision
        var hasImage: Bool

        init(revision: PhotoContentRevision, hasImage: Bool) {
            self.revision = revision
            self.hasImage = hasImage
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

/// Async-loading thumbnail tile with a yes/no/undecided badge overlay.
/// The whole photo fits inside the tile (letterboxed, never cropped).
struct ThumbnailView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.mediaReadAccess) private var mediaReadAccess
    let item: PhotoItem
    var isCurrent: Bool
    /// Part of a multi-selection: same accent as the current photo, dimmed.
    var isSelected: Bool = false
    /// Grid supplies its own interactive badge above the tile's click target.
    var showsRatingBadge: Bool = true
    var videoPlayback: VideoPlaybackController?
    private let mediaAlignment: TileMediaAlignment
    private let badgePlacement: TileBadgePlacement
    private let browserCues: AnyView?
    private let tileOverlay: AnyView
    private let onImageSizeChange: ((PhotoContentRevision, CGSize?) -> Void)?
    /// Scalar projections make metadata changes visible to SwiftUI even
    /// though the PhotoItem's lock-backed storage reference stays identical.
    private let ratingState: PhotoItemRatingState
    private let starRatingState: PhotoItemStarRatingState
    private let colorLabelState: PhotoItemColorLabelState

    @State private var retainedImage: ThumbnailImageState
    /// Apple Photos tiles load through their own session, not ImagePipeline.
    @State private var photosImageSize: (revision: PhotoContentRevision, size: CGSize)?

    init(
        item: PhotoItem,
        isCurrent: Bool,
        isSelected: Bool = false,
        showsRatingBadge: Bool = true,
        videoPlayback: VideoPlaybackController? = nil,
        mediaAlignment: TileMediaAlignment = .center,
        badgePlacement: TileBadgePlacement = .grid,
        browserCues: AnyView? = nil,
        tileOverlay: AnyView = AnyView(EmptyView()),
        onImageSizeChange: ((PhotoContentRevision, CGSize?) -> Void)? = nil
    ) {
        self.item = item
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.showsRatingBadge = showsRatingBadge
        self.videoPlayback = videoPlayback
        self.mediaAlignment = mediaAlignment
        self.badgePlacement = badgePlacement
        self.browserCues = browserCues
        self.tileOverlay = tileOverlay
        self.onImageSizeChange = onImageSizeChange
        self.ratingState = item.ratingState
        self.starRatingState = item.starRatingState
        self.colorLabelState = item.colorLabelState
        let revision = item.contentRevision
        // Reappearing lazy cells should render their memory-cached image on
        // their first frame instead of flashing a placeholder and scheduling
        // an otherwise unnecessary state update.
        self._retainedImage = State(
            initialValue: ThumbnailImageState(
                revision: revision,
                image: item.hasVisualPreview
                    ? ImagePipeline.shared.cachedThumbnail(for: item)
                    : nil
            )
        )
    }

    var body: some View {
        let revision = item.contentRevision
        let displayedImage = retainedImage.revision == revision
            ? retainedImage.image
            : ImagePipeline.shared.cachedThumbnail(for: item)
        let imageSize = item.primaryFile.photosMedia != nil
            ? (photosImageSize?.revision == revision ? photosImageSize?.size : nil)
            : TileMediaGeometry.imageSize(for: item, loadedImage: displayedImage)
        TilePhotoLayout(imageSize: imageSize, alignment: mediaAlignment) {
            ZStack {
                Group {
                    if let reference = item.primaryFile.photosMedia {
                        PhotosThumbnailView(reference: reference) { size in
                            photosImageSize = (revision, size)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
                    } else if item.isText {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 28, weight: .light))
                            Text(item.fileTypeLabel)
                                .font(.system(size: 14, design: .serif))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.appBackground)
                    } else if item.isAudio, item.audioIsPlayable {
                        AudioThumbnail(item: item, adaptsToShortSlot: badgePlacement.isBrowser)
                    } else if !item.isSupported {
                        UnsupportedThumbnail(item: item)
                    } else if let displayedImage {
                        Image(nsImage: displayedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(
                                RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                            .fill(Color(nsColor: .quaternaryLabelColor))
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                if let videoPlayback, item.isVideo, item.videoIsPlayable {
                    GridVideoPlaybackOverlay(
                        item: item,
                        playback: videoPlayback
                    )
                }
            }
            .reviewTileSelectionOutline(isCurrent: isCurrent, isSelected: isSelected)
            .overlay(alignment: .topTrailing) {
                if showsRatingBadge, !badgePlacement.isBrowser {
                    RatingBadge(
                        rating: ratingState.effectiveRating,
                        isMixed: ratingState == .mixed,
                        size: TileBadgeLayout.height
                    )
                    .padding(TileBadgeLayout.inset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo || item.isAudio, !badgePlacement.isBrowser {
                    MediaDurationBadge(
                        duration: item.duration,
                        mediaKind: item.mediaKind
                    )
                        .padding(TileBadgeLayout.inset)
                }
            }
            .overlay(alignment: .topLeading) {
                if !badgePlacement.isBrowser {
                    MetadataBadgeStrip(
                        starRatingState: starRatingState,
                        colorLabelState: colorLabelState,
                        showsColorNames: differentiateWithoutColor
                    )
                        .padding(TileBadgeLayout.inset)
                }
            }
            .allowsHitTesting(showsRatingBadge)
            .accessibilityHidden(!showsRatingBadge)
            .overlay { tileOverlay }
        }
        .overlay {
            if case .browser(let reservesCueRow) = badgePlacement {
                BrowserTileBadges(
                    imageSize: imageSize, alignment: mediaAlignment, reservesCueRow: reservesCueRow,
                    showsDecision: showsRatingBadge, ratingState: ratingState,
                    starRatingState: starRatingState, colorLabelState: colorLabelState,
                    showsColorNames: differentiateWithoutColor,
                    duration: item.isVideo || item.isAudio ? (item.duration, item.mediaKind) : nil,
                    cues: browserCues)
                    .accessibilityHidden(!showsRatingBadge)
            }
        }
        .onChange(of: imageSize, initial: true) { _, size in onImageSizeChange?(revision, size) }
        .onChange(of: revision) { old, new in
            onImageSizeChange?(old, nil)
            onImageSizeChange?(new, imageSize)
        }
        .onDisappear { onImageSizeChange?(revision, nil) }
        #if LOUPPE_TEST_SEAMS
        .background {
            ThumbnailRenderMarker(revision: revision, hasImage: displayedImage != nil)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
        .task(id: revision) {
            guard item.primaryFile.photosMedia == nil else { return }
            let requestedItem = item
            let requestedRevision = requestedItem.contentRevision
            // A remounted same-revision cell already owns its pixels. Avoid a
            // cache-key rebuild and a no-op @State mutation on task re-entry.
            if retainedImage.revision == requestedRevision, retainedImage.image != nil,
               requestedItem.hasVisualPreview { return }
            let cached = requestedItem.hasVisualPreview
                ? ImagePipeline.shared.cachedThumbnail(for: requestedItem)
                : nil
            guard !Task.isCancelled else { return }
            guard retainedImage.prepare(
                revision: requestedRevision,
                cached: cached,
                hasVisualPreview: requestedItem.hasVisualPreview
            ) else { return }
            let loaded = await ImagePipeline.shared.thumbnail(
                for: requestedItem, sourceAccess: mediaReadAccess
            )
            guard !Task.isCancelled else { return }
            retainedImage.accept(loaded, revision: requestedRevision)
        }
    }
}

private struct GridVideoPlaybackOverlay: View {
    let item: PhotoItem
    @ObservedObject var playback: VideoPlaybackController

    var body: some View {
        if playback.isActive(item) {
            NativeVideoPlayer(player: playback.player, controls: .none)
                .clipShape(RoundedRectangle(cornerRadius: thumbnailCornerRadius))
                .allowsHitTesting(false)
        }
    }
}

struct MediaDurationBadge: View {
    let duration: TimeInterval?
    let mediaKind: MediaKind

    var body: some View {
        Text(MediaDurationFormat.display(duration))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(height: TileBadgeLayout.height)
            .mediaBadgeBackdrop(Capsule(), role: .glyph)
            .shadow(radius: 1)
            .accessibilityLabel(L10n.text("\(L10n.label(mediaKind.singularLabel)) duration: \(MediaDurationFormat.accessibility(duration))"))
    }
}

/// A lightweight, non-decoding tile for a playable audio file. Audio has no
/// visual preview, so keeping it out of ImagePipeline preserves the thumbnail
/// queue for photos and video first frames.
private struct AudioThumbnail: View {
    let item: PhotoItem
    /// Browser's short slot drops text rather than run it into the decision
    /// and duration badges; Grid keeps the full tile.
    var adaptsToShortSlot = false

    var body: some View {
        RoundedRectangle(cornerRadius: thumbnailCornerRadius)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay {
                if adaptsToShortSlot {
                    ViewThatFits(in: .vertical) {
                        content(lines: 2)
                        content(lines: 1)
                        content(lines: 0)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, TileBadgeLayout.inset + TileBadgeLayout.height)
                } else {
                    content(lines: 2)
                        .multilineTextAlignment(.center)
                        .padding(6)
                }
            }
    }

    private func content(lines: Int) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.louppeAccent)
            if lines > 0 {
                Text(L10n.text("Audio"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if lines > 1 {
                Text(item.fileTypeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Grey placeholder tile shown for recognised-but-unpreviewable files.
struct UnsupportedThumbnail: View {
    let item: PhotoItem

    var body: some View {
        RoundedRectangle(cornerRadius: thumbnailCornerRadius)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("File isn't supported"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.fileTypeLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(6)
            }
    }
}

/// The ✓ / ✗ / undecided / Mixed decision shown on thumbnails and in the Info panel.
struct RatingBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast
    static let yesSymbolColor = NSColor.black
    static let yesFillColor = NSColor.systemGreen
    static let noSymbolColor = NSColor.white
    static let noFillColor = NSColor.systemRed

    let rating: Rating
    var isMixed = false
    var size: CGFloat = 14

    var body: some View {
        Group {
            if isMixed {
                Image(systemName: "circle.lefthalf.filled")
                    .resizable().scaledToFit()
                    .foregroundStyle(Color.louppeAccent)
            } else {
                switch rating {
                case .yes:
                    Image(systemName: "checkmark.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(Color(nsColor: Self.yesSymbolColor), Color(nsColor: Self.yesFillColor))
                case .no:
                    Image(systemName: "xmark.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(Color(nsColor: Self.noSymbolColor), Color(nsColor: Self.noFillColor))
                case .undecided:
                    // An open ring reads as "not decided yet" without color.
                    // It stays quieter than ✓ / ✗ yet visible over photos.
                    Image(systemName: "circle")
                        .resizable().scaledToFit()
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.9))
                        .background(.black.opacity(contrast == .increased ? 0.8 : 0.4), in: Circle())
                }
            }
        }
        .font(.system(size: size, weight: .bold))
        .frame(width: size, height: size)
        .shadow(radius: 1.5)
        .accessibilityLabel(
            MediaTileAccessibility.ratingDescription(
                for: isMixed ? .mixed : ratingState
            )
        )
    }

    private var ratingState: PhotoItemRatingState {
        switch rating {
        case .yes: return .yes
        case .no: return .no
        case .undecided: return .undecided
        }
    }
}
