import XCTest
import CryptoKit
@testable import Louppe

/// The save that follows a newly proven fingerprint waits for the next rating
/// save instead of writing the sidecar a second time (C-1).
@MainActor
final class FingerprintSaveCoalescingTests: XCTestCase {
    private struct Fixture {
        let photos: URL
        let backups: URL
        var a: URL { photos.appendingPathComponent("A.png") }
        var sidecar: URL { photos.appendingPathComponent(SessionConstants.sidecarName) }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-FingerprintSave-\(UUID())")
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let icons = URL(fileURLWithPath: "Packaging/AppIcon/AppIcon.iconset")
        try Data(contentsOf: icons.appendingPathComponent("icon_32x32.png"))
            .write(to: photos.appendingPathComponent("A.png"))
        try Data(contentsOf: icons.appendingPathComponent("icon_16x16.png"))
            .write(to: photos.appendingPathComponent("B.png"))
        return Fixture(photos: photos, backups: root.appendingPathComponent("Backups"))
    }

    /// Holds the first fingerprint until released, so the rating's own save
    /// lands first, as with a large photo.
    private func store(_ f: Fixture, persistence: CountingPersistence, gate: FirstVerificationGate,
                       checkpointDelay: TimeInterval) -> SessionStore {
        SessionStore(persistence: persistence, saveTrailingDelay: 0.05, saveMaximumDelay: 60,
                     contentCheckpointDelay: checkpointDelay,
                     sessionContentVerification: { file, proof in
                         await gate.enter()
                         return try SessionContentVerifier.verify(file, knownProof: proof)
                     })
    }

