import Foundation
import XCTest
@testable import Louppe

/// Differential checks for projection fast paths: every result must equal the
/// earlier full computation, kept here as the reference.
final class ProjectionEquivalenceTests: XCTestCase {
    // MARK: Projection

    func testCaptureDateGroupsMatchAdjacentComparisonReference() {
        var random = EquivalenceRandom(seed: 0xA3)
        for session in 0..<6 {
            let items = makeSession(count: 400 + session * 90, random: &random)
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: PhotoSort())
            for step in 0..<40 {
                let sort = randomSort(step: step, random: &random)
                let filter = randomFilter(items: items, random: &random)
                let grouping = step % 9 != 4
                let candidates: [Int]? = step % 5 == 2
                    ? items.indices.filter { _ in random.next() % 3 != 0 }.shuffled(using: &random)
                    : nil
                index.rebuildPreparedSort(items, sort: sort)
                index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: grouping,
                                  candidateIndices: candidates)
                let order = candidates.map(index.orderedCandidates) ?? index.sortedIndices
                let reference = referenceProjection(items, order: order, filter: filter,
                                                    sort: sort, grouping: grouping)
                assertEquivalent(index, reference, items: items,
                                 context: "session \(session) step \(step) \(sort)")
            }
        }
    }

    func testCaptureDateEdgeSessions() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = calendar("UTC")
        let tokyo = calendar("Asia/Tokyo")
        let cases: [[PhotoItem]] = [
            // One item; one unknown date.
            [item("A.JPG", date: base)],
            [item("A.JPG", date: nil)],
            // Same-instant ties, unknown dates, and items on the same day.
            (0..<12).map { item(String(format: "T%02d.JPG", 11 - $0), date: $0 < 4 ? base : nil) },
            // Midnight neighbours whose day depends on the scan calendar.
            [item("A.JPG", date: base.addingTimeInterval(-1), calendar: utc),
             item("B.JPG", date: base, calendar: utc),
             item("C.JPG", date: base.addingTimeInterval(-1), calendar: tokyo),
             item("D.MOV", date: base, calendar: tokyo, kind: .video),
             item("E.JPG", date: base.addingTimeInterval(86_400), calendar: tokyo)],
            // Every item unknown.
            (0..<5).map { item("U\($0).JPG", date: nil) },
        ]
        for (offset, items) in cases.enumerated() {
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: PhotoSort())
            for ascending in [true, false] {
                let sort = PhotoSort(key: .captureDate, ascending: ascending)
                index.rebuildPreparedSort(items, sort: sort)
                for filter in [PhotoFilter(), excludingTypes(["MOV"]), excludingTypes(["JPEG", "MOV"])] {
                    index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: true)
                    let reference = referenceProjection(items, order: index.sortedIndices, filter: filter,
                                                        sort: sort, grouping: true)
                    assertEquivalent(index, reference, items: items, context: "edge \(offset) \(ascending)")
                }
            }
        }
    }

    // MARK: Search through items

    func testSearchThroughItemsMatchesReferencePredicate() {
        var random = EquivalenceRandom(seed: 0x17E5)
        let items = makeSession(count: 700, random: &random)
        for query in ["dsc", "img 0", "trip 1 raw", "cafe", "CAFÉ", "東京", "photos 2023", "camera 3",
                      "jpeg", "raw + jpeg", "fünf", "unknown", "_00", "e\u{301}", "  ", "z q"] {
            var filter = PhotoFilter()
            filter.searchText = query
            let prepared = PreparedPhotoFilter(filter)
            XCTAssertEqual(items.indices.filter { prepared.matches(items[$0]) },
                           items.indices.filter { referenceMatches(prepared, items[$0]) }, query)
        }
    }

    // MARK: References (the computations before AUD-06)

    private struct Projection {
        let indices: [Int]
        let groups: [PhotoGroup]
        let entries: [PreparedSessionIndex.VisibleEntry]
        let titles: [Int: String]
        let locations: [Int: PreparedSessionIndex.VisibleLocation]
    }

    private func referenceProjection(_ items: [PhotoItem], order: [Int], filter: PhotoFilter,
                                     sort: PhotoSort, grouping: Bool) -> Projection {
        let prepared = PreparedPhotoFilter(filter)
        let indices = order.filter { referenceMatches(prepared, items[$0]) }
        var groups: [PhotoGroup] = []
        if !indices.isEmpty, !grouping || sort.key == .name {
            groups = [PhotoGroup(id: .ungrouped, title: nil, indices: indices)]
        } else if !indices.isEmpty {
            var run: [Int] = []
            var previousItem: PhotoItem?
            func closeRun() {
                guard let first = run.first else { return }
                groups.append(PhotoGroup(id: sort.key.groupID(for: items[first]),
                                         title: sort.key.groupTitle(for: items[first]), indices: run))
            }
            for index in indices {
                let item = items[index]
                if let previousItem, !sort.key.sameGroup(previousItem, item) {
                    closeRun()
                    run = []
                }
                run.append(index)
                previousItem = item
            }
            closeRun()
        }
        let entries = indices.map { PreparedSessionIndex.VisibleEntry(id: items[$0].id, index: $0) }
        var titles: [Int: String] = [:]
        var locations: [Int: PreparedSessionIndex.VisibleLocation] = [:]
        var position = 0
        for (groupIndex, group) in groups.enumerated() {
            if let title = group.title, let first = group.indices.first { titles[first] = title }
            for (positionInGroup, index) in group.indices.enumerated() {
                locations[index] = .init(position: position, groupIndex: groupIndex,
                                         positionInGroup: positionInGroup)
                position += 1
            }
        }
        return Projection(indices: indices, groups: groups, entries: entries, titles: titles,
                          locations: locations)
    }

    /// `PreparedPhotoFilter.matches` before inactive facets skipped their labels.
    private func referenceMatches(_ filter: PreparedPhotoFilter, _ item: PhotoItem) -> Bool {
        if filter.excludedMediaKinds.contains(item.mediaKind) { return false }
        if filter.excludedTypes.contains(item.fileTypeLabel) { return false }
        if filter.excludedCameras.contains(item.cameraLabel) { return false }
        if filter.excludedLenses.contains(item.lensLabel) { return false }
        if filter.excludedFilmSimulations.contains(item.filmSimulationFacet) { return false }
        if !filter.excludedVideoResolutions.isEmpty {
            guard item.isVideo else { return false }
            if filter.excludedVideoResolutions.contains(item.videoResolutionLabel ?? "Unknown resolution") {
                return false
            }
        }
        if !filter.excludedVideoCodecs.isEmpty {
            guard item.isVideo else { return false }
            if filter.excludedVideoCodecs.contains(item.videoCodec ?? "Unknown video codec") { return false }
        }
        if filter.excludedSubfolders.contains(item.subfolderLabel) { return false }
        if !filter.excludedDecisionStates.isEmpty || !filter.excludedStarStates.isEmpty
            || !filter.excludedColorStates.isEmpty {
            let metadata = item.metadataState
            if filter.excludedDecisionStates.contains(metadata.decision) { return false }
            if filter.excludedStarStates.contains(metadata.stars) { return false }
            if filter.excludedColorStates.contains(metadata.color) { return false }
        }
        if let dateRange = filter.dateRange {
            guard let date = item.captureDate, dateRange.contains(date) else { return false }
        }
        if filter.usesSpecificDates {
            if let day = item.captureDay {
                if filter.excludedDates.contains(day) { return false }
            } else if filter.excludesUnknownDate {
                return false
            }
        }
        if filter.usesSpecificYears {
            if let year = item.captureYear {
                if filter.excludedYears.contains(year) { return false }
            } else if filter.excludesUnknownYear {
                return false
            }
        }
        if let range = filter.apertureRange {
            guard let value = item.aperture, range.contains(value) else { return false }
        }
        if let range = filter.shutterRange {
            guard let value = item.shutterSpeed, range.contains(value) else { return false }
        }
        if let range = filter.isoRange {
            guard let value = item.iso, range.contains(value) else { return false }
        }
        if let range = filter.durationRange {
            guard let value = item.duration, range.contains(value) else { return false }
        }
        if let range = filter.videoFrameRateRange {
            guard item.isVideo, let value = item.videoFrameRate, range.contains(value) else { return false }
        }
        return referenceSearch(item.searchableText, filter.searchTokens)
    }

    /// The general matcher exactly as it was written before the fast path.
    private func referenceSearch(_ text: String, _ tokens: [Substring]) -> Bool {
        for token in tokens where !text.contains(token) {
            return false
        }
        return true
    }

    private func assertEquivalent(_ index: PreparedSessionIndex, _ reference: Projection, items: [PhotoItem],
                                  context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(index.visibleIndices, reference.indices, context, file: file, line: line)
        XCTAssertEqual(index.visibleGroups, reference.groups, context, file: file, line: line)
        XCTAssertEqual(index.visibleEntries, reference.entries, context, file: file, line: line)
        XCTAssertEqual(index.visibleGroupTitles, reference.titles, context, file: file, line: line)
        XCTAssertEqual(index.visibleLocations, reference.locations, context, file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map(\.id), reference.groups.map(\.id), context,
                       file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map(\.title), reference.groups.map(\.title), context,
                       file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map { $0.entries.map(\.index) }, reference.groups.map(\.indices),
                       context, file: file, line: line)
    }

    // MARK: Fixtures

    private func makeSession(count: Int, random: inout EquivalenceRandom) -> [PhotoItem] {
        let base = Date(timeIntervalSince1970: 1_690_000_000)
        let calendars = [Calendar.current, calendar("UTC"), calendar("Asia/Tokyo"), calendar("America/Los_Angeles")]
        let names = ["DSC", "IMG", "Café", "naïve", "東京", "фото", "a-b_c", "Fünf", "e\u{301}clair", "😀"]
        var items: [PhotoItem] = []
        for offset in 0..<count {
            let roll = random.next()
            let day = Double(roll % 9)
            let time = Double(random.next() % 4) * 21_600 - 3_600 // crosses midnight in some zones
            let date: Date? = roll % 11 == 0 ? nil : base.addingTimeInterval(day * 86_400 + time)
            let kind: MediaKind = roll % 7 == 3 ? .video : .photo
            let ext = kind == .video ? "MOV" : (roll % 3 == 0 ? "ARW" : "JPG")
            let name = String(format: "%@_%04d.%@", names[Int(roll % UInt64(names.count))], offset, ext)
            let subfolder = roll % 5 == 0 ? nil : "Trip \(roll % 4)"
            let id = subfolder.map { "\($0)/\(name)" } ?? name
            let rating: Rating = [.yes, .no, .undecided][Int(random.next() % 3)]
            let file = PhotoFile(
                id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-equivalence/\(id)"),
                captureDate: date,
                cameraModel: roll % 13 == 0 ? nil : "Camera \(roll % 5)",
                lensModel: roll % 17 == 0 ? nil : "Lens \(roll % 3)",
                mediaKind: kind, fileSize: 1, rating: rating,
                starRating: roll % 4 == 0 ? .three : nil,
                colorLabel: roll % 6 == 0 ? .green : nil,
                calendar: calendars[Int(random.next() % UInt64(calendars.count))])
            if ext == "ARW", roll % 2 == 0 {
                let pairedID = String(id.dropLast(3)) + "JPG"
                let paired = PhotoFile(
                    id: pairedID, url: URL(fileURLWithPath: "/private/tmp/louppe-equivalence/\(pairedID)"),
                    captureDate: date, cameraModel: nil, lensModel: nil, fileSize: 1,
                    rating: random.next() % 4 == 0 ? .no : rating)
                items.append(PhotoItem(primaryFile: file, pairedFile: paired))
            } else {
                items.append(PhotoItem(primaryFile: file))
            }
        }
        // Scan order is canonical; shuffle some sessions to cover arbitrary input.
        return count % 2 == 0 ? items.sorted { PhotoSort().areInOrder($0, $1) } : items
    }

    private func randomSort(step: Int, random: inout EquivalenceRandom) -> PhotoSort {
        let keys: [PhotoSort.Key] = [.captureDate, .captureDate, .captureDate, .name, .camera, .fileType,
                                     .decision, .subfolder, .mediaKind]
        return PhotoSort(key: keys[Int(random.next() % UInt64(keys.count))], ascending: step % 2 == 0)
    }

    private func randomFilter(items: [PhotoItem], random: inout EquivalenceRandom) -> PhotoFilter {
        var filter = PhotoFilter()
        switch random.next() % 9 {
        case 0: break
        case 1: filter.excludedDecisionStates = [.no]
        case 2: filter.excludedCameras = ["Camera \(random.next() % 5)", "Unknown"]
        case 3: filter.excludedTypes = ["JPEG"]
        case 4: filter.excludedMediaKinds = [.video]
        case 5: filter.searchText = ["dsc", "trip 2", "cafe", "東京", "jpeg 00", "e\u{301}"][Int(random.next() % 6)]
        case 6:
            filter.excludedSubfolders = ["None"]
            filter.excludedLenses = ["Lens 1"]
        case 7:
            filter.excludedStarStates = [.unrated]
            filter.excludedColorStates = [.label(.green)]
        default:
            filter.dateEnabled = true
            filter.dateMode = .specificDates
            filter.excludedDates = Set(items.prefix(40).compactMap(\.captureDay))
            filter.excludesUnknownDate = random.next() % 2 == 0
        }
        return filter
    }

    private func excludingTypes(_ types: Set<String>) -> PhotoFilter {
        var filter = PhotoFilter()
        filter.excludedTypes = types
        return filter
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func item(_ name: String, date: Date?, calendar: Calendar = .current,
                      kind: MediaKind = .photo) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-equivalence/\(name)"),
            captureDate: date, cameraModel: nil, lensModel: nil, mediaKind: kind, fileSize: 1,
            calendar: calendar))
    }
}

/// SplitMix64: reproducible randomized inputs.
struct EquivalenceRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
