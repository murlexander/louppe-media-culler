import Foundation
import XCTest
@testable import Louppe

final class PhotosLibraryOrganizationTests: XCTestCase, @unchecked Sendable {
    func testExactScopeAndOpaqueDestinationPreserveOtherMemberships() async {
        let library = OrganizationLibraryDouble(assets: ["a", "b", "unselected"], collections: [album("target"), album("same-title"), album("source")],
            memberships: ["source": ["a", "b"], "same-title": ["unselected"]])
        let service = PhotosLibraryOrganizationService(library: library)
        let result = await service.execute(.init(assetIdentifiers: ["b", "a", "b"], destination: .existingAlbum(localIdentifier: "target")))
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.requestedCount, 2)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["b", "a"])
        XCTAssertEqual(state.batches, [["b", "a"]])
        XCTAssertEqual(state.memberships["target"], ["a", "b"])
        XCTAssertEqual(state.memberships["source"], ["a", "b"])
        XCTAssertEqual(state.memberships["same-title"], ["unselected"])
        XCTAssertEqual(state.assets, ["a", "b", "unselected"])
    }

    func testNewAlbumInitialMembershipAndFolderPlacementAreOneTransaction() async {
        let parentFolder = folder("parent")
        let library = OrganizationLibraryDouble(assets: ["a", "b", "c"], collections: [parentFolder])
        let service = PhotosLibraryOrganizationService(library: library, batchSize: 2)
        let result = await service.execute(.init(assetIdentifiers: ["a", "b", "c"],
            destination: .newAlbum(title: "Chosen album", parentFolderIdentifier: "parent")))
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.createdAlbumIdentifier, "created-1")
        XCTAssertEqual(result.destinationIdentifier, "created-1")
        XCTAssertTrue(result.destinationVerified)
        XCTAssertTrue(result.placementVerified)
        XCTAssertEqual(state.transactions.count, 2)
        XCTAssertEqual(state.transactions.first?.createdIdentifier, "created-1")
        XCTAssertEqual(state.transactions.first?.parentIdentifier, "parent")
        XCTAssertEqual(state.transactions.first?.additions, ["a", "b"])
        XCTAssertNil(state.transactions.last?.createdIdentifier)
        XCTAssertEqual(state.targets, [.newAlbum(title: "Chosen album", parentFolderIdentifier: "parent"), .existingAlbum(localIdentifier: "created-1")])
        XCTAssertEqual(state.collections["created-1"]?.parentIdentifier, "parent")
        XCTAssertEqual(state.memberships["created-1"], ["a", "b", "c"])
    }

    func testTopLevelCreationAndMissingInitialChunkDoNotCreateEmptyAlbums() async {
        let library = OrganizationLibraryDouble(assets: ["present"])
        let result = await PhotosLibraryOrganizationService(library: library, batchSize: 1).execute(
            .init(assetIdentifiers: ["missing", "present"], destination: .newAlbum(title: "Album", parentFolderIdentifier: nil)))
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .stopped)
        XCTAssertEqual(result.issue, .assetsUnavailable)
        XCTAssertEqual(result.missingAssetIdentifiers, ["missing"])
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["present"])
        XCTAssertEqual(state.transactions.count, 1)
        XCTAssertNil(state.collections["created-1"]?.parentIdentifier)
        XCTAssertTrue(result.placementVerified)
        XCTAssertEqual(state.verificationPlacements, [.topLevel])
    }

    func testAllMissingAssetsNeverCreateAnAlbum() async {
        let library = OrganizationLibraryDouble()
        let result = await PhotosLibraryOrganizationService(library: library).execute(
            .init(assetIdentifiers: ["missing"], destination: .newAlbum(title: "Album", parentFolderIdentifier: nil)))
        let state = await library.snapshot()
        XCTAssertNil(result.createdAlbumIdentifier)
        XCTAssertEqual(result.issue, .assetsUnavailable)
        XCTAssertEqual(result.missingAssetIdentifiers, ["missing"])
        XCTAssertTrue(state.transactions.isEmpty)
        XCTAssertTrue(state.collections.isEmpty)
    }

    func testAlreadyPresentIsVerifiedWithoutReportingAnAddition() async {
        let library = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")], memberships: ["target": ["a"]])
        let result = await PhotosLibraryOrganizationService(library: library).execute(existingPlan(["a"]))
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a"])
        XCTAssertEqual(result.alreadyPresentAssetIdentifiers, ["a"])
        XCTAssertTrue(result.acknowledgedAddedAssetIdentifiers.isEmpty)
        XCTAssertEqual(result.acknowledgedTransactionCount, 0)
        XCTAssertTrue(state.transactions.isEmpty)
        XCTAssertEqual(state.verificationBatches, [["a"]])
    }

    func testAlreadyPresentDoesNotBecomeSuccessWhenConcurrentChangeRemovesIt() async {
        let library = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")], memberships: ["target": ["a"]])
        await library.setVerificationFault(.omit(["a"]), at: 1)
        let result = await PhotosLibraryOrganizationService(library: library).execute(existingPlan(["a"]))
        XCTAssertEqual(result.issue, .verificationMismatch)
        XCTAssertTrue(result.verifiedAssetIdentifiers.isEmpty)
        XCTAssertTrue(result.alreadyPresentAssetIdentifiers.isEmpty)
        XCTAssertEqual(result.unverifiedAssetIdentifiers, ["a"])
        XCTAssertTrue(result.uncertainAssetIdentifiers.isEmpty)
    }

    func testPreCancelledCreationDoesNotFetchOrMutate() async {
        let library = OrganizationLibraryDouble(assets: ["a"])
        let cancellation = PhotosOrganizationCancellation()
        cancellation.cancel()
        let result = await PhotosLibraryOrganizationService(library: library).execute(
            .init(assetIdentifiers: ["a"], destination: .newAlbum(title: "Album", parentFolderIdentifier: nil)), cancellation: cancellation)
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["a"])
        XCTAssertTrue(state.batches.isEmpty)
        XCTAssertTrue(state.transactions.isEmpty)
    }

    func testCancellationAtCommitAdmissionCannotCreateAnEmptyAlbum() async {
        let library = OrganizationLibraryDouble(assets: ["a"])
        let cancellation = PhotosOrganizationCancellation()
        let result = await PhotosLibraryOrganizationService(library: library).execute(
            .init(assetIdentifiers: ["a"], destination: .newAlbum(title: "Album", parentFolderIdentifier: nil)), cancellation: cancellation) { update in
                if update.phase == .committing { cancellation.cancel() }
            }
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertNil(result.createdAlbumIdentifier)
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["a"])
        XCTAssertTrue(state.transactions.isEmpty)
        XCTAssertTrue(state.collections.isEmpty)
    }

    func testCancellationDuringCommitAwaitsCallbackAndVerificationAndKeepsFirstChunk() async {
        let started = OrganizationTestGate(), callback = OrganizationTestGate()
        let library = OrganizationLibraryDouble(assets: ["a", "b", "c"], collections: [album("target")])
        await library.pauseFirstCallback(started: started, release: callback)
        let service = PhotosLibraryOrganizationService(library: library, batchSize: 2)
        let cancellation = PhotosOrganizationCancellation()
        let task = Task { await service.execute(existingPlan(["a", "b", "c"]), cancellation: cancellation) }
        let didStart = await started.wait()
        XCTAssertTrue(didStart, "The mock transaction did not reach its callback boundary")
        cancellation.cancel()
        let overlapping = await service.execute(existingPlan(["c"]))
        let during = await library.snapshot()
        XCTAssertEqual(overlapping.issue, .busy)
        XCTAssertTrue(during.verificationBatches.isEmpty, "Verification cannot precede the transaction callback")
        await callback.open()
        let result = await task.value
        let after = await library.snapshot()
        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a", "b"])
        XCTAssertEqual(result.acknowledgedAddedAssetIdentifiers, ["a", "b"])
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["c"])
        XCTAssertEqual(after.verificationBatches, [["a", "b"]])
        XCTAssertEqual(after.memberships["target"], ["a", "b"])
    }

    func testTaskCancellationAlsoAwaitsCurrentCommit() async {
        let started = OrganizationTestGate(), callback = OrganizationTestGate()
        let library = OrganizationLibraryDouble(assets: ["a", "b"], collections: [album("target")])
        await library.pauseFirstCallback(started: started, release: callback)
        let service = PhotosLibraryOrganizationService(library: library, batchSize: 1)
        let task = Task { await service.execute(existingPlan(["a", "b"])) }
        let didStart = await started.wait()
        XCTAssertTrue(didStart, "The mock transaction did not reach its callback boundary")
        task.cancel()
        await callback.open()
        let result = await task.value
        XCTAssertEqual(result.completion, .cancelled)
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a"])
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["b"])
    }

    func testCallbackFailureVerifiesObservedMembershipButNeverClaimsAcknowledgedSuccess() async {
        let library = OrganizationLibraryDouble(assets: ["a", "b"], collections: [album("target")])
        await library.failCallback(at: 1, applyChanges: true)
        let result = await PhotosLibraryOrganizationService(library: library, batchSize: 1).execute(existingPlan(["a", "b"]))
        XCTAssertEqual(result.completion, .stopped)
        XCTAssertEqual(result.issue, .changeFailed("Injected callback failure"))
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a"])
        XCTAssertTrue(result.acknowledgedAddedAssetIdentifiers.isEmpty)
        XCTAssertTrue(result.uncertainAssetIdentifiers.isEmpty)
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["b"])
    }

    func testFailedCallbackAndUnobservedAdditionStayUncertain() async {
        let library = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")])
        await library.failCallback(at: 1, applyChanges: false)
        let result = await PhotosLibraryOrganizationService(library: library).execute(existingPlan(["a"]))
        XCTAssertEqual(result.completion, .stopped)
        XCTAssertEqual(result.unverifiedAssetIdentifiers, ["a"])
        XCTAssertEqual(result.uncertainAssetIdentifiers, ["a"])
        XCTAssertTrue(result.verifiedAssetIdentifiers.isEmpty)
        XCTAssertTrue(result.acknowledgedAddedAssetIdentifiers.isEmpty)
    }

    func testFailedCreationKeepsCandidateIDWithoutClaimingThatAlbumExists() async {
        let library = OrganizationLibraryDouble(assets: ["a"])
        await library.failCallback(at: 1, applyChanges: false)
        let result = await PhotosLibraryOrganizationService(library: library).execute(
            .init(assetIdentifiers: ["a"], destination: .newAlbum(title: "Album", parentFolderIdentifier: nil)))
        let state = await library.snapshot()
        XCTAssertEqual(result.completion, .stopped)
        XCTAssertEqual(result.createdAlbumIdentifier, "created-1")
        XCTAssertFalse(result.destinationVerified)
        XCTAssertFalse(result.placementVerified)
        XCTAssertEqual(result.uncertainAssetIdentifiers, ["a"])
        XCTAssertTrue(state.collections.isEmpty)
    }

    func testVerificationFailurePreservesEarlierProgressAndUncertainCurrentChunk() async {
        let library = OrganizationLibraryDouble(assets: ["a", "b", "c"], collections: [album("target")])
        await library.setVerificationFault(.denied, at: 2)
        let result = await PhotosLibraryOrganizationService(library: library, batchSize: 1).execute(existingPlan(["a", "b", "c"]))
        let state = await library.snapshot()
        XCTAssertEqual(result.issue, .permissionDenied)
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a"])
        XCTAssertEqual(result.acknowledgedAddedAssetIdentifiers, ["a", "b"])
        XCTAssertEqual(result.uncertainAssetIdentifiers, ["b"])
        XCTAssertEqual(result.unverifiedAssetIdentifiers, ["b"])
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["c"])
        XCTAssertFalse(result.destinationVerified)
        XCTAssertEqual(state.memberships["target"], ["a", "b"], "No fake rollback on a verification failure")
    }

    func testSuccessfulCreationCallbackDoesNotProveParentPlacement() async {
        let library = OrganizationLibraryDouble(assets: ["a", "b"], collections: [folder("parent")])
        await library.setVerificationFault(.wrongPlacement, at: 1)
        let result = await PhotosLibraryOrganizationService(library: library, batchSize: 1).execute(
            .init(assetIdentifiers: ["a", "b"], destination: .newAlbum(title: "Album", parentFolderIdentifier: "parent")))
        XCTAssertEqual(result.issue, .verificationMismatch)
        XCTAssertEqual(result.createdAlbumIdentifier, "created-1")
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a"])
        XCTAssertTrue(result.destinationVerified)
        XCTAssertFalse(result.placementVerified)
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["b"])
    }

    func testDeletedDestinationNeverFallsBackToAnotherAlbumWithSameTitle() async {
        let library = OrganizationLibraryDouble(assets: ["a", "b"], collections: [album("target"), album("replacement")])
        await library.deleteCollection("target", beforeTransaction: 2)
        let result = await PhotosLibraryOrganizationService(library: library, batchSize: 1).execute(existingPlan(["a", "b"]))
        let state = await library.snapshot()
        XCTAssertEqual(result.issue, .collectionUnavailable("target"))
        XCTAssertEqual(result.verifiedAssetIdentifiers, ["a"])
        XCTAssertEqual(result.unprocessedAssetIdentifiers, ["b"])
        XCTAssertFalse(result.destinationVerified)
        XCTAssertNil(state.memberships["replacement"])
        XCTAssertEqual(state.targets, [.existingAlbum(localIdentifier: "target"), .existingAlbum(localIdentifier: "target")])
    }

    func testDestinationDeletionAfterCallbackIsUncertainAndStops() async {
        let library = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")])
        await library.setVerificationFault(.destinationDeleted, at: 1)
        let result = await PhotosLibraryOrganizationService(library: library).execute(existingPlan(["a"]))
        XCTAssertEqual(result.issue, .verificationMismatch)
        XCTAssertFalse(result.destinationVerified)
        XCTAssertEqual(result.uncertainAssetIdentifiers, ["a"])
        XCTAssertTrue(result.verifiedAssetIdentifiers.isEmpty)
    }

    func testVerificationCannotSubstituteDestinationOrIntroduceUnselectedIDs() async {
        for fault in [OrganizationLibraryDouble.VerificationFault.wrongDestination, .foreignMembership] {
            let library = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")])
            await library.setVerificationFault(fault, at: 1)
            let result = await PhotosLibraryOrganizationService(library: library).execute(existingPlan(["a"]))
            XCTAssertEqual(result.issue, .invalidLibraryResponse)
            XCTAssertEqual(result.uncertainAssetIdentifiers, ["a"])
            XCTAssertTrue(result.verifiedAssetIdentifiers.isEmpty)
        }
    }

    func testCapabilitiesAreCheckedForExactTargetAndFolderBeforeRequests() async {
        for destination in [PhotosOrganizationDestination.existingAlbum(localIdentifier: "blocked"),
                            .newAlbum(title: "Album", parentFolderIdentifier: "blocked")] {
            let blocked = PhotosOrganizationCollection(id: "blocked", title: "Same title", parentIdentifier: nil,
                kind: destination == .existingAlbum(localIdentifier: "blocked") ? .album : .folder,
                canAddAssets: false, canCreateAlbum: false)
            let library = OrganizationLibraryDouble(assets: ["a"], collections: [blocked])
            let result = await PhotosLibraryOrganizationService(library: library).execute(.init(assetIdentifiers: ["a"], destination: destination))
            let state = await library.snapshot()
            XCTAssertEqual(result.issue, .collectionNotWritable("blocked"))
            XCTAssertTrue(state.transactions.isEmpty)
            XCTAssertEqual(result.unprocessedAssetIdentifiers, ["a"])
        }
        XCTAssertThrowsError(try PhotosOrganizationBatchPolicy.validate(assetIdentifiers: ["a"], destination: .existingAlbum(localIdentifier: "target"),
            album: album("different-id"), folder: nil)) { error in
            XCTAssertEqual(error as? PhotosOrganizationIssue, .collectionUnavailable("target"))
        }
        XCTAssertThrowsError(try PhotosOrganizationBatchPolicy.validate(assetIdentifiers: ["a"], destination: .newAlbum(title: "Album", parentFolderIdentifier: "target"),
            album: nil, folder: album("target")))
    }

    func testRevokedPermissionAndUnsupportedSourcesRefuseChanges() async {
        let denied = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")])
        await denied.revokePermission()
        let deniedResult = await PhotosLibraryOrganizationService(library: denied).execute(existingPlan(["a"]))
        XCTAssertEqual(deniedResult.issue, .permissionDenied)
        let unsupported = OrganizationLibraryDouble(assets: ["a"], collections: [album("target")])
        await unsupported.setUnsupportedAssets(["a"])
        let result = await PhotosLibraryOrganizationService(library: unsupported).execute(existingPlan(["a"]))
        let state = await unsupported.snapshot()
        XCTAssertEqual(result.issue, .unsupportedAssets(["a"]))
        XCTAssertTrue(state.transactions.isEmpty)
    }

    func testBatchesAndVerificationAreBoundedAndProgressIsExact() async {
        let ids = (0..<605).map { "asset-\($0)" }
        let library = OrganizationLibraryDouble(assets: Set(ids), collections: [album("target")])
        let progress = OrganizationProgressRecorder()
        let result = await PhotosLibraryOrganizationService(library: library, batchSize: 10_000).execute(existingPlan(ids), progress: progress.record)
        let state = await library.snapshot()
        let updates = progress.values
        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(state.batches.map(\.count), [200, 200, 200, 5])
        XCTAssertEqual(state.verificationBatches, state.batches)
        XCTAssertEqual(result.verifiedAssetIdentifiers, ids)
        XCTAssertEqual(result.acknowledgedAddedAssetIdentifiers, ids)
        XCTAssertEqual(updates.first?.phase, .preparing)
        XCTAssertEqual(updates.first?.processedCount, 0)
        XCTAssertEqual(updates.last?.phase, .finished)
        XCTAssertEqual(updates.last?.processedCount, 605)
        XCTAssertEqual(updates.last?.verifiedCount, 605)
        XCTAssertEqual(updates.last?.acknowledgedAddedCount, 605)
        XCTAssertEqual(updates.last?.uncertainCount, 0)
        XCTAssertEqual(updates.map(\.processedCount), updates.map(\.processedCount).sorted())
    }

    func testInvalidPlansNeverReachPhotoKitBoundary() async {
        let library = OrganizationLibraryDouble(assets: ["a"])
        let service = PhotosLibraryOrganizationService(library: library)
        let plans = [PhotosOrganizationPlan(assetIdentifiers: [], destination: .existingAlbum(localIdentifier: "target")),
            .init(assetIdentifiers: [""], destination: .existingAlbum(localIdentifier: "target")),
            .init(assetIdentifiers: ["a"], destination: .existingAlbum(localIdentifier: "")),
            .init(assetIdentifiers: ["a"], destination: .newAlbum(title: " \n", parentFolderIdentifier: nil)),
            .init(assetIdentifiers: ["a"], destination: .newAlbum(title: "Album", parentFolderIdentifier: ""))]
        for plan in plans {
            let result = await service.execute(plan)
            XCTAssertEqual(result.completion, .stopped)
            XCTAssertNotNil(result.issue)
        }
        let state = await library.snapshot()
        XCTAssertTrue(state.batches.isEmpty)
    }

    func testHierarchyKeepsOpaqueIDsAndActualParentsAndDuplicateTitles() async throws {
        let nodes = [folder("f1"), folder("f2"), album("a1", parent: "f1"), album("a2", parent: "f2")]
        let library = OrganizationLibraryDouble(collections: nodes)
        let result = try await PhotosLibraryOrganizationService(library: library).hierarchy()
        XCTAssertEqual(result, nodes)
        XCTAssertEqual(result.filter { $0.kind == .album }.map(\.parentIdentifier), ["f1", "f2"])
    }

    func testMetadataOnlyNativeBoundaryCannotAcquireMediaOrRemoveMembership() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Louppe/PhotosLibraryOrganization.swift"), encoding: .utf8)
        for forbidden in ["PHImageManager", "PHAssetResource", "PHAssetChangeRequest", "FileManager", "performChangesAndWait",
                          "removeAssets(", "deleteAssetCollections(", "deleteCollectionLists(", "requestImage"] {
            XCTAssertFalse(source.contains(forbidden), "Organization must not introduce \(forbidden)")
        }
    }
}

