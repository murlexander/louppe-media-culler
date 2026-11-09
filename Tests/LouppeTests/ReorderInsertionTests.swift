import XCTest
@testable import Louppe

final class ReorderInsertionTests: XCTestCase {
    func testPointerHalfChoosesGapBeforeOrAfterRow() {
        XCTAssertEqual(ReorderInsertion.gap(hoveredRow: 0, pointerY: 0, rowHeight: 40), 0)
        XCTAssertEqual(ReorderInsertion.gap(hoveredRow: 2, pointerY: 19.9, rowHeight: 40), 2)
        XCTAssertEqual(ReorderInsertion.gap(hoveredRow: 2, pointerY: 20, rowHeight: 40), 3)
        XCTAssertEqual(ReorderInsertion.gap(hoveredRow: 5, pointerY: 40, rowHeight: 40), 6)
    }

    func testGapsAroundTheDraggedRowAreNoOps() {
        XCTAssertNil(ReorderInsertion.moveOffset(from: 2, toGap: 2, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: 2, toGap: 3, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: 0, toGap: 0, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: 5, toGap: 6, count: 6))
    }

    func testInvalidIndicesAreRejected() {
        XCTAssertNil(ReorderInsertion.moveOffset(from: 6, toGap: 0, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: -1, toGap: 0, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: 0, toGap: 7, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: 0, toGap: -1, count: 6))
        XCTAssertNil(ReorderInsertion.moveOffset(from: 0, toGap: 0, count: 0))
    }

    /// The dropped row lands exactly where the line was drawn: between the
    /// rows that bordered the gap, including both list ends.
    func testMoveLandsInTheIndicatedGap() {
        let rows = Array("ABCDEF")
        for source in rows.indices {
            for gap in 0...rows.count {
                guard let offset = ReorderInsertion.moveOffset(
                    from: source, toGap: gap, count: rows.count) else {
                    XCTAssertTrue(gap == source || gap == source + 1)
                    continue
                }
                var moved = rows
                moved.move(fromOffsets: IndexSet(integer: source), toOffset: offset)
                let landed = moved.firstIndex(of: rows[source])!
                let before = gap > 0 ? rows[gap - 1] : nil
                let after = gap < rows.count ? rows[gap] : nil
                XCTAssertEqual(landed > 0 ? moved[landed - 1] : nil, before,
                               "source \(source), gap \(gap)")
                XCTAssertEqual(landed + 1 < moved.count ? moved[landed + 1] : nil, after,
                               "source \(source), gap \(gap)")
            }
        }
    }

    func testDraggingCameraToTheTopOfRenameParts() {
        var configuration = FileRenamingConfiguration.initial
        let kinds = configuration.parts.map(\.kind)
        let source = kinds.firstIndex(of: .camera)!
        let offset = ReorderInsertion.moveOffset(from: source, toGap: 0, count: kinds.count)!
        configuration.parts.move(fromOffsets: IndexSet(integer: source), toOffset: offset)
        XCTAssertEqual(configuration.parts.map(\.kind),
                       [.camera, .captureDate, .captureTime, .lens, .originalName, .sequence])
        XCTAssertFalse(configuration.parts[0].isEnabled, "The part keeps its enabled state.")
    }
}
