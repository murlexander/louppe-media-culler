import Foundation
import XCTest
@testable import Louppe

final class PreparedSessionLargeFolderTests: XCTestCase {
    func testCameraAndLensRanksMatchComparatorAcrossPermutationsAndDirections() {
        let fixture = modelFixture()
        let permutations = [fixture, Array(fixture.reversed()),
                            fixture.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                                + fixture.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)]
        for items in permutations {
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: PhotoSort())
            for key in [PhotoSort.Key.camera, .lens] {
                for ascending in [true, false, true] {
                    let sort = PhotoSort(key: key, ascending: ascending)
                    index.rebuildPreparedSort(items, sort: sort)
                    let expected = items.indices.sorted { sort.areInOrder(items[$0], items[$1]) }
                    XCTAssertEqual(index.sortedIndices, expected, "\(key), ascending=\(ascending)")
                    XCTAssertEqual(Set(index.sortedIndices), Set(items.indices))
                    let nilIndices = expected.filter {
                        (key == .camera ? items[$0].cameraModel : items[$0].lensModel) == nil
                    }
                    XCTAssertEqual(Array(expected.suffix(nilIndices.count)), nilIndices)
                    index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
                    assertPresentation(index, items: items, expected: expected, sort: sort, grouped: true)
                }
            }
        }
    }

    func testCanonicalEquivalentSpellingsKeepComparatorOrderAndEqualModelsKeepExactTies() {
        // Swift equality does not establish localized comparator equality.
        // Distinct Unicode encodings must reach that comparator independently.
        let composed = "Caf\u{00e9} 2"
        let decomposed = "Cafe\u{0301} 2"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let items = [
            photo("z/Same.JPG", name: "Same.JPG", date: nil, camera: composed, lens: decomposed),
            photo("b/Same.JPG", name: "Same.JPG", date: 100, camera: decomposed, lens: composed),
            photo("a/Same.JPG", name: "Same.JPG", date: 100, camera: composed, lens: decomposed),
            photo("c/IMG_10.JPG", date: 1, camera: decomposed, lens: composed),
            photo("d/IMG_2.JPG", date: 1, camera: composed, lens: decomposed)
        ]
        var index = PreparedSessionIndex()
        for key in [PhotoSort.Key.camera, .lens] {
            for ascending in [true, false] {
                let sort = PhotoSort(key: key, ascending: ascending)
                index.rebuildSort(items, sort: sort)
                XCTAssertEqual(index.sortedIndices, items.indices.sorted { sort.areInOrder(items[$0], items[$1]) })
                let equalModels = items.map {
                    photo($0.id, name: $0.displayName, date: $0.captureDate?.timeIntervalSince1970,
                          camera: composed, lens: decomposed)
                }
                index.rebuildSort(equalModels, sort: sort)
                XCTAssertEqual(index.sortedIndices, [4, 3, 2, 1, 0])
            }
        }
    }

    func testSameCountReplacementAndExplicitInvalidationDiscardModelRanksAndPresentation() {
        let original = modelFixture()
        let replacement = original.enumerated().map { offset, item in
            photo(item.id, name: item.displayName, date: Double(-offset),
                  camera: "Replacement \(offset % 3)", lens: offset.isMultiple(of: 2) ? nil : "New lens")
        }
        var index = PreparedSessionIndex()
        for key in [PhotoSort.Key.camera, .lens] {
            let sort = PhotoSort(key: key, ascending: false)
            index.rebuildItems(original, sort: sort)
            index.applyFilter(PhotoFilter(), to: original, sort: sort, isGroupingEnabled: true)
            for items in [replacement, Array(replacement.reversed())] {
                index.invalidateItemOrder()
                index.rebuildPreparedSort(items, sort: sort)
                XCTAssertEqual(index.sortedIndices, items.indices.sorted { sort.areInOrder(items[$0], items[$1]) })
            }
            // The arbitrary-input API also invalidates without a separate call.
            index.rebuildSort(original, sort: sort)
            XCTAssertEqual(index.sortedIndices, original.indices.sorted { sort.areInOrder(original[$0], original[$1]) })
            index.rebuildItems(replacement, sort: sort)
            index.applyFilter(PhotoFilter(), to: replacement, sort: sort, isGroupingEnabled: true)
            assertPresentation(index, items: replacement, expected: index.sortedIndices, sort: sort, grouped: true)
            for (position, item) in replacement.enumerated() {
                XCTAssertEqual(index.itemIndex(forID: item.id), position)
            }
        }

        // Same indices and IDs are insufficient: immutable group values changed.
        let first = [photo("A.JPG", camera: "Old"), photo("B.JPG", camera: "Old")]
        let second = [photo("A.JPG", camera: "New"), photo("B.JPG", camera: "New")]
        let sort = PhotoSort(key: .camera)
        index.rebuildItems(first, sort: sort)
        index.applyFilter(PhotoFilter(), to: first, sort: sort, isGroupingEnabled: true)
        let oldID = index.visibleGroups.first?.id
        index.rebuildItems(second, sort: sort)
        index.applyFilter(PhotoFilter(), to: second, sort: sort, isGroupingEnabled: true)
        XCTAssertNotEqual(index.visibleGroups.first?.id, oldID)
        XCTAssertEqual(index.visibleGroups.first?.title, "New")
        index.reset()
        index.rebuildItems([], sort: sort)
        index.applyFilter(PhotoFilter(), to: [], sort: sort, isGroupingEnabled: true)
        XCTAssertTrue(index.visibleGridGroups.isEmpty)
        XCTAssertTrue(index.visibleLocations.isEmpty)
    }

    func testUnrestrictedPreparedPredicatesAndUnchangedMatchesReusePresentationStorage() {
        let items = modelFixture()
        let sort = PhotoSort(key: .camera)
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: sort)
        index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
        var neutral = PhotoFilter()
        neutral.searchText = " \t\n "
        neutral.isoEnabled = true
        neutral.isoFrom = .nan
        neutral.apertureEnabled = true
        neutral.apertureFrom = 8
        neutral.apertureTo = 2
        neutral.dateEnabled = true
        neutral.dateMode = .specificDates
        neutral.excludedDates = []
        XCTAssertTrue(items.allSatisfy(PreparedPhotoFilter(neutral).matches))
        let entries = index.visibleEntries
        let groups = index.visibleGroups
        let gridGroups = index.visibleGridGroups
        index.applyFilter(neutral, to: items, sort: sort, isGroupingEnabled: true)
        assertSharedStorage(entries, index.visibleEntries)
        assertSharedStorage(groups, index.visibleGroups)
        assertSharedStorage(gridGroups, index.visibleGridGroups)
        assertPresentation(index, items: items, expected: index.sortedIndices, sort: sort, grouped: true)

        var restricted = PhotoFilter()
        restricted.excludedCameras = [items[0].cameraLabel]
        index.applyFilter(restricted, to: items, sort: sort, isGroupingEnabled: true)
        let filteredEntries = index.visibleEntries
        let filteredGroups = index.visibleGroups
        restricted.excludedLenses = ["No such lens"] // Different predicate, identical matches.
        index.applyFilter(restricted, to: items, sort: sort, isGroupingEnabled: true)
        assertSharedStorage(filteredEntries, index.visibleEntries)
        assertSharedStorage(filteredGroups, index.visibleGroups)
        let expected = index.sortedIndices.filter { PreparedPhotoFilter(restricted).matches(items[$0]) }
        assertPresentation(index, items: items, expected: expected, sort: sort, grouped: true)
    }

    func testMutableGroupingRefreshesWhenVisibleOrderAndMembershipStayIdentical() {
        for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
            let items = (0..<8).map { photo("\($0).JPG", date: Double($0)) }
            let sort = PhotoSort(key: key)
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: sort)
            index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
            let oldGroupID = index.visibleGroups.first?.id
            for item in items {
                item.setRating(.yes, ratedAt: nil)
                item.setStars(.three, changedAt: nil)
                item.setColor(.red, changedAt: nil)
            }
            index.rebuildPreparedSort(items, sort: sort)
            index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
            XCTAssertNotEqual(index.visibleGroups.first?.id, oldGroupID)
            assertPresentation(index, items: items, expected: Array(items.indices), sort: sort, grouped: true)
            // Splitting and merging the trailing group also keeps index order.
            items[7].setRating(.no, ratedAt: nil)
            items[7].setStars(nil, changedAt: nil)
            items[7].setColor(nil, changedAt: nil)
            index.rebuildPreparedSort(items, sort: sort)
            index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
            XCTAssertEqual(index.visibleGroups.count, 2)
            assertPresentation(index, items: items, expected: Array(items.indices), sort: sort, grouped: true)
            items[7].setRating(.yes, ratedAt: nil)
            items[7].setStars(.three, changedAt: nil)
            items[7].setColor(.red, changedAt: nil)
            index.rebuildPreparedSort(items, sort: sort)
            index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
            XCTAssertEqual(index.visibleGroups.count, 1)
        }
    }

    func testCueMasksGroupingChangesAndReviewExitKeepMapsAndSelectionConsistent() {
        let items = (0..<6).map { photo("\($0).JPG", date: Double($0), camera: $0 < 3 ? "A" : "B") }
        let sort = PhotoSort(key: .camera)
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: sort)
        var filter = PhotoFilter()
        filter.selectedQualityCues = [.highISO]
        var masks: [QualityCueMatch] = [.highISO, [], .highISO, .highISO, [], .highISO]
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: true, qualityCueMatches: masks)
        let survivingGroupID = index.visibleGroups[0].id
        var selection = SelectionState()
        selection.replace(with: [0, 2, 5], items: items)
        masks[0] = []
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: true, qualityCueMatches: masks)
        XCTAssertEqual(index.visibleGroups[0].id, survivingGroupID)
        assertPresentation(index, items: items, expected: [2, 3, 5], sort: sort, grouped: true)
        selection.retainVisible(items: items, preparedIndex: index)
        XCTAssertEqual(selection.indices, [2, 5])
        XCTAssertEqual(selection.itemIDs, [items[2].id, items[5].id])
        XCTAssertEqual(selection.replacementCurrentIndex(currentIndex: 0, preparedIndex: index), 2)

        filter.selectedQualityCues = []
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: false, qualityCueMatches: masks)
        assertPresentation(index, items: items, expected: Array(items.indices), sort: sort, grouped: false)
        index.applyGroupedReview([
            .init(id: "one", mode: .captureBursts, itemIDs: Array(items.prefix(3).map(\.id))),
            .init(id: "two", mode: .captureBursts, itemIDs: Array(items.suffix(3).map(\.id)))
        ], to: items)
        XCTAssertEqual(index.visibleIndices, Array(items.indices))
        XCTAssertEqual(index.visibleGridGroups.map(\.id), index.visibleGroups.map(\.id))
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: false)
        assertPresentation(index, items: items, expected: Array(items.indices), sort: sort, grouped: false)
        index.rebuildGroups(for: items, sort: sort, isGroupingEnabled: true)
        assertPresentation(index, items: items, expected: Array(items.indices), sort: sort, grouped: true)
    }

    private func assertSharedStorage<T>(_ before: [T], _ after: [T], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(before.isEmpty, file: file, line: line)
        before.withUnsafeBufferPointer { left in
            after.withUnsafeBufferPointer { right in
                XCTAssertEqual(left.baseAddress, right.baseAddress,
                               "Unchanged presentation must retain its prepared storage", file: file, line: line)
            }
        }
    }

    private func assertPresentation(_ index: PreparedSessionIndex, items: [PhotoItem], expected: [Int],
                                    sort: PhotoSort, grouped: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(index.visibleIndices, expected, file: file, line: line)
        XCTAssertEqual(index.visibleEntries.map(\.id), expected.map { items[$0].id }, file: file, line: line)
        XCTAssertEqual(index.visibleEntries.map(\.index), expected, file: file, line: line)
        var runs: [[Int]] = []
        for itemIndex in expected {
            if let last = runs.last?.last, grouped, sort.key != .name,
               !sort.key.sameGroup(items[last], items[itemIndex]) {
                runs.append([itemIndex])
            } else if runs.isEmpty {
                runs.append([itemIndex])
            } else {
                runs[runs.count - 1].append(itemIndex)
            }
        }
        let groups = runs.map { run in
            PhotoGroup(id: grouped && sort.key != .name ? sort.key.groupID(for: items[run[0]]) : .ungrouped,
                       title: grouped && sort.key != .name ? sort.key.groupTitle(for: items[run[0]]) : nil,
                       indices: run)
        }
        XCTAssertEqual(index.visibleGroups, groups, file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map(\.id), groups.map(\.id), file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map(\.title), groups.map(\.title), file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.flatMap { $0.entries.map(\.index) }, expected, file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.flatMap { $0.entries.map(\.id) }, expected.map { items[$0].id }, file: file, line: line)
        XCTAssertEqual(index.visibleLocations.count, expected.count, file: file, line: line)
        var position = 0
        var titles: [Int: String] = [:]
        for (groupIndex, group) in groups.enumerated() {
            if let title = group.title { titles[group.indices[0]] = title }
            for (positionInGroup, itemIndex) in group.indices.enumerated() {
                XCTAssertEqual(index.location(forItemIndex: itemIndex),
                               .init(position: position, groupIndex: groupIndex, positionInGroup: positionInGroup),
                               file: file, line: line)
                position += 1
            }
        }
        XCTAssertEqual(index.visibleGroupTitles, titles, file: file, line: line)
        for itemIndex in items.indices where !Set(expected).contains(itemIndex) {
            XCTAssertNil(index.location(forItemIndex: itemIndex), file: file, line: line)
        }
    }

    private func modelFixture() -> [PhotoItem] {
        let values: [String?] = [nil, "", "Camera 2", "Camera 02", "Camera 10", "camera 2",
                                 "CAMERA 2", "Caf\u{00e9}", "Cafe\u{0301}", "Ｃａｍｅｒａ 2", "Å", "A\u{030a}"]
        let names = ["Z.JPG", "A.JPG", "IMG_10.JPG", "IMG_2.JPG", "Same.JPG", "same.JPG", "caf\u{00e9}.JPG", "cafe\u{0301}.JPG"]
        return (0..<96).map { offset in
            photo("folder\(offset)/\(names[offset % names.count])", name: names[offset % names.count],
                  date: offset.isMultiple(of: 5) ? nil : Double(offset % 4),
                  camera: values[offset % values.count], lens: values[(offset / 3) % values.count])
        }
    }

    private func photo(_ id: String, name: String? = nil, date: TimeInterval? = 100,
                       camera: String? = nil, lens: String? = nil) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-large-index/\(id)").deletingLastPathComponent()
                .appendingPathComponent(name ?? (id as NSString).lastPathComponent),
            captureDate: date.map(Date.init(timeIntervalSince1970:)), cameraModel: camera, lensModel: lens,
            fileSize: 1))
    }
}
