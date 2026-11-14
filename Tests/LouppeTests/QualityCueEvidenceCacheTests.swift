import Combine
import ImageIO
import XCTest
@testable import Louppe

/// Persisted clipping evidence: counters decide, never wall-clock time. A
/// reopen measures nothing, a changed file is measured once, the folder walk
/// estimates from thumbnails, and only a shown photo is measured exactly.
@MainActor
final class QualityCueEvidenceCacheTests: XCTestCase {
    // MARK: - Reopen

    func testReopenMeasuresNothingAndAChangedFileIsMeasuredOnce() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg", "C.jpg", "D.jpg", "E.jpg"])
        let cache = try temporaryDirectory()

        let first = CueMeasurements()
        let opened = try open(folder, cache: cache, measurements: first, viewMode: .grid)
        try await settle(opened, evidence: 5)
        let firstCalls = await first.snapshot
        XCTAssertEqual(firstCalls.approximate.count, 5)
        XCTAssertEqual(Set(firstCalls.approximate).count, 5)
        XCTAssertEqual(firstCalls.exact, [], "Grid without Info never measures the full image")
        XCTAssertEqual(opened.qualityCueEvidenceCacheForTesting?.snapshotWritesForTesting, 1)
        let states = cueStates(opened)
        close(opened)

        let second = CueMeasurements()
        let reopened = try open(folder, cache: cache, measurements: second, viewMode: .grid)
        try await settle(reopened, evidence: 5)
        let secondCalls = await second.snapshot
        XCTAssertEqual(secondCalls.approximate, [])
        XCTAssertEqual(secondCalls.exact, [])
        XCTAssertEqual(cueStates(reopened), states)
        XCTAssertEqual(reopened.qualityCueEvidenceCacheForTesting?.snapshotReadsForTesting, 1)
        XCTAssertEqual(reopened.qualityCueEvidenceCacheForTesting?.snapshotWritesForTesting, 0,
                       "An unchanged folder rewrites nothing")
        close(reopened)

        try writeImage(to: folder.appendingPathComponent("C.jpg"), highlightFraction: 0.5, size: 96)
        let third = CueMeasurements()
        let changed = try open(folder, cache: cache, measurements: third, viewMode: .grid)
        try await settle(changed, evidence: 5)
        let thirdCalls = await third.snapshot
        XCTAssertEqual(thirdCalls.approximate, ["C.jpg"])
        XCTAssertEqual(thirdCalls.exact, [])
        close(changed)

