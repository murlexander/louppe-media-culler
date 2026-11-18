import AppKit
import SwiftUI

/// Opt-in readout for a drag of the collection's native scroller knob. The
/// closure resolves the first visible entry; nil (a stale or ineligible
/// entry) hides the label until a current value exists.
struct ReviewCollectionScrollerLabel {
    let text: (ReviewCollectionEntry) -> String?
}

/// Shows a passive label beside the native knob only while that knob is
/// dragged. AppKit keeps the scroller, its tracking loop and the clip; this
/// observes the original press and the scroll view's live-scroll lifecycle.
/// Track clicks, wheel, momentum and programmatic scrolling never show it.
@MainActor
final class ReviewCollectionKnobLabel {
    static let edgeInset: CGFloat = 6
    static let verticalInset: CGFloat = 5

    private weak var scroll: ReviewCollectionScrollView?
    private var label: ReviewCollectionScrollerLabel?
    private var environment = EnvironmentValues()
    private let overlay = ReviewCollectionKnobLabelOverlay()
    private var mouseMonitor: Any?
    private weak var observedScroll: NSScrollView?
    /// A left press that began on the knob, consumed by the next live scroll.
    private var pressArmed = false
    private var trackingStartY: CGFloat?
    private var lastPosition: Int?
    /// The scroller's own value description, restored when the drag ends.
    private var priorValueDescription: String??
    private(set) var text: String?
    var isShowing: Bool { !overlay.isHidden }
    var frame: CGRect { overlay.frame }

    #if LOUPPE_TEST_SEAMS
    /// Called synchronously after each presentation update while tracking,
    /// shown or hidden, inside AppKit's tracking loop during a real drag.
    static var didUpdate: ((ReviewCollectionKnobLabel) -> Void)?
    private(set) var lookupCount = 0
    #endif

    init(scroll: ReviewCollectionScrollView) {
        self.scroll = scroll
        overlay.isHidden = true
    }

    func configure(_ label: ReviewCollectionScrollerLabel?, environment: EnvironmentValues) {
        self.label = label
        if self.environment.layoutDirection != environment.layoutDirection
            || self.environment.locale != environment.locale {
            self.environment = environment
            text = nil
            lastPosition = nil
        }
        // Sort or source changes mid-drag retire the readout immediately.
        if label == nil { cancel() } else { lastPosition = nil }
        bind()
    }

    func bind() {
        guard let scroll, label != nil, scroll.window != nil else { return unbind() }
        if observedScroll !== scroll {
            observedScroll = scroll
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(willStartLiveScroll),
                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(didLiveScroll),
                               name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(didEndLiveScroll),
                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        if mouseMonitor == nil {
            // Non-consuming and window-scoped: only the original press location
            // is read. AppKit's nested knob loop owns the drag and release.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.observePress(event) }
                return event
            }
        }
    }

    func unbind() {
        cancel()
        if let observedScroll {
            let center = NotificationCenter.default
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification,
                         NSScrollView.didEndLiveScrollNotification] {
                center.removeObserver(self, name: name, object: observedScroll)
            }
        }
        observedScroll = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// A wheel or trackpad gesture is never a knob drag.
    func noteWheel() {
        if trackingStartY == nil { pressArmed = false }
    }

    private func observePress(_ event: NSEvent) {
        guard let scroll, let window = scroll.window, event.window === window else { return }
        guard event.type == .leftMouseDown else { pressArmed = false; return }
        // Gate on where the press began: jump-to-click moves the knob under
        // the pointer before tracking starts, and page clicks never track it.
        guard let scroller = scroll.verticalScroller, scroller.isEnabled,
              !scroller.isHiddenOrHasHiddenAncestor, scroller.knobProportion < 1 else {
            pressArmed = false
            return
        }
        pressArmed = scroller.testPart(event.locationInWindow) == .knob
    }

    @objc private func willStartLiveScroll(_ notification: Notification) {
        // AppKit can post the lifecycle more than once for one knob drag.
        guard trackingStartY == nil else { return }
        let fromPress = pressArmed
            && [.leftMouseDown, .leftMouseDragged].contains(NSApp.currentEvent?.type)
        pressArmed = false
        guard fromPress, let scroll else { return }
        begin(scroll)
    }

