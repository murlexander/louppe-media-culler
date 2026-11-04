import Foundation
import XCTest
@testable import Louppe

@MainActor
final class ProgressiveOpeningMetadataTests: XCTestCase {
    func testOneSafeItemPublishesWhileUnrelatedMetadataStillWaits() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let opening = OpeningSessionState(snapshot: .init(items: inventory.items), viewMode: .gallery, sourceAccess: nil)
        let first = expectation(description: "first item's observation is ready")
        let blocked = expectation(description: "unrelated item is still loading")
        let release = DispatchSemaphore(value: 0)
        let updates = ProgressiveMetadataUpdates()
        defer { release.signal() }
        let task = Task.detached {
            try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { url in
                if url.lastPathComponent == "B.JPG" {
                    blocked.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return MetadataExtractor.scanInfo(for: url)
            }, metadataReady: { update in
                updates.append(update)
                if update.item.id == "A.JPG" { first.fulfill() }
            })
        }
        await fulfillment(of: [first, blocked], timeout: 5)
        XCTAssertEqual(updates.items.count, 1)
        XCTAssertEqual(opening.applyMetadata(updates.items), 1)
        XCTAssertEqual(opening.currentItem?.cameraModel, "Archive camera")
        XCTAssertFalse(opening.metadataIsReady(for: "B.JPG"))
        release.signal()
        _ = try await task.value
        XCTAssertEqual(updates.items.count, 2)
    }

    func testReadyDetailsArriveWithoutReorderingInventorySelectionOrViewport() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let opening = OpeningSessionState(snapshot: .init(items: inventory.items), viewMode: .grid, sourceAccess: nil)
        opening.select("B.JPG")
        opening.recordViewport(.init(surface: .grid, physicalFileID: "A.JPG", topOffset: -13))
        let handoff = opening.handoff()
        let updates = ProgressiveMetadataUpdates()
        let prepared = try FolderScanner.prepareMetadata(in: inventory,
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataReady: { updates.append($0) })
        let current = try XCTUnwrap(updates.items.first { $0.item.id == "B.JPG" })
        XCTAssertEqual(opening.applyMetadata([current]), 1)
        XCTAssertEqual(opening.readyMetadataCount, 1)
        XCTAssertTrue(opening.metadataIsReady(for: "B.JPG"))
        XCTAssertFalse(opening.metadataIsReady(for: "A.JPG"))
        XCTAssertEqual(opening.currentItem?.cameraModel, "Archive camera")
        XCTAssertEqual(opening.items.map(\.id), inventory.items.map(\.id))
        XCTAssertTrue(opening.items.allSatisfy { !$0.primaryFile.metadataIsLoaded })
        XCTAssertEqual(opening.currentIndex, 1)
        XCTAssertEqual(opening.handoff().selectedPhysicalFileIDs, handoff.selectedPhysicalFileIDs)
        XCTAssertEqual(opening.handoff().viewportReceipts, handoff.viewportReceipts)
        XCTAssertEqual(opening.applyMetadata([current]), 0)
        XCTAssertEqual(opening.applyMetadata(updates.items), 1)
        XCTAssertEqual(opening.readyMetadataCount, prepared.count)
        let detail = try XCTUnwrap(opening.currentItem)
        XCTAssertTrue(MetadataExtractor.openingFields(for: detail).contains { $0.label == "Camera" && $0.value == "Archive camera" })
        // A ready opening field list is derived from the observation, even if
        // source access disappears. It cannot secretly reread ImageIO on main.
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("B.JPG"))
        XCTAssertTrue(MetadataExtractor.openingFields(for: detail).contains { $0.value == "Archive camera" })
    }

    func testReplacementAndChangedPairMembershipUpdatesAreRejected() throws {
        let fixture = try ArchiveMetadataFixture(names: ["PAIR.RAF", "PAIR.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source, pairingMode: .together)
        let opening = OpeningSessionState(snapshot: .init(items: inventory.items), viewMode: .gallery, sourceAccess: nil)
        let prepared = try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) })
        let pair = try XCTUnwrap(prepared.first)
        XCTAssertEqual(opening.applyMetadata([.init(item: PhotoItem(primaryFile: pair.primaryFile))]), 0)
        try ArchiveMetadataFixture.jpeg(camera: "Changed camera").write(to: fixture.source.appendingPathComponent("PAIR.RAF"), options: .atomic)
        let fresh = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source, pairingMode: .together),
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) })
        XCTAssertEqual(opening.applyMetadata(fresh.map { .init(item: $0) }), 0)
        XCTAssertEqual(opening.readyMetadataCount, 0)
        XCTAssertNil(opening.currentItem?.cameraModel)
    }

    func testObservationCannotChangeRestoredDecisions() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        inventory.items[0].primaryFile.rating = .yes
        let opening = OpeningSessionState(snapshot: .init(items: inventory.items), viewMode: .gallery, sourceAccess: nil)
        let prepared = try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) })
        let ready = try XCTUnwrap(prepared.first)
        ready.primaryFile.rating = .no
        XCTAssertEqual(opening.applyMetadata([.init(item: ready)]), 0)
        XCTAssertEqual(opening.currentItem?.rating, .yes)
        XCTAssertFalse(opening.metadataIsReady(for: "A.JPG"))
    }

    func testDistantNavigationPromotesNextUnclaimedSlotWithoutDuplicateReads() async throws {
        let fixture = try ArchiveMetadataFixture(names: (0..<100).map { String(format: "%03d.JPG", $0) })
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let interest = OpeningMetadataInterest()
        let firstWorkers = expectation(description: "initial bounded workers entered")
        let workerCount = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
        firstWorkers.expectedFulfillmentCount = workerCount
        let target = expectation(description: "distant current details admitted next")
        let gate = ProgressiveMetadataReadGate(initialCount: workerCount, firstWorkers: firstWorkers, target: target)
        defer { for _ in 0..<workerCount { gate.release.signal() } }
        let task = Task.detached {
            try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { gate.read($0) }, metadataInterest: interest)
        }
        await fulfillment(of: [firstWorkers], timeout: 5)
        interest.setCurrentPhysicalFileID("099.JPG")
        gate.release.signal()
        await fulfillment(of: [target], timeout: 5)
        XCTAssertEqual(gate.startedIDs.dropFirst(workerCount).first, "099.JPG")
        for _ in 0..<workerCount { gate.release.signal() }
        let prepared = try await task.value
        XCTAssertEqual(prepared.map(\.id), FolderScanner.sortItems(prepared).map(\.id))
        XCTAssertEqual(gate.startedIDs.count, 100)
        XCTAssertEqual(Set(gate.startedIDs).count, 100)
    }

    func testCancelledMetadataUnitCannotEmitReadyObservation() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let flag = FolderScanner.CancelFlag()
        let updates = ProgressiveMetadataUpdates()
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(in: inventory, isCancelled: { flag.isSet },
            metadataReaderForTesting: { url in flag.set(); return MetadataExtractor.scanInfo(for: url) },
            metadataReady: { updates.append($0) })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(updates.items.isEmpty)
        XCTAssertFalse(inventory.items[0].primaryFile.metadataIsLoaded)
        try fixture.assertOriginalBytes()
    }

    func testWorkerSuppressesProgressiveDetailsWithoutPreviewAndNeverSavesFailedFinalScan() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let persistence = ProgressiveMetadataPersistence()
        let updates = ProgressiveMetadataUpdates()
        _ = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .separate,
            persistence: persistence, recorder: SessionOpeningRecorder(), allowsPreview: false, preview: { _ in },
            metadataReady: { updates.append($0) }, hooks: .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) }))
        XCTAssertTrue(updates.items.isEmpty)
        let index = try fixture.index()
        do {
            _ = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .separate,
                persistence: persistence, recorder: SessionOpeningRecorder(), preview: { _ in },
                metadataReady: { updates.append($0) }, hooks: .init(willBeginStage: { stage in
                    if stage == .finalIdentityValidation {
                        try Data("late source replacement".utf8).write(to: fixture.source.appendingPathComponent("A.JPG"), options: .atomic)
                    }
                }, metadataReader: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: index))
            XCTFail("partial observations must never turn a failed opening into a prepared session")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(updates.items.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.cacheURL.path))
        let saves = await persistence.saveCount
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(".louppe_session.json").path))
    }
}

