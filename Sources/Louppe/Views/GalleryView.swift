import SwiftUI

/// The one-photo-at-a-time Gallery view: Browser column and large photo pane.
/// SessionView owns the shared trailing Info panel so switching modes does not
/// restart its metadata and histogram work.
struct GalleryView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            if store.showBrowser {
                BrowserView(store: store)
                    .frame(width: BrowserView.width)
                    .background(Color.appBackground)
                    .transition(.move(edge: .leading))
            }

            ZStack {
                Color.appBackground
                if store.items.isEmpty {
                    SessionEmptyView(
                        reason: store.emptySessionReason,
                        canUndo: store.canUndo
                    )
                } else if store.visibleIndices.isEmpty && store.isGroupedReviewActive {
                    ContentUnavailableView(
                        store.groupedReviewEmptyTitle,
                        systemImage: "rectangle.3.group",
                        description: Text(store.groupedReviewEmptyDescription)
                    )
                } else if store.visibleIndices.isEmpty && store.filter.isActive {
                    ContentUnavailableView {
                        Label("No items match the filter", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try different choices or clear the filters to see media again.")
                    } actions: {
                        Button("Clear Filters") { store.resetFilter() }
                    }
                } else if let item = store.currentItem {
                    if item.isText {
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
                            }
                        ) { loading in
                            store.fullImageLoads += loading ? 1 : -1
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
        }
        .background(SessionRenderMarker(kind: .gallery))
    }
}
