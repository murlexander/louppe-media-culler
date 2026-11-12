import XCTest
@testable import Louppe

@MainActor
final class SessionMetadataFilterTimingTests: XCTestCase {
    func testStarsUsePendingSearchResultsInsteadOfHiddenCurrentPhoto() async throws {
        try await checkPendingSearch { $0.setStarRating(.four) }
    }

    func testColorUsesPendingSearchResultsInsteadOfHiddenSelection() async throws {
        try await checkPendingSearch(selectAll: true, dimension: .color) { $0.setColorLabel(.red) }
    }

    func testStarsWithPendingZeroMatchSearchLeaveFilesUntouched() async throws {
        try await checkPendingSearch(matches: false) { $0.setStarRating(.four) }
    }

    func testColorWithPendingZeroMatchSearchLeavesSelectionUntouched() async throws {
        try await checkPendingSearch(selectAll: true, matches: false, dimension: .color) { $0.setColorLabel(.red) }
    }

    func testTileStarsUsePendingSearchBeforeResolvingBatchSelection() async throws {
        try await checkPendingSearch(selectAll: true) { store in
            store.setStarRating(.four, at: store.items.firstIndex { $0.id == "B.png" }!)
        }
    }

    func testTileColorUsesPendingSearchBeforeResolvingBatchSelection() async throws {
        try await checkPendingSearch(selectAll: true, dimension: .color) { store in
            store.setColorLabel(.red, at: store.items.firstIndex { $0.id == "B.png" }!)
        }
    }

    func testTileDecisionUsesPendingSearchBeforeResolvingBatchSelection() async throws {
        try await checkPendingSearch(selectAll: true, dimension: .decision) { store in
            store.rate(.yes, at: store.items.firstIndex { $0.id == "B.png" }!)
        }
    }

    func testTileDecisionCycleUsesPendingSearchBeforeResolvingBatchSelection() async throws {
        try await checkPendingSearch(selectAll: true, dimension: .decision) { store in
            store.toggleRating(at: store.items.firstIndex { $0.id == "B.png" }!)
        }
    }

    private enum Dimension { case decision, stars, color }

    private func checkPendingSearch(
        selectAll: Bool = false, matches: Bool = true, dimension: Dimension = .stars,
        edit: (SessionStore) -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-MetadataTiming-\(UUID())")
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        for name in ["A.png", "B.png"] { try bytes.write(to: media.appendingPathComponent(name)) }
        let suite = "SessionMetadataFilterTiming.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            saveTrailingDelay: 60, saveMaximumDelay: 60,
            operationJournalDirectory: root.appendingPathComponent("Operations"), reviewDefaults: defaults)
        defer {
            store.beginTerminationPreparation()
            defaults.removePersistentDomain(forName: suite)
        }
        store.openFolder(media)
        let deadline = ContinuousClock.now + .seconds(15)
        while store.isSessionTransitioning || store.items.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready = store.phase else { return XCTFail("Opening failed: \(store.scanError ?? "timeout")") }
        let a = try XCTUnwrap(store.items.firstIndex { $0.id == "A.png" })
        let b = try XCTUnwrap(store.items.firstIndex { $0.id == "B.png" })
        store.setIndex(a)
        if selectAll { store.selectAllVisible() }
        store.filter.searchText = matches ? "B.png" : "absent"
        // Stay in the same actor turn: the 150 ms search debounce has not fired.
        edit(store)
        XCTAssertEqual(store.visibleIndices, matches ? [b] : [], "The edit must first commit the search currently on screen")
        XCTAssertEqual(store.items[a].starRatingState, .unrated, "Hidden files must stay untouched")
        XCTAssertEqual(store.items[a].colorLabelState, .none, "Hidden files must stay untouched")
        XCTAssertEqual(store.items[a].ratingState, .undecided, "Hidden files must stay untouched")
        if !matches {
            XCTAssertEqual(store.items[b].colorLabelState, .none)
            XCTAssertEqual(store.items[b].starRatingState, .unrated)
            XCTAssertFalse(store.canUndo, "A search with no matches must not create a metadata edit")
        } else {
            switch dimension {
            case .decision: XCTAssertEqual(store.items[b].ratingState, .yes)
            case .stars: XCTAssertEqual(store.items[b].starRatingState, .stars(.four))
            case .color: XCTAssertEqual(store.items[b].colorLabelState, .label(.red))
            }
        }
        assertCleanUpAvailabilityMatchesFresh(store)
        store.undo()
        XCTAssertTrue(store.items.allSatisfy {
            $0.ratingState == .undecided && $0.starRatingState == .unrated && $0.colorLabelState == .none
        })
        assertCleanUpAvailabilityMatchesFresh(store)
        _ = await store.saveSessionForTermination()
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        for name in ["A.png", "B.png"] {
            XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(name)), bytes)
        }
    }
}
