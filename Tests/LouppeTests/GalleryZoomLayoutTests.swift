import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class GalleryZoomLayoutTests: XCTestCase {
    func testCompactReadoutKeepsPillSizeStableWhileDetailLoads() throws {
        _ = NSApplication.shared
        let store = readyStore()
        let revision = try XCTUnwrap(store.currentItem?.contentRevision)
        store.zoomToFit()
        store.reportFittedPhotoZoomScale(0.23, revision: revision, mode: .fit)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: PhotoZoomControl(store: store).fixedSize()
                    .environment(\.layoutDirection, direction)
                    .preferredColorScheme(scheme))
                let window = mountedWindow(host, width: 240, height: 60)
                defer { window.close() }
                settle(host)
                let idle = host.fittingSize
                XCTAssertLessThanOrEqual(idle.width, 240, "The percentage must not reserve a separate trailing indicator column")
                for representation in [PhotoRepresentation.loadingPreview, .preview, .loadingRAW, .raw, .unavailable] {
                    store.reportPhotoRepresentation(representation, revision: revision)
                    settle(host)
                    XCTAssertEqual(host.fittingSize.width, idle.width, accuracy: 0.5,
                                   "Loading must not resize the pill or shift its native controls")
                    XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5)
                }
            }
        }
    }

    func testSessionMediaUsesFullHeightWithBothPanelsHidden() async throws {
        _ = NSApplication.shared
        let store = readyStore()
        let host = NSHostingView(rootView: SessionView(store: store))
        let window = mountedWindow(host, width: 900, height: 640)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let marker = try XCTUnwrap(descendants(host)
            .compactMap { $0 as? SessionRenderMarker.MarkerView }
            .first { $0.kind == .gallery })
        let frame = marker.convert(marker.bounds, to: host)
        XCTAssertEqual(frame.height, host.bounds.height, accuracy: 1,
                       "No bottom status strip may reduce the media viewport")
        XCTAssertEqual(frame.width, host.bounds.width, accuracy: 1)
    }

    func testFloatingControlFitsNarrowPhotoPaneInLightDarkAndRTL() throws {
        _ = NSApplication.shared
        let store = readyStore()
        store.setPhotoZoomScale(2.7)
        for scheme in [ColorScheme.light, .dark] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let host = NSHostingView(rootView: PhotoZoomControl(store: store)
                    .environment(\.layoutDirection, direction)
                    .preferredColorScheme(scheme))
                let window = mountedWindow(host, width: 276, height: 60)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, 276)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 60)
                XCTAssertEqual(host.fittingSize.height, 36, accuracy: 0.5,
                               "Zoom glass must match the native toolbar group height")
                try snapshot(host, name: "zoom-\(scheme)-\(direction)")
            }
        }
    }

    func testFitAndSliderReceiveNativeClicksOnFloatingSurface() throws {
        _ = NSApplication.shared
        let store = readyStore()
        store.setPhotoZoomScale(2.7)
        let host = NSHostingView(rootView: PhotoZoomControl(store: store).fixedSize())
        let size = host.fittingSize
        let window = mountedWindow(host, width: size.width, height: size.height)
        defer { window.close() }
        settle(host)

        // The intrinsic capsule has 12-point side padding and a 30-point Fit
        // target, followed by a 10-point gap and the 120-point native slider.
        try click(host, window: window, x: 27, fromTop: size.height / 2)
        XCTAssertEqual(store.zoomMode, .fit, "Fit must activate through the glass surface")
        try click(host, window: window, x: 80, fromTop: size.height / 2)
        XCTAssertEqual(store.zoomMode, .actual, "The slider must accept input after Fit")
        XCTAssertLessThan(store.photoZoomScale, 2.7)
    }

    func testDoubleClickAcrossZoomCapsuleReturnsToFit() throws {
        _ = NSApplication.shared
        let store = readyStore()
        let host = NSHostingView(rootView: PhotoZoomControl(store: store).fixedSize())
        let size = host.fittingSize
        let window = mountedWindow(host, width: size.width, height: size.height)
        defer { window.close() }
        // Track, thumb, percentage, and padded glass all share the Fit action.
        for x in [CGFloat(80), 145, size.width - 30, size.width / 2] {
            store.setPhotoZoomScale(2.7)
            settle(host)
            let y: CGFloat = x == size.width / 2 ? 5 : size.height / 2
            try click(host, window: window, x: x, fromTop: y)
            try click(host, window: window, x: x, fromTop: y, clickCount: 2)
            XCTAssertEqual(store.zoomMode, .fit, "Double-click must fit at x=\(x), y=\(y)")
        }
    }

    func testSliderDraggingStillChangesZoom() throws {
        _ = NSApplication.shared
        let store = readyStore()
        store.setPhotoZoomScale(2.7)
        let host = NSHostingView(rootView: PhotoZoomControl(store: store).fixedSize())
        let size = host.fittingSize
        let window = mountedWindow(host, width: size.width, height: size.height)
        defer { window.close() }
        settle(host)
        let start = host.convert(NSPoint(x: 145, y: size.height / 2), to: nil)
        let end = host.convert(NSPoint(x: 110, y: size.height / 2), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: start, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: end, modifierFlags: [], timestamp: time + 0.02,
            windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(drag, atStart: true)
        NSApp.sendEvent(down)
        while let queued = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        settle(host)
        XCTAssertEqual(store.zoomMode, .actual)
        XCTAssertLessThan(store.photoZoomScale, 2)
        XCTAssertGreaterThan(store.photoZoomScale, 0.3)
    }

    func testDoubleClickIsScopedToVisibleCapsuleAndItsWindowLifetime() throws {
        _ = NSApplication.shared
        let store = readyStore()
        store.setPhotoZoomScale(2.7)
        let control = AnyView(PhotoZoomControl(store: store).fixedSize()
            .frame(width: 400, height: 120, alignment: .topLeading))
        let host = NSHostingView(rootView: control)
        let window = mountedWindow(host, width: 400, height: 120)
        let otherHost = NSView()
        let otherWindow = mountedWindow(otherHost, width: 400, height: 120)
        defer { window.close(); otherWindow.close() }
        settle(host)
        try click(otherHost, window: otherWindow, x: 100, fromTop: 18, clickCount: 2)
        XCTAssertEqual(store.zoomMode, .actual, "Other windows must keep their own double-click behavior")
        try click(host, window: window, x: 300, fromTop: 18, clickCount: 2)
        XCTAssertEqual(store.zoomMode, .actual, "Clicks beyond the capsule must pass through")
        host.rootView = AnyView(Color.clear)
        settle(host)
        try click(host, window: window, x: 100, fromTop: 18, clickCount: 2)
        XCTAssertEqual(store.zoomMode, .actual, "A removed zoom control must not retain its monitor")
        host.rootView = control
        settle(host)
        try click(host, window: window, x: 100, fromTop: 18, clickCount: 2)
        XCTAssertEqual(store.zoomMode, .fit, "The control must work again after reattaching")
    }

    private func click(_ host: NSView, window: NSWindow, x: CGFloat, fromTop: CGFloat, clickCount: Int = 1) throws {
        let point = host.convert(NSPoint(x: x, y: host.isFlipped ? fromTop : host.bounds.height - fromTop), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: clickCount, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        settle(host)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = [PhotoItem(
            id: "ZOOM.JPG", primaryURL: URL(fileURLWithPath: "/tmp/ZOOM.JPG"),
            pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1
        )]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.showBrowser = false
        store.showMetadataPanel = false
        return store
    }

    private func mountedWindow(_ host: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_ZOOM_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