private final class ProgressiveMetadataUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OpeningMetadataUpdate] = []
    var items: [OpeningMetadataUpdate] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: OpeningMetadataUpdate) { lock.lock(); values.append(value); lock.unlock() }
}

private final class ProgressiveMetadataReadGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var ids: [String] = []
    private let initialCount: Int
    private let firstWorkers: XCTestExpectation
    private let target: XCTestExpectation
    var startedIDs: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    init(initialCount: Int, firstWorkers: XCTestExpectation, target: XCTestExpectation) {
        self.initialCount = initialCount
        self.firstWorkers = firstWorkers
        self.target = target
    }
    func read(_ url: URL) -> MetadataExtractor.ScanInfo {
        lock.lock()
        ids.append(url.lastPathComponent)
        let ordinal = ids.count
        lock.unlock()
        if ordinal <= initialCount {
            firstWorkers.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        if url.lastPathComponent == "099.JPG" { target.fulfill() }
        return MetadataExtractor.scanInfo(for: url)
    }
}

private actor ProgressiveMetadataPersistence: SessionPersistenceClient {
    private(set) var saveCount = 0
    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?) async -> SessionPersistence.ReadResult {
        .init(session: nil, origin: nil, problems: [], access: .init(id: UUID(), folderIdentity: folderIdentity, sidecarRevision: .absent))
    }
    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        saveCount += 1
        return .savedToSidecar
    }
}
