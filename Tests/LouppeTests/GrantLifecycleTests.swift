import Foundation
import XCTest
@testable import Louppe

/// AUD-03 grant core: a draft (UI) lease plus independent preparation and
/// worker leases stay balanced through Back, cancellation, failure, retry,
/// revocation and dropped tasks, using real Copy workers on disposable files.
@MainActor
final class GrantLifecycleTests: XCTestCase {
    private let granted = URL(string: "file:///scope-test/unresolved/../destination/")!

    func testDraftAndWorkerLeasesBalanceAcrossBackCancelFailureAndRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ledger = GrantLedger(original: granted.absoluteString)
        let draft = SecurityScopedFolderAccess(url: granted, resourceAccess: ledger.access)
        XCTAssertEqual(ledger.active, 1)

        // Review → Back → Review: each preparation holds and ends its own lease.
        for _ in 0..<2 {
            let preparation = draft.makeIndependentAccess()
            XCTAssertEqual(ledger.active, 2)
            preparation.stop()
            XCTAssertEqual(ledger.active, 1, "Back keeps only the draft lease")
        }

        // Copy cancelled after the first staged file.
        var result = try await runCopy(fixture, draft: draft, ledger: ledger, outcome: .cancelAfterFirstStage)
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(ledger.active, 1)

        // Back → Review → Copy that fails because its destination vanished.
        draft.makeIndependentAccess().stop()
        result = try await runCopy(fixture, draft: draft, ledger: ledger, outcome: .missingDestination)
        XCTAssertGreaterThan(result.failedPhotos, 0)
        XCTAssertEqual(ledger.active, 1)

        // Retry succeeds with the same draft authority.
        result = try await runCopy(fixture, draft: draft, ledger: ledger, outcome: .succeed)
        XCTAssertEqual(result.copiedFiles, 2, result.failureMessage ?? "")
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(ledger.active, 1)

        draft.stop()
        draft.stop()
        XCTAssertEqual(ledger.active, 0)
        XCTAssertEqual(ledger.starts, ledger.stops)
        XCTAssertFalse(ledger.sawTransformedURL, "every start/stop uses the original granted URL")
        XCTAssertEqual(try Data(contentsOf: fixture.first), Data("first original".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.second), Data("second original".utf8))
    }

    /// A grant revoked mid-session refuses later starts. Refused leases never
    /// stop, while the leases that did start still end exactly once.
    func testRevokedGrantRefusesNewLeasesWithoutUnbalancedStops() {
        let ledger = GrantLedger(original: granted.absoluteString)
        let draft = SecurityScopedFolderAccess(url: granted, resourceAccess: ledger.access)
        let worker = draft.makeIndependentAccess()
        XCTAssertEqual(ledger.active, 2)
        ledger.revoke()
        let refused = draft.makeIndependentAccess()
        refused.stop()
        XCTAssertEqual(ledger.refusedStarts, 1)
        XCTAssertEqual(ledger.active, 2, "a refused start must not be stopped")
        worker.stop()
        draft.stop()
        XCTAssertEqual(ledger.active, 0)
        XCTAssertEqual(ledger.starts, ledger.stops)
    }

    /// A cancelled task that drops its lease without an explicit stop still
    /// releases it once on deinitialization; a later stop is a no-op.
    func testDroppedWorkerLeaseReleasesOnceOnDeinit() async {
        let ledger = GrantLedger(original: granted.absoluteString)
        let draft = SecurityScopedFolderAccess(url: granted, resourceAccess: ledger.access)
        var lease: SecurityScopedFolderAccess? = draft.makeIndependentAccess()
        let task = Task.detached { [lease] in
            try? await Task.sleep(for: .seconds(30))
            _ = lease
        }
        XCTAssertEqual(ledger.active, 2)
        task.cancel()
        await task.value
        lease = nil
        XCTAssertEqual(ledger.active, 1)
        draft.stop()
        XCTAssertEqual(ledger.active, 0)
        XCTAssertEqual(ledger.starts, ledger.stops)
    }

    // MARK: Helpers

    private enum CopyOutcome { case succeed, cancelAfterFirstStage, missingDestination }

    private func runCopy(
        _ fixture: GrantFixture,
        draft: SecurityScopedFolderAccess,
        ledger: GrantLedger,
        outcome: CopyOutcome
    ) async throws -> ExportWorker.CopyResult {
        let destination = fixture.root.appendingPathComponent("Copy-\(UUID().uuidString)", isDirectory: true)
        if outcome != .missingDestination {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let items = [fixture.first, fixture.second].map {
            PhotoItem(id: $0.lastPathComponent, primaryURL: $0, pairedURL: nil,
                captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1, rating: .yes)
        }
        let journals = fixture.journals
        let cancellation = ExportWorker.CancelFlag()
        let cancelAfterStage = outcome == .cancelAfterFirstStage
        let lease = draft.makeIndependentAccess()
        XCTAssertEqual(ledger.active, 2, "the worker owns its own lease while it runs")
        let worker = Task.detached {
            ExportWorker.copy(
                items, to: destination, journalDirectory: journals,
                isCancelled: { cancellation.isSet },
                cancellationReason: { cancellation.reason },
                afterStagedFile: { _ in if cancelAfterStage { cancellation.request(.userConfirmed) } },
                progress: { _, _ in }
            )
        }
        let result = await worker.value
        lease.stop()
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        return result
    }

    private func makeFixture() throws -> GrantFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeGrantLifecycle-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("FIRST.JPG")
        let second = source.appendingPathComponent("SECOND.JPG")
        try Data("first original".utf8).write(to: first)
        try Data("second original".utf8).write(to: second)
        return GrantFixture(root: root, first: first, second: second,
                            journals: root.appendingPathComponent("Journals", isDirectory: true))
    }
}

private struct GrantFixture {
    let root: URL
    let first: URL
    let second: URL
    let journals: URL
}

private final class GrantLedger: @unchecked Sendable {
    private let lock = NSLock()
    private let original: String
    private var activeCount = 0
    private var startCount = 0
    private var stopCount = 0
    private var refusedCount = 0
    private var revoked = false
    private var transformed = false

    init(original: String) { self.original = original }

    var active: Int { lock.withLock { activeCount } }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var refusedStarts: Int { lock.withLock { refusedCount } }
    var sawTransformedURL: Bool { lock.withLock { transformed } }
    func revoke() { lock.withLock { revoked = true } }

    var access: SecurityScopedResourceAccess {
        .init(start: { url in
            self.lock.withLock {
                if url.absoluteString != self.original { self.transformed = true }
                guard !self.revoked else { self.refusedCount += 1; return false }
                self.startCount += 1
                self.activeCount += 1
                return true
            }
        }, stop: { url in
            self.lock.withLock {
                if url.absoluteString != self.original { self.transformed = true }
                self.stopCount += 1
                self.activeCount -= 1
            }
        })
    }
}
