import Foundation
import XCTest
@testable import Louppe

final class PhotosFullMembershipTests: XCTestCase, @unchecked Sendable {
    func testFullRealLibraryCountEnumeratesEveryLightweightRecordOffMain() async throws {
        let count = 80_708
        let probe = MembershipProbe()
        let range = PhotosBatchRange(entireSelection: count)
        let recorder = PhotosBatchProgressRecorder()
        let membership = try await Task.detached {
            try PhotosReviewMembership.read(inventory: ProbedInventory(count: count, probe: probe),
                                          range: range, recorder: recorder)
        }.value
        XCTAssertTrue(range.isEntireSelection)
        XCTAssertEqual(range.indices, 0..<count)
        XCTAssertEqual(range.pageCount, 1)
        XCTAssertFalse(range.hasNext)
        XCTAssertFalse(range.hasPrevious)
        XCTAssertEqual(membership.assets.count, count)
        XCTAssertEqual(membership.indicesByAssetID.count, count)
        XCTAssertEqual(membership.indicesByAssetID["asset-80707"], 80_707)
        XCTAssertEqual(membership.assets.last?.id, "asset-80707")
        XCTAssertEqual(probe.reads, count)
        XCTAssertFalse(probe.readOnMain)
    }

    func testCancellationOnFinalMetadataReadCannotReturnCompleteInventory() async throws {
        let probe = MembershipProbe()
        let task = Task.detached {
            try PhotosReviewMembership.read(inventory: ProbedInventory(count: 2_003, probe: probe, cancelAt: 2_002),
                range: PhotosBatchRange(entireSelection: 2_003), recorder: PhotosBatchProgressRecorder())
        }
        do { _ = try await task.value; XCTFail("Late cancellation must not publish membership") }
        catch is CancellationError {}
        XCTAssertEqual(probe.reads, 2_003)
    }

    func testMismatchedSnapshotAndDuplicateAssetIdentityAreRejected() async throws {
        let probe = MembershipProbe()
        do {
            _ = try PhotosReviewMembership.read(inventory: ProbedInventory(count: 2_003, probe: probe),
                range: PhotosBatchRange(entireSelection: 2_004), recorder: PhotosBatchProgressRecorder())
            XCTFail("A count from a different fetch must be refused")
        } catch PhotosLibraryError.staleSelection {}
        XCTAssertEqual(probe.reads, 0)
        do {
            _ = try PhotosReviewMembership.read(inventory: ProbedInventory(count: 2_003, probe: probe, duplicateID: true),
                range: PhotosBatchRange(entireSelection: 2_003), recorder: PhotosBatchProgressRecorder())
            XCTFail("Duplicate identity cannot represent complete membership")
        } catch PhotosLibraryError.staleSelection {}
        XCTAssertEqual(probe.reads, 2)
    }
}

