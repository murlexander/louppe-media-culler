import Foundation
import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ReviewGuidanceTests: XCTestCase {
    func testCompletionAndCleanUpCountsKeepMixedPairsPending() {
        let store = SessionStore()
        store.items = [
            item("YES.JPG", decision: .yes),
            item("NO.JPG", decision: .no),
            item("PENDING.JPG"),
            PhotoItem(
                primaryFile: file("MIXED.NEF", decision: .yes),
                pairedFile: file("MIXED.JPG", decision: .no)
            ),
        ]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.cleanUpScope = .all

        XCTAssertEqual(store.yesCount, 1)
        XCTAssertEqual(store.noCount, 1)
        XCTAssertEqual(store.undecidedCount, 2)
        XCTAssertEqual(store.mixedCount, 1)
        XCTAssertFalse(store.isReviewComplete)
        let breakdown = store.cleanUpDecisionBreakdown(for: .keepOnlyYes)
        XCTAssertEqual(breakdown.no, 1)
        XCTAssertEqual(breakdown.undecided, 1)
        XCTAssertEqual(store.cleanUpCounts(for: .keepOnlyYes).photos, 2)

        store.rate(.yes, at: 2)
        XCTAssertFalse(store.isReviewComplete, "a mixed pair still needs one decision")
        store.rate(.yes, at: 3)
        XCTAssertTrue(store.isReviewComplete)
        XCTAssertEqual(store.yesCount + store.noCount, store.items.count)
    }

    func testStatusPopoverOwnsReviewKeysUntilDismissed() throws {
        let store = SessionStore()
        store.items = [item("PENDING.JPG")]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        let view = SessionView(store: store)
        let rateYes = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ))

        store.isReviewStatusPresented = true
        XCTAssertFalse(view.handleKey(rateYes))
        XCTAssertEqual(store.items[0].rating, .undecided)
        store.presentActionPalette()
        XCTAssertFalse(store.isActionPalettePresented, "Commands must not run behind status details")
        store.isReviewStatusPresented = false
        XCTAssertTrue(view.handleKey(rateYes))
        XCTAssertEqual(store.items[0].rating, .yes)
    }

    func testFilterSummaryNamesOnlyActiveChoices() {
        var filter = PhotoFilter()
        filter.searchText = "birthday"
        filter.excludedDecisionStates = [.no, .undecided, .mixed]
        filter.excludedTypes = ["RAW"]
        XCTAssertEqual(
            filter.reviewSummary,
            "Filters: Search: “birthday” · Decision: Yes · File type"
        )
    }

    func testSaveLabelDoesNotCallAChangedSessionSavedUntilWriteCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeReviewGuidance-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png")
        try Data(contentsOf: source).write(to: photos.appendingPathComponent("A.png"))

        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: backup),
            saveTrailingDelay: 5,
            saveMaximumDelay: 10
        )
        store.openFolder(photos)
        let sidecar = photos.appendingPathComponent(SessionConstants.sidecarName)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .ready = store.phase,
               FileManager.default.fileExists(atPath: sidecar.path) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready = store.phase else {
            return XCTFail("fixture did not open")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let initialSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(initialSaveFinished)
        XCTAssertEqual(store.sessionSaveStatus, "Saved")

        store.rate(.yes, at: 0)
        XCTAssertNotEqual(store.sessionSaveStatus, "Saved")
        store.saveSession()
        let changedSaveFinished = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(changedSaveFinished)
        XCTAssertEqual(store.sessionSaveStatus, "Saved")
    }

    private func item(
        _ id: String,
        decision: Rating = .undecided
    ) -> PhotoItem {
        PhotoItem(primaryFile: file(id, decision: decision))
    }

    private func file(_ id: String, decision: Rating) -> PhotoFile {
        PhotoFile(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id)"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: decision
        )
    }
}
