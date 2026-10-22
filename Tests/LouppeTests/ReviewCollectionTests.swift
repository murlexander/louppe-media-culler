import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ReviewCollectionTests: XCTestCase {
    func testBrowserEqualityIncludesGroupsWhenItemOrderDoesNotChange() {
        let store = SessionStore()
        let entries = [PreparedSessionIndex.VisibleEntry(id: "a", index: 0),
                       PreparedSessionIndex.VisibleEntry(id: "b", index: 1)]
        let first = [PreparedSessionIndex.VisibleGroup(id: .ungrouped, title: "Before", entries: entries[...])]
        let renamed = [PreparedSessionIndex.VisibleGroup(id: .ungrouped, title: "After", entries: entries[...])]
        let regrouped = [
            PreparedSessionIndex.VisibleGroup(id: .ungrouped, title: "One", entries: entries[0..<1]),
            PreparedSessionIndex.VisibleGroup(id: PhotoGroup.ID(key: .name, value: .text("second")),
                                              title: "Two", entries: entries[1..<2])
        ]
        func content(_ groups: [PreparedSessionIndex.VisibleGroup]) -> BrowserCollectionContent {
            BrowserCollectionContent(store: store, entries: entries,
                viewportSize: CGSize(width: BrowserView.width, height: 500), locale: Locale(identifier: "en"),
                onPlainClick: { _ in }, groups: groups)
        }
        XCTAssertNotEqual(content(first), content(renamed))
        XCTAssertNotEqual(content(first), content(regrouped))
    }

    func testDistantGeometryRealizesOnlyIntersectingRowsAcrossManyGroups() {
        let projection = projection(count: 10_000, groupSize: 10)
        let layout = ReviewCollectionGeometry(projection: projection, style: .grid(thumbnailSize: 170),
            width: 900, captionHeight: 13, headerHeight: 24, rightToLeft: false)
        let tail = layout.itemFrame(at: 9_999, projection: projection)!
        let elements = layout.elements(in: CGRect(x: 0, y: tail.minY - 200, width: 900, height: 500),
                                       projection: projection)
        XCTAssertTrue(elements.contains { $0.key == .item(9_999) })
        XCTAssertLessThan(elements.count, 30)
        XCTAssertFalse(elements.contains { $0.key == .item(0) })
        let nextGroup = layout.itemFrame(at: 10, projection: projection)!
        XCTAssertGreaterThan(nextGroup.minY, layout.itemFrame(at: 9, projection: projection)!.maxY)
        XCTAssertEqual(nextGroup.minX, layout.itemFrame(at: 0, projection: projection)!.minX)
    }

    func testGridMirrorsPhysicalColumnsAndControlExclusion() {
        let projection = projection(count: 100)
        let ltr = ReviewCollectionGeometry(projection: projection, style: .grid(thumbnailSize: 170),
            width: 900, captionHeight: 13, headerHeight: 24, rightToLeft: false)
        let rtl = ReviewCollectionGeometry(projection: projection, style: .grid(thumbnailSize: 170),
            width: 900, captionHeight: 13, headerHeight: 24, rightToLeft: true)
        XCTAssertEqual(ltr.columns, rtl.columns)
        XCTAssertGreaterThan(rtl.itemFrame(at: 0, projection: projection)!.minX,
                             rtl.itemFrame(at: 1, projection: projection)!.minX)
        let frame = CGRect(x: 10, y: 10, width: 170, height: 186)
        XCTAssertFalse(GridRubberBandHitTest.shouldTrackCanvasDrag(
            startingAt: CGPoint(x: 20, y: 20), tileFrames: [0: frame], playableVideoIndices: [], rightToLeft: true))
        XCTAssertTrue(GridRubberBandHitTest.shouldTrackCanvasDrag(
            startingAt: CGPoint(x: 170, y: 20), tileFrames: [0: frame], playableVideoIndices: [], rightToLeft: true))
    }

    func testMountedDistantFollowIsBoundedAndManualScrollDoesNotRefollow() async throws {
        let controller = ReviewCollectionController()
        var userScrolls = 0
        controller.onUserViewportChange = { _ in userScrolls += 1 }
        let host = NSHostingView(rootView: collection(projection(count: 10_000), controller: controller))
        let window = mount(host)
        defer { window.close() }
        try await settle(host)
        let document = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionDocument }.first)
        let scroll = try XCTUnwrap(document.enclosingScrollView)
        XCTAssertFalse(ReviewCollectionDocument.isCompatibleWithResponsiveScrolling,
                       "Hosted cell realization has main-thread coverage, not responsive-scrolling overdraw")
        let initialGeometry = document.geometryGeneration
        let initialProjection = document.projectionGeneration
        for index in [9_999, 0, 5_000, 17, 9_998] {
            controller.follow(id: "item-\(index)")
            try await settle(host)
            XCTAssertLessThan(document.realizedItemCount, 12)
            XCTAssertLessThan(document.retainedHostCount, 24)
            XCTAssertEqual(document.geometryGeneration, initialGeometry)
            XCTAssertEqual(document.projectionGeneration, initialProjection)
        }
        XCTAssertLessThan(document.createdHostCount, 24, "Distant follow reuses hosts rather than walking the folder")
        XCTAssertEqual(userScrolls, 0, "Programmatic following is not a user's viewport choice")
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 173))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.minY, 173, accuracy: 0.5)
        scroll.contentView.setBoundsOrigin(CGPoint(x: 100, y: 173))
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        try VerticalScrollRegression.assertWheelInputStaysVertical(scroll)
        XCTAssertGreaterThan(userScrolls, 0, "Native gesture scrolling records an intentional viewport")
    }

    func testOneShotPhysicalViewportRestoresThroughReorderAndThenAllowsNavigation() async throws {
        let controller = ReviewCollectionController()
        let original = projection(count: 1_000)
        let host = NSHostingView(rootView: collection(original, controller: controller))
        let window = mount(host)
        defer { window.close() }
        try await settle(host)
        var restorations = 0
        controller.onViewportRestored = { _ in restorations += 1 }
        controller.restoreViewport(.init(physicalFileID: "file-500", topOffset: -23))
        try await settle(host)
        XCTAssertEqual(restorations, 1)
        let before = try XCTUnwrap(controller.snapshotViewport())
        XCTAssertEqual(before.physicalFileID, "file-500")
        XCTAssertEqual(before.topOffset, -23, accuracy: 0.5)

        let entries = original.entries
        let reordered = ReviewCollectionProjection(sections: [ReviewCollectionSection(
            id: "reordered", title: "New header", entries: Array(entries[400...]) + Array(entries[..<400]))])
        host.rootView = collection(reordered, controller: controller)
        try await settle(host)
        let after = try XCTUnwrap(controller.snapshotViewport())
        XCTAssertEqual(after.physicalFileID, before.physicalFileID)
        XCTAssertEqual(after.topOffset, before.topOffset, accuracy: 0.5)
        XCTAssertEqual(restorations, 1, "Layout preservation must not replay the external one-shot receipt")
        controller.follow(id: "item-900")
        try await settle(host)
        XCTAssertNotEqual(controller.snapshotViewport()?.physicalFileID, before.physicalFileID)
        XCTAssertEqual(restorations, 1)
    }

    func testNativeDocumentRebindsAxisGuardAndCannotRestartAfterDismantle() async throws {
        let controller = ReviewCollectionController()
        let first = ReviewCollectionScrollView(frame: CGRect(x: 0, y: 0, width: BrowserView.width, height: 500))
        let document = ReviewCollectionDocument()
        first.documentView = document
        PersistentVerticalScroller.configure(first)
        document.configure(projection: projection(count: 100), style: .browser, controller: controller,
                           rubberBand: nil, environment: EnvironmentValues()) { entry in
            AnyView(Text(entry.id).frame(width: 102, height: 102))
        }
        let firstWindow = mount(first)
        defer { firstWindow.close() }
        try await settle(first)
        let oldClip = first.contentView
        first.documentView = nil
        oldClip.setBoundsOrigin(CGPoint(x: 17, y: 100))
        XCTAssertEqual(oldClip.bounds.minX, 17, accuracy: 0.01)

        let second = ReviewCollectionScrollView(frame: first.frame)
        PersistentVerticalScroller.configure(second)
        let secondWindow = mount(second)
        defer { secondWindow.close() }
        second.documentView = document
        document.updateViewport()
        try await settle(second)
        second.contentView.setBoundsOrigin(CGPoint(x: 17, y: 100))
        XCTAssertEqual(second.contentView.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(second.contentView.bounds.minY, 100, accuracy: 0.01)
        oldClip.setBoundsOrigin(CGPoint(x: 23, y: 100))
        XCTAssertEqual(oldClip.bounds.minX, 23, accuracy: 0.01)
        document.dismantle()
        document.updateViewport()
        controller.follow(id: "item-90")
        // Leave actual horizontal range after dismantle. With a fitting
        // document AppKit may constrain X independently of our removed guard.
        document.setFrameSize(CGSize(width: second.contentView.bounds.width + 100, height: document.frame.height))
        second.contentView.setBoundsOrigin(CGPoint(x: 17, y: 100))
        XCTAssertEqual(second.contentView.bounds.minX, 17, accuracy: 0.01)
        XCTAssertEqual(document.realizedItemCount, 0)
        XCTAssertEqual(document.retainedHostCount, 0)
    }

    private func projection(count: Int, groupSize: Int? = nil) -> ReviewCollectionProjection {
        let entries = (0..<count).map { ReviewCollectionEntry(id: "item-\($0)", index: $0,
                                                              physicalFileIDs: ["file-\($0)"]) }
        let size = groupSize ?? max(1, count)
        let sections = stride(from: 0, to: count, by: size).map { start in
            ReviewCollectionSection(id: "group-\(start)", title: groupSize == nil ? nil : "Group \(start)",
                                    entries: Array(entries[start..<min(count, start + size)]))
        }
        return ReviewCollectionProjection(sections: sections)
    }

    private func collection(_ projection: ReviewCollectionProjection,
                            controller: ReviewCollectionController) -> ReviewCollection {
        ReviewCollection(projection: projection, style: .browser, controller: controller) { entry in
            AnyView(Text(entry.id).frame(width: 102, height: 102))
        }
    }

    private func mount(_ host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: BrowserView.width, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
