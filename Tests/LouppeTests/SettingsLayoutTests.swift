import AppKit
import SwiftUI
import XCTest
#if !APP_STORE
import Sparkle
#endif
@testable import Louppe

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testAllSettingsShareOneScrollableForm() throws {
        let store = SessionStore()
        #if APP_STORE
        let settings = LouppeSettingsView(store: store)
        #else
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let settings = LouppeSettingsView(store: store, updater: controller.updater)
        #endif
        let host = NSHostingView(rootView: settings.preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(host)

        let scrollViews = descendants(host).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrollViews.count, 1, "Settings must not nest independent scrolling panels")
        let scroll = try XCTUnwrap(scrollViews.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        XCTAssertEqual(host.bounds.width, 520, accuracy: 1)
        XCTAssertEqual(host.bounds.height, 600, accuracy: 1)
        try snapshot(host, name: "top")

        document.scroll(NSPoint(x: 0, y: 520))
        settle(host)
        try snapshot(host, name: "middle")

        document.scroll(NSPoint(x: 0, y: document.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The lower settings must be reachable")
        try snapshot(host, name: "bottom")
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_SETTINGS_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
