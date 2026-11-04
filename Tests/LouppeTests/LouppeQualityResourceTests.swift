import Combine
import Foundation
import XCTest
@testable import Louppe

/// Resource contracts with deterministic gated workers, independent of decoder timing.
@MainActor
final class LouppeQualityResourceTests: XCTestCase {
    func testAtMostTwoMeasurementsAndFiniteWorkDrainsToIdle() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 12)
        store.startQualityCueAnalysis()
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.snapshot.started.count == 2 }
        let initial = await probe.snapshot
        XCTAssertEqual(initial.active, 2)
        XCTAssertEqual(initial.peak, 2)
        await probe.releaseAll(allowFuture: true)
        try await waitUntil {
            let snapshot = await probe.snapshot
            return store.qualityCueEvidence.count == 12 && snapshot.active == 0
        }
        // Let the scheduler perform its final empty batch check, then observe
        // settled inactivity without pausing it or closing the session.
        try await Task.sleep(for: .milliseconds(60))
        let settled = await probe.snapshot
        XCTAssertEqual(settled.started.count, 12)
        XCTAssertEqual(Set(settled.started).count, 12)
        XCTAssertLessThanOrEqual(settled.peak, 2)
        XCTAssertTrue(store.qualityCueCheckingIDs.isEmpty)
        var publications = 0
        let subscription = store.objectWillChange.sink { _ in publications += 1 }
        try await Task.sleep(for: .milliseconds(80))
        let idle = await probe.snapshot
        XCTAssertEqual(idle.started, settled.started)
        XCTAssertEqual(idle.active, 0)
        XCTAssertEqual(publications, 0, "Completed coverage must settle without a polling/publication loop")
        subscription.cancel()
    }

    func testThresholdEditsReuseCompletedEvidence() async throws {
        let probe = QualityResourceProbe()
        await probe.releaseAll(allowFuture: true)
        let store = makeStore(probe: probe, count: 6)
        store.startQualityCueAnalysis()
        try await waitUntil { store.qualityCueEvidence.count == 6 }
        try await Task.sleep(for: .milliseconds(40))
        let baseline = await probe.snapshot
        for step in 0..<20 {
            var preferences = store.qualityCuePreferences
            preferences.highlightPercentageThreshold = Double(10 + step)
            preferences.shadowPercentageThreshold = Double(30 - step)
            preferences.highISOThreshold = Double(6_400 + step)
            store.updateQualityCuePreferences(preferences)
        }
        try await Task.sleep(for: .milliseconds(80))
        let changed = await probe.snapshot
        XCTAssertEqual(changed.started, baseline.started)
        XCTAssertEqual(changed.active, 0)
        XCTAssertEqual(store.qualityCueEvidence.count, 6)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 6)
    }

    func testMetadataOnlyAndDisabledRulesPerformZeroMeasurements() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 10, histogram: false)
        store.startQualityCueAnalysis()
        var preferences = store.qualityCuePreferences
        preferences.highISOThreshold = 12_800
        store.updateQualityCuePreferences(preferences)
        store.startQualityCueAnalysis()
        try await Task.sleep(for: .milliseconds(40))
        let metadataOnly = await probe.snapshot
        XCTAssertTrue(metadataOnly.started.isEmpty)
        preferences.isEnabled = false
        store.updateQualityCuePreferences(preferences)
        store.startQualityCueAnalysis()
        try await Task.sleep(for: .milliseconds(40))
        let disabled = await probe.snapshot
        XCTAssertTrue(disabled.started.isEmpty)
        XCTAssertEqual(disabled.active, 0)
    }

    func testCurrentSelectedThenVisibleInterestPrecedeFolderWalk() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 10)
        // Direct model assignment avoids starting navigation media work.
        store.currentIndex = 4
        store.setSelection([7])
        store.prioritizeQualityCues(for: store.items[9])
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.snapshot.started.count == 2 }
        let first = await probe.snapshot
        XCTAssertEqual(Set(first.started), Set([store.items[4].id, store.items[7].id]))
        await probe.releaseAll(allowFuture: false)
        try await waitUntil { await probe.snapshot.started.count == 4 }
        let second = await probe.snapshot
        XCTAssertTrue(second.started.dropFirst(2).contains(store.items[9].id))
        XCTAssertLessThanOrEqual(second.peak, 2)
        await probe.releaseAll(allowFuture: true)
        try await waitUntil { store.qualityCueEvidence.count == 10 }
    }

    /// A
    /// decoder may need time to exit after cancellation; new scheduler work
    /// should wait for that exit rather than admitting another full batch.
    func testPauseResumeKeepsGlobalMeasurementAdmissionAtTwo() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 6)
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.snapshot.started.count == 2 }
        store.pauseQualityCueAnalysis()
        store.startQualityCueAnalysis()
        try await Task.sleep(for: .milliseconds(60))
        let restarting = await probe.snapshot
        XCTAssertLessThanOrEqual(restarting.peak, 2,
            "Cancellation retires publication immediately; active measurement admission must wait for worker exit")
        await probe.releaseAll(allowFuture: true)
        try await waitUntil { store.qualityCueEvidence.count == 6 }
        let finished = await probe.snapshot
        XCTAssertLessThanOrEqual(finished.peak, 2)
        XCTAssertEqual(finished.active, 0)
    }

    /// Product/resource intent: explicit Pause remains a user choice while
    /// thresholds change.
    func testExplicitPauseSurvivesThresholdChanges() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 6)
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.snapshot.started.count == 2 }
        store.pauseQualityCueAnalysis(userInitiated: true)
        var preferences = store.qualityCuePreferences
        preferences.highlightPercentageThreshold += 1
        store.updateQualityCuePreferences(preferences)
        XCTAssertTrue(store.isQualityCueAnalysisPaused)
        await probe.releaseAll(allowFuture: true)
        try await Task.sleep(for: .milliseconds(100))
        let paused = await probe.snapshot
        XCTAssertEqual(paused.started.count, 2, "Editing a cutoff must not undo explicit Pause")
        XCTAssertEqual(paused.active, 0)
        XCTAssertTrue(store.qualityCueEvidence.isEmpty, "Retired generation cannot publish")
    }

    /// No Copy worker is started: this exercises only the model's existing
    /// operation lifecycle gate and confirms a user's Pause remains deliberate.
    func testExplicitPauseSurvivesFileOperationLifecycle() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 6)
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.snapshot.started.count == 2 }
        store.pauseQualityCueAnalysis(userInitiated: true)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        XCTAssertTrue(store.isQualityCueAnalysisPaused)
        await probe.releaseAll(allowFuture: true)
        try await Task.sleep(for: .milliseconds(100))
        let paused = await probe.snapshot
        XCTAssertEqual(paused.started.count, 2)
        XCTAssertEqual(paused.active, 0)
        XCTAssertTrue(store.qualityCueEvidence.isEmpty)
    }

    func testSameIDReplacementRejectsRetiredEvidenceBeforeRestart() async throws {
        let probe = QualityResourceProbe()
        let store = makeStore(probe: probe, count: 4)
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.snapshot.started.count == 2 }
        let previous = store.items
        store.items = previous.map { item in
            PhotoItem(primaryFile: PhotoFile(
                id: item.id, url: item.primaryURL, captureDate: item.captureDate,
                cameraModel: nil, lensModel: nil, shutterSpeed: 0.001,
                iso: 100, fileSize: item.fileSize + 1
            ))
        }
        store.rebuildDerivedDataForTesting()
        await probe.releaseAll(allowFuture: true)
        try await waitUntil { await probe.snapshot.active == 0 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(store.qualityCueEvidence.isEmpty)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 0)
        store.startQualityCueAnalysis()
        try await waitUntil { store.qualityCueEvidence.count == 4 }
        for index in store.items.indices {
            XCTAssertNotEqual(store.items[index].contentRevision, previous[index].contentRevision)
            XCTAssertEqual(store.qualityEvidence(for: store.items[index])?.revision,
                           store.items[index].contentRevision)
            XCTAssertNil(store.qualityEvidence(for: previous[index]))
        }
    }

    /// Counts the selected-loop probes independently of decode time and the
    /// scheduler's delay. The modeled current photo is already covered; all remaining
    /// selected candidates are visited in one stable Set iteration order.
    /// Execute only bounded small fixtures, then extrapolate the exact formula.
    func testLegacyRepeatedSelectionPriorityWalkHasQuadraticProbeCount() {
        for count in [100, 1_000, 2_000] {
            let selectedOrder = Array(Set(0..<count))
            var measured = Set<Int>()
            var repeatedWalkProbes = 0
            while measured.count < count {
                var batch: [Int] = []
                for index in selectedOrder {
                    repeatedWalkProbes += 1
                    if measured.contains(index) { continue }
                    batch.append(index)
                    if batch.count == 2 { break }
                }
                measured.formUnion(batch)
            }
            let batches = count / 2
            XCTAssertEqual(repeatedWalkProbes, batches * (batches + 1))
            XCTAssertEqual(measured, Set(selectedOrder))

            // A retained frontier visits each pending priority only once.
            var frontier = 0
            var frontierProbes = 0
            var frontierMeasured = Set<Int>()
            while frontier < selectedOrder.count {
                var batch: [Int] = []
                while batch.count < 2, frontier < selectedOrder.count {
                    frontierProbes += 1
                    batch.append(selectedOrder[frontier])
                    frontier += 1
                }
                frontierMeasured.formUnion(batch)
            }
            XCTAssertEqual(frontierMeasured, measured)
            XCTAssertEqual(frontierProbes, count)
        }
        let hundredThousandBatches: Int64 = 100_000 / 2
        XCTAssertEqual(hundredThousandBatches * (hundredThousandBatches + 1), 2_500_050_000)
    }

    func testDisableCloseAndQuitRetireLateResults() async throws {
        for boundary in ["disable", "close", "quit"] {
            let probe = QualityResourceProbe()
            let store = makeStore(probe: probe, count: 6)
            store.startQualityCueAnalysis()
            try await waitUntil { await probe.snapshot.started.count == 2 }
            switch boundary {
            case "disable":
                var preferences = store.qualityCuePreferences
                preferences.isEnabled = false
                store.updateQualityCuePreferences(preferences)
            case "close":
                store.closeSession()
                try await waitUntil { if case .welcome = store.phase { return true }; return false }
            default:
                store.beginTerminationPreparation()
                // Existing isFileOperationRunning includes the Quit barrier.
                var preferences = store.qualityCuePreferences
                preferences.highlightPercentageThreshold += 1
                store.updateQualityCuePreferences(preferences)
            }
            store.startQualityCueAnalysis()
            await probe.releaseAll(allowFuture: true)
            try await Task.sleep(for: .milliseconds(80))
            let retired = await probe.snapshot
            XCTAssertEqual(retired.started.count, 2, boundary)
            XCTAssertEqual(retired.active, 0, boundary)
            XCTAssertTrue(store.qualityCueEvidence.isEmpty, boundary)
            XCTAssertTrue(store.qualityCueCheckingIDs.isEmpty, boundary)
        }
    }

    private func makeStore(probe: QualityResourceProbe, count: Int, histogram: Bool = true) -> SessionStore {
        let name = "LouppeQualityResourceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        CameraQualityWarningPreferences(isClippingEnabled: histogram).save(to: defaults)
        let store = SessionStore(reviewDefaults: defaults, qualityCueMeasurement: { item in
            await probe.measure(item)
        })
        store.items = (0..<count).map { index in
            let id = String(format: "RESOURCE_%04d.JPG", index)
            return PhotoItem(primaryFile: PhotoFile(
                id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-quality-resource-synthetic/\(id)"),
                captureDate: Date(timeIntervalSince1970: Double(index)),
                cameraModel: nil, lensModel: nil, shutterSpeed: 0.001,
                iso: index.isMultiple(of: 2) ? 12_800 : 100, fileSize: 1
            ))
        }
        store.showMetadataPanel = false
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        addTeardownBlock {
            await MainActor.run { store.beginTerminationPreparation() }
            await probe.releaseAll(allowFuture: true)
            await MainActor.run { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        }
        return store
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let ready = await predicate()
        XCTAssertTrue(ready, "Resource contract did not reach its next bounded milestone")
        if !ready { throw QualityResourceTimeout.expired }
    }
}

private enum QualityResourceTimeout: Error { case expired }

/// The gate intentionally does not pretend a cancelled native operation has
/// already exited. Tests control that boundary explicitly, without real I/O.
private actor QualityResourceProbe {
    struct Snapshot: Sendable {
        let started: [String]
        let active: Int
        let peak: Int
    }
    private var started: [String] = []
    private var active = 0
    private var peak = 0
    private var allowFuture = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var snapshot: Snapshot { .init(started: started, active: active, peak: peak) }

    func measure(_ item: PhotoItem) async -> QualityCueEvidence {
        started.append(item.id)
        active += 1
        peak = max(peak, active)
        if !allowFuture { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
        return QualityCueEvidence(item: item,
            analysis: HistogramAnalysis(bins: [], sampleCount: 100,
                shadowCount: 20, highlightCount: 30, width: 10, height: 10),
            source: .renderedPreview)
    }

    func releaseAll(allowFuture: Bool) {
        self.allowFuture = allowFuture
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