        let fourth = CueMeasurements()
        let settled = try open(folder, cache: cache, measurements: fourth, viewMode: .grid)
        try await settle(settled, evidence: 5)
        let fourthCalls = await fourth.snapshot
        XCTAssertEqual(fourthCalls.approximate + fourthCalls.exact, [])
        close(settled)
    }

    func testThresholdChangeReevaluatesRestoredEvidenceWithoutMeasuring() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg", "C.jpg"])
        let cache = try temporaryDirectory()
        let first = CueMeasurements(highlightPercent: 20)
        let opened = try open(folder, cache: cache, measurements: first, viewMode: .grid)
        try await settle(opened, evidence: 3)
        close(opened)

        let second = CueMeasurements(highlightPercent: 20)
        let store = try open(folder, cache: cache, measurements: second, viewMode: .grid)
        try await settle(store, evidence: 3)
        XCTAssertEqual(store.qualityCues(for: store.items[0]).map(\.kind), [.highlightClipping])
        var preferences = store.qualityCuePreferences
        preferences.highlightPercentageThreshold = 21
        store.updateQualityCuePreferences(preferences)
        XCTAssertTrue(store.qualityCues(for: store.items[0]).isEmpty)
        preferences.highlightPercentageThreshold = 20
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(store.qualityCues(for: store.items[0]).map(\.kind), [.highlightClipping])
        try await settle(store, evidence: 3)
        let calls = await second.snapshot
        XCTAssertEqual(calls.approximate + calls.exact, [])
        XCTAssertEqual(store.qualityCueEvidenceCacheForTesting?.snapshotWritesForTesting, 0)
        close(store)
    }

    func testCuesOffReadNothingWriteNothingAndMeasureNothing() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg"])
        let cache = try temporaryDirectory()
        // A snapshot exists, so a read would find something.
        let seeded = try open(folder, cache: cache, measurements: CueMeasurements(), viewMode: .grid)
        try await settle(seeded, evidence: 2)
        close(seeded)
        let snapshot = try XCTUnwrap(snapshotFiles(in: cache).first)
        let before = try Data(contentsOf: snapshot)
        let written = try snapshot.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        for preferences in [CameraQualityWarningPreferences(isEnabled: false),
                            CameraQualityWarningPreferences(isClippingEnabled: false)] {
            let measurements = CueMeasurements()
            let store = try open(folder, cache: cache, measurements: measurements, viewMode: .gallery,
                                 preferences: preferences)
            for _ in 0..<40 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(50))
            store.setIndex(1)
            for _ in 0..<40 { await Task.yield() }
            let calls = await measurements.snapshot
            XCTAssertEqual(calls.approximate + calls.exact, [])
            XCTAssertNil(store.qualityCueEvidenceCacheForTesting, "No snapshot is opened with clipping cues off")
            XCTAssertTrue(store.qualityCueEvidence.isEmpty)
            await store.flushQualityCueEvidenceForTesting()
            close(store)
        }
        XCTAssertEqual(try Data(contentsOf: snapshot), before)
        XCTAssertEqual(try snapshot.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, written)
        XCTAssertEqual(try snapshotFiles(in: cache).count, 1)
    }

    func testTurningCuesOffBeforeTheWriteIsDueWritesNothing() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg"])
        let on = CameraQualityWarningPreferences()
        var off = on
        off.isClippingEnabled = false
        for closes in [false, true] {
            let cache = try temporaryDirectory()
            let measurements = CueMeasurements()
            let store = try open(folder, cache: cache, measurements: measurements, viewMode: .grid)
            // The coalesced write is due long after this test.
            store.qualityCueEvidenceFlushDelay = .seconds(600)
            try await waitUntil { store.isQualityCueWalkIdleForTesting && store.qualityCueEvidence.count == 2 }
            let evidence = try XCTUnwrap(store.qualityCueEvidenceCacheForTesting)
            XCTAssertTrue(evidence.hasUnsavedChanges)

            store.updateQualityCuePreferences(off)
            // Pause, Close and Quit write nothing either while cues are off.
            store.pauseQualityCueAnalysis(userInitiated: true)
            if closes { close(store) }
            await store.flushQualityCueEvidenceForTesting()
            for _ in 0..<40 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(evidence.snapshotWritesForTesting, 0, "Cues off: the pending write is retired")
            XCTAssertEqual(try snapshotFiles(in: cache), [])
            XCTAssertTrue(evidence.hasUnsavedChanges, "The evidence stays in memory")
            if closes { continue }

            // Cues on again: what was kept is written, and nothing is measured again.
            store.qualityCueEvidenceFlushDelay = .milliseconds(1)
            store.resumeQualityCueAnalysis()
            store.updateQualityCuePreferences(on)
            try await settle(store, evidence: 2)
            XCTAssertEqual(evidence.snapshotWritesForTesting, 1)
            XCTAssertEqual(evidence.storedRecordsForTesting()?.map(\.path), ["A.jpg", "B.jpg"])
            let calls = await measurements.snapshot
            XCTAssertEqual(calls.approximate.count, 2)
            close(store)
        }
    }

    func testReopeningAFolderWhileItsWriteIsPendingKeepsExactEvidence() async throws {
        let folderA = try makeFolder(["A.jpg", "B.jpg"])
        let folderB = try makeFolder(["X.jpg"])
        let cache = try temporaryDirectory()
        // A's snapshot holds estimates only.
        let seeded = try open(folderA, cache: cache, measurements: CueMeasurements(), viewMode: .grid)
        try await settle(seeded, evidence: 2)
        close(seeded)

        let measurements = CueMeasurements()
        let gate = CueWriteGate()
        let store = try open(folderA, cache: cache, measurements: measurements, viewMode: .grid)
        store.qualityCueEvidenceWriteGateForTesting = { await gate.wait() }
        func show(_ folder: URL) throws {
            store.items = try scan(folder)
            store.rebuildDerivedDataForTesting(sourceFolder: folder)
            store.phase = .ready
        }
        try await waitUntil { store.isQualityCueWalkIdleForTesting && store.qualityCueEvidence.count == 2 }
        store.viewMode = .gallery
        try await waitUntil { store.qualityEvidence(for: store.items[0])?.isApproximate == false }
        let first = try XCTUnwrap(store.qualityCueEvidenceCacheForTesting)

        // A → B: A's write with the exact result is still pending.
        store.viewMode = .grid
        try show(folderB)
        try await waitUntil { store.isQualityCueWalkIdleForTesting && store.qualityCueEvidence.count == 1 }
        XCTAssertFalse(store.qualityCueEvidenceCacheForTesting === first)
        XCTAssertEqual(first.snapshotWritesForTesting, 0)

        // B → A with a new photo, before that write.
        try writeImage(to: folderA.appendingPathComponent("C.jpg"), highlightFraction: 0.25, size: 48)
        try show(folderA)
        try await waitUntil { store.isQualityCueWalkIdleForTesting && store.qualityCueEvidence.count == 3 }
        XCTAssertEqual(store.items.map(\.displayName), ["A.jpg", "B.jpg", "C.jpg"])
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.isApproximate, false,
                       "The reopened folder sees the exact result that is not written yet")
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.highlightCount, CueMeasurements.exactHighlights)
        let calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg"])
        XCTAssertEqual(calls.approximate, ["X.jpg", "C.jpg"])

        await gate.open()
        await store.flushQualityCueEvidenceForTesting()
        let stored = try XCTUnwrap(QualityCueEvidenceCache(folder: folderA, cacheDirectory: cache)?
            .storedRecordsForTesting())
        XCTAssertEqual(stored.map(\.path), ["A.jpg", "B.jpg", "C.jpg"])
        XCTAssertEqual(stored.map(\.record.isApproximate), [false, true, true],
                       "No later write replaces the exact result with the older estimate")
        close(store)
    }

    func testOpenReturnsTheInstanceWithUnsavedEvidenceOnly() throws {
        let folder = try temporaryDirectory()
        let directory = try temporaryDirectory()
        let items = syntheticItems(count: 2, in: folder)
        let first = try XCTUnwrap(QualityCueEvidenceCache.open(folder: folder, cacheDirectory: directory))
        first.record(evidence(items[0], highlights: 30, approximate: true), for: items[0])
        XCTAssertTrue(first.flush())
        // Everything is on disk: a reopen reads the snapshot.
        let clean = try XCTUnwrap(QualityCueEvidenceCache.open(folder: folder, cacheDirectory: directory))
        XCTAssertFalse(clean === first)
        clean.record(evidence(items[0], highlights: 12), for: items[0])
        let pending = try XCTUnwrap(QualityCueEvidenceCache.open(folder: folder, cacheDirectory: directory))
        XCTAssertTrue(pending === clean, "Unsaved evidence has one owner per folder")
        XCTAssertEqual(pending.evidence(for: items).map(\.1.isApproximate), [false])
        pending.record(evidence(items[1], highlights: 5, approximate: true), for: items[1])
        XCTAssertTrue(pending.flush())
        XCTAssertEqual(pending.storedRecordsForTesting()?.map(\.record.isApproximate), [false, true])
        XCTAssertFalse(try XCTUnwrap(QualityCueEvidenceCache.open(folder: folder, cacheDirectory: directory)) === pending)
    }

    func testCorruptOrTruncatedSnapshotIsAMissAndIsRebuilt() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg", "C.jpg"])
        let cache = try temporaryDirectory()
        let seeded = try open(folder, cache: cache, measurements: CueMeasurements(), viewMode: .grid)
        try await settle(seeded, evidence: 3)
        close(seeded)
        let snapshot = try XCTUnwrap(snapshotFiles(in: cache).first)
        let valid = try Data(contentsOf: snapshot)

        var flipped = valid
        flipped[flipped.count / 2] ^= 0x40
        for damaged in [valid.prefix(valid.count / 2), Data(), Data("not a snapshot".utf8), flipped] {
            try Data(damaged).write(to: snapshot)
            let measurements = CueMeasurements()
            let store = try open(folder, cache: cache, measurements: measurements, viewMode: .grid)
            try await settle(store, evidence: 3)
            let calls = await measurements.snapshot
            XCTAssertEqual(calls.approximate.count, 3, "A damaged snapshot is measured again")
            close(store)
            XCTAssertEqual(try Data(contentsOf: snapshot), valid, "The rebuilt snapshot is deterministic")
        }

        let measurements = CueMeasurements()
        let store = try open(folder, cache: cache, measurements: measurements, viewMode: .grid)
        try await settle(store, evidence: 3)
        let calls = await measurements.snapshot
        XCTAssertEqual(calls.approximate + calls.exact, [])
        close(store)
    }

    func testRealOpeningOfNestedFoldersRestoresEvidenceAndLeavesTheSourceAlone() async throws {
        let root = try temporaryDirectory()
        let media = root.appendingPathComponent("media", isDirectory: true)
        let names = ["root.jpg", "A/one.jpg", "A/Nested/two.jpg", "B/three.jpg"]
        for name in names {
            let url = media.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeImage(to: url, highlightFraction: 0.25, size: 48)
        }
        let cache = root.appendingPathComponent("cue-cache", isDirectory: true)
        func openedStore(_ measurements: CueMeasurements) async throws -> SessionStore {
            let name = "QualityCueEvidenceCacheTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            CameraQualityWarningPreferences().save(to: defaults)
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            let store = SessionStore(
                persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                reviewDefaults: defaults,
                archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("navigation.json")),
                qualityCueMeasurement: { await measurements.exact($0) },
                qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
                qualityCueRest: { _ in await measurements.rest() })
            store.qualityCueApproximateMeasurement = { await measurements.approximate($0) }
            store.qualityCueEvidenceCacheDirectory = cache
            store.qualityCueEvidenceFlushDelay = .milliseconds(1)
            store.openFolder(media)
            try await waitUntil {
                if case .ready = store.phase { return true }
                return false
            }
            try await settle(store, evidence: 4)
            return store
        }
        func closed(_ store: SessionStore) async {
            store.beginTerminationPreparation()
            _ = await store.saveSessionForTermination()
            await store.flushQualityCueEvidenceForTesting()
        }

        let first = CueMeasurements()
        let opened = try await openedStore(first)
        let firstCalls = await first.snapshot
        XCTAssertEqual(firstCalls.exact.count, 1, "The shown photo")
        XCTAssertEqual(firstCalls.approximate.count, 3)
        let states = cueStates(opened)
        XCTAssertEqual(opened.qualityCueEvidenceCacheForTesting?.storedRecordsForTesting()?.map(\.path),
                       ["A/Nested/two.jpg", "A/one.jpg", "B/three.jpg", "root.jpg"])
        await closed(opened)

        let second = CueMeasurements()
        let reopened = try await openedStore(second)
        let secondCalls = await second.snapshot
        XCTAssertEqual(secondCalls.approximate + secondCalls.exact, [])
        XCTAssertEqual(cueStates(reopened), states)
        XCTAssertEqual(reopened.qualityCueEvidenceCacheForTesting?.snapshotWritesForTesting, 0)
        await closed(reopened)

        XCTAssertEqual(try snapshotFiles(in: cache).count, 1)
        let sourceFiles = try XCTUnwrap(FileManager.default.enumerator(at: media, includingPropertiesForKeys: nil))
            .compactMap { ($0 as? URL)?.lastPathComponent }
        XCTAssertFalse(sourceFiles.contains { $0.hasSuffix(".lqc") }, "Evidence never lands beside originals")
        XCTAssertEqual(Set(sourceFiles.filter { $0.hasSuffix(".jpg") }).count, 4)
    }

    // MARK: - Exact on show

    func testShownPhotoIsMeasuredExactlyOncePersistedAndNeverAgain() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg", "C.jpg", "D.jpg"])
        let cache = try temporaryDirectory()
        let first = CueMeasurements()
        // Without metadata rules, coverage depends on the image check alone.
        let preferences = CameraQualityWarningPreferences(isHighISOEnabled: false, isSlowShutterEnabled: false)
        let store = try open(folder, cache: cache, measurements: first, viewMode: .gallery, preferences: preferences)
        try await settle(store, evidence: 4)
        var calls = await first.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg"], "The shown photo is measured from the full image")
        XCTAssertEqual(Set(calls.approximate), ["B.jpg", "C.jpg", "D.jpg"])
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.isApproximate, false)
        XCTAssertEqual(store.qualityEvidence(for: store.items[2])?.isApproximate, true)
        XCTAssertEqual(store.qualityCueStatus(for: store.items[0]), .checked)
        XCTAssertEqual(store.qualityCueStatus(for: store.items[2]), .partial)

        store.setIndex(2)
        try await waitUntil { store.qualityEvidence(for: store.items[2])?.isApproximate == false }
        try await settle(store, evidence: 4)
        calls = await first.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg", "C.jpg"], "Opening a photo measures it exactly once")
        XCTAssertEqual(calls.approximate.count, 3)
        XCTAssertEqual(store.qualityEvidence(for: store.items[2])?.highlightCount, CueMeasurements.exactHighlights)
        // Leaving and returning measures nothing.
        store.setIndex(0)
        store.setIndex(2)
        try await settle(store, evidence: 4)
        calls = await first.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg", "C.jpg"])
        let stored = try XCTUnwrap(store.qualityCueEvidenceCacheForTesting?.storedRecordsForTesting())
        XCTAssertEqual(stored.map(\.path), ["A.jpg", "B.jpg", "C.jpg", "D.jpg"])
        XCTAssertEqual(stored.map(\.record.isApproximate), [false, true, false, true])
        let states = cueStates(store)
        close(store)

        let second = CueMeasurements()
        let reopened = try open(folder, cache: cache, measurements: second, viewMode: .gallery, preferences: preferences)
        try await settle(reopened, evidence: 4)
        reopened.setIndex(2)
        try await settle(reopened, evidence: 4)
        calls = await second.snapshot
        XCTAssertEqual(calls.approximate + calls.exact, [], "Persisted exact evidence is never measured again")
        XCTAssertEqual(cueStates(reopened), states)
        reopened.setIndex(3)
        try await waitUntil { reopened.qualityEvidence(for: reopened.items[3])?.isApproximate == false }
        try await settle(reopened, evidence: 4)
        calls = await second.snapshot
        XCTAssertEqual(calls.exact, ["D.jpg"])
        XCTAssertEqual(calls.approximate, [])
        close(reopened)
    }

    func testGridShowsExactOnlyBesideInfoAndSwitchingToGalleryMeasuresTheShownPhoto() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg"])
        let measurements = CueMeasurements()
        let store = try open(folder, cache: try temporaryDirectory(), measurements: measurements, viewMode: .grid)
        try await settle(store, evidence: 2)
        var calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, [])
        store.viewMode = .gallery
        try await waitUntil { store.qualityEvidence(for: store.items[0])?.isApproximate == false }
        store.viewMode = .grid
        store.setIndex(1)
        try await settle(store, evidence: 2)
        calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg"])
        // Info's histogram asks for the same full measurement.
        store.showMetadataPanel = true
        try await waitUntil { store.qualityEvidence(for: store.items[1])?.isApproximate == false }
        calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg", "B.jpg"])
        XCTAssertEqual(calls.approximate.count, 2)
        close(store)
    }

    func testGridMultiSelectionBesideInfoMeasuresNothingExactly() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg", "C.jpg"])
        let measurements = CueMeasurements()
        let store = try open(folder, cache: try temporaryDirectory(), measurements: measurements, viewMode: .grid)
        try await settle(store, evidence: 3)
        // Info shows a selection summary and no histogram.
        store.selectAllVisible()
        XCTAssertEqual(store.selectedIndices, [0, 1, 2])
        store.showMetadataPanel = true
        for _ in 0..<40 { await Task.yield() }
        try await settle(store, evidence: 3)
        store.toggleSelection(of: 2)
        XCTAssertEqual(store.selectedIndices, [0, 1])
        for _ in 0..<40 { await Task.yield() }
        try await settle(store, evidence: 3)
        var calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, [], "Several selected photos: nothing is inspected")
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.isApproximate, true)

        // One selected photo is inspected: Info draws its histogram.
        store.toggleSelection(of: 1)
        XCTAssertLessThanOrEqual(store.selectedIndices.count, 1)
        XCTAssertEqual(store.currentIndex, 0)
        try await waitUntil { store.qualityEvidence(for: store.items[0])?.isApproximate == false }
        try await settle(store, evidence: 3)
        calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg"])

        // Gallery shows the current photo whatever the selection.
        store.selectAllVisible()
        store.viewMode = .gallery
        store.currentIndex = 1
        XCTAssertEqual(store.selectedIndices.count, 3)
        try await waitUntil { store.qualityEvidence(for: store.items[1])?.isApproximate == false }
        close(store)
    }

    func testShowingAnotherPhotoRetiresTheExactRequestInFlight() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg"])
        let measurements = CueMeasurements()
        let store = try open(folder, cache: try temporaryDirectory(), measurements: measurements, viewMode: .grid)
        try await settle(store, evidence: 2)
        await measurements.holdExact("A.jpg")
        store.viewMode = .gallery
        try await waitUntil { await measurements.snapshot.exact == ["A.jpg"] }
        store.setIndex(1)
        try await waitUntil { await measurements.retiredExact == ["A.jpg"] }
        try await waitUntil { store.qualityEvidence(for: store.items[1])?.isApproximate == false }
        try await settle(store, evidence: 2)
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.isApproximate, true)
        var calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg", "B.jpg"])
        // A retired request is no attempt: the photo is measured when shown again.
        await measurements.releaseExact("A.jpg")
        store.setIndex(0)
        try await waitUntil { store.qualityEvidence(for: store.items[0])?.isApproximate == false }
        calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg", "B.jpg", "A.jpg"])
        close(store)
    }

    func testFailedExactMeasurementKeepsTheEstimateAndIsNotRetried() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg"])
        let measurements = CueMeasurements(exactFails: true)
        let store = try open(folder, cache: try temporaryDirectory(), measurements: measurements, viewMode: .grid)
        try await settle(store, evidence: 2)
        store.viewMode = .gallery
        try await waitUntil { await measurements.snapshot.exact == ["A.jpg"] }
        try await settle(store, evidence: 2)
        store.setIndex(1)
        try await waitUntil { await measurements.snapshot.exact == ["A.jpg", "B.jpg"] }
        store.setIndex(0)
        try await settle(store, evidence: 2)
        let calls = await measurements.snapshot
        XCTAssertEqual(calls.exact, ["A.jpg", "B.jpg"])
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.isApproximate, true)
        XCTAssertEqual(store.qualityEvidence(for: store.items[0])?.sampleCount, 100)
        XCTAssertEqual(store.qualityCueEvidenceCacheForTesting?.storedRecordsForTesting()?.map(\.record.isApproximate),
                       [true, true])
        close(store)
    }

    // MARK: - Publication and pacing

    func testFullyCachedFolderAppliesItsCuesInAFewPublications() async throws {
        let folder = try temporaryDirectory()
        let cacheDirectory = try temporaryDirectory()
        let items = syntheticItems(count: 5_000, in: folder)
        let cache = try XCTUnwrap(QualityCueEvidenceCache(folder: folder, cacheDirectory: cacheDirectory))
        for (index, item) in items.enumerated() {
            cache.record(evidence(item, highlights: index % 2 == 0 ? 20 : 0, approximate: true), for: item)
        }
        XCTAssertTrue(cache.flush())
        XCTAssertLessThan(try Data(contentsOf: cache.cacheURL).count, 5_000 * 48)

        let measurements = CueMeasurements()
        let store = makeStore(cache: cacheDirectory, measurements: measurements)
        var publications = 0
        let observer = store.qualityCuePublication.objectWillChange.sink { publications += 1 }
        defer { observer.cancel() }
        store.viewMode = .grid
        store.showMetadataPanel = false
        store.items = items
        store.rebuildDerivedDataForTesting(sourceFolder: folder)
        publications = 0
        let storeTurns = store.publicationTurnsForTesting
        store.phase = .ready
        try await settle(store, evidence: 5_000)
        let calls = await measurements.snapshot
        XCTAssertEqual(calls.approximate + calls.exact, [])
        XCTAssertEqual(publications, 3, "5,000 restored photos publish in 2,048-photo batches")
        XCTAssertLessThanOrEqual(store.publicationTurnsForTesting - storeTurns, 1,
                                 "Restoring evidence publishes on the cue object, not the store")
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 5_000)
        XCTAssertEqual(store.qualityCues(for: store.items[0]).map(\.kind), [.highlightClipping])
        XCTAssertTrue(store.qualityCues(for: store.items[1]).isEmpty)
        close(store)
    }

    func testRestoredCueFilterShowsMatchesBeforeAnyMeasurement() async throws {
        let folder = try makeFolder(["A.jpg", "B.jpg", "C.jpg"])
        let cache = try temporaryDirectory()
        let seeded = try open(folder, cache: cache, measurements: CueMeasurements(highlightPercent: 20), viewMode: .grid)
        try await settle(seeded, evidence: 3)
        close(seeded)

        let measurements = CueMeasurements()
        let store = makeStore(cache: cache, measurements: measurements)
        store.viewMode = .grid
        store.showMetadataPanel = false
        store.items = try scan(folder)
        store.rebuildDerivedDataForTesting(sourceFolder: folder)
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.phase = .ready
        try await settle(store, evidence: 3)
        XCTAssertEqual(store.visibleIndices.count, 3)
        let calls = await measurements.snapshot
        XCTAssertEqual(calls.approximate + calls.exact, [])
        close(store)
    }

    func testEstimatesRunInLargerBatchesThanExactMeasurements() async throws {
        let folder = try makeFolder((0..<40).map { String(format: "P%02d.jpg", $0) }, size: 16)
        let measurements = CueMeasurements()
        let store = try open(folder, cache: try temporaryDirectory(), measurements: measurements, viewMode: .grid)
        try await settle(store, evidence: 40)
        let batches = await measurements.restBoundaries
        XCTAssertEqual(batches, [32, 40], "Estimates are cheap: 32 per batch, then rest")
        close(store)
    }

    // MARK: - Real pipelines

    func testFolderWalkStartsNoFullDecodeAndNoRAWRender() async throws {
        let folder = try makeFolder(["One.jpg", "Two.jpg", "Three.jxl", "Four.RAF"], size: 400)
        let scanned = try scan(folder)
        XCTAssertEqual(scanned.map(\.displayName), ["Four.RAF", "One.jpg", "Three.jxl", "Two.jpg"])
        let whole = try XCTUnwrap(scanned.first { $0.displayName == "Three.jxl" })
        let raw = try XCTUnwrap(scanned.first { $0.displayName == "Four.RAF" })
        XCTAssertTrue(RawHistogramPipeline.supportsAnalysis(for: raw))
        XCTAssertTrue(ImagePipeline.decodesWholeImage(whole))

        let full = ImagePipeline.shared.sourceDecodesForTesting
        let histogram = HistogramPipeline.shared.sourceDecodesForTesting
        let rawRenders = RawHistogramPipeline.shared.sourceDecodesForTesting
        let estimates = HistogramPipeline.shared.approximateWorkForTesting

        let store = makeStore(cache: try temporaryDirectory(), measurements: nil)
        store.viewMode = .grid
        store.showMetadataPanel = false
        store.items = scanned
        store.rebuildDerivedDataForTesting(sourceFolder: folder)
        store.phase = .ready
        try await settle(store, evidence: 3)

        XCTAssertEqual(ImagePipeline.shared.sourceDecodesForTesting.full, full.full, "No Fit-size decode")
        XCTAssertEqual(ImagePipeline.shared.sourceDecodesForTesting.thumbnail, full.thumbnail,
                       "The walk starts no thumbnail decode, so no whole JPEG XL decode")
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting, histogram, "No 1,024-pixel analysis decode")
        XCTAssertEqual(RawHistogramPipeline.shared.sourceDecodesForTesting, rawRenders, "No RAW render")
        XCTAssertEqual(HistogramPipeline.shared.approximateWorkForTesting.sourceDecodes - estimates.sourceDecodes, 3,
                       "Photos without a cached thumbnail take one thumbnail-size decode")
        XCTAssertNil(store.qualityEvidence(for: whole), "A JPEG XL photo without a thumbnail waits")
        let rawEvidence = try XCTUnwrap(store.qualityEvidence(for: raw))
        XCTAssertTrue(rawEvidence.isApproximate)
        XCTAssertEqual(rawEvidence.source, .renderedPreview)
        XCTAssertLessThanOrEqual(max(rawEvidence.width, rawEvidence.height), Int(ImagePipeline.thumbPixelSize))
        XCTAssertGreaterThan(rawEvidence.sampleCount, 0)

        // The tile's thumbnail arrives; its appearance retries the estimate.
        _ = await ImagePipeline.shared.thumbnail(for: whole)
        store.prioritizeQualityCues(for: whole)
        try await waitUntil { store.qualityEvidence(for: whole) != nil }
        try await settle(store, evidence: 4)
        XCTAssertEqual(store.qualityEvidence(for: whole)?.isApproximate, true)
        XCTAssertEqual(HistogramPipeline.shared.approximateWorkForTesting.thumbnailReuses - estimates.thumbnailReuses, 1)
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting, histogram)
        XCTAssertEqual(ImagePipeline.shared.sourceDecodesForTesting.full, full.full)
        XCTAssertEqual(store.qualityCueEvidenceCacheForTesting?.storedRecordsForTesting()?.map(\.record.isApproximate),
                       [true, true, true, true])

        // Showing a photo measures it once from the full-size analysis.
        let shown = try XCTUnwrap(store.items.firstIndex { $0.displayName == "One.jpg" })
        store.setIndex(shown)
        store.showMetadataPanel = true
        try await waitUntil { store.qualityEvidence(for: store.items[shown])?.isApproximate == false }
        try await settle(store, evidence: 4)
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting - histogram, 1)
        XCTAssertEqual(RawHistogramPipeline.shared.sourceDecodesForTesting, rawRenders)
        let exact = try XCTUnwrap(store.qualityEvidence(for: store.items[shown]))
        XCTAssertGreaterThan(max(exact.width, exact.height), Int(ImagePipeline.thumbPixelSize))
        close(store)
    }

    func testGalleryExactMeasurementSharesGallerysFitAndDecodesNothingItself() async throws {
        // One photo: Gallery prefetches no neighbour's Fit preview.
        let folder = try makeFolder(["Whole.jxl"], size: 400)
        let scanned = try scan(folder)
        let whole = try XCTUnwrap(scanned.first)
        XCTAssertTrue(ImagePipeline.decodesWholeImage(whole))
        let full = ImagePipeline.shared.sourceDecodesForTesting
        let histogram = HistogramPipeline.shared.sourceDecodesForTesting

        // The walk asks before Gallery has requested its Fit preview.
        let store = makeStore(cache: try temporaryDirectory(), measurements: nil)
        store.viewMode = .gallery
        store.showMetadataPanel = true
        store.items = scanned
        store.rebuildDerivedDataForTesting(sourceFolder: folder)
        store.phase = .ready
        try await waitUntil { store.isQualityCueWalkIdleForTesting }
        XCTAssertNil(store.qualityEvidence(for: whole))
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting, histogram,
                       "The cue never decodes a JPEG XL photo that Gallery is about to decode")
        XCTAssertEqual(ImagePipeline.shared.sourceDecodesForTesting.full, full.full)

        // Gallery decodes and publishes; the cue measures those pixels.
        let fit = await ImagePipeline.shared.fullImage(for: whole)
        XCTAssertNotNil(fit)
        store.reportPhotoRepresentation(.preview, revision: whole.contentRevision)
        try await waitUntil { store.qualityEvidence(for: whole)?.isApproximate == false }
        try await settle(store, evidence: 1)
        XCTAssertGreaterThan(store.qualityEvidence(for: whole)?.sampleCount ?? 0, 0)
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting, histogram)
        XCTAssertEqual(ImagePipeline.shared.sourceDecodesForTesting.full - full.full, 1)
        XCTAssertEqual(store.qualityCueEvidenceCacheForTesting?.storedRecordsForTesting()?.map(\.record.isApproximate),
                       [false])
        close(store)
    }

    func testInfoInGridStillMeasuresAJPEGXLPhotoOnItsOwn() async throws {
        let folder = try makeFolder(["Whole.jxl"], size: 400)
        let whole = try XCTUnwrap(try scan(folder).first)
        let histogram = HistogramPipeline.shared.sourceDecodesForTesting
        let store = makeStore(cache: try temporaryDirectory(), measurements: nil)
        store.viewMode = .gallery
        store.showMetadataPanel = true
        store.items = [whole]
        store.rebuildDerivedDataForTesting(sourceFolder: folder)
        store.phase = .ready
        try await waitUntil { store.isQualityCueWalkIdleForTesting }
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting, histogram)
        // No single-photo view will decode it now: Info's histogram does.
        store.viewMode = .grid
        try await waitUntil { store.qualityEvidence(for: whole)?.isApproximate == false }
        try await settle(store, evidence: 1)
        XCTAssertEqual(HistogramPipeline.shared.sourceDecodesForTesting - histogram, 1)
        close(store)
    }

    func testEstimateReusesTheDiskThumbnailWithoutTouchingTheOriginal() async throws {
        let folder = try makeFolder(["Kept.jpg", "Whole.jxl"], size: 400)
        let scanned = try scan(folder)
        let root = try temporaryDirectory()
        let images = ImagePipeline(testingDiskCacheRoot: root)
        let pipeline = HistogramPipeline(imagePipeline: images)
        for item in scanned {
            _ = await images.thumbnail(for: item)
            images.evictThumbnailForTesting(for: item)
        }
        await images.waitForPendingDiskWrites()
        let decodes = images.sourceDecodesForTesting
        for item in scanned {
            guard case .measured(let analysis) = await pipeline.approximateAnalysis(for: item) else {
                return XCTFail("\(item.displayName) has a disk thumbnail")
            }
            XCTAssertEqual(max(analysis.width, analysis.height), Int(ImagePipeline.thumbPixelSize))
            XCTAssertEqual(analysis.highlightPercentage, 25, accuracy: 2)
        }
        XCTAssertEqual(pipeline.approximateWorkForTesting.thumbnailReuses, 2)
        XCTAssertEqual(pipeline.approximateWorkForTesting.sourceDecodes, 0)
        XCTAssertEqual(pipeline.sourceDecodesForTesting, 0)
        XCTAssertEqual(images.sourceDecodesForTesting.thumbnail, decodes.thumbnail)
        XCTAssertEqual(images.sourceDecodesForTesting.full, decodes.full)

        // Without a thumbnail a JPEG XL photo is left alone; others decode small.
        let empty = HistogramPipeline(imagePipeline: ImagePipeline(testingDiskCacheRoot: try temporaryDirectory()))
        for item in scanned {
            let result = await empty.approximateAnalysis(for: item)
            if ImagePipeline.decodesWholeImage(item) {
                guard case .noCheapSource = result else { return XCTFail("JPEG XL must not be decoded") }
            } else {
                guard case .measured = result else { return XCTFail("JPEG decodes at thumbnail size") }
            }
        }
        XCTAssertEqual(empty.approximateWorkForTesting.sourceDecodes, 1)
        XCTAssertEqual(empty.sourceDecodesForTesting, 0)
    }

    // MARK: - Snapshot rules

    func testExactAlwaysWinsAndIdentityOwnsHits() throws {
        let folder = try temporaryDirectory()
        let directory = try temporaryDirectory()
        let items = syntheticItems(count: 3, in: folder)
        let cache = try XCTUnwrap(QualityCueEvidenceCache(folder: folder, cacheDirectory: directory))
        cache.record(evidence(items[0], highlights: 30, approximate: true), for: items[0])
        cache.record(evidence(items[0], highlights: 12), for: items[0])
        cache.record(evidence(items[0], highlights: 40, approximate: true), for: items[0])
        cache.record(evidence(items[1], highlights: 5, approximate: true), for: items[1])
        cache.record(evidence(items[1], highlights: 7, approximate: true), for: items[1])
        // Failed and fallback measurements are retried, never stored.
        cache.record(QualityCueEvidence(item: items[2], analysis: nil, source: .renderedPreview), for: items[2])
        cache.record(QualityCueEvidence(item: items[2], analysis: analysis(highlights: 1), source: .renderedPreview,
                                        rawFallback: true), for: items[2])
        XCTAssertTrue(cache.flush())
        XCTAssertFalse(cache.flush(), "Nothing new: no second write")

        let reopened = try XCTUnwrap(QualityCueEvidenceCache(folder: folder, cacheDirectory: directory))
        let hits = Dictionary(uniqueKeysWithValues: reopened.evidence(for: items))
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[items[0].id]?.highlightCount, 12)
        XCTAssertEqual(hits[items[0].id]?.isApproximate, false)
        XCTAssertEqual(hits[items[1].id]?.highlightCount, 7)
        XCTAssertEqual(hits[items[1].id]?.isApproximate, true)
        XCTAssertEqual(hits[items[0].id], evidence(items[0], highlights: 12))

        // Same path, another file: every identity field must match.
        let replaced = syntheticItems(count: 3, in: folder, inodeOffset: 100)
        XCTAssertTrue(reopened.evidence(for: replaced).isEmpty)
        let resized = syntheticItems(count: 3, in: folder, fileSize: 2)
        XCTAssertTrue(reopened.evidence(for: resized).isEmpty)
        let touched = syntheticItems(count: 3, in: folder, modifiedSeconds: 2)
        XCTAssertTrue(reopened.evidence(for: touched).isEmpty)
        // A new file's estimate replaces the old file's exact entry.
        reopened.record(evidence(replaced[0], highlights: 3, approximate: true), for: replaced[0])
        XCTAssertTrue(reopened.flush())
        let again = try XCTUnwrap(QualityCueEvidenceCache(folder: folder, cacheDirectory: directory))
        XCTAssertEqual(again.evidence(for: replaced).map(\.1.highlightCount), [3])
        XCTAssertTrue(again.evidence(for: items).isEmpty, "Unmatched entries are not written again")
    }

    func testContextsAndFolderOwnTheSnapshot() throws {
        let folder = try temporaryDirectory()
        let directory = try temporaryDirectory()
        let items = syntheticItems(count: 2, in: folder, pathExtensions: ["RAF", "JPG"])
        func cache(analyzer: String = "A1", decoder: String = "27.2.0|26B1") -> QualityCueEvidenceCache? {
            QualityCueEvidenceCache(folder: folder, cacheDirectory: directory,
                                    analyzerContext: analyzer, decoderContext: decoder)
        }
        let written = try XCTUnwrap(cache())
        written.record(QualityCueEvidence(item: items[0], analysis: analysis(highlights: 9), source: .rawDecode),
                       for: items[0])
        written.record(evidence(items[1], highlights: 4), for: items[1])
        // An estimate is never a RAW decode, and exact RAW evidence is.
        written.record(QualityCueEvidence(item: items[1], analysis: analysis(highlights: 4), source: .rawDecode),
                       for: items[1])
        XCTAssertTrue(written.flush())
        XCTAssertEqual(try XCTUnwrap(cache()).evidence(for: items).count, 2)
        XCTAssertEqual(try XCTUnwrap(cache(decoder: "27.3.0|26C1")).evidence(for: items).map(\.0), [items[1].id],
                       "Another OS build keeps rendered evidence and drops RAW decodes")
        XCTAssertTrue(try XCTUnwrap(cache(analyzer: "A2")).evidence(for: items).isEmpty)
        let elsewhere = try temporaryDirectory()
        XCTAssertTrue(try XCTUnwrap(QualityCueEvidenceCache(folder: elsewhere, cacheDirectory: directory,
            analyzerContext: "A1", decoderContext: "27.2.0|26B1")).evidence(for: items).isEmpty)
        XCTAssertFalse(QualityCueEvidenceCache.analyzerContext.contains(String(
            CameraQualityWarningPreferences.defaultClippingPercentageThreshold)),
            "The user's thresholds are not part of the key")
    }

    func testEveryTruncationAndForeignDataDecodeToNothing() throws {
        let folder = try temporaryDirectory()
        let items = syntheticItems(count: 12, in: folder)
        let cache = try XCTUnwrap(QualityCueEvidenceCache(folder: folder, cacheDirectory: try temporaryDirectory()))
        for item in items { cache.record(evidence(item, highlights: 3, approximate: true), for: item) }
        XCTAssertTrue(cache.flush())
        let data = try Data(contentsOf: cache.cacheURL)
        XCTAssertEqual(cache.storedRecordsForTesting()?.count, 12)
        let binding = "binding"
        let entries: [String: QualityCueEvidenceCache.Record] = ["a.jpg": .init(identityHigh: 1, identityLow: 2,
            source: .renderedPreview, isApproximate: true, width: 320, height: 213, sampleCount: 68_160,
            shadowCount: 10, highlightCount: 20)]
        let encoded = try XCTUnwrap(QualityCueEvidenceCache.encode(entries, analyzerContext: "A", decoderContext: "D",
                                                                   folderBinding: binding))
        XCTAssertEqual(QualityCueEvidenceCache.decode(encoded, analyzerContext: "A", decoderContext: "D",
                                                      folderBinding: binding), entries)
        for length in 0..<encoded.count {
            XCTAssertNil(QualityCueEvidenceCache.decode(encoded.prefix(length), analyzerContext: "A",
                decoderContext: "D", folderBinding: binding), "prefix \(length)")
        }
        for index in encoded.indices {
            var damaged = encoded
            damaged[index] ^= 1
            XCTAssertNil(QualityCueEvidenceCache.decode(damaged, analyzerContext: "A", decoderContext: "D",
                                                        folderBinding: binding), "byte \(index)")
        }
        XCTAssertNil(QualityCueEvidenceCache.decode(encoded + Data([0]), analyzerContext: "A",
                                                    decoderContext: "D", folderBinding: binding))
        XCTAssertGreaterThan(data.count, encoded.count)
    }

    func testOldestSnapshotsAreEvictedAndForeignFilesStay() throws {
        let folder = try temporaryDirectory()
        let directory = try temporaryDirectory()
        let old = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        var stale: [URL] = []
        for index in 0..<(QualityCueEvidenceCache.maximumFolderSnapshots + 4) {
            let url = directory.appendingPathComponent(
                String(repeating: "0", count: 60) + String(format: "%04x", index) + ".lqc")
            try Data([1]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(Double(index))],
                                                  ofItemAtPath: url.path)
            stale.append(url)
        }
        let foreign = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(-100)], ofItemAtPath: foreign.path)
        let cache = try XCTUnwrap(QualityCueEvidenceCache(folder: folder, cacheDirectory: directory))
        let item = syntheticItems(count: 1, in: folder)[0]
        cache.record(evidence(item, highlights: 1), for: item)
        XCTAssertTrue(cache.flush())
        XCTAssertEqual(try snapshotFiles(in: directory).count, QualityCueEvidenceCache.maximumFolderSnapshots)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale[0].path), "Oldest first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale[4].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale[5].path))
    }

    /// Prints estimate and exact clipping for real photos. Set
    /// LOUPPE_CUE_COMPARE_FOLDERS (colon-separated) and, optionally,
    /// LOUPPE_CUE_COMPARE_OUTPUT (a TSV path) and LOUPPE_CUE_COMPARE_LIMIT.
    func testCompareEstimateWithExactOnRealPhotos() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folders = environment["LOUPPE_CUE_COMPARE_FOLDERS"], !folders.isEmpty else {
            throw XCTSkip("Set LOUPPE_CUE_COMPARE_FOLDERS to compare estimates with exact evidence")
        }
        let limit = environment["LOUPPE_CUE_COMPARE_LIMIT"].flatMap(Int.init) ?? 40
        let images = ImagePipeline(testingDiskCacheRoot: try temporaryDirectory())
        let estimator = HistogramPipeline(imagePipeline: images)
        let direct = HistogramPipeline(imagePipeline: ImagePipeline(testingDiskCacheRoot: try temporaryDirectory()))
        var lines = ["file\tkind\tsource\tthumb_shadow\tthumb_highlight\tdecode_shadow\tdecode_highlight\texact_shadow\texact_highlight"]
        func text(_ analysis: HistogramAnalysis?) -> String {
            analysis.map { String(format: "%.2f\t%.2f", $0.shadowPercentage, $0.highlightPercentage) } ?? "-\t-"
        }
        for path in folders.split(separator: ":") {
            var taken: [String: Int] = [:]
            for item in try scan(URL(fileURLWithPath: String(path))) where item.mediaKind == .photo && item.isSupported {
                let kind = item.primaryURL.pathExtension.lowercased()
                guard !item.displayName.hasPrefix("FRAME_"), taken[kind, default: 0] < limit else { continue }
                taken[kind, default: 0] += 1
                var decoded: HistogramAnalysis?
                if case .measured(let analysis) = await direct.approximateAnalysis(for: item) { decoded = analysis }
                _ = await images.thumbnail(for: item)
                await images.waitForPendingDiskWrites()
                images.evictThumbnailForTesting(for: item)
                var thumbnail: HistogramAnalysis?
                if case .measured(let analysis) = await estimator.approximateAnalysis(for: item) { thumbnail = analysis }
                let exact = await QualityCueEvidence.measure(item)
                lines.append("\(item.displayName)\t\(kind)\t\(exact.rawFallback ? "fallback" : exact.source.shortLabel)\t"
                             + "\(text(thumbnail))\t\(text(decoded))\t\(text(exact.analysis))")
            }
        }
        let report = lines.joined(separator: "\n") + "\n"
        if let output = environment["LOUPPE_CUE_COMPARE_OUTPUT"] {
            try report.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
        XCTAssertGreaterThan(lines.count, 1)
    }

    /// Counts real decodes for a folder of camera files. Set
    /// LOUPPE_CUE_REAL_FOLDER; originals are only read.
    func testRealFolderWalkCountsAndReopen() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_CUE_REAL_FOLDER"], !path.isEmpty else {
            throw XCTSkip("Set LOUPPE_CUE_REAL_FOLDER to count decodes on real camera files")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let cache = try temporaryDirectory()
        let scanned = try scan(folder)
        let photos = scanned.filter { $0.mediaKind == .photo && $0.isSupported }
        let raw = try XCTUnwrap(photos.firstIndex { RawHistogramPipeline.supportsAnalysis(for: $0) })
        func counters() -> [Int] {
            [ImagePipeline.shared.sourceDecodesForTesting.full, HistogramPipeline.shared.sourceDecodesForTesting,
             RawHistogramPipeline.shared.sourceDecodesForTesting,
             HistogramPipeline.shared.approximateWorkForTesting.sourceDecodes,
             HistogramPipeline.shared.approximateWorkForTesting.thumbnailReuses]
        }
        func opened() async throws -> SessionStore {
            let store = makeStore(cache: cache, measurements: nil)
            store.viewMode = .grid
            store.showMetadataPanel = false
            store.items = photos
            store.rebuildDerivedDataForTesting(sourceFolder: folder)
            store.phase = .ready
            try await waitUntil(timeout: .seconds(120)) {
                store.isQualityCueWalkIdleForTesting && store.qualityCueEvidence.count == photos.count
            }
            await store.flushQualityCueEvidenceForTesting()
            return store
        }
        var before = counters()
        let first = try await opened()
        var delta = zip(counters(), before).map(-)
        print("CUE-REAL first walk: photos \(photos.count), full \(delta[0]), 1024 \(delta[1]), raw \(delta[2]), "
              + "estimate decodes \(delta[3]), thumbnail reuses \(delta[4])")
        XCTAssertEqual(Array(delta[0...2]), [0, 0, 0])
        XCTAssertEqual(delta[3] + delta[4], photos.count)

        before = counters()
        first.setIndex(raw)
        first.showMetadataPanel = true
        try await waitUntil(timeout: .seconds(60)) { first.qualityEvidence(for: first.items[raw])?.isApproximate == false }
        try await settle(first, evidence: photos.count)
        delta = zip(counters(), before).map(-)
        print("CUE-REAL shown RAW: full \(delta[0]), 1024 \(delta[1]), raw \(delta[2]), estimates \(delta[3] + delta[4])")
        XCTAssertEqual(delta[2], 1, "One RAW render for the shown photo")
        XCTAssertEqual(first.qualityEvidence(for: first.items[raw])?.source, .rawDecode)
        close(first)

        before = counters()
        let second = try await opened()
        second.setIndex(raw)
        second.showMetadataPanel = true
        try await settle(second, evidence: photos.count)
        delta = zip(counters(), before).map(-)
        print("CUE-REAL reopen: full \(delta[0]), 1024 \(delta[1]), raw \(delta[2]), "
              + "estimate decodes \(delta[3]), thumbnail reuses \(delta[4])")
        XCTAssertEqual(delta, [0, 0, 0, 0, 0])
        XCTAssertEqual(second.qualityEvidence(for: second.items[raw])?.isApproximate, false)
        close(second)
    }

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeCueEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// JPEG bytes under every name: `.jxl` exercises the whole-image rule and
    /// `.RAF` the RAW rule. A quarter of each picture is white.
    private func makeFolder(_ names: [String], size: Int = 48) throws -> URL {
        let folder = try temporaryDirectory()
        for name in names {
            try writeImage(to: folder.appendingPathComponent(name), highlightFraction: 0.25, size: size)
        }
        return folder
    }

    private func writeImage(to url: URL, highlightFraction: Double, size: Int) throws {
        let height = size * 3 / 4
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Double(size) * highlightFraction, height: Double(height)))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
    }

    private func scan(_ folder: URL) throws -> [PhotoItem] {
        try FolderScanner.scan(folder, progress: { _ in }).sorted { $0.displayName < $1.displayName }
    }

    private func snapshotFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == QualityCueEvidenceCache.snapshotExtension }
    }

    private func syntheticItems(count: Int, in folder: URL, inodeOffset: UInt64 = 0, fileSize: Int64 = 1,
                                modifiedSeconds: Int64 = 1, pathExtensions: [String]? = nil) -> [PhotoItem] {
        (0..<count).map { index in
            let id = String(format: "sub/SYNTHETIC_%05d.", index) + (pathExtensions?[index] ?? "JPG")
            let time = FileOperationJournal.FileIdentity.Timestamp(seconds: modifiedSeconds, nanoseconds: 7)
            return PhotoItem(primaryFile: PhotoFile(
                id: id, url: folder.appendingPathComponent(id),
                captureDate: Date(timeIntervalSince1970: Double(index)), cameraModel: nil, lensModel: nil,
                fileSize: fileSize,
                scannedIdentity: FileOperationJournal.FileIdentity(volumeRootPath: "/Volumes/CUES",
                    volumeUUIDString: "0A0A0A0A-0000-4000-8000-000000000001", systemNumber: 77,
                    fileNumber: UInt64(index) + 1_000 + inodeOffset, logicalSize: fileSize, modificationTime: time,
                    statusChangeTime: time, birthTime: time)))
        }
    }

    private func analysis(highlights: Int) -> HistogramAnalysis {
        HistogramAnalysis(bins: [], sampleCount: 100, shadowCount: 0, highlightCount: highlights, width: 10, height: 10)
    }

    private func evidence(_ item: PhotoItem, highlights: Int, approximate: Bool = false) -> QualityCueEvidence {
        QualityCueEvidence(item: item, analysis: analysis(highlights: highlights), source: .renderedPreview,
                           isApproximate: approximate)
    }

    private func makeStore(cache: URL, measurements: CueMeasurements?,
                           preferences: CameraQualityWarningPreferences = .init()) -> SessionStore {
        let name = "QualityCueEvidenceCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        preferences.save(to: defaults)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let store: SessionStore
        if let measurements {
            store = SessionStore(reviewDefaults: defaults,
                qualityCueMeasurement: { await measurements.exact($0) },
                qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
                qualityCueRest: { _ in await measurements.rest() })
            store.qualityCueApproximateMeasurement = { await measurements.approximate($0) }
        } else {
            store = SessionStore(reviewDefaults: defaults,
                qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
                qualityCueRest: { _ in await Task.yield() })
        }
        store.qualityCueEvidenceCacheDirectory = cache
        store.qualityCueEvidenceFlushDelay = .milliseconds(1)
        addTeardownBlock { await MainActor.run { store.beginTerminationPreparation() } }
        return store
    }

    private func open(_ folder: URL, cache: URL, measurements: CueMeasurements, viewMode: ViewMode,
                      preferences: CameraQualityWarningPreferences = .init()) throws -> SessionStore {
        let store = makeStore(cache: cache, measurements: measurements, preferences: preferences)
        store.viewMode = viewMode
        store.showMetadataPanel = false
        store.items = try scan(folder)
        store.rebuildDerivedDataForTesting(sourceFolder: folder)
        store.phase = .ready
        return store
    }

    private func close(_ store: SessionStore) {
        store.beginTerminationPreparation()
    }

    /// The walk has finished, the expected evidence is in, the snapshot is written.
    private func settle(_ store: SessionStore, evidence count: Int) async throws {
        try await waitUntil { store.isQualityCueWalkIdleForTesting && store.qualityCueEvidence.count == count }
        await store.flushQualityCueEvidenceForTesting()
    }

    private func cueStates(_ store: SessionStore) -> [String] {
        store.items.map { item in
            let evidence = store.qualityEvidence(for: item)
            let cues = store.qualityCues(for: item).map { "\($0.kind):\($0.measuredValue)" }.joined(separator: ",")
            return "\(item.displayName) \(store.qualityCueStatus(for: item)) \(evidence?.isApproximate ?? false) "
                + "\(evidence?.sampleCount ?? -1)/\(evidence?.shadowCount ?? -1)/\(evidence?.highlightCount ?? -1) "
                + "\(evidence?.width ?? -1)x\(evidence?.height ?? -1) [\(cues)]"
        }
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "The cue walk did not reach the expected state")
        if !satisfied { throw CueEvidenceTimeout() }
    }
}

