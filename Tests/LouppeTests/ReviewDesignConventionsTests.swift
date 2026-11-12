import Foundation
import XCTest
@testable import Louppe

final class ReviewDesignConventionsTests: XCTestCase {
    func testTilesRejectSeparateSelectionTreatments() throws {
        for file in ["ThumbnailView", "OpeningSessionContent"] {
            let source = try viewSource(file)
            XCTAssertFalse(source.contains("strokeBorder"), "\(file) must not own another selection outline")
        }
        let opening = try viewSource("OpeningSessionContent")
        XCTAssertFalse(opening.contains("louppeAccent.opacity"), "Opening must not add a separate selection fill")
    }

    func testGalleryAndGridRejectSeparateEmptyStateRemedies() throws {
        for file in ["GalleryView", "GridView"] {
            let source = try viewSource(file)
            XCTAssertFalse(source.contains("store.resetFilter()"), "\(file) must share the empty-state remedy")
        }
    }

    func testBadgeBackdropsPreserveRolesAndRespectAccessibility() {
        let roles: [(MediaBadgeBackdropRole, Double)] = [(.glyph, 0.70), (.text, 0.85)]
        for (role, opacity) in roles {
            XCTAssertEqual(role.opacity(increasedContrast: false, reduceTransparency: false), opacity)
            XCTAssertEqual(role.opacity(increasedContrast: true, reduceTransparency: false), 0.85)
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