@MainActor
final class PhotosFullSelectionTests: XCTestCase {
    func testExtensionlessProductionLabelsKeepInspectionControlsWithoutInventingOriginalFormats() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let prepared = try await fixture.selection()
        let session = try XCTUnwrap(prepared.mediaSession)
        let batch = try PhotosReviewBatch.prepared(folder: prepared.folder,
            snapshot: .init(id: UUID(), count: 2, title: "Test", query: .init()),
            range: .init(entireSelection: 2),
            assets: [.init(id: "asset-0", filename: "Photo 1", captureDate: nil, mediaKind: .photo),
                     .init(id: "asset-1", filename: "Video 2", captureDate: nil, mediaKind: .video)],
            decisions: [:], mediaSession: session)
        let items = try XCTUnwrap(batch.reviewItems)
        let photo = items[0]
        XCTAssertFalse(photo.isSupported, "Unknown source format is not local decode evidence")
        XCTAssertFalse(photo.isRaw)
        XCTAssertTrue(photo.supportsPhotoInspection)
        XCTAssertFalse(items[1].supportsPhotoInspection)
        let unknownLocal = PhotoItem(primaryFile: PhotoFile(id: "local-unknown",
            url: fixture.root.appendingPathComponent("Unknown.xyz"), captureDate: nil,
            cameraModel: nil, lensModel: nil, fileSize: 0), pairedFile: nil)
        XCTAssertFalse(unknownLocal.isSupported)
        XCTAssertFalse(unknownLocal.supportsPhotoInspection)
        XCTAssertEqual(photo.fileTypeLabel, MediaKind.photo.label)
        XCTAssertFalse(SessionOpeningFacets(items: items).availableTypes.contains(""))
        let before = await fixture.provider.requests
        XCTAssertTrue(before.images.isEmpty)
        XCTAssertTrue(before.originals.isEmpty)
        XCTAssertTrue(before.filenames.isEmpty)
        let store = fixture.store()
        store.items = items
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.viewMode = .gallery
        XCTAssertTrue(store.canToggleClippingWarnings)
        XCTAssertTrue(store.toggleClippingWarnings())
        await fixture.provider.setOriginalFilename("Inspected.JPG")
        let original = try await session.original(for: photo)
        XCTAssertEqual(original.item.primaryURL.lastPathComponent, "Inspected.JPG")
        XCTAssertTrue(original.item.isSupported)
        XCTAssertTrue(original.item.supportsPhotoInspection)
        XCTAssertTrue(try XCTUnwrap(store.currentItem).supportsPhotoInspection)
        XCTAssertFalse(try XCTUnwrap(store.currentItem).isSupported)
        store.beginTerminationPreparation()
    }

    func testEntireSelectionIgnoresOldBatchDefaultsMountsWithoutMediaAndRestoresLastDecision() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        fixture.defaults.set(500, forKey: "photosReview.batchSize")
        fixture.defaults.set(161, forKey: "photosReview.page")
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { store.items.count == 2_003 && !store.isFileOperationRunning }
        let batch = try XCTUnwrap(store.photosBatch)
        XCTAssertTrue(batch.range.isEntireSelection)
        XCTAssertEqual(batch.range.indices, 0..<2_003)
        XCTAssertEqual(store.visibleIndices.count, 2_003)
        XCTAssertEqual(batch.assetIDsByPath.count, 2_003)
        XCTAssertEqual(store.photosBrowser.openingSelection, .entireSelection)
        XCTAssertFalse(store.photosBrowser.allowNetwork)
        let requests = await fixture.provider.requests
        XCTAssertTrue(requests.images.isEmpty)
        XCTAssertTrue(requests.originals.isEmpty)
        XCTAssertTrue(requests.filenames.isEmpty, "Preparation must not inspect original resources for filenames")
        XCTAssertTrue(store.items.allSatisfy { !FileManager.default.fileExists(atPath: $0.primaryURL.path) })
        store.rate(.yes, at: 2_002)
        store.setStarRating(.five, at: 2_002)
        store.setColorLabel(.purple, at: 2_002)
        let save = await store.saveSessionForTermination()
        XCTAssertTrue(save?.canDiscardInMemoryState != false)
        let decision = try await fixture.decisions.load(assetIDs: ["asset-2002"])
        XCTAssertEqual(decision["asset-2002"]?.rating, .yes)
        XCTAssertEqual(decision["asset-2002"]?.stars, .five)
        XCTAssertEqual(decision["asset-2002"]?.color, .purple)
        let reopened = fixture.store()
        await reopened.photosBrowser.load()
        reopened.openPhotosSelection()
        try await wait { reopened.items.count == 2_003 && !reopened.isFileOperationRunning }
        let restored = try XCTUnwrap(reopened.items.first { $0.id == "photos:asset-2002" })
        XCTAssertEqual(restored.rating, .yes)
        XCTAssertEqual(restored.primaryFile.starRating, .five)
        XCTAssertEqual(restored.primaryFile.colorLabel, .purple)
    }

    func testCancellationAfterFullPreparationRetiresLateResultAndKeepsDurableOutgoingReview() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { store.items.count == 2_003 && !store.isFileOperationRunning }
        let originalFolder = try XCTUnwrap(store.sourceFolder)
        let originalSnapshot = try XCTUnwrap(store.photosBatch?.snapshot)
        store.rate(.no, at: 2_002)
        store.photosBrowser.query.newestFirst = false
        await store.photosBrowser.load()
        await fixture.library.holdNextSelection()
        store.openPhotosSelection()
        try await wait { await fixture.library.selectionIsHeld }
        store.cancelPhotosOpening()
        await fixture.library.releaseSelection()
        try await wait { !store.photosBrowser.isOpening && !store.isSessionTransitioning }
        XCTAssertEqual(store.sourceFolder, originalFolder)
        XCTAssertEqual(store.items.count, 2_003)
        XCTAssertEqual(store.items[2_002].rating, .no)
        XCTAssertNil(store.photosBrowser.failure)
        let saved = try await fixture.decisions.load(assetIDs: ["asset-2002"])
        XCTAssertEqual(saved["asset-2002"]?.rating, .no)
        let removed = await fixture.library.removedFolders
        XCTAssertEqual(removed.count, 1)
        XCTAssertNotEqual(removed.first, originalFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(removed.first).path))
        let requests = await fixture.provider.requests
        XCTAssertTrue(requests.images.isEmpty)
        XCTAssertTrue(requests.originals.isEmpty)
        store.rescan()
        try await wait { store.sourceFolder != originalFolder && store.items.count == 2_003 && !store.isFileOperationRunning }
        XCTAssertEqual(store.photosBatch?.snapshot.id, originalSnapshot.id)
        XCTAssertTrue(store.photosBatch?.range.isEntireSelection == true)
        XCTAssertEqual(store.items.first { $0.id == "photos:asset-2002" }?.rating, .no)
    }

    func testExistingRescanRoutePreservesWholePinnedSelectionAfterChooserChanges() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { store.items.count == 2_003 && !store.isFileOperationRunning }
        let originalFolder = store.sourceFolder
        let originalSnapshot = try XCTUnwrap(store.photosBatch?.snapshot)
        store.rate(.yes, at: 2_002)
        store.photosBrowser.query.newestFirst = false
        await store.photosBrowser.load()
        XCTAssertNotEqual(store.photosBrowser.snapshot?.id, originalSnapshot.id)
        store.rescan()
        try await wait { store.sourceFolder != originalFolder && store.items.count == 2_003 && !store.isFileOperationRunning }
        XCTAssertTrue(store.photosBatch?.range.isEntireSelection == true)
        XCTAssertEqual(store.photosBatch?.snapshot.id, originalSnapshot.id)
        XCTAssertEqual(store.photosBrowser.query, originalSnapshot.query)
        XCTAssertEqual(store.items.first { $0.id == "photos:asset-2002" }?.rating, .yes)
    }

    func testFailedFullSelectionDecisionSaveBlocksReplacementUntilRetry() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { store.items.count == 2_003 && !store.isFileOperationRunning }
        _ = await store.saveSessionForTermination()
        let originalFolder = store.sourceFolder
        let json = fixture.root.appendingPathComponent("Decisions/decisions.json")
        let goodBytes = try Data(contentsOf: json)
        let damagedBytes = Data("invalid decision checkpoint".utf8)
        try damagedBytes.write(to: json)
        store.rate(.yes, at: 2_002)
        store.openPhotosSelection()
        try await wait { !store.photosBrowser.isOpening }
        XCTAssertEqual(store.sourceFolder, originalFolder)
        XCTAssertEqual(store.items[2_002].rating, .yes)
        XCTAssertNotNil(store.persistenceWarning)
        let requests = await fixture.library.selectionRequests
        XCTAssertEqual(requests, 1, "Failed save must block preparation, not just publication")
        XCTAssertEqual(try Data(contentsOf: json), damagedBytes)
        try goodBytes.write(to: json)
        store.retryPersistence()
        try await wait { store.persistenceWarning == nil }
        store.openPhotosSelection()
        try await wait { store.sourceFolder != originalFolder && store.items.count == 2_003 && !store.isFileOperationRunning }
        XCTAssertEqual(store.items.first { $0.id == "photos:asset-2002" }?.rating, .yes)
    }

    func testClampedClientResultCannotReplaceCompleteAuthoritativeMembership() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await wait { store.items.count == 2_003 && !store.isFileOperationRunning }
        let originalFolder = store.sourceFolder
        store.rate(.yes, at: 2_002)
        await fixture.library.returnClampedSelection()
        store.openPhotosSelection()
        try await wait { !store.photosBrowser.isOpening }
        XCTAssertEqual(store.sourceFolder, originalFolder)
        XCTAssertEqual(store.items.count, 2_003)
        XCTAssertEqual(store.items[2_002].rating, .yes)
        XCTAssertNotNil(store.photosBrowser.failure)
        let removed = await fixture.library.removedFolders
        XCTAssertEqual(removed.count, 1)
        let saved = try await fixture.decisions.load(assetIDs: ["asset-2002"])
        XCTAssertEqual(saved["asset-2002"]?.rating, .yes)
    }

    func testOriginalNameIsResolvedOnlyOnExplicitOriginalRequestAndCopyUsesIt() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let batch = try await fixture.selection()
        let session = try XCTUnwrap(batch.mediaSession)
        let item = try XCTUnwrap(batch.reviewItems?.last)
        await fixture.provider.setOriginalFilename("Camera original.dng")
        let before = await fixture.provider.requests
        XCTAssertTrue(before.filenames.isEmpty)
        let result = await PhotosCopyWorker.copy([item], sourceFolder: batch.folder,
            destination: fixture.destination, binding: try DurableFileIO.DirectoryBinding(url: fixture.destination),
            journalDirectory: fixture.journals, cancelFlag: ExportWorker.CancelFlag(), progress: { _, _ in })
        XCTAssertEqual(result.copiedFiles, 1, result.failureMessage ?? "")
        let copied = fixture.destination.appendingPathComponent("Camera original.dng")
        XCTAssertEqual(try Data(contentsOf: copied), MockPhotosMedia.originalBytes("asset-2002"))
        let after = await fixture.provider.requests
        XCTAssertEqual(after.filenames, ["asset-2002"])
        XCTAssertEqual(after.originals, ["asset-2002"])
        XCTAssertTrue(after.images.isEmpty)
        let staged = await session.originalBytes
        XCTAssertEqual(staged, 0)
    }

    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await predicate()) {
            if Date() > deadline { XCTFail("Timed out waiting for full Photos selection"); throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class MembershipProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onMain = false
    var reads: Int { lock.withLock { count } }
    var readOnMain: Bool { lock.withLock { onMain } }
    func record() { lock.withLock { count += 1; onMain = onMain || Thread.isMainThread } }
}

private struct ProbedInventory: PhotosReviewInventory {
    let count: Int
    let probe: MembershipProbe
    var cancelAt: Int? = nil
    var duplicateID = false
    func reviewAsset(at index: Int) -> PhotosReviewAsset {
        probe.record()
        if index == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
        return PhotosReviewAsset(id: "asset-\(duplicateID ? 0 : index)", filename: "Photo \(index + 1)", captureDate: nil)
    }
}
