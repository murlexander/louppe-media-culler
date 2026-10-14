import Foundation
import XCTest
@testable import Louppe

final class PreparedSessionMetadataOrderingTests: XCTestCase {
    func testPureMetadataSortMatchesComparatorForArbitraryInputAndEveryDirection() {
        let fixture = metadataFixture()
        for items in [fixture, Array(fixture.reversed()), interleaved(fixture)] {
            var index = PreparedSessionIndex()
            for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
                for ascending in [true, false] {
                    let sort = PhotoSort(key: key, ascending: ascending)
                    index.rebuildSort(items, sort: sort)
                    XCTAssertEqual(index.sortedIndices, expectedOrder(items, sort: sort))
                    XCTAssertEqual(Set(index.sortedIndices), Set(items.indices))
                }
            }
        }
    }

    func testEqualMetadataOnReversedNamesKeepsCanonicalTies() {
        for date in [Date?.none, Date(timeIntervalSince1970: 1)] {
            let items = ["Z.JPG", "A.JPG"].enumerated().map { offset, name in
                item(name, position: offset, date: date, decision: .yes, stars: .three, color: .green)
            }
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: PhotoSort())
            XCTAssertEqual(index.sortedIndices, [1, 0])
            for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
                for ascending in [true, false] {
                    index.rebuildPreparedSort(items, sort: PhotoSort(key: key, ascending: ascending))
                    XCTAssertEqual(index.sortedIndices, [1, 0])
                }
            }
        }
    }

    func testPreparedMetadataEditsAndResetRetainComparatorOrderAndLookupIdentity() {
        let items = interleaved(metadataFixture())
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: PhotoSort(key: .name, ascending: false))
        let itemMap = index.itemIndexByID
        for mutation in 0..<4 {
            for offset in stride(from: mutation, to: items.count, by: 4) {
                items[offset].setRating(mutation.isMultiple(of: 2) ? .yes : .no, ratedAt: nil)
                items[offset].setStars(mutation.isMultiple(of: 2) ? .five : nil, changedAt: nil)
                items[offset].setColor(mutation.isMultiple(of: 2) ? .purple : nil, changedAt: nil)
            }
            for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
                for ascending in [true, false] {
                    let sort = PhotoSort(key: key, ascending: ascending)
                    index.rebuildPreparedSort(items, sort: sort)
                    index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
                    XCTAssertEqual(index.sortedIndices, expectedOrder(items, sort: sort))
                    XCTAssertEqual(index.visibleIndices, index.sortedIndices)
                    XCTAssertEqual(index.visibleLocations.count, items.count)
                    XCTAssertEqual(index.itemIndexByID, itemMap)
                }
            }
        }
        index.reset()
        index.rebuildItems([], sort: PhotoSort(key: .decision))
        XCTAssertTrue(index.sortedIndices.isEmpty)
        XCTAssertTrue(index.itemIndexByID.isEmpty)
    }

    func testSameCountReplacementAndReorderingRebuildChronology() {
        let first = metadataFixture()
        let second = Array(first.reversed())
        var index = PreparedSessionIndex()
        index.rebuildItems(first, sort: PhotoSort(key: .decision))
        index.invalidateItemOrder()
        let sort = PhotoSort(key: .starRating, ascending: false)
        index.rebuildPreparedSort(second, sort: sort)
        XCTAssertEqual(index.sortedIndices, expectedOrder(second, sort: sort))

        // Generic callers can replace immutable dates without declaring a
        // structural generation, even when IDs and count stay unchanged.
        let replacement = second.enumerated().map { offset, original in
            item(original.displayName, position: offset,
                 date: offset.isMultiple(of: 3) ? nil : Date(timeIntervalSince1970: Double(-offset)),
                 decision: .no, stars: .one, color: .red)
        }
        index.rebuildSort(replacement, sort: sort)
        XCTAssertEqual(index.sortedIndices, expectedOrder(replacement, sort: sort))
        index.rebuildSort(replacement, sort: PhotoSort())
        XCTAssertEqual(index.sortedIndices, expectedOrder(replacement, sort: PhotoSort()))
    }

    @MainActor
    func testRealScanAndMainActorPairPreparationPreserveAllPhysicalFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppePairOrder-\(UUID().uuidString)", isDirectory: true)
        let names = [
            "B/SHOT.NEF", "A/SHOT.JPG", "B/SHOT.PNG", "A/SHOT.MOV",
            "A/SHOT.WAV", "A/SHOT.txt", "B/AMBIG.NEF", "A/AMBIG.JPG",
            "C/AMBIG.jpeg", "Z.JPG", "A.JPG", "nested/only.RAF",
        ]
        let contents = Dictionary(uniqueKeysWithValues: names.map { ($0, Data($0.utf8)) })
        defer { try? FileManager.default.removeItem(at: root) }
        for name in names.reversed() {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents[name]!.write(to: url)
        }
        for mode in [RawJPEGPairingMode.separate, .together] {
            let items = try FolderScanner.scan(root, pairingMode: mode) { _ in }
            XCTAssertEqual(items.flatMap(\.individualFiles).count, names.count)
            XCTAssertEqual(Set(items.flatMap(\.individualFiles).map(\.id)).count, names.count)
            XCTAssertEqual(items.count, mode == .together ? names.count - 1 : names.count)
            XCTAssertEqual(items.filter { $0.pairedFile != nil }.count, mode == .together ? 1 : 0)
            let pairs = FolderScanner.rawJPEGPairs(from: items, root: root)
            XCTAssertEqual(pairs.map { $0.raw.id }, ["B/SHOT.NEF"])
            XCTAssertEqual(pairs.map { $0.jpeg.id }, ["A/SHOT.JPG"])

            let store = SessionStore()
            store.items = items
            store.rebuildDerivedDataForTesting(sourceFolder: root)
            store.pauseQualityCueAnalysis()
            XCTAssertEqual(store.rawJPEGPairCount, 1)
            XCTAssertEqual(Set(store.visibleIndices), Set(items.indices))
            store.beginTerminationPreparation()
        }
        for name in names {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), contents[name])
        }
    }

    private func expectedOrder(_ items: [PhotoItem], sort: PhotoSort) -> [Int] {
        items.indices.sorted { sort.areInOrder(items[$0], items[$1]) }
    }

    private func metadataFixture() -> [PhotoItem] {
        let names = ["Z.JPG", "A.JPG", "IMG_10.JPG", "IMG_2.JPG", "caf\u{00e9}.JPG", "cafe\u{0301}.JPG", "Same.JPG", "same.JPG"]
        return (0..<56).map { offset in
            let stars = offset % 7 < 5 ? StarRating.allCases[offset % 7] : nil
            let color = offset % 7 < 5 ? PhotoColorLabel.allCases[offset % 7] : nil
            let date = offset.isMultiple(of: 3) ? nil : Date(timeIntervalSince1970: Double(offset % 5))
            let decision: Rating = offset % 3 == 0 ? .yes : (offset % 3 == 1 ? .no : .undecided)
            let primary = item(names[offset % names.count], position: offset, date: date,
                               decision: decision, stars: stars, color: color)
            guard offset % 7 == 6 else { return primary }
            let partner = item("partner.RAF", position: offset + 100, date: date,
                               decision: decision == .yes ? .no : .yes, stars: .five, color: .purple)
            return PhotoItem(primaryFile: primary.primaryFile, pairedFile: partner.primaryFile)
        }
    }

    private func interleaved<T>(_ items: [T]) -> [T] {
        items.indices.filter { $0.isMultiple(of: 2) }.map { items[$0] }
            + items.indices.reversed().filter { !$0.isMultiple(of: 2) }.map { items[$0] }
    }

    private func item(
        _ name: String, position: Int, date: Date?, decision: Rating,
        stars: StarRating?, color: PhotoColorLabel?
    ) -> PhotoItem {
        let url = URL(fileURLWithPath: "/private/tmp/louppe-metadata-order/\(position)/\(name)")
        return PhotoItem(primaryFile: PhotoFile(
            id: url.path(percentEncoded: true), url: url,
            captureDate: date, cameraModel: nil, lensModel: nil, fileSize: 1,
            rating: decision, starRating: stars, colorLabel: color
        ))
    }
}
