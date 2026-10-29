import Foundation
import XCTest
@testable import Louppe

@MainActor
final class PhotosNetworkSettingsTests: XCTestCase {
    func testFreshPreferencesAndFirstReviewRequireSeparateConsent() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        XCTAssertFalse(store.photosReviewNetwork)
        XCTAssertFalse(store.photosOriginalNetwork)
        XCTAssertFalse(store.photosBrowser.allowNetwork)
        try await openSelection(store)
        let session = try XCTUnwrap(store.photosBatch?.mediaSession)
        let before = await fixture.provider.requests
        XCTAssertTrue(before.images.isEmpty)
        XCTAssertTrue(before.originals.isEmpty)
        try await assertCloudImageBlocked(session, assetID: "asset-1")
        try await assertCloudOriginalBlocked(session, item: store.items[1])
    }

    func testSettingsPersistIndependentlyAcrossRelaunchWithoutOpeningASource() throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let suite = "Louppe.PhotosNetworkRelaunch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func relaunched() throws -> SessionStore {
            SessionStore(photosDecisions: fixture.decisions, photosLibrary: fixture.library,
                operationJournalDirectory: fixture.journals,
                reviewDefaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        }
        let initial = try relaunched()
        initial.photosReviewNetwork = true
        let reviewOnly = try relaunched()
        XCTAssertTrue(reviewOnly.photosReviewNetwork)
        XCTAssertTrue(reviewOnly.photosBrowser.allowNetwork)
        XCTAssertFalse(reviewOnly.photosOriginalNetwork)

        reviewOnly.photosOriginalNetwork = true
        let both = try relaunched()
        XCTAssertTrue(both.photosReviewNetwork)
        XCTAssertTrue(both.photosOriginalNetwork)

        both.photosReviewNetwork = false
        let originalsOnly = try relaunched()
        XCTAssertFalse(originalsOnly.photosReviewNetwork)
        XCTAssertFalse(originalsOnly.photosBrowser.allowNetwork)
        XCTAssertTrue(originalsOnly.photosOriginalNetwork)

        originalsOnly.photosOriginalNetwork = false
        let neither = try relaunched()
        XCTAssertFalse(neither.photosReviewNetwork)
        XCTAssertFalse(neither.photosOriginalNetwork)
        XCTAssertNil(neither.photosBatch)
        XCTAssertNil(neither.sourceFolder)
        XCTAssertEqual(defaults.object(forKey: "photosReview.allowNetworkImages") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "photosReview.allowNetworkOriginals") as? Bool, false)
    }

    func testActiveSettingsKeepSourceAndDecisionsAndDoNotRequestOriginals() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        try await openSelection(store)
        let session = try XCTUnwrap(store.photosBatch?.mediaSession)
        let folder = store.sourceFolder
        let snapshotID = store.photosBatch?.snapshot.id
        store.rate(.yes, at: 1)
        store.setStarRating(.five, at: 1)
        store.setIndex(1)
        store.selectRange(to: 3)
        let currentIndex = store.currentIndex
        let selection = store.selectedIndices
        let originalRequests = await fixture.provider.requests.originals.count

        store.photosReviewNetwork = true
        await store.waitForPhotosNetworkSettingsForTesting()
        _ = try await session.image(assetID: "asset-1", pixels: 384)
        let afterReviewSetting = await fixture.provider.requests
        XCTAssertEqual(afterReviewSetting.originals.count, originalRequests,
                       "Review permission must never initiate an original request")
        try await assertCloudOriginalBlocked(session, item: store.items[1])

        let afterBlockedOriginal = await fixture.provider.requests.originals.count
        store.photosOriginalNetwork = true
        await store.waitForPhotosNetworkSettingsForTesting()
        let afterOriginalSetting = await fixture.provider.requests
        XCTAssertEqual(afterOriginalSetting.originals.count, afterBlockedOriginal,
                       "Original permission alone must not retry or start a download")
        let lease = try await session.original(for: store.items[1])
        XCTAssertEqual(try Data(contentsOf: lease.item.primaryURL), MockPhotosMedia.originalBytes("asset-1"))
        await lease.close()

        store.photosReviewNetwork = false
        await store.waitForPhotosNetworkSettingsForTesting()
        // A fresh asset misses the representation cache after revocation.
        try await assertCloudImageBlocked(session, assetID: "asset-3")
        let originalStillAllowed = try await session.original(for: store.items[3])
        await originalStillAllowed.close()
        store.photosOriginalNetwork = false
        await store.waitForPhotosNetworkSettingsForTesting()
        try await assertCloudOriginalBlocked(session, item: store.items[5])

        XCTAssertEqual(store.sourceFolder, folder)
        XCTAssertEqual(store.photosBatch?.snapshot.id, snapshotID)
        XCTAssertEqual(store.items.count, 2_003)
        XCTAssertEqual(store.items[1].rating, .yes)
        XCTAssertEqual(store.items[1].primaryFile.starRating, .five)
        XCTAssertEqual(store.currentIndex, currentIndex)
        XCTAssertEqual(store.selectedIndices, selection)
        let preparations = await fixture.library.selectionRequests
        XCTAssertEqual(preparations, 1, "Changing Settings must not reopen the source")
    }

    func testRememberedPermissionsApplyToFutureReviewsAndKeepOriginalConsentSeparate() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let settings = fixture.store()
        settings.photosReviewNetwork = true
        let reopened = fixture.store()
        try await openSelection(reopened)
        let reviewSession = try XCTUnwrap(reopened.photosBatch?.mediaSession)
        _ = try await reviewSession.image(assetID: "asset-1", pixels: 384)
        try await assertCloudOriginalBlocked(reviewSession, item: reopened.items[1])

        reopened.photosOriginalNetwork = true
        reopened.photosReviewNetwork = false
        await reopened.waitForPhotosNetworkSettingsForTesting()
        let originalFolder = reopened.sourceFolder
        reopened.openPhotosSelection()
        try await wait { ready(reopened) && reopened.sourceFolder != originalFolder }
        let nextSession = try XCTUnwrap(reopened.photosBatch?.mediaSession)
        try await assertCloudImageBlocked(nextSession, assetID: "asset-1")
        let lease = try await nextSession.original(for: reopened.items[1])
        await lease.close()

        let relaunched = fixture.store()
        try await openSelection(relaunched)
        let restoredSession = try XCTUnwrap(relaunched.photosBatch?.mediaSession)
        try await assertCloudImageBlocked(restoredSession, assetID: "asset-1")
        let restoredLease = try await restoredSession.original(for: relaunched.items[1])
        await restoredLease.close()
        XCTAssertFalse(relaunched.photosReviewNetwork)
        XCTAssertTrue(relaunched.photosOriginalNetwork)
    }

    func testRapidTogglesWhilePreparingAndReplacingSessionsUseLatestConsent() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.photosReviewNetwork = true
        store.photosOriginalNetwork = true
        try await openSelection(store)
        let firstFolder = store.sourceFolder

        await fixture.library.holdNextSelection()
        store.openPhotosSelection()
        try await wait { await fixture.library.selectionIsHeld }
        // The held batch has already captured review=true. Settings now change
        // repeatedly while the outgoing session remains available.
        for _ in 0..<12 {
            store.photosReviewNetwork = false
            store.photosOriginalNetwork = false
            store.photosReviewNetwork = true
            store.photosOriginalNetwork = true
        }
        store.photosReviewNetwork = false
        XCTAssertEqual(store.sourceFolder, firstFolder)
        await fixture.library.releaseSelection()
        try await wait { ready(store) && store.sourceFolder != firstFolder }
        await store.waitForPhotosNetworkSettingsForTesting()
        let secondSession = try XCTUnwrap(store.photosBatch?.mediaSession)
        try await assertCloudImageBlocked(secondSession, assetID: "asset-1")
        let lease = try await secondSession.original(for: store.items[1])
        await lease.close()

        // Queue another permission update and immediately replace the session.
        // Late updates bound to the outgoing actor cannot change the new one.
        let secondFolder = store.sourceFolder
        store.photosOriginalNetwork = false
        store.photosReviewNetwork = true
        store.photosReviewNetwork = false
        store.openPhotosSelection()
        try await wait { ready(store) && store.sourceFolder != secondFolder }
        await store.waitForPhotosNetworkSettingsForTesting()
        let thirdSession = try XCTUnwrap(store.photosBatch?.mediaSession)
        try await assertCloudImageBlocked(thirdSession, assetID: "asset-1")
        try await assertCloudOriginalBlocked(thirdSession, item: store.items[1])
        let beforeLateTasks = store.photosReviewGeneration
        await Task.yield()
        XCTAssertEqual(store.photosReviewGeneration, beforeLateTasks,
                       "A retired session's completion must not refresh the current review")
        XCTAssertFalse(fixture.store().photosReviewNetwork)
        XCTAssertFalse(fixture.store().photosOriginalNetwork)
    }

    private func assertCloudImageBlocked(_ session: PhotosMediaSession, assetID: String) async throws {
        do {
            _ = try await session.image(assetID: assetID, pixels: 384)
            XCTFail("Cloud review images require their own permission")
        } catch PhotosRepresentationError.cloud {}
    }

    private func assertCloudOriginalBlocked(_ session: PhotosMediaSession, item: PhotoItem) async throws {
        do {
            let lease = try await session.original(for: item)
            await lease.close()
            XCTFail("Cloud originals require their own permission")
        } catch PhotosLibraryError.iCloudDownloadRequired {}
    }

    private func openSelection(_ store: SessionStore) async throws {
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { ready(store) }
    }

    private func ready(_ store: SessionStore) -> Bool {
        if case .ready = store.phase {
            return store.items.count == 2_003 && !store.isFileOperationRunning && !store.photosBrowser.isOpening
        }
        return false
    }

    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await predicate()) {
            guard Date() < deadline else { throw SettingsTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum SettingsTestError: Error { case timedOut }
}
