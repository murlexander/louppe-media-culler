import SwiftUI
import AppKit

/// The big central image in the Gallery view, with fit / 100% / phone-size zoom.
struct FullImageView: View {
    private static let navigationDebounceNanoseconds: UInt64 = 40_000_000
    @Environment(\.openWindow) private var openWindow
    @AppStorage(RawDisplayMode.preferenceKey) private var rawDisplayMode = RawDisplayMode.fast
    @AppStorage(AppleRawDecoder.preferenceKey) private var rawDecoder = AppleRawDecoder.appleDefault

    let item: PhotoItem
    @Binding var zoomMode: ZoomMode
    let showsClippingWarnings: Bool
    let actualSizeViewport: ActualSizeViewport
    let zoomScale: CGFloat
    /// Fit/phone-size double-click asks the store to enter 100% at this point.
    let onZoomToActual: (NormalizedImagePosition) -> Void
    /// A second double-click in 100% asks the store to return to Fit.
    let onZoomToFit: () -> Void
    let onZoomScaleChanged: (CGFloat, Bool) -> Void
    let onFittedScaleMeasured: (CGFloat, PhotoContentRevision, ZoomMode) -> Void
    let onZoomFromFit: (CGFloat, NormalizedImagePosition, CGPoint, PhotoContentRevision) -> Void
    /// Reports decode start/finish upward — the toolbar shows a small spinner
    /// there instead of flashing one in the middle of the photo area.
    var onLoading: (Bool) -> Void
    let onRepresentation: (PhotoRepresentation, PhotoContentRevision) -> Void

    @State private var image: NSImage?
    @State private var loadedDisplayMode = RawDisplayMode.fast
    @State private var loadedDecoder = AppleRawDecoder.appleDefault
    @State private var fallbackRevision: PhotoContentRevision?
    @State private var actualRenderingFailed = false
    @State private var clippingImage: NSImage?
    /// Low-res stand-in (the Browser thumbnail) shown while the real
    /// decode runs, so switching photos never flashes an empty pane.
    @State private var preview: NSImage?
    @State private var failedToLoad = false
    @State private var previewRetryGeneration: UInt64 = 0
    @State private var fittedPinchGeneration: UInt64 = 0
    @State private var fittedPinchResetGeneration: UInt64 = 0
    @State private var imageRevision: PhotoContentRevision
    @State private var clippingDisplayMode = RawDisplayMode.fast
    @State private var clippingDecoder = AppleRawDecoder.appleDefault
    @State private var clippingRevision: PhotoContentRevision

