import AppKit
import SwiftUI

/// Stable, non-observable handle. Scroll traffic never invalidates SwiftUI.
/// A pending one-shot receipt takes precedence over initial current following.
@MainActor
final class ReviewCollectionController {
    fileprivate weak var document: ReviewCollectionDocument?
    fileprivate var pendingFollowID: String?
    fileprivate var pendingReceipt: ReviewCollectionViewportReceipt?
    var onViewportChange: ((ReviewCollectionViewportReceipt) -> Void)?
    var onUserViewportChange: ((ReviewCollectionViewportReceipt) -> Void)?
    var onViewportRestored: ((ReviewCollectionViewportReceipt) -> Void)?

    func follow(id: String) {
        ForegroundWorkCoordinator.shared.noteInteraction()
        pendingReceipt = nil
        pendingFollowID = id
        document?.applyPendingPosition()
    }

    func restoreViewport(_ receipt: ReviewCollectionViewportReceipt) {
        guard receipt.topOffset.isFinite else { return }
        pendingReceipt = receipt
        pendingFollowID = nil
        document?.applyPendingPosition()
    }

    func snapshotViewport() -> ReviewCollectionViewportReceipt? { document?.snapshotViewport() }
}

struct ReviewCollectionRubberBand {
    let shouldBegin: (CGPoint, [Int: CGRect]) -> Bool
    let changed: (CGRect, [Int: CGRect]) -> Void
    let ended: () -> Void
}

/// A native vertical document with a bounded population of hosted SwiftUI cells.
/// The projection/layout is independent of its state owner, so early read-only
/// opening can supply the same bridge without constructing another SessionStore.
struct ReviewCollection: NSViewRepresentable {
    let projection: ReviewCollectionProjection
    let style: ReviewCollectionStyle
    var controller: ReviewCollectionController?
    var rubberBand: ReviewCollectionRubberBand? = nil
    let cell: (ReviewCollectionEntry) -> AnyView
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> ReviewCollectionScrollView {
        let scroll = ReviewCollectionScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Color.appBackground)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let document = ReviewCollectionDocument()
        scroll.documentView = document
        PersistentVerticalScroller.configure(scroll)
        document.configure(projection: projection, style: style, controller: controller,
                           rubberBand: rubberBand, environment: environment, cell: cell)
        return scroll
    }

    func updateNSView(_ scroll: ReviewCollectionScrollView, context: Context) {
        PersistentVerticalScroller.configure(scroll)
        (scroll.documentView as? ReviewCollectionDocument)?.configure(
            projection: projection, style: style, controller: controller,
            rubberBand: rubberBand, environment: environment, cell: cell)
    }

    static func dismantleNSView(_ scroll: ReviewCollectionScrollView, coordinator: ()) {
        (scroll.documentView as? ReviewCollectionDocument)?.dismantle()
    }
}

final class ReviewCollectionScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        ForegroundWorkCoordinator.shared.noteInteraction()
        super.scrollWheel(with: event)
        // Distinguish native input from programmatic follow/layout without
        // changing AppKit's wheel or momentum handling.
        (documentView as? ReviewCollectionDocument)?.userDidScroll()
    }

    override func layout() {
        super.layout()
        (documentView as? ReviewCollectionDocument)?.updateViewport()
        (documentView as? ReviewCollectionDocument)?.applyPendingPosition()
    }
}

