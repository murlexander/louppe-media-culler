import SwiftUI

/// The one-photo-at-a-time Gallery view: Browser column and large photo pane.
/// SessionView owns the shared trailing Info panel so switching modes does not
/// restart its metadata and histogram work.
struct GalleryView: View {
    @ObservedObject var store: SessionStore
    /// Tests substitute a gated pipeline; the app always uses the shared one.
    var imagePipeline = ImagePipeline.shared

    var body: some View {
        HStack(spacing: 0) {

            ZStack {
                Color.appBackground
                if let emptyState = ReviewEmptyState(store: store) {
                    ReviewEmptyStateView(store: store, state: emptyState)
                } else if let item = store.currentItem {
                    if let reference = item.primaryFile.photosMedia {
                        PhotosGalleryView(store: store, item: item, reference: reference)
                    } else if item.isText {
                        TextPreviewView(item: item)
                            .id(item.contentRevision)
                    } else if item.isVideo {
                        GalleryVideoPlayerView(item: item, playback: store.videoPlayback)
                    } else if item.isAudio {
                        GalleryAudioPlayerView(item: item, playback: store.videoPlayback)
                    } else {
                        FullImageView(
                            item: item,
                            zoomMode: $store.zoomMode,
                            showsClippingWarnings:
                                store.showClippingWarnings
                                && store.selectedIndices.count <= 1,
                            actualSizeViewport: store.actualSizeViewport,
                            zoomScale: store.photoZoomScale,
                            onZoomToActual: { position in
                                store.zoomToActual(at: position)
                            },
                            onZoomToFit: {
                                store.zoomToFit()
                            },
                            onZoomScaleChanged: { scale, ended in
                                store.reportPhotoZoomScaleFromGesture(
                                    scale, ended: ended
                                )
                            },
                            onFittedScaleMeasured: { scale, revision, mode in
                                store.reportFittedPhotoZoomScale(
                                    scale, revision: revision, mode: mode
                                )
                            },
                            onZoomFromFit: { scale, position, anchor, revision in
                                guard store.currentItem?.contentRevision == revision
                                else { return }
                                store.setPhotoZoomScale(
                                    scale,
                                    at: position,
                                    viewportAnchor: anchor
                                )
                            },
                            onRepresentation: { representation, revision in
                                store.reportPhotoRepresentation(representation, revision: revision)
                            },
                            onLoading: { loading in
                                store.fullImageLoads += loading ? 1 : -1
                            },
                            imagePipeline: imagePipeline
                        )
                    }
                } else if !store.visibleIndices.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.text("Choose a matching item"), systemImage: "photo")
                    } description: {
                        Text(L10n.text("Checks found matching photos. Select one to continue reviewing."))
                    } actions: {
                        Button(L10n.text("Make Current")) {
                            if let first = store.visibleIndices.first { store.setIndex(first) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !store.visibleIndices.isEmpty,
                   let item = store.currentItem,
                   item.supportsPhotoInspection {
                    PhotoZoomControl(store: store)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 16)
                }
            }
            .clipped()
        }
        .background(SessionRenderMarker(kind: .gallery))
    }
}
