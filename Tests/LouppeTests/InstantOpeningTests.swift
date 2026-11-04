import Foundation
import XCTest
@testable import Louppe

final class InstantOpeningTests: XCTestCase, @unchecked Sendable {
    func testCachedPreviewPrecedesDiscoveryAndFreshInventoryWins() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["old.JPG", "stays.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let index = try fixture.index()
        let cacheBefore = try Data(contentsOf: index.cacheURL)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("old.JPG"))
        try ArchiveMetadataFixture.jpeg(camera: "New camera").write(to: fixture.source.appendingPathComponent("new.JPG"))
        let events = InstantPreviewEvents()
        var hooks = SessionOpeningWorker.Hooks()
        hooks.metadataIndex = index
        hooks.beforeEnumeratingURL = { _ in
            XCTAssertEqual(events.snapshots.count, 1, "cached browsing must precede the first drive listing")
        }
        let result = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .separate,
            expectedPinnedIdentity: PinnedFolderIdentity(source: .capture(at: fixture.source)),
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            recorder: SessionOpeningRecorder(), preview: { events.append($0) }, hooks: hooks)
        XCTAssertEqual(events.snapshots.count, 1, "no intermediate replacement may reset browsing")
        let snapshot = try XCTUnwrap(events.snapshots.first)
        XCTAssertTrue(snapshot.isCached)
        XCTAssertEqual(Set(snapshot.items.map(\.id)), ["old.JPG", "stays.JPG"])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.rating == .undecided })
        XCTAssertEqual(Set(result.restoration.items.map(\.id)), ["new.JPG", "stays.JPG"])
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), cacheBefore, "opening adds no cache file or write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(".louppe_session.json").path))
    }

    func testCancelledCachedPublicationNeverDiscoversOrReturnsReady() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        var hooks = SessionOpeningWorker.Hooks()
        hooks.metadataIndex = try fixture.index()
        hooks.beforeEnumeratingURL = { _ in XCTFail("cancelled preview must not start discovery") }
        do {
            _ = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .separate,
                expectedPinnedIdentity: PinnedFolderIdentity(source: .capture(at: fixture.source)),
                persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
                recorder: SessionOpeningRecorder(), preview: { snapshot in
                    XCTAssertTrue(snapshot.isCached)
                    withUnsafeCurrentTask { $0?.cancel() }
                }, hooks: hooks)
            XCTFail("cancelled opening returned Ready")
        } catch { XCTAssertTrue(error is CancellationError) }
        try fixture.assertOriginalBytes()
    }

    func testMissingCacheFallsBackAndWrongFolderNeverPublishes() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        let other = try ArchiveMetadataFixture(names: [])
        defer { fixture.remove(); other.remove() }
        var hooks = SessionOpeningWorker.Hooks()
        hooks.metadataIndex = try fixture.index()
        let events = InstantPreviewEvents()
        let persistence = SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups"))
        let pin = PinnedFolderIdentity(source: try .capture(at: fixture.source))
        _ = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .separate,
            expectedPinnedIdentity: pin, persistence: persistence, recorder: SessionOpeningRecorder(),
            preview: { events.append($0) }, hooks: hooks)
        XCTAssertEqual(events.snapshots.count, 1)
        XCTAssertFalse(try XCTUnwrap(events.snapshots.first).isCached)
        do {
            _ = try await SessionOpeningWorker.prepare(folder: other.source, pairingMode: .separate,
                expectedPinnedIdentity: pin, persistence: persistence, recorder: SessionOpeningRecorder(),
                preview: { _ in XCTFail("wrong folder published") }, hooks: hooks)
            XCTFail("wrong folder accepted")
        } catch { XCTAssertTrue(error is FolderScanner.ScanError) }
    }

    @MainActor
    func testCachedPositionIsProvisionalAndInteractionRejectsReplacements() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let cached = try fixture.index().openingItems(pairingMode: .separate, isCancelled: { false })
        let opening = OpeningSessionState(snapshot: .init(items: cached, isCached: true), viewMode: .grid,
            sourceAccess: nil, initialPhysicalFileID: "B.JPG")
        XCTAssertEqual(opening.currentItem?.id, "B.JPG")
        XCTAssertNil(opening.handoff().currentPhysicalFileID, "saved visual starting point is not user intent")
        opening.select("B.JPG")
        opening.recordViewport(.init(surface: .grid, physicalFileID: "B.JPG", topOffset: -12))
        let fresh = try FolderScanner.discoverInventory(fixture.source).items
        XCTAssertEqual(opening.handoff(validatedItems: fresh).currentPhysicalFileID, "B.JPG")
        try ArchiveMetadataFixture.jpeg(camera: "Replacement").write(to: fixture.source.appendingPathComponent("B.JPG"), options: .atomic)
        let changed = try FolderScanner.discoverInventory(fixture.source).items
        let handoff = opening.handoff(validatedItems: changed)
        XCTAssertNil(handoff.currentPhysicalFileID)
        XCTAssertTrue(handoff.selectedPhysicalFileIDs.isEmpty)
        XCTAssertTrue(handoff.viewportReceipts.isEmpty)
    }

    @MainActor
    func testStoreKeepsCachedBrowsingOutsideMutationAuthority() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let suite = "Louppe-Instant-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            reviewDefaults: defaults)
        let entered = expectation(description: "discovery waits after cached publication")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); store.cancelScan() }
        store.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
            if stage == .discovery {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
        }, metadataIndex: try fixture.index())
        store.openFolder(fixture.source, expectedPinnedIdentity: .init(source: try .capture(at: fixture.source)))
        await fulfillment(of: [entered], timeout: 5)
        let opening = try XCTUnwrap(store.openingSession)
        XCTAssertTrue(opening.isCached)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.canRate)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canRenameSource)
        XCTAssertFalse(store.canCleanUp)
        opening.select("B.JPG")
        store.rate(.yes)
        release.signal()
        for _ in 0..<500 {
            if case .ready = store.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready = store.phase else { return XCTFail("opening failed: \(store.scanError ?? "unknown")") }
        XCTAssertEqual(store.currentItem?.id, "B.JPG")
        XCTAssertEqual(store.currentItem?.rating, .undecided)
    }

    func testLivePinnedOpeningReadOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_INSTANT_OPEN_FOLDER"] else {
            throw XCTSkip("Opt-in read-only real-drive measurement")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-Instant-Profile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: backup) }
        let clock = ContinuousClock()
        let start = clock.now
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: folder)
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.alexandermarkin.louppe/archive-metadata-v2")
        let index = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, folderIdentity: identity, cacheDirectory: cache))
        let result = try await SessionOpeningWorker.prepare(folder: folder, pairingMode: .separate,
            expectedPinnedIdentity: .init(source: identity), persistence: SessionPersistence(backupDirectory: backup),
            recorder: SessionOpeningRecorder(), preview: { snapshot in
                print("INSTANT OPEN cached=\(snapshot.isCached) items=\(snapshot.items.count) elapsed=\(start.duration(to: clock.now))")
            }, hooks: .init(metadataIndex: index))
        print("INSTANT READY items=\(result.restoration.items.count) elapsed=\(start.duration(to: clock.now))")
    }

    func testCacheProjectionPreservesExactNamesPairingAndRejectsOutsidePaths() throws {
        let fixture = try ArchiveMetadataFixture(names: ["a b/é%.JPG", "PAIR.RAF", "PAIR.JPG"])
        defer { fixture.remove() }
        let scanned = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let cached = try fixture.index().openingItems(pairingMode: .together, isCancelled: { false })
        let expected = try FolderScanner.discoverInventory(fixture.source, pairingMode: .together).items
        XCTAssertEqual(Set(cached.map(\.id)), Set(expected.map(\.id)))
        XCTAssertEqual(cached.flatMap(\.individualFiles).count, 3)
        XCTAssertTrue(cached.allSatisfy { $0.cameraModel == "Archive camera" })
        let file = try XCTUnwrap(scanned.first).primaryFile
        let outside = ArchiveMetadataIndex.Entry(path: "/private/tmp/elsewhere.JPG",
            identity: try XCTUnwrap(file.scannedIdentity), metadata: .init(file))
        XCTAssertTrue(try FolderScanner.cachedOpeningItems([outside], root: fixture.source,
            pairingMode: .separate, isCancelled: { false }).isEmpty)
    }
}

private final class InstantPreviewEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpeningSessionSnapshot] = []
    var snapshots: [OpeningSessionSnapshot] { lock.withLock { values } }
    func append(_ value: OpeningSessionSnapshot) { lock.withLock { values.append(value) } }
}
