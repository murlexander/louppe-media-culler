import Combine
import Foundation
import XCTest
@testable import Louppe

@MainActor
final class LouppeSpeedSessionTests: XCTestCase {
    func testReviewHotPathsAndCoverage() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "session-review")
        for count in SpeedBenchmark.sizes {
            let defaultsName = "LouppeSpeedSession.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
            defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
            let store = SessionStore(reviewDefaults: defaults)
            store.items = (0..<count).map { i in
                let name = String(format: "FRAME_%06d.JPG", i)
                return PhotoItem(primaryFile: PhotoFile(
                    id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-speed-synthetic/\(name)"),
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                    cameraModel: "Camera \(i % 25)", lensModel: "Lens \(i % 4)",
                    shutterSpeed: 0.001, iso: i.isMultiple(of: 2) ? 6_400 : 100,
                    fileSize: 1, rating: i.isMultiple(of: 3) ? .yes : .undecided
                ))
            }
            store.rebuildDerivedDataForTesting()
            store.phase = .ready
            store.pauseQualityCueAnalysis()
            XCTAssertEqual(store.visibleIndices.count, count)
            var publishes = 0
            let subscription = store.objectWillChange.sink { _ in publishes += 1 }
            try report.measure(name: "review.rating.default-sort", count: count) {
                store.toggleRating(at: count / 2)
            }
            XCTAssertGreaterThan(publishes, 0)
            XCTAssertLessThanOrEqual(publishes, (SpeedBenchmark.repetitions + 1) * 6)
            subscription.cancel()
            XCTAssertEqual(store.yesCount + store.noCount + store.undecidedCount, count)

            store.sort = PhotoSort(key: .decision, ascending: true)
            try report.measure(name: "review.rating.decision-sort", count: count) {
                store.toggleRating(at: count / 2)
            }
            XCTAssertEqual(Set(store.visibleIndices).count, count)
            XCTAssertEqual(store.visibleIndices, store.visibleIndices.sorted {
                store.sort.areInOrder(store.items[$0], store.items[$1])
            })

            store.sort = PhotoSort(key: .starRating, ascending: false)
            var star: StarRating = .one
            try report.measure(name: "review.stars.star-sort", count: count) {
                star = star == .one ? .five : .one
                store.setStarRating(star, at: count / 2)
            }
            XCTAssertEqual(store.items[count / 2].starRatingState, .stars(star))
            XCTAssertEqual(Set(store.visibleIndices).count, count)

            store.sort = PhotoSort()
            var index = PreparedSessionIndex()
            index.rebuildItems(store.items, sort: PhotoSort())
            var filter = PhotoFilter()
            filter.excludedDecisionStates = [.no]
            try report.measure(name: "filter.decision.projection-and-groups", count: count) {
                index.applyFilter(filter, to: store.items, sort: PhotoSort(), isGroupingEnabled: true)
            }
            XCTAssertEqual(index.visibleIndices.count, count - store.noCount)
            XCTAssertEqual(index.visibleLocations.count, index.visibleIndices.count)

            store.setSelection([0, count / 2, count - 1])
            let selectedIDs = Set(store.selectedIndices.map { store.items[$0].id })
            try report.measure(name: "sort-menu.camera.full-store", count: count, prepare: {
                store.sort = PhotoSort(key: .camera, ascending: false)
            }) {
                store.sort = PhotoSort(key: .camera, ascending: true)
            }
            XCTAssertEqual(Set(store.selectedIndices.map { store.items[$0].id }), selectedIDs)
            let expectedOrder = store.visibleIndices
            try report.measure(name: "sort-menu.camera.prepared-only-hypothesis", count: count) {
                let sort = PhotoSort(key: .camera, ascending: true)
                index.rebuildSort(store.items, sort: sort)
                index.applyFilter(PhotoFilter(), to: store.items, sort: sort, isGroupingEnabled: true)
            }
            // Diagnostic lower bound: this also omits observable publications
            // and selection reconciliation, so the delta is not solely maps.
            var reference = PreparedSessionIndex()
            reference.rebuildItems(store.items, sort: PhotoSort(key: .camera, ascending: true))
            reference.applyFilter(PhotoFilter(), to: store.items,
                                  sort: PhotoSort(key: .camera, ascending: true), isGroupingEnabled: true)
            XCTAssertEqual(index.visibleIndices, reference.visibleIndices)
            XCTAssertEqual(index.visibleIndices, expectedOrder)
            XCTAssertEqual(Set(expectedOrder), Set(index.visibleIndices))
            store.clearSelection()
            store.sort = PhotoSort()

            var text = ""
            try report.measure(name: "quality.coverage.unmeasured-read", count: count) {
                text = store.qualityCueCoverageSummary
            }
            XCTAssertFalse(text.isEmpty)
            var highISO = false
            try report.measure(name: "filter.quality.switch-metadata-cue", count: count) {
                highISO.toggle()
                store.filter.selectedQualityCues = highISO ? [.highISO] : [.slowShutter]
            }
            XCTAssertEqual(store.visibleIndices.count, highISO ? (count + 1) / 2 : 0)
            XCTAssertEqual(store.items.count, count)
            store.filter.selectedQualityCues = []
            var current = 0
            try report.measure(name: "navigation.100-steps", count: count) {
                for _ in 0..<100 { store.goNext() }
                current = store.currentIndex
            }
            XCTAssertTrue(store.items.indices.contains(current))
            store.beginTerminationPreparation()
        }
        try report.finish()
    }
}
