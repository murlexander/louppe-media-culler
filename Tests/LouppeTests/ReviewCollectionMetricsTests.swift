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
        XCTAssertEqual(frame?.width, ReviewCollectionMetrics.browserTileWidth)
        XCTAssertEqual(frame?.minX, ReviewCollectionMetrics.browserHorizontalInset)
        XCTAssertEqual(frame?.height, ReviewCollectionMetrics.browserTileHeight)
        XCTAssertEqual(ReviewCollectionMetrics.browserColumnWidth, 122)
        XCTAssertEqual(BrowserView.width, 122 + PersistentVerticalScroller.gutterWidth)
    }

    /// A ~950-point Browser shows about eleven frames instead of eight, and
    /// 3:2 landscapes keep their full 102-point width.
    func testBrowserSlotsShowAboutElevenFramesAndKeepLandscapeWidth() {
        let entries = (0..<40).map { ReviewCollectionEntry(id: "\($0)", index: $0, physicalFileIDs: ["\($0)"]) }
        let projection = ReviewCollectionProjection(sections: [ReviewCollectionSection(id: "all", title: nil, entries: entries)])
        let geometry = ReviewCollectionGeometry(projection: projection, style: .browser,
            width: ReviewCollectionMetrics.browserColumnWidth, captionHeight: 13, headerHeight: 24, rightToLeft: false)
        let whole = geometry.elements(in: CGRect(x: 0, y: 0, width: 122, height: 950), projection: projection)
            .filter { $0.frame.maxY <= 950 }
        XCTAssertEqual(whole.count, 11)
        let slot = CGRect(x: 0, y: 0, width: ReviewCollectionMetrics.browserTileWidth,
                          height: ReviewCollectionMetrics.browserTileHeight)
        XCTAssertEqual(TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 900, height: 600)).width, 102)
    }

    /// Stars about 31 points wide (upright 20 × 33 when narrower), a swatch
    /// or a 48-point color name that falls back to its swatch.
    private func sizing(stars: Bool, label: CGFloat?) -> [TileBadgeLayout.BrowserBadgeSizing] {
        var result: [TileBadgeLayout.BrowserBadgeSizing] = []
        if stars {
            result.append(.init(ideal: CGSize(width: 31, height: 20)) {
                $0 >= 31 ? CGSize(width: 31, height: 20) : CGSize(width: 20, height: 33)
            })
        }
        if let label {
            result.append(.init(ideal: CGSize(width: label, height: 20)) {
                $0 >= label ? CGSize(width: label, height: 20) : CGSize(width: 20, height: 20)
            })
        }
        return result
    }

    /// `count` cue icons wrapped to the offered width, inside the 36-point target.
    private func cueButton(_ count: Int) -> (CGFloat) -> CGSize {
        { width in
            let columns = max(1, min(count, Int((width + 3) / 23)))
            let rows = (count + columns - 1) / columns
            return CGSize(width: max(36, CGFloat(columns) * 23 - 3), height: max(36, CGFloat(rows) * 23 - 3))
        }
    }

    func testBrowserBadgesNeverOverlapAcrossShapesAndBottomRows() {
        let slot = CGRect(x: 0, y: 0, width: ReviewCollectionMetrics.browserTileWidth,
                          height: ReviewCollectionMetrics.browserTileHeight)
        let overhang = ReviewCollectionMetrics.browserHorizontalInset - 4
        let column = slot.insetBy(dx: -overhang, dy: 0)
        let shapes = [CGSize(width: 3, height: 2), CGSize(width: 16, height: 9), CGSize(width: 2.39, height: 1),
                      CGSize(width: 4, height: 1), CGSize(width: 1, height: 1), CGSize(width: 4, height: 5),
                      CGSize(width: 3, height: 4), CGSize(width: 2, height: 3), CGSize(width: 9, height: 16),
                      CGSize(width: 1, height: 3), CGSize(width: 1, height: 4), CGSize(width: 1, height: 5)]
        // Videos and audio: an 8-second or hour-long duration. Photos (the only
        // media with cues): cues off, on with none measured yet, or 1–4 cues.
        var bottoms: [(String, CGFloat?, Int?, Bool)] = [
            ("0:08", 34, nil, false), ("1:00:00", 50, nil, false), ("cues off", nil, nil, false),
            ("cue row reserved", nil, nil, true),
        ]
        for count in 1...4 { bottoms.append(("\(count) cues", nil, count, true)) }
        for shape in shapes {
            let media = TileMediaGeometry.fittedRect(in: slot, imageSize: shape)
            for (bottom, duration, cues, reserves) in bottoms {
                for stars in [false, true] {
                    for label: CGFloat? in [nil, 20, 48] {
                        let plan = TileBadgeLayout.browserBadges(
                            slot: slot, media: media, showsDecision: true,
                            metadata: sizing(stars: stars, label: label), durationWidth: duration,
                            cues: cues.map(cueButton), reservesBottomRow: reserves, overhang: overhang)
                        let context = "\(shape) \(bottom) stars \(stars) label \(String(describing: label))"
                        let badges = plan.metadata + [plan.decision, plan.duration].compactMap { $0 }
                        let rects = badges + [plan.cues].compactMap { $0 }
                        XCTAssertEqual(plan.metadata.count, (stars ? 1 : 0) + (label == nil ? 0 : 1), context)
                        XCTAssertEqual(plan.cues != nil, cues != nil, context)
                        if let cueRect = plan.cues {
                            XCTAssertTrue(slot.insetBy(dx: -0.5, dy: -0.5).contains(cueRect), "cues \(cueRect) outside slot: \(context)")
                            // Icons stop at the selection outline unless two don't fit before it.
                            let twoIcons = 2 * TileBadgeLayout.height + TileBadgeLayout.spacing
                            XCTAssertLessThanOrEqual(cueRect.maxX,
                                max(media.maxX - ReviewTileMetrics.selectionLineWidth, media.minX + TileBadgeLayout.inset + twoIcons) + 0.5,
                                "cues cross the outline: \(context)")
                        }
                        for (index, rect) in rects.enumerated() {
                            XCTAssertTrue(column.insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(rect) outside column: \(context)")
                            for other in rects[(index + 1)...] {
                                XCTAssertFalse(rect.insetBy(dx: 0.25, dy: 0.25).intersects(other), "\(rect) × \(other): \(context)")
                            }
                        }
                        if shape.width < shape.height {
                            let covered = badges.reduce(CGFloat(0)) {
                                let part = $1.intersection(media)
                                return $0 + (part.isNull ? 0 : part.width * part.height)
                            }
                            XCTAssertLessThan(covered, media.width * media.height / 2, "media mostly visible: \(context)")
                        }
                    }
                }
            }
        }
    }

    /// The three round-2 review cases, each named.
    func testBrowserBadgesClearLongDurationsCueTargetsAndTheColumn() throws {
        let slot = CGRect(x: 0, y: 0, width: 102, height: 80)
        // 9:16 video, hour-long duration: the side column moves to the trailing side.
        let video = TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 9, height: 16))
        let hour = TileBadgeLayout.browserBadges(slot: slot, media: video, showsDecision: true,
            metadata: sizing(stars: true, label: 20), durationWidth: 50, reservesBottomRow: false, overhang: 6)
        let duration = try XCTUnwrap(hour.duration)
        XCTAssertTrue(hour.metadata.allSatisfy { !$0.intersects(duration) && $0.minX >= video.maxX }, "\(hour)")
        // 4:5 photo with one cue: badges clear the whole 36-point target.
        let fourFive = TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 4, height: 5))
        let cue = TileBadgeLayout.browserBadges(slot: slot, media: fourFive, showsDecision: true,
            metadata: sizing(stars: true, label: 20), durationWidth: nil, cues: cueButton(1),
            reservesBottomRow: true, overhang: 6)
        let target = try XCTUnwrap(cue.cues)
        XCTAssertEqual(target.height, TileBadgeLayout.cueTargetHeight)
        XCTAssertTrue(cue.metadata.allSatisfy { !$0.intersects(target) }, "\(cue)")
        // A square photo wraps its label onto the media: it steps past the target.
        let square = TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 1, height: 1))
        let wrapped = TileBadgeLayout.browserBadges(slot: slot, media: square, showsDecision: true,
            metadata: sizing(stars: true, label: 20), durationWidth: nil, cues: cueButton(1),
            reservesBottomRow: true, overhang: 6)
        let squareTarget = try XCTUnwrap(wrapped.cues)
        XCTAssertTrue(wrapped.metadata.allSatisfy { !$0.intersects(squareTarget) && square.contains($0) }, "\(wrapped)")
        // 2:3 photo with four cues: the icons wrap inside the slot.
        let twoThree = TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 2, height: 3))
        let four = TileBadgeLayout.browserBadges(slot: slot, media: twoThree, showsDecision: true,
            metadata: sizing(stars: true, label: 20), durationWidth: nil, cues: cueButton(4),
            reservesBottomRow: true, overhang: 6)
        let cues = try XCTUnwrap(four.cues)
        XCTAssertLessThanOrEqual(cues.maxX, slot.maxX)
        XCTAssertGreaterThan(cues.height, TileBadgeLayout.height + TileBadgeLayout.spacing, "four icons wrap to two rows")
    }

    func testBrowserBadgeRowsForLandscapeAndNarrowPortraits() {
        let slot = CGRect(x: 0, y: 0, width: 102, height: 80)
        // 3:2 landscape: unchanged single row, stars then label, beside the decision.
        let landscape = TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 3, height: 2))
        let row = TileBadgeLayout.browserBadges(slot: slot, media: landscape, showsDecision: true,
            metadata: sizing(stars: true, label: 20), durationWidth: nil, reservesBottomRow: false)
        XCTAssertEqual(row.metadata, [CGRect(x: 6, y: 12, width: 31, height: 20), CGRect(x: 40, y: 12, width: 20, height: 20)])
        XCTAssertEqual(row.decision, CGRect(x: 76, y: 12, width: 20, height: 20))
        // 9:16 video: stars upright and label in the spare width beside it,
        // so the duration and the media stay clear.
        let video = TileMediaGeometry.fittedRect(in: slot, imageSize: CGSize(width: 9, height: 16))
        let beside = TileBadgeLayout.browserBadges(slot: slot, media: video, showsDecision: true,
            metadata: sizing(stars: true, label: 48), durationWidth: 34, reservesBottomRow: false)
        XCTAssertEqual(beside.metadata.map(\.size), [CGSize(width: 20, height: 33), CGSize(width: 20, height: 20)])
        XCTAssertTrue(beside.metadata.allSatisfy { $0.maxX <= video.minX }, "\(beside.metadata)")
        XCTAssertEqual(beside.duration?.maxY, video.maxY - 6)
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
