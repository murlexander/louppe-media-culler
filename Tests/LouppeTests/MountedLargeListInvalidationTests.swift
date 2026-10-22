#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Count immutable projection builds and native projection generations, not
/// SwiftUI body evaluations: the framework may reevaluate identical inputs.
/// Live rows keep observing while navigation leaves the projection intact.
@MainActor
final class MountedLargeListInvalidationTests: XCTestCase {
    func testMountedGridDoesNotReconstructCollectionForCurrentOrSelection() async throws {
        let store = readyStore()
        store.viewMode = .grid
        var constructions = 0
        GridCollectionContent.didBuildProjection = { constructions += 1 }
        defer { GridCollectionContent.didBuildProjection = nil }
        let host = NSHostingView(rootView: GridView(store: store))
        let window = mount(host, width: 620)
        defer { window.close() }
        try await settle(host)
        let initial = constructions
        XCTAssertGreaterThan(initial, 0)
        let document = try XCTUnwrap(nativeDocument(in: host))
        let nativeProjection = document.projectionGeneration

        for index in [1, 2, 3] {
            store.setIndex(index)
            store.setSelection([index, index + 1])
            try await settle(host)
        }
        XCTAssertEqual(constructions, initial,
                       "Current/selection update observed cells, not the full grid")
        XCTAssertEqual(document.projectionGeneration, nativeProjection,
                       "Native Grid must retain the exact immutable projection on navigation")

        store.items[0] = item(2_000)
        store.rebuildDerivedDataForTesting()
        try await settle(host)
        XCTAssertGreaterThan(constructions, initial, "Replacement identities must reach sections")
        let replaced = constructions
        let beforeThumbnailGeometry = document.geometryGeneration
        store.gridThumbSize += 20
        try await settle(host)
        XCTAssertEqual(constructions, replaced, "Tile resizing reuses the immutable projection")
        XCTAssertGreaterThan(document.geometryGeneration, beforeThumbnailGeometry, "Tile resizing must rebuild columns")
        let beforeWidthGeometry = document.geometryGeneration
        let resized = constructions
        window.setContentSize(NSSize(width: 900, height: 500))
        try await settle(host)
        XCTAssertEqual(constructions, resized, "Viewport changes reflow geometry without rebuilding item maps")
        XCTAssertGreaterThan(document.geometryGeneration, beforeWidthGeometry, "Viewport width must reach native geometry")
        let relaidOut = constructions
        store.filter.excludedMediaKinds = [.photo]
        try await settle(host)
        store.resetFilter()
        try await settle(host)
        XCTAssertGreaterThan(constructions, relaidOut, "A changed projection must remount its collection")
    }

    func testMountedBrowserDoesNotReconstructCollectionForCurrentOrSelection() async throws {
        let store = readyStore()
        var constructions = 0
        var snapshots: [BrowserCollectionContent] = []
        BrowserCollectionContent.didBuildProjection = { constructions += 1 }
        BrowserCollectionContent.didConstructSnapshot = { snapshots.append($0) }
        defer {
            BrowserCollectionContent.didBuildProjection = nil
            BrowserCollectionContent.didConstructSnapshot = nil
        }
        let host = NSHostingView(rootView: BrowserView(store: store))
        let window = mount(host, width: BrowserView.width)
        defer { window.close() }
        try await settle(host)
        let initial = constructions
        XCTAssertGreaterThan(initial, 0)
        let document = try XCTUnwrap(nativeDocument(in: host))
        let nativeProjection = document.projectionGeneration

        for index in [1, 2, 3] {
            store.setIndex(index)
            store.setSelection([index, index + 1])
            try await settle(host)
        }
        let changes = snapshots.enumerated().map { index, value in
            "\(index): viewport=\(value.viewportSize), locale=\(value.locale.identifier), entriesSame=\(value.entries == snapshots[0].entries), groupsSame=\(value.groups == snapshots[0].groups)"
        }.joined(separator: "; ")
        XCTAssertEqual(constructions, initial,
                       "Current/selection update observed rows, not the full strip. \(changes)")
        XCTAssertEqual(document.projectionGeneration, nativeProjection,
                       "Native Browser must retain the exact immutable projection on navigation")

        // Same-size replacement exercises stable-ID invalidation, not just counts.
        store.items[0] = item(2_000)
        store.rebuildDerivedDataForTesting()
        try await settle(host)
        XCTAssertGreaterThan(constructions, initial, "Replacement identities must reach the native projection")
        let replaced = constructions
        window.setContentSize(NSSize(width: BrowserView.width, height: 600))
        try await settle(host)
        XCTAssertEqual(constructions, replaced, "Viewport height does not change presentation identity")
        XCTAssertEqual(document.enclosingScrollView?.contentView.bounds.height ?? 0, 600, accuracy: 0.5,
                       "Viewport height still reaches the native clip")
    }

    func testCollectionEqualityRetainsLocaleAndStoreIdentity() {
        let store = readyStore()
        let otherStore = readyStore()
        func grid(_ store: SessionStore, locale: String) -> GridCollectionContent {
            GridCollectionContent(store: store, groups: store.gridGroups,
                                  thumbnailSize: 170, viewportSize: CGSize(width: 620, height: 500),
                                  locale: Locale(identifier: locale), onPointerCurrentChange: {})
        }
        func browser(_ store: SessionStore, locale: String) -> BrowserCollectionContent {
            BrowserCollectionContent(store: store, entries: store.browserEntries,
                                     viewportSize: CGSize(width: BrowserView.width, height: 500),
                                     locale: Locale(identifier: locale), onPlainClick: { _ in })
        }
        XCTAssertNotEqual(grid(store, locale: "en"), grid(store, locale: "ar"))
        XCTAssertNotEqual(browser(store, locale: "en"), browser(store, locale: "ar"))
        XCTAssertNotEqual(grid(store, locale: "en"), grid(otherStore, locale: "en"))
        XCTAssertNotEqual(browser(store, locale: "en"), browser(otherStore, locale: "en"))
    }

    private func nativeDocument(in view: NSView) -> ReviewCollectionDocument? {
        if let document = view as? ReviewCollectionDocument { return document }
        return view.subviews.lazy.compactMap { self.nativeDocument(in: $0) }.first
    }

    private func readyStore() -> SessionStore {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = (0..<1_000).map(item)
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        return store
    }

    private func item(_ index: Int) -> PhotoItem {
        let name = String(format: "MOUNTED_%04d.JPG", index)
        return PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/tmp/\(name)"),
                         pairedURL: nil, captureDate: nil, cameraModel: nil,
                         lensModel: nil, fileSize: 1)
    }

    private func mount(_ host: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
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
}
#endif
