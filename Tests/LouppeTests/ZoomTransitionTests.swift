import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ZoomTransitionTests: XCTestCase {
    func testRemovedViewportDoesNotRestartLoadingDuringLateLayout() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.configure(scale: 1)
        try await fixture.waitForSource()
        try await fixture.waitForTiles()
        fixture.scroll.prepareForRemoval()
        let reportsAfterRemoval = fixture.loadingReports

        // AppKit can still reflect/layout the clip view while SwiftUI removes
        // the representable after S/A switches back to a fitted preview.
        fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
        fixture.scroll.layoutSubtreeIfNeeded()
        fixture.scroll.viewDidChangeBackingProperties()
        XCTAssertEqual(fixture.loadingReports, reportsAfterRemoval,
                       "A removed viewport must not leave a new loading count behind")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.loadingReports, reportsAfterRemoval)

        fixture.loadingReports = []
        fixture.configure(scale: 1)
        try await fixture.waitForTiles()
        XCTAssertEqual(fixture.loadingReports, [true, false],
                       "Explicitly configuring the same photo must start a fresh, balanced load")
    }

    func testGalleryLoadingSettlesAfterRepeatedZoomModeChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = SessionStore()
        store.items = [fixture.item]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.showBrowser = false
        let host = NSHostingView(rootView: GalleryView(store: store))
        fixture.window.contentView = host
        fixture.window.makeKeyAndOrderFront(nil)
        defer { fixture.window.contentView = nil }

        for delay in [150, 5] {
            for mode in [ZoomMode.actual, .small, .actual, .actual, .small, .actual] {
                store.toggleZoom(mode)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
        store.setPhotoZoomScale(1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(store.fullImageLoads, 0,
                       "The toolbar spinner must stop after the displayed photo settles")
    }

    func testLiveFittedPinchDoesNotPaintOverBrowser() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let store = SessionStore()
        store.items = [fixture.item]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.showBrowser = true
        store.zoomMode = .fit
        let host = NSHostingView(rootView: GalleryView(store: store))
        fixture.window.setContentSize(CGSize(width: 600, height: 320))
        fixture.window.contentView = host
        fixture.window.makeKeyAndOrderFront(nil)
        defer { fixture.window.contentView = nil }

        func fittedSurface(in view: NSView) -> FittedImageDoubleClickView? {
            if let fitted = view as? FittedImageDoubleClickView { return fitted }
            return view.subviews.lazy.compactMap { fittedSurface(in: $0) }.first
        }
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if fittedSurface(in: host) != nil, store.fullImageLoads == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let fitted = try XCTUnwrap(fittedSurface(in: host))
        func browserPixel() throws -> NSColor {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Below the only thumbnail and clear of the native scroller.
            let x = Int((BrowserView.width - 25) / host.bounds.width * CGFloat(bitmap.pixelsWide))
            return try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        let before = try browserPixel()
        fitted.beginPinch()
        fitted.updatePinch(delta: 1.5,
                           at: CGPoint(x: fitted.bounds.midX, y: fitted.bounds.midY),
                           backingScale: fixture.window.backingScaleFactor)
        try await Task.sleep(for: .milliseconds(100))
        let during = try browserPixel()
        XCTAssertEqual(during.redComponent, before.redComponent, accuracy: 0.02)
        XCTAssertEqual(during.greenComponent, before.greenComponent, accuracy: 0.02)
        XCTAssertEqual(during.blueComponent, before.blueComponent, accuracy: 0.02)
        XCTAssertEqual(store.zoomMode, .fit, "Check the live preview before the pinch hands off")
    }

    func testCustomZoomReturnsSmoothlyToCenteredActualSizeFromBothDirections() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for initialScale: CGFloat in [0.6, 1.8] {
            fixture.configure(scale: initialScale)
            try await fixture.waitForSource()
            fixture.scroll.contentView.scroll(to: CGPoint(x: 70, y: 90))
            fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)

            fixture.viewport.reset() // The same explicit reset made by S.
            fixture.configure(scale: 1)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try await Task.sleep(for: .milliseconds(60))
                let intermediate = fixture.scroll.magnification
                XCTAssertGreaterThan(intermediate, min(initialScale, 1))
                XCTAssertLessThan(intermediate, max(initialScale, 1))
            }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(fixture.scroll.magnification, 1, accuracy: 0.001)
            XCTAssertEqual(fixture.viewport.position.x, 0.5, accuracy: 0.003)
            XCTAssertEqual(fixture.viewport.position.y, 0.5, accuracy: 0.003)
        }
    }

    func testNewSliderValueInterruptsTheReturnToActualSize() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.configure(scale: 1.8)
        try await fixture.waitForSource()
        fixture.viewport.reset()
        fixture.configure(scale: 1)
        try await Task.sleep(for: .milliseconds(40))
        fixture.configure(scale: 0.75)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.scroll.magnification, 0.75, accuracy: 0.001,
                       "An old animation must not overwrite a newer slider value")
    }

    func testDragInterruptsAnimationAndPublishesTheVisibleScale() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("No in-flight animation when Reduce Motion is enabled")
        }
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.configure(scale: 1.8)
        try await fixture.waitForSource()
        fixture.viewport.reset()
        fixture.configure(scale: 1)
        try await Task.sleep(for: .milliseconds(40))
        let visibleOrigin = fixture.scroll.contentView.bounds.origin
        XCTAssertTrue(fixture.scroll.beginPhotoPan(at: CGPoint(x: 100, y: 100)))
        let scale = try XCTUnwrap(fixture.reportedScale,
                                  "Interruption must replace the store's pending 100% target")
        XCTAssertGreaterThan(scale, 1)
        XCTAssertLessThan(scale, 1.8)
        fixture.configure(scale: scale)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.x, visibleOrigin.x, accuracy: 0.5)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, visibleOrigin.y, accuracy: 0.5)
        fixture.scroll.movePhotoPan(to: CGPoint(x: 120, y: 110))
        fixture.scroll.endPhotoPan()
        fixture.configure(scale: scale)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.scroll.magnification, scale, accuracy: 0.001)
    }

    @MainActor
    private final class Fixture {
        let folder: URL
        let item: PhotoItem
        let window: NSWindow
        let scroll: ActualSizeScrollView
        let viewport = ActualSizeViewport()
        var reportedScale: CGFloat?
        var loadingReports: [Bool] = []

        init() throws {
            _ = NSApplication.shared
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("LouppeZoomTransition-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("photo.jpg")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1600,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let bytes = try XCTUnwrap(bitmap.bitmapData)
            memset(bytes, 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
            try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
            item = PhotoItem(primaryFile: PhotoFile(
                id: UUID().uuidString, url: url, captureDate: nil,
                cameraModel: nil, lensModel: nil, fileSize: 1
            ))
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
            scroll = ActualSizeScrollView(frame: window.contentView!.bounds)
            window.contentView = scroll
        }

        func configure(scale: CGFloat) {
            scroll.configure(item: item, preview: nil, showsClippingWarnings: false,
                             viewport: viewport, onLoading: { [weak self] active in
                                 self?.loadingReports.append(active)
                             }, zoomScale: scale,
                             onZoomScaleChanged: { [weak self] scale, _ in
                                 self?.reportedScale = scale
                             })
            scroll.layoutSubtreeIfNeeded()
        }

        func waitForSource() async throws {
            let width = 2000 / window.backingScaleFactor
            for _ in 0..<200 {
                if abs((scroll.documentView?.frame.width ?? 0) - width) < 1 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("The source-backed document did not load")
        }

        func waitForTiles() async throws {
            for _ in 0..<200 {
                if loadingReports.contains(true), loadingReports.last == false { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Source tiles did not finish loading")
        }

        func close() {
            scroll.prepareForRemoval()
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
