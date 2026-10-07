import Foundation
import XCTest
@testable import Louppe

private enum ScopeTestFailure: Error { case injected }

private final class ScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var recorded: [String] = []

    var active: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
    func event(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(event)
    }
    func active(for url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[url.path] ?? 0
    }
    var access: SecurityScopedResourceAccess {
        .init(start: { url in
            self.lock.lock(); defer { self.lock.unlock() }
            self.recorded.append("start")
            self.counts[url.path, default: 0] += 1
            return true
        }, stop: { url in
            self.lock.lock(); defer { self.lock.unlock() }
            self.recorded.append("stop")
            self.counts[url.path, default: 0] -= 1
        })
    }
}

@MainActor
final class SecurityScopedAccessTests: XCTestCase {
    private struct SavedEntry: Codable, Equatable {
        let path: String
        let bookmark: Data?
    }
    private let old = Data("old-bookmark".utf8)
    private let fresh = Data("fresh-bookmark".utf8)
    private let folder = URL(fileURLWithPath: "/scope-test/selected", isDirectory: true)

    func testRecentsInspectAndRefreshOnlyInsideBalancedScope() throws {
        let defaults = isolatedDefaults()
        let recorder = ScopeRecorder()
        let oldEntry = SavedEntry(path: "/scope-test/previous", bookmark: old)
        defaults.set(try JSONEncoder().encode([oldEntry]), forKey: "recentFolderBookmarks")
        let destination = folder
        let fresh = fresh
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in
                recorder.event("resolve")
                return .init(url: destination, isStale: true)
            },
            create: { url in
                recorder.event(recorder.active(for: url) > 0 ? "create-authorized" : "create-without-scope")
                return fresh
            },
            exists: { url in
                recorder.event(recorder.active(for: url) > 0 ? "exists-authorized" : "exists-without-scope")
                return recorder.active(for: url) > 0
            },
            access: recorder.access
        )

        XCTAssertEqual(SecurityScopedFolderBookmarks.load(from: defaults, operations: operations), [folder])
        XCTAssertEqual(recorder.events, ["resolve", "start", "create-authorized", "exists-authorized", "stop"])
        XCTAssertEqual(recorder.active, 0)
        XCTAssertEqual(try stored("recentFolderBookmarks", in: defaults), [.init(path: folder.path, bookmark: fresh)])
        XCTAssertEqual(defaults.stringArray(forKey: "recentFolders"), [folder.path])
    }

    func testFailedStaleRefreshPreservesBookmarkAndUsableRecent() throws {
        let defaults = isolatedDefaults()
        let original = SavedEntry(path: folder.path, bookmark: old)
        defaults.set(try JSONEncoder().encode([original]), forKey: "recentFolderBookmarks")
        let recorder = ScopeRecorder()
        let folder = folder
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in .init(url: folder, isStale: true) },
            create: { _ in throw ScopeTestFailure.injected },
            exists: { recorder.active(for: $0) > 0 },
            access: recorder.access
        )
        XCTAssertEqual(SecurityScopedFolderBookmarks.load(from: defaults, operations: operations), [folder])
        XCTAssertEqual(try stored("recentFolderBookmarks", in: defaults), [original])
        XCTAssertEqual(recorder.active, 0)
        SecurityScopedFolderBookmarks.save([folder], to: defaults, operations: operations)
        XCTAssertEqual(try stored("recentFolderBookmarks", in: defaults), [original])
        XCTAssertEqual(recorder.active, 0)
    }

    func testFailedResolutionNeverUsesFallbackPathOrErasesRecoveryEntry() throws {
        let defaults = isolatedDefaults()
        let inaccessible = SavedEntry(path: "/scope-test/unavailable", bookmark: old)
        let encoded = try JSONEncoder().encode([inaccessible])
        defaults.set(encoded, forKey: "recentFolderBookmarks")
        defaults.set(encoded, forKey: "recoveryExportDestinations")
        let recorder = ScopeRecorder()
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in throw ScopeTestFailure.injected },
            create: { _ in Data("new".utf8) },
            exists: { _ in recorder.event("unexpected-fallback-inspection"); return true },
            access: recorder.access
        )
        XCTAssertTrue(SecurityScopedFolderBookmarks.load(from: defaults, operations: operations).isEmpty)
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "recentFolderBookmarks"), encoded)
        XCTAssertTrue(SecurityScopedFolderBookmarks.beginRecoveryDestinationAccesses(from: defaults, operations: operations).isEmpty)
        SecurityScopedFolderBookmarks.recordRecoveryDestination(folder, in: defaults, operations: operations)
        XCTAssertEqual(try stored("recoveryExportDestinations", in: defaults).last, inaccessible)
        XCTAssertEqual(recorder.active, 0)
    }

    func testMissingAndDuplicateRecentsDoNotLeakScopeOrForgetStoredEntries() throws {
        let defaults = isolatedDefaults()
        let entries = [SavedEntry(path: folder.path, bookmark: old), SavedEntry(path: folder.path, bookmark: old)]
        defaults.set(try JSONEncoder().encode(entries), forKey: "recentFolderBookmarks")
        let recorder = ScopeRecorder()
        let folder = folder
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in .init(url: folder, isStale: false) },
            create: { _ in throw ScopeTestFailure.injected },
            exists: { _ in false },
            access: recorder.access
        )
        XCTAssertTrue(SecurityScopedFolderBookmarks.load(from: defaults, operations: operations).isEmpty)
        XCTAssertEqual(try stored("recentFolderBookmarks", in: defaults), entries)
        XCTAssertEqual(recorder.events, ["start", "stop", "start", "stop"])
        XCTAssertEqual(recorder.active, 0)
    }

    func testTokenExplicitStopAndDeinitializationBalanceSuccessfulStartsOnly() {
        let recorder = ScopeRecorder()
        var token: SecurityScopedFolderAccess? = .init(url: folder, resourceAccess: recorder.access)
        XCTAssertEqual(recorder.active, 1)
        token?.stop(); token?.stop(); token = nil
        XCTAssertEqual(recorder.active, 0)
        XCTAssertEqual(recorder.events, ["start", "stop"])
        token = .init(url: folder, resourceAccess: recorder.access)
        token = nil
        XCTAssertEqual(recorder.active, 0)
        let refused = SecurityScopedResourceAccess(start: { _ in false }, stop: { _ in recorder.event("unbalanced-stop") })
        token = .init(url: folder, resourceAccess: refused)
        token?.stop(); token = nil
        XCTAssertFalse(recorder.events.contains("unbalanced-stop"))
    }

    func testFolderLeaseStartsAndStopsOriginalURLWhileKeepingStandardizedIdentity() {
        let granted = URL(string: "file:///scope-test/unresolved/../selected/")!
        let original = granted.absoluteString
        let recorder = ScopeRecorder()
        let access = SecurityScopedResourceAccess(
            start: { recorder.event("start:" + $0.absoluteString); return true },
            stop: { recorder.event("stop:" + $0.absoluteString) }
        )
        let lease = SecurityScopedFolderAccess(url: granted, resourceAccess: access)
        XCTAssertEqual(lease.url, granted.standardizedFileURL)
        lease.stop()
        XCTAssertEqual(recorder.events, ["start:" + original, "stop:" + original])
    }

    func testRecentRefreshAndSaveKeepResolvedURLAuthority() throws {
        let defaults = isolatedDefaults()
        let granted = URL(string: "file:///scope-test/unresolved/../selected/")!
        let original = granted.absoluteString
        let path = granted.standardizedFileURL.path
        defaults.set(
            try JSONEncoder().encode([SavedEntry(path: path, bookmark: old)]),
            forKey: "recentFolderBookmarks"
        )
        let recorder = ScopeRecorder()
        let fresh = fresh
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in .init(url: granted, isStale: true) },
            create: { url in
                guard url.absoluteString == original,
                      recorder.active(for: url) > 0 else {
                    recorder.event("create-without-original-authority")
                    throw ScopeTestFailure.injected
                }
                recorder.event("create-original")
                return fresh
            },
            exists: { url in
                recorder.event("inspect:" + url.absoluteString)
                return url.absoluteString == original && recorder.active(for: url) > 0
            },
            access: recorder.access
        )
        let recents = SecurityScopedFolderBookmarks.load(from: defaults, operations: operations)
        XCTAssertEqual(recents.map(\.absoluteString), [original])
        XCTAssertEqual(try stored("recentFolderBookmarks", in: defaults), [.init(path: path, bookmark: fresh)])
        SecurityScopedFolderBookmarks.save(recents, to: defaults, operations: operations)
        XCTAssertEqual(try stored("recentFolderBookmarks", in: defaults), [.init(path: path, bookmark: fresh)])
        XCTAssertEqual(recorder.active, 0)
        XCTAssertFalse(recorder.events.contains("create-without-original-authority"))
        XCTAssertEqual(recorder.events.filter { $0 == "create-original" }.count, 2)
    }

    func testRecoveryBookmarkCreationAndLeaseKeepOriginalURLAuthority() throws {
        let defaults = isolatedDefaults()
        let granted = URL(string: "file:///scope-test/unresolved/../selected/")!
        let original = granted.absoluteString
        let recorder = ScopeRecorder()
        let fresh = fresh
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in .init(url: granted, isStale: false) },
            create: { url in
                guard url.absoluteString == original else { throw ScopeTestFailure.injected }
                return fresh
            },
            exists: { _ in true },
            access: .init(
                start: { recorder.event("start:" + $0.absoluteString); return true },
                stop: { recorder.event("stop:" + $0.absoluteString) }
            )
        )
        SecurityScopedFolderBookmarks.recordRecoveryDestination(granted, in: defaults, operations: operations)
        XCTAssertEqual(try stored("recoveryExportDestinations", in: defaults), [
            .init(path: granted.standardizedFileURL.path, bookmark: fresh)
        ])
        let leases = SecurityScopedFolderBookmarks.beginRecoveryDestinationAccesses(from: defaults, operations: operations)
        XCTAssertEqual(leases.count, 1)
        leases.forEach { $0.stop() }
        XCTAssertEqual(recorder.events, [
            "start:" + original, "stop:" + original,
            "start:" + original, "stop:" + original,
            "start:" + original, "stop:" + original
        ])
    }

    func testRecoveryRefreshUsesTemporaryScopeThenHoldsIndependentLease() throws {
        let defaults = isolatedDefaults()
        defaults.set(try JSONEncoder().encode([SavedEntry(path: folder.path, bookmark: old)]), forKey: "recoveryExportDestinations")
        let recorder = ScopeRecorder()
        let folder = folder
        let fresh = fresh
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { data in .init(url: folder, isStale: data != fresh) },
            create: { _ in fresh },
            exists: { _ in true },
            access: recorder.access
        )
        let leases = SecurityScopedFolderBookmarks.beginRecoveryDestinationAccesses(from: defaults, operations: operations)
        XCTAssertEqual(try stored("recoveryExportDestinations", in: defaults), [.init(path: folder.path, bookmark: fresh)])
        XCTAssertEqual(recorder.events, ["start", "stop", "start"])
        XCTAssertEqual(recorder.active, 1)
        leases.forEach { $0.stop() }
        XCTAssertEqual(recorder.active, 0)
    }

    func testRecoveryBookmarkKeepsBoundPathAndOriginalURLAuthority() throws {
        let defaults = isolatedDefaults()
        let granted = URL(string: "file:///scope-test/unresolved/../selected/")!
        let original = granted.absoluteString
        let bound = granted.standardizedFileURL
        let recorder = ScopeRecorder()
        let recordedAccess = recorder.access
        let access = SecurityScopedResourceAccess(
            start: { url in
                guard url.absoluteString == original else {
                    recorder.event("refused-transformed-url")
                    return false
                }
                return recordedAccess.start(url)
            },
            stop: recordedAccess.stop
        )
        let fresh = fresh
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { _ in .init(url: granted, isStale: false) },
            create: { url in
                guard url.absoluteString == original, recorder.active(for: url) > 0 else {
                    throw ScopeTestFailure.injected
                }
                return fresh
            },
            exists: { _ in true },
            access: access
        )
        let lease = SecurityScopedFolderAccess(url: granted, resourceAccess: access)
        lease.recordRecoveryDestination(for: bound, in: defaults, operations: operations)
        XCTAssertEqual(try stored("recoveryExportDestinations", in: defaults), [
            .init(path: bound.path, bookmark: fresh)
        ])
        let failedRefresh = SecurityScopedFolderBookmarks.Operations(
            resolve: operations.resolve,
            create: { _ in throw ScopeTestFailure.injected },
            exists: operations.exists,
            access: access
        )
        lease.recordRecoveryDestination(for: bound, in: defaults, operations: failedRefresh)
        XCTAssertEqual(try stored("recoveryExportDestinations", in: defaults), [
            .init(path: bound.path, bookmark: fresh)
        ])
        lease.stop()
        XCTAssertEqual(recorder.active, 0)
        XCTAssertFalse(recorder.events.contains("refused-transformed-url"))
    }

    #if APP_STORE
    func testStoreRecoveryDeferralPreservesOriginalRecentURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeDeferredScope-\(UUID().uuidString)", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let via = root.appendingPathComponent("Via", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        for directory in [media, via, journals] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Disposable text preview.".utf8).write(to: media.appendingPathComponent("note.txt"))
        let pending = journals.appendingPathComponent("\(UUID().uuidString.lowercased()).operation", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        XCTAssertTrue(FileOperationJournal.hasPendingOperations(directory: journals))
        let granted = URL(string: root.absoluteString + "Via/../Media/")!
        let defaults = UserDefaults.standard
        let oldBookmarks = defaults.object(forKey: "recentFolderBookmarks")
        let oldPaths = defaults.object(forKey: "recentFolders")
        defer {
            if let oldBookmarks { defaults.set(oldBookmarks, forKey: "recentFolderBookmarks") }
            else { defaults.removeObject(forKey: "recentFolderBookmarks") }
            if let oldPaths { defaults.set(oldPaths, forKey: "recentFolders") }
            else { defaults.removeObject(forKey: "recentFolders") }
        }
        let store = SessionStore(operationJournalDirectory: journals, reviewDefaults: isolatedDefaults())
        store.openFolder(granted)
        for _ in 0..<1000 {
            if case .ready = store.phase, store.items.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready = store.phase else { return XCTFail("Recovery did not resume the selected folder") }
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.sourceFolder, granted.standardizedFileURL)
        XCTAssertEqual(store.recentFolders.first?.absoluteString, granted.absoluteString)
        store.closeSession()
        for _ in 0..<1000 {
            if case .welcome = store.phase, !store.isSessionTransitioning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isSessionTransitioning)
    }
    #endif

    private func isolatedDefaults() -> UserDefaults {
        let name = "LouppeScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func stored(_ key: String, in defaults: UserDefaults) throws -> [SavedEntry] {
        try JSONDecoder().decode([SavedEntry].self, from: XCTUnwrap(defaults.data(forKey: key)))
    }
}

