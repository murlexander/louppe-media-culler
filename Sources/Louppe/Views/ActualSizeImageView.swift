import SwiftUI
import AppKit

/// AppKit-backed 100% image viewport. One instance survives Gallery
/// navigation, so its normalized inspection position can be restored for the
/// next photo instead of every new SwiftUI ScrollView centering itself.
struct ActualSizeImageView: NSViewRepresentable {
    let item: PhotoItem
    let preview: NSImage?
    let showsClippingWarnings: Bool
    let viewport: ActualSizeViewport
    let onDoubleClick: () -> Void
    let onLoading: (Bool) -> Void
    var zoomScale: CGFloat = 1
    var onZoomScaleChanged: (CGFloat, Bool) -> Void = { _, _ in }
    var previewIsRAW = false
    var decoder: AppleRawDecoder = .appleDefault
    var retryGeneration: UInt64 = 0
    var onRenderingFailure: (Bool) -> Void = { _ in }
    var onRepresentation: (PhotoRepresentation) -> Void = { _ in }

    func makeNSView(context: Context) -> ActualSizeScrollView {
        ActualSizeScrollView()
    }

    func updateNSView(
        _ scrollView: ActualSizeScrollView,
        context: Context
    ) {
        scrollView.configure(
            item: item,
            preview: preview,
            showsClippingWarnings: showsClippingWarnings,
            viewport: viewport,
            onDoubleClick: onDoubleClick,
            onLoading: onLoading,
            zoomScale: zoomScale,
            onZoomScaleChanged: onZoomScaleChanged,
            previewIsRAW: previewIsRAW,
            decoder: decoder,
            retryGeneration: retryGeneration,
            onRenderingFailure: onRenderingFailure,
            onRepresentation: onRepresentation
        )
    }

    static func dismantleNSView(
        _ scrollView: ActualSizeScrollView,
        coordinator: ()
    ) {
        scrollView.prepareForRemoval()
    }
}

@MainActor
final class ActualSizeScrollView: NSScrollView {
    private let canvas = ActualSizeCanvasView()
    private var sourceLoader: @MainActor (PhotoItem, AppleRawDecoder) async -> ZoomImageSource? = {
        await HighResolutionImagePipeline.shared.source(for: $0, decoder: $1)
    }
    var displayedSourceKey: String? { canvas.source?.key }

