import Darwin
import Foundation
import XCTest
@testable import Louppe

/// Opening runs few complete identity passes: discovery capture, a preview
/// barrier, a bracket around each metadata read and one final barrier.
/// A same-path replacement of a file or a folder in any window must still
/// end without a prepared session, a sidecar write or a changed original.
final class OpeningIdentityPassTests: XCTestCase, @unchecked Sendable {
    private enum Target: CaseIterable { case file, directory }
    private enum Window: CaseIterable {
        case discovery, beforePreview, metadataMissAdmission, metadataMissRead, afterCacheHit,
             persistenceRead, derivedPreparation
    }

    // MARK: Fault injection

    func testSamePathReplacementInEveryWindowNeverPreparesASession() async throws {
        for allowsPreview in [true, false] {
            for window in Window.allCases {
                for target in Target.allCases {
                    try await assertReplacementFails(window: window, target: target, allowsPreview: allowsPreview)
                }
            }
        }
    }

    private func assertReplacementFails(window: Window, target: Target, allowsPreview: Bool) async throws {
        let context = "\(window) \(target) preview=\(allowsPreview)"
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        if window == .afterCacheHit { try await fixture.primeCache() }
        let reads = NamedReads()
        let replaced = OneShot()
        let replace: @Sendable () -> Void = {
            replaced.run {
                switch target {
                case .file: fixture.replaceFile()
                case .directory: fixture.replaceDirectory()
                }
            }
        }
        var hooks = SessionOpeningWorker.Hooks()
        hooks.metadataReader = { url in
            if window == .metadataMissRead, url.lastPathComponent == "A.JPG" { replace() }
            return reads.read(url)
        }
        hooks.metadataIndex = try fixture.index()
        switch window {
        case .discovery:
            hooks.beforeEnumeratingURL = { url in
                let name = url.lastPathComponent
                if (target == .file && name == "A.JPG") || (target == .directory && name == "empty") { replace() }
            }
        case .beforePreview:
            let stage: SessionOpeningStage = allowsPreview ? .previewIdentityValidation : .decisionRestoration
            hooks.willBeginStage = { if $0 == stage { replace() } }
        case .metadataMissAdmission:
            // A miss checks identity after its admission wait, before reading.
            hooks.willBeginStage = { if $0 == .metadata { replace() } }
        case .afterCacheHit:
            // Every file was a cache hit; no source I/O happened for them.
            hooks.willBeginStage = { if $0 == .chronologicalSort { replace() } }
        case .derivedPreparation:
            hooks.willBeginStage = { if $0 == .derivedPreparation { replace() } }
        case .metadataMissRead, .persistenceRead:
            break
        }
        let persistence = IdentityPersistence(duringRead: window == .persistenceRead ? replace : nil)
        let previews = PreviewCounter()
        do {
            _ = try await Task.detached {
                try await SessionOpeningWorker.prepare(
                    folder: fixture.source, pairingMode: .together, persistence: persistence,
                    recorder: SessionOpeningRecorder(), allowsPreview: allowsPreview,
                    preview: { _ in previews.increment() }, hooks: hooks)
            }.value
            XCTFail("replacement became a prepared session: \(context)")
        } catch {
            XCTAssertFalse(error is CancellationError, "\(context): \(error)")
        }
        XCTAssertTrue(replaced.didRun, context)
        if [.discovery, .persistenceRead, .beforePreview].contains(window) {
            XCTAssertEqual(previews.value, 0, "the preview barrier must reject it: \(context)")
        }
        if window == .afterCacheHit {
            XCTAssertEqual(reads.count(for: "A.JPG"), 0, "A.JPG must have been a cache hit: \(context)")
        }
        let saves = await persistence.saveCount
        XCTAssertEqual(saves, 0, context)
        try fixture.assertUnchanged(replacedFile: target == .file, context: context)
    }

