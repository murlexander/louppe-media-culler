import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Mounted production Grid, native badge events and the session's arrow route.
/// All windows remain offscreen and all stores use disposable settings/storage.
@MainActor
final class GridPointerFollowTests: XCTestCase {
    func testFilteredPointerRatingCannotConsumeNextKeyboardFollow() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try SelectionInteractionFixture()
                defer { fixture.remove() }
                let store = try fixture.readyStore(count: 100)
                store.sort = PhotoSort(key: .name, ascending: false)
                store.filter.excludedDecisionStates = [.yes]
                store.setIndex(99)
                store.showBrowser = false
                store.showMetadataPanel = true
                let host = NSHostingView(rootView: SessionView(store: store)
                    .environment(\.accessibilityEnabled, true)
                    .environment(\.layoutDirection, direction).preferredColorScheme(scheme))
                let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 1000, height: 560))
                defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
                try await SelectionInteractionFixture.settle(host)
                let scroll = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.documentView!.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await SelectionInteractionFixture.settle(host)
                let bottomY = scroll.contentView.bounds.minY
                XCTAssertGreaterThan(bottomY, 1000)
                try SelectionInteractionFixture.clickControl(L10n.text("Change decision for \(store.items[0].displayName)"), in: host, window: window)
                try await SelectionInteractionFixture.settle(host)
                XCTAssertEqual(store.items[0].rating, .yes, "The mounted badge must receive the native click")
                XCTAssertEqual(store.currentIndex, 99, "Filtering returns to the original first item")
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1000, "Pointer rating preserves manual browsing")
                try navigateRight(store)
                try await SelectionInteractionFixture.settle(host)
                XCTAssertEqual(store.currentIndex, 98)
                try fixture.capture(host, name: "grid-\(direction)-\(scheme)")
                try SelectionInteractionFixture.assertCurrentVisible(store, in: scroll)
                XCTAssertEqual(scroll.contentView.bounds.minX, 0)
                store.undo()
                try await SelectionInteractionFixture.settle(host)
                XCTAssertEqual(store.items[0].rating, .undecided)
                XCTAssertEqual(store.visibleIndices.count, 100, "Undo restores the filtered item")
                XCTAssertEqual(store.currentIndex, 0, "Undo restores the rated physical item as current")
                try SelectionInteractionFixture.assertCurrentVisible(store, in: scroll)
            }
        }
    }

    func testPointerSelectionRatingCoalescingAndUndoDoNotLeaveStaleFollow() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 100)
        let host = NSHostingView(rootView: GridView(store: store).environment(\.accessibilityEnabled, true))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 700, height: 560))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let scroll = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1500))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await SelectionInteractionFixture.settle(host)
        let y = scroll.contentView.bounds.minY
        let surfaces = SelectionInteractionFixture.descendants(scroll).compactMap { $0 as? GridImmediateClickSurface.ClickView }
            .filter { $0.bounds.height > 100 }
            .filter { scroll.contentView.convert(scroll.contentView.bounds, to: nil).contains($0.convert($0.bounds, to: nil)) }
        let surface = try XCTUnwrap(surfaces.first)
        let point = surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        try SelectionInteractionFixture.click(point, window: window)
        try await SelectionInteractionFixture.settle(host)
        let pointerCurrent = store.currentIndex
        XCTAssertGreaterThan(pointerCurrent, 0)
        XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 1)
        // Repeated pointer changes can coalesce back to the observed current.
        try SelectionInteractionFixture.clickControl(L10n.text("Change decision for \(store.items[pointerCurrent].displayName)"), in: host, window: window)
        let other = try XCTUnwrap(surfaces.dropFirst().first)
        try SelectionInteractionFixture.click(other.convert(CGPoint(x: other.bounds.midX, y: other.bounds.midY), to: nil), window: window)
        try SelectionInteractionFixture.click(point, window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, pointerCurrent)
        XCTAssertEqual(scroll.contentView.bounds.minY, y, accuracy: 1)
        XCTAssertEqual(store.items[pointerCurrent].rating, .yes)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await SelectionInteractionFixture.settle(host)
        try navigateRight(store)
        try await SelectionInteractionFixture.settle(host)
        try SelectionInteractionFixture.assertCurrentVisible(store, in: scroll)
        store.undo()
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.items[pointerCurrent].rating, .undecided)
        XCTAssertEqual(store.currentIndex, pointerCurrent)
        try SelectionInteractionFixture.assertCurrentVisible(store, in: scroll)
    }

    func testNativePlayPreservesPointerViewportAndNextKeyboardFollow() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 100)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AccessibilityMedia/captioned-described.mov")
        let url = fixture.root.appendingPathComponent("PHOTO_000.mov")
        try FileManager.default.copyItem(at: source, to: url)
        store.items[0] = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
            captureDate: nil, cameraModel: nil, lensModel: nil, mediaKind: .video,
            duration: 8, videoDimensions: CGSize(width: 640, height: 360), videoIsPlayable: true, fileSize: 1)
        store.rebuildDerivedDataForTesting()
        store.setIndex(99)
        store.videoPlayback.player.isMuted = true
        let host = NSHostingView(rootView: GridView(store: store).environment(\.accessibilityEnabled, true))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 700, height: 560))
        defer { store.videoPlayback.stop(); store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let scroll = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await SelectionInteractionFixture.settle(host)
        try SelectionInteractionFixture.clickControl(L10n.text("Play \(L10n.label(store.items[0].mediaKind.singularLabel))"), in: host, window: window)
        XCTAssertTrue(store.videoPlayback.isPlaying, "Native Play starts playback synchronously")
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertTrue(store.videoPlayback.isActive(store.items[0]))
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(scroll.contentView.bounds.minY, 40, accuracy: 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1500))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await SelectionInteractionFixture.settle(host)
        try navigateRight(store)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 1)
        try SelectionInteractionFixture.assertCurrentVisible(store, in: scroll)
    }

    func testReturningFromEmptyGridCannotSuppressKeyboardFollow() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 100)
        store.sort = PhotoSort(key: .name, ascending: false)
        store.filter.excludedDecisionStates = [.yes]
        store.setIndex(99)
        let host = NSHostingView(rootView: GridView(store: store).environment(\.accessibilityEnabled, true))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 700, height: 560))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let scroll = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.documentView!.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await SelectionInteractionFixture.settle(host)
        try SelectionInteractionFixture.clickControl(L10n.text("Change decision for \(store.items[0].displayName)"), in: host, window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 99)

        store.filter.excludedMediaKinds = [.photo]
        try await SelectionInteractionFixture.settle(host)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.setIndex(98)
        store.filter.excludedMediaKinds = []
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 98)
        let restoredScroll = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
        restoredScroll.contentView.scroll(to: CGPoint(x: 0, y: restoredScroll.documentView!.bounds.height - restoredScroll.contentView.bounds.height))
        restoredScroll.reflectScrolledClipView(restoredScroll.contentView)
        try await SelectionInteractionFixture.settle(host)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        XCTAssertTrue(SessionView(store: store).handleKey(event, context: .focusedSession))
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 99)
        try SelectionInteractionFixture.assertCurrentVisible(store, in: restoredScroll)
    }

    private func navigateRight(_ store: SessionStore) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        XCTAssertTrue(SessionView(store: store).handleKey(event, context: .focusedSession))
    }
}