private struct CueEvidenceTimeout: Error {}

/// Holds snapshot writes until opened.
private actor CueWriteGate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async {
        while !isOpen { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

/// Records every measurement by kind. Estimates and exact results differ, so
/// a test can tell which one a photo holds.
private actor CueMeasurements {
    static let exactHighlights = 12
    struct Snapshot: Sendable {
        let approximate: [String]
        let exact: [String]
    }
    private var approximate: [String] = []
    private var exact: [String] = []
    /// Measurements started before each rest: the batch boundaries.
    private(set) var restBoundaries: [Int] = []
    private let highlightPercent: Int
    private let exactFails: Bool
    private var heldExact: Set<String> = []
    /// Held exact measurements that ended by cancellation.
    private(set) var retiredExact: [String] = []

    init(highlightPercent: Int = 30, exactFails: Bool = false) {
        self.highlightPercent = highlightPercent
        self.exactFails = exactFails
    }

    var snapshot: Snapshot { Snapshot(approximate: approximate, exact: exact) }

    func approximate(_ item: PhotoItem) -> QualityCueEvidence? {
        approximate.append(item.displayName)
        return QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 100,
            shadowCount: 1, highlightCount: highlightPercent, width: 320, height: 240),
            source: .renderedPreview, isApproximate: true)
    }

    func holdExact(_ name: String) { heldExact.insert(name) }
    func releaseExact(_ name: String) { heldExact.remove(name) }

    func exact(_ item: PhotoItem) async -> QualityCueEvidence {
        exact.append(item.displayName)
        while heldExact.contains(item.displayName) {
            if Task.isCancelled {
                retiredExact.append(item.displayName)
                return QualityCueEvidence(item: item, analysis: nil, source: .renderedPreview)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let analysis = exactFails ? nil : HistogramAnalysis(bins: [], sampleCount: 100, shadowCount: 2,
            highlightCount: Self.exactHighlights, width: 1_024, height: 768)
        return QualityCueEvidence(item: item, analysis: analysis, source: .renderedPreview)
    }

    func rest() {
        let total = approximate.count + exact.count
        if restBoundaries.last != total { restBoundaries.append(total) }
    }
}
