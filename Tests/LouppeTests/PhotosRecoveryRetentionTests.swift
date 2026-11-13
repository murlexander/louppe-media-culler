import Foundation
import XCTest
@testable import Louppe

final class PhotosRecoveryRetentionTests: XCTestCase, @unchecked Sendable {
    func testStartedCompleteCopySurvivesProductionBatchRemovalWithoutPreserveCallback() async throws {
        for recordedIdentity in [false, true] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let writer = try fixture.writer()
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try writer.mark(.started, fileAt: 0)
            try FileManager.default.copyItem(at: fixture.source, to: temporary)
            if recordedIdentity { try writer.mark(.started, fileAt: 0, identityAt: temporary) }
            XCTAssertTrue(FileOperationJournal.finalize(writer, operationIsConsistent: false))
            // Crash window: the complete temporary exists but neither the staged
            // checkpoint nor the lease preserve callback ran.
            let service = PhotosLibraryService(cacheRoot: fixture.cache,
                decisionsStore: PhotosReviewDecisions(directory: fixture.root.appendingPathComponent("Decisions")),
                operationJournalDirectory: fixture.journals)
            await service.remove(fixture.batch)
            XCTAssertEqual(try? Data(contentsOf: fixture.source), fixture.bytes)
            let report = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
            XCTAssertEqual(report.unresolvedOperations, 0)
            XCTAssertEqual(report.removedPartialCopies, 0)
            XCTAssertEqual(try? Data(contentsOf: fixture.destination), fixture.bytes)
        }
    }
    func testFreshServicePrunesOnlyUnreferencedBatchesThenReclaimsAfterRetirement() async throws {
        for recordedIdentity in [false, true] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let unrelated = try fixture.extraBatch()
            let writer = try fixture.writer()
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try writer.mark(.started, fileAt: 0)
            try FileManager.default.copyItem(at: fixture.source, to: temporary)
            if recordedIdentity { try writer.mark(.started, fileAt: 0, identityAt: temporary) }
            _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
            try await fixture.service().pruneAbandonedBatches()
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.path))
            let report = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
            XCTAssertEqual(report.unresolvedOperations, 0)
            XCTAssertEqual(report.removedPartialCopies, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
            try await fixture.service().pruneAbandonedBatches()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        }
    }

    func testActualPartialRequiresRecordedOwnershipAndRetainsSourceUntilRetirement() async throws {
        for recordedIdentity in [false, true] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let writer = try fixture.writer()
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try writer.mark(.started, fileAt: 0)
            let partial = Data("partial".utf8)
            try partial.write(to: temporary)
            if recordedIdentity { try writer.mark(.started, fileAt: 0, identityAt: temporary) }
            _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
            await fixture.service().remove(fixture.batch)
            let report = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
            XCTAssertEqual(report.removedPartialCopies, recordedIdentity ? 1 : 0)
            XCTAssertEqual(report.unresolvedOperations, recordedIdentity ? 0 : 1)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
            if !recordedIdentity { XCTAssertEqual(try Data(contentsOf: temporary), partial) }
        }
    }

    func testStagedAndCompletedCopiesStillRecoverWithoutSource() throws {
        for completed in [false, true] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let writer = try fixture.writer()
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try writer.mark(.started, fileAt: 0)
            try FileManager.default.copyItem(at: fixture.source, to: temporary)
            try writer.mark(.staged, fileAt: 0, identityAt: temporary)
            if completed {
                try FileManager.default.moveItem(at: temporary, to: fixture.destination)
                try writer.mark(.completed, fileAt: 0, identityAt: fixture.destination)
            }
            _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
            try FileManager.default.removeItem(at: fixture.source)
            let report = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
            XCTAssertEqual(report.unresolvedOperations, 0)
            XCTAssertEqual(report.removedPartialCopies, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        }
    }

    func testLockedCorruptUnsupportedAndUnreadablePlansDeferEntirePass() async throws {
        for obstruction in ["locked", "corrupt", "unsupported", "unreadable"] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let unrelated = try fixture.extraBatch()
            let writer = try fixture.writer()
            if obstruction != "locked" {
                _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
                let plan = writer.token.directory.appendingPathComponent("plan.json")
                if obstruction == "corrupt" { try Data("{broken".utf8).write(to: plan) }
                if obstruction == "unsupported" {
                    var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: plan)) as? [String: Any])
                    value["version"] = 999
                    try JSONSerialization.data(withJSONObject: value).write(to: plan)
                }
                if obstruction == "unreadable" {
                    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: plan.path)
                }
            }
            await fixture.service().remove(fixture.batch)
            try await fixture.service().pruneAbandonedBatches()
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), obstruction)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes, obstruction)
            _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
        }
    }

    func testChangedSourceStillPinsBatchAndAliasesPinExactBatch() async throws {
        for alias in [false, true] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let source: URL
            if alias {
                let link = fixture.root.appendingPathComponent("Alias")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.folder)
                source = link.appendingPathComponent("Originals/lease/ORIGINAL.JPG")
            } else { source = fixture.source }
            let writer = try FileOperationJournal.start(kind: .exportCopy,
                seeds: [.init(itemID: "original", source: source, destination: fixture.destination)], directory: fixture.journals)
            _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
            try Data("changed source".utf8).write(to: fixture.source)
            await fixture.service().remove(fixture.batch)
            XCTAssertEqual(try Data(contentsOf: fixture.source), Data("changed source".utf8))
        }
    }

    func testCleanupHoldsOperationLockIncludingWithInitiallyMissingRoot() throws {
        let fixture = try PhotosRecoveryFixture()
        defer { fixture.remove() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        var entered = false
        try FileOperationJournal.withUnreferencedPhotosBatches([fixture.folder], directory: fixture.journals) { candidates in
            entered = true
            XCTAssertEqual(candidates, [fixture.folder])
            XCTAssertThrowsError(try fixture.writer()) { error in
                guard case FileOperationJournal.JournalError.operationInUse = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(entered)
        let writer = try fixture.writer()
        _ = FileOperationJournal.finalize(writer, operationIsConsistent: true)
    }

    func testUnmarkedForeignSymlinkAndOversizedOrNonregularMarkersAreNotDeleted() async throws {
        let fixture = try PhotosRecoveryFixture()
        defer { fixture.remove() }
        let fm = FileManager.default
        let foreign = fixture.root.appendingPathComponent("Foreign")
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        let evidence = foreign.appendingPathComponent("keep")
        try fixture.bytes.write(to: evidence)
        let link = fixture.cache.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: foreign)
        let unmarked = fixture.cache.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: unmarked, withIntermediateDirectories: true)
        let oversized = try fixture.extraBatch()
        try Data(repeating: 0, count: 1024).write(to: oversized.appendingPathComponent(".louppe-photos-batch"))
        let nonregular = try fixture.extraBatch()
        let marker = nonregular.appendingPathComponent(".louppe-photos-batch")
        try fm.removeItem(at: marker)
        try fm.createSymbolicLink(at: marker, withDestinationURL: fixture.folder.appendingPathComponent(".louppe-photos-batch"))
        await fixture.service().remove(.init(folder: foreign, snapshot: fixture.batch.snapshot,
            range: fixture.batch.range, assetIDsByPath: [:], decisions: [:], captureDatesByPath: [:]))
        try await fixture.service().pruneAbandonedBatches()
        for folder in [foreign, link, unmarked, oversized, nonregular] { XCTAssertTrue(fm.fileExists(atPath: folder.path)) }
        XCTAssertEqual(try Data(contentsOf: evidence), fixture.bytes)
    }

    func testRedirectedRootOrCandidateCannotFollowForeignTree() throws {
        for redirectRoot in [false, true] {
            let fixture = try PhotosRecoveryFixture()
            defer { fixture.remove() }
            let fm = FileManager.default
            let foreign = fixture.root.appendingPathComponent("Foreign")
            try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
            let evidence = foreign.appendingPathComponent("keep")
            try fixture.bytes.write(to: evidence)
            PhotosBatchCleanup.remove([fixture.folder], cacheRoot: fixture.cache,
                                      operationJournalDirectory: fixture.journals) {
                XCTAssertThrowsError(try fixture.writer()) { error in
                    guard case FileOperationJournal.JournalError.operationInUse = error else { return XCTFail("\(error)") }
                }
                // Swap after the final path check, immediately before removal.
                let target = redirectRoot ? fixture.cache : fixture.folder
                try fm.moveItem(at: target, to: fixture.root.appendingPathComponent("Retained"))
                try fm.createSymbolicLink(at: target, withDestinationURL: foreign)
            }
            XCTAssertEqual(try Data(contentsOf: evidence), fixture.bytes)
        }
    }

}

