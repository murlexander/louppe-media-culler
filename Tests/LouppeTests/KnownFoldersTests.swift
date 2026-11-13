import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Louppe

extension ArchiveMetadataCacheStorageTests {
    func testWarmUseKeepsSnapshotAheadOfNewerFolders() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let items = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let url = try fixture.index().cacheURL
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: url.path)
        let index = try fixture.index()
        let bytes = try Data(contentsOf: url)
        for value in 0..<ArchiveMetadataIndex.maximumFolderSnapshots {
            let sibling = fixture.cache.appendingPathComponent(ArchiveMetadataFixture.snapshotName(value))
            try Data("disposable observation".utf8).write(to: sibling)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: sibling.path)
        }
        XCTAssertTrue(SessionOpeningMetadataCommit(index: index, items: items).run(isCancelled: { false }))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(index.maintenanceRunsForTesting, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count, 257,
                       "unchanged warm use must run no maintenance")
        let other = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try ArchiveMetadataFixture.jpeg(camera: "New").write(to: other.appendingPathComponent("B.JPG"))
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(other),
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) },
            metadataIndex: ArchiveMetadataIndex(folder: other, cacheDirectory: fixture.cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "use date protects it during another folder's maintenance")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count, 256)
        print("KNOWN warm unchanged maintenance runs=\(index.maintenanceRunsForTesting)")
    }

    func testNoteUsedWritesAtMostOncePerDay() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let url = try fixture.index().cacheURL
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: url.path)
        let index = try fixture.index()
        let stale = try fixture.index()
        let before = try Data(contentsOf: url)
        XCTAssertFalse(index.noteUsed(isCancelled: { true }))
        XCTAssertTrue(index.noteUsed())
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertFalse(index.noteUsed())
        XCTAssertFalse(stale.noteUsed(), "stale producers cannot touch a newer revision")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, date)
        XCTAssertEqual(try Data(contentsOf: url), before)
        // The touch refreshes loadedRevision, allowing a later changed commit.
        try ArchiveMetadataFixture.jpeg(camera: "Changed observation").write(to: fixture.source.appendingPathComponent("B.JPG"))
        let changed = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: index, commitsMetadataIndex: false)
        XCTAssertTrue(index.commit(changed))
        XCTAssertEqual(try fixture.index().storedEntriesForTesting()?.count, 2)
    }
}

extension ArchiveMetadataIndexTests {
    func testContextIsLocaleIndependent() throws {
        let parts = ArchiveMetadataIndex.currentContext.split(separator: "|", omittingEmptySubsequences: false)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(String(parts[0]), String(MetadataExtractor.archiveSchemaVersion))
        XCTAssertEqual(String(parts[1]), TimeZone.current.identifier)
        XCTAssertEqual(String(parts[2]), "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        var size = 0
        XCTAssertEqual(sysctlbyname("kern.osversion", nil, &size, nil, 0), 0)
        var build = [CChar](repeating: 0, count: size)
        XCTAssertEqual(sysctlbyname("kern.osversion", &build, &size, nil, 0), 0)
        XCTAssertEqual(String(parts[3]), String(decoding: build.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        XCTAssertNotEqual(ArchiveMetadataIndex.currentContext, ArchiveMetadataIndex.legacyLocalizedContext)
    }

    func testLegacyLocalizedContextMigratesOnce() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let old = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
            interpretationContext: ArchiveMetadataIndex.legacyLocalizedContext))
        _ = try FolderScanner.prepareMetadata(in: inventory,
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: old)
        let bytes = try Data(contentsOf: old.cacheURL)
        let index = try fixture.index()
        XCTAssertTrue(index.isMigratingForTesting)
        XCTAssertNotNil(index.metadata(for: inventory.items[0].primaryFile))
        let reads = ArchiveMetadataReads()
        let items = try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { reads.read($0) },
                                                     metadataIndex: index, commitsMetadataIndex: false)
        XCTAssertTrue(SessionOpeningMetadataCommit(index: index, items: items).run(isCancelled: { false }))
        XCTAssertEqual(reads.total, 0)
        XCTAssertNotEqual(try Data(contentsOf: old.cacheURL), bytes)
        let rewritten = try fixture.index()
        XCTAssertFalse(rewritten.isMigratingForTesting)
        XCTAssertNotNil(rewritten.metadata(for: inventory.items[0].primaryFile))
        XCTAssertFalse(SessionOpeningMetadataCommit(index: rewritten, items: items).run(isCancelled: { false }))
        XCTAssertEqual(rewritten.maintenanceRunsForTesting, 0)
        let legacy = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
            interpretationContext: ArchiveMetadataIndex.legacyLocalizedContext))
        XCTAssertNil(legacy.metadata(for: inventory.items[0].primaryFile), "rewritten cache no longer uses localized context")
    }

    func testContextMigrationKeepsSchemaZoneAndOSBuildStrict() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let contexts = [ArchiveMetadataIndex.currentContext, ArchiveMetadataIndex.legacyLocalizedContext]
        for context in contexts {
            let parts = context.components(separatedBy: "|")
            for offset in parts.indices {
                var foreign = parts
                foreign[offset] += "-foreign"
                let writer = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
                    interpretationContext: foreign.joined(separator: "|")))
                _ = try FolderScanner.prepareMetadata(in: inventory,
                    metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: writer)
                XCTAssertNil(try fixture.index().metadata(for: inventory.items[0].primaryFile))
            }
        }
    }
}

