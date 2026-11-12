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
}

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
        tileOverlay: AnyView = AnyView(EmptyView()),
        onImageSizeChange: ((PhotoContentRevision, CGSize?) -> Void)? = nil
    ) {
        self.item = item
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.showsRatingBadge = showsRatingBadge
        self.videoPlayback = videoPlayback
        self.mediaAlignment = mediaAlignment
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
                        AudioThumbnail(item: item)
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
                if showsRatingBadge {
                    RatingBadge(
                        rating: ratingState.effectiveRating,
                        isMixed: ratingState == .mixed,
                        size: TileBadgeLayout.height
                    )
                    .padding(TileBadgeLayout.inset)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo || item.isAudio {
                    MediaDurationBadge(
                        duration: item.duration,
                        mediaKind: item.mediaKind
                    )
                        .padding(TileBadgeLayout.inset)
                }
            }
            .overlay(alignment: .topLeading) {
                MetadataBadgeStrip(
                    starRatingState: starRatingState,
                    colorLabelState: colorLabelState,
                    showsColorNames: differentiateWithoutColor
                )
                    .padding(TileBadgeLayout.inset)
            }
            .allowsHitTesting(showsRatingBadge)
            .accessibilityHidden(!showsRatingBadge)
            .overlay { tileOverlay }
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

    var body: some View {
        RoundedRectangle(cornerRadius: thumbnailCornerRadius)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .overlay {
                VStack(spacing: 7) {
                    Image(systemName: "waveform")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color.louppeAccent)
                    Text(L10n.text("Audio"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.fileTypeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(6)
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