    /// The post-Ready cache commit holds identities the final barrier
    /// verified. A replacement while it writes can never hit those entries.
    func testReplacementDuringPostReadyCommitIsRereadOnNextOpen() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let reads = NamedReads()
        var hooks = SessionOpeningWorker.Hooks(metadataReader: { reads.read($0) }, metadataIndex: try fixture.index())
        hooks.willCommitMetadataIndex = { fixture.replaceFile() }
        let first = try await SessionOpeningWorker.prepare(
            folder: fixture.source, pairingMode: .separate, persistence: IdentityPersistence(),
            recorder: SessionOpeningRecorder(), preview: { _ in }, hooks: hooks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.index().cacheURL.path),
                       "the worker itself must not write the cache")
        XCTAssertEqual(try XCTUnwrap(first.metadataCommit).run(isCancelled: { false }), true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.index().cacheURL.path))
        let before = reads.snapshot()
        let second = try await SessionOpeningWorker.prepare(
            folder: fixture.source, pairingMode: .separate, persistence: IdentityPersistence(),
            recorder: SessionOpeningRecorder(), preview: { _ in },
            hooks: .init(metadataReader: { reads.read($0) }, metadataIndex: try fixture.index()))
        XCTAssertEqual(reads.count(for: "A.JPG"), (before["A.JPG"] ?? 0) + 1, "the replaced file is read again")
        XCTAssertEqual(reads.count(for: "B.JPG"), before["B.JPG"] ?? 0, "an unchanged file stays a hit")
        let replacedFile = try XCTUnwrap(second.restoration.items.flatMap(\.individualFiles).first { $0.id == "A.JPG" })
        XCTAssertEqual(replacedFile.scannedIdentity,
                       try FileOperationJournal.captureIdentity(at: fixture.source.appendingPathComponent("A.JPG")))
        try fixture.assertUnchanged(replacedFile: true, context: "post-Ready commit")
    }

    // MARK: Volume lookup

    func testDeviceNumberReusedByAnotherVolumeFailsTheBarrier() async throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        // The device number is unchanged, but the volume behind it is another one.
        let otherVolume: FileOperationJournal.VolumeLookup.Resolver = { _ in
            (URL(fileURLWithPath: "/Volumes/Other", isDirectory: true), "00000000-0000-4000-8000-000000000000")
        }
        for allowsPreview in [true, false] {
            let persistence = IdentityPersistence()
            do {
                _ = try await SessionOpeningWorker.prepare(
                    folder: fixture.source, pairingMode: .separate, persistence: persistence,
                    recorder: SessionOpeningRecorder(), allowsPreview: allowsPreview, preview: { _ in },
                    hooks: .init(metadataReader: { _ in .init() }, volumeResolver: otherVolume))
                XCTFail("another volume behind a reused device number was accepted")
            } catch FolderScanner.ScanError.filesChangedDuringScan {
            } catch { XCTFail("unexpected \(error)") }
            let saves = await persistence.saveCount
            XCTAssertEqual(saves, 0)
        }
        try fixture.assertUnchanged(replacedFile: false, context: "reused device")
    }

    func testVolumeLookupRunsOncePerDevicePerPass() throws {
        let root = try makeFolder(files: 600, folders: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root)
        let calls = Counter()
        let live: FileOperationJournal.VolumeLookup.Resolver = { url in
            calls.increment()
            guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey]),
                  let volume = values.volume else { return nil }
            return (volume, values.volumeUUIDString)
        }
        for pass in 1...2 {
            try FolderScanner.validateScannedIdentities(inventory.items, volumes: .init(resolver: live))
            XCTAssertEqual(calls.value, pass * 2 - 1, "one lookup for one device in a fresh pass")
            try FolderScanner.validateDirectories(in: inventory, volumes: .init(resolver: live))
            XCTAssertEqual(calls.value, pass * 2)
        }
        // The default lookup gives the same identities as captureIdentity(at:).
        let lookup = FileOperationJournal.VolumeLookup()
        for file in inventory.items.flatMap(\.individualFiles).prefix(50) {
            XCTAssertEqual(try FileOperationJournal.captureIdentity(at: file.url, volumes: lookup),
                           try FileOperationJournal.captureIdentity(at: file.url))
        }
    }

    // MARK: Parallel passes

    func testParallelPassesRejectReplacementAnywhere() throws {
        let root = try makeFolder(files: 900, folders: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root)
        XCTAssertNoThrow(try FolderScanner.validateScannedIdentities(inventory.items))
        XCTAssertNoThrow(try FolderScanner.validateDirectories(in: inventory))
        let victim = inventory.items[617].primaryFile.url
        try Data("same path, new file".utf8).write(to: victim, options: .atomic)
        XCTAssertThrowsError(try FolderScanner.validateScannedIdentities(inventory.items)) {
            guard case FolderScanner.ScanError.filesChangedDuringScan = $0 else { return XCTFail("\($0)") }
        }
        let folder = root.appendingPathComponent("folder-271")
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("folder-271-old"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FolderScanner.validateDirectories(in: inventory)) {
            guard case FolderScanner.ScanError.filesChangedDuringScan = $0 else { return XCTFail("\($0)") }
        }
    }

    func testCancellationMidParallelPassStopsRemainingChecks() throws {
        let root = try makeFolder(files: 1_200, folders: 400)
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root)
        let flag = FolderScanner.CancelFlag()
        let probes = Counter()
        XCTAssertThrowsError(try FolderScanner.validateScannedIdentities(
            inventory.items, isCancelled: { flag.isSet },
            beforeIdentityProbeForTesting: { _ in if probes.increment() == 100 { flag.set() } }
        )) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // Workers poll before every file, so at most one more probe each.
        XCTAssertLessThan(probes.value, 100 + 16)

        let polls = Counter()
        XCTAssertThrowsError(try FolderScanner.validateDirectories(
            in: inventory, isCancelled: { polls.increment() > 60 })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
        XCTAssertLessThan(polls.value, inventory.directories.count)
    }

