import SwiftUI
import AppKit

private let thumbnailCornerRadius: CGFloat = 6

/// Async-loading thumbnail tile with a yes/no/undecided badge overlay.
/// The whole photo fits inside the tile (letterboxed, never cropped).
struct ThumbnailView: View {
    let item: PhotoItem
    var isCurrent: Bool
    /// Part of a multi-selection: same accent as the current photo, dimmed.
    var isSelected: Bool = false
    /// Grid supplies its own interactive badge above the tile's click target.
    var showsRatingBadge: Bool = true
    var videoPlayback: VideoPlaybackController?
    /// Scalar projections make metadata changes visible to SwiftUI even
    /// though the PhotoItem's lock-backed storage reference stays identical.
    private let ratingState: PhotoItemRatingState
    private let starRatingState: PhotoItemStarRatingState
    private let colorLabelState: PhotoItemColorLabelState

    @State private var image: NSImage?
    @State private var imageRevision: PhotoContentRevision

    init(
        item: PhotoItem,
        isCurrent: Bool,
        isSelected: Bool = false,
        showsRatingBadge: Bool = true,
        videoPlayback: VideoPlaybackController? = nil
    ) {
        self.item = item
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.showsRatingBadge = showsRatingBadge
        self.videoPlayback = videoPlayback
        self.ratingState = item.ratingState
        self.starRatingState = item.starRatingState
        self.colorLabelState = item.colorLabelState
        let revision = item.contentRevision
        self._imageRevision = State(initialValue: revision)
        // Reappearing lazy cells should render their memory-cached image on
        // their first frame instead of flashing a placeholder and scheduling
        // an otherwise unnecessary state update.
        self._image = State(
            initialValue: item.hasVisualPreview
                ? ImagePipeline.shared.cachedThumbnail(for: item)
                : nil
        )
    }

    var body: some View {
        let revision = item.contentRevision
        let displayedImage = imageRevision == revision
            ? image
            : ImagePipeline.shared.cachedThumbnail(for: item)
        ZStack {
            Group {
                if item.isText {
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
        .overlay {
            RoundedRectangle(cornerRadius: thumbnailCornerRadius)
                .strokeBorder(borderColor, lineWidth: 3)
        }
        .overlay(alignment: .topTrailing) {
            if showsRatingBadge {
                RatingBadge(
                    rating: ratingState.effectiveRating,
                    isMixed: ratingState == .mixed
                )
                .padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.isVideo || item.isAudio {
                MediaDurationBadge(
                    duration: item.duration,
                    mediaKind: item.mediaKind
                )
                    .padding(4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            MetadataBadgeStrip(
                starRatingState: starRatingState,
                colorLabelState: colorLabelState
            )
                .padding(4)
        }
        .task(id: revision) {
            let requestedItem = item
            let requestedRevision = requestedItem.contentRevision
            let cached = requestedItem.hasVisualPreview
                ? ImagePipeline.shared.cachedThumbnail(for: requestedItem)
                : nil
            image = cached
            imageRevision = requestedRevision
            guard requestedItem.hasVisualPreview, cached == nil else { return }
            let loaded = await ImagePipeline.shared.thumbnail(
                for: requestedItem
            )
            guard !Task.isCancelled,
                  imageRevision == requestedRevision else { return }
            image = loaded
        }
    }

    private var borderColor: Color {
        if isCurrent { return .louppeAccent }
        if isSelected { return .louppeAccent.opacity(0.45) }
        return .clear
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
            .padding(.vertical, 3)
            .background(.black.opacity(0.68), in: Capsule())
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
    let rating: Rating
    var isMixed = false
    var size: CGFloat = 14

    var body: some View {
        Group {
            if isMixed {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(Color.louppeAccent)
            } else {
                switch rating {
                case .yes:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                case .no:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .red)
                case .undecided:
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .opacity(0.85)
                }
            }
        }
        .font(.system(size: size, weight: .bold))
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
