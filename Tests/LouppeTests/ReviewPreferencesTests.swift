import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ReviewPreferencesTests: XCTestCase {
    func testDefaultsAndEachSortKeyRoundTripInAnIsolatedSuite() {
        let defaults = makeDefaults()
        XCTAssertEqual(ReviewPreferences.load(from: defaults), ReviewPreferences())
        for key in PhotoSort.Key.allCases {
            let expected = ReviewPreferences(
                advancesAfterDecision: false,
                defaultSort: PhotoSort(key: key, ascending: false),
                isGroupingEnabled: false,
                defaultView: .grid
            )
            expected.save(to: defaults)
            XCTAssertEqual(ReviewPreferences.load(from: defaults), expected)
        }
        XCTAssertEqual(ReviewPreferences.load(from: makeDefaults()), ReviewPreferences())
    }

    func testMalformedPreferencesFallBackWithoutMutatingTheStoredValues() {
        let defaults = makeDefaults()
        defaults.set("unknown-future-sort", forKey: ReviewPreferences.Keys.defaultSortKey)
        defaults.set("unknown-future-view", forKey: ReviewPreferences.Keys.defaultView)
        defaults.set("invalid", forKey: ReviewPreferences.Keys.advancesAfterDecision)
        defaults.set("invalid", forKey: ReviewPreferences.Keys.defaultSortAscending)
        defaults.set("invalid", forKey: ReviewPreferences.Keys.isGroupingEnabled)
        XCTAssertEqual(ReviewPreferences.load(from: defaults), ReviewPreferences())
        XCTAssertEqual(defaults.string(forKey: ReviewPreferences.Keys.defaultView), "unknown-future-view")
    }

    func testDefaultAdvancementStepsToTheNextItemWhateverItsDecisionAndNeverWraps() {
        let store = readyStore(decisions: [.undecided, .yes, .undecided, .no])
        store.rate(.yes)
        XCTAssertEqual(store.currentIndex, 1, "the next item, even though it is already Yes")
        store.setIndex(3)
        store.rate(.yes)
        XCTAssertEqual(store.currentIndex, 3, "the last item stays; an earlier Unmarked item is not a target")
        XCTAssertEqual(store.items[3].rating, .yes)
        XCTAssertEqual(store.items[2].rating, .undecided)
    }

    func testLastDecisionStaysAtLastItemAndUndoRestoresIt() {
        let store = readyStore(decisions: [.yes, .no, .undecided])
        store.setIndex(2)
        store.rate(.yes)
        XCTAssertEqual(store.currentIndex, 2)
        store.undo()
        XCTAssertEqual(store.items[2].rating, .undecided)
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testAdvancementOffKeepsSingleItemAndRespondsToLivePreferenceChanges() {
        let defaults = makeDefaults()
        let store = readyStore(defaults: defaults)
        ReviewPreferences(advancesAfterDecision: false).save(to: defaults)
        let view = SessionView(store: store)
        XCTAssertTrue(view.handleKey(key("f", code: 3)))
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.items[0].rating, .yes)
        ReviewPreferences().save(to: defaults)
        XCTAssertTrue(view.handleKey(key("d", code: 2)))
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.items[0].rating, .no)
    }

    func testAdvancementOffPreservesMultiSelectionAndOneUndoRestoresBatch() {
        let defaults = makeDefaults()
        ReviewPreferences(advancesAfterDecision: false).save(to: defaults)
        let store = readyStore(defaults: defaults)
        store.selectRange(to: 1)
        store.rate(.yes)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.selectedIndices, [0, 1])
        XCTAssertEqual(store.items.map(\.rating), [.yes, .yes, .undecided])
        store.undo()
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .undecided])
    }

    func testAdvancementOnRatesBatchAndCollapsesSelectionToTheItemAfterIt() {
        let store = readyStore()
        store.selectRange(to: 1)
        store.rate(.no)
        XCTAssertEqual(store.currentIndex, 2, "the first item after the batch in display order")
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(store.items.map(\.rating), [.no, .no, .undecided])
        store.undo()
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .undecided])
    }

    func testUnmarkedFilterDoesNotSkipTheNextItemInEitherDirection() {
        for ascending in [true, false] {
            let store = readyStore()
            store.sort = PhotoSort(key: .name, ascending: ascending)
            store.filter.excludedDecisionStates = [.yes, .no]
            store.setIndex(ascending ? 0 : 2)
            store.rate(.yes)
            XCTAssertEqual(store.currentIndex, 1)
            XCTAssertEqual(store.visibleIndices.count, 2)
            store.rate(.no)
            XCTAssertEqual(store.currentIndex, ascending ? 2 : 0)
            store.rate(.yes)
            XCTAssertTrue(store.visibleIndices.isEmpty)
            let ratings = store.items.map(\.rating)
            store.rate(.no)
            XCTAssertEqual(store.items.map(\.rating), ratings, "empty review cannot rate hidden media")
        }
    }

    func testAdvancementOffFilterRemovalKeepsNearestItemInDisplayedOrder() {
        let defaults = makeDefaults()
        ReviewPreferences(advancesAfterDecision: false).save(to: defaults)
        let store = readyStore(defaults: defaults)
        store.sort = PhotoSort(key: .name, ascending: false)
        store.filter.excludedDecisionStates = [.yes, .no]
        store.setIndex(2)
        store.rate(.yes)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.effectiveSelection, [1])
        store.selectRange(to: 0)
        store.rate(.no)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testDecisionSortAdvancesFromTheOrderBeforeTheDecision() {
        let store = readyStore(decisions: [.undecided, .undecided, .no, .undecided])
        store.sort = PhotoSort(key: .decision, ascending: false)
        store.setIndex(0)
        store.rate(.no)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.items[0].rating, .no)
    }

    func testPointerAndAccessibleTileDecisionsNeverAdvanceAndStarsStayIndependent() {
        let store = readyStore()
        store.toggleRating(at: 0)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.items[0].rating, .yes)
        store.rate(.no, at: 0)
        XCTAssertEqual(store.currentIndex, 0)
        store.setStarRating(.five)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.items[0].rating, .no)
        XCTAssertEqual(store.items[0].starRatingState, .stars(.five))
    }

    func testPendingSearchIsAppliedBeforeReviewDecision() {
        let store = readyStore()
        store.filter.searchText = "C.JPG"
        store.rate(.yes)
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .yes])
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testNewFolderAndCloseUseDefaultsWhileRescanPreservesCurrentLayout() async throws {
        let defaults = makeDefaults()
        let initial = ReviewPreferences(
            defaultSort: PhotoSort(key: .name, ascending: false),
            isGroupingEnabled: false,
            defaultView: .grid
        )
        initial.save(to: defaults)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Review preference fixture".utf8).write(to: folder.appendingPathComponent("A.txt"))
        }
        try Data("Second document".utf8).write(to: first.appendingPathComponent("B.txt"))
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backup")),
            reviewDefaults: defaults
        )
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertEqual(store.sort, initial.defaultSort)
        XCTAssertFalse(store.isGroupingEnabled)
        store.openFolder(first)
        try await waitForReady(store, folder: first, count: 2)
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertEqual(store.sort, initial.defaultSort)
        XCTAssertEqual(store.currentItem?.displayName, "B.txt")
        store.setIndex(try XCTUnwrap(store.items.firstIndex { $0.displayName == "A.txt" }))
        store.viewMode = .gallery
        store.sort = PhotoSort(key: .captureDate)
        store.isGroupingEnabled = true
        let changed = ReviewPreferences(
            defaultSort: PhotoSort(key: .folderHierarchy, ascending: false),
            isGroupingEnabled: false,
            defaultView: .grid
        )
        changed.save(to: defaults)
        try Data("Another document".utf8).write(to: first.appendingPathComponent("C.txt"))
        store.rescan()
        try await waitForReady(store, folder: first, count: 3)
        XCTAssertEqual(store.currentItem?.displayName, "A.txt")
        XCTAssertEqual(store.viewMode, .gallery)
        XCTAssertEqual(store.sort, PhotoSort())
        XCTAssertTrue(store.isGroupingEnabled)
        store.openFolder(second)
        try await waitForReady(store, folder: second, count: 1)
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertEqual(store.sort, changed.defaultSort)
        XCTAssertFalse(store.isGroupingEnabled)
        store.viewMode = .gallery
        store.closeSession()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .welcome = store.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .welcome = store.phase else { return XCTFail("close did not finish") }
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertEqual(store.sort, changed.defaultSort)
        XCTAssertFalse(store.isGroupingEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ReviewPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func readyStore(
        decisions: [Rating] = [.undecided, .undecided, .undecided],
        defaults: UserDefaults? = nil
    ) -> SessionStore {
        let store = SessionStore(reviewDefaults: defaults ?? makeDefaults())
        store.items = decisions.enumerated().map { index, rating in
            let name = "\(UnicodeScalar(65 + index)!).JPG"
            return PhotoItem(primaryFile: PhotoFile(
                id: name,
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                fileSize: 1,
                rating: rating
            ))
        }
        store.phase = .ready
        store.sort = PhotoSort(key: .name)
        store.rebuildDerivedDataForTesting()
        return store
    }

    private func key(_ character: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code
        )!
    }

    private func waitForReady(_ store: SessionStore, folder: URL, count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .ready = store.phase,
               !store.isSessionTransitioning,
               store.sourceFolder == folder,
               store.items.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("fixture did not finish opening: \(store.scanError ?? "no scan error")")
    }
}
