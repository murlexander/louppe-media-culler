import AppKit
import XCTest
@testable import Louppe

/// Item C: fixed Yes/No intents toggle, only new marks advance (to the next
/// item, never wrapping), and Clear Stars and Labels leaves decisions alone.
@MainActor
final class DecisionToggleTests: XCTestCase {
    func testResolutionClearsOnlyWhenEveryTargetHasTheRequestedDecision() {
        XCTAssertEqual(Rating.yes.resolvingDecisionToggle(for: [.yes]), .undecided)
        XCTAssertEqual(Rating.yes.resolvingDecisionToggle(for: [.yes, .yes]), .undecided)
        XCTAssertEqual(Rating.yes.resolvingDecisionToggle(for: [.yes, .no]), .yes)
        XCTAssertEqual(Rating.yes.resolvingDecisionToggle(for: [.yes, .undecided]), .yes)
        XCTAssertEqual(Rating.no.resolvingDecisionToggle(for: [.yes]), .no)
        XCTAssertEqual(Rating.no.resolvingDecisionToggle(for: [.no, .mixed]), .no)
        XCTAssertEqual(Rating.yes.resolvingDecisionToggle(for: [.mixed]), .yes, "a Mixed pair is marked")
        XCTAssertEqual(Rating.no.resolvingDecisionToggle(for: [PhotoItemRatingState]()), .no)
        XCTAssertEqual(Rating.undecided.resolvingDecisionToggle(for: [.undecided]), .undecided,
                       "an explicit clear stays a clear")
    }

    func testSecondSameKeyClearsWithoutAdvancingAndStampsTheClear() throws {
        let store = readyStore([.undecided, .undecided, .undecided])
        let view = SessionView(store: store)
        XCTAssertTrue(view.handleKey(key("f", code: 3)))
        XCTAssertEqual(store.currentIndex, 1)
        store.setIndex(0)
        let markedAt = try XCTUnwrap(store.items[0].primaryFile.ratedAt)
        XCTAssertTrue(view.handleKey(key("f", code: 3)))
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertEqual(store.currentIndex, 0, "a toggle-clear never advances")
        let clearedAt = try XCTUnwrap(store.items[0].primaryFile.ratedAt, "a deliberate clear is dated")
        XCTAssertGreaterThanOrEqual(clearedAt, markedAt)
        XCTAssertTrue(view.handleKey(key("d", code: 2)))
        XCTAssertEqual(store.items[0].rating, .no)
        XCTAssertEqual(store.currentIndex, 1)
        store.setIndex(0)
        XCTAssertTrue(view.handleKey(key("f", code: 3)))
        XCTAssertEqual(store.items[0].rating, .yes, "the contrary decision switches")
        XCTAssertEqual(store.currentIndex, 1)
    }

