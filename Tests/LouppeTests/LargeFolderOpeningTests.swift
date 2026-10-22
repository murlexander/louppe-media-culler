import Foundation
import XCTest
@testable import Louppe

final class LargeFolderOpeningTests: XCTestCase, @unchecked Sendable {
    func testInventoryCompletesGlobalAmbiguityBeforeAnyMetadata() throws {
        let root = try fixture(["a/SHOT.NEF", "a/SHOT.JPG", "b/SHOT.NEF", "b/SHOT.JPG", "UNIQUE.NEF", "UNIQUE.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root, pairingMode: .together)
        XCTAssertEqual(inventory.physicalFileCount, 6)
        XCTAssertEqual(inventory.items.count, 5)
        XCTAssertEqual(inventory.rawJPEGFileIDs.count, 1)
        XCTAssertEqual(inventory.items.filter { $0.pairedFile != nil }.first?.id, "UNIQUE.NEF")
        XCTAssertTrue(inventory.items.allSatisfy { !$0.primaryFile.metadataIsLoaded })
    }

    func testPendingInventoryPreservesMediaKindAndContentRevisionAfterMetadata() throws {
        let root = try fixture(["A.JPG", "B.MOV", "C.WAV", "D.txt", "PAIR.NEF", "PAIR.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root, pairingMode: .together)
        let revisions = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.id, $0.contentRevision) })
        let kinds = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.id, $0.mediaKind) })
        XCTAssertEqual(kinds["B.MOV"], .video)
        XCTAssertEqual(kinds["C.WAV"], .audio)
        XCTAssertEqual(kinds["D.txt"], .text)
        let ready = try FolderScanner.prepareMetadata(in: inventory)
        for item in ready {
            XCTAssertTrue(item.primaryFile.metadataIsLoaded)
            XCTAssertEqual(item.contentRevision, revisions[item.id])
            XCTAssertEqual(item.mediaKind, kinds[item.id])
        }
        XCTAssertFalse(try XCTUnwrap(ready.first { $0.pairedFile != nil }?.pairedFile).metadataIsLoaded)
        XCTAssertEqual(inventory.physicalPairs(in: ready).count, 1)
    }

    func testSynchronousWrapperRetainsExactPairingAndChronology() throws {
        let root = try fixture(["Z.JPG", "A.JPG", "PAIR.NEF", "PAIR.JPG", "nested/MOVIE.MOV"])
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in [RawJPEGPairingMode.separate, .together] {
            let inventory = try FolderScanner.discoverInventory(root, pairingMode: mode)
            let prepared = try FolderScanner.prepareMetadata(in: inventory)
            let synchronous = try FolderScanner.scan(root, pairingMode: mode) { _ in }
            XCTAssertEqual(prepared.map(\.id), synchronous.map(\.id))
            XCTAssertEqual(prepared.map(\.contentRevision), synchronous.map(\.contentRevision))
            XCTAssertEqual(Set(inventory.physicalPairs(in: prepared).map { $0.raw.id }), ["PAIR.NEF"])
        }
    }

    func testReplacementBeforeAndDuringMetadataNeverAdoptsNewBytes() throws {
        for duringRead in [false, true] {
            let root = try fixture(["A.JPG"])
            defer { try? FileManager.default.removeItem(at: root) }
            let inventory = try FolderScanner.discoverInventory(root)
            let url = root.appendingPathComponent("A.JPG")
            if !duringRead { try Data("replacement before read".utf8).write(to: url, options: .atomic) }
            XCTAssertThrowsError(try FolderScanner.prepareMetadata(
                in: inventory, metadataReaderForTesting: { url in
                    if !duringRead { XCTFail("replacement must fail before metadata opens") }
                    try Data("replacement during read".utf8).write(to: url, options: .atomic)
                    return MetadataExtractor.ScanInfo()
                }
            ))
            XCTAssertFalse(inventory.items[0].primaryFile.metadataIsLoaded)
        }
    }

    func testMetadataUsesBoundedWorkersAndDeterministicSlots() throws {
        let root = try fixture((0..<80).map { String(format: "%03d.JPG", $0) })
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root)
        let counter = OpeningReaderCounter()
        let items = try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { _ in
            counter.enter()
            defer { counter.leave() }
            Thread.sleep(forTimeInterval: 0.001)
            return MetadataExtractor.ScanInfo()
        })
        XCTAssertEqual(counter.snapshot().reads, 80)
        XCTAssertLessThanOrEqual(counter.snapshot().maximumActive, 8)
        XCTAssertEqual(Set(items.map(\.id)), Set(inventory.items.map(\.id)))
        XCTAssertEqual(items.map(\.id), FolderScanner.sortItems(items).map(\.id))
    }

    func testCancellationAtEveryWorkerStageReturnsNoPreparationAndNeverSaves() async throws {
        let stages = SessionOpeningStage.allCases.filter { $0 != .mainPublication }
        for stage in stages {
            let root = try fixture(["A.JPG", "PAIR.NEF", "PAIR.JPG"])
            defer { try? FileManager.default.removeItem(at: root) }
            let sidecar = root.appendingPathComponent(SessionStore.sidecarName)
            let original = Data("saved decisions must remain byte-for-byte".utf8)
            try original.write(to: sidecar)
            let persistence = OpeningPersistence()
            let entered = expectation(description: "entered \(stage)")
            let resume = DispatchSemaphore(value: 0)
            let task = Task.detached {
                try await SessionOpeningWorker.prepare(
                    folder: root, pairingMode: .together, persistence: persistence,
                    recorder: SessionOpeningRecorder(), preview: { _ in }, hooks: .init(willBeginStage: { current in
                        guard current == stage else { return }
                        entered.fulfill()
                        _ = resume.wait(timeout: .now() + 5)
                    })
                )
            }
            await fulfillment(of: [entered], timeout: 5)
            task.cancel()
            resume.signal()
            do { _ = try await task.value; XCTFail("cancelled \(stage) produced a session") }
            catch { XCTAssertTrue(error is CancellationError, "\(stage): \(error)") }
            let saves = await persistence.saveCount
            XCTAssertEqual(saves, 0)
            XCTAssertEqual(try Data(contentsOf: sidecar), original)
        }
    }

    func testCancellationInsideMetadataStopsRemainingAdmissions() throws {
        let root = try fixture((0..<120).map { "\($0).JPG" })
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = FolderScanner.CancelFlag()
        let counter = OpeningReaderCounter()
        let inventory = try FolderScanner.discoverInventory(root)
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(
            in: inventory, isCancelled: { flag.isSet }, metadataReaderForTesting: { _ in
                counter.enter()
                defer { counter.leave() }
                flag.set()
                return MetadataExtractor.ScanInfo()
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThanOrEqual(counter.snapshot().reads, 8)
    }

    func testTraversalFailureAndFinalReplacementNeverSave() async throws {
        for traversalFailure in [true, false] {
            let root = try fixture(["A.JPG"])
            defer { try? FileManager.default.removeItem(at: root) }
            let sidecar = root.appendingPathComponent(SessionStore.sidecarName)
            let original = Data("preserved previous snapshot".utf8)
            try original.write(to: sidecar)
            let persistence = OpeningPersistence()
            let hooks = SessionOpeningWorker.Hooks(
                willBeginStage: { stage in
                    if !traversalFailure, stage == .finalIdentityValidation {
                        try Data("late replacement".utf8).write(to: root.appendingPathComponent("A.JPG"), options: .atomic)
                    }
                },
                beforeEnumeratingURL: { url in
                    if traversalFailure {
                        throw FolderScanner.ScanError.unreadableFolder(url, CocoaError(.fileReadNoPermission))
                    }
                }
            )
            do {
                _ = try await Task.detached {
                    try await SessionOpeningWorker.prepare(folder: root, pairingMode: .separate,
                        persistence: persistence, recorder: SessionOpeningRecorder(), hooks: hooks)
                }.value
                XCTFail("failed opening must not produce a prepared session")
            } catch { XCTAssertFalse(error is CancellationError) }
            let saves = await persistence.saveCount
            XCTAssertEqual(saves, 0)
            XCTAssertEqual(try Data(contentsOf: sidecar), original)
        }
    }

    func testSavedPhysicalPairDecisionsStayIndependentAndOldStoreUntouched() throws {
        let root = try fixture(["PAIR.NEF", "PAIR.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try XCTUnwrap(FolderScanner.scan(root, pairingMode: .together) { _ in }.first)
        old.primaryFile.rating = .no
        let fresh = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(root, pairingMode: .together))
        let pair = try XCTUnwrap(fresh.first)
        let raw = pair.primaryFile
        let jpeg = try XCTUnwrap(pair.pairedFile)
        let session = SessionFile(version: 7, sourcePath: root.path, scannedAt: Date(), entries: [
            SessionEntry(filename: raw.id, rating: "yes", ratedAt: nil, fileIdentity: raw.scannedIdentity),
            SessionEntry(filename: jpeg.id, rating: "no", ratedAt: nil, fileIdentity: jpeg.scannedIdentity)
        ], fileIDEncoding: .percentEncodedFileSystemPath)
        let restored = try SessionOpeningRestoration.prepare(scanned: fresh, url: root,
            persistenceResult: .init(session: session, origin: nil, problems: []), replaceSavedSession: false)
        XCTAssertEqual(restored.items[0].primaryFile.rating, .yes)
        XCTAssertEqual(restored.items[0].pairedFile?.rating, .no)
        XCTAssertEqual(restored.items[0].ratingState, .mixed)
        XCTAssertEqual(old.primaryFile.rating, .no)
        XCTAssertEqual(old.pairedFile?.rating, .undecided)
    }

    func testReplacementConflictRetainsSavedDecisionAsRecovery() throws {
        let root = try fixture(["A.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try XCTUnwrap(FolderScanner.scan(root) { _ in }.first)
        let entry = SessionEntry(filename: old.id, rating: "yes", ratedAt: nil, fileIdentity: old.primaryFile.scannedIdentity)
        try Data("new physical file".utf8).write(to: root.appendingPathComponent("A.JPG"), options: .atomic)
        let fresh = try FolderScanner.scan(root) { _ in }
        let session = SessionFile(version: 7, sourcePath: root.path, scannedAt: Date(), entries: [entry], fileIDEncoding: .percentEncodedFileSystemPath)
        let restored = try SessionOpeningRestoration.prepare(scanned: fresh, url: root,
            persistenceResult: .init(session: session, origin: nil, problems: []), replaceSavedSession: false)
        XCTAssertEqual(restored.items[0].rating, .undecided)
        XCTAssertEqual(restored.sessionRecoveryEntries.count, 1)
        XCTAssertEqual(restored.sessionRecoveryEntries[0].entry.rating, "yes")
    }

    func testLegacyMissingAndRelocatedPoliciesStillRequireConfirmation() throws {
        let root = try fixture(["A.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let scanned = try FolderScanner.scan(root) { _ in }
        var legacy = SessionFile(version: 1, sourcePath: root.path, scannedAt: Date(), entries: [
            SessionEntry(filename: "A.JPG", rating: "yes", ratedAt: nil),
            SessionEntry(filename: "MISSING.JPG", rating: "no", ratedAt: nil)
        ])
        let restored = try SessionOpeningRestoration.prepare(scanned: scanned, url: root,
            persistenceResult: .init(session: legacy, origin: nil, problems: []), replaceSavedSession: false)
        XCTAssertTrue(restored.legacySessionNeedsConfirmation)
        XCTAssertEqual(restored.unmatchedLegacyPhysicalFileCount, 1)
        legacy.sourcePath = "/private/tmp/a-different-folder"
        legacy.entries.removeFirst()
        let relocated = try SessionOpeningRestoration.prepare(scanned: scanned, url: root,
            persistenceResult: .init(session: legacy, origin: nil, problems: []), replaceSavedSession: false)
        XCTAssertTrue(relocated.requiresNewSessionConfirmation)
        XCTAssertTrue(relocated.relocatedLegacySessionHasNoFilenameMatch)
    }

    func testPreviewAndEnrichmentPreserveEveryPhysicalPairMetadataField() async throws {
        let root = try fixture(["PAIR.NEF", "PAIR.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root, pairingMode: .together)
        let files = inventory.items.flatMap(\.individualFiles)
        let date = Date(timeIntervalSince1970: 1234)
        let entries = files.enumerated().map { offset, file in
            SessionEntry(filename: file.id, rating: offset == 0 ? "yes" : "no", ratedAt: date,
                         stars: offset == 0 ? .four : .two, starsChangedAt: date,
                         colorLabel: offset == 0 ? .purple : .green, colorChangedAt: date,
                         fileIdentity: file.scannedIdentity)
        }
        let saved = SessionFile(version: 7, sourcePath: root.path, scannedAt: Date(), entries: entries,
                                fileIDEncoding: .percentEncodedFileSystemPath)
        let snapshots = OpeningSnapshotRecorder()
        let prepared = try await SessionOpeningWorker.prepare(
            folder: root, pairingMode: .together, persistence: OpeningPersistence(session: saved),
            recorder: SessionOpeningRecorder(), preview: { await snapshots.append($0) },
            hooks: .init(metadataReader: { _ in .init() })
        )
        let preview = await snapshots.last
        let early = try XCTUnwrap(preview?.items.first)
        let final = try XCTUnwrap(prepared.restoration.items.first)
        XCTAssertEqual(early.ratingState, .mixed)
        XCTAssertEqual(early.metadataSnapshots, final.metadataSnapshots)
        XCTAssertEqual(early.contentRevision, final.contentRevision)
        XCTAssertEqual(final.primaryFile.starRating, .four)
        XCTAssertEqual(final.pairedFile?.starRating, .two)
        XCTAssertEqual(final.primaryFile.colorLabel, .purple)
        XCTAssertEqual(final.pairedFile?.colorLabel, .green)
        XCTAssertEqual(final.pairedFile?.ratedAt, date)
    }

    func testUnsafeCapabilitiesAndRescanSuppressPreview() async throws {
        let root = try fixture(["A.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(FolderScanner.discoverInventory(root).items.first)
        let conflictEntry = SessionEntry(filename: original.id, rating: "yes", ratedAt: nil,
                                         fileIdentity: original.primaryFile.scannedIdentity)
        try Data("new original".utf8).write(to: root.appendingPathComponent("A.JPG"), options: .atomic)
        let conflict = SessionFile(version: 7, sourcePath: root.path, scannedAt: Date(), entries: [conflictEntry],
                                   fileIDEncoding: .percentEncodedFileSystemPath)
        let legacy = SessionFile(version: 1, sourcePath: root.path, scannedAt: Date(), entries: [
            SessionEntry(filename: "MISSING.JPG", rating: "yes", ratedAt: nil)
        ])
        let cases: [(OpeningPersistence, Bool)] = [
            (OpeningPersistence(problems: [.sourceFolderChanged]), true),
            (OpeningPersistence(permitsAccess: false), true),
            (OpeningPersistence(session: legacy), true),
            (OpeningPersistence(session: conflict), true),
            (OpeningPersistence(), false)
        ]
        for (persistence, allowsPreview) in cases {
            let snapshots = OpeningSnapshotRecorder()
            _ = try await SessionOpeningWorker.prepare(
                folder: root, pairingMode: .separate, persistence: persistence,
                recorder: SessionOpeningRecorder(), allowsPreview: allowsPreview,
                preview: { await snapshots.append($0) }, hooks: .init(metadataReader: { _ in .init() })
            )
            let count = await snapshots.count
            XCTAssertEqual(count, 0)
        }
    }

    func testReplacementAfterPreviewStillFailsFinalPublication() async throws {
        for stage in [SessionOpeningStage.metadata, .finalIdentityValidation] {
            let root = try fixture(["A.JPG"])
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshots = OpeningSnapshotRecorder()
            do {
                _ = try await SessionOpeningWorker.prepare(
                    folder: root, pairingMode: .separate, persistence: OpeningPersistence(),
                    recorder: SessionOpeningRecorder(), preview: { await snapshots.append($0) },
                    hooks: .init(willBeginStage: { current in
                        if current == stage {
                            try Data("replaced after preview".utf8).write(to: root.appendingPathComponent("A.JPG"), options: .atomic)
                        }
                    })
                )
                XCTFail("replacement after preview became authoritative")
            } catch { XCTAssertFalse(error is CancellationError) }
            let count = await snapshots.count
            XCTAssertEqual(count, 1)
        }
    }

    func testProgressCoalescesWithoutRetainingEveryFileUpdate() {
        let recorder = SessionOpeningRecorder()
        for index in 0..<100_000 { recorder.progress(.metadata, completed: index, total: 100_000) }
        XCTAssertEqual(recorder.takeProgress(), SessionOpeningProgress(stage: .metadata, completed: 99_999, total: 100_000))
        XCTAssertNil(recorder.takeProgress())
    }

    private func fixture(_ names: [String]) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Louppe-Large-Opening-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("disposable \(name)".utf8).write(to: url)
        }
        return root
    }
}

private actor OpeningPersistence: SessionPersistenceClient {
    private(set) var saveCount = 0
    let session: SessionFile?
    let problems: [SessionPersistence.ReadProblem]
    let permitsAccess: Bool
    init(session: SessionFile? = nil, problems: [SessionPersistence.ReadProblem] = [], permitsAccess: Bool = true) {
        self.session = session
        self.problems = problems
        self.permitsAccess = permitsAccess
    }
    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?) async -> SessionPersistence.ReadResult {
        .init(session: session, origin: nil, problems: problems,
              access: permitsAccess ? .init(id: UUID(), folderIdentity: folderIdentity, sidecarRevision: .absent) : nil)
    }
    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        saveCount += 1
        return .savedToSidecar
    }
}

private final class OpeningReaderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var reads = 0
    func enter() {
        lock.lock()
        active += 1
        reads += 1
        maximum = max(maximum, active)
        lock.unlock()
    }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    func snapshot() -> (reads: Int, maximumActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (reads, maximum)
    }
}

private actor OpeningSnapshotRecorder {
    private var snapshots: [OpeningSessionSnapshot] = []
    func append(_ snapshot: OpeningSessionSnapshot) { snapshots.append(snapshot) }
    var last: OpeningSessionSnapshot? { snapshots.last }
    var count: Int { snapshots.count }
}