    convenience init(sourceLoader: @escaping @MainActor (PhotoItem, AppleRawDecoder) async -> ZoomImageSource?) {
        self.init(frame: .zero)
        self.sourceLoader = sourceLoader
    }
    private var sourceTask: Task<Void, Never>?
    private var currentContentRevision: PhotoContentRevision?
    private var currentSourceKey: String?
    private var currentRetryGeneration: UInt64 = 0
    private var sourceGeneration: UInt64 = 0
    private var representationGeneration: UInt64 = 0
    private var appliedPositionRequestGeneration: UInt64?
    private var backingScale: CGFloat = 1
    private var isApplyingViewport = false
    private var viewport: ActualSizeViewport?
    private var onLoading: (Bool) -> Void = { _ in }
    private var onZoomScaleChanged: (CGFloat, Bool) -> Void = { _, _ in }
    private var pendingPlacement: (position: NormalizedImagePosition, anchor: CGPoint)?
    private var isNativeMagnifying = false
    private var nativeMagnificationHasEnded = false
    private var displayedItemName = L10n.text("photo")
    private var panStart: (windowPoint: CGPoint, contentOrigin: CGPoint)?
    private var zoomAnimationTask: Task<Void, Never>?
    private var animatedViewportPosition: NormalizedImagePosition?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = ActualSizeGeometry.minimumZoom
        maxMagnification = ActualSizeGeometry.maximumZoom
        documentView = canvas
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveMagnificationStarted(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveMagnificationEnded(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: self
        )
        canvas.onTileActivityChanged = { [weak self] active in
            self?.onLoading(active)
        }
        canvas.onPanStart = { [weak self] point in
            self?.beginPhotoPan(at: point) ?? false
        }
        canvas.onPanMove = { [weak self] point in
            self?.movePhotoPan(to: point)
        }
        canvas.onPanEnd = { [weak self] in
            self?.endPhotoPan()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(
        item: PhotoItem,
        preview: NSImage?,
        showsClippingWarnings: Bool,
        viewport: ActualSizeViewport,
        onDoubleClick: @escaping () -> Void = {},
        onLoading: @escaping (Bool) -> Void,
        zoomScale: CGFloat = 1,
        onZoomScaleChanged: @escaping (CGFloat, Bool) -> Void = { _, _ in },
        previewIsRAW: Bool = false,
        decoder: AppleRawDecoder = .appleDefault,
        retryGeneration: UInt64 = 0,
        onRenderingFailure: @escaping (Bool) -> Void = { _ in },
        onRepresentation: @escaping (PhotoRepresentation) -> Void = { _ in }
    ) {
        self.viewport = viewport
        self.onLoading = onLoading
        self.onZoomScaleChanged = onZoomScaleChanged
        displayedItemName = item.displayName
        updateAccessibilityZoomLabel()
        setAccessibilityHelp(
            L10n.text("Scroll or pinch to inspect; double-click for Fit. Navigation keeps the position; S resets it.")
        )
        canvas.onTileActivityChanged = { [weak self] active in
            self?.onLoading(active)
        }
        canvas.onDoubleClick = onDoubleClick
        representationGeneration &+= 1
        let representationGeneration = self.representationGeneration
        canvas.previewIsRAW = previewIsRAW
        canvas.onRenderingFailure = { [weak self] failed in
            let generation = self?.sourceGeneration
            Task { @MainActor [weak self] in
                guard let self, self.sourceGeneration == generation,
                      self.representationGeneration == representationGeneration else { return }
                onRenderingFailure(failed)
            }
        }
        canvas.onRepresentation = { [weak self] representation in
            guard let self else { return }
            let generation = self.sourceGeneration
            Task { @MainActor [weak self] in
                guard let self,
                      self.sourceGeneration == generation,
                      self.representationGeneration == representationGeneration,
                      self.currentContentRevision == item.contentRevision else { return }
                onRepresentation(representation)
            }
        }
        canvas.setPreview(preview)
        let clippingChanged = canvas.setShowsClippingWarnings(
            showsClippingWarnings
        )

        let requestedRevision = item.contentRevision
        let sourceKey = HighResolutionImagePipeline.sourceKey(for: item, decoder: decoder)
        let itemChanged = currentContentRevision != requestedRevision || currentSourceKey != sourceKey || currentRetryGeneration != retryGeneration
        if itemChanged {
            if zoomAnimationTask != nil {
                // The store has already requested the centered S destination.
                // Do not let a transient animation frame replace it on a
                // quick navigation to the next photo.
                cancelZoomAnimation()
            } else {
                captureViewport()
            }
            pendingPlacement = nil
            currentContentRevision = requestedRevision
            currentSourceKey = sourceKey
            currentRetryGeneration = retryGeneration
            sourceGeneration &+= 1
            let generation = sourceGeneration
            sourceTask?.cancel()
            canvas.beginItem(key: "\(sourceKey)|retry-\(retryGeneration)")
            HighResolutionImagePipeline.shared.cancelTileRequests(
                exceptSourceKey: nil
            )
            sourceTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let source = await self.sourceLoader(item, decoder)
                guard !Task.isCancelled,
                      self.sourceGeneration == generation,
                      self.currentContentRevision == requestedRevision
                else { return }
                self.install(source: source)
            }
        }

        let requestedScale = ActualSizeGeometry.clampedZoom(zoomScale)
        let positionRequestChanged =
            appliedPositionRequestGeneration
                != viewport.positionRequestGeneration
        if zoomAnimationTask != nil,
           (requestedScale != 1 || positionRequestChanged) {
            cancelZoomAnimation()
        }
        if !isNativeMagnifying,
           zoomAnimationTask == nil,
           abs(magnification - requestedScale) > 0.001 {
            if !itemChanged,
               positionRequestChanged,
               requestedScale == 1,
               canvas.source != nil,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                appliedPositionRequestGeneration = viewport.positionRequestGeneration
                pendingPlacement = nil
                animateCenteredReset(to: viewport.position)
                return
            }
            let retained = viewport.position
            isApplyingViewport = true
            setMagnification(
                requestedScale,
                centeredAt: CGPoint(
                    x: contentView.bounds.midX,
                    y: contentView.bounds.midY
                )
            )
            updateDocumentGeometry()
            scrollToViewportPosition(retained)
            isApplyingViewport = false
            updateAccessibilityZoomLabel()
        }
        canvas.setUsesSourceTiles(magnification >= 1)
        canvas.reportRepresentation()

        if positionRequestChanged {
            appliedPositionRequestGeneration =
                viewport.positionRequestGeneration
            pendingPlacement = (
                viewport.position,
                viewport.placementAnchor
            )
            applyViewportPosition()
        } else if itemChanged, canvas.source != nil {
            applyViewportPosition()
        }
        if clippingChanged || canvas.source != nil {
            canvas.updateVisibleRect(contentView.documentVisibleRect)
        }
    }