#if DEBUG
    // MARK: Identity-capture budget

    func testWarmOpenCapturesAboutTwoIdentitiesPerFile() async throws {
        let fixture = try IdentityFixture(extraFiles: 400, extraFolders: 40)
        defer { fixture.remove() }
        try await fixture.primeCache(pairingMode: .separate)
        let files = try FolderScanner.discoverInventory(fixture.source).physicalFileCount
        let directories = try FolderScanner.discoverInventory(fixture.source).directories.count
        for allowsPreview in [false, true] {
            let reads = NamedReads()
            let before = FileOperationJournal.IdentityCaptureCounter.shared.value
            _ = try await SessionOpeningWorker.prepare(
                folder: fixture.source, pairingMode: .separate, persistence: IdentityPersistence(),
                recorder: SessionOpeningRecorder(), allowsPreview: allowsPreview, preview: { _ in },
                hooks: .init(metadataReader: { reads.read($0) }, metadataIndex: try fixture.index()))
            let captures = FileOperationJournal.IdentityCaptureCounter.shared.value - before
            let misses = reads.total
            XCTAssertLessThanOrEqual(misses, 1, "a warm open hits the cache (a fake NEF may fail to decode)")
            // Discovery and the final barrier; the preview barrier adds one pass.
            let passes = allowsPreview ? 3 : 2
            XCTAssertGreaterThanOrEqual(captures, 2 * files)
            XCTAssertLessThanOrEqual(captures, passes * files + 2 * misses + (passes + 1) * directories + 16,
                                     "preview=\(allowsPreview) files=\(files) dirs=\(directories) captures=\(captures)")
        }
    }
#endif

    // MARK: Helpers

    private func makeFolder(files: Int, folders: Int) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Louppe-IdentityPass-\(UUID())", isDirectory: true)
        for index in 0..<folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder-\(index)"),
                                                    withIntermediateDirectories: true)
        }
        for index in 0..<files {
            let url = root.appendingPathComponent("folder-\(index % max(folders, 1))")
                .appendingPathComponent(String(format: "IMG_%04d.JPG", index))
            try Data("disposable \(index)".utf8).write(to: url)
        }
        return root
    }
}