private actor PreparationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

@MainActor
final class ExportScopeOwnershipTests: XCTestCase {
    private let destination = URL(fileURLWithPath: "/scope-test/route", isDirectory: true)

    func testRoutingBackAndFailedRetryKeepDraftScopeUntilDismissal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ScopeRecorder()
        let manager = ExportManager(makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) })
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: fixture.destination)
        manager.retainRoutingDestinationAccess(fixture.destination, for: route.id)
        prepare(manager, routes: [route], items: [fixture.item], source: fixture.source)
        try await eventually { if case .awaitingMultiDestinationConfirmation = manager.state { return true }; return false }
        XCTAssertEqual(recorder.active, 1)
        manager.backFromMultiDestinationConfirmation()
        XCTAssertEqual(recorder.active, 1)
        prepare(manager, routes: [route], items: [fixture.item], source: fixture.source)
        try await eventually { if case .awaitingMultiDestinationConfirmation = manager.state { return true }; return false }
        // A refused shared-operation gate returns to a retryable failure screen.
        manager.confirmMultiDestinationExport()
        XCTAssertEqual(recorder.active, 1)
        manager.reset(keepingRoutingDestinations: true)
        XCTAssertEqual(recorder.active, 1)
        manager.reset()
        XCTAssertEqual(recorder.active, 0)
    }

    func testRetargetedRoutingAliasRefusesBeforeActivatingFileWork() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let alias = fixture.root.appendingPathComponent("RouteAlias", isDirectory: true)
        let other = fixture.root.appendingPathComponent("OtherDestination", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.destination)
        let recorder = ScopeRecorder()
        let manager = ExportManager(makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) })
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: alias)
        manager.retainRoutingDestinationAccess(alias, for: route.id)
        manager.prepareMultiDestinationExport(
            routes: [route], items: [fixture.item], sourceFolder: fixture.source,
            includeXMP: false, familyContextItems: [fixture.item], sessionGeneration: 0,
            xmpProfile: .universal, visibleDecisionKeywords: false,
            allowExternalLabelReplacement: false,
            onOperationWillStart: { _ in XCTFail("A retargeted alias must not activate file work"); return true },
            onOperationDidFinish: { _, _, _, _ in XCTFail("No worker should start") }
        )
        try await eventually { if case .awaitingMultiDestinationConfirmation = manager.state { return true }; return false }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        manager.confirmMultiDestinationExport()
        guard case .failed(let message) = manager.state else { return XCTFail("Expected a destination refusal") }
        XCTAssertEqual(message, ExportDestinationValidator.ValidationError.notWritable.localizedDescription)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        manager.reset()
        XCTAssertEqual(recorder.active, 0)
    }

    func testPreparationFailureKeepsDraftScopeForRetry() async throws {
        let recorder = ScopeRecorder()
        let manager = ExportManager(
            makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) },
            prepareRoutingWork: { _ in throw ScopeTestFailure.injected }
        )
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: destination)
        manager.retainRoutingDestinationAccess(destination, for: route.id)
        prepare(manager, routes: [route])
        try await eventually { if case .failed = manager.state { return true }; return false }
        XCTAssertEqual(recorder.active, 1)
        manager.reset(keepingRoutingDestinations: true)
        prepare(manager, routes: [route])
        try await eventually { if case .failed = manager.state { return true }; return false }
        XCTAssertEqual(recorder.active, 1)
        manager.removeRoutingDestinationAccess(for: route.id)
        XCTAssertEqual(recorder.active, 0)
    }

    func testCancelledPreparationLeaseOutlivesDraftRemovalAndEndsWithTask() async throws {
        let recorder = ScopeRecorder()
        let gate = PreparationGate()
        let manager = ExportManager(
            makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) },
            prepareRoutingWork: { _ in await gate.wait(); throw ScopeTestFailure.injected }
        )
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: destination)
        manager.retainRoutingDestinationAccess(destination, for: route.id)
        prepare(manager, routes: [route])
        for _ in 0..<100 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let waiterCount = await gate.count
        XCTAssertEqual(waiterCount, 1)
        XCTAssertEqual(recorder.active, 2)
        manager.cancelMultiDestinationPreparation()
        XCTAssertEqual(recorder.active, 2)
        manager.removeRoutingDestinationAccess(for: route.id)
        XCTAssertEqual(recorder.active, 1)
        manager.reset()
        XCTAssertEqual(recorder.active, 1)
        await gate.release()
        try await eventually { recorder.active == 0 }
        XCTAssertEqual(manager.state, .summary)
    }

    func testIndependentLeaseSurvivesUIReleaseAndWorkerCancellationWithOriginalAuthority() async throws {
        let granted = URL(string: "file:///scope-test/unresolved/../selected/")!
        let original = granted.absoluteString
        let recorder = ScopeRecorder()
        let recordedAccess = recorder.access
        let access = SecurityScopedResourceAccess(
            start: { url in
                guard url.absoluteString == original else {
                    recorder.event("refused-transformed-url")
                    return false
                }
                return recordedAccess.start(url)
            },
            stop: recordedAccess.stop
        )
        let uiLease = SecurityScopedFolderAccess(url: granted, resourceAccess: access)
        let workerLease = uiLease.makeIndependentAccess()
        let gate = PreparationGate()
        let task = Task.detached { await gate.wait() }
        for _ in 0..<100 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(recorder.active, 2)
        uiLease.stop()
        task.cancel()
        XCTAssertEqual(recorder.active, 1)
        await gate.release()
        await task.value
        workerLease.stop()
        XCTAssertEqual(recorder.active, 0)
        XCTAssertEqual(recorder.events, ["start", "start", "stop", "stop"])
    }

    func testCancelledRoutingPreparationKeepsOriginalAuthorityAfterDraftRemoval() async throws {
        let granted = URL(string: "file:///scope-test/unresolved/../selected/")!
        let original = granted.absoluteString
        let recorder = ScopeRecorder()
        let recordedAccess = recorder.access
        let access = SecurityScopedResourceAccess(
            start: { url in
                guard url.absoluteString == original else {
                    recorder.event("refused-transformed-url")
                    return false
                }
                return recordedAccess.start(url)
            },
            stop: recordedAccess.stop
        )
        let gate = PreparationGate()
        let manager = ExportManager(
            makeFolderAccess: { .init(url: $0, resourceAccess: access) },
            prepareRoutingWork: { _ in await gate.wait(); throw ScopeTestFailure.injected }
        )
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: granted)
        manager.retainRoutingDestinationAccess(granted, for: route.id)
        prepare(manager, routes: [route])
        for _ in 0..<100 where await gate.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let count = await gate.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(recorder.active, 2)
        manager.cancelMultiDestinationPreparation()
        manager.removeRoutingDestinationAccess(for: route.id)
        manager.reset()
        XCTAssertEqual(recorder.active, 1)
        await gate.release()
        try await eventually { recorder.active == 0 }
        XCTAssertFalse(recorder.events.contains("refused-transformed-url"))
        XCTAssertEqual(manager.state, .summary)
    }

    func testSupersededPreparationsRetainSeparateLeasesUntilEachTaskExits() async throws {
        let recorder = ScopeRecorder()
        let gate = PreparationGate()
        let manager = ExportManager(
            makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) },
            prepareRoutingWork: { _ in await gate.wait(); throw ScopeTestFailure.injected }
        )
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: destination)
        manager.retainRoutingDestinationAccess(destination, for: route.id)
        prepare(manager, routes: [route]); prepare(manager, routes: [route])
        for _ in 0..<100 where await gate.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let waiterCount = await gate.count
        XCTAssertEqual(waiterCount, 2)
        XCTAssertEqual(recorder.active, 3)
        manager.reset()
        XCTAssertEqual(recorder.active, 2)
        await gate.release()
        try await eventually { recorder.active == 0 }
        XCTAssertEqual(manager.state, .summary)
    }

    func testReplacingAndRemovingRoutesReleaseDraftLeasesPromptly() {
        let recorder = ScopeRecorder()
        let manager = ExportManager(makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) })
        let first = UUID(), second = UUID()
        manager.retainRoutingDestinationAccess(destination, for: first)
        manager.retainRoutingDestinationAccess(destination, for: second)
        XCTAssertEqual(recorder.active, 2)
        manager.retainRoutingDestinationAccess(URL(fileURLWithPath: "/scope-test/replacement"), for: first)
        XCTAssertEqual(recorder.active(for: destination), 1)
        XCTAssertEqual(recorder.active, 2)
        manager.removeRoutingDestinationAccess(for: first)
        XCTAssertEqual(recorder.active, 1)
        manager.removeRoutingDestinationAccess(for: second)
        XCTAssertEqual(recorder.active, 0)
    }

    private func prepare(_ manager: ExportManager, routes: [MultiDestinationExportRoute], items: [PhotoItem] = [], source: URL? = nil) {
        manager.prepareMultiDestinationExport(
            routes: routes, items: items, sourceFolder: source, includeXMP: false,
            familyContextItems: items, sessionGeneration: 0, xmpProfile: .universal,
            visibleDecisionKeywords: false, allowExternalLabelReplacement: false,
            onOperationWillStart: { _ in false }, onOperationDidFinish: { _, _, _, _ in }
        )
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The asynchronous scope/state contract did not settle")
    }
    private func makeFixture() throws -> (root: URL, source: URL, destination: URL, item: PhotoItem) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeExportScope-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = source.appendingPathComponent("KEEP.JPG")
        try Data("test media".utf8).write(to: url)
        let item = PhotoItem(id: "KEEP.JPG", primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, mediaKind: .photo, fileSize: 10, rating: .yes)
        return (root, source, destination, item)
    }
}