    func prepareForRemoval() {
        endPhotoPan()
        let wasAnimating = zoomAnimationTask != nil
        cancelZoomAnimation()
        // S requests the centered viewport before SwiftUI removes this
        // representable. Do not capture the old scroll position over a newer
        // explicit position request.
        if !wasAnimating,
           appliedPositionRequestGeneration
            == viewport?.positionRequestGeneration {
            captureViewport()
        }
        sourceTask?.cancel()
        sourceTask = nil
        sourceGeneration &+= 1
        currentContentRevision = nil
        currentSourceKey = nil
        canvas.prepareForRemoval()
        HighResolutionImagePipeline.shared.cancelTileRequests(
            exceptSourceKey: nil
        )
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard clipView === contentView else { return }
        if !isApplyingViewport, zoomAnimationTask == nil {
            captureViewport()
        }
        canvas.updateVisibleRect(clipView.documentVisibleRect)
    }

    override func scrollWheel(with event: NSEvent) {
        if zoomAnimationTask != nil {
            cancelZoomAnimation(publishingCurrentScale: true)
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if zoomAnimationTask != nil {
            cancelZoomAnimation(publishingCurrentScale: true)
        }
        let terminal = event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
        if event.phase.contains(.began) || (!terminal && !isNativeMagnifying) {
            nativeMagnificationHasEnded = false
        }
        if terminal && nativeMagnificationHasEnded {
            return
        }
        isNativeMagnifying = true
        super.magnify(with: event)
        if terminal {
            finishNativeMagnification()
        } else if isNativeMagnifying {
            didChangeNativeMagnification(ended: false)
        }
    }

    @objc private func liveMagnificationStarted(_ notification: Notification) {
        nativeMagnificationHasEnded = false
        isNativeMagnifying = true
    }

    @objc private func liveMagnificationEnded(_ notification: Notification) {
        finishNativeMagnification()
    }

    private func finishNativeMagnification() {
        guard isNativeMagnifying else { return }
        isNativeMagnifying = false
        nativeMagnificationHasEnded = true
        didChangeNativeMagnification(ended: true)
    }

    /// Dragging is measured in stable window points; dividing by the current
    /// magnification maps it into the flipped document's scroll coordinates.
    /// NSClipView constrains the result to the actual photo bounds.
    func beginPhotoPan(at windowPoint: CGPoint) -> Bool {
        guard canvas.source != nil,
              !isNativeMagnifying,
              canvas.frame.width > contentView.bounds.width + 1
                || canvas.frame.height > contentView.bounds.height + 1
        else { return false }
        cancelZoomAnimation(publishingCurrentScale: true)
        panStart = (windowPoint, contentView.bounds.origin)
        return true
    }

    func movePhotoPan(to windowPoint: CGPoint) {
        guard let panStart else { return }
        let scale = max(magnification, ActualSizeGeometry.minimumZoom)
        let target = CGPoint(
            x: panStart.contentOrigin.x
                - (windowPoint.x - panStart.windowPoint.x) / scale,
            y: panStart.contentOrigin.y
                + (windowPoint.y - panStart.windowPoint.y) / scale
        )
        contentView.scroll(to: CGPoint(
            x: min(max(target.x, 0), max(canvas.frame.width - contentView.bounds.width, 0)),
            y: min(max(target.y, 0), max(canvas.frame.height - contentView.bounds.height, 0))
        ))
        reflectScrolledClipView(contentView)
    }

    func endPhotoPan() {
        guard panStart != nil else { return }
        panStart = nil
        captureViewport()
    }

    /// The S key's explicit return from custom zoom to centered 100% is the
    /// only animated programmatic zoom. A short fixed frame count keeps the
    /// viewport position and zoom moving together; continuous slider and
    /// trackpad updates remain immediate.
    private func animateCenteredReset(to target: NormalizedImagePosition) {
        cancelZoomAnimation()
        let startScale = magnification
        let startPosition = ActualSizeGeometry.normalizedPosition(
            contentOffset: contentView.bounds.origin,
            documentSize: canvas.imageSize,
            viewportSize: contentView.bounds.size,
            preserving: target
        )
        animatedViewportPosition = startPosition
        zoomAnimationTask = Task { @MainActor [weak self] in
            for frame in 1...10 {
                do {
                    try await Task.sleep(nanoseconds: 18_000_000)
                } catch { return }
                guard let self, !Task.isCancelled else { return }
                let progress = CGFloat(frame) / 10
                let remaining = 1 - progress
                let eased = 1 - remaining * remaining * remaining
                let position = NormalizedImagePosition(
                    x: startPosition.x + (target.x - startPosition.x) * eased,
                    y: startPosition.y + (target.y - startPosition.y) * eased
                )
                self.animatedViewportPosition = position
                self.isApplyingViewport = true
                self.setMagnification(
                    startScale + (1 - startScale) * eased,
                    centeredAt: CGPoint(
                        x: self.contentView.bounds.midX,
                        y: self.contentView.bounds.midY
                    )
                )
                self.updateDocumentGeometry()
                self.scrollToViewportPosition(position)
                self.isApplyingViewport = false
                self.canvas.setUsesSourceTiles(self.magnification >= 1)
                self.canvas.updateVisibleRect(self.contentView.documentVisibleRect)
            }
            guard let self else { return }
            self.zoomAnimationTask = nil
            self.animatedViewportPosition = nil
            self.viewport?.update(position: target)
            self.updateAccessibilityZoomLabel()
        }
    }

    private func cancelZoomAnimation(publishingCurrentScale: Bool = false) {
        guard let zoomAnimationTask else { return }
        zoomAnimationTask.cancel()
        self.zoomAnimationTask = nil
        animatedViewportPosition = nil
        if publishingCurrentScale {
            captureViewport()
            onZoomScaleChanged(magnification, true)
        }
    }

    /// Shared with focused tests: native magnification has already changed
    /// the scroll view's transform and pointer anchor before this runs.
    func didChangeNativeMagnification(ended: Bool) {
        updateAccessibilityZoomLabel()
        canvas.setUsesSourceTiles(magnification >= 1)
        updateDocumentGeometry()
        canvas.updateVisibleRect(contentView.documentVisibleRect)
        captureViewport()
        onZoomScaleChanged(magnification, ended)
    }

    private func updateAccessibilityZoomLabel() {
        let percent = Int((magnification * 100).rounded())
        setAccessibilityLabel(L10n.text("\(percent)% view of \(displayedItemName)"))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let retained = animatedViewportPosition ?? viewport?.position ?? .center
        let wasApplyingViewport = isApplyingViewport
        isApplyingViewport = true
        super.setFrameSize(newSize)
        updateDocumentGeometry()
        scrollToViewportPosition(retained)
        if zoomAnimationTask == nil { viewport?.update(position: retained) }
        isApplyingViewport = wasApplyingViewport
    }

    override func layout() {
        let retained = animatedViewportPosition ?? viewport?.position ?? .center
        isApplyingViewport = true
        super.layout()
        updateDocumentGeometry()
        if let viewport, zoomAnimationTask == nil {
            viewport.update(position: retained)
        }
        scrollToViewportPosition(retained)
        isApplyingViewport = false
        canvas.updateVisibleRect(contentView.documentVisibleRect)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let retained = animatedViewportPosition ?? viewport?.position ?? .center
        isApplyingViewport = true
        updateBackingScale()
        updateDocumentGeometry()
        scrollToViewportPosition(retained)
        if zoomAnimationTask == nil { viewport?.update(position: retained) }
        isApplyingViewport = false
        canvas.updateVisibleRect(contentView.documentVisibleRect)
    }

    private func install(source: ZoomImageSource?) {
        let retained = viewport?.position ?? .center
        isApplyingViewport = true
        updateBackingScale()
        canvas.setSource(source, backingScale: backingScale)
        canvas.setUsesSourceTiles(magnification >= 1)
        updateDocumentGeometry()
        if pendingPlacement != nil {
            applyViewportPosition()
        } else {
            scrollToViewportPosition(retained)
            viewport?.update(position: retained)
        }
        isApplyingViewport = false
        canvas.updateVisibleRect(contentView.documentVisibleRect)
        canvas.reportRepresentation()
    }

    private func updateBackingScale() {
        backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        canvas.setBackingScale(backingScale)
    }

    private func updateDocumentGeometry() {
        // The clip view's bounds are measured in document points. `contentSize`
        // stays in screen points while NSScrollView is magnified, which would
        // miscenter photos and restore the wrong normalized position below 100%.
        let viewportSize = contentView.bounds.size
        let imageSize = canvas.source.map {
            ActualSizeGeometry.documentSize(
                sourcePixels: $0.pixelSize,
                backingScale: backingScale
            )
        } ?? .zero
        let documentSize = CGSize(
            width: max(imageSize.width, viewportSize.width),
            height: max(imageSize.height, viewportSize.height)
        )
        canvas.updateGeometry(
            imageSize: imageSize,
            documentSize: documentSize
        )
    }

    private func applyViewportPosition() {
        guard canvas.source != nil else { return }
        if let placement = pendingPlacement {
            let offset = ActualSizeGeometry.anchoredOffset(
                imagePosition: placement.position,
                viewportAnchor: placement.anchor,
                documentSize: canvas.imageSize,
                viewportSize: contentView.bounds.size
            )
            isApplyingViewport = true
            contentView.scroll(to: offset)
            super.reflectScrolledClipView(contentView)
            isApplyingViewport = false
            pendingPlacement = nil
            captureViewport()
        } else {
            scrollToViewportPosition(viewport?.position ?? .center)
        }
    }

    private func scrollToViewportPosition(
        _ position: NormalizedImagePosition
    ) {
        guard canvas.source != nil else { return }
        let offset = ActualSizeGeometry.contentOffset(
            for: position,
            documentSize: canvas.imageSize,
            viewportSize: contentView.bounds.size
        )
        let wasApplyingViewport = isApplyingViewport
        isApplyingViewport = true
        contentView.scroll(to: offset)
        super.reflectScrolledClipView(contentView)
        isApplyingViewport = wasApplyingViewport
    }

    private func captureViewport() {
        guard let viewport, canvas.source != nil else { return }
        let position = ActualSizeGeometry.normalizedPosition(
            contentOffset: contentView.bounds.origin,
            documentSize: canvas.imageSize,
            viewportSize: contentView.bounds.size,
            preserving: viewport.position
        )
        viewport.update(position: position)
    }
}

@MainActor
private final class ActualSizeCanvasView: NSView {
    private struct DisplayTile {
        let image: NSImage
        let pixelRect: CGRect
    }

