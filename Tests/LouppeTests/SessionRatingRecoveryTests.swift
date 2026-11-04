import XCTest
import CryptoKit
@testable import Louppe

@MainActor
final class SessionRatingRecoveryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let photos: URL
        let backups: URL
        var a: URL { photos.appendingPathComponent("A.png") }
        var sidecar: URL { photos.appendingPathComponent(SessionConstants.sidecarName) }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-Recovery-\(UUID())")
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let fixture = Fixture(root: root, photos: photos, backups: root.appendingPathComponent("Backups"))
        let source = URL(fileURLWithPath: "AppIcon/AppIcon.iconset/icon_32x32.png")
        try Data(contentsOf: source).write(to: fixture.a)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return fixture
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func entry(_ url: URL, name: String = "A.png", rating: Rating = .no,
                       fingerprint: Bool = false) throws -> SessionEntry {
        SessionEntry(filename: name, pairedFilename: nil, rating: rating.rawValue,
                     ratedAt: rating == .undecided ? nil : Date(timeIntervalSince1970: 123),
                     stars: rating == .undecided ? nil : .four,
                     colorLabel: rating == .undecided ? nil : .purple,
                     fileIdentity: try FileOperationJournal.captureIdentity(at: url),
                     contentSHA256: fingerprint ? try hash(url) : nil)
    }

    private func save(_ entries: [SessionEntry], fixture: Fixture,
                      records: [SessionRecoveryEntry]? = nil, version: Int = 7) async throws {
        let result = await SessionPersistence(backupDirectory: fixture.backups).save(
            SessionFile(version: version, sourcePath: fixture.photos.path, scannedAt: Date(),
                        entries: entries, fileIDEncoding: .percentEncodedFileSystemPath,
                        recoveryEntries: records), for: fixture.photos, sequence: 1)
        XCTAssertEqual(result, .savedToSidecar)
    }

    private func replace(_ fixture: Fixture, changed: Bool = false) throws {
        let bytes = try Data(contentsOf: fixture.a)
        try FileManager.default.moveItem(at: fixture.a, to: fixture.root.appendingPathComponent("Original.png"))
        if changed {
            try Data(contentsOf: URL(fileURLWithPath: "AppIcon/AppIcon.iconset/icon_16x16.png")).write(to: fixture.a)
        } else { try bytes.write(to: fixture.a) }
    }

    private func store(_ fixture: Fixture) -> SessionStore {
        SessionStore(persistence: SessionPersistence(backupDirectory: fixture.backups))
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func ready(_ store: SessionStore) async throws {
        try await wait { if case .ready = store.phase { return true }; return false }
    }

    private func finished(_ store: SessionStore) async throws {
        try await wait { store.sessionContentCheck == .finished }
        _ = await store.saveSessionForTermination()
        _ = await store.waitForPersistenceIdleForTesting()
    }

    private func read(_ fixture: Fixture) throws -> SessionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFile.self, from: Data(contentsOf: fixture.sidecar))
    }

    func testIdenticalCopyRestoresAllMetadataAndRetainsHistory() async throws {
        let f = try fixture()
        let old = try entry(f.a, fingerprint: true)
        let bytes = try hash(f.a)
        try await save([old], fixture: f)
        try replace(f)
        let session = store(f)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .no)
        XCTAssertEqual(session.items.first?.primaryFile.starRating, .four)
        XCTAssertEqual(session.items.first?.primaryFile.colorLabel, .purple)
        XCTAssertEqual(session.automaticallyRestoredSessionFiles, 1)
        XCTAssertTrue(session.pendingSessionRecoveryEntries.isEmpty)
        let saved = try read(f)
        XCTAssertEqual(saved.entries.first?.contentSHA256, bytes)
        XCTAssertEqual(saved.recoveryEntries?.first?.entry.fileIdentity, old.fileIdentity)
        XCTAssertEqual(saved.recoveryEntries?.first?.resolvedFileID, "A.png")
        XCTAssertEqual(try hash(f.a), bytes)
    }

    func testOlderSessionOpensAndManualRestoreSurvivesReopen() async throws {
        let f = try fixture()
        try await save([entry(f.a)], fixture: f, version: 6)
        try replace(f)
        let session = store(f)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .undecided)
        let record = try XCTUnwrap(session.pendingSessionRecoveryEntries.first)
        XCTAssertTrue(session.canRestoreSessionRecoveryEntry(record))
        XCTAssertEqual(try read(f).recoveryEntries?.first?.entry.rating, "no")
        let reopen = store(f)
        reopen.openFolder(f.photos)
        try await ready(reopen)
        try await finished(reopen)
        XCTAssertEqual(reopen.pendingSessionRecoveryEntries.count, 1)
        XCTAssertTrue(reopen.showsSessionRecoveryNotice)
        reopen.dismissSessionRecoveryNotice()
        XCTAssertFalse(reopen.showsSessionRecoveryNotice)
        XCTAssertEqual(reopen.pendingSessionRecoveryEntries.map(\.id), [record.id])
        XCTAssertEqual(try read(f).recoveryEntries?.first?.entry.rating, "no")
        reopen.isSessionRecoveryPresented = true
        XCTAssertTrue(reopen.isSessionCommandPresentationActive)
        reopen.isSessionRecoveryPresented = false
        let structuralGeneration = reopen.structuralIndexGenerationForTesting
        let pendingFiles = reopen.pendingContentFileIDsForTesting
        for key in [PhotoSort.Key.camera, .decision, .starRating, .colorLabel] {
            reopen.sort = PhotoSort(key: key, ascending: false)
            XCTAssertTrue(reopen.canRestoreSessionRecoveryEntry(record))
            XCTAssertEqual(reopen.pendingContentFileIDsForTesting, pendingFiles)
            XCTAssertEqual(reopen.structuralIndexGenerationForTesting, structuralGeneration)
        }
        reopen.restoreSessionRecoveryEntries([record.id])
        try await finished(reopen)
        XCTAssertEqual(reopen.items.first?.rating, .no)
        XCTAssertEqual(try read(f).recoveryEntries?.first?.resolvedFileID, "A.png")
    }

    func testUnratedReplacementNeedsNoAttentionAndVerifiedRatingsSurvive() async throws {
        let f = try fixture()
        let b = f.photos.appendingPathComponent("B.png")
        try Data(contentsOf: f.a).write(to: b)
        try await save([entry(f.a, rating: .undecided), entry(b, name: "B.png", rating: .yes)], fixture: f)
        try replace(f)
        let session = store(f)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        XCTAssertTrue(session.pendingSessionRecoveryEntries.isEmpty)
        XCTAssertNil(session.scanError)
        XCTAssertEqual(session.items.first { $0.id == "A.png" }?.rating, .undecided)
        XCTAssertEqual(session.items.first { $0.id == "B.png" }?.rating, .yes)
    }

    func testDifferentContentsStayUnratedAndKeepCurrentRetainsHistory() async throws {
        let f = try fixture()
        try await save([entry(f.a, fingerprint: true)], fixture: f)
        try replace(f, changed: true)
        let session = store(f)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .undecided)
        let record = try XCTUnwrap(session.pendingSessionRecoveryEntries.first)
        XCTAssertEqual(session.sessionRecoveryStatus(record), L10n.text("File contents changed"))
        session.keepCurrentSessionDecisions([record.id])
        _ = await session.saveSessionForTermination()
        _ = await session.waitForPersistenceIdleForTesting()
        XCTAssertTrue(session.pendingSessionRecoveryEntries.isEmpty)
        XCTAssertEqual(try read(f).recoveryEntries?.first?.entry.rating, "no")
        XCTAssertEqual(try read(f).entries.first?.rating, "undecided")
        XCTAssertEqual(try read(f).recoveryEntries?.first?.resolvedFileID, "A.png")
    }

    func testAlreadySavedCurrentProofStillRecoversPendingOldDecision() async throws {
        let f = try fixture()
        let old = try entry(f.a, fingerprint: true)
        try replace(f)
        try await save([entry(f.a, rating: .undecided, fingerprint: true)], fixture: f,
                       records: [SessionRecoveryEntry(entry: old)])
        let session = store(f)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .no)
        XCTAssertTrue(session.pendingSessionRecoveryEntries.isEmpty)
    }

    func testCurrentDecisionDuringBackgroundCheckIsNeverOverwritten() async throws {
        let f = try fixture()
        try await save([entry(f.a, fingerprint: true)], fixture: f)
        try replace(f)
        let gate = CheckGate()
        let session = SessionStore(persistence: SessionPersistence(backupDirectory: f.backups),
            sessionContentVerification: { file, proof in
                await gate.wait()
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        session.openFolder(f.photos)
        try await ready(session)
        session.rate(.yes, at: 0)
        await gate.release()
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .yes)
        XCTAssertEqual(session.pendingSessionRecoveryEntries.count, 1)
        let record = try XCTUnwrap(session.pendingSessionRecoveryEntries.first)
        XCTAssertFalse(session.canRestoreSessionRecoveryEntry(record))
        session.restoreSessionRecoveryEntries([record.id])
        XCTAssertEqual(session.items.first?.rating, .yes)
        _ = await session.saveSessionForTermination()
        XCTAssertEqual(try read(f).entries.first?.rating, "yes")
        XCTAssertEqual(try read(f).recoveryEntries?.first?.entry.rating, "no")
    }

    func testCanceledFolderCheckCannotRestoreIntoNextFolder() async throws {
        let f = try fixture()
        let next = try fixture()
        try await save([entry(f.a, fingerprint: true)], fixture: f)
        try replace(f)
        let gate = CheckGate()
        let session = SessionStore(persistence: SessionPersistence(backupDirectory: f.backups),
            sessionContentVerification: { file, proof in
                await gate.wait()
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        session.openFolder(f.photos)
        try await ready(session)
        session.openFolder(next.photos)
        try await wait { session.sourceFolder?.standardizedFileURL == next.photos.standardizedFileURL && !session.items.isEmpty }
        XCTAssertEqual(session.sourceFolder?.standardizedFileURL, next.photos.standardizedFileURL)
        XCTAssertNil(session.persistenceWarning)
        XCTAssertNil(session.scanError)
        XCTAssertFalse(session.isSessionTransitioning)
        await gate.release()
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .undecided)
        XCTAssertTrue(session.sessionRecoveryEntries.isEmpty)
        XCTAssertEqual(session.automaticallyRestoredSessionFiles, 0)
    }

    func testUnratedFolderDoesNotReadContentsAndNewDecisionGainsFingerprint() async throws {
        let f = try fixture()
        let counter = ReadCounter()
        let session = SessionStore(persistence: SessionPersistence(backupDirectory: f.backups),
            sessionContentVerification: { file, proof in
                await counter.record()
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        let initialReads = await counter.count
        XCTAssertEqual(initialReads, 0)
        session.rate(.yes, at: 0)
        try await finished(session)
        let reviewedReads = await counter.count
        XCTAssertEqual(reviewedReads, 1)
        XCTAssertEqual(try read(f).entries.first?.contentSHA256, try hash(f.a))
    }

    func testManualRestoreRefusesReplacementAfterScan() async throws {
        let f = try fixture()
        try await save([entry(f.a)], fixture: f, version: 6)
        try replace(f)
        let session = store(f)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        let record = try XCTUnwrap(session.pendingSessionRecoveryEntries.first)
        let bytes = try Data(contentsOf: f.a)
        try FileManager.default.moveItem(at: f.a, to: f.root.appendingPathComponent("Second.png"))
        try bytes.write(to: f.a)
        session.restoreSessionRecoveryEntries([record.id])
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .undecided)
        XCTAssertNil(session.pendingSessionRecoveryEntries.first?.resolvedFileID)
        XCTAssertEqual(session.sessionRecoveryStatus(record), L10n.text("Could not check file"))
    }

    func testPairedRecoveryKeepsIndependentDecisionsAndMixedCounts() async throws {
        let f = try fixture()
        let raw = f.photos.appendingPathComponent("PAIR.NEF")
        let jpeg = f.photos.appendingPathComponent("PAIR.JPG")
        let bytes = try Data(contentsOf: f.a)
        try bytes.write(to: raw)
        try bytes.write(to: jpeg)
        try await save([entry(raw, name: "PAIR.NEF", rating: .yes),
                        entry(jpeg, name: "PAIR.JPG", rating: .no)], fixture: f)
        try FileManager.default.moveItem(at: raw, to: f.root.appendingPathComponent("Original.NEF"))
        try bytes.write(to: raw)
        let session = store(f)
        session.setRawJPEGPairingMode(.together)
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        let record = try XCTUnwrap(session.pendingSessionRecoveryEntries.first)
        session.restoreSessionRecoveryEntries([record.id])
        try await finished(session)
        let pair = try XCTUnwrap(session.items.first { $0.pairedFile != nil })
        XCTAssertEqual(pair.primaryFile.rating, .yes)
        XCTAssertEqual(pair.pairedFile?.rating, .no)
        XCTAssertEqual(session.mixedCount, 1)
        XCTAssertEqual(try read(f).recoveryEntries?.first?.entry.rating, "yes")
    }

    func testClearAllDuringContentCheckKeepsTheExplicitClearAfterReopen() async throws {
        let f = try fixture()
        try await save([entry(f.a, fingerprint: true)], fixture: f)
        try replace(f)
        let gate = CheckGate()
        let session = SessionStore(persistence: SessionPersistence(backupDirectory: f.backups),
            sessionContentVerification: { file, proof in
                await gate.wait()
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        session.openFolder(f.photos)
        try await ready(session)
        session.rate(.yes, at: 0)
        session.clearAllRatings()
        await gate.release()
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .undecided)
        XCTAssertEqual(session.pendingSessionRecoveryEntries.count, 1)
        let reopen = store(f)
        reopen.openFolder(f.photos)
        try await ready(reopen)
        try await finished(reopen)
        XCTAssertEqual(reopen.items.first?.rating, .undecided)
        XCTAssertEqual(reopen.pendingSessionRecoveryEntries.count, 1)
    }

    func testUndoDuringContentCheckKeepsUndecidedAndRetainsHistoryAfterReopen() async throws {
        let f = try fixture()
        try await save([entry(f.a, fingerprint: true)], fixture: f)
        try replace(f)
        let gate = CheckGate()
        let session = SessionStore(persistence: SessionPersistence(backupDirectory: f.backups),
            sessionContentVerification: { file, proof in
                await gate.wait()
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        session.openFolder(f.photos)
        try await ready(session)
        session.rate(.yes, at: 0)
        session.undo()
        await gate.release()
        try await finished(session)
        XCTAssertEqual(session.items.first?.rating, .undecided)
        XCTAssertNil(session.items.first?.ratedAt, "Undo retains the original metadata snapshot")
        XCTAssertEqual(session.sessionRecoveryEntries.first?.entry.rating, "no")
        let reopen = store(f)
        reopen.openFolder(f.photos)
        try await ready(reopen)
        try await finished(reopen)
        XCTAssertEqual(reopen.items.first?.rating, .undecided)
        XCTAssertEqual(reopen.sessionRecoveryEntries.first?.entry.rating, "no")
    }

    func testReturningPhysicalOriginalRecoversHistoryAfterRenameWithoutHashing() async throws {
        let f = try fixture()
        let old = try entry(f.a)
        let renamed = f.photos.appendingPathComponent("Renamed.png")
        try FileManager.default.moveItem(at: f.a, to: renamed)
        let b = f.photos.appendingPathComponent("B.png")
        try Data(contentsOf: renamed).write(to: b)
        try await save([entry(renamed, name: "Renamed.png", rating: .undecided),
                        entry(b, name: "B.png", rating: .undecided)], fixture: f,
                       records: [SessionRecoveryEntry(entry: old)])
        let counter = ReadCounter()
        let session = SessionStore(persistence: SessionPersistence(backupDirectory: f.backups),
            sessionContentVerification: { file, proof in
                await counter.record()
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        session.openFolder(f.photos)
        try await ready(session)
        try await finished(session)
        XCTAssertEqual(session.items.first { $0.id == "Renamed.png" }?.rating, .no)
        XCTAssertEqual(session.items.first { $0.id == "B.png" }?.rating, .undecided)
        XCTAssertEqual(session.sessionRecoveryEntries.first?.resolvedFileID, "Renamed.png")
        let reads = await counter.count
        XCTAssertEqual(reads, 1, "Only the restored decision needs its later portable fingerprint")
    }

    func testVerifierRejectsReplacementAndSymlinkAndHashesEveryByte() throws {
        let f = try fixture()
        let file = PhotoFile(id: "A.png", url: f.a, captureDate: nil, cameraModel: nil,
                             lensModel: nil, fileSize: 1,
                             scannedIdentity: try FileOperationJournal.captureIdentity(at: f.a))
        XCTAssertEqual(try SessionContentVerifier.verify(file).sha256, try hash(f.a))
        try replace(f)
        XCTAssertThrowsError(try SessionContentVerifier.verify(file))
        try FileManager.default.removeItem(at: f.a)
        try FileManager.default.createSymbolicLink(at: f.a, withDestinationURL: f.root.appendingPathComponent("Original.png"))
        XCTAssertThrowsError(try SessionContentVerifier.verify(file))
    }

    func testMalformedProofAndDuplicateRecoveryIDsRejectSnapshot() async throws {
        let f = try fixture()
        var old = try entry(f.a, fingerprint: true)
        old.contentSHA256 = "not-a-digest"
        let persistence = SessionPersistence(backupDirectory: f.backups)
        var snapshot = SessionFile(version: 7, sourcePath: f.photos.path, scannedAt: Date(),
                                   entries: [old], fileIDEncoding: .percentEncodedFileSystemPath)
        var result = await persistence.save(snapshot, for: f.photos, sequence: 1)
        XCTAssertEqual(result, .rejectedInvalidSnapshot)
        old.contentSHA256 = nil
        snapshot.entries = [old]
        let record = SessionRecoveryEntry(entry: old)
        snapshot.recoveryEntries = [record, record]
        result = await persistence.save(snapshot, for: f.photos, sequence: 2)
        XCTAssertEqual(result, .rejectedInvalidSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.sidecar.path))
    }
}

private actor CheckGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        isReleased = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private actor ReadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