struct PhotosRecoveryFixture {
    let root: URL
    let cache: URL
    let folder: URL
    let source: URL
    let destination: URL
    let journals: URL
    let bytes = Data("exact original bytes for started Copy".utf8)
    var batch: PhotosReviewBatch {
        PhotosReviewBatch(folder: folder,
            snapshot: .init(id: UUID(), count: 1, title: "Disposable Photos", query: .init()),
            range: .init(entireSelection: 1), assetIDsByPath: [:], decisions: [:], captureDatesByPath: [:])
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosRecovery-\(UUID())")
        cache = root.appendingPathComponent("Cache")
        folder = cache.appendingPathComponent(UUID().uuidString)
        source = folder.appendingPathComponent("Originals/lease/ORIGINAL.JPG")
        destination = root.appendingPathComponent("Export/COPY.JPG")
        journals = root.appendingPathComponent("Operations")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("louppe-photos-review-v1".utf8).write(to: folder.appendingPathComponent(".louppe-photos-batch"))
        try bytes.write(to: source)
    }
    func writer() throws -> FileOperationJournal.Writer {
        try FileOperationJournal.start(kind: .exportCopy,
            seeds: [.init(itemID: "original", source: source, destination: destination)], directory: journals)
    }
    func service() -> PhotosLibraryService {
        PhotosLibraryService(cacheRoot: cache,
            decisionsStore: PhotosReviewDecisions(directory: root.appendingPathComponent("Decisions")),
            operationJournalDirectory: journals)
    }
    func extraBatch() throws -> URL {
        let extra = cache.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("louppe-photos-review-v1".utf8).write(to: extra.appendingPathComponent(".louppe-photos-batch"))
        return extra
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class PhotosRecoverySessionTests: XCTestCase {
    func testActiveCopyBlocksSwitchButUnresolvedRecoveryRetainsSourceWhenSwitchAllowed() async throws {
        let fixture = try PhotosRecoveryFixture()
        defer { fixture.remove() }
        let defaultsName = "PhotosRecovery.Session.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let library = RecoveryPhotosClient(fixture: fixture)
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("Backup")),
            photosDecisions: PhotosReviewDecisions(directory: fixture.root.appendingPathComponent("Decisions")),
            photosLibrary: library, operationJournalDirectory: fixture.journals, reviewDefaults: defaults)
        await store.photosBrowser.load()
        store.openPhotosSelection()
        try await settle { store.photosBatch != nil && !store.isFileOperationRunning }
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        store.openFolder(fixture.destination.deletingLastPathComponent())
        XCTAssertNotNil(store.photosBatch, "Active Copy keeps the source mounted")
        let writer = try fixture.writer()
        let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
        try writer.mark(.started, fileAt: 0)
        try Data("unknown partial".utf8).write(to: temporary)
        _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: true)
        try await settle { store.recoveryNeedsAttention && !store.isFileOperationRunning }
        store.openFolder(fixture.destination.deletingLastPathComponent())
        try await settle { store.photosBatch == nil && !store.isFileOperationRunning && !store.isSessionTransitioning }
        await library.removed()
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: temporary), Data("unknown partial".utf8))
        XCTAssertTrue(store.recoveryNeedsAttention)
    }

    func testExportManagerPhotosCopyUsesInjectedOperationsRoot() async throws {
        let fixture = try PhotosRecoveryFixture()
        defer { fixture.remove() }
        let provider = MockPhotosMedia()
        let session = PhotosMediaSession(provider: provider, folder: fixture.folder)
        let batch = try PhotosReviewBatch.prepared(folder: fixture.folder, snapshot: fixture.batch.snapshot,
            range: fixture.batch.range, assets: [.init(id: "asset-0", filename: "Photo.raw", captureDate: nil)],
            decisions: [:], mediaSession: session)
        // A sentinel pending journal makes the injected root observably refuse
        // new work. The old branch is verified by source only: running it would
        // inspect the real default Operations store.
        let writer = try fixture.writer()
        _ = FileOperationJournal.finalize(writer, operationIsConsistent: false)
        let manager = ExportManager(chooseDestination: { _ in fixture.destination.deletingLastPathComponent() },
                                    journalDirectory: fixture.journals)
        let finished = expectation(description: "Photos Copy finished")
        var needsRecovery = false
        manager.promptDestinationAndExport(sourceFolder: fixture.folder,
            selected: try XCTUnwrap(batch.reviewItems), familyContextItems: try XCTUnwrap(batch.reviewItems),
            sessionGeneration: 0, mode: .copy, includeXMP: false, xmpProfile: .universal,
            visibleDecisionKeywords: false, allowExternalLabelReplacement: false,
            onOperationWillStart: { _ in true }, onOperationDidFinish: { _, _, recovery, _ in
                needsRecovery = recovery; finished.fulfill()
            })
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertTrue(needsRecovery)
        XCTAssertTrue(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.deletingLastPathComponent().appendingPathComponent("Photo.raw").path))
        manager.reset()
        await session.stop()
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            await Task.yield()
        }
    }
}