    override var isFlipped: Bool { true }

    private(set) var source: ZoomImageSource?
    private(set) var imageSize: CGSize = .zero
    var onTileActivityChanged: (Bool) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onPanStart: (CGPoint) -> Bool = { _ in false }
    var onPanMove: (CGPoint) -> Void = { _ in }
    var onPanEnd: () -> Void = {}
    private var isPhotoPanning = false
    var previewIsRAW = false
    var onRepresentation: (PhotoRepresentation) -> Void = { _ in }
    var onRenderingFailure: (Bool) -> Void = { _ in }
    private var visibleCoordinates: Set<ZoomTileCoordinate> = []
    private var failedCoordinates: Set<ZoomTileCoordinate> = []
    private var sourceFailed = false

    private var itemKey: String?
    private var preview: NSImage?
    private var backingScale: CGFloat = 1
    private var imageFrame: CGRect = .zero
    private var tiles: [ZoomTileCoordinate: DisplayTile] = [:]
    private var pending: Set<ZoomTileCoordinate> = []
    private var wanted: Set<ZoomTileCoordinate> = []
    private var generation: UInt64 = 0
    private var reportsTileActivity = false
    private var showsClippingWarnings = false
    private var usesSourceTiles = true

    func beginItem(key: String) {
        guard itemKey != key else { return }
        cancelPhotoPan()
        stopReportingActivity()
        itemKey = key
        sourceFailed = false
        visibleCoordinates = []
        failedCoordinates = []
        source = nil
        tiles = [:]
        pending = []
        wanted = []
        imageSize = .zero
        imageFrame = bounds
        generation &+= 1
        needsDisplay = true
    }

