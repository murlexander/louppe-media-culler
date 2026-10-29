import SwiftUI

/// Each native collection cell observes this shared access token directly;
/// separately hosted collection cells do not inherit parent SwiftUI environments.
struct PhotosThumbnailView: View {
    let reference: PhotosMediaReference
    @ObservedObject private var access: PhotosMediaAccess
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var retry: UInt64 = 0
    init(reference: PhotosMediaReference) {
        self.reference = reference
        self.access = reference.session.access
    }
    var body: some View {
        GeometryReader { geometry in
            let pixels = min(1_024, max(256, Int(max(geometry.size.width, geometry.size.height) * displayScale)))
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if let failure {
                    VStack(spacing: 4) {
                        Image(systemName: "icloud.slash").foregroundStyle(.secondary)
                        Button(L10n.text("Retry")) { retry &+= 1 }.controlSize(.mini)
                        SettingsLink { Text(L10n.text("Open Settings…")) }.controlSize(.mini)
                    }
                    .help(failure)
                    .accessibilityLabel(failure)
                } else { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("Loading review image")) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: "\(reference.assetID)|\(pixels)|\(access.generation)|\(retry)") {
                image = nil; failure = nil
                do {
                    let result = try await reference.session.image(assetID: reference.assetID, pixels: pixels)
                    try Task.checkCancellation()
                    image = result.image
                } catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
        }
        .onDisappear { image = nil }
    }
}

/// A PhotoKit preview has no 100% claim. Source-pixel zoom/RAW and video use a
/// leased exact-original file and the existing bounded renderer/player.
struct PhotosGalleryView: View {
    @ObservedObject var store: SessionStore
    let item: PhotoItem
    let reference: PhotosMediaReference
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var imagePixels: CGSize = .zero
    @State private var imageFraction: Double = 0
    @State private var imageFailure: String?
    @State private var originalFailure: String?
    @State private var original: PhotosOriginalLease?
    @State private var requestedOriginal = false
    @State private var loadingOriginal = false
    @State private var retry: UInt64 = 0
    @State private var fraction: Double = 0
    private var wantsOriginal: Bool { requestedOriginal || store.zoomMode == .actual }

    var body: some View {
        GeometryReader { geometry in
            let pixels = min(PhotosMediaSession.maximumPreviewPixels,
                             Int(max(geometry.size.width, geometry.size.height) * displayScale))
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(original == nil ? previewLabel : L10n.text("Original file"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if original != nil {
                        Button(L10n.text("Use Review Preview")) { original = nil; requestedOriginal = false; store.zoomToFit() }
                    } else if loadingOriginal {
                        ProgressView(value: fraction).frame(width: 75)
                        Button(L10n.text("Cancel")) { requestedOriginal = false; store.zoomToFit(); retry &+= 1 }
                    } else {
                        Button(item.isVideo ? L10n.text("Load Original Video") : L10n.text("Open Original Detail")) {
                            requestedOriginal = true; retry &+= 1
                        }
                    }
                }
                .padding(.horizontal, 12)
                if let original {
                    originalContent(original.item)
                } else {
                    ZStack {
                        if wantsOriginal {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.arrow.down")
                                Text(loadingOriginal ? L10n.text("Loading original detail…") : L10n.text("Original detail unavailable"))
                                    .foregroundStyle(.secondary)
                            }
                        } else if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else if imageFailure == nil {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                if imageFraction > 0 {
                                    Text(L10n.text("Downloading review image: \(Int(imageFraction * 100))%"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let imageFailure, image == nil, !wantsOriginal {
                            ContentUnavailableView {
                                Label(L10n.text("Review image unavailable"), systemImage: "icloud.slash")
                            } description: { Text(imageFailure) } actions: {
                                Button(L10n.text("Retry")) { retry &+= 1 }
                                SettingsLink { Text(L10n.text("Open Settings…")) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { requestedOriginal = true; store.zoomToActual(at: .center) }
                }
                if let originalFailure {
                    HStack {
                        Text(originalFailure).font(.callout).foregroundStyle(.secondary)
                        Button(L10n.text("Retry Original")) { requestedOriginal = true; retry &+= 1 }
                        SettingsLink { Text(L10n.text("Open Settings…")) }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
            .task(id: "\(item.id)|\(pixels)|\(retry)|\(store.photosReviewGeneration)") {
                let revision = item.contentRevision
                image = nil; imageFailure = nil; imageFraction = 0
                let recorder = PhotosBatchProgressRecorder()
                let sampling = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        if let value = recorder.take() { imageFraction = value.downloadFraction }
                    }
                }
                defer { sampling.cancel() }
                do {
                    let result = try await reference.session.image(assetID: reference.assetID, pixels: pixels) { value in
                        recorder.update(PhotosBatchProgress(completed: 0, total: 1, downloadFraction: value))
                    }
                    try Task.checkCancellation()
                    guard item.contentRevision == revision else { return }
                    image = result.image; imagePixels = result.pixels
                } catch is CancellationError {} catch { if !Task.isCancelled { imageFailure = error.localizedDescription } }
            }
            // Consent changes update the session, but only an explicit action
            // retries original detail/playback after a failure.
            .task(id: "\(item.id)|\(wantsOriginal)|\(retry)") {
                originalFailure = nil
                guard wantsOriginal, original == nil else { return }
                loadingOriginal = true; fraction = 0
                let recorder = PhotosBatchProgressRecorder()
                let sampling = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        if let value = recorder.take() { fraction = value.downloadFraction }
                    }
                }
                defer { sampling.cancel(); loadingOriginal = false }
                do {
                    let lease = try await reference.session.original(for: item) { value in
                        recorder.update(PhotosBatchProgress(completed: 0, total: 1, downloadFraction: value))
                    }
                    try Task.checkCancellation()
                    original = lease
                } catch is CancellationError {} catch { if !Task.isCancelled { originalFailure = error.localizedDescription } }
            }
        }
        .onChange(of: item.contentRevision) { _, _ in
            original = nil; image = nil; imageFailure = nil; originalFailure = nil; requestedOriginal = false
        }
        .onDisappear { original = nil }
    }

    private var previewLabel: String {
        if wantsOriginal { return L10n.text("Original detail requested · review preview hidden") }
        if image != nil {
            return L10n.text("Unadjusted review preview · \(Int(imagePixels.width)) × \(Int(imagePixels.height)) pixels · not original detail")
        }
        return L10n.text("Unadjusted review preview · not original detail")
    }

    @ViewBuilder private func originalContent(_ resolved: PhotoItem) -> some View {
        if resolved.isVideo {
            GalleryVideoPlayerView(item: resolved, playback: store.videoPlayback)
        } else {
            FullImageView(item: resolved, zoomMode: $store.zoomMode,
                showsClippingWarnings: store.showClippingWarnings,
                actualSizeViewport: store.actualSizeViewport, zoomScale: store.photoZoomScale,
                onZoomToActual: { store.zoomToActual(at: $0) }, onZoomToFit: { store.zoomToFit() },
                onZoomScaleChanged: { store.reportPhotoZoomScaleFromGesture($0, ended: $1) },
                onFittedScaleMeasured: { scale, _, mode in
                    store.reportFittedPhotoZoomScale(scale, revision: item.contentRevision, mode: mode)
                },
                onZoomFromFit: { scale, position, anchor, _ in
                    store.setPhotoZoomScale(scale, at: position, viewportAnchor: anchor)
                },
                onRepresentation: { representation, _ in
                    store.reportPhotoRepresentation(representation, revision: item.contentRevision)
                }) { loading in store.fullImageLoads += loading ? 1 : -1 }
        }
    }
}
