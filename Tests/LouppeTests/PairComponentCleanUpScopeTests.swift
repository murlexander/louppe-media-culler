import Foundation
import XCTest
@testable import Louppe

@MainActor
final class PairComponentCleanUpScopeTests: XCTestCase {
    func testSeparateReviewScopesOnlyThePhysicalMemberBeingRemoved() throws {
        for mode in [CleanUpMode.pairedJPEGs, .pairedRAWs] {
            let fixture = try makePair(together: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let store = fixture.store
            let target = mode == .pairedJPEGs ? 1 : 0
            let counterpart = 1 - target
            let expectedBytes: Int64 = mode == .pairedJPEGs ? 4 : 3

            store.cleanUpScope = .selected
            store.setSelection([counterpart])
            assertTargets(store, mode: mode, count: 0, bytes: 0)
            store.setSelection([target])
            assertTargets(store, mode: mode, count: 1, bytes: expectedBytes)

            store.cleanUpScope = .filtered
            store.filter.excludedTypes = [store.items[target].fileTypeLabel]
            XCTAssertEqual(store.visibleIndices, [counterpart])
            assertTargets(store, mode: mode, count: 0, bytes: 0)
            store.filter.excludedTypes = [store.items[counterpart].fileTypeLabel]
            XCTAssertEqual(store.visibleIndices, [target])
            assertTargets(store, mode: mode, count: 1, bytes: expectedBytes)

            store.cleanUpScope = .all
            assertTargets(store, mode: mode, count: 1, bytes: expectedBytes)
            XCTAssertEqual(store.items.map(\.rating), [.yes, .no])
            XCTAssertEqual(store.items.map(\.starRatingState), [.stars(.five), .stars(.one)])
            XCTAssertEqual(store.items.map(\.colorLabelState), [.label(.purple), .label(.red)])
            XCTAssertEqual(try Data(contentsOf: fixture.raw), Data("raw".utf8))
            XCTAssertEqual(try Data(contentsOf: fixture.jpeg), Data("jpeg".utf8))
        }
    }

    func testTogetherReviewUsesTheDisplayedPairsScopeForBothComponents() throws {
        for mode in [CleanUpMode.pairedJPEGs, .pairedRAWs] {
            let fixture = try makePair(together: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let store = fixture.store
            let expectedBytes: Int64 = mode == .pairedJPEGs ? 4 : 3

            store.cleanUpScope = .selected
            store.setSelection([0])
            assertTargets(store, mode: mode, count: 1, bytes: expectedBytes)
            store.cleanUpScope = .filtered
            assertTargets(store, mode: mode, count: 1, bytes: expectedBytes)
            store.filter.excludedTypes = ["RAW + JPEG"]
            XCTAssertTrue(store.visibleIndices.isEmpty)
            assertTargets(store, mode: mode, count: 0, bytes: 0)
            store.cleanUpScope = .selected
            assertTargets(store, mode: mode, count: 0, bytes: 0)
            store.cleanUpScope = .all
            assertTargets(store, mode: mode, count: 1, bytes: expectedBytes)
            XCTAssertTrue(store.items[0].hasMixedRatings)
            XCTAssertEqual(store.items[0].individualFiles.map(\.rating), [.yes, .no])
        }
    }

    /// Trash Paired JPEGs/RAWs name JPEG, so a RAW paired with HEIF or
    /// JPEG XL is never their target.
    func testNonJPEGCompanionPairsAreNotPairMemberCleanUpTargets() throws {
        for companion in ["HEIC", "jxl"] {
            for together in [false, true] {
                let fixture = try makePair(together: together, companionExtension: companion)
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let store = fixture.store
                XCTAssertEqual(store.rawJPEGPairCount, 1)
                store.cleanUpScope = .all
                for mode in [CleanUpMode.pairedJPEGs, .pairedRAWs] {
                    assertTargets(store, mode: mode, count: 0, bytes: 0)
                }
            }
        }
    }

    private func assertTargets(
        _ store: SessionStore,
        mode: CleanUpMode,
        count: Int,
        bytes: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(store.hasCleanUpTargets(for: mode), count > 0, file: file, line: line)
        let counts = store.cleanUpCounts(for: mode)
        XCTAssertEqual(counts.photos, count, file: file, line: line)
        XCTAssertEqual(counts.files, count, file: file, line: line)
        XCTAssertEqual(counts.bytes, bytes, file: file, line: line)
    }

    private func makePair(together: Bool, companionExtension: String = "JPG") throws -> (
        root: URL, raw: URL, jpeg: URL, store: SessionStore
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-PairScope-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rawURL = root.appendingPathComponent("PAIR.NEF")
        let jpegURL = root.appendingPathComponent("PAIR.\(companionExtension)")
        try Data("raw".utf8).write(to: rawURL)
        try Data("jpeg".utf8).write(to: jpegURL)
        let raw = PhotoFile(
            id: "PAIR.NEF", url: rawURL, captureDate: nil, cameraModel: nil,
            lensModel: nil, fileSize: 3, rating: .yes,
            starRating: .five, colorLabel: .purple
        )
        let jpeg = PhotoFile(
            id: "PAIR.\(companionExtension)", url: jpegURL, captureDate: nil, cameraModel: nil,
            lensModel: nil, fileSize: 4, rating: .no,
            starRating: .one, colorLabel: .red
        )
        let store = SessionStore()
        if together { store.setRawJPEGPairingMode(.together) }
        store.items = together
            ? [PhotoItem(primaryFile: raw, pairedFile: jpeg)]
            : [PhotoItem(primaryFile: raw), PhotoItem(primaryFile: jpeg)]
        store.phase = .ready
        store.rebuildDerivedDataForTesting(sourceFolder: root)
        return (root, rawURL, jpegURL, store)
    }
}
