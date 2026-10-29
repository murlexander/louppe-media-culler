import SwiftUI

/// The one-photo-at-a-time Gallery view: Browser column and large photo pane.
/// SessionView owns the shared trailing Info panel so switching modes does not
/// restart its metadata and histogram work.
struct GalleryView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            if store.showBrowser {
                BrowserView(store: store,
                    initialViewportReceipt: store.pendingOpeningViewportReceipt(for: .browser).map {
                        ReviewCollectionViewportReceipt(physicalFileID: $0.physicalFileID, topOffset: CGFloat($0.topOffset))
                    },
                    onViewportRestored: { _ in store.consumeOpeningViewportReceipt(for: .browser) })
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
                        Label(L10n.text("No items match the filter"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("Change or clear filters to show media."))
                    } actions: {
                        Button(L10n.text("Clear Filters")) { store.resetFilter() }
                    }
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
                            }
                        ) { loading in
                            store.fullImageLoads += loading ? 1 : -1
                        }
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