    private func wait(_ condition: () async -> Bool, file: StaticString = #filePath,
                      line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let met = await condition()
        XCTAssertTrue(met, file: file, line: line)
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func entry(_ name: String, in session: SessionFile?) -> SessionEntry? {
        session?.entries.first { $0.filename == name }
    }

    /// Opens the folder, rates A, lets that save land, then finishes A's
    /// fingerprint. Returns the number of writes before the rating.
    private func rateAndProve(_ session: SessionStore, _ f: Fixture, persistence: CountingPersistence,
                              gate: FirstVerificationGate) async throws -> Int {
        session.openFolder(f.photos)
        try await wait { if case .ready = session.phase { return true }; return false }
        try await wait { session.sessionContentCheck == .finished }
        _ = await session.waitForPersistenceIdleForTesting()
        let base = await persistence.count
        let index = try XCTUnwrap(session.items.firstIndex { $0.primaryURL.lastPathComponent == "A.png" })
        session.rate(.yes, at: index)
        try await wait { await persistence.count == base + 1 }
        _ = await session.waitForPersistenceIdleForTesting()
        let ratingSave = await persistence.last
        XCTAssertNil(entry("A.png", in: ratingSave)?.contentSHA256)
        await gate.release()
        try await wait { session.sessionContentCheck == .finished && session.contentCheckpointIsPendingForTesting }
        return base
    }

    func testRatingWithinDelayCarriesFingerprintInOneSave() async throws {
        let f = try fixture()
        let persistence = CountingPersistence(backups: f.backups)
        let gate = FirstVerificationGate()
        let session = store(f, persistence: persistence, gate: gate, checkpointDelay: 60)
        defer { session.beginTerminationPreparation() }
        let base = try await rateAndProve(session, f, persistence: persistence, gate: gate)

        // Today's checkpoint would have written within one trailing delay.
        try await Task.sleep(for: .milliseconds(300))
        let afterProof = await persistence.count
        XCTAssertEqual(afterProof, base + 1, "The fingerprint waits for the next rating save")

        let b = try XCTUnwrap(session.items.firstIndex { $0.primaryURL.lastPathComponent == "B.png" })
        session.rate(.no, at: b)
        try await wait { await persistence.count == base + 2 }
        _ = await session.waitForPersistenceIdleForTesting()
        let saved = await persistence.last
        XCTAssertEqual(entry("A.png", in: saved)?.contentSHA256, try hash(f.a))
        XCTAssertEqual(entry("A.png", in: saved)?.rating, Rating.yes.rawValue)
        XCTAssertEqual(entry("B.png", in: saved)?.rating, Rating.no.rawValue)
        try await Task.sleep(for: .milliseconds(300))
        let total = await persistence.count
        XCTAssertEqual(total, base + 2, "One save carries the rating and the fingerprint")
    }

    func testFingerprintSavesOnceAfterDelayWithoutAnotherRating() async throws {
        let f = try fixture()
        let persistence = CountingPersistence(backups: f.backups)
        let gate = FirstVerificationGate()
        let session = store(f, persistence: persistence, gate: gate, checkpointDelay: 0.4)
        defer { session.beginTerminationPreparation() }
        let base = try await rateAndProve(session, f, persistence: persistence, gate: gate)

        try await wait { await persistence.count == base + 2 }
        _ = await session.waitForPersistenceIdleForTesting()
        XCTAssertFalse(session.contentCheckpointIsPendingForTesting)
        let checkpoint = await persistence.last
        XCTAssertEqual(entry("A.png", in: checkpoint)?.contentSHA256, try hash(f.a))
        try await Task.sleep(for: .milliseconds(600))
        let total = await persistence.count
        XCTAssertEqual(total, base + 2)
    }

    func testQuitDuringDelayPersistsFingerprint() async throws {
        let f = try fixture()
        let persistence = CountingPersistence(backups: f.backups)
        let gate = FirstVerificationGate()
        let session = store(f, persistence: persistence, gate: gate, checkpointDelay: 60)
        let base = try await rateAndProve(session, f, persistence: persistence, gate: gate)

        session.beginTerminationPreparation()
        let result = await session.saveSessionForTermination()
        XCTAssertEqual(result, .savedToSidecar)
        let total = await persistence.count
        XCTAssertEqual(total, base + 2)
        XCTAssertEqual(entry("A.png", in: try read(f))?.contentSHA256, try hash(f.a))
    }

    func testCloseFolderDuringDelayPersistsFingerprint() async throws {
        let f = try fixture()
        let persistence = CountingPersistence(backups: f.backups)
        let gate = FirstVerificationGate()
        let session = store(f, persistence: persistence, gate: gate, checkpointDelay: 60)
        defer { session.beginTerminationPreparation() }
        _ = try await rateAndProve(session, f, persistence: persistence, gate: gate)

        session.closeSession()
        try await wait { if case .welcome = session.phase { return true }; return false }
        XCTAssertFalse(session.contentCheckpointIsPendingForTesting)
        XCTAssertEqual(entry("A.png", in: try read(f))?.contentSHA256, try hash(f.a))
    }

    func testQuitWhileContentRunIsInProgressPersistsAlreadyAppliedProofs() async throws {
        try await quitDuringContentRun(capturesBeforeQuit: false)
    }

    func testSaveDuringContentRunClearsCheckpointAndQuitDoesNotWriteAgain() async throws {
        try await quitDuringContentRun(capturesBeforeQuit: true)
    }

    private func quitDuringContentRun(capturesBeforeQuit: Bool) async throws {
        let f = try fixture()
        let persistence = CountingPersistence(backups: f.backups)
        let gate = BatchVerificationGate()
        addTeardownBlock { await gate.releaseAll() }
        let session = SessionStore(persistence: persistence, saveTrailingDelay: 0.05, saveMaximumDelay: 60,
            contentCheckpointDelay: 60, sessionContentVerification: { file, proof in
                await gate.enter(file.id)
                let result = Result { try SessionContentVerifier.verify(file, knownProof: proof) }
                await gate.finished()
                return try result.get()
            })
        defer { session.beginTerminationPreparation() }
        session.openFolder(f.photos)
        try await wait { if case .ready = session.phase { return true }; return false }
        try await wait { session.sessionContentCheck == .finished }
        _ = await session.waitForPersistenceIdleForTesting()
        let base = await persistence.count
        session.selectAllVisible()
        session.rate(.yes)
        try await wait { await persistence.count == base + 1 }
        _ = await session.waitForPersistenceIdleForTesting()
        await gate.release("A.png")
        try await wait { session.contentResultsNeedCheckpointForTesting }
        XCTAssertEqual(session.sessionContentCheck, .checking(done: 1, total: 2))
        XCTAssertFalse(session.contentCheckpointIsPendingForTesting, "The run has not scheduled its checkpoint yet")
        if capturesBeforeQuit {
            session.saveSession()
            _ = await session.waitForPersistenceIdleForTesting()
            XCTAssertFalse(session.contentResultsNeedCheckpointForTesting)
        }
        session.beginTerminationPreparation()
        let result = await session.saveSessionForTermination()
        XCTAssertEqual(result, capturesBeforeQuit ? nil : .savedToSidecar)
        XCTAssertFalse(session.contentResultsNeedCheckpointForTesting)
        let total = await persistence.count
        XCTAssertEqual(total, base + 2, "A proof captured before Quit needs no duplicate write")
        let saved = try read(f)
        XCTAssertEqual(entry("A.png", in: saved)?.contentSHA256, try hash(f.a))
        XCTAssertNil(entry("B.png", in: saved)?.contentSHA256)
        await gate.releaseAll()
        try await wait { await gate.completed == 2 }
    }

    private func read(_ f: Fixture) throws -> SessionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFile.self, from: Data(contentsOf: f.sidecar))
    }
}

private actor CountingPersistence: SessionPersistenceClient {
    private let base: SessionPersistence
    private var saved: [SessionFile] = []

    init(backups: URL) { base = SessionPersistence(backupDirectory: backups) }

    var count: Int { saved.count }
    var last: SessionFile? { saved.last }

    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        saved.append(session)
        return await base.save(session, for: folder, sequence: sequence, access: access)
    }

    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?
    ) async -> SessionPersistence.ReadResult {
        await base.read(for: folder, folderIdentity: folderIdentity,
                        legacySidecarRelocationAuthorization: legacySidecarRelocationAuthorization)
    }
}

private actor FirstVerificationGate {
    private var calls = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func enter() async {
        calls += 1
        guard calls == 1, !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor BatchVerificationGate {
    private var released: Set<String> = []
    private var allReleased = false
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var completed = 0

    func enter(_ id: String) async {
        guard !allReleased, !released.contains(id) else { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func release(_ id: String) {
        released.insert(id)
        waiters.removeValue(forKey: id)?.resume()
    }

    func releaseAll() {
        allReleased = true
        for waiter in waiters.values { waiter.resume() }
        waiters = [:]
    }

    func finished() { completed += 1 }
}
