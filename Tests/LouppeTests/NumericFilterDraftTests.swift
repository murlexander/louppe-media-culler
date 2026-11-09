import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class NumericFilterDraftTests: XCTestCase {
    func testNoEditsNeverParsesOrCommitsRoundedDisplayValues() {
        let result = NumericFilterRangeDraft.resolve(
            available: 5...30, currentFrom: 10.2, currentTo: 20.8, isEnabled: true,
            fromText: "0:10", toText: "0:21", editedFrom: false, editedTo: false,
            parse: { _ in XCTFail("untouched display must never be parsed"); return nil },
            snap: { value, _ in value })
        XCTAssertNil(result)
    }

    func testOneEditedEndpointPreservesUntouchedPreciseValueAndDisabledRangeUsesAvailableBounds() throws {
        let lower = try XCTUnwrap(NumericFilterRangeDraft.resolve(
            available: 5...30, currentFrom: 10.2, currentTo: 20.8, isEnabled: true,
            fromText: "12", toText: "21", editedFrom: true, editedTo: false,
            parse: Double.init, snap: { value, _ in value }))
        XCTAssertEqual(lower.from, 12)
        XCTAssertEqual(lower.to, 20.8)
        let upper = try XCTUnwrap(NumericFilterRangeDraft.resolve(
            available: 5...30, currentFrom: 10.2, currentTo: 20.8, isEnabled: true,
            fromText: "10", toText: "19", editedFrom: false, editedTo: true,
            parse: Double.init, snap: { value, _ in value }))
        XCTAssertEqual(upper.from, 10.2)
        XCTAssertEqual(upper.to, 19)
        let disabled = try XCTUnwrap(NumericFilterRangeDraft.resolve(
            available: 5...30, currentFrom: 0, currentTo: 0, isEnabled: false,
            fromText: "12", toText: "garbage", editedFrom: true, editedTo: false,
            parse: Double.init, snap: { value, _ in value }))
        XCTAssertEqual(disabled.from, 12)
        XCTAssertEqual(disabled.to, 30)
    }

    func testPrecisionIsUsedWhenValidatingEditedEndpointAndFullRangeSnapSurvives() {
        let inverted = NumericFilterRangeDraft.resolve(
            available: 5...30, currentFrom: 10.2, currentTo: 20.8, isEnabled: true,
            fromText: "20.9", toText: "21", editedFrom: true, editedTo: false,
            parse: Double.init, snap: { value, _ in value })
        XCTAssertNil(inverted, "rounded display 21 must not permit a lower bound above exact 20.8")
        let complete = NumericFilterRangeDraft.resolve(
            available: 5.4...30.4, currentFrom: 10.2, currentTo: 20.8, isEnabled: true,
            fromText: "5", toText: "30", editedFrom: true, editedTo: true,
            parse: Double.init, snap: { value, bound in value == bound.rounded() ? bound : value })
        XCTAssertEqual(complete?.from, 5.4)
        XCTAssertEqual(complete?.to, 30.4)
    }

    func testOpeningWaitingAndClosingRealFilterPreservesAllPreciseCutoffs() async throws {
        try requireForegroundUI()
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = [makeItem("min", duration: 5, aperture: 1.4, shutter: 0.000123, iso: 100, fps: 24),
                       makeItem("max", duration: 30, aperture: 16, shutter: 2, iso: 10_000, fps: 120)]
        store.rebuildDerivedDataForTesting()
        var filter = store.filter
        filter.durationEnabled = true; filter.durationFrom = 10.2; filter.durationTo = 20.8
        filter.apertureEnabled = true; filter.apertureFrom = 2.1234; filter.apertureTo = 8.789
        filter.shutterEnabled = true; filter.shutterFrom = 0.003123; filter.shutterTo = 0.008765
        filter.isoEnabled = true; filter.isoFrom = 123; filter.isoTo = 321
        filter.videoFrameRateEnabled = true; filter.videoFrameRateFrom = 29.970029; filter.videoFrameRateTo = 59.940059
        store.filter = filter
        let expected = store.filter
        let host = NSHostingView(rootView: AnyView(FilterView(store: store)))
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertEqual(store.filter, expected, "draft initialization must not schedule destructive rounding")
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.filter, expected, "closing without typing must leave exact cutoffs untouched")
    }

    private func makeItem(_ id: String, duration: Double, aperture: Double,
                          shutter: Double, iso: Double, fps: Double) -> PhotoItem {
        PhotoItem(id: id, primaryURL: URL(fileURLWithPath: "/private/tmp/\(UUID())/\(id).mov"),
            pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil,
            aperture: aperture, shutterSpeed: shutter, iso: iso, mediaKind: .video,
            duration: duration, videoFrameRate: fps, videoIsPlayable: true, fileSize: 1)
    }
}