/// Retains only viewport cells, one row of overscan and a viewport-sized reuse
/// pool. Offscreen hosts have EmptyView roots, releasing media interests and
/// observed-object subscriptions before they enter the pool.
final class ReviewCollectionDocument: NSView {
    // AppKit's responsive-scrolling worker may advance beyond visibleRect
    // before main-thread bounds observation runs. This document constructs and
    // rebinds SwiftUI hosts synchronously on the main actor and does not promise
    // prepareContent(in:) coverage for that worker's overdraw rectangle. Opt out
    // through the documented NSView contract; native wheel/momentum/scrollers
    // still perform all scrolling, on the same thread as viewport realization.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
    override var isFlipped: Bool { true }
    private var projection: ReviewCollectionProjection?
    private var style: ReviewCollectionStyle = .browser
    private weak var controller: ReviewCollectionController?
    private var environment = EnvironmentValues()
    private var cell: (ReviewCollectionEntry) -> AnyView = { _ in AnyView(EmptyView()) }
    private var rubberBand: ReviewCollectionRubberBand?
    private(set) var geometry: ReviewCollectionGeometry?
    private var viewportSize = CGSize.zero
    private var hosts: [ReviewCollectionGeometry.Element.Key: NSHostingView<AnyView>] = [:]
    private var reusePool: [NSHostingView<AnyView>] = []
    private let configurator = PersistentVerticalScroller.Configurator()
    private let selectionOverlay = ReviewCollectionSelectionOverlay()
    private weak var observedClip: NSClipView?
    private weak var observedScroll: NSScrollView?
    private var mouseMonitor: Any?
    private var dragStart: CGPoint?
    private var dragIsActive = false
    private var updating = false
    private var isDismantled = false
    private var needsCellRebind = false
    private var measurement = NSHostingView(rootView: AnyView(EmptyView()))
    private var measuredTemplates: (width: CGFloat, style: ReviewCollectionStyle, caption: CGFloat, header: CGFloat)?
    private var realizedViewport: CGRect?
    private var realizedElements: [ReviewCollectionGeometry.Element] = []

    // Small deterministic receipts for mounted regression tests and profiling.
    private(set) var geometryGeneration = 0
    private(set) var projectionGeneration = 0
    private(set) var createdHostCount = 0
    private(set) var realizedItemCount = 0
    private(set) var viewportRealizationCount = 0
    private(set) var templateMeasurementCount = 0
    private(set) var contentBindCount = 0
    var retainedHostCount: Int { hosts.count + reusePool.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(configurator)
        addSubview(selectionOverlay)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(projection: ReviewCollectionProjection, style: ReviewCollectionStyle,
                   controller: ReviewCollectionController?, rubberBand: ReviewCollectionRubberBand?,
                   environment: EnvironmentValues, cell: @escaping (ReviewCollectionEntry) -> AnyView) {
        guard !isDismantled else { return }
        let changed = self.projection !== projection || self.style != style
        let environmentChanged = self.environment.locale != environment.locale
            || self.environment.layoutDirection != environment.layoutDirection
            || self.environment.dynamicTypeSize != environment.dynamicTypeSize
            || self.environment.displayScale != environment.displayScale
            || self.environment.colorScheme != environment.colorScheme
            || self.environment.colorSchemeContrast != environment.colorSchemeContrast
            || self.environment.legibilityWeight != environment.legibilityWeight
            || self.environment.accessibilityEnabled != environment.accessibilityEnabled
            || self.environment.accessibilityVoiceOverEnabled != environment.accessibilityVoiceOverEnabled
            || self.environment.accessibilityReduceMotion != environment.accessibilityReduceMotion
            || self.environment.accessibilityReduceTransparency != environment.accessibilityReduceTransparency
            || self.environment.accessibilityDifferentiateWithoutColor != environment.accessibilityDifferentiateWithoutColor
        let receipt = changed || environmentChanged ? snapshotViewport() : nil
        if self.controller !== controller {
            if self.controller?.document === self { self.controller?.document = nil }
            self.controller = controller
            controller?.document = self
        }
        if self.projection !== projection { projectionGeneration += 1 }
        self.projection = projection
        self.style = style
        setAccessibilityLabel(style == .browser ? L10n.text("Browser") : L10n.text("Grid"))
        self.environment = environment
        self.cell = cell
        self.rubberBand = rubberBand
        if environmentChanged { measuredTemplates = nil }
        if changed || environmentChanged {
            geometry = nil
            needsCellRebind = true
            // Section positions and source indices may have changed. No host
            // keeps an earlier entry at the same numeric position.
            recycleAll()
        }
        bind()
        updateViewport()
        if let receipt, controller?.pendingReceipt == nil, controller?.pendingFollowID == nil {
            restore(receipt)
        }
        applyPendingPosition()
    }

    override func accessibilityChildren() -> [Any]? {
        // Hosting views are ignored AX wrappers. Flatten them with AppKit's
        // public helper so the vended nodes report this group as their parent.
        // Projection order survives reuse and the Grid's mirrored RTL columns.
        NSAccessibility.unignoredChildren(from: realizedElements.compactMap { hosts[$0.key] })
    }

    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        accessibilityChildren()?.compactMap { $0 as? any NSAccessibilityElementProtocol }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { unbind() } else { bind(); updateViewport() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { unbind() } else { bind(); updateViewport(); applyPendingPosition() }
    }

    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        unbind()
        configurator.dismantle()
        recycleAll()
        reusePool.removeAll()
        projection = nil
        cell = { _ in AnyView(EmptyView()) }
        if controller?.document === self { controller?.document = nil }
        controller = nil
    }