extension InstantOpeningTests {
    func testFullyCachedSmallFolderSkipsPreview() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let recorder = SessionOpeningRecorder()
        let result = try await prepareKnownFolder(fixture, recorder: recorder, expectedPreviews: 0)
        XCTAssertEqual(Set(result.restoration.items.map(\.id)), ["A.JPG", "B.JPG"])
        XCTAssertTrue(result.restoration.items.allSatisfy { $0.cameraModel == "Archive camera" })
        XCTAssertNil(recorder.snapshot().secondsByStage[.previewPublication])
        XCTAssertNil(recorder.snapshot().secondsByStage[.previewIdentityValidation])
        XCTAssertNotNil(recorder.snapshot().secondsByStage[.finalIdentityValidation])
    }

    func testOneMissKeepsPreview() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        try ArchiveMetadataFixture.jpeg(camera: "Miss").write(to: fixture.source.appendingPathComponent("B.JPG"))
        let recorder = SessionOpeningRecorder()
        _ = try await prepareKnownFolder(fixture, recorder: recorder, expectedPreviews: 1)
        XCTAssertNotNil(recorder.snapshot().secondsByStage[.previewPublication])
        XCTAssertNotNil(recorder.snapshot().secondsByStage[.previewIdentityValidation])
        XCTAssertNotNil(recorder.snapshot().secondsByStage[.finalIdentityValidation])
    }

    func testLargeCachedFolderKeepsPreview() async throws {
        let fixture = try ArchiveMetadataFixture(names: (0..<3_001).map { "\($0).JPG" })
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        _ = try await prepareKnownFolder(fixture, recorder: SessionOpeningRecorder(), expectedPreviews: 1)
    }

    func testPreviewLimitCountsHiddenPairedFiles() async throws {
        let fixture = try ArchiveMetadataFixture(names: (0..<1_501).flatMap { ["\($0).RAF", "\($0).JPG"] })
        defer { fixture.remove() }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source, pairingMode: .together), reads: ArchiveMetadataReads())
        _ = try await prepareKnownFolder(fixture, recorder: SessionOpeningRecorder(), expectedPreviews: 1, pairing: .together)
    }

    private func prepareKnownFolder(_ fixture: ArchiveMetadataFixture, recorder: SessionOpeningRecorder,
                                    expectedPreviews: Int, pairing: RawJPEGPairingMode = .separate) async throws -> SessionOpeningPreparation {
        let previews = KnownPreviewCount()
        let reads = ArchiveMetadataReads()
        let result = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: pairing,
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")), recorder: recorder,
            preview: { _ in previews.increment() }, hooks: .init(metadataReader: { reads.read($0) }, metadataIndex: fixture.index()))
        XCTAssertEqual(previews.count, expectedPreviews)
        return result
    }
}

