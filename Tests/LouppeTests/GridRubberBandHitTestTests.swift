import AppKit
import XCTest
@testable import Louppe

final class GridRubberBandHitTestTests: XCTestCase {
    private let slot = CGRect(x: 10, y: 20, width: 180, height: 180)

    func testLandscapeControlsFollowBottomAlignedPhoto() {
        let size = CGSize(width: 3, height: 2)
        XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: size),
                       CGRect(x: 10, y: 50, width: 180, height: 120))
        // Grid rests the photo on its caption: y 80...200 inside the 20...200 slot.
        for rtl in [false, true] {
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 20 : 180, y: 90), size: size, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: rtl ? 20 : 180, y: 30), size: size, rtl: rtl))
            XCTAssertFalse(tracks(CGPoint(x: rtl ? 180 : 20, y: 190), size: size, rtl: rtl))
            XCTAssertTrue(tracks(CGPoint(x: rtl ? 180 : 20, y: 60), size: size, rtl: rtl))
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

    func testBottomAlignmentRestsPhotoOnCaption() {
        XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 3, height: 2), alignment: .bottom),
                       CGRect(x: 10, y: 80, width: 180, height: 120))
        XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 2, height: 3), alignment: .bottom),
                       CGRect(x: 40, y: 20, width: 120, height: 180))
    }

    func testDecisionTargetStaysAbovePhotoBottom() {
        // A normal photo: target and badge at its top trailing corner.
        let photo = CGRect(x: 0, y: 0, width: 180, height: 120)
        XCTAssertEqual(TileBadgeLayout.decisionTarget(inPhoto: photo), CGRect(x: 134, y: 6, width: 40, height: 40))
        XCTAssertEqual(TileBadgeLayout.decisionBadge(inPhoto: photo), CGRect(x: 154, y: 6, width: 20, height: 20))
        // A 6:1 panorama 30 points high: the target grows upward and never
        // passes the photo's bottom edge, where the filename caption starts.
        let panorama = CGRect(x: 0, y: 150, width: 180, height: 30)
        let target = TileBadgeLayout.decisionTarget(inPhoto: panorama)
        XCTAssertEqual(target.maxY, panorama.maxY)
        XCTAssertEqual(target.height, TileBadgeLayout.decisionTargetSize)
        XCTAssertTrue(target.contains(CGPoint(x: 160, y: 170)))
        let badge = TileBadgeLayout.decisionBadge(inPhoto: panorama)
        XCTAssertEqual(badge.minY, panorama.minY + TileBadgeLayout.inset)
        XCTAssertTrue(target.contains(badge))
        // Too short for the badge: it rises above the photo, not over the caption.
        let sliver = CGRect(x: 0, y: 190, width: 180, height: 10)
        XCTAssertLessThanOrEqual(TileBadgeLayout.decisionBadge(inPhoto: sliver).maxY, sliver.maxY)
        XCTAssertTrue(TileBadgeLayout.decisionTarget(inPhoto: sliver).contains(TileBadgeLayout.decisionBadge(inPhoto: sliver)))
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
        // The visible landscape is only ten points high (y 190...200), but its
        // controls keep 40/36-point targets, grown upward inside the slot.
        XCTAssertFalse(tracks(CGPoint(x: 150, y: 170), size: landscape), "decision target grows above the photo")
        XCTAssertTrue(tracks(CGPoint(x: 150, y: 210), size: landscape), "the caption keeps its own clicks")
        XCTAssertFalse(tracks(CGPoint(x: 30, y: 170), size: landscape))
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
            let center = TileMediaGeometry.fittedRect(in: slot, imageSize: size, alignment: .bottom)
            XCTAssertFalse(tracks(CGPoint(x: center.midX, y: center.midY), size: size, playable: true))
            XCTAssertTrue(tracks(CGPoint(x: center.midX, y: center.midY), size: size))
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
