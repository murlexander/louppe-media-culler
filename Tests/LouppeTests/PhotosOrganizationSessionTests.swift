import Foundation
import XCTest
@testable import Louppe

@MainActor
final class PhotosOrganizationSessionTests: XCTestCase {
    func testCurrentFallbackHoldsSharedGateThroughCancellationAndVerification() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient(held: true)
        let store = makeStore(fixture, client)
        try await open(store)
        store.currentIndex = 12
        store.presentPhotosOrganization()
        try await choosing(store)
        XCTAssertEqual(store.photosOrganizationModel.selectionLabel, L10n.text("Current item"))
        XCTAssertEqual(store.photosOrganizationModel.scopeCounts[.selected], 1)
        store.confirmPhotosOrganization(draft(.selected))
        try await wait { await client.hasStarted }
        XCTAssertEqual(store.activeFileOperation, .photosOrganization)
        XCTAssertTrue(store.isPreventingIdleSystemSleep)
        XCTAssertFalse(store.canRate)
        XCTAssertFalse(store.canExport)
        store.cancelPhotosOrganization()
        store.dismissPhotosOrganization()
        XCTAssertTrue(store.isPhotosOrganizationPresented)
        XCTAssertEqual(store.activeFileOperation, .photosOrganization,
                       "Cancellation must not release the gate before a submitted update settles")
        let requestedIDs = await client.identifiers()
        XCTAssertEqual(requestedIDs, ["asset-12"])
        await client.release()
        try await finished(store)
        XCTAssertNil(store.activeFileOperation)
        XCTAssertFalse(store.isPreventingIdleSystemSleep)
        guard case .finished(let report) = store.photosOrganizationModel.phase else { return XCTFail() }
        XCTAssertEqual(report.disposition, .cancelled)
        XCTAssertEqual(report.unprocessed, 1)
        store.dismissPhotosOrganization()
        XCTAssertFalse(store.isSessionCommandPresentationActive)
    }

    func testSnapshotSelectionAndDecisionsSurviveAdditiveOrganization() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient()
        let store = makeStore(fixture, client)
        try await open(store)
        store.currentIndex = 3
        store.setStarRating(.four, at: 3)
        store.toggleSelection(of: 2)
        store.toggleSelection(of: 7)
        let originalOrder = store.items.map(\.id)
        let originalSelection = store.selectedIndices
        store.presentPhotosOrganization()
        try await choosing(store)
        // A direct model mutation cannot substitute the reviewed snapshot's IDs.
        store.clearSelection()
        store.toggleSelection(of: 9)
        store.confirmPhotosOrganization(draft(.selected))
        try await finished(store)
        let requestedIDs = await client.identifiers()
        XCTAssertEqual(requestedIDs, ["asset-2", "asset-3", "asset-7"])
        XCTAssertEqual(store.items.map(\.id), originalOrder)
        XCTAssertEqual(store.currentIndex, 3)
        XCTAssertEqual(store.items[3].primaryFile.starRating, .four)
        let decisions = try await fixture.decisions.load(assetIDs: ["asset-3"])
        XCTAssertEqual(decisions["asset-3"]?.stars, .four, "Decision checkpoint precedes PhotoKit changes")
        XCTAssertEqual(originalSelection, [2, 3, 7])
        XCTAssertEqual(store.selectedIndices, [3, 9], "Album addition must not rewrite local selection")
        store.dismissPhotosOrganization()
        store.undo()
        XCTAssertNil(store.items[3].primaryFile.starRating, "Existing review Undo remains usable")
        _ = await store.saveSessionForTermination()
    }

    func testAllScopeIsExactAndDoesNotRequestOriginals() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient()
        let store = makeStore(fixture, client)
        try await open(store)
        store.presentPhotosOrganization()
        try await choosing(store)
        store.confirmPhotosOrganization(draft(.all))
        try await finished(store)
        let ids = await client.identifiers()
        XCTAssertEqual(ids, (0..<2_003).map { "asset-\($0)" })
        let requests = await fixture.provider.requests
        XCTAssertTrue(requests.originals.isEmpty)
        XCTAssertTrue(requests.filenames.isEmpty)
        guard case .finished(let report) = store.photosOrganizationModel.phase else { return XCTFail() }
        XCTAssertEqual(report.disposition, .completed)
        XCTAssertEqual(report.verified, 2_003)
    }

    func testFilteredScopeRetainsItsExactSnapshotWhenLiveFilterChanges() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient()
        let store = makeStore(fixture, client)
        try await open(store)
        store.rate(.yes, at: 5)
        store.rate(.yes, at: 10)
        store.filter.excludedDecisionStates = [.no, .undecided, .mixed]
        XCTAssertEqual(Set(store.visibleIndices), [5, 10])
        store.presentPhotosOrganization()
        try await choosing(store)
        XCTAssertEqual(store.photosOrganizationModel.scopeCounts[.filtered], 2)
        store.filter = PhotoFilter()
        store.confirmPhotosOrganization(draft(.filtered))
        try await finished(store)
        let ids = await client.identifiers()
        XCTAssertEqual(Set(ids), ["asset-5", "asset-10"])
        XCTAssertEqual(store.visibleIndices.count, 2_003)
        store.dismissPhotosOrganization()
        _ = await store.saveSessionForTermination()
    }

    func testReplacedReviewCannotExecuteOldConfirmedScope() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient()
        let store = makeStore(fixture, client)
        try await open(store)
        let old = store.sourceFolder
        store.presentPhotosOrganization()
        try await choosing(store)
        store.openPhotosSelection()
        try await wait { store.sourceFolder != old && !store.isFileOperationRunning }
        store.confirmPhotosOrganization(draft(.selected))
        guard case .finished(let report) = store.photosOrganizationModel.phase else { return XCTFail() }
        XCTAssertEqual(report.disposition, .failed)
        let started = await client.hasStarted
        XCTAssertFalse(started)
        XCTAssertNil(store.activeFileOperation)
    }

    func testFailedDecisionSaveBlocksAlbumMutationAndPreservesUnpublishedDecision() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient()
        let store = makeStore(fixture, client)
        try await open(store)
        _ = await store.saveSessionForTermination()
        let json = fixture.root.appendingPathComponent("Decisions/decisions.json")
        let good = try Data(contentsOf: json)
        let damaged = Data("invalid decision checkpoint".utf8)
        try damaged.write(to: json)
        store.rate(.yes, at: 5)
        store.presentPhotosOrganization()
        try await choosing(store)
        store.confirmPhotosOrganization(draft(.selected))
        try await finished(store)
        let started = await client.hasStarted
        XCTAssertFalse(started)
        XCTAssertEqual(store.items[5].rating, .yes)
        XCTAssertNotNil(store.persistenceWarning)
        XCTAssertEqual(try Data(contentsOf: json), damaged)
        guard case .finished(let report) = store.photosOrganizationModel.phase else { return XCTFail() }
        XCTAssertEqual(report.disposition, .failed)
        try good.write(to: json)
        store.retryPersistence()
        try await wait { store.persistenceWarning == nil }
    }

    func testRevokedHierarchyIsVisibleAndCanReloadWithoutMutation() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let client = SessionAlbumClient()
        await client.setHierarchyDenied(true)
        let store = makeStore(fixture, client)
        try await open(store)
        store.presentPhotosOrganization()
        try await choosing(store)
        XCTAssertNotNil(store.photosOrganizationModel.hierarchyError)
        XCTAssertFalse(store.photosOrganizationModel.canCreateTopLevelAlbum)
        let started = await client.hasStarted
        XCTAssertFalse(started)
        await client.setHierarchyDenied(false)
        store.reloadPhotosOrganization()
        try await choosing(store)
        XCTAssertNil(store.photosOrganizationModel.hierarchyError)
        XCTAssertEqual(store.photosOrganizationModel.hierarchy.map(\.id), ["destination"])
        store.dismissPhotosOrganization()
        XCTAssertNil(store.activeFileOperation)
    }

    func testFilterChoosesPhotosOnlyAfterPopoverDismissalAndConsumesHandoffOnce() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = makeStore(fixture, SessionAlbumClient())
        try await open(store)
        store.isFilterPresented = true
        store.requestPhotosLibraryFromFilter()
        XCTAssertFalse(store.isFilterPresented)
        XCTAssertFalse(store.isPhotosLibraryPresented)
        store.finishFilterDismissal()
        try await wait { store.isPhotosLibraryPresented }
        store.isPhotosLibraryPresented = false
        store.finishFilterDismissal()
        await Task.yield()
        XCTAssertFalse(store.isPhotosLibraryPresented, "Dismissal handoff must be consumed once")
    }

    func testCompletionRequiresVerifiedDestinationPlacementAndMembershipNotAcknowledgement() {
        var result = PhotosOrganizationResult()
        result.requestedCount = 2
        result.acknowledgedAddedAssetIdentifiers = ["one", "two"]
        result.verifiedAssetIdentifiers = ["one", "two"]
        result.destinationVerified = true
        result.placementVerified = false
        result.createdAlbumIdentifier = "candidate"
        var report = PhotosOrganizationPresentation.report(result, destinationPath: "Photos Library › Test")
        XCTAssertEqual(report.disposition, .partial)
        XCTAssertNotNil(report.message)
        result.placementVerified = true
        report = PhotosOrganizationPresentation.report(result, destinationPath: nil)
        XCTAssertEqual(report.disposition, .completed)
        result.completion = .stopped
        result.issue = .changeFailed("Callback failed despite observable membership")
        report = PhotosOrganizationPresentation.report(result, destinationPath: nil)
        XCTAssertEqual(report.disposition, .partial)
        XCTAssertTrue(report.message?.contains("Callback failed") == true)
        result.verifiedAssetIdentifiers = ["one"]
        result.unverifiedAssetIdentifiers = ["two"]
        result.uncertainAssetIdentifiers = ["two"]
        report = PhotosOrganizationPresentation.report(result, destinationPath: nil)
        XCTAssertEqual(report.verified, 1)
        XCTAssertEqual(report.uncertain, 1)
        XCTAssertNotNil(report.message)
    }

    private func makeStore(_ fixture: LazyPhotosFixture, _ client: SessionAlbumClient) -> SessionStore {
        SessionStore(persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("Backups")),
            photosDecisions: fixture.decisions, photosLibrary: fixture.library, photosOrganization: client,
            operationJournalDirectory: fixture.journals, reviewDefaults: fixture.defaults)
    }
    private func draft(_ scope: SourceOrganizationScope) -> PhotosOrganizationDraft {
        .init(scope: scope, destination: .existingAlbum(id: "destination"))
    }
    private func open(_ store: SessionStore) async throws {
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { store.items.count == 2_003 && !store.isFileOperationRunning }
    }
    private func choosing(_ store: SessionStore) async throws {
        try await wait { if case .choosing = store.photosOrganizationModel.phase { return true }; return false }
    }
    private func finished(_ store: SessionStore) async throws {
        try await wait {
            if case .finished = store.photosOrganizationModel.phase { return !store.isFileOperationRunning }
            return false
        }
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await predicate()) {
            guard Date() < deadline else { throw SessionAlbumError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum SessionAlbumError: Error { case timeout }
private actor SessionAlbumClient: PhotosLibraryOrganizationClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private var requested: [String] = []
    private var denied = false
    private let held: Bool
    private(set) var hasStarted = false
    init(held: Bool = false) { self.held = held }
    func setHierarchyDenied(_ value: Bool) { denied = value }
    func hierarchy() throws -> [PhotosOrganizationCollection] {
        if denied { throw PhotosOrganizationIssue.permissionDenied }
        return [.init(id: "destination", title: "Test Album", parentIdentifier: nil,
            kind: .album, canAddAssets: true, canCreateAlbum: false)]
    }
    func execute(_ plan: PhotosOrganizationPlan, cancellation: PhotosOrganizationCancellation,
                 progress: @escaping @Sendable (PhotosOrganizationProgress) -> Void) async -> PhotosOrganizationResult {
        requested = plan.assetIdentifiers
        hasStarted = true
        if held {
            await withCheckedContinuation { continuation = $0 }
        }
        var result = PhotosOrganizationResult()
        result.requestedCount = requested.count
        result.destinationIdentifier = "destination"
        if cancellation.isCancelled {
            result.completion = .cancelled
            result.unprocessedAssetIdentifiers = requested
        } else {
            result.verifiedAssetIdentifiers = requested
            result.destinationVerified = true
            result.placementVerified = true
        }
        return result
    }
    func identifiers() -> [String] { requested }
    func release() { continuation?.resume(); continuation = nil }
}

final class PhotosOrganizationChoicesTests: XCTestCase, @unchecked Sendable {
    func testExactHierarchyAndDuplicateTitlesStayDisambiguatedWithCachedLookup() async throws {
        let nodes: [PhotosOrganizationCollection] = [
            .init(id: "a", title: "Archive", parentIdentifier: nil, kind: .folder, canAddAssets: false, canCreateAlbum: true),
            .init(id: "b", title: "Archive", parentIdentifier: nil, kind: .folder, canAddAssets: false, canCreateAlbum: true),
            .init(id: "one", title: "Shoot", parentIdentifier: "a", kind: .album, canAddAssets: true, canCreateAlbum: false),
            .init(id: "two", title: "Shoot", parentIdentifier: "b", kind: .album, canAddAssets: true, canCreateAlbum: false),
            .init(id: "readonly", title: "Read only", parentIdentifier: "a", kind: .album, canAddAssets: false, canCreateAlbum: false)]
        let choices = try await Task.detached { try PhotosOrganizationChoices.prepare(nodes) }.value
        XCTAssertEqual(choices.albums.map(\.id), ["one", "two"])
        XCTAssertEqual(choices.folders.map(\.id), ["a", "b"])
        XCTAssertNotEqual(choices.albumsByID["one"]?.label, choices.albumsByID["two"]?.label)
        XCTAssertTrue(choices.albumsByID["one"]?.label.contains("one") == true)
        XCTAssertNil(choices.albumsByID["readonly"])
        XCTAssertEqual(PhotosOrganizationPresentation.destinationPath(.existingAlbum(localIdentifier: "two"), choices: choices),
                       choices.albumsByID["two"]?.label)
        XCTAssertNil(PhotosOrganizationPresentation.destinationPath(.existingAlbum(localIdentifier: "missing"), choices: choices))
    }

    func testMalformedAncestryAndDisplayBudgetAreRejectedWithoutPartialChoices() throws {
        let invalid: [[PhotosOrganizationCollection]] = [
            [.init(id: "a", title: "A", parentIdentifier: "missing", kind: .album, canAddAssets: true, canCreateAlbum: false)],
            [.init(id: "a", title: "A", parentIdentifier: "a", kind: .folder, canAddAssets: false, canCreateAlbum: true)],
            [.init(id: "a", title: "A", parentIdentifier: nil, kind: .album, canAddAssets: true, canCreateAlbum: false),
             .init(id: "a", title: "B", parentIdentifier: nil, kind: .album, canAddAssets: true, canCreateAlbum: false)]]
        for nodes in invalid { XCTAssertThrowsError(try PhotosOrganizationChoices.prepare(nodes)) }
        XCTAssertThrowsError(try PhotosOrganizationChoices.prepare([
            .init(id: "a", title: String(repeating: "X", count: 100), parentIdentifier: nil,
                  kind: .album, canAddAssets: true, canCreateAlbum: false)], maximumPathBytes: 20))
    }

    func testSyntheticFiftyThousandAlbumsPrepareOffMainWithoutPerInteractionRebuilding() async throws {
        let nodes = (0..<50_000).map { index in PhotosOrganizationCollection(
            id: "album-\(index)", title: "Album \(index)", parentIdentifier: nil,
            kind: .album, canAddAssets: true, canCreateAlbum: false) }
        let prepared = try await Task.detached {
            try Self.measuredPreparation(nodes)
        }.value
        XCTAssertFalse(prepared.1)
        XCTAssertEqual(prepared.0.albums.count, 50_000)
        XCTAssertEqual(prepared.0.albumsByID["album-49999"]?.collection.title, "Album 49999")
        print("PHOTOS_ORGANIZATION_CHOICES synthetic_albums=50000 off_main=true preparation=\(prepared.2)")
    }

    private static func measuredPreparation(_ nodes: [PhotosOrganizationCollection]) throws
        -> (PhotosOrganizationChoices, Bool, Duration) {
        let start = ContinuousClock.now
        let choices = try PhotosOrganizationChoices.prepare(nodes)
        return (choices, Thread.isMainThread, start.duration(to: .now))
    }
}
