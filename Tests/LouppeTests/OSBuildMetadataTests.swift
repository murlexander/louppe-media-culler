import Foundation
import XCTest
@testable import Louppe

@MainActor
final class OSBuildMetadataTests: XCTestCase {
    private let contextA = "2|Europe/Copenhagen|27.1.0|26A1"
    private let contextB = "2|Europe/Copenhagen|27.2.0|26B2"

    func testOSOnlyMismatchIsAllHitsBeforeReadyThenRechecksOnce() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG", "C.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let probe = OSBuildProbe()
        defer { probe.release.signal() }
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: index,
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        guard case .ready = store.phase else { return XCTFail("recheck must start after Ready") }
        XCTAssertEqual(probe.readCount, 0)
        XCTAssertEqual(store.openingMetrics?.metadataIndexHits, 3)
        XCTAssertEqual(store.openingMetrics?.metadataSnapshotReason, .osBuild)
        XCTAssertTrue(store.openingMetrics?.metadataMissReasons.isEmpty == true)
        XCTAssertNil(index.storedEntriesForTesting(), "old context cannot be published as B before validation")
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(probe.readCount, 3)
        XCTAssertEqual(probe.readsByName, ["A.JPG": 1, "B.JPG": 1, "C.JPG": 1])
        XCTAssertEqual(index.storedEntriesForTesting()?.count, 3)
        let secondIndex = try self.index(fixture)
        XCTAssertEqual(secondIndex.snapshotReason, .hit)
        XCTAssertFalse(secondIndex.needsOSBuildRecheck)
        let recorder = SessionOpeningRecorder()
        let result = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .together,
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups2")),
            recorder: recorder, hooks: .init(metadataReader: { probe.read($0) }, metadataIndex: secondIndex))
        XCTAssertNil(result.metadataCommit?.recheck)
        XCTAssertEqual(recorder.snapshot().metadataIndexHits, 3)
        XCTAssertEqual(recorder.snapshot().metadataSnapshotReason, .hit)
        XCTAssertEqual(probe.readCount, 3, "second opening needs neither extraction nor recheck")
        store.beginTerminationPreparation()
        try fixture.assertOriginalBytes()
        print("OSBUILD same: Ready reads=0 hits=3; recheck reads=3; second open reads=0 rechecks=0")
    }

    func testChangedDateRebuildsLiveOrderFacetsAndFiltersWithoutChangingDecisions() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let index = try index(fixture)
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: index,
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        XCTAssertEqual(store.items.map(\.id), ["A.JPG", "B.JPG"])
        let target = try XCTUnwrap(store.items.first?.primaryFile)
        let decision = Date(timeIntervalSince1970: 10)
        target.setRating(.yes, ratedAt: decision)
        target.setStars(.three, changedAt: decision)
        target.setColor(.red, changedAt: decision)
        let decisions = target.metadataSnapshot
        store.setIndex(0)
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        let sidecar = SessionPersistence.sidecarURL(for: fixture.source)
        let before = try? Data(contentsOf: sidecar)
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(probe.readCount, 2)
        XCTAssertEqual(store.items.map(\.id), ["B.JPG", "A.JPG"])
        XCTAssertEqual(store.items.last?.captureDate, probe.changedDate)
        XCTAssertEqual(store.items.last?.primaryFile.metadataSnapshot, decisions)
        XCTAssertEqual(store.currentItem?.id, "A.JPG")
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["B.JPG", "A.JPG"])
        XCTAssertTrue(store.availableCaptureDates.contains(try XCTUnwrap(store.items.last?.captureDay)))
        XCTAssertEqual(try? Data(contentsOf: sidecar), before, "recheck cannot save decisions or sidecars")
        XCTAssertEqual(index.storedEntriesForTesting()?.first { $0.path.hasSuffix("A.JPG") }?.metadata.capture?.date,
                       probe.changedDate)
        // The same injected extraction under B must give identical dates/order.
        let cold = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { probe.read($0) })
        XCTAssertEqual(store.items.map(\.id), cold.map(\.id))
        XCTAssertEqual(store.items.map(\.captureDate), cold.map(\.captureDate))
        var filter = store.filter
        filter.excludedCameras = ["Archive camera"]
        store.filter = filter
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.beginTerminationPreparation()
        try fixture.assertOriginalBytes()
        print("OSBUILD changed: Ready reads=0 hits=2; recheck reads=2; order=B,A; decision preserved; sidecar writes=0")
    }

    func testSchemaAndZoneMismatchStayCold() async throws {
        for (context, reason) in [("3|Europe/Copenhagen|27.2.0|26B2", ArchiveMetadataIndex.MissReason.schema),
                                  ("2|UTC|27.2.0|26B2", .zone)] {
            let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
            defer { fixture.remove() }
            try seed(fixture)
            let index = try self.index(fixture, context: context)
            let reads = ArchiveMetadataReads()
            let recorder = SessionOpeningRecorder()
            let result = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .together,
                persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
                recorder: recorder, hooks: .init(metadataReader: { reads.read($0) }, metadataIndex: index))
            XCTAssertEqual(index.snapshotReason, reason)
            XCTAssertFalse(index.needsOSBuildRecheck)
            XCTAssertEqual(reads.total, 2)
            XCTAssertEqual(recorder.snapshot().metadataIndexHits, 0)
            XCTAssertEqual(recorder.snapshot().metadataMissReasons[reason], 2)
            XCTAssertNil(result.metadataCommit?.recheck)
        }
    }

    func testCloseMidRecheckStopsReadsAndLeavesOldSnapshot() async throws {
        try await cancelRecheck(opensAnother: false, quits: false)
    }

    func testAnotherOpenCancelsRecheckAndCannotPublishOldMetadata() async throws {
        try await cancelRecheck(opensAnother: true, quits: false)
    }

    func testQuitDoesNotWaitForBlockedRecheck() async throws {
        try await cancelRecheck(opensAnother: false, quits: true)
    }

    func testRecheckHasNoAdmissionFloor() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let coordinator = ForegroundWorkCoordinator(quietInterval: .zero, maximumDeferral: .seconds(60))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let probe = OSBuildProbe()
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: try index(fixture),
            foregroundWork: coordinator, willCommitMetadataIndex: { probe.noteStarted() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        XCTAssertEqual(probe.readCount, 0)
        XCTAssertEqual(store.openingMetrics?.metadataIndexHits, 2)
        // Foreground demand is still held; cancellation must retire a waiting admission.
        store.closeSession()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(probe.readCount, 0)
        XCTAssertNil(try index(fixture).storedEntriesForTesting())
    }

    func testRemovedEXIFFallsBackToFreshInventoryDate() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let recorder = SessionOpeningRecorder()
        let result = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .together,
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            recorder: recorder, hooks: .init(metadataReader: { _ in .init() }, metadataIndex: index))
        let commit = try XCTUnwrap(result.metadataCommit)
        let recheck = try XCTUnwrap(commit.recheck)
        let refreshed = try recheck.run(index: index, items: commit.items, isCancelled: { false })
        let cold = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { _ in .init() })
        XCTAssertEqual(refreshed.items.map(\.captureDateEvidence), cold.map(\.captureDateEvidence))
        XCTAssertEqual(refreshed.changedFiles.count, 1)
        XCTAssertEqual(refreshed.items.first?.captureDateEvidence?.source, .fileCreation)
    }

    func testUnrecheckedValuesCannotBeCommittedAsCurrentContext() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let items = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { _ in XCTFail("expected hit"); return .init() },
            metadataIndex: index, commitsMetadataIndex: false)
        XCTAssertNil(index.prepareCommit(items))
        XCTAssertFalse(SessionOpeningMetadataCommit(index: index, items: items).run(isCancelled: { false }))
        XCTAssertNil(index.storedEntriesForTesting())
    }

    func testActiveDateFilterRebuildsAfterDateChanges() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: try index(fixture),
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        var filter = store.filter
        filter.dateMode = .specificDates
        filter.excludedDates = [try XCTUnwrap(store.items.first?.captureDay)]
        store.normalizeDateFilter(&filter)
        store.filter = filter
        XCTAssertTrue(store.visibleIndices.isEmpty)
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["A.JPG"])
        XCTAssertEqual(store.items.last?.captureDate, probe.changedDate)
        store.beginTerminationPreparation()
    }

    func testCachedHiddenPartnerIsRecheckedButRemainsLightweightInLiveSession() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.RAF", "A.JPG"])
        defer { fixture.remove() }
        let writer = try index(fixture, context: contextA, reuse: false)
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source, pairingMode: .separate),
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: writer)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let index = try index(fixture)
        let store = makeStore(fixture)
        store.setRawJPEGPairingMode(.together)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: index,
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.openingMetrics?.metadataIndexHits, 1)
        let lightweight = try XCTUnwrap(store.items.first?.pairedFile)
        XCTAssertFalse(lightweight.metadataIsLoaded)
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(probe.readsByName, ["A.RAF": 1, "A.JPG": 1])
        XCTAssertFalse(store.items.first?.pairedFile?.metadataIsLoaded ?? true)
        XCTAssertEqual(store.items.first?.pairedFile?.captureDate, lightweight.captureDate)
        XCTAssertEqual(index.storedEntriesForTesting()?.first { $0.path.hasSuffix("A.JPG") }?.metadata.capture?.date,
                       probe.changedDate)
        store.beginTerminationPreparation()
    }

    func testMissingAndIdentityMissReasonsAreRecorded() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        XCTAssertEqual(try index(fixture).snapshotReason, .none)
        try seed(fixture)
        let index = try self.index(fixture, context: contextA)
        try ArchiveMetadataFixture.jpeg(camera: "Replacement").write(to: fixture.source.appendingPathComponent("A.JPG"),
                                                                    options: .atomic)
        let reads = ArchiveMetadataReads()
        let recorder = SessionOpeningRecorder()
        _ = try await SessionOpeningWorker.prepare(folder: fixture.source, pairingMode: .together,
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            recorder: recorder, hooks: .init(metadataReader: { reads.read($0) }, metadataIndex: index))
        XCTAssertEqual(recorder.snapshot().metadataSnapshotReason, .hit)
        XCTAssertEqual(recorder.snapshot().metadataIndexHits, 0)
        XCTAssertEqual(recorder.snapshot().metadataMissReasons[.identity], 1)
        XCTAssertEqual(reads.total, 1)
    }

    func testRefreshWaitsForOperationBeforeReorderingItsItemIndices() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let index = try index(fixture)
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: index,
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        probe.release.signal()
        try await until { store.metadataRecheckDeferralsForTesting > 0 }
        XCTAssertEqual(store.items.map(\.id), ["A.JPG", "B.JPG"])
        XCTAssertNil(index.storedEntriesForTesting())
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(store.items.map(\.id), ["B.JPG", "A.JPG"])
        XCTAssertEqual(probe.readCount, 2, "publication deferral cannot repeat extraction")
        XCTAssertEqual(index.storedEntriesForTesting()?.count, 2)
        store.beginTerminationPreparation()
    }

    private func cancelRecheck(opensAnother: Bool, quits: Bool) async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG", "C.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let before = try Data(contentsOf: index.cacheURL)
        let probe = OSBuildProbe(blockFirstRead: true)
        defer { probe.release.signal() }
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: index)
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        XCTAssertEqual(probe.readCount, 1)
        if quits {
            store.beginTerminationPreparation()
            _ = await store.saveSessionForTermination()
            XCTAssertTrue(probe.isHeld, "Quit finished while extractor was still blocked")
        } else if opensAnother {
            let other = fixture.root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("disposable text".utf8).write(to: other.appendingPathComponent("other.txt"))
            store.openingWorkerHooksForTesting = .init(metadataReader: { _ in .init() })
            store.openFolder(other)
            try await until { store.items.first?.id == "other.txt" }
        } else {
            store.closeSession()
            try await until { store.sourceFolder == nil }
        }
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(probe.readCount, 1, "cancel stops new reads after the in-flight unit")
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), before)
        XCTAssertNil(index.storedEntriesForTesting())
        store.beginTerminationPreparation()
    }

    func testRefreshPreservesMeasuredEvidenceCoverageAndCueFilterWithoutRemeasuring() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let measurements = OSBuildMeasurements()
        let store = makeStore(fixture, qualityCueMeasurement: { await measurements.measure($0) })
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: try index(fixture),
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        store.startQualityCueAnalysis()
        try await until { store.qualityCueEvidence.count == 2 }
        store.pauseQualityCueAnalysis(userInitiated: true)
        let evidence = store.qualityCueEvidence
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["A.JPG"])
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 2)
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(store.items.map(\.id), ["B.JPG", "A.JPG"])
        XCTAssertEqual(store.qualityCueEvidence, evidence)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 2)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, 2)
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["A.JPG"])
        XCTAssertTrue(store.isQualityCueAnalysisPaused)
        store.resumeQualityCueAnalysis()
        for _ in 0..<20 { await Task.yield() }
        let count = await measurements.count
        XCTAssertEqual(count, 2, "A metadata refresh cannot repeat histogram work")
        store.beginTerminationPreparation()
        try fixture.assertOriginalBytes()
        print("OSBUILD evidence: measured=2 before/after; histogram measurements=2 total; cue membership=A")
    }

    func testMovedFileBeforeRecheckIsDroppedAndOtherMetadataCommits() async throws {
        try await recheckWithChangedFile(movedBeforeRead: true)
    }

    func testModifiedFileDuringRecheckIsDroppedAndOtherMetadataCommits() async throws {
        try await recheckWithChangedFile(movedBeforeRead: false)
    }

    func testStatusOnlyChangeDuringRecheckIsDroppedAndOtherMetadataCommits() async throws {
        try await recheckWithChangedFile(movedBeforeRead: false, statusOnly: true)
    }

    private func recheckWithChangedFile(movedBeforeRead: Bool, statusOnly: Bool = false) async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let replacement = try ArchiveMetadataFixture.jpeg(camera: "Changed camera")
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { url in
            let info = probe.read(url)
            if !movedBeforeRead && url.lastPathComponent == "B.JPG" {
                if statusOnly {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } else {
                    try replacement.write(to: url, options: .atomic)
                }
            }
            return info
        }, metadataIndex: index, willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        let b = fixture.source.appendingPathComponent("B.JPG")
        let removed = fixture.root.appendingPathComponent("removed.JPG")
        if movedBeforeRead {
            try FileManager.default.moveItem(at: b, to: removed)
            store.items.removeAll { $0.id == "B.JPG" }
            store.rebuildDerivedDataForTesting()
        }
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(store.items.first { $0.id == "A.JPG" }?.captureDate, probe.changedDate)
        XCTAssertEqual(index.storedEntriesForTesting()?.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["A.JPG"])
        let reopenedIndex = try self.index(fixture)
        XCTAssertEqual(reopenedIndex.snapshotReason, .hit)
        XCTAssertFalse(reopenedIndex.needsOSBuildRecheck)
        if movedBeforeRead { try FileManager.default.moveItem(at: removed, to: b) }
        let reads = ArchiveMetadataReads()
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { reads.read($0) }, metadataIndex: reopenedIndex)
        XCTAssertEqual(reads.total, 1, "Only the skipped file must miss next time")
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("A.JPG")), fixture.originals["A.JPG"])
        store.beginTerminationPreparation()
        print("OSBUILD per-file skip: moved=\(movedBeforeRead); new-context entries=1; next-open reads=1")
    }

    func testFinalBarrierDropsAFileChangedAfterItsRecheckRead() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let probe = OSBuildProbe(changedName: "B.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { url in
            let info = probe.read(url)
            if url.lastPathComponent == "B.JPG" {
                try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("A.JPG"),
                                                 to: fixture.root.appendingPathComponent("removed.JPG"))
            }
            return info
        }, metadataIndex: index)
        store.openFolder(fixture.source)
        try await until { if case .ready = store.phase { return true }; return false }
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(probe.readsByName, ["A.JPG": 1, "B.JPG": 1])
        XCTAssertEqual(store.items.first { $0.id == "B.JPG" }?.captureDate, probe.changedDate)
        XCTAssertEqual(index.storedEntriesForTesting()?.count, 1)
        XCTAssertTrue(index.storedEntriesForTesting()?.first?.path.hasSuffix("B.JPG") == true)
        XCTAssertEqual(try self.index(fixture).snapshotReason, .hit)
        store.beginTerminationPreparation()
    }

    func testFileRemovedWhilePublicationWaitsDoesNotRejectOtherChangesOrEnterSnapshot() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let probe = OSBuildProbe()
        defer { probe.release.signal() }
        let store = makeStore(fixture)
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        store.openingWorkerHooksForTesting = .init(metadataReader: { url in
            var info = probe.read(url)
            info.captureDate = date
            info.captureDateEvidence = .init(date: date, source: .exifOriginal)
            return info
        }, metadataIndex: index, willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        probe.release.signal()
        try await until { store.metadataRecheckDeferralsForTesting > 0 }
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("A.JPG"),
                                         to: fixture.root.appendingPathComponent("removed.JPG"))
        store.items.removeAll { $0.id == "A.JPG" }
        store.rebuildDerivedDataForTesting()
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(store.items.map(\.id), ["B.JPG"])
        XCTAssertEqual(store.items.first?.captureDate, date)
        XCTAssertEqual(index.storedEntriesForTesting()?.count, 1)
        XCTAssertTrue(index.storedEntriesForTesting()?.first?.path.hasSuffix("B.JPG") == true)
        XCTAssertEqual(try self.index(fixture).snapshotReason, .hit)
        store.beginTerminationPreparation()
    }

    func testDuplicateLiveIDsDoNotTrapDuringRefresh() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let probe = OSBuildProbe(changedName: "A.JPG", changedDate: Date(timeIntervalSince1970: 2_000_000_000))
        defer { probe.release.signal() }
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: try index(fixture),
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        store.items.append(try XCTUnwrap(store.items.first))
        store.rebuildDerivedDataForTesting()
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.allSatisfy { $0.captureDate == probe.changedDate })
        store.beginTerminationPreparation()
    }

    func testReplacedDirectoryStillRejectsEntireRecheck() async throws {
        let fixture = try ArchiveMetadataFixture(names: ["sub/A.JPG"])
        defer { fixture.remove() }
        try seed(fixture)
        let index = try index(fixture)
        let before = try Data(contentsOf: index.cacheURL)
        let probe = OSBuildProbe()
        defer { probe.release.signal() }
        let store = makeStore(fixture)
        store.openingWorkerHooksForTesting = .init(metadataReader: { probe.read($0) }, metadataIndex: index,
                                                   willCommitMetadataIndex: { probe.hold() })
        store.openFolder(fixture.source)
        try await until { probe.isHeld }
        let sub = fixture.source.appendingPathComponent("sub")
        try FileManager.default.moveItem(at: sub, to: fixture.root.appendingPathComponent("old-sub"))
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        probe.release.signal()
        await store.waitForMetadataIndexCommitForTesting()
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), before)
        XCTAssertNil(index.storedEntriesForTesting())
        store.beginTerminationPreparation()
    }

    private func seed(_ fixture: ArchiveMetadataFixture) throws {
        let writer = try index(fixture, context: contextA, reuse: false)
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: writer)
    }

    private func index(_ fixture: ArchiveMetadataFixture, context: String? = nil, reuse: Bool = true) throws -> ArchiveMetadataIndex {
        try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
            interpretationContext: context ?? contextB, allowsOSBuildReuse: reuse))
    }

    private func makeStore(_ fixture: ArchiveMetadataFixture,
                           qualityCueMeasurement: (@Sendable (PhotoItem) async -> QualityCueEvidence)? = nil) -> SessionStore {
        let name = "Louppe-OSBuild-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return SessionStore(persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            reviewDefaults: defaults,
            pinnedFolders: PinnedFoldersStore(storageDirectory: fixture.root.appendingPathComponent("pins"),
                                               observesSystemChanges: false),
            qualityCueMeasurement: qualityCueMeasurement)
    }

    private func until(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class OSBuildProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String: Int] = [:]
    private var held = false
    let release = DispatchSemaphore(value: 0)
    let changedName: String?
    let changedDate: Date?
    let blockFirstRead: Bool
    init(changedName: String? = nil, changedDate: Date? = nil, blockFirstRead: Bool = false) {
        self.changedName = changedName
        self.changedDate = changedDate
        self.blockFirstRead = blockFirstRead
    }
    var readCount: Int { lock.withLock { reads.values.reduce(0, +) } }
    var readsByName: [String: Int] { lock.withLock { reads } }
    var isHeld: Bool { lock.withLock { held } }
    func noteStarted() { lock.withLock { held = true } }
    func hold() { noteStarted(); release.wait() }
    func read(_ url: URL) -> MetadataExtractor.ScanInfo {
        let count = lock.withLock { reads[url.lastPathComponent, default: 0] += 1; return reads.values.reduce(0, +) }
        if blockFirstRead && count == 1 { hold() }
        var info = MetadataExtractor.scanInfo(for: url)
        if url.lastPathComponent == changedName {
            info.captureDate = changedDate
            info.captureDateEvidence = changedDate.map { CaptureDateEvidence(date: $0, source: .exifOriginal) }
        }
        return info
    }
}

private actor OSBuildMeasurements {
    private(set) var count = 0
    func measure(_ item: PhotoItem) -> QualityCueEvidence {
        count += 1
        return QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 100,
            shadowCount: 0, highlightCount: item.id == "A.JPG" ? 20 : 0), source: .renderedPreview)
    }
}