    private func bind() {
        guard !isDismantled, window != nil, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        if observedClip !== clip {
            unbind()
            observedClip = clip
            observedScroll = scroll
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(userDidScroll),
                name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        configurator.scheduleConfiguration()
        if mouseMonitor == nil, rubberBand != nil {
            // Non-consuming, window-scoped pointer observation lets native
            // Buttons and the immediate click surface keep exact multi-click
            // behavior. It is removed on reparenting/teardown, never global.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.observePointer(event) }
                return event
            }
        }
    }

    private func unbind() {
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip)
        }
        observedClip = nil
        if let observedScroll {
            NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: observedScroll)
        }
        observedScroll = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        dragStart = nil
        dragIsActive = false
        selectionOverlay.selection = nil
    }

    @objc private func boundsChanged() {
        guard !updating, !isDismantled else { return }
        updateViewport()
        if let receipt = snapshotViewport() { controller?.onViewportChange?(receipt) }
    }

    @objc fileprivate func userDidScroll() {
        guard !isDismantled else { return }
        ForegroundWorkCoordinator.shared.noteInteraction()
        guard let receipt = snapshotViewport() else { return }
        controller?.onUserViewportChange?(receipt)
    }

    func updateViewport() {
        guard !isDismantled, !updating, let scroll = enclosingScrollView,
              let projection else { return }
        let size = scroll.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        updating = true
        defer { updating = false }
        let oldReceipt = size != viewportSize ? snapshotViewport() : nil
        if geometry == nil || size.width != viewportSize.width {
            // Projection changes do not change the font templates. Avoid two
            // synchronous SwiftUI fitting/layout passes on each new inventory.
            if measuredTemplates?.width != size.width || measuredTemplates?.style != style {
                measuredTemplates = (size.width, style,
                    measure(AnyView(ReviewGridCaption(title: "Ag")), width: max(1, size.width - 18)),
                    measure(AnyView(ReviewGroupHeader(title: "Ag", style: style)),
                            width: style == .browser ? 102 : max(1, size.width - 18)))
            }
            guard let templates = measuredTemplates else { return }
            realizedViewport = nil
            realizedElements = []
            geometry = ReviewCollectionGeometry(projection: projection, style: style, width: size.width,
                                                captionHeight: templates.caption, headerHeight: templates.header,
                                                rightToLeft: environment.layoutDirection == .rightToLeft)
            geometryGeneration += 1
        }
        viewportSize = size
        guard let geometry else { return }
        let documentSize = CGSize(width: size.width, height: max(size.height + 1, geometry.contentHeight))
        if frame.size != documentSize { setFrameSize(documentSize) }
        configurator.frame = bounds
        selectionOverlay.frame = bounds
        configurator.scheduleConfiguration()
        if let oldReceipt, controller?.pendingReceipt == nil, controller?.pendingFollowID == nil {
            restore(oldReceipt)
        }
        realizeViewport(projection: projection, geometry: geometry)
    }

    private func measure(_ view: AnyView, width: CGFloat) -> CGFloat {
        templateMeasurementCount += 1
        measurement.rootView = AnyView(hostedContent(view)
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        measurement.invalidateIntrinsicContentSize()
        // The same SwiftUI text/header views produce the measurement and pixels.
        // Round only to the actual display pixel, never an assumed font metric.
        let height = measurement.fittingSize.height
        let scale = max(1, environment.displayScale)
        return ceil(height * scale) / scale
    }

    private func realizeViewport(projection: ReviewCollectionProjection, geometry: ReviewCollectionGeometry) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = CGRect(origin: CGPoint(x: 0, y: clip.bounds.minY), size: viewportSize)
        // AppKit can call layout repeatedly for the same bounds, including
        // after a hosted thumbnail publishes pixels. Reuse the mounted result.
        guard visible != realizedViewport || needsCellRebind else { return }
        ForegroundWorkCoordinator.shared.noteInteraction()
        realizedViewport = visible
        let overscan = visible.insetBy(dx: 0, dy: -(geometry.itemHeight + geometry.spacing))
        let elements = geometry.elements(in: overscan, projection: projection)
        guard elements != realizedElements || needsCellRebind else { return }
        realizedElements = elements
        viewportRealizationCount += 1
        let needed = Set(elements.map(\.key))
        for key in Array(hosts.keys) where !needed.contains(key) {
            if let host = hosts.removeValue(forKey: key) { recycle(host) }
        }
        for element in elements {
            let host: NSHostingView<AnyView>
            if let existing = hosts[element.key] {
                host = existing
                if needsCellRebind { bindContent(host, key: element.key, projection: projection) }
            } else {
                if let reused = reusePool.popLast() {
                    host = reused
                } else {
                    host = NSHostingView(rootView: AnyView(EmptyView()))
                    host.sizingOptions = []
                    host.safeAreaRegions = []
                    createdHostCount += 1
                }
                hosts[element.key] = host
                bindContent(host, key: element.key, projection: projection)
                addSubview(host, positioned: .below, relativeTo: selectionOverlay)
            }
            if host.frame != element.frame { host.frame = element.frame }
        }
        needsCellRebind = false
        realizedItemCount = elements.reduce(0) { count, element in
            if case .item = element.key { return count + 1 }; return count
        }
        // A viewport-sized pool is useful after resize and bounded independently
        // of folder size. Pooled roots are empty, so only visible/reuse cells live.
        let poolLimit = max(1, elements.count)
        if reusePool.count > poolLimit { reusePool.removeLast(reusePool.count - poolLimit) }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func bindContent(_ host: NSHostingView<AnyView>, key: ReviewCollectionGeometry.Element.Key,
                             projection: ReviewCollectionProjection) {
        contentBindCount += 1
        let content: AnyView
        switch key {
        case .item(let position):
            let entry = projection.entries[position]
            content = AnyView(cell(entry).id(entry.id))
        case .header(let section):
            content = AnyView(ReviewGroupHeader(title: projection.sections[section].title ?? "", style: style)
                .id(projection.sections[section].id))
        }
        host.rootView = AnyView(hostedContent(content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    }

    private func hostedContent(_ content: AnyView) -> some View {
        // Forward app presentation values, not the outer host's private AX
        // context. Each independent hosting view owns its accessibility tree
        // and reads system accessibility preferences from its native window.
        content
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.displayScale, environment.displayScale)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.font, environment.font)
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.mediaReadAccess, environment.mediaReadAccess)
            .environment(\.accessibilityEnabled, true)
            .tint(Color.louppeAccent)
    }

    private func recycle(_ host: NSHostingView<AnyView>) {
        host.removeFromSuperview()
        host.rootView = AnyView(EmptyView())
        reusePool.append(host)
    }

    private func recycleAll() {
        for host in hosts.values { recycle(host) }
        hosts.removeAll()
        realizedViewport = nil
        realizedElements = []
        realizedItemCount = 0
    }

    func applyPendingPosition() {
        guard !updating, !isDismantled, window != nil,
              let controller, let projection, let geometry else { return }
        if let receipt = controller.pendingReceipt {
            // Consume once this projection can resolve the physical file. A
            // missing/filtered target stays pending for the next projection.
            if restore(receipt) {
                controller.pendingReceipt = nil
                controller.onViewportRestored?(receipt)
            }
        } else if let id = controller.pendingFollowID,
                  let position = projection.positionByID[id],
                  let frame = geometry.itemFrame(at: position, projection: projection) {
            controller.pendingFollowID = nil
            scroll(toY: frame.midY - viewportSize.height / 2)
        }
        if let receipt = snapshotViewport() { controller.onViewportChange?(receipt) }
    }

    @discardableResult
    private func restore(_ receipt: ReviewCollectionViewportReceipt) -> Bool {
        guard let projection, let geometry,
              let position = projection.positionByPhysicalFileID[receipt.physicalFileID],
              let frame = geometry.itemFrame(at: position, projection: projection) else { return false }
        scroll(toY: frame.minY - receipt.topOffset)
        return true
    }

    private func scroll(toY y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let target = min(max(0, y), max(0, bounds.height - clip.bounds.height))
        clip.setBoundsOrigin(CGPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(clip)
        if !updating, let projection, let geometry {
            realizeViewport(projection: projection, geometry: geometry)
        }
    }

    func snapshotViewport() -> ReviewCollectionViewportReceipt? {
        guard let projection, let geometry, let clip = enclosingScrollView?.contentView else { return nil }
        let visible = CGRect(origin: CGPoint(x: 0, y: clip.bounds.minY), size: clip.bounds.size)
        let items = geometry.elements(in: visible, projection: projection).compactMap { element -> (Int, CGRect)? in
            if case .item(let position) = element.key { return (position, element.frame) }; return nil
        }
        guard let first = items.min(by: {
            $0.1.minY == $1.1.minY ? $0.0 < $1.0 : $0.1.minY < $1.1.minY
        }), let physicalID = projection.entries[first.0].physicalFileIDs.first else { return nil }
        return ReviewCollectionViewportReceipt(physicalFileID: physicalID, topOffset: first.1.minY - visible.minY)
    }

    private func visibleTileFrames() -> [Int: CGRect] {
        guard let projection, let geometry, let clip = enclosingScrollView?.contentView else { return [:] }
        let visible = CGRect(origin: CGPoint(x: 0, y: clip.bounds.minY), size: clip.bounds.size)
        return Dictionary(uniqueKeysWithValues: geometry.elements(in: visible, projection: projection).compactMap {
            if case .item(let position) = $0.key { return (projection.entries[position].index, $0.frame) }; return nil
        })
    }

    private func observePointer(_ event: NSEvent) {
        guard !isDismantled, event.window === window, window != nil,
              !isHiddenOrHasHiddenAncestor, let rubberBand else { return }
        let point = convert(event.locationInWindow, from: nil)
        if visibleRect.contains(point) { ForegroundWorkCoordinator.shared.noteInteraction() }
        switch event.type {
        case .leftMouseDown:
            guard visibleRect.contains(point),
                  rubberBand.shouldBegin(point, visibleTileFrames()) else { dragStart = nil; return }
            dragStart = point
            dragIsActive = false
        case .leftMouseDragged:
            guard let start = dragStart else { return }
            if !dragIsActive, hypot(point.x - start.x, point.y - start.y) < 8 { return }
            dragIsActive = true
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(start.x - point.x), height: abs(start.y - point.y))
            selectionOverlay.selection = rect
            rubberBand.changed(rect, visibleTileFrames())
        case .leftMouseUp:
            if dragIsActive { rubberBand.ended() }
            dragStart = nil
            dragIsActive = false
            selectionOverlay.selection = nil
        default: break
        }
    }
}

private final class ReviewCollectionSelectionOverlay: NSView {
    override var isFlipped: Bool { true }
    var selection: CGRect? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let selection else { return }
        let path = NSBezierPath(roundedRect: selection.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        NSColor(Color.louppeAccent).withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor(Color.louppeAccent).withAlphaComponent(0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
