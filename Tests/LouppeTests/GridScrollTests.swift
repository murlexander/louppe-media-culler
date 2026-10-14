import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class GridScrollTests: XCTestCase {
    func testGridFitsItsVerticalViewportAfterResizeThumbnailChangesAndNavigation() async throws {
        _ = NSApplication.shared
        let store = readyStore()
        let host = NSHostingView(rootView: GridView(store: store))
        let window = mountedWindow(host)
        defer { window.close() }
        for width in [CGFloat(280), 420, 620, 900, 1100] {
            window.setContentSize(NSSize(width: width, height: 500))
            for thumbnailSize in [CGFloat(90), 170, 400] {
                store.gridThumbSize = thumbnailSize
                try await settle(host)
                let scroll = try nativeScroll(in: host)
                assertVerticalViewport(scroll)
                let expectedColumns = max(1, Int((scroll.contentView.bounds.width - 18 + 10) / (thumbnailSize + 10)))
                XCTAssertEqual(store.gridColumnCount, expectedColumns,
                               "Arrow navigation must match the rendered columns")
            }
        }
        store.setIndex(119)
        try await settle(host)
        let scroll = try nativeScroll(in: host)
        assertVerticalViewport(scroll)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
    }

    func testEmptyAndNoMatchingGridStayInsideVerticalViewport() async throws {
        _ = NSApplication.shared
        for empty in [true, false] {
            let store = readyStore()
            if empty {
                store.items = []
                store.rebuildDerivedDataForTesting()
            } else {
                store.filter.excludedMediaKinds = [.photo]
                XCTAssertTrue(store.visibleIndices.isEmpty)
            }
            let host = NSHostingView(rootView: GridView(store: store))
            let window = mountedWindow(host)
            defer { window.close() }
            try await settle(host)
            // Empty states have no tile scroller. If the system message owns
            // a scroll view, it must still fit its native viewport.
            for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
                assertVerticalViewport(scroll)
            }
        }
    }

    func testNativeScrollerRepairsHorizontalConfigurationDrift() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        PersistentVerticalScroller.configure(scroll)
        // SwiftUI can update the enclosing native view after the bridge has
        // installed its vertical gutter. A subsequent pass must repair axes too.
        scroll.hasHorizontalScroller = true
        scroll.horizontalScrollElasticity = .allowed
        PersistentVerticalScroller.configure(scroll)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
    }

    func testShortGridFitsWithInfoPanelAndLargeThumbnails() async throws {
        _ = NSApplication.shared
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for count in [1, 5, 30] {
                let store = readyStore()
                store.items = Array(store.items.prefix(count))
                store.rebuildDerivedDataForTesting()
                store.showMetadataPanel = true
                // Exercise the minimum-height guard at standard and Retina scales.
                let scale: CGFloat = count == 1 ? 1 : 2
                let host = NSHostingView(rootView: SessionView(store: store)
                    .environment(\.layoutDirection, direction)
                    .environment(\.displayScale, scale))
                let window = mountedWindow(host)
                defer { window.close() }
                for width in [CGFloat(620), 1100] {
                    window.setContentSize(NSSize(width: width, height: 800))
                    for thumbnailSize in [CGFloat(170), 400] {
                        store.gridThumbSize = thumbnailSize
                        try await settle(host)
                        let grid = try XCTUnwrap(descendants(host).compactMap { $0 as? SessionRenderMarker.MarkerView }
                            .first { $0.kind == .grid })
                        // Identify Grid by its actual tile surfaces, excluding Info.
                        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                            .first { descendants($0).contains { $0 is GridImmediateClickSurface.ClickView } })
                        XCTAssertEqual(scroll.frame.width, grid.frame.width, accuracy: 0.5,
                                       "Short content must retain the full native pane width")
                        assertVerticalViewport(scroll)
                        if count == 1 {
                            XCTAssertLessThanOrEqual(scroll.documentView!.frame.height - scroll.contentView.bounds.height,
                                                     1 / scale + 0.1,
                                                     "The short-grid workaround must add at most one backing pixel")
                        }
                    }
                }
            }
        }
    }

    private func assertVerticalViewport(_ scroll: NSScrollView, file: StaticString = #filePath, line: UInt = #line) {
        guard let document = scroll.documentView else {
            return XCTFail("Grid needs its native document", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 0.5, file: file, line: line)
        let requested = NSRect(origin: NSPoint(x: 100, y: 100), size: scroll.contentView.bounds.size)
        XCTAssertEqual(scroll.contentView.constrainBoundsRect(requested).minX, 0, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5, file: file, line: line)
        XCTAssertTrue(scroll.hasVerticalScroller, file: file, line: line)
        XCTAssertEqual(scroll.scrollerStyle, .legacy, file: file, line: line)
        XCTAssertFalse(scroll.hasHorizontalScroller, file: file, line: line)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none, file: file, line: line)
        for surface in descendants(scroll).compactMap({ $0 as? GridImmediateClickSurface.ClickView }) {
            guard !surface.isHiddenOrHasHiddenAncestor, !surface.visibleRect.isEmpty else { continue }
            let frame = surface.convert(surface.bounds, to: document)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "A narrow pane must not crop tiles on the leading edge", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.width + 0.5,
                                     "A narrow pane must not overflow tiles on the trailing edge", file: file, line: line)
        }
    }

    private func readyStore() -> SessionStore {
        let store = SessionStore()
        store.items = (0..<120).map { index in
            let name = String(format: "GRID_%03d.JPG", index)
            return PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/tmp/\(name)"),
                             pairedURL: nil, captureDate: Date(timeIntervalSince1970: Double(index / 12) * 86400),
                             cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.viewMode = .grid
        return store
    }

    private func mountedWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private func nativeScroll(in view: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
