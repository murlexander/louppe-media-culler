import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ReviewCollectionMetricsTests: XCTestCase {
    func testArrowKeyColumnsMatchRenderedGridAcrossWidthsAndGutters() {
        let entries = (0..<64).map { ReviewCollectionEntry(id: "\($0)", index: $0, physicalFileIDs: ["\($0)"]) }
        let projection = ReviewCollectionProjection(sections: [
            ReviewCollectionSection(id: "all", title: nil, entries: entries)
        ])
        let widths = Array(stride(from: CGFloat(20), through: 2_600, by: 7)) + [279.5, 420.25, 1_512]
        for gutter in [CGFloat(0), PersistentVerticalScroller.gutterWidth] {
            for thumbnailSize in [CGFloat(60), 90, 120, 170, 260, 400] {
                for paneWidth in widths {
                    let clipWidth = paneWidth - gutter
                    let arrowColumns = ReviewCollectionMetrics.gridColumnCount(
                        paneWidth: paneWidth, thumbnailSize: thumbnailSize, gutterWidth: gutter)
                    for rightToLeft in [false, true] {
                        let rendered = ReviewCollectionGeometry(
                            projection: projection, style: .grid(thumbnailSize: thumbnailSize),
                            width: clipWidth, captionHeight: 13, headerHeight: 24, rightToLeft: rightToLeft)
                        let context = "pane \(paneWidth), gutter \(gutter), tile \(thumbnailSize), RTL \(rightToLeft)"
                        XCTAssertEqual(arrowColumns, rendered.columns, context)

                        // The rendered first row really holds that many tiles,
                        // all inside the clip, and the next tile wraps.
                        let row = (0..<min(rendered.columns, entries.count)).compactMap {
                            rendered.itemFrame(at: $0, projection: projection)
                        }
                        XCTAssertEqual(Set(row.map(\.minY)).count, 1, context)
                        if clipWidth > ReviewCollectionMetrics.gridLeadingInset + ReviewCollectionMetrics.gridTrailingInset {
                            for frame in row {
                                XCTAssertGreaterThanOrEqual(frame.minX, 0, context)
                                XCTAssertLessThanOrEqual(frame.maxX, clipWidth + 0.5, context)
                            }
                        }
                        if rendered.columns < entries.count,
                           let next = rendered.itemFrame(at: rendered.columns, projection: projection) {
                            XCTAssertGreaterThan(next.minY, row[0].minY, context)
                        }
                    }
                }
            }
        }
    }

    func testBrowserGeometryUsesTheSharedColumn() {
        let projection = ReviewCollectionProjection(sections: [
            ReviewCollectionSection(id: "all", title: nil,
                                    entries: [ReviewCollectionEntry(id: "a", index: 0, physicalFileIDs: ["a"])])
        ])
        let geometry = ReviewCollectionGeometry(projection: projection, style: .browser,
            width: ReviewCollectionMetrics.browserColumnWidth, captionHeight: 13, headerHeight: 24, rightToLeft: false)
        let frame = geometry.itemFrame(at: 0, projection: projection)
        XCTAssertEqual(frame?.width, ReviewCollectionMetrics.browserTileSize)
        XCTAssertEqual(frame?.minX, ReviewCollectionMetrics.browserHorizontalInset)
        XCTAssertEqual(ReviewCollectionMetrics.browserColumnWidth, 122)
        XCTAssertEqual(BrowserView.width, 122 + PersistentVerticalScroller.gutterWidth)
    }

    func testEmptyStatePriorityMatchesGalleryAndGrid() {
        func resolve(items: Bool = true, visible: Bool = false, grouped: Bool = false,
                     folder: Bool = false, filter: Bool = false, scope: Int = 0) -> ReviewEmptyState? {
            ReviewEmptyState.resolve(hasItems: items, hasVisibleItems: visible, isGroupedReviewActive: grouped,
                                     isInArchiveFolder: folder, isFilterActive: filter, archiveScopeCount: scope)
        }
        XCTAssertEqual(resolve(items: false, grouped: true, folder: true, filter: true), .session)
        XCTAssertNil(resolve(visible: true, grouped: true, folder: true, filter: true))
        XCTAssertEqual(resolve(grouped: true, folder: true, filter: true), .groupedReview)
        XCTAssertEqual(resolve(folder: true), .emptyFolder)
        XCTAssertEqual(resolve(folder: true, filter: true, scope: 0), .emptyFolder)
        XCTAssertEqual(resolve(folder: true, filter: true, scope: 5), .filterEmpty)
        XCTAssertEqual(resolve(filter: true), .filterEmpty)
        XCTAssertNil(resolve())
    }
}