    private struct ClippingLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isEnabled: Bool
        let mode: RawDisplayMode
        let decoder: AppleRawDecoder
    }

    private struct PreviewLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let retryGeneration: UInt64
        let mode: RawDisplayMode
        let decoder: AppleRawDecoder
    }

    private var displayMode: RawDisplayMode {
        fallbackRevision == item.contentRevision ? .fast : rawDisplayMode
    }

    init(
        item: PhotoItem,
        zoomMode: Binding<ZoomMode>,
        showsClippingWarnings: Bool = false,
        actualSizeViewport: ActualSizeViewport,
        zoomScale: CGFloat = 1,
        onZoomToActual: @escaping (NormalizedImagePosition) -> Void,
        onZoomToFit: @escaping () -> Void,
        onZoomScaleChanged: @escaping (CGFloat, Bool) -> Void = { _, _ in },
        onFittedScaleMeasured: @escaping (CGFloat, PhotoContentRevision, ZoomMode) -> Void = { _, _, _ in },
        onZoomFromFit: @escaping (CGFloat, NormalizedImagePosition, CGPoint, PhotoContentRevision) -> Void = { _, _, _, _ in },
        onRepresentation: @escaping (PhotoRepresentation, PhotoContentRevision) -> Void = { _, _ in },
        onLoading: @escaping (Bool) -> Void = { _ in }
    ) {
        self.item = item
        self._zoomMode = zoomMode
        self.showsClippingWarnings = showsClippingWarnings
        self.actualSizeViewport = actualSizeViewport
        self.zoomScale = zoomScale
        self.onZoomToActual = onZoomToActual
        self.onZoomToFit = onZoomToFit
        self.onZoomScaleChanged = onZoomScaleChanged
        self.onFittedScaleMeasured = onFittedScaleMeasured
        self.onZoomFromFit = onZoomFromFit
        self.onLoading = onLoading
        self.onRepresentation = onRepresentation
        let revision = item.contentRevision
        self._imageRevision = State(initialValue: revision)
        self._clippingRevision = State(initialValue: revision)
        // Seed from the in-memory caches — synchronous dictionary lookups,
        // nothing is decoded here. Prefetched neighbours appear instantly at
        // full quality; anything else starts from its thumbnail.
        guard item.isSupported else { return }
        let mode = RawDisplayMode(rawValue: UserDefaults.standard.string(forKey: RawDisplayMode.preferenceKey) ?? "") ?? .fast
        let decoder = AppleRawDecoder.load()
        self._loadedDecoder = State(initialValue: decoder)
        self._clippingDecoder = State(initialValue: decoder)
        self._loadedDisplayMode = State(initialValue: mode)
        self._clippingDisplayMode = State(initialValue: mode)
        let cachedFull = ImagePipeline.shared.cachedFullImage(for: item, mode: mode, decoder: decoder)
        self._image = State(initialValue: cachedFull)
        self._clippingImage = State(
            initialValue: ClippingPreviewPipeline.shared.cachedImage(for: item, mode: mode, decoder: decoder)
        )
        if cachedFull == nil, !mode.rendersRAW(for: item) {
            self._preview = State(initialValue: ImagePipeline.shared.cachedThumbnail(for: item))
        }
    }

    var body: some View {
        let contentRevision = item.contentRevision
        let mode = displayMode
        let rendersRAW = mode.rendersRAW(for: item)
        let currentLoad = imageRevision == contentRevision && loadedDisplayMode == mode && loadedDecoder == rawDecoder
        let displayedImage = currentLoad
            ? image
            : ImagePipeline.shared.cachedFullImage(for: item, mode: mode, decoder: rawDecoder)
        let displayedPreview = rendersRAW ? nil : currentLoad
            ? preview
            : ImagePipeline.shared.cachedThumbnail(for: item)
        let displayedClippingImage = clippingRevision == contentRevision && clippingDisplayMode == mode && clippingDecoder == rawDecoder
            ? clippingImage
            : ClippingPreviewPipeline.shared.cachedImage(for: item, mode: mode, decoder: rawDecoder)
        let presentationImage = showsClippingWarnings
            ? displayedClippingImage ?? displayedImage
            : displayedImage
        let presentationPreview = showsClippingWarnings
            ? displayedClippingImage ?? displayedPreview
            : displayedPreview
        Group {
            if !item.isSupported {
                ContentUnavailableView {
                    Label(L10n.text("File isn't supported"), systemImage: "doc.questionmark")
                } description: {
                    Text(L10n.text("No preview for \(item.fileTypeLabel). You can still rate it — \(item.displayName)"))
                } actions: {
                    Button(L10n.text("Show in Finder")) { showInFinder() }
                    Button(L10n.text("Supported Formats")) {
                        openWindow(id: LouppeHelpWindow.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch zoomMode {
                case .actual:
                    ActualSizeImageView(
                        item: item,
                        preview: presentationImage ?? presentationPreview,
                        showsClippingWarnings: showsClippingWarnings,
                        viewport: actualSizeViewport,
                        onDoubleClick: onZoomToFit,
                        onLoading: onLoading,
                        zoomScale: zoomScale,
                        onZoomScaleChanged: onZoomScaleChanged,
                        previewIsRAW: rendersRAW,
                        decoder: rawDecoder,
                        retryGeneration: previewRetryGeneration,
                        onRenderingFailure: { failed in actualRenderingFailed = failed },
                        onRepresentation: { representation in
                            guard zoomMode == .actual else { return }
                            onRepresentation(representation, contentRevision)
                        }
                    )
                case .fit where presentationImage != nil:
                    if let presentationImage {
                        ZoomableFittedImage(
                            item: item,
                            mode: .fit,
                            image: presentationImage,
                            decoder: rawDecoder,
                            pinchResetGeneration: fittedPinchResetGeneration,
                            onMeasuredScale: onFittedScaleMeasured,
                            onDoubleClick: onZoomToActual,
                            onMagnify: { position, anchor, factor, size, backingScale in
                                magnifyFittedImage(
                                    at: position,
                                    viewportAnchor: anchor,
                                    factor: factor,
                                    containerSize: size,
                                    backingScale: backingScale,
                                    maximumSize: nil
                                )
                            }
                        )
                    }
                case .small where presentationImage != nil:
                    if let presentationImage {
                        ZoomableFittedImage(
                            item: item,
                            mode: .small,
                            image: presentationImage,
                            decoder: rawDecoder,
                            maximumSize: CGSize(width: 400, height: 600),
                            pinchResetGeneration: fittedPinchResetGeneration,
                            onMeasuredScale: onFittedScaleMeasured,
                            onDoubleClick: onZoomToActual,
                            onMagnify: { position, anchor, factor, size, backingScale in
                                magnifyFittedImage(
                                    at: position,
                                    viewportAnchor: anchor,
                                    factor: factor,
                                    containerSize: size,
                                    backingScale: backingScale,
                                    maximumSize: CGSize(width: 400, height: 600)
                                )
                            }
                        )
                    }
                case .fit, .small:
                    if currentLoad, failedToLoad {
                        ContentUnavailableView {
                            Label(rendersRAW ? L10n.text("RAW unavailable") : L10n.text("Can't preview this photo"), systemImage: "exclamationmark.triangle")
                        } description: {
                            if rendersRAW {
                                Text(rawDecoder.failureMessage)
                            } else {
                                Text(L10n.text("Can’t read \(item.displayName). It may be unavailable or unsupported by this Mac. You can still rate it."))
                            }
                        } actions: {
                            Button(rendersRAW ? L10n.text("Retry RAW") : L10n.text("Retry Preview")) {
                                previewRetryGeneration &+= 1
                            }
                            if rendersRAW {
                                if rawDecoder == .raw9 {
                                    Button(L10n.text("Use Apple Default")) { rawDecoder = .appleDefault }
                                }
                                Button(L10n.text("Use Preview")) { fallbackRevision = contentRevision }
                            }
                            Button(L10n.text("Show in Finder")) { showInFinder() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let presentationPreview {
                        // Blurry-but-instant stand-in; the full decode replaces it.
                        ZoomableFittedImage(
                            item: item,
                            mode: zoomMode,
                            image: presentationPreview,
                            decoder: rawDecoder,
                            maximumSize: zoomMode == .small
                                ? CGSize(width: 400, height: 600)
                                : nil,
                            pinchResetGeneration: fittedPinchResetGeneration,
                            onMeasuredScale: onFittedScaleMeasured,
                            onDoubleClick: onZoomToActual,
                            onMagnify: { position, anchor, factor, size, backingScale in
                                magnifyFittedImage(
                                    at: position,
                                    viewportAnchor: anchor,
                                    factor: factor,
                                    containerSize: size,
                                    backingScale: backingScale,
                                    maximumSize: zoomMode == .small
                                        ? CGSize(width: 400, height: 600) : nil
                                )
                            }
                        )
                    } else {
                        // Loading with nothing cached yet: keep the photo area
                        // quiet; the toolbar spinner is the indication.
                        Color.clear
                    }
                }
            }
        }
        .overlay {
            if zoomMode == .actual, item.isRaw, actualRenderingFailed {
                VStack(spacing: 8) {
                    Text(L10n.text("RAW unavailable")).font(.callout)
                    Text(rawDecoder.failureMessage).font(.caption).frame(maxWidth: 320)
                    Button(L10n.text("Retry RAW")) { previewRetryGeneration &+= 1 }
                    if rawDecoder == .raw9 {
                        Button(L10n.text("Use Apple Default")) { rawDecoder = .appleDefault }
                    }
                    Button(L10n.text("Use Preview")) {
                        fallbackRevision = contentRevision
                        onZoomToFit()
                    }
                }
                .padding()
                .background(Color.appBackground)
            }
        }
        .onChange(of: fittedRepresentation, initial: true) { _, representation in
            if zoomMode != .actual { onRepresentation(representation, contentRevision) }
        }
        .onChange(of: zoomMode) { _, mode in
            if mode != .actual { onRepresentation(fittedRepresentation, contentRevision) }
        }
        .onChange(of: contentRevision) { _, _ in
            actualRenderingFailed = false
            if zoomMode != .actual { onRepresentation(fittedRepresentation, contentRevision) }
        }
        .onChange(of: mode) { _, _ in actualRenderingFailed = false }
        .onChange(of: rawDisplayMode) { _, _ in fallbackRevision = nil }
        .onChange(of: rawDecoder) { _, _ in
            fallbackRevision = nil
            actualRenderingFailed = false
            fittedPinchGeneration &+= 1
            if zoomMode != .actual { onRepresentation(fittedRepresentation, contentRevision) }
        }
        .task(id: PreviewLoadID(
            contentRevision: contentRevision,
            retryGeneration: previewRetryGeneration,
            mode: mode,
            decoder: rawDecoder
        )) {
            let requestedItem = item
            let decoder = rawDecoder
            let requestedRevision = requestedItem.contentRevision
            let cachedFull = ImagePipeline.shared.cachedFullImage(
                for: requestedItem, mode: mode, decoder: decoder
            )
            loadedDisplayMode = mode
            loadedDecoder = decoder
            image = cachedFull
            preview = cachedFull == nil && !rendersRAW
                ? ImagePipeline.shared.cachedThumbnail(for: requestedItem)
                : nil
            failedToLoad = false
            imageRevision = requestedRevision
            guard requestedItem.isSupported, cachedFull == nil else { return }

            // Key repeat can create and cancel several view tasks in a few
            // milliseconds. Let stale tasks disappear before they add work.
            try? await Task.sleep(
                nanoseconds: Self.navigationDebounceNanoseconds
            )
            guard !Task.isCancelled, rawDecoder == decoder, loadedDisplayMode == mode, imageRevision == requestedRevision
            else { return }
            onLoading(true)
            defer { onLoading(false) }
            async let full = ImagePipeline.shared.fullImage(
                for: requestedItem, mode: mode, decoder: decoder
            )
            if !rendersRAW, preview == nil,
               let thumb = await ImagePipeline.shared.thumbnail(
                   for: requestedItem
               ),
               !Task.isCancelled, rawDecoder == decoder, loadedDisplayMode == mode,
               imageRevision == requestedRevision,
               image == nil {
                preview = thumb
            }
            let loaded = await full
            guard !Task.isCancelled, rawDecoder == decoder, loadedDisplayMode == mode, imageRevision == requestedRevision
            else { return }
            image = loaded
            failedToLoad = (loaded == nil)
        }
        .task(
            id: ClippingLoadID(
                contentRevision: contentRevision,
                isEnabled: showsClippingWarnings,
                mode: mode,
                decoder: rawDecoder
            )
        ) {
            let requestedItem = item
            let decoder = rawDecoder
            let requestedRevision = requestedItem.contentRevision
            let cached = ClippingPreviewPipeline.shared.cachedImage(
                for: requestedItem, mode: mode, decoder: decoder
            )
            clippingImage = cached
            clippingDisplayMode = mode
            clippingDecoder = decoder
            clippingRevision = requestedRevision
            guard showsClippingWarnings,
                  requestedItem.mediaKind == .photo,
                  requestedItem.isSupported,
                  cached == nil
            else { return }
            // Match the normal preview's key-repeat protection. Without this,
            // clipping inspection immediately requested a full decode for
            // every transient photo and defeated the debounce above.
            try? await Task.sleep(
                nanoseconds: Self.navigationDebounceNanoseconds
            )
            guard !Task.isCancelled, rawDecoder == decoder, clippingDisplayMode == mode,
                  clippingRevision == requestedRevision else { return }
            onLoading(true)
            defer { onLoading(false) }
            let loaded = await ClippingPreviewPipeline.shared.image(
                for: requestedItem, mode: mode, decoder: decoder
            )
            guard !Task.isCancelled, rawDecoder == decoder, clippingDisplayMode == mode,
                  clippingRevision == requestedRevision else { return }
            clippingImage = loaded
        }
    }

    private var fittedRepresentation: PhotoRepresentation {
        let mode = displayMode
        guard mode.rendersRAW(for: item) else { return .preview }
        guard loadedDisplayMode == mode, loadedDecoder == rawDecoder, imageRevision == item.contentRevision else {
            return ImagePipeline.shared.cachedFullImage(for: item, mode: mode, decoder: rawDecoder) == nil ? .loadingRAW : .raw
        }
        if image != nil { return .raw }
        return failedToLoad ? .unavailable : .loadingRAW
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([item.primaryURL])
    }

    private func magnifyFittedImage(
        at position: NormalizedImagePosition,
        viewportAnchor: CGPoint,
        factor: CGFloat,
        containerSize: CGSize,
        backingScale: CGFloat,
        maximumSize: CGSize?
    ) {
        fittedPinchGeneration &+= 1
        let generation = fittedPinchGeneration
        let requestedItem = item
        let revision = item.contentRevision
        let decoder = rawDecoder
        Task { @MainActor in
            let source = await HighResolutionImagePipeline.shared.source(for: requestedItem, decoder: decoder)
            guard generation == fittedPinchGeneration,
                  rawDecoder == decoder,
                  revision == item.contentRevision,
                  zoomMode != .actual
            else { return }
            guard let source else {
                fittedPinchResetGeneration &+= 1
                return
            }
            let fittedScale = ActualSizeGeometry.fitZoom(
                sourcePixels: source.pixelSize,
                backingScale: backingScale,
                viewportSize: containerSize,
                maximumSize: maximumSize
            )
            onZoomFromFit(
                ActualSizeGeometry.clampedZoom(fittedScale * factor),
                position,
                viewportAnchor,
                revision
            )
        }
    }
}

/// Displays exactly the fitted image rectangle so only the photo—not its
/// letterboxed surroundings—owns the location-aware double-click gesture.
private struct ZoomableFittedImage: View {
    @Environment(\.displayScale) private var displayScale
    let item: PhotoItem
    let mode: ZoomMode
    let image: NSImage
    var decoder: AppleRawDecoder = .appleDefault
    var maximumSize: CGSize? = nil
    let pinchResetGeneration: UInt64
    let onMeasuredScale: (CGFloat, PhotoContentRevision, ZoomMode) -> Void
    let onDoubleClick: (NormalizedImagePosition) -> Void
    let onMagnify: (NormalizedImagePosition, CGPoint, CGFloat, CGSize, CGFloat) -> Void
    @State private var livePinchFactor: CGFloat = 1
    @State private var livePinchPosition: NormalizedImagePosition = .center
    @State private var sourcePixelSize: CGSize?
    @State private var measuredRevision: PhotoContentRevision?
    @State private var containerSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let imageFrame = FittedImageGeometry.frame(
                imageSize: image.size,
                containerSize: geometry.size,
                maximumSize: maximumSize
            )
            if !imageFrame.isEmpty {
                Image(nsImage: image)
                    .resizable()
                    .frame(
                        width: imageFrame.width,
                        height: imageFrame.height
                    )
                    .contentShape(Rectangle())
                    .overlay {
                        FittedImageDoubleClickOverlay(
                            onDoubleClick: onDoubleClick,
                            onMagnify: { position, factor, backingScale, ended in
                                livePinchPosition = position
                                livePinchFactor = min(max(factor, 0.25), 4)
                                guard ended else { return }
                                let anchor = CGPoint(
                                    x: (imageFrame.minX + position.x * imageFrame.width)
                                        / geometry.size.width,
                                    y: (imageFrame.minY + position.y * imageFrame.height)
                                        / geometry.size.height
                                )
                                onMagnify(
                                    position, anchor, factor,
                                    geometry.size, backingScale
                                )
                            }
                        )
                        .accessibilityHidden(true)
                    }
                    .scaleEffect(
                        livePinchFactor,
                        anchor: UnitPoint(
                            x: livePinchPosition.x,
                            y: livePinchPosition.y
                        )
                    )
                    .position(
                        x: imageFrame.midX,
                        y: imageFrame.midY
                    )
                    .accessibilityHint(
                        L10n.text("Double-click to inspect this point at 100 percent.")
                    )
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear { containerSize = geometry.size }
                .onChange(of: geometry.size) { _, size in
                    containerSize = size
                }
        }
        .task(id: HighResolutionImagePipeline.sourceKey(for: item, decoder: decoder)) {
            let revision = item.contentRevision
            let source = await HighResolutionImagePipeline.shared.source(for: item, decoder: decoder)
            guard !Task.isCancelled else { return }
            measuredRevision = revision
            sourcePixelSize = source?.pixelSize
            reportMeasuredScale()
        }
        .onChange(of: containerSize) { _, _ in reportMeasuredScale() }
        .onChange(of: displayScale) { _, _ in reportMeasuredScale() }
        .onChange(of: mode) { _, _ in
            livePinchFactor = 1
            reportMeasuredScale()
        }
        .onChange(of: item.contentRevision) { _, _ in
            livePinchFactor = 1
            sourcePixelSize = nil
        }
        .onChange(of: pinchResetGeneration) { _, _ in
            livePinchFactor = 1
        }
    }

    private func reportMeasuredScale() {
        guard measuredRevision == item.contentRevision,
              let sourcePixelSize,
              containerSize.width > 0,
              containerSize.height > 0 else { return }
        onMeasuredScale(
            ActualSizeGeometry.fitZoom(
                sourcePixels: sourcePixelSize,
                backingScale: displayScale,
                viewportSize: containerSize,
                maximumSize: maximumSize
            ),
            item.contentRevision,
            mode
        )
    }
}

/// A native macOS click surface sized to the rendered photo rectangle. It
/// reports pointer locations in the same top-left coordinate system used by
/// the tiled 100% viewport.
private struct FittedImageDoubleClickOverlay: NSViewRepresentable {
    let onDoubleClick: (NormalizedImagePosition) -> Void
    let onMagnify: (NormalizedImagePosition, CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> FittedImageDoubleClickView {
        let view = FittedImageDoubleClickView()
        view.onDoubleClick = onDoubleClick
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(
        _ nsView: FittedImageDoubleClickView,
        context: Context
    ) {
        nsView.onDoubleClick = onDoubleClick
        nsView.onMagnify = onMagnify
    }
}

@MainActor
final class FittedImageDoubleClickView: NSView {
    override var isFlipped: Bool { true }

    var onDoubleClick: (NormalizedImagePosition) -> Void = { _ in }
    var onMagnify: (NormalizedImagePosition, CGFloat, CGFloat, Bool) -> Void = { _, _, _, _ in }
    private var magnificationFactor: CGFloat = 1
    private var lastPinchPosition: NormalizedImagePosition?
    private var pinchIsActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installMagnificationRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installMagnificationRecognizer()
    }

    private func installMagnificationRecognizer() {
        // NSResponder's begin/endGesture callbacks are no longer delivered.
        // The recognizer owns the complete native pinch lifecycle, including
        // cancelled gestures, without replacing this view mid-gesture.
        addGestureRecognizer(NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnification(_:))
        ))
    }

    @objc func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        let point = recognizer.location(in: self)
        let backingScale = window?.backingScaleFactor ?? 1
        switch recognizer.state {
        case .began:
            beginPinch()
            updatePinch(factor: 1 + recognizer.magnification,
                        at: point, backingScale: backingScale)
        case .changed:
            if !pinchIsActive { beginPinch() }
            updatePinch(factor: 1 + recognizer.magnification,
                        at: point, backingScale: backingScale)
        case .ended:
            guard pinchIsActive else { return }
            updatePinch(factor: 1 + recognizer.magnification,
                        at: point, backingScale: backingScale)
            finishPinch(backingScale: backingScale)
        case .cancelled, .failed:
            cancelPinch(backingScale: backingScale)
        default:
            break
        }
    }

    func beginPinch() {
        pinchIsActive = true
        magnificationFactor = 1
        lastPinchPosition = nil
    }

    func updatePinch(delta: CGFloat, at point: CGPoint, backingScale: CGFloat) {
        magnificationFactor *= max(0.01, 1 + delta)
        reportPinch(at: point, backingScale: backingScale)
    }

    private func updatePinch(factor: CGFloat, at point: CGPoint, backingScale: CGFloat) {
        magnificationFactor = max(0.01, factor)
        reportPinch(at: point, backingScale: backingScale)
    }

    private func reportPinch(at point: CGPoint, backingScale: CGFloat) {
        // Recognition can end just outside the image. Keep the first valid
        // anchor so the terminal callback still enters the pannable viewport.
        if lastPinchPosition == nil {
            lastPinchPosition = FittedImageGeometry.normalizedPosition(
                at: point,
                in: bounds
            )
        }
        if let lastPinchPosition {
            onMagnify(lastPinchPosition, magnificationFactor,
                      backingScale, false)
        }
    }

    func finishPinch(backingScale: CGFloat) {
        guard pinchIsActive else { return }
        pinchIsActive = false
        guard let lastPinchPosition else { return }
        onMagnify(lastPinchPosition, magnificationFactor,
                  backingScale, true)
        self.lastPinchPosition = nil
    }

    private func cancelPinch(backingScale: CGFloat) {
        guard pinchIsActive else { return }
        pinchIsActive = false
        if let lastPinchPosition {
            onMagnify(lastPinchPosition, 1, backingScale, false)
        }
        self.lastPinchPosition = nil
        magnificationFactor = 1
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = FittedImageGeometry.normalizedPosition(
            at: point,
            in: bounds
        ) else {
            return
        }
        onDoubleClick(position)
    }
}