private actor RecoveryPhotosClient: PhotosLibraryClient {
    let fixture: PhotosRecoveryFixture
    private var didRemove = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(fixture: PhotosRecoveryFixture) { self.fixture = fixture }
    func authorize() {}
    func albums() -> [PhotosLibraryAlbum] { [] }
    func select(_ query: PhotosLibraryQuery) -> PhotosLibrarySnapshot { fixture.batch.snapshot }
    func prepare(snapshot: PhotosLibrarySnapshot, page: Int, size: Int, allowNetwork: Bool,
                 recorder: PhotosBatchProgressRecorder) throws -> PhotosReviewBatch { try prepared(snapshot) }
    func prepareSelection(snapshot: PhotosLibrarySnapshot, allowNetwork: Bool,
                          recorder: PhotosBatchProgressRecorder) throws -> PhotosReviewBatch { try prepared(snapshot) }
    private func prepared(_ snapshot: PhotosLibrarySnapshot) throws -> PhotosReviewBatch {
        try PhotosReviewBatch.prepared(folder: fixture.folder, snapshot: snapshot, range: fixture.batch.range,
            assets: [.init(id: "asset-0", filename: "Photo.raw", captureDate: nil)], decisions: [:],
            mediaSession: PhotosMediaSession(provider: MockPhotosMedia(), folder: fixture.folder))
    }
    func remove(_ batch: PhotosReviewBatch) async {
        await fixture.service().remove(batch)
        didRemove = true
        continuation?.resume(); continuation = nil
    }
    func removed() async {
        if !didRemove { await withCheckedContinuation { continuation = $0 } }
    }
}
