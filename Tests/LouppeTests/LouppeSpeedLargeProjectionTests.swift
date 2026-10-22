import Foundation
import XCTest
@testable import Louppe

/// Opt-in pure-index measurements. These exclude scan/I/O, observable-store
/// publication, selection reconciliation and mounted SwiftUI rendering.
@MainActor
final class LouppeSpeedLargeProjectionTests: XCTestCase {
    func testDistinctModelRanksAndUnchangedProjection() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "large-projection")
        for count in SpeedBenchmark.sizes {
            let items = fixture(count: count)
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: PhotoSort())
            var referenceOrder: [Int] = []
            for key in [PhotoSort.Key.camera, .lens] {
                let sort = PhotoSort(key: key)
                let expected = items.indices.sorted { sort.areInOrder(items[$0], items[$1]) }
                try report.measure(name: "sort.\(key.rawValue).comparator-reference", count: count) {
                    referenceOrder = items.indices.sorted { sort.areInOrder(items[$0], items[$1]) }
                }
                XCTAssertEqual(referenceOrder, expected)
                try report.measure(name: "sort.\(key.rawValue).cold-distinct-ranks", count: count, prepare: {
                    // The structural owner already prepared chronology and ID
                    // maps. Include first-use string ranking, exclude setup.
                    index.rebuildItems(items, sort: PhotoSort())
                }) {
                    index.rebuildPreparedSort(items, sort: sort)
                }
                XCTAssertEqual(index.sortedIndices, expected)
                try report.measure(name: "sort.\(key.rawValue).warm-distinct-ranks", count: count, prepare: {
                    index.rebuildPreparedSort(items, sort: PhotoSort(key: key, ascending: false))
                }) {
                    index.rebuildPreparedSort(items, sort: sort)
                }
                XCTAssertEqual(index.sortedIndices, expected)
                index.rebuildPreparedSort(items, sort: PhotoSort(key: key, ascending: false))
                XCTAssertEqual(index.sortedIndices, items.indices.sorted {
                    PhotoSort(key: key, ascending: false).areInOrder(items[$0], items[$1])
                })
            }

            let sort = PhotoSort(key: .camera)
            index.rebuildPreparedSort(items, sort: sort)
            let order = index.sortedIndices
            let unrestricted = PhotoFilter()
            var reference = fullProjection(items, order: order, filter: unrestricted, sort: sort)
            try report.measure(name: "projection.unrestricted.full-rebuild-reference", count: count) {
                reference = fullProjection(items, order: order, filter: unrestricted, sort: sort)
            }
            try report.measure(name: "projection.unrestricted.unchanged-prepared", count: count) {
                index.applyFilter(unrestricted, to: items, sort: sort, isGroupingEnabled: true)
            }
            assertEquivalent(index, reference: reference, items: items)

            var allVisible = PhotoFilter()
            allVisible.excludedCameras = ["Absent model"]
            try report.measure(name: "projection.active-all-visible.unchanged-prepared", count: count) {
                index.applyFilter(allVisible, to: items, sort: sort, isGroupingEnabled: true)
            }
            assertEquivalent(index, reference: reference, items: items)

            var restricted = PhotoFilter()
            restricted.excludedCameras = ["Camera 2", "Camera 4"]
            try report.measure(name: "projection.restricted.full-rebuild-reference", count: count) {
                reference = fullProjection(items, order: order, filter: restricted, sort: sort)
            }
            try report.measure(name: "projection.restricted.unchanged-prepared", count: count) {
                index.applyFilter(restricted, to: items, sort: sort, isGroupingEnabled: true)
            }
            assertEquivalent(index, reference: reference, items: items)

            var narrow = false
            try report.measure(name: "projection.membership-toggle.full-rebuild-reference", count: count) {
                narrow.toggle()
                reference = fullProjection(items, order: order,
                                           filter: narrow ? restricted : unrestricted, sort: sort)
            }
            var preparedNarrow = false
            try report.measure(name: "projection.membership-toggle.prepared", count: count) {
                preparedNarrow.toggle()
                index.applyFilter(preparedNarrow ? restricted : unrestricted,
                                  to: items, sort: sort, isGroupingEnabled: true)
            }
            XCTAssertEqual(preparedNarrow, narrow)
            assertEquivalent(index, reference: reference, items: items)

            // Identical selected-cue membership is common during accepted
            // evidence updates. Numeric masks stay owned by the caller.
            let masks: [QualityCueMatch] = items.indices.map { $0.isMultiple(of: 3) ? .highISO : [] }
            var cueFilter = restricted
            cueFilter.selectedQualityCues = [.highISO]
            try report.measure(name: "projection.cue-mask.unchanged-prepared", count: count) {
                index.applyFilter(cueFilter, to: items, sort: sort, isGroupingEnabled: true,
                                  qualityCueMatches: masks)
            }
            let expectedCueOrder = order.filter {
                !masks[$0].intersection(.highISO).isEmpty && PreparedPhotoFilter(restricted).matches(items[$0])
            }
            XCTAssertEqual(index.visibleIndices, expectedCueOrder)
            XCTAssertEqual(index.visibleGroups.flatMap(\.indices), expectedCueOrder)
            XCTAssertEqual(index.visibleLocations.count, expectedCueOrder.count)
            XCTAssertEqual(index.visibleGridGroups.flatMap { $0.entries.map(\.id) },
                           expectedCueOrder.map { items[$0].id })
        }
        try report.finish()
    }

    private struct Projection {
        let indices: [Int]
        let groups: [PhotoGroup]
        let entries: [PreparedSessionIndex.VisibleEntry]
        let titles: [Int: String]
        let locations: [Int: PreparedSessionIndex.VisibleLocation]
    }

    /// Retain the old full traversal/rebuild workload independently of the
    /// production cache. The old path had Browser entries but no Grid slices.
    private func fullProjection(_ items: [PhotoItem], order: [Int], filter: PhotoFilter,
                                sort: PhotoSort) -> Projection {
        let prepared = PreparedPhotoFilter(filter)
        let indices = order.filter { prepared.matches(items[$0]) }
        var groups: [PhotoGroup] = []
        var run: [Int] = []
        func closeRun() {
            guard let first = run.first else { return }
            groups.append(PhotoGroup(id: sort.key.groupID(for: items[first]),
                                     title: sort.key.groupTitle(for: items[first]), indices: run))
        }
        for index in indices {
            if let previous = run.last, !sort.key.sameGroup(items[previous], items[index]) {
                closeRun()
                run = []
            }
            run.append(index)
        }
        closeRun()
        let entries = indices.map { PreparedSessionIndex.VisibleEntry(id: items[$0].id, index: $0) }
        var titles: [Int: String] = [:]
        var locations: [Int: PreparedSessionIndex.VisibleLocation] = [:]
        locations.reserveCapacity(indices.count)
        var position = 0
        for (groupIndex, group) in groups.enumerated() {
            if let title = group.title, let first = group.indices.first { titles[first] = title }
            for (positionInGroup, index) in group.indices.enumerated() {
                locations[index] = .init(position: position, groupIndex: groupIndex, positionInGroup: positionInGroup)
                position += 1
            }
        }
        return Projection(indices: indices, groups: groups, entries: entries, titles: titles, locations: locations)
    }

    private func assertEquivalent(_ index: PreparedSessionIndex, reference: Projection, items: [PhotoItem],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(index.visibleIndices, reference.indices, file: file, line: line)
        XCTAssertEqual(index.visibleGroups, reference.groups, file: file, line: line)
        XCTAssertEqual(index.visibleEntries, reference.entries, file: file, line: line)
        XCTAssertEqual(index.visibleGroupTitles, reference.titles, file: file, line: line)
        XCTAssertEqual(index.visibleLocations, reference.locations, file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map(\.id), reference.groups.map(\.id), file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.flatMap { $0.entries.map(\.id) },
                       reference.indices.map { items[$0].id }, file: file, line: line)
    }

    private func fixture(count: Int) -> [PhotoItem] {
        (0..<count).map { offset in
            let name = String(format: "FRAME_%06d.JPG", offset)
            return PhotoItem(primaryFile: PhotoFile(
                id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-speed-large-projection/\(name)"),
                captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)),
                cameraModel: offset.isMultiple(of: 37) ? nil : "Camera \(offset % 25)",
                lensModel: offset.isMultiple(of: 29) ? nil : "Lens \(offset % 4)", fileSize: 1))
        }
    }
}