final class FolderScannerAdmissionTests: XCTestCase, @unchecked Sendable {
    func testColdScanCompletesWhileForegroundDemandIsHeld() async throws {
        let fixture = try ArchiveMetadataFixture(names: (0..<64).map { "\($0).JPG" })
        defer { fixture.remove() }
        let foreground = ForegroundWorkCoordinator(maximumDeferral: .seconds(60))
        let demand = foreground.beginForegroundDemand()
        defer { demand.finish() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let cancel = FolderScanner.CancelFlag()
        let readers = KnownReaderThreads()
        let release = DispatchSemaphore(value: 0)
        let completed = expectation(description: "all real reads finish with foreground demand still held")
        let scan = Task.detached {
            defer { completed.fulfill() }
            return try FolderScanner.prepareMetadata(in: inventory, isCancelled: { cancel.isSet },
                metadataIndex: fixture.index(), metadataReady: { _ in
                    if readers.record() <= 2 {
                        if readers.count == 2 { release.signal(); release.signal() }
                        _ = release.wait(timeout: .now() + 3)
                    }
                }, metadataWorkers: 8, admissionFloor: 2, foregroundWork: foreground)
        }
        await fulfillment(of: [completed], timeout: 5)
        cancel.set()
        let items = try await scan.value
        XCTAssertEqual(items.count, 64)
        XCTAssertTrue(items.allSatisfy { $0.cameraModel == "Archive camera" })
        XCTAssertEqual(foreground.foregroundDemandCountForTesting, 1)
        XCTAssertEqual(readers.threadCount, 2, "exactly two real readers advance the held-demand scan")
        print("KNOWN held demand files=\(items.count) worker threads=\(readers.threadCount)")
    }

    func testNoDemandUsesAllWorkers() async throws {
        let fixture = try ArchiveMetadataFixture(names: (0..<64).map { "\($0).JPG" })
        defer { fixture.remove() }
        let entered = KnownPreviewCount()
        let workers = min(8, ProcessInfo.processInfo.activeProcessorCount)
        let allWorkers = expectation(description: "every real reader reaches its first result")
        let release = DispatchSemaphore(value: 0)
        let scan = Task.detached {
            try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
                metadataIndex: fixture.index(), metadataReady: { _ in
                    let count = entered.increment()
                    if count <= workers {
                        if count == workers { allWorkers.fulfill() }
                        _ = release.wait(timeout: .now() + 5)
                    }
                }, metadataWorkers: 8, foregroundWork: ForegroundWorkCoordinator(maximumDeferral: .seconds(60)))
        }
        await fulfillment(of: [allWorkers], timeout: 5)
        for _ in 0..<workers { release.signal() }
        let items = try await scan.value
        XCTAssertEqual(items.count, 64)
    }

    /// Background callers such as pinned-folder preparation have no floor.
    func testNoFloorKeepsEveryWorkerBehindForegroundDemand() async throws {
        let fixture = try ArchiveMetadataFixture(names: (0..<8).map { "\($0).JPG" })
        defer { fixture.remove() }
        let foreground = ForegroundWorkCoordinator(maximumDeferral: .seconds(60))
        let demand = foreground.beginForegroundDemand()
        defer { demand.finish() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let cancel = FolderScanner.CancelFlag()
        let reads = KnownPreviewCount()
        let scan = Task.detached {
            try FolderScanner.prepareMetadata(in: inventory, isCancelled: { cancel.isSet },
                metadataIndex: fixture.index(), metadataReady: { _ in reads.increment() },
                metadataWorkers: 2, foregroundWork: foreground)
        }
        try await Task.sleep(for: .milliseconds(500))
        cancel.set()
        _ = try? await scan.value
        XCTAssertEqual(reads.count, 0, "no read starts while demand is held and no floor is requested")
    }
}

private final class KnownPreviewCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    @discardableResult func increment() -> Int { lock.withLock { value += 1; return value } }
}

