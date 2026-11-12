import Foundation
import XCTest
@testable import Louppe

final class ReviewDesignConventionsTests: XCTestCase {
    func testReadyAndOpeningTilesUseOneSelectionTreatment() throws {
        for file in ["ThumbnailView", "OpeningSessionContent"] {
            let source = try viewSource(file)
            XCTAssertTrue(source.contains(".reviewTileSelectionOutline(isCurrent: isCurrent, isSelected: isSelected)"), file)
            XCTAssertFalse(source.contains("strokeBorder"), "\(file) must not own another selection outline")
        }
        let opening = try viewSource("OpeningSessionContent")
        XCTAssertFalse(opening.contains("louppeAccent.opacity"), "Opening must not add a separate selection fill")
        let selection = try viewSource("Design/ReviewTileSelection")
        XCTAssertTrue(selection.contains("accessibilityDifferentiateWithoutColor"))
        XCTAssertTrue(selection.contains("colorSchemeContrast"))
    }

    func testRenderedKeyboardAndOpeningColumnsUseSharedMetrics() throws {
        for file in ["GridView", "OpeningSessionContent", "ReviewCollectionGeometry"] {
            XCTAssertTrue(try viewSource(file).contains("ReviewCollectionMetrics.gridColumnCount("), file)
        }
        XCTAssertTrue(try viewSource("BrowserView").contains("ReviewCollectionMetrics.browserWidth"))
    }

    func testGalleryAndGridShareEmptyStateRemedies() throws {
        for file in ["GalleryView", "GridView"] {
            let source = try viewSource(file)
            XCTAssertTrue(source.contains("ReviewEmptyState(store: store)"), file)
            XCTAssertTrue(source.contains("ReviewEmptyStateView("), file)
            XCTAssertFalse(source.contains("store.resetFilter()"), "\(file) must share the empty-state remedy")
        }
    }

    func testOrdinarySelectionAndOpeningReadoutsShareCombinedAccessibility() throws {
        let panel = try viewSource("MetadataPanel")
        XCTAssertEqual(panel.components(separatedBy: "LabeledReadout(").count - 1, 2)
        XCTAssertTrue(try viewSource("OpeningSessionContent").contains("LabeledReadout("))
        XCTAssertTrue(try viewSource("Design/LabeledReadout").contains(".accessibilityElement(children: .combine)"))
    }

    func testHeroLabelsIncludeLocalizedFieldNameAndValueAndKeepApprovedRows() throws {
        let panel = try viewSource("MetadataPanel")
        XCTAssertTrue(panel.contains(#".accessibilityLabel(Text("\(L10n.label(field.label)) \(field.value)"))"#))
        XCTAssertTrue(panel.contains(".accessibilityElement(children: .combine)"))
        XCTAssertTrue(panel.contains(#"shootingLabels = ["Aperture", "Shutter", "ISO"]"#))
        XCTAssertTrue(panel.contains(#"secondaryShootingLabels = ["Focal length", "Exposure comp.", "White balance"]"#))
    }

    func testBadgeBackdropsPreserveRolesAndRespectAccessibility() {
        let roles: [(MediaBadgeBackdropRole, Double)] = [(.glyph, 0.68), (.qualityCue, 0.72), (.text, 0.85)]
        for (role, originalOpacity) in roles {
            XCTAssertEqual(role.opacity(increasedContrast: false, reduceTransparency: false), originalOpacity)
            XCTAssertGreaterThanOrEqual(role.opacity(increasedContrast: true, reduceTransparency: false), originalOpacity)
            for increasedContrast in [false, true] {
                XCTAssertEqual(role.opacity(increasedContrast: increasedContrast, reduceTransparency: true), 1)
            }
        }
    }

    private func viewSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Louppe/Views/\(name).swift"), encoding: .utf8)
    }
}