    private func begin(_ scroll: NSScrollView) {
        trackingStartY = scroll.contentView.bounds.minY
        lastPosition = nil
        // Never open a drag with the previous drag's month.
        text = nil
        overlay.isHidden = true
        priorValueDescription = .some(scroll.verticalScroller?.accessibilityValueDescription())
    }

    @objc private func didLiveScroll(_ notification: Notification) {
        guard let start = trackingStartY, let scroll else { return }
        // Show on the first real vertical movement, then follow the knob even
        // if it returns to the starting offset.
        if overlay.isHidden, scroll.contentView.bounds.minY == start { return }
        present()
    }

    @objc private func didEndLiveScroll(_ notification: Notification) {
        cancel()
    }

    func cancel() {
        trackingStartY = nil
        overlay.isHidden = true
        if let prior = priorValueDescription {
            scroll?.verticalScroller?.setAccessibilityValueDescription(prior)
        }
        priorValueDescription = nil
    }

    #if LOUPPE_TEST_SEAMS
    /// Presents at the current offset without a drag, for static captures.
    func presentForCapture() {
        guard let scroll else { return }
        begin(scroll)
        present()
    }
    #endif

    private func present() {
        guard let scroll, let label, let document = scroll.documentView as? ReviewCollectionDocument,
              let scroller = scroll.verticalScroller else { return cancel() }
        guard trackingStartY != nil else { return }
        #if LOUPPE_TEST_SEAMS
        defer { Self.didUpdate?(self) }
        #endif
        if overlay.superview !== scroll || scroll.subviews.last !== overlay {
            // Stay above the clip after AppKit retiles the scroll view.
            scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        var changed = false
        if let entry = document.firstVisibleEntry(), entry.position != lastPosition {
            #if LOUPPE_TEST_SEAMS
            lookupCount += 1
            #endif
            lastPosition = entry.position
            let next = label.text(entry.entry)
            if next != text {
                text = next
                changed = true
                if let next { overlay.show(text: next, environment: environment) }
            }
        }
        guard let text else {
            overlay.isHidden = true
            return
        }
        // VoiceOver reads the month with the scroller's numeric value; no
        // announcement is posted for each movement.
        if changed || overlay.isHidden { scroller.setAccessibilityValueDescription(text) }
        let knob = scroll.convert(scroller.rect(for: .knob), from: scroller)
        let bar = scroll.convert(scroller.bounds, from: scroller)
        let clip = scroll.contentView.frame
        let leftGutter = bar.midX < clip.midX
        // An overlay-style scroller lies over the clip; stay clear of it.
        let minX = leftGutter ? max(clip.minX, bar.maxX) : clip.minX
        let maxX = leftGutter ? clip.maxX : min(clip.maxX, bar.minX)
        let size = overlay.fittedSize
        let width = min(size.width, maxX - minX - 2 * Self.edgeInset)
        guard !knob.isEmpty, width > 0, clip.height >= size.height + 2 * Self.verticalInset else {
            overlay.isHidden = true
            return
        }
        let x = leftGutter ? minX + Self.edgeInset : maxX - Self.edgeInset - width
        let y = min(max(knob.midY - size.height / 2, clip.minY + Self.verticalInset),
                    clip.maxY - Self.verticalInset - size.height)
        let frame = scroll.backingAlignedRect(CGRect(x: x, y: y, width: width, height: size.height),
                                              options: .alignAllEdgesNearest)
        if overlay.frame != frame { overlay.frame = frame }
        overlay.isHidden = false
    }
}

/// Pointer- and accessibility-transparent: the native scroller stays the one
/// control, and its value description carries the month for VoiceOver.
final class ReviewCollectionKnobLabelOverlay: NSView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var fittedSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        host.setAccessibilityElement(false)
        addSubview(host)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilityElement() -> Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    /// Light and dark follow the window's effective appearance.
    func show(text: String, environment: EnvironmentValues) {
        host.rootView = AnyView(ReviewCollectionKnobLabelContent(text: text)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection))
        host.invalidateIntrinsicContentSize()
        fittedSize = host.fittingSize
    }
}

struct ReviewCollectionKnobLabelContent: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .modifier(FloatingControlSurface(shape: Capsule(), reduceTransparency: reduceTransparency,
                                             contrast: contrast, role: .panel))
            .accessibilityHidden(true)
    }
}
