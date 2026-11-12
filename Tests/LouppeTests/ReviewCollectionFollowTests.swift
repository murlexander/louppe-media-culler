import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Composed UI regressions. Windows stay inactive and offscreen; input goes
/// through the installed session monitor or the rendered native controls.
@MainActor
final class ReviewCollectionFollowTests: XCTestCase {
    func testCurrentTileStaysVisibleAfterSortAndResize() async throws {
        for mode in [ViewMode.gallery, .grid] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let store = readyStore()
                store.viewMode = mode
                let host = NSHostingView(rootView: HStack(spacing: 0) {
                    Group {
                        if mode == .gallery { BrowserView(store: store).frame(width: BrowserView.width) }
                        else { GridView(store: store) }
                    }
                    SortView(store: store)
                }.environment(\.layoutDirection, direction).environment(\.accessibilityEnabled, true))
                let window = mount(host, size: CGSize(width: mode == .gallery ? BrowserView.width + 340 : 990, height: 700))
                defer { window.contentView = nil; window.close() }
                store.setIndex(50)
                try await settle(host)
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
                try assertCurrentVisible(store, in: scroll)

                // Exercise the production Sort binding through its native menu.
                let order = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.last)
                let menu = try XCTUnwrap(order.menu)
                let coordinator = try XCTUnwrap(menu.delegate as? NSObject)
                coordinator.perform(NSSelectorFromString("popUpButtonCell:willShowMenu:"), with: order.cell, with: menu)
                let descending = try XCTUnwrap(menu.items.firstIndex { $0.title == store.sort.key.descendingLabel })
                menu.performActionForItem(at: descending)
                try await settle(host)
                XCTAssertFalse(store.sort.ascending)
                XCTAssertEqual(store.currentIndex, 50)
                try assertCurrentVisible(store, in: scroll)

                // Shrinking the window must retain the current tile, rather
                // than only the old first visible item.
                window.setContentSize(CGSize(width: window.contentLayoutRect.width, height: 300))
                try await settle(host)
                try assertCurrentVisible(store, in: scroll)
                XCTAssertEqual(scroll.contentView.bounds.minX, 0)
            }
        }
    }

    func testResizeKeepsCurrentVisibleWithoutInterruptingManualScrolling() async throws {
        for mode in [ViewMode.gallery, .grid] {
            let store = readyStore()
            store.viewMode = mode
            let host = NSHostingView(rootView: Group {
                if mode == .gallery { BrowserView(store: store) } else { GridView(store: store) }
            }.environment(\.accessibilityEnabled, true))
            let width = mode == .gallery ? BrowserView.width : 650
            let window = mount(host, size: CGSize(width: width, height: 700))
            defer { window.contentView = nil; window.close() }
            store.setIndex(50)
            try await settle(host)
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
            try assertCurrentVisible(store, in: scroll)
            window.setContentSize(CGSize(width: width, height: 260))
            try await settle(host)
            XCTAssertEqual(scroll.contentView.bounds.height, 260, accuracy: 1)
            try assertCurrentVisible(store, in: scroll)

            // A real pixel-wheel event scrolls away from the current tile.
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 100_000, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            try await settle(host)
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
            window.setContentSize(CGSize(width: width, height: 400))
            try await settle(host)
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1,
                           "Resizing must not pull a manually scrolled viewport back to the current item")
        }
    }

    func testReceiptRestoredViewportKeepsCurrentVisibleAfterSort() async throws {
        // A remembered position (opening handoff, pinned folder, archive
        // folder switch) mounts the collection through a viewport receipt
        // instead of following the current item. A current tile visible in
        // that restored viewport must survive the first reorder as well.
        for mode in [ViewMode.gallery, .grid] {
            let store = readyStore()
            store.viewMode = mode
            let width = mode == .gallery ? BrowserView.width : 650
            let columns = mode == .gallery ? 1
                : ReviewCollectionMetrics.gridColumnCount(paneWidth: width, thumbnailSize: store.gridThumbSize)
            // The anchor starts a row in descending order too, so the current
            // tile (beside or just below it now) lands one row above the
            // restored anchor after reversing the order.
            let anchor = 99 - columns * (51 / columns)
            let current = anchor + max(columns - 1, 1)
            store.setIndex(current)
            let anchorFileID = store.items[anchor].individualFiles[0].id
            let receipt = ReviewCollectionViewportReceipt(physicalFileID: anchorFileID, topOffset: 0)
            let host = NSHostingView(rootView: Group {
                if mode == .gallery { BrowserView(store: store, initialViewportReceipt: receipt) }
                else { GridView(store: store, initialViewportReceipt: receipt) }
            }.environment(\.accessibilityEnabled, true))
            let window = mount(host, size: CGSize(width: width, height: 700))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
            let document = try XCTUnwrap(scroll.documentView as? ReviewCollectionDocument)
            XCTAssertEqual(document.geometry?.columns, columns)
            let restored = try XCTUnwrap(document.snapshotViewport())
            XCTAssertEqual(restored.physicalFileID, anchorFileID, "The receipt, not following, positions the viewport")
            XCTAssertEqual(restored.topOffset, 0, accuracy: 1)
            try assertCurrentVisible(store, in: scroll)

            store.sort.ascending = false
            try await settle(host)
            XCTAssertEqual(store.currentIndex, current)
            try assertCurrentVisible(store, in: scroll)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0)
        }
    }

    private func readyStore() -> SessionStore {
        let suite = "ReviewUI.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.register(defaults: [ReviewPreferences.Keys.advancesAfterDecision: false])
        let store = SessionStore(reviewDefaults: defaults)
        store.items = (0..<100).map { index in
            let name = String(format: "PHOTO_%03d.JPG", index)
            return PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/tmp/\(name)"), pairedURL: nil,
                             captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.sort = PhotoSort(key: .name, ascending: true)
        store.isGroupingEnabled = false
        store.rebuildDerivedDataForTesting()
        return store
    }

    private func assertCurrentVisible(_ store: SessionStore, in scroll: NSScrollView,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try XCTUnwrap(store.currentItem)
        let element = try XCTUnwrap(elements(scroll).first { string($0, "accessibilityLabel") == item.displayName },
                                   "Current tile must be mounted", file: file, line: line)
        let frame = scroll.window!.convertFromScreen(try XCTUnwrap(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1, file: file, line: line)
    }

    private func mount(_ host: NSView, size: CGSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        return window
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func elements(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(walk) }
            if let view = object as? NSView { view.subviews.forEach(walk) }
        }
        walk(root)
        return result
    }

}
