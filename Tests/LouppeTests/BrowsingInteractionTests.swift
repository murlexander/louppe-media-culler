import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// These mounted checks use native geometry and hosted cells without raising a
/// window or taking keyboard focus. Parent serializes them with other UI checks.
@MainActor
final class BrowsingInteractionTests: XCTestCase {
    func testRepeatedNativeLayoutDoesNotRepeatRealizationOrTextMeasurement() async throws {
        let fixture = mount(projection: projection(count: 10_000), style: .browser)
        defer { fixture.window.close() }
        try await settle(fixture)
        let document = fixture.document
        let baseline = (document.geometryGeneration, document.viewportRealizationCount,
                        document.templateMeasurementCount, document.contentBindCount)
        XCTAssertGreaterThan(document.realizedItemCount, 0)
        for _ in 0..<100 {
            fixture.scroll.layout()
            document.updateViewport()
        }
        XCTAssertEqual(document.geometryGeneration, baseline.0)
        XCTAssertEqual(document.viewportRealizationCount, baseline.1)
        XCTAssertEqual(document.templateMeasurementCount, baseline.2)
        XCTAssertEqual(document.contentBindCount, baseline.3)
        XCTAssertLessThan(document.retainedHostCount, 24)
    }

    func testSubrowTravelRetainsHostsAndVerticalAxisWithoutRebindingCells() async throws {
        let fixture = mount(projection: projection(count: 10_000), style: .browser)
        defer { fixture.window.close() }
        try await settle(fixture)
        fixture.scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 30))
        fixture.document.updateViewport()
        let realizations = fixture.document.viewportRealizationCount
        let binds = fixture.document.contentBindCount
        let creations = fixture.document.createdHostCount
        fixture.scroll.contentView.setBoundsOrigin(CGPoint(x: 47, y: 31))
        fixture.document.updateViewport()
        XCTAssertEqual(fixture.scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 31, accuracy: 0.01)
        XCTAssertEqual(fixture.document.viewportRealizationCount, realizations,
                       "travel within the same realized row range needs no host bookkeeping")
        XCTAssertEqual(fixture.document.contentBindCount, binds)
        XCTAssertEqual(fixture.document.createdHostCount, creations)
    }

    func testProjectionChangeReusesFontMeasurementsAndPreservesPhysicalViewport() async throws {
        let original = projection(count: 1_000)
        let fixture = mount(projection: original, style: .browser)
        defer { fixture.window.close() }
        try await settle(fixture)
        fixture.controller.restoreViewport(.init(physicalFileID: "file-500", topOffset: -23))
        let before = try XCTUnwrap(fixture.controller.snapshotViewport())
        let measured = fixture.document.templateMeasurementCount
        let geometry = fixture.document.geometryGeneration
        let reversed = ReviewCollectionProjection(sections: [ReviewCollectionSection(
            id: "reversed", title: nil, entries: Array(original.entries.reversed()))])
        fixture.document.configure(projection: reversed, style: .browser, controller: fixture.controller,
                                   rubberBand: nil, environment: EnvironmentValues(), cell: cell)
        let after = try XCTUnwrap(fixture.controller.snapshotViewport())
        XCTAssertEqual(after.physicalFileID, before.physicalFileID)
        XCTAssertEqual(after.topOffset, before.topOffset, accuracy: 0.5)
        XCTAssertGreaterThan(fixture.document.geometryGeneration, geometry)
        XCTAssertEqual(fixture.document.templateMeasurementCount, measured,
                       "changing inventory must reuse same-width, same-environment font templates")
        fixture.document.dismantle()
        fixture.document.updateViewport()
        XCTAssertEqual(fixture.document.retainedHostCount, 0)
        XCTAssertEqual(fixture.document.realizedItemCount, 0)
    }

    func testEnvironmentAndWidthChangesInvalidateTemplateMeasurements() async throws {
        let original = projection(count: 1_000)
        let fixture = mount(projection: original, style: .grid(thumbnailSize: 170))
        defer { fixture.window.close() }
        try await settle(fixture)
        let measured = fixture.document.templateMeasurementCount
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = .accessibility2
        environment.layoutDirection = .rightToLeft
        fixture.document.configure(projection: original, style: .grid(thumbnailSize: 170),
                                   controller: fixture.controller, rubberBand: nil,
                                   environment: environment, cell: cell)
        XCTAssertGreaterThan(fixture.document.templateMeasurementCount, measured)
        let afterEnvironment = fixture.document.templateMeasurementCount
        fixture.window.setContentSize(CGSize(width: 750, height: 500))
        try await settle(fixture)
        XCTAssertGreaterThan(fixture.document.templateMeasurementCount, afterEnvironment)
        XCTAssertEqual(fixture.scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        XCTAssertLessThan(fixture.document.retainedHostCount, 100)
    }

    private struct Fixture {
        let window: NSWindow
        let scroll: ReviewCollectionScrollView
        let document: ReviewCollectionDocument
        let controller: ReviewCollectionController
    }

    private func mount(projection: ReviewCollectionProjection, style: ReviewCollectionStyle) -> Fixture {
        _ = NSApplication.shared
        let width: CGFloat = style == .browser ? BrowserView.width : 900
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = ReviewCollectionScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
        scroll.autoresizingMask = [.width, .height]
        let document = ReviewCollectionDocument()
        let controller = ReviewCollectionController()
        scroll.documentView = document
        PersistentVerticalScroller.configure(scroll)
        window.contentView = scroll
        document.configure(projection: projection, style: style, controller: controller,
                           rubberBand: nil, environment: EnvironmentValues(), cell: cell)
        return Fixture(window: window, scroll: scroll, document: document, controller: controller)
    }

    private func projection(count: Int) -> ReviewCollectionProjection {
        ReviewCollectionProjection(sections: [ReviewCollectionSection(id: "all", title: nil,
            entries: (0..<count).map { ReviewCollectionEntry(id: "item-\($0)", index: $0,
                                                          physicalFileIDs: ["file-\($0)"]) })])
    }

    private func cell(_ entry: ReviewCollectionEntry) -> AnyView {
        AnyView(Text(entry.id).frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    private func settle(_ fixture: Fixture) async throws {
        fixture.scroll.layoutSubtreeIfNeeded()
        fixture.document.updateViewport()
        try await Task.sleep(for: .milliseconds(30))
        fixture.scroll.layoutSubtreeIfNeeded()
        fixture.document.updateViewport()
    }
}