    func setPreview(_ preview: NSImage?) {
        guard self.preview !== preview else { return }
        self.preview = preview
        needsDisplay = true
    }

    func setUsesSourceTiles(_ value: Bool) {
        guard usesSourceTiles != value else { return }
        usesSourceTiles = value
        failedCoordinates = []
        if !value {
            stopReportingActivity()
            generation &+= 1
            pending = []
            wanted = []
            tiles = [:]
            if let source {
                HighResolutionImagePipeline.shared.retainTileRequests(
                    sourceKey: source.key,
                    coordinates: [],
                    showsClippingWarnings: showsClippingWarnings
                )
            }
        }
        reportRepresentation()
        needsDisplay = true
    }

    @discardableResult
    func setShowsClippingWarnings(_ value: Bool) -> Bool {
        guard showsClippingWarnings != value else { return false }
        stopReportingActivity()
        showsClippingWarnings = value
        failedCoordinates = []
        tiles = [:]
        pending = []
        wanted = []
        generation &+= 1
        HighResolutionImagePipeline.shared.cancelTileRequests(
            exceptSourceKey: nil
        )
        needsDisplay = true
        return true
    }

    func setSource(
        _ source: ZoomImageSource?,
        backingScale: CGFloat
    ) {
        self.source = source
        sourceFailed = source == nil
        failedCoordinates = []
        visibleCoordinates = []
        self.backingScale = validScale(backingScale)
        tiles = [:]
        pending = []
        wanted = []
        generation &+= 1
        needsDisplay = true
    }

