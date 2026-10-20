import SwiftUI
import AppKit

/// Configures the enclosing SwiftUI ScrollView with AppKit's permanently
/// visible native vertical scroller. The non-overlay style reserves a real
/// gutter and lets AppKit keep the indicator synchronized during live scroll.
struct PersistentVerticalScroller: NSViewRepresentable {
    static let gutterWidth = NSScroller.scrollerWidth(
        for: .regular,
        scrollerStyle: .legacy
    )

    func makeNSView(context: Context) -> NSView {
        Configurator()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Configurator)?.scheduleConfiguration()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? Configurator)?.dismantle()
    }

    /// Internal for the focused AppKit regression check.
    static func configure(_ scrollView: NSScrollView) {
        // updateNSView re-runs this on every SwiftUI update pass (every store
        // publish). Once the scroll view holds a fully configured scroller,
        // skip the replace/tile work; any drifted property re-takes the full
        // path, so the invariant remains self-healing.
        if scrollView.scrollerStyle == .legacy,
           scrollView.hasVerticalScroller,
           !scrollView.hasHorizontalScroller,
           scrollView.horizontalScrollElasticity == .none,
           !scrollView.autohidesScrollers,
           scrollView.verticalScroller?.controlSize == .regular,
           scrollView.verticalScroller?.isHidden == false,
           scrollView.verticalScroller?.alphaValue == 1 {
            return
        }
        // Keep the NSScroller object installed by AppKit. Replacing it with a
        // hand-drawn subclass made the indicator miss live-scroll frames while
        // the lazy Grid was realizing tiles.
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScroller?.controlSize = .regular
        scrollView.verticalScroller?.isHidden = false
        scrollView.verticalScroller?.alphaValue = 1
        scrollView.autohidesScrollers = false
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    final class Configurator: NSView {
        private var configurationScheduled = false
        private weak var observedClipView: NSClipView?
        private var correctingHorizontalOrigin = false
        private var isDismantled = false

        func dismantle() {
            isDismantled = true
            stopObserving()
        }

        private func stopObserving() {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
            observedClipView = nil
        }

        private func bind(to scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            if observedClipView !== clipView {
                stopObserving()
                observedClipView = clipView
                clipView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(clipBoundsChanged),
                    name: NSView.boundsDidChangeNotification, object: clipView
                )
            }
            pinHorizontalOrigin()
        }

        @objc private func clipBoundsChanged(_ notification: Notification) {
            pinHorizontalOrigin()
        }

        private func pinHorizontalOrigin() {
            guard !correctingHorizontalOrigin, let clipView = observedClipView,
                  clipView.bounds.origin.x != 0 else { return }
            // Hiding a scroller and disabling rubber-banding do not lock an
            // axis. SwiftUI layout/follow-scroll can still introduce X travel.
            // Correct synchronously, preserving the native clip and vertical Y.
            correctingHorizontalOrigin = true
            clipView.setBoundsOrigin(NSPoint(x: 0, y: clipView.bounds.origin.y))
            clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
            correctingHorizontalOrigin = false
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil { stopObserving(); return }
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopObserving(); return }
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !isDismantled else { return }
            // Once mounted, update synchronously. Queueing one block for every
            // lazy-Grid update can make those callbacks compete with live
            // scrolling even though configure itself immediately returns.
            if let scrollView = enclosingScrollView {
                PersistentVerticalScroller.configure(scrollView)
                bind(to: scrollView)
                return
            }

            // SwiftUI can install its NSScrollView around this representable
            // later in the first update pass. Coalesce those unresolved calls
            // into one next-turn lookup.
            guard !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismantled else { return }
                self.configurationScheduled = false
                guard let scrollView = self.enclosingScrollView else { return }
                PersistentVerticalScroller.configure(scrollView)
                self.bind(to: scrollView)
            }
        }
    }
}
