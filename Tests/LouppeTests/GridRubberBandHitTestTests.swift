import AppKit
import XCTest
@testable import Louppe

final class GridRubberBandHitTestTests: XCTestCase {
    private let slot = CGRect(x: 10, y: 20, width: 180, height: 180)

    func testLandscapeControlsFollowPhotoInsteadOfUpperAndLowerLetterbox() {
        let size = CGSize(width: 3, height: 2)
        XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: size),
                       CGRect(x: 10, y: 50, width: 180, height: 120))
        for rtl in [false, true] {
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 20 : 180, y: 60), size: size, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: rtl ? 20 : 180, y: 30), size: size, rtl: rtl))
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 180 : 20, y: 140), size: size, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: rtl ? 180 : 20, y: 190), size: size, rtl: rtl))
        }
    }

    func testPortraitControlsFollowPhotoInsteadOfSideLetterbox() {
        let size = CGSize(width: 2, height: 3)
        XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: size),
                       CGRect(x: 40, y: 20, width: 120, height: 180))
        for rtl in [false, true] {
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 50 : 150, y: 30), size: size, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: rtl ? 20 : 180, y: 30), size: size, rtl: rtl))
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 150 : 50, y: 180), size: size, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: rtl ? 180 : 20, y: 180), size: size, rtl: rtl))
        }
    }

    func testMissingAndInvalidAspectKeepFullSlot() {
        for size in [nil, .zero, CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 1, height: -1)] as [CGSize?] {
            XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: size), slot)
        }
        for rtl in [false, true] {
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 20 : 180, y: 30), size: nil, rtl: rtl))
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 180 : 20, y: 180), size: nil, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: 100, y: 100), size: nil, rtl: rtl))
        }
    }

    func testSmallPhotoKeepsExpandedDecisionAndCueTargets() {
        let landscape = CGSize(width: 18, height: 1)
        let portrait = CGSize(width: 1, height: 18)
        // The visible landscape is only ten points high, but its controls keep
        // their 40/36-point targets above and below the photo's narrow band.
        XCTAssertFalse(tracks(CGPoint(x: 150, y: 140), size: landscape))
        XCTAssertFalse(tracks(CGPoint(x: 30, y: 80), size: landscape))
        // A narrow portrait keeps the decision target to its inside/left and
        // the entire four-cue row to its inside/right, with RTL mirrored.
        for rtl in [false, true] {
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 130 : 70, y: 30), size: portrait, rtl: rtl))
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 18 : 182, y: 180), size: portrait, rtl: rtl))
        }
        XCTAssertTrue(tracks(CGPoint(x: 100, y: 210), size: portrait), "caption remains selection canvas")
    }

    func testPlaybackCenterAndGapsRemainUnchangedWithAspect() {
        for size in [CGSize(width: 3, height: 2), CGSize(width: 2, height: 3)] {
            XCTAssertFalse(tracks(CGPoint(x: 100, y: 110), size: size, playable: true))
            XCTAssertTrue(tracks(CGPoint(x: 100, y: 110), size: size))
            XCTAssertTrue(tracks(CGPoint(x: 0, y: 0), size: size))
            XCTAssertTrue(tracks(CGPoint(x: 20, y: 140), size: size, playable: true))
        }
    }

    private func tracks(_ point: CGPoint, size: CGSize?, rtl: Bool = false, playable: Bool = false) -> Bool {
        GridRubberBandHitTest.shouldTrackCanvasDrag(
            startingAt: point, tileFrames: [0: CGRect(x: 10, y: 20, width: 180, height: 200)],
            playableVideoIndices: playable ? [0] : [], rightToLeft: rtl,
            imageSizes: size.map { [0: $0] } ?? [:])
    }
}
