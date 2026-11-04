import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class BrowserScrollTests: XCTestCase {
    func testShortBrowserCannotScrollSideways() async throws {
        _ = NSApplication.shared
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for scale in [CGFloat(1), 2] {
                for count in [1, 4, 30] {
                    let store = SessionStore()
                    store.items = (0..<count).map { index in
                        PhotoItem(id: "SHORT_\(index).JPG",
                                  primaryURL: URL(fileURLWithPath: "/tmp/SHORT_\(index).JPG"),
                                  pairedURL: nil, captureDate: nil, cameraModel: nil,
                                  lensModel: nil, fileSize: 1)
                    }
                    store.phase = .ready
                    store.rebuildDerivedDataForTesting()
                    let host = NSHostingView(rootView: BrowserView(store: store)
                        .environment(\.layoutDirection, direction)
                        .environment(\.displayScale, scale))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: BrowserView.width, height: 900),
                                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                    window.orderBack(nil)
                    window.makeKey()
                    defer { window.close() }
                    try await settle(host)
                    let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
                    XCTAssertEqual(scroll.frame.width, BrowserView.width, accuracy: 0.5, "Short Browser must keep its gutter inside its allocated pane")
                    try assertContentFits(scroll)
                    try VerticalScrollRegression.assertWheelInputStaysVertical(scroll)
                }
            }
        }
    }

    func testBrowserStaysVerticalDuringScrollingAndFollowNavigation() async throws {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = (0..<30).map { index in
            PhotoItem(id: "BROWSER_\(index).JPG",
                      primaryURL: URL(fileURLWithPath: "/tmp/BROWSER_\(index).JPG"),
                      pairedURL: nil, captureDate: nil, cameraModel: nil,
                      lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        let host = NSHostingView(rootView: BrowserView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: BrowserView.width, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        defer { window.close() }
        try await settle(host)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        print("Browser geometry before scroll: clip=\(scroll.contentView.bounds), document=\(document.frame), content=\(scroll.contentSize)")
        let requested = NSRect(origin: NSPoint(x: 100, y: 100), size: scroll.contentView.bounds.size)
        let constrained = scroll.contentView.constrainBoundsRect(requested)
        scroll.contentView.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        try await settle(host)
        print("Browser geometry after scroll: clip=\(scroll.contentView.bounds), document=\(document.frame)")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        try assertContentFits(scroll)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
        store.setIndex(29)
        try await settle(host)
        print("Browser geometry after follow: clip=\(scroll.contentView.bounds), document=\(document.frame)")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500, "Following a distant photo must still scroll vertically")
        try assertContentFits(scroll)
        store.setIndex(0)
        try await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    func testShortBrowserKeepsItsColumnAfterInfoResizeAndViewSwitches() async throws {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = (0..<4).map { index in
            PhotoItem(id: "SESSION_\(index).JPG",
                      primaryURL: URL(fileURLWithPath: "/tmp/SESSION_\(index).JPG"),
                      pairedURL: nil, captureDate: nil, cameraModel: nil,
                      lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.showBrowser = true
        store.rebuildDerivedDataForTesting()
        let host = NSHostingView(rootView: SessionView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        defer { window.close() }
        for info in [false, true] {
            store.showMetadataPanel = info
            for width in [CGFloat(620), 1100] {
                window.setContentSize(NSSize(width: width, height: 720))
                store.viewMode = .grid
                try await settle(host)
                store.viewMode = .gallery
                try await settle(host)
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                    .first { scroll in
                        !scroll.isHiddenOrHasHiddenAncestor && descendants(scroll).contains {
                            $0 is PersistentVerticalScroller.Configurator
                        }
                    })
                XCTAssertEqual(scroll.frame.width, BrowserView.width, accuracy: 0.5)
                try assertContentFits(scroll)
                try VerticalScrollRegression.assertWheelInputStaysVertical(scroll)
            }
        }
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private func assertContentFits(_ scroll: NSScrollView) throws {
        let document = try XCTUnwrap(scroll.documentView)
        // The bridge is mounted on the actual padded 122pt column, before its
        // flexible outer document. Verify content, not the empty gutter tail.
        let column = try XCTUnwrap(descendants(document).compactMap {
            $0 as? PersistentVerticalScroller.Configurator
        }.first)
        let frame = column.convert(column.bounds, to: document)
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frame.width, 122, accuracy: 0.5)
        XCTAssertLessThanOrEqual(frame.maxX, scroll.contentView.bounds.width + 0.5)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