private final class KnownReaderThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: Set<UInt64> = []
    private var completed = 0
    var count: Int { lock.withLock { completed } }
    var threadCount: Int { lock.withLock { threads.count } }
    func record() -> Int {
        var thread: UInt64 = 0
        pthread_threadid_np(nil, &thread)
        return lock.withLock {
            threads.insert(thread)
            completed += 1
            return completed
        }
    }
}

#if LOUPPE_TEST_SEAMS
extension LouppeSpeedOpeningSessionViewTests {
    func testWarmOpenCreatesOneSurfaceWorthOfHosts() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required") }
        _ = NSApplication.shared
        let fixture = try ArchiveMetadataFixture(names: (0..<32).map { "\($0).JPG" })
        defer { fixture.remove() }
        let items = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        for mode in [ViewMode.gallery, .grid] {
            let suite = "Louppe-Known-Mount-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var preferences = ReviewPreferences()
            preferences.defaultView = mode
            preferences.save(to: defaults)
            let store = SessionStore(persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
                                     reviewDefaults: defaults)
            store.viewMode = mode
            store.showBrowser = true
            store.showMetadataPanel = mode == .gallery
            let barrier = expectation(description: "warm opening reaches final barrier")
            let release = DispatchSemaphore(value: 0)
            store.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
                if stage == .finalIdentityValidation {
                    barrier.fulfill()
                    _ = release.wait(timeout: .now() + 10)
                }
            }, metadataIndex: try fixture.index())
            let host = NSHostingView(rootView: KnownOpeningSurface(store: store))
            host.sizingOptions = []
            let window = knownMount(host)
            defer {
                release.signal()
                store.cancelScan()
                store.beginTerminationPreparation()
                window.contentView = nil
                window.close()
            }
            store.openFolder(fixture.source)
            await fulfillment(of: [barrier], timeout: 5)
            try await knownSettle(host)
            XCTAssertNil(store.openingSession, "fully cached small opens never construct an opening state")
            XCTAssertEqual(knownDocuments(in: host).count, 0, "no read-only surface mounted before Ready")
            release.signal()
            for _ in 0..<500 {
                if case .ready = store.phase { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard case .ready = store.phase else { return XCTFail("warm open did not reach Ready: \(store.scanError ?? "unknown")") }
            try await knownSettle(host)
            let documents = knownDocuments(in: host)
            XCTAssertEqual(documents.count, 1)
            let hosts = documents.reduce(0) { $0 + $1.createdHostCount }
            XCTAssertGreaterThan(hosts, 0)
            await store.waitForMetadataIndexCommitForTesting()

            // No native collection existed before Ready. Retain that one
            // document and its host budget through the settled publication.
            try await knownSettle(host)
            XCTAssertEqual(knownDocuments(in: host).map(ObjectIdentifier.init), documents.map(ObjectIdentifier.init))
            XCTAssertEqual(documents.reduce(0) { $0 + $1.createdHostCount }, hosts)
            XCTAssertEqual(store.viewMode, mode)
            XCTAssertEqual(store.items.map(\.id), items.map(\.id))
            XCTAssertEqual(store.currentItem?.id, items.first?.id)
            XCTAssertTrue(store.selectedIndices.isEmpty)
            XCTAssertFalse(window.isVisible)
            print("KNOWN warm \(mode) surfaces=\(documents.count) hosts=\(hosts)")
        }
    }

    private func knownMount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1_440, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        return window
    }

    private func knownDocuments(in view: NSView) -> [ReviewCollectionDocument] {
        (view as? ReviewCollectionDocument).map { [$0] } ?? view.subviews.flatMap { knownDocuments(in: $0) }
    }

    private func knownSettle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
}

private struct KnownOpeningSurface: View {
    @ObservedObject var store: SessionStore
    private var showsReview: Bool {
        if case .ready = store.phase { return true }
        return store.openingSession != nil
    }
    var body: some View {
        if showsReview {
            SessionView(store: store)
        } else {
            ProgressView()
        }
    }
}
#endif