/// Session-level contract: a failed barrier never reaches Ready, and the
/// optional cache commit starts only after Ready without delaying Close.
@MainActor
final class OpeningIdentitySessionTests: XCTestCase {
    func testReplacementBeforeFinalBarrierShowsWelcomeAndWritesNothing() async throws {
        for directory in [false, true] {
            let fixture = try IdentityFixture(withSidecar: false)
            defer { fixture.remove() }
            let (store, defaults) = try makeStore(fixture)
            defer { UserDefaults.standard.removePersistentDomain(forName: defaults) }
            store.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
                guard stage == .derivedPreparation else { return }
                if directory { fixture.replaceDirectory() } else { fixture.replaceFile() }
            }, metadataReader: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: try fixture.index())
            store.openFolder(fixture.source)
            try await until { store.scanError != nil }
            XCTAssertEqual(store.scanError, FolderScanner.ScanError.filesChangedDuringScan.localizedDescription)
            XCTAssertTrue(isWelcome(store.phase))
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertNil(store.openingSession)
            await store.waitForMetadataIndexCommitForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.index().cacheURL.path))
            try fixture.assertUnchanged(replacedFile: !directory, context: "store directory=\(directory)")
        }
    }

    func testCacheCommitRunsAfterReadyAndNeverDelaysClose() async throws {
        let fixture = try IdentityFixture(withSidecar: false)
        defer { fixture.remove() }
        let (store, defaults) = try makeStore(fixture)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaults) }
        let entered = expectation(description: "commit started after Ready")
        let release = DispatchSemaphore(value: 0)
        let phases = PhaseProbe()
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try fixture.index(), willCommitMetadataIndex: {
                phases.record(DispatchQueue.main.sync { MainActor.assumeIsolated {
                    if case .ready = store.phase { return true }; return false
                } })
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            })
        store.openFolder(fixture.source)
        await fulfillment(of: [entered], timeout: 8)
        XCTAssertEqual(phases.readiness, [true])
        // Close does not wait for the blocked cache commit.
        store.closeSession()
        try await until { isWelcome(store.phase) }
        release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.index().cacheURL.path))
    }

    func testQuitCancelsAPendingCacheCommit() async throws {
        let fixture = try IdentityFixture(withSidecar: false)
        defer { fixture.remove() }
        let (store, defaults) = try makeStore(fixture)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaults) }
        let entered = expectation(description: "commit started")
        let release = DispatchSemaphore(value: 0)
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try fixture.index(), willCommitMetadataIndex: {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            })
        store.openFolder(fixture.source)
        await fulfillment(of: [entered], timeout: 8)
        store.beginTerminationPreparation()
        release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.index().cacheURL.path))
        _ = await store.saveSessionForTermination()
    }

    /// Pin positions and folder memory load after the worker's final barrier;
    /// the repeated barrier must stop a replacement made during that load.
    func testReplacementWhileLoadingOpeningStateNeverReachesReady() async throws {
        for directory in [false, true] {
            let fixture = try IdentityFixture(withSidecar: false)
            defer { fixture.remove() }
            let (store, defaults) = try makeStore(fixture)
            defer { UserDefaults.standard.removePersistentDomain(forName: defaults) }
            store.openingWorkerHooksForTesting = .init(
                metadataReader: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: try fixture.index(),
                didLoadOpeningStateForTesting: {
                    if directory { fixture.replaceDirectory() } else { fixture.replaceFile() }
                })
            store.openFolder(fixture.source)
            try await until { store.scanError != nil }
            XCTAssertEqual(store.scanError, FolderScanner.ScanError.filesChangedDuringScan.localizedDescription)
            XCTAssertTrue(isWelcome(store.phase))
            XCTAssertTrue(store.items.isEmpty)
            await store.waitForMetadataIndexCommitForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.index().cacheURL.path))
            try fixture.assertUnchanged(replacedFile: !directory, context: "opening state directory=\(directory)")
        }
    }

    /// One commit runs, a newer opening replaces the single waiting one, and
    /// nothing accumulates behind a stalled write.
    func testStalledCommitKeepsOnlyTheNewestWaitingCommit() async throws {
        let first = try IdentityFixture(withSidecar: false)
        let second = try IdentityFixture(withSidecar: false)
        let third = try IdentityFixture(withSidecar: false)
        defer { first.remove(); second.remove(); third.remove() }
        let (store, defaults) = try makeStore(first)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaults) }
        let entered = expectation(description: "first commit started")
        let release = DispatchSemaphore(value: 0)
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try first.index(), willCommitMetadataIndex: {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            })
        store.openFolder(first.source)
        await fulfillment(of: [entered], timeout: 8)
        store.closeSession()
        try await until { isWelcome(store.phase) }
        let superseded = PhaseProbe()
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try second.index(), willCommitMetadataIndex: { superseded.record(true) })
        store.openFolder(second.source)
        try await until { isReady(store.phase) }
        store.closeSession()
        try await until { isWelcome(store.phase) }
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try third.index())
        store.openFolder(third.source)
        try await until { isReady(store.phase) }
        release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try first.index().cacheURL.path))
        XCTAssertEqual(superseded.readiness, [], "a replaced waiting commit must never run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try second.index().cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try third.index().cacheURL.path))
    }

    func testQuitCancelsTheRunningCommitAndDropsTheWaitingOne() async throws {
        let first = try IdentityFixture(withSidecar: false)
        let second = try IdentityFixture(withSidecar: false)
        defer { first.remove(); second.remove() }
        let (store, defaults) = try makeStore(first)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaults) }
        let entered = expectation(description: "first commit started")
        let release = DispatchSemaphore(value: 0)
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try first.index(), willCommitMetadataIndex: {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            })
        store.openFolder(first.source)
        await fulfillment(of: [entered], timeout: 8)
        store.closeSession()
        try await until { isWelcome(store.phase) }
        store.openingWorkerHooksForTesting = .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: try second.index())
        store.openFolder(second.source)
        try await until { isReady(store.phase) }
        store.beginTerminationPreparation()
        release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try first.index().cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try second.index().cacheURL.path))
        _ = await store.saveSessionForTermination()
    }

    private func isReady(_ phase: AppPhase) -> Bool {
        if case .ready = phase { return true }
        return false
    }

    private func makeStore(_ fixture: IdentityFixture) throws -> (SessionStore, String) {
        let name = "Louppe-OpeningIdentity-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults)
        return (store, name)
    }

    private func isWelcome(_ phase: AppPhase) -> Bool {
        if case .welcome = phase { return true }
        return false
    }

    private func until(timeout: Duration = .seconds(8), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class PhaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ isReady: Bool) { lock.withLock { values.append(isReady) } }
    var readiness: [Bool] { lock.withLock { values } }
}

