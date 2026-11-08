#if LOUPPE_TEST_SEAMS
import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class DateYearFilterTests: XCTestCase {
    func testFacetsCountYearsAscendingAndShareTheUnknownDateCount() throws {
        let items = try fixture()
        let facets = SessionOpeningFacets(items: items)
        XCTAssertEqual(facets.availableCaptureYears, [y(2022), y(2024)])
        XCTAssertEqual(facets.captureYearCounts, [y(2022): 1, y(2024): 2])
        XCTAssertEqual(facets.availableCaptureDates.count, 3)
        XCTAssertEqual(facets.unknownDateCount, 1)
        XCTAssertEqual(items.map(\.captureYear), [y(2024), y(2024), y(2022), nil])

        let store = store(items)
        XCTAssertEqual(store.availableCaptureYears, [y(2022), y(2024)])
        XCTAssertEqual(store.captureYearCounts, [y(2022): 1, y(2024): 2])
        XCTAssertEqual(store.unknownDateCount, 1)
        store.items = []
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(store.availableCaptureYears, [])
        XCTAssertEqual(store.captureYearCounts, [:])
    }

    func testYearModeHidesUncheckedYearsAndUnknownDates() throws {
        let store = store(try fixture())
        edit(store) {
            $0.dateMode = .specificYears
            $0.excludedYears = [y(2022)]
        }
        XCTAssertTrue(store.filter.dateEnabled)
        XCTAssertEqual(visibleIDs(store), ["A", "B", "UNKNOWN"])

        edit(store) { $0.excludesUnknownYear = true }
        XCTAssertEqual(visibleIDs(store), ["A", "B"])

        // Day exclusions belong to Date mode and cannot narrow Year mode.
        edit(store) { $0.excludedDates = Set(store.availableCaptureDates) }
        XCTAssertEqual(visibleIDs(store), ["A", "B"])
    }

    func testYearEffectIgnoresAnUnknownChoiceWithoutUndatedItems() throws {
        let store = store(Array(try fixture().dropLast()))
        XCTAssertEqual(store.unknownDateCount, 0)
        var filter = store.filter
        filter.dateMode = .specificYears
        filter.excludesUnknownYear = true
        XCTAssertFalse(store.dateFilterHasEffect(filter))
        filter.excludedYears = [y(2024)]
        XCTAssertTrue(store.dateFilterHasEffect(filter))
        filter.dateMode = .range
        XCTAssertFalse(store.dateFilterHasEffect(filter), "Range mode ignores retained year choices")
    }

    func testRetainedYearChoicesKeepResetAvailable() throws {
        let store = store(try fixture())
        XCTAssertFalse(store.filterCanReset)
        edit(store) { $0.dateMode = .specificYears }
        XCTAssertFalse(store.filter.isActive)
        XCTAssertTrue(store.filterCanReset, "A non-default mode is resettable")

        edit(store) {
            $0.excludedYears = [y(2022)]
            $0.dateMode = .range
        }
        XCTAssertFalse(store.filter.isActive, "Hidden year choices do not narrow Range mode")
        XCTAssertTrue(store.filterCanReset)

        edit(store) {
            $0.excludedYears = []
            $0.excludesUnknownYear = true
        }
        XCTAssertTrue(store.filterCanReset)
    }

    func testModeSwitchesKeepEachModesChoices() throws {
        let store = store(try fixture())
        let range = try XCTUnwrap(store.captureDateRange)
        let laterDay = try XCTUnwrap(store.availableCaptureDates.last)
        edit(store) {
            $0.dateFrom = laterDay
            $0.dateTo = range.upperBound
        }
        XCTAssertEqual(visibleIDs(store), ["B"])
        edit(store) {
            $0.dateMode = .specificYears
            $0.excludedYears = [y(2024)]
        }
        XCTAssertEqual(visibleIDs(store), ["C", "UNKNOWN"])
        edit(store) {
            $0.dateMode = .specificDates
            $0.excludedDates = [laterDay]
            $0.excludesUnknownDate = true
        }
        XCTAssertEqual(visibleIDs(store), ["A", "C"])

        edit(store) { $0.dateMode = .specificYears }
        XCTAssertEqual(visibleIDs(store), ["C", "UNKNOWN"])
        edit(store) { $0.dateMode = .range }
        XCTAssertEqual(visibleIDs(store), ["B"])
        XCTAssertEqual(store.filter.excludedYears, [y(2024)])
        XCTAssertEqual(store.filter.excludedDates, [laterDay])
        XCTAssertTrue(store.filter.excludesUnknownDate)
        XCTAssertFalse(store.filter.excludesUnknownYear)
    }

    func testStructuralSyncDropsVanishedYearsAndResetClearsYears() throws {
        let items = try fixture()
        let store = store(items)
        edit(store) {
            $0.dateMode = .specificYears
            $0.excludedYears = [y(2022), y(2024)]
            $0.excludesUnknownYear = true
        }
        XCTAssertEqual(visibleIDs(store), [])
        try trash("C", from: store)
        XCTAssertEqual(store.availableCaptureYears, [y(2024)])
        XCTAssertEqual(store.filter.excludedYears, [y(2024)], "The vanished 2022 exclusion is dropped")
        XCTAssertTrue(store.filter.dateEnabled)

        store.resetFilter()
        XCTAssertEqual(store.filter.dateMode, .range)
        XCTAssertEqual(store.filter.excludedYears, [])
        XCTAssertFalse(store.filter.excludesUnknownYear)
        XCTAssertFalse(store.filterCanReset)
        XCTAssertEqual(visibleIDs(store), ["A", "B", "UNKNOWN"])
    }

    func testRangeNarrowedInAnotherModeSurvivesStructuralRefresh() throws {
        let store = store(try fixture())
        let a = try XCTUnwrap(store.items.first { $0.id == "A" }?.captureDay)
        let range = try XCTUnwrap(store.captureDateRange)
        edit(store) { $0.dateFrom = a }
        XCTAssertEqual(visibleIDs(store), ["A", "B"])
        edit(store) { $0.dateMode = .specificYears }
        XCTAssertTrue(store.filter.dateRangeIsNarrowed)
        XCTAssertFalse(store.filter.dateEnabled)

        try trash("B", from: store)
        let refreshed = try XCTUnwrap(store.captureDateRange)
        XCTAssertLessThan(refreshed.upperBound, range.upperBound)
        XCTAssertEqual(store.filter.dateFrom, a)
        XCTAssertEqual(store.filter.dateTo, refreshed.upperBound, "The retained end is clamped, not reset")
        edit(store) { $0.dateMode = .range }
        XCTAssertEqual(visibleIDs(store), ["A"])
    }

    func testRangeModeRefreshStillClampsNarrowedAndExpandsUntouchedBounds() throws {
        let narrowed = store(try fixture())
        let a = try XCTUnwrap(narrowed.items.first { $0.id == "A" }?.captureDay)
        edit(narrowed) { $0.dateFrom = a }
        try trash("B", from: narrowed)
        XCTAssertEqual(narrowed.filter.dateFrom, a)
        XCTAssertEqual(narrowed.filter.dateTo, narrowed.captureDateRange?.upperBound)
        XCTAssertTrue(narrowed.filter.dateEnabled)
        XCTAssertEqual(visibleIDs(narrowed), ["A"])

        for mode in [DateFilterMode.range, .specificYears] {
            let untouched = store(try fixture())
            edit(untouched) { $0.dateMode = mode }
            try trash("C", from: untouched)
            let refreshed = try XCTUnwrap(untouched.captureDateRange)
            XCTAssertEqual(untouched.filter.dateFrom, refreshed.lowerBound, "\(mode)")
            XCTAssertEqual(untouched.filter.dateTo, refreshed.upperBound, "\(mode)")
            XCTAssertFalse(untouched.filter.dateRangeIsNarrowed, "\(mode)")
            XCTAssertFalse(untouched.filter.dateEnabled, "\(mode)")
        }
    }

    func testJapaneseErasKeepRepeatedEraYearsSeparate() throws {
        let japanese = calendar(.japanese)
        let heisei6 = try utc(1994, 6, 15)
        let reiwa6 = try utc(2024, 6, 15)
        let heisei31 = try utc(2019, 2, 1)
        let reiwa1 = try utc(2019, 6, 1)
        let years = [heisei6, reiwa6, heisei31, reiwa1].map { CaptureYear($0, calendar: japanese) }
        XCTAssertEqual(years.map(\.year), [6, 6, 31, 1])
        XCTAssertNotEqual(years[0], years[1])
        XCTAssertNotEqual(years[2], years[3])
        XCTAssertEqual(years.sorted(), [years[0], years[2], years[3], years[1]], "Chronological order")
        for (year, date) in zip(years, [heisei6, reiwa6, heisei31, reiwa1]) {
            let representative = try XCTUnwrap(year.representativeDate(in: japanese))
            XCTAssertEqual(CaptureYear(representative, calendar: japanese), year)
            XCTAssertEqual(japanese.component(.era, from: representative), japanese.component(.era, from: date))
        }

        let locale = Locale(identifier: "en_US")
        let labels = years.map { AppDateFormat.year($0, calendar: japanese, locale: locale) }
        XCTAssertEqual(Set(labels).count, 4, "Era-aware labels: \(labels)")
        XCTAssertTrue(labels[0].contains("Heisei") && labels[1].contains("Reiwa"), "\(labels)")

        // The facet list and predicate treat them as two years.
        func item(_ id: String, _ date: Date) -> PhotoItem {
            PhotoItem(primaryFile: PhotoFile(
                id: id, url: URL(fileURLWithPath: "/tmp/era-\(id).JPG"), captureDate: date,
                cameraModel: nil, lensModel: nil, fileSize: 1, calendar: japanese))
        }
        let items = [item("H6", heisei6), item("R6", reiwa6)]
        let facets = SessionOpeningFacets(items: items)
        XCTAssertEqual(facets.availableCaptureYears, [years[0], years[1]])
        XCTAssertEqual(facets.captureYearCounts, [years[0]: 1, years[1]: 1])
        var filter = PhotoFilter()
        filter.dateEnabled = true
        filter.dateMode = .specificYears
        filter.excludedYears = [years[0]]
        let prepared = PreparedPhotoFilter(filter, calendar: japanese)
        XCTAssertEqual(items.filter(prepared.matches).map(\.id), ["R6"])
    }

    func testCyclicCalendarYearLabelsStayDistinctSixtyYearsApart() throws {
        var identifiers = [Calendar.Identifier.chinese]
        if #available(macOS 26.0, *) { identifiers.append(.dangi) }
        for identifier in identifiers {
            let cyclic = calendar(identifier)
            let years = try [1964, 2024].map { CaptureYear(try utc($0, 6, 15), calendar: cyclic) }
            XCTAssertEqual(years[0].year, years[1].year, "Same cyclic year number")
            XCTAssertNotEqual(years[0], years[1])
            for localeID in ["en_US", "zh_Hans_CN"] {
                let labels = years.map { AppDateFormat.year($0, calendar: cyclic, locale: Locale(identifier: localeID)) }
                XCTAssertNotEqual(labels[0], labels[1], "\(identifier) \(localeID): \(labels)")
                XCTAssertTrue(labels[0].contains("1964") && labels[1].contains("2024"), "\(labels)")
            }
        }
    }

    func testGregorianYearLabelsAreWholeYearsWithoutEra() throws {
        let gregorian = calendar(.gregorian)
        let locale = Locale(identifier: "en_US")
        for year in [1999, 2024] {
            let key = CaptureYear(try utc(year, 6, 15), calendar: gregorian)
            XCTAssertEqual(AppDateFormat.year(key, calendar: gregorian, locale: locale), String(year),
                           "Short date styles cannot shorten the year list to two digits")
        }
        // The cached label follows the Mac's calendar and digits.
        let current = AppDateFormat.year(y(2024)).compactMap(\.wholeNumberValue)
        XCTAssertFalse(current.isEmpty)
    }

    // MARK: - Popover layout

    /// The popover is 340 points wide with 14-point margins.
    private let columnWidth: CGFloat = 312

    func testModePickerSpansTheColumnWithEqualSegmentsInBothDirections() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("Flexible segmented sizing requires macOS 26; earlier systems keep the intrinsic width.")
        }
        let store = store(try fixture())
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for mode in [DateFilterMode.range, .specificYears, .specificDates] {
                edit(store) { $0.dateMode = mode }
                let host = NSHostingView(rootView: FilterDateSection(store: store, isExpanded: .constant(true))
                    .frame(width: columnWidth)
                    .padding(14)
                    .background(Color.appBackground)
                    .environment(\.layoutDirection, direction)
                    .preferredColorScheme(.dark))
                let window = mount(host)
                defer { window.close() }
                let controls = descendants(host).compactMap { $0 as? NSSegmentedControl }
                XCTAssertEqual(controls.count, 1)
                let control = try XCTUnwrap(controls.first)
                XCTAssertEqual(control.segmentCount, 3)
                let frame = control.convert(control.bounds, to: host)
                XCTAssertEqual(frame.width, columnWidth, accuracy: 2, "\(direction), \(mode)")
                XCTAssertEqual(frame.minX, 14, accuracy: 2, "\(direction), \(mode)")
                XCTAssertEqual(control.segmentDistribution, .fillEqually, "\(direction), \(mode)")
                XCTAssertEqual((0..<3).map(control.width(forSegment:)), [0, 0, 0],
                               "No fixed segment width overrides equal distribution")
                if direction == .leftToRight {
                    XCTAssertEqual(control.selectedSegment,
                                   [DateFilterMode.range, .specificYears, .specificDates].firstIndex(of: mode))
                    try snapshot(host, name: "date-filter-\(mode)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func fixture() throws -> [PhotoItem] {
        let calendar = Calendar.current
        func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }
        func item(_ id: String, _ date: Date?) -> PhotoItem {
            PhotoItem(id: id, primaryURL: URL(fileURLWithPath: "/tmp/date-year-\(id).JPG"),
                      pairedURL: nil, captureDate: date, cameraModel: nil,
                      lensModel: nil, fileSize: 1)
        }
        return [
            item("A", try date(2024, 3, 1)),
            item("B", try date(2024, 9, 14)),
            item("C", try date(2022, 6, 30)),
            item("UNKNOWN", nil),
        ]
    }

    private func store(_ items: [PhotoItem]) -> SessionStore {
        let store = SessionStore()
        store.items = items
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.resetFilter()
        return store
    }

    /// Mirrors FilterDateSection: one assignment with recomputed date flags.
    private func edit(_ store: SessionStore, _ change: (inout PhotoFilter) -> Void) {
        var filter = store.filter
        change(&filter)
        store.normalizeDateFilter(&filter)
        store.filter = filter
    }

    /// A completed Clean Up: the structural refresh that resynchronizes filters.
    private func trash(_ id: String, from store: SessionStore) throws {
        let index = try XCTUnwrap(store.items.firstIndex { $0.id == id })
        let url = store.items[index].primaryURL
        store.finishCleanUpForTesting(
            TrashBatchResult(
                succeeded: [TrashedPhotoSnapshot(
                    index: index, item: store.items[index],
                    files: [TrashedFile(original: url, trash: url, identity: nil)]
                )],
                stalePhotos: [], failedPhotos: 0, inconsistentPhotos: 0,
                journalFailure: false, requiresRecovery: false
            ),
            mode: .selection,
            preparedSurvivors: []
        )
    }

    /// The fixture's year in the Mac's calendar, matching `PhotoFile`.
    private func y(_ year: Int) -> CaptureYear {
        let calendar = Calendar.current
        return CaptureYear(calendar.date(from: DateComponents(year: year, month: 6, day: 15, hour: 12))!,
                           calendar: calendar)
    }

    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try XCTUnwrap(calendar(.gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    private func visibleIDs(_ store: SessionStore) -> [String] {
        store.visibleIndices.map { store.items[$0].id }.sorted()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func mount<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_SETTINGS_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
#endif