    func setBackingScale(_ value: CGFloat) {
        let scale = validScale(value)
        guard scale != backingScale else { return }
        backingScale = scale
        // Tiles are keyed and stored in source pixels, so a display-scale
        // change only alters their point-space destination rectangles.
        needsDisplay = true
    }

    func updateGeometry(imageSize: CGSize, documentSize: CGSize) {
        self.imageSize = imageSize
        if frame.size != documentSize {
            setFrameSize(documentSize)
        }
        let nextImageFrame = CGRect(
            x: max((documentSize.width - imageSize.width) / 2, 0),
            y: max((documentSize.height - imageSize.height) / 2, 0),
            width: imageSize.width,
            height: imageSize.height
        )
        guard imageFrame != nextImageFrame else { return }
        imageFrame = nextImageFrame
        needsDisplay = true
    }

    func updateVisibleRect(_ visibleRect: CGRect) {
        guard usesSourceTiles,
              let source, imageFrame.width > 0, imageFrame.height > 0
        else { return }
        let intersection = visibleRect.intersection(imageFrame)
        guard !intersection.isNull, !intersection.isEmpty else { return }
        let sourceRect = CGRect(
            x: (intersection.minX - imageFrame.minX) * backingScale,
            y: (intersection.minY - imageFrame.minY) * backingScale,
            width: intersection.width * backingScale,
            height: intersection.height * backingScale
        )
        let tilePixels = CGFloat(HighResolutionImagePipeline.tilePixelSize)
        let maximumColumn = max(
            Int(ceil(source.pixelSize.width / tilePixels)) - 1,
            0
        )
        let maximumRow = max(
            Int(ceil(source.pixelSize.height / tilePixels)) - 1,
            0
        )
        let firstColumn = max(Int(floor(sourceRect.minX / tilePixels)) - 1, 0)
        let lastColumn = min(
            Int(floor(max(sourceRect.maxX - 1, 0) / tilePixels)) + 1,
            maximumColumn
        )
        let firstRow = max(Int(floor(sourceRect.minY / tilePixels)) - 1, 0)
        let lastRow = min(
            Int(floor(max(sourceRect.maxY - 1, 0) / tilePixels)) + 1,
            maximumRow
        )
        var coordinates: Set<ZoomTileCoordinate> = []
        if firstColumn <= lastColumn, firstRow <= lastRow {
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    coordinates.insert(
                        ZoomTileCoordinate(column: column, row: row)
                    )
                }
            }
        }
        visibleCoordinates = Set(coordinates.filter { coordinate in
            guard let rect = coordinate.pixelRect(sourceSize: source.pixelSize) else { return false }
            let intersection = rect.intersection(sourceRect)
            return !intersection.isNull && !intersection.isEmpty
        })
        failedCoordinates.formIntersection(coordinates)
        wanted = coordinates
        tiles = tiles.filter { coordinates.contains($0.key) }
        HighResolutionImagePipeline.shared.retainTileRequests(
            sourceKey: source.key,
            coordinates: coordinates,
            showsClippingWarnings: showsClippingWarnings
        )
        requestMissingTiles(source: source)
    }

    func prepareForRemoval() {
        cancelPhotoPan()
        // AppKit may still deliver layout/scroll callbacks as this view leaves
        // its window. Retire the source before reporting idle, so those late
        // callbacks cannot request new tiles whose owner is about to disappear.
        source = nil
        itemKey = nil
        generation &+= 1
        pending = []
        wanted = []
        tiles = [:]
        stopReportingActivity()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let displayedFrame = source == nil ? fittedPreviewFrame() : imageFrame
        if event.clickCount == 2, displayedFrame.contains(point) {
            onDoubleClick()
            return
        }
        if event.clickCount == 1, onPanStart(event.locationInWindow) {
            isPhotoPanning = true
            NSCursor.closedHand.push()
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPhotoPanning else {
            super.mouseDragged(with: event)
            return
        }
        onPanMove(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        if isPhotoPanning {
            cancelPhotoPan()
        } else {
            super.mouseUp(with: event)
        }
    }

    private func cancelPhotoPan() {
        guard isPhotoPanning else { return }
        isPhotoPanning = false
        onPanEnd()
        NSCursor.pop()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if source == nil {
            drawPreviewFitted()
            return
        }
        if let preview {
            NSGraphicsContext.current?.imageInterpolation = .high
            preview.draw(
                in: imageFrame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        guard usesSourceTiles else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        for tile in tiles.values {
            let rect = CGRect(
                x: imageFrame.minX + tile.pixelRect.minX / backingScale,
                y: imageFrame.minY + tile.pixelRect.minY / backingScale,
                width: tile.pixelRect.width / backingScale,
                height: tile.pixelRect.height / backingScale
            )
            guard rect.intersects(dirtyRect) else { continue }
            tile.image.draw(
                in: rect,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
    }

    private func drawPreviewFitted() {
        guard let preview else { return }
        let rect = fittedPreviewFrame()
        guard !rect.isEmpty else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        preview.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func fittedPreviewFrame() -> CGRect {
        guard let preview else { return .zero }
        return FittedImageGeometry.frame(
            imageSize: preview.size,
            containerSize: bounds.size
        )
    }

    private func requestMissingTiles(source: ZoomImageSource) {
        let missing = wanted.subtracting(tiles.keys).subtracting(pending).subtracting(failedCoordinates)
        guard !missing.isEmpty else {
            updateActivityReport()
            return
        }
        pending.formUnion(missing)
        updateActivityReport()
        let requestGeneration = generation
        for coordinate in missing {
            Task { @MainActor [weak self] in
                let tile = await HighResolutionImagePipeline.shared.tile(
                    for: source,
                    coordinate: coordinate,
                    showsClippingWarnings: self?.showsClippingWarnings ?? false
                )
                guard let self else { return }
                guard self.generation == requestGeneration else { return }
                self.pending.remove(coordinate)
                defer { self.updateActivityReport() }
                guard self.source?.key == source.key,
                      self.wanted.contains(coordinate) else { return }
                guard let tile else {
                    self.failedCoordinates.insert(coordinate)
                    return
                }
                let pointSize = CGSize(
                    width: tile.pixelRect.width / self.backingScale,
                    height: tile.pixelRect.height / self.backingScale
                )
                self.tiles[coordinate] = DisplayTile(
                    image: NSImage(cgImage: tile.image, size: pointSize),
                    pixelRect: tile.pixelRect
                )
                let rect = CGRect(
                    x: self.imageFrame.minX
                        + tile.pixelRect.minX / self.backingScale,
                    y: self.imageFrame.minY
                        + tile.pixelRect.minY / self.backingScale,
                    width: pointSize.width,
                    height: pointSize.height
                )
                self.setNeedsDisplay(rect)
            }
        }
    }

    func reportRepresentation() {
        onRenderingFailure(sourceFailed || !failedCoordinates.isDisjoint(with: visibleCoordinates))
        onRepresentation(PhotoRepresentation.viewport(
            hasSource: source != nil,
            usesTiles: usesSourceTiles,
            visibleTilesReady: !visibleCoordinates.isEmpty && visibleCoordinates.isSubset(of: Set(tiles.keys)),
            hasPreview: preview != nil,
            previewIsRAW: previewIsRAW,
            failed: sourceFailed || !failedCoordinates.isDisjoint(with: visibleCoordinates)
        ))
    }

    private func updateActivityReport() {
        reportRepresentation()
        let active = !pending.isEmpty
        guard active != reportsTileActivity else { return }
        reportsTileActivity = active
        onTileActivityChanged(active)
    }

    private func stopReportingActivity() {
        guard reportsTileActivity else { return }
        reportsTileActivity = false
        onTileActivityChanged(false)
    }

    private func validScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}