/// A disposable source: real JPEGs, a nested folder, an empty folder and a
/// sidecar whose bytes must never change. Lives only in /private/tmp.
private struct IdentityFixture: Sendable {
    let root: URL
    let source: URL
    let cache: URL
    /// Nil: no sidecar exists and none may be created.
    let sidecarBytes: Data?
    let replacementBytes = Data("same path, different physical file".utf8)
    private let originals: [String: Data]

    init(extraFiles: Int = 0, extraFolders: Int = 0, withSidecar: Bool = true) throws {
        sidecarBytes = withSidecar ? Data("previous decisions, byte for byte".utf8) : nil
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Louppe-OpeningIdentity-\(UUID())", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("shoot"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let jpeg = try ArchiveMetadataFixture.jpeg(camera: "Identity camera")
        var names = ["A.JPG", "B.JPG", "shoot/C.JPG", "PAIR.NEF", "PAIR.JPG"]
        for index in 0..<extraFolders {
            try fm.createDirectory(at: source.appendingPathComponent("extra-\(index)"), withIntermediateDirectories: true)
        }
        for index in 0..<extraFiles {
            names.append("extra-\(index % max(extraFolders, 1))/X\(index).JPG")
        }
        var originals: [String: Data] = [:]
        for name in names {
            try jpeg.write(to: source.appendingPathComponent(name))
            originals[name] = jpeg
        }
        self.originals = originals
        try sidecarBytes?.write(to: source.appendingPathComponent(SessionStore.sidecarName))
    }

    func index() throws -> ArchiveMetadataIndex {
        try XCTUnwrap(ArchiveMetadataIndex(folder: source, cacheDirectory: cache))
    }

    /// One complete opening plus its post-Ready commit.
    func primeCache(pairingMode: RawJPEGPairingMode = .together) async throws {
        let prepared = try await SessionOpeningWorker.prepare(
            folder: source, pairingMode: pairingMode, persistence: IdentityPersistence(),
            recorder: SessionOpeningRecorder(), preview: { _ in },
            hooks: .init(metadataReader: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: try index()))
        XCTAssertEqual(try XCTUnwrap(prepared.metadataCommit).run(isCancelled: { false }), true)
    }

    func replaceFile() {
        XCTAssertNoThrow(try replacementBytes.write(to: source.appendingPathComponent("A.JPG"), options: .atomic))
    }

    func replaceDirectory() {
        let empty = source.appendingPathComponent("empty")
        XCTAssertNoThrow(try FileManager.default.moveItem(at: empty, to: root.appendingPathComponent("empty-old")))
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false))
    }

    func assertUnchanged(replacedFile: Bool, context: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let sidecar = source.appendingPathComponent(SessionStore.sidecarName)
        if let sidecarBytes {
            XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes, context, file: file, line: line)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), context, file: file, line: line)
        }
        for (name, bytes) in originals {
            let expected = replacedFile && name == "A.JPG" ? replacementBytes : bytes
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), expected,
                           "\(name) \(context)", file: file, line: line)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor IdentityPersistence: SessionPersistenceClient {
    private(set) var saveCount = 0
    private let duringRead: (@Sendable () -> Void)?
    init(duringRead: (@Sendable () -> Void)? = nil) { self.duringRead = duringRead }
    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?) async -> SessionPersistence.ReadResult {
        duringRead?()
        return .init(session: nil, origin: nil, problems: [],
                     access: .init(id: UUID(), folderIdentity: folderIdentity, sidecarRevision: .absent))
    }
    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        saveCount += 1
        return .savedToSidecar
    }
}

private final class NamedReads: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func read(_ url: URL) -> MetadataExtractor.ScanInfo {
        lock.withLock { counts[url.lastPathComponent, default: 0] += 1 }
        return MetadataExtractor.scanInfo(for: url)
    }
    func count(for name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    func snapshot() -> [String: Int] { lock.withLock { counts } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in defer { ran = true }; return !ran }
        if first { body() }
    }
    var didRun: Bool { lock.withLock { ran } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

private final class PreviewCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