private func album(_ id: String, parent: String? = nil) -> PhotosOrganizationCollection {
    .init(id: id, title: "Same title", parentIdentifier: parent, kind: .album, canAddAssets: true, canCreateAlbum: false)
}

private func folder(_ id: String) -> PhotosOrganizationCollection {
    .init(id: id, title: "Same title", parentIdentifier: nil, kind: .folder, canAddAssets: false, canCreateAlbum: true)
}

private func existingPlan(_ ids: [String]) -> PhotosOrganizationPlan {
    .init(assetIdentifiers: ids, destination: .existingAlbum(localIdentifier: "target"))
}

/// Faithful atomic metadata model: the shared policy runs before request construction, then creation,
/// parent placement and initial add publish together. Its callback can fail independently of observed
/// state, and verification always reads that state again. No native Photos object is instantiated.
private actor OrganizationLibraryDouble: PhotosOrganizationLibrary {
    enum VerificationFault: Sendable {
        case denied, destinationDeleted, wrongPlacement, wrongDestination, foreignMembership, omit(Set<String>)
    }
    struct Transaction: Sendable {
        let createdIdentifier: String?
        let parentIdentifier: String?
        let additions: [String]
    }
    struct Snapshot: Sendable {
        let assets: Set<String>
        let collections: [String: PhotosOrganizationCollection]
        let memberships: [String: Set<String>]
        let batches: [[String]]
        let targets: [PhotosOrganizationDestination]
        let transactions: [Transaction]
        let verificationBatches: [[String]]
        let verificationPlacements: [PhotosOrganizationPlacement?]
    }
    private var assets: Set<String>
    private var nodes: [PhotosOrganizationCollection]
    private var collections: [String: PhotosOrganizationCollection]
    private var memberships: [String: Set<String>]
    private var batches: [[String]] = []
    private var targets: [PhotosOrganizationDestination] = []
    private var transactions: [Transaction] = []
    private var verificationBatches: [[String]] = []
    private var verificationPlacements: [PhotosOrganizationPlacement?] = []
    private var permission = true
    private var unsupported: Set<String> = []
    private var verificationFaults: [Int: VerificationFault] = [:]
    private var deletions: [Int: String] = [:]
    private var callbackFailures: [Int: Bool] = [:]
    private var started: OrganizationTestGate?
    private var release: OrganizationTestGate?
    private var creationCount = 0

    init(assets: Set<String> = [], collections: [PhotosOrganizationCollection] = [], memberships: [String: Set<String>] = [:]) {
        self.assets = assets; self.nodes = collections
        self.collections = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        self.memberships = memberships
    }
    func revokePermission() { permission = false }
    func setUnsupportedAssets(_ ids: Set<String>) { unsupported = ids }
    func setVerificationFault(_ fault: VerificationFault, at index: Int) { verificationFaults[index] = fault }
    func deleteCollection(_ id: String, beforeTransaction index: Int) { deletions[index] = id }
    func failCallback(at index: Int, applyChanges: Bool) { callbackFailures[index] = applyChanges }
    func pauseFirstCallback(started: OrganizationTestGate, release: OrganizationTestGate) { self.started = started; self.release = release }
    func hierarchy() async throws -> [PhotosOrganizationCollection] {
        guard permission else { throw PhotosOrganizationIssue.permissionDenied }
        return nodes
    }
    func snapshot() -> Snapshot {
        .init(assets: assets, collections: collections, memberships: memberships, batches: batches, targets: targets,
              transactions: transactions, verificationBatches: verificationBatches, verificationPlacements: verificationPlacements)
    }

    func transact(assetIdentifiers ids: [String], destination: PhotosOrganizationDestination,
                  cancellation: PhotosOrganizationCancellation) async -> PhotosOrganizationBatchResult {
        batches.append(ids); targets.append(destination)
        let index = batches.count
        if let deletion = deletions[index] { collections.removeValue(forKey: deletion); memberships.removeValue(forKey: deletion) }
        guard permission else { return .init(status: .rejected(.permissionDenied)) }
        if cancellation.isCancelled { return .init(status: .cancelled) }
        let destinationID: String?
        let parent: String?
        switch destination {
        case .existingAlbum(let id): destinationID = id; parent = nil
        case .newAlbum(_, let folder): destinationID = nil; parent = folder
        }
        let available = ids.filter { assets.contains($0) }
        let already = available.filter { memberships[destinationID ?? ""]?.contains($0) == true }
        let additions = available.filter { !Set(already).contains($0) }
        do {
            try PhotosOrganizationBatchPolicy.validate(assetIdentifiers: ids, destination: destination,
                album: destinationID.flatMap { collections[$0] }, folder: parent.flatMap { collections[$0] },
                unsupportedAssetIdentifiers: additions.filter { unsupported.contains($0) })
        } catch {
            return .init(status: .rejected((error as? PhotosOrganizationIssue) ?? .requestUnavailable))
        }
        if cancellation.isCancelled { return .init(status: .cancelled) }
        var report = PhotosOrganizationBatchResult(status: .noChanges, destinationIdentifier: destinationID,
            availableAssetIdentifiers: available, missingAssetIdentifiers: ids.filter { !assets.contains($0) }, alreadyPresentAssetIdentifiers: already)
        guard !additions.isEmpty else { return report }
        let actualID: String
        if let destinationID { actualID = destinationID }
        else {
            creationCount += 1; actualID = "created-\(creationCount)"
            report.createdAlbumIdentifier = actualID
        }
        report.destinationIdentifier = actualID
        report.submittedAssetIdentifiers = additions
        let applies = callbackFailures[index] ?? true
        if applies {
            if report.createdAlbumIdentifier != nil {
                collections[actualID] = .init(id: actualID, title: "Created album", parentIdentifier: parent,
                    kind: .album, canAddAssets: true, canCreateAlbum: false)
            }
            memberships[actualID, default: []].formUnion(additions)
        }
        transactions.append(.init(createdIdentifier: report.createdAlbumIdentifier, parentIdentifier: parent, additions: additions))
        // A paused callback cannot be interrupted by Task cancellation, matching PhotoKit.
        if index == 1 { await started?.open(); _ = await release?.wait() }
        report.status = callbackFailures[index] == nil ? .committed : .failed(.changeFailed("Injected callback failure"))
        return report
    }

    func verify(assetIdentifiers ids: [String], destinationIdentifier: String,
                placement: PhotosOrganizationPlacement?) async throws -> PhotosOrganizationVerification {
        verificationBatches.append(ids); verificationPlacements.append(placement)
        guard permission else { throw PhotosOrganizationIssue.permissionDenied }
        let fault = verificationFaults[verificationBatches.count]
        if case .some(.denied) = fault { throw PhotosOrganizationIssue.permissionDenied }
        if case .some(.destinationDeleted) = fault { collections.removeValue(forKey: destinationIdentifier); memberships.removeValue(forKey: destinationIdentifier) }
        let node = collections[destinationIdentifier]
        var present = Set(ids).intersection(assets).intersection(memberships[destinationIdentifier] ?? [])
        if case .some(.omit(let omitted)) = fault { present.subtract(omitted) }
        if case .some(.foreignMembership) = fault { present.insert("unselected") }
        var matches: Bool
        switch placement {
        case nil: matches = true
        case .some(.topLevel): matches = node?.parentIdentifier == nil
        case .some(.folder(let id)): matches = collections[id] != nil && node?.parentIdentifier == id
        }
        if case .some(.wrongPlacement) = fault { matches = false }
        let returnedID: String
        if case .some(.wrongDestination) = fault { returnedID = "replacement" } else { returnedID = destinationIdentifier }
        return .init(destinationIdentifier: returnedID, destinationExists: node != nil,
                     placementMatches: matches && node != nil, presentAssetIdentifiers: present)
    }
}

private actor OrganizationTestGate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    func wait() async -> Bool {
        if opened { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(5))
                expire(id)
            }
        }
    }
    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for continuation in pending.values { continuation.resume(returning: true) }
    }
}

private final class OrganizationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [PhotosOrganizationProgress] = []
    var values: [PhotosOrganizationProgress] { lock.withLock { updates } }
    func record(_ progress: PhotosOrganizationProgress) { lock.withLock { updates.append(progress) } }
}
