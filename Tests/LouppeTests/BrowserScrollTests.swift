import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class BrowserScrollTests: XCTestCase {
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
        window.makeKeyAndOrderFront(nil)
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
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 0.5)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
        store.setIndex(29)
        try await settle(host)
        print("Browser geometry after follow: clip=\(scroll.contentView.bounds), document=\(document.frame)")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500, "Following a distant photo must still scroll vertically")
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 0.5)
        store.setIndex(0)
        try await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