    func testMultiSelectionClearsOnlyWhenAllShareTheDecision() {
        let store = readyStore([.yes, .yes, .no, .undecided])
        store.selectRange(to: 1)
        store.rate(.yes)
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .no, .undecided])
        XCTAssertEqual(store.selectedIndices, [0, 1], "a clear keeps the selection")
        XCTAssertEqual(store.currentIndex, 0)
        store.setIndex(1)
        store.selectRange(to: 2)
        store.rate(.no)
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .no, .no, .undecided], "mixed targets are all marked")
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(store.currentIndex, 3, "the first item after the batch")
        store.undo()
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .no, .undecided])
    }

    func testMixedPairIsMarkedAndUndoRestoresPerFileValuesAndDates() throws {
        let earlier = Date(timeIntervalSince1970: 1_000), later = Date(timeIntervalSince1970: 2_000)
        let raw = file("PAIR.NEF", rating: .yes, ratedAt: earlier)
        let jpeg = file("PAIR.JPG", rating: .no, ratedAt: later)
        let store = readyStore([], extra: [PhotoItem(primaryFile: raw, pairedFile: jpeg)])
        XCTAssertEqual(store.items[0].ratingState, .mixed)
        store.rate(.yes)
        XCTAssertEqual(store.items[0].ratingState, .yes)
        store.rate(.yes)
        XCTAssertEqual(store.items[0].ratingState, .undecided)
        XCTAssertEqual(raw.ratedAt, jpeg.ratedAt, "one clear date for both files")
        store.undo()
        XCTAssertEqual(store.items[0].ratingState, .yes)
        store.undo()
        XCTAssertEqual(store.items[0].ratingState, .mixed)
        XCTAssertEqual(raw.ratedAt, earlier)
        XCTAssertEqual(jpeg.ratedAt, later)
    }

    func testAdvanceStopsAtTheEndInGalleryAndGridAcrossSortsAndNeverWraps() {
        for viewMode in [ViewMode.gallery, .grid] {
            for ascending in [true, false] {
                let store = readyStore([.undecided, .yes, .no, .undecided])
                store.viewMode = viewMode
                store.sort = PhotoSort(key: .name, ascending: ascending)
                let order = store.visibleIndices
                store.setIndex(order[0])
                store.rate(.no)
                XCTAssertEqual(store.currentIndex, order[1], "next item whatever its decision (\(viewMode), \(ascending))")
                store.setIndex(order[3])
                store.rate(.yes)
                XCTAssertEqual(store.currentIndex, order[3], "stays at the end (\(viewMode), \(ascending))")
            }
        }
    }

    func testBatchMarkAdvancesPastTheBatchInGalleryAndGrid() {
        for viewMode in [ViewMode.gallery, .grid] {
            // Shift-range with current at its start: lands after the batch.
            let range = readyStore(Array(repeating: .undecided, count: 10))
            range.viewMode = viewMode
            range.setIndex(3)
            range.selectRange(to: 7)
            range.rate(.yes)
            XCTAssertEqual(range.items[3...7].map(\.rating), Array(repeating: .yes, count: 5))
            XCTAssertEqual(range.currentIndex, 8, "\(viewMode)")
            XCTAssertTrue(range.selectedIndices.isEmpty)

            // A batch ending at the last item stays there; no wrap.
            let end = readyStore(Array(repeating: .undecided, count: 6))
            end.viewMode = viewMode
            end.setIndex(3)
            end.selectRange(to: 5)
            end.rate(.no)
            XCTAssertEqual(end.currentIndex, 5, "\(viewMode)")

            // The Unmarked filter hides the whole batch: next visible item after it.
            let filtered = readyStore(Array(repeating: .undecided, count: 8))
            filtered.viewMode = viewMode
            filtered.filter.excludedDecisionStates = [.yes, .no]
            filtered.setIndex(2)
            filtered.selectRange(to: 4)
            filtered.rate(.yes)
            XCTAssertEqual(filtered.visibleIndices, [0, 1, 5, 6, 7])
            XCTAssertEqual(filtered.currentIndex, 5, "\(viewMode)")
            // Nothing after a hidden end batch: closest surviving predecessor.
            filtered.setIndex(6)
            filtered.selectRange(to: 7)
            filtered.rate(.no)
            XCTAssertEqual(filtered.visibleIndices, [0, 1, 5])
            XCTAssertEqual(filtered.currentIndex, 5, "\(viewMode)")

            // Rubber band with current before the batch: after the batch.
            let before = readyStore(Array(repeating: .undecided, count: 10))
            before.viewMode = viewMode
            before.setIndex(1)
            before.setSelection([4, 5, 6])
            before.rate(.yes)
            XCTAssertEqual(before.items.map(\.rating).filter { $0 == .yes }.count, 3)
            XCTAssertEqual(before.items[1].rating, .undecided)
            XCTAssertEqual(before.currentIndex, 7, "\(viewMode)")

            // Rubber band with current after the batch: only marked targets
            // anchor, so the advance follows the batch, not the current item.
            let after = readyStore(Array(repeating: .undecided, count: 10))
            after.viewMode = viewMode
            after.setIndex(8)
            after.setSelection([2, 3, 4])
            after.rate(.no)
            XCTAssertEqual(after.items[2...4].map(\.rating), [.no, .no, .no])
            XCTAssertEqual(after.items[8].rating, .undecided)
            XCTAssertEqual(after.currentIndex, 5, "\(viewMode)")

            // A one-item selection away from the current item is a batch too:
            // the advance leaves it rather than following the current item.
            let single = readyStore(Array(repeating: .undecided, count: 10))
            single.viewMode = viewMode
            single.setIndex(1)
            single.setSelection([5])
            single.rate(.yes)
            XCTAssertEqual(single.items.indices.filter { single.items[$0].rating == .yes }, [5])
            XCTAssertEqual(single.currentIndex, 6, "\(viewMode)")
            // Selecting only the current item still anchors on it.
            single.setIndex(7)
            single.setSelection([7])
            single.rate(.no)
            XCTAssertEqual(single.items[7].rating, .no)
            XCTAssertEqual(single.currentIndex, 8, "\(viewMode)")
            // A one-item selection before the current item: after the target.
            single.setIndex(8)
            single.setSelection([2])
            single.rate(.no)
            XCTAssertEqual(single.items[2].rating, .no)
            XCTAssertEqual(single.items[8].rating, .undecided)
            XCTAssertEqual(single.currentIndex, 3, "\(viewMode)")
        }
    }

    func testDecisionSortAndUnmarkedFilterUseThePreEditOrder() {
        let store = readyStore([.undecided, .undecided, .undecided, .undecided])
        store.sort = PhotoSort(key: .decision, ascending: true)
        let order = store.visibleIndices
        store.setIndex(order[1])
        store.rate(.yes)
        XCTAssertEqual(store.currentIndex, order[2], "the marked item moved, the next one did not")

        // The Unmarked view hides each mark; the last one falls back to the
        // closest surviving predecessor instead of wrapping.
        let filtered = readyStore([.undecided, .undecided, .undecided])
        filtered.filter.excludedDecisionStates = [.yes, .no]
        filtered.setIndex(2)
        filtered.rate(.yes)
        XCTAssertEqual(filtered.currentIndex, 1)
        XCTAssertEqual(filtered.visibleIndices, [0, 1])
        // A clear in the Yes view hides the item; nothing advances.
        let yesView = readyStore([.yes, .yes, .yes])
        yesView.filter.excludedDecisionStates = [.no, .undecided]
        yesView.setIndex(1)
        yesView.rate(.yes)
        XCTAssertEqual(yesView.visibleIndices, [0, 2])
        XCTAssertEqual(yesView.currentIndex, 2, "the nearest surviving item in the old order")
    }

    func testTileAndPaletteIntentsToggleWhileTheBadgeStillCycles() throws {
        let store = readyStore([.undecided, .undecided])
        store.rate(.yes, at: 1)
        XCTAssertEqual(store.items[1].rating, .yes)
        store.rate(.yes, at: 1)
        XCTAssertEqual(store.items[1].rating, .undecided, "context menu and VoiceOver Yes toggle")
        XCTAssertEqual(store.currentIndex, 1)
        store.rate(.undecided, at: 1)
        XCTAssertEqual(store.items[1].rating, .undecided, "Clear Decision stays a clear")
        for expected in [Rating.yes, .no, .undecided] {
            store.toggleRating(at: 0)
            XCTAssertEqual(store.items[0].rating, expected, "Info/Grid badge cycles")
        }
        let palette = ActionPaletteView(store: store)
        let markYes = try XCTUnwrap(palette.actions.first { $0.id == "mark-yes" })
        store.setIndex(0)
        markYes.perform()
        XCTAssertEqual(store.items[0].rating, .yes)
        store.setIndex(0)
        markYes.perform()
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertFalse(try XCTUnwrap(palette.actions.first { $0.id == "mark-no" }).keywords
            .contains(L10n.text("no decision")), "the ambiguous synonym is gone")
    }

    func testClearStarsAndLabelsKeepsDecisionsAndOneUndoRestoresBothFieldsWithDates() throws {
        let starsAt = Date(timeIntervalSince1970: 3_000), colorAt = Date(timeIntervalSince1970: 4_000)
        let ratedAt = Date(timeIntervalSince1970: 5_000)
        let raw = file("PAIR.NEF", rating: .yes, ratedAt: ratedAt, stars: .four, starsAt: starsAt)
        let jpeg = file("PAIR.JPG", rating: .yes, ratedAt: ratedAt, color: .red, colorAt: colorAt)
        let plain = file("PLAIN.JPG", rating: .no, ratedAt: ratedAt)
        let store = readyStore([], extra: [PhotoItem(primaryFile: raw, pairedFile: jpeg), PhotoItem(primaryFile: plain)])
        XCTAssertTrue(store.canClearArchiveStarsAndLabels)
        let depth = store.undoStepCountForTesting
        store.requestClearStarsAndLabels()
        XCTAssertFalse(store.isClearStarsAndLabelsConfirmationPresented, "up to 15 items clear at once")
        XCTAssertEqual(store.undoStepCountForTesting, depth + 1, "one Undo step")
        XCTAssertNil(raw.starRating); XCTAssertNil(jpeg.colorLabel)
        XCTAssertNotNil(raw.starsChangedAt); XCTAssertNotEqual(raw.starsChangedAt, starsAt)
        XCTAssertNil(raw.colorChangedAt, "an empty field keeps its date")
        XCTAssertNil(plain.starsChangedAt)
        XCTAssertEqual([raw.rating, jpeg.rating, plain.rating], [.yes, .yes, .no])
        XCTAssertEqual([raw.ratedAt, jpeg.ratedAt, plain.ratedAt], [ratedAt, ratedAt, ratedAt])
        XCTAssertEqual(store.unratedStarCount, 2)
        XCTAssertEqual(store.noColorCount, 2)
        XCTAssertFalse(store.canClearArchiveStarsAndLabels)
        store.undo()
        XCTAssertEqual(raw.starRating, .four); XCTAssertEqual(raw.starsChangedAt, starsAt)
        XCTAssertEqual(jpeg.colorLabel, .red); XCTAssertEqual(jpeg.colorChangedAt, colorAt)
        XCTAssertEqual(store.items[0].starRatingState, .mixed)
        XCTAssertEqual(store.mixedStarCount, 1)
        XCTAssertTrue(store.canClearArchiveStarsAndLabels)
    }

    func testClearStarsAndLabelsConfirmsAbove15AndRefreshesStarSortAndFilterOnce() throws {
        let store = readyStore([], extra: (0..<16).map { PhotoItem(primaryFile: file(String(format: "I%02d.JPG", $0), stars: .two)) })
        store.filter.excludedStarStates = [.unrated]
        XCTAssertEqual(store.visibleIndices.count, 16)
        store.requestClearStarsAndLabels()
        XCTAssertTrue(store.isClearStarsAndLabelsConfirmationPresented)
        XCTAssertEqual(store.clearStarsAndLabelsConfirmationCount, 16)
        XCTAssertTrue(store.isSessionCommandPresentationActive, "the alert blocks other session commands")
        XCTAssertEqual(store.items.compactMap(\.primaryFile.starRating).count, 16, "nothing changes before confirming")
        store.clearStarsAndLabels()
        XCTAssertFalse(store.isClearStarsAndLabelsConfirmationPresented)
        XCTAssertTrue(store.visibleIndices.isEmpty, "the star filter reapplies")
        let palette = ActionPaletteView(store: store).actions.map(\.id)
        let decisions = try XCTUnwrap(palette.firstIndex(of: "clear-decisions"))
        XCTAssertEqual(palette[decisions + 1], "clear-stars-labels")
    }

    // MARK: - Fixtures

    private func file(_ name: String, rating: Rating = .undecided, ratedAt: Date? = nil,
                      stars: StarRating? = nil, starsAt: Date? = nil,
                      color: PhotoColorLabel? = nil, colorAt: Date? = nil) -> PhotoFile {
        PhotoFile(id: name, url: URL(fileURLWithPath: "/tmp/\(name)"), captureDate: nil, cameraModel: nil,
                  lensModel: nil, fileSize: 1, rating: rating, ratedAt: ratedAt, starRating: stars,
                  starsChangedAt: starsAt, colorLabel: color, colorChangedAt: colorAt)
    }

    private func readyStore(_ decisions: [Rating], extra: [PhotoItem] = []) -> SessionStore {
        let suite = "DecisionToggleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        store.items = decisions.enumerated().map { index, rating in
            PhotoItem(primaryFile: file("\(UnicodeScalar(65 + index)!).JPG", rating: rating,
                                        ratedAt: rating == .undecided ? nil : Date(timeIntervalSince1970: 100)))
        } + extra
        store.phase = .ready
        store.sort = PhotoSort(key: .name)
        store.rebuildDerivedDataForTesting()
        return store
    }

    private func key(_ character: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
}
