import Foundation
import XCTest
@testable import Louppe

/// Tests admission and interruption with controlled rest boundaries. These
/// assertions concern scheduler work; they do not claim a CPU/GPU usage cap.
@MainActor
final class QualityCueSchedulingTests: XCTestCase {
    func testAnotherBatchCannotStartUntilAdaptiveRestYields() async throws {
        let measurements = CueSchedulingMeasurements()
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 8, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)

        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }
        let first = await measurements.started
        let firstRest = await rest.snapshot
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(store.qualityCueEvidence.count, 2)
        XCTAssertEqual(firstRest.requests, 1)
        XCTAssertGreaterThanOrEqual(firstRest.durations[0], .milliseconds(100))
        await allowScheduledTasksToRun()
        let whileResting = await measurements.started
        XCTAssertEqual(whileResting, first, "A suspended rest must block follow-on admission")

        await rest.releaseNext()
        try await waitUntil { await rest.snapshot.requests == 2 }
        let second = await measurements.started
        let secondRest = await rest.snapshot
        XCTAssertEqual(second.count, 4)
        XCTAssertEqual(Set(second).count, 4)
        XCTAssertEqual(secondRest.waiting, 1)
        XCTAssertEqual(secondRest.manualReleases, 1)
        XCTAssertEqual(secondRest.cancellations, 0)
    }

    func testCurrentPhotoInterruptsRestAndRunsInNextBatch() async throws {
        let measurements = CueSchedulingMeasurements()
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 10, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }
        let first = await measurements.started
        XCTAssertEqual(first.count, 2)

        // Model assignment exercises the same interest wakeup without starting
        // Gallery/navigation image work in a windowless scheduler test.
        store.currentIndex = 8
        try await waitUntil { await rest.snapshot.requests == 2 }
        let next = await measurements.started
        let interrupted = await rest.snapshot
        XCTAssertEqual(next.count, 4)
        XCTAssertTrue(next.dropFirst(2).contains(store.items[8].id))
        XCTAssertEqual(interrupted.cancellations, 1)
        XCTAssertEqual(interrupted.waiting, 1, "The cancelled rest continuation must be retired")
        XCTAssertEqual(interrupted.manualReleases, 0)
    }

    func testNewTileInterestInterruptsRestButCoveredTileDoesNot() async throws {
        let measurements = CueSchedulingMeasurements()
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 10, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }

        store.prioritizeQualityCues(for: store.items[8])
        try await waitUntil { await rest.snapshot.requests == 2 }
        let prioritized = await measurements.started
        let nextRest = await rest.snapshot
        XCTAssertEqual(prioritized.count, 4)
        XCTAssertTrue(prioritized.dropFirst(2).contains(store.items[8].id))
        XCTAssertEqual(nextRest.cancellations, 1)
        XCTAssertEqual(nextRest.waiting, 1)

        XCTAssertNotNil(store.qualityEvidence(for: store.items[0]))
        store.prioritizeQualityCues(for: store.items[0])
        await allowScheduledTasksToRun()
        let covered = await measurements.started
        let resting = await rest.snapshot
        XCTAssertEqual(covered, prioritized)
        XCTAssertEqual(resting.requests, 2)
        XCTAssertEqual(resting.cancellations, 1,
                       "Repeated appearance of a covered tile should not defeat background rest")
    }

    func testCoveredCurrentPhotoDoesNotInterruptRest() async throws {
        let measurements = CueSchedulingMeasurements()
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 10, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }
        let covered = await measurements.started
        XCTAssertEqual(covered.count, 2)
        XCTAssertNotNil(store.qualityEvidence(for: store.items[1]))

        store.currentIndex = 1
        await allowScheduledTasksToRun()
        let afterNavigation = await measurements.started
        let stillResting = await rest.snapshot
        XCTAssertEqual(afterNavigation, covered)
        XCTAssertEqual(stillResting.requests, 1)
        XCTAssertEqual(stillResting.waiting, 1)
        XCTAssertEqual(stillResting.cancellations, 0,
                       "Navigation to measured evidence should not defeat background rest")
    }

    func testCoveredSelectionChangesDoNotInterruptRest() async throws {
        let measurements = CueSchedulingMeasurements()
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 10, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }
        let covered = await measurements.started
        XCTAssertEqual(covered.count, 2)
        XCTAssertNotNil(store.qualityEvidence(for: store.items[0]))
        XCTAssertNotNil(store.qualityEvidence(for: store.items[1]))

        for selection in [Set([0, 1]), Set([1]), Set<Int>()] {
            store.setSelection(selection)
            await allowScheduledTasksToRun()
            let afterSelection = await measurements.started
            let stillResting = await rest.snapshot
            XCTAssertEqual(afterSelection, covered)
            XCTAssertEqual(stillResting.requests, 1)
            XCTAssertEqual(stillResting.waiting, 1)
            XCTAssertEqual(stillResting.cancellations, 0,
                           "A selection containing only covered photos should retain background rest")
        }
    }

    func testUserPausePersistsUntilExplicitResume() async throws {
        let measurements = CueSchedulingMeasurements()
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 8, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }
        let beforePause = await measurements.started

        store.pauseQualityCueAnalysis(userInitiated: true)
        var preferences = store.qualityCuePreferences
        preferences.highlightPercentageThreshold += 1
        store.updateQualityCuePreferences(preferences)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        store.prioritizeQualityCues(for: store.items[7])
        store.currentIndex = 6
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 0 }
        await allowScheduledTasksToRun()
        let paused = await measurements.started
        XCTAssertEqual(paused, beforePause)
        XCTAssertTrue(store.isQualityCueAnalysisPaused)
        XCTAssertEqual(store.qualityCueEvidence.count, 2, "Copy suspension preserves reusable evidence")

        store.resumeQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.requests == 2 }
        let resumed = await measurements.started
        XCTAssertFalse(store.isQualityCueAnalysisPaused)
        XCTAssertEqual(resumed.count, 4)
        XCTAssertEqual(Set(resumed).count, 4, "Resume must reuse evidence rather than remeasure covered photos")
        XCTAssertEqual(Set(resumed.dropFirst(2)), Set([store.items[6].id, store.items[7].id]))
    }

    func testPauseFlushesAcceptedCueMatchesWithoutRetargetingSelection() async throws {
        let measurements = CueSchedulingMeasurements(highlights: 30)
        let rest = CueSchedulingRestGate()
        let store = makeStore(count: 8, measurements: measurements, rest: { await rest.sleep($0) })
        registerCleanup(store: store, rest: rest)
        // A metadata match keeps an explicit selection alive before histogram
        // evidence exists. The active highlight rule will add the second item.
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        XCTAssertEqual(store.visibleIndices, [0])
        store.setSelection([0])
        let current = store.currentIndex
        let selected = store.selectedIndices
        store.startQualityCueAnalysis()
        try await waitUntil { await rest.snapshot.waiting == 1 }
        XCTAssertEqual(store.qualityCueEvidence.count, 2)
        XCTAssertNotNil(store.qualityEvidence(for: store.items[1]))
        XCTAssertEqual(store.visibleIndices, [0, 1],
                       "Accepted matches must become visible before adaptive rest can suspend publication")
        XCTAssertEqual(store.currentIndex, current)
        XCTAssertEqual(store.selectedIndices, selected)

        // No elapsed-time threshold is asserted: the rest gate gives a stable
        // boundary after acceptance and before any following batch. Pause must
        // preserve the already-flushed projection and its explicit selection.
        store.pauseQualityCueAnalysis(userInitiated: true)
        XCTAssertEqual(store.visibleIndices, [0, 1])
        XCTAssertEqual(store.currentIndex, current)
        XCTAssertEqual(store.selectedIndices, selected)
        try await waitUntil { await rest.snapshot.waiting == 0 }
        let starts = await measurements.started
        XCTAssertEqual(starts.count, 2)
    }

    func testActualSelectedPriorityWalkIsLinearAtTwoThousandPhotos() async throws {
        let count = 2_000
        let measurements = CueSchedulingMeasurements()
        let store = makeStore(count: count, measurements: measurements, rest: { _ in })
        registerCleanup(store: store)
        store.selectAllVisible()
        let before = store.qualityCueSelectionProbesForTesting
        store.startQualityCueAnalysis()
        try await waitUntil(timeout: .seconds(10)) { store.qualityCueEvidence.count == count }
        await allowScheduledTasksToRun()
        let starts = await measurements.started
        let probes = store.qualityCueSelectionProbesForTesting - before
        XCTAssertEqual(starts.count, count)
        XCTAssertEqual(Set(starts).count, count)
        XCTAssertGreaterThanOrEqual(probes, count - 1)
        XCTAssertLessThanOrEqual(probes, count,
            "The actual scheduler must consume a retained selection frontier, not rescan completed selections per batch")
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, count)
        XCTAssertTrue(store.qualityCueCheckingIDs.isEmpty)

        store.startQualityCueAnalysis()
        await allowScheduledTasksToRun()
        let restarted = await measurements.started
        XCTAssertEqual(restarted, starts)
        XCTAssertLessThanOrEqual(store.qualityCueSelectionProbesForTesting - before, count,
            "Finishing or revisiting complete coverage must not restart the selected-priority walk")
    }

    private func makeStore(
        count: Int,
        measurements: CueSchedulingMeasurements,
        rest: @escaping @Sendable (Duration) async -> Void
    ) -> SessionStore {
        let name = "QualityCueSchedulingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        CameraQualityWarningPreferences().save(to: defaults)
        let store = SessionStore(reviewDefaults: defaults,
            qualityCueMeasurement: { await measurements.measure($0) },
            qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
            qualityCueRest: rest)
        store.items = (0..<count).map { index in
            let id = String(format: "SCHEDULING_%04d.JPG", index)
            return PhotoItem(primaryFile: PhotoFile(
                id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-cue-scheduling-synthetic/\(id)"),
                captureDate: Date(timeIntervalSince1970: Double(index)),
                cameraModel: nil, lensModel: nil,
                iso: index == 0 ? 12_800 : 100, fileSize: 1))
        }
        store.showMetadataPanel = false
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        addTeardownBlock {
            await MainActor.run {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }
        return store
    }

    private func registerCleanup(store: SessionStore, rest: CueSchedulingRestGate? = nil) {
        addTeardownBlock {
            await MainActor.run { store.beginTerminationPreparation() }
            await rest?.close()
        }
    }

    private func allowScheduledTasksToRun() async {
        for _ in 0..<12 { await Task.yield() }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied, "Scheduler did not reach the controlled milestone")
        if !satisfied { throw CueSchedulingTimeout.expired }
    }
}

private enum CueSchedulingTimeout: Error { case expired }

private actor CueSchedulingMeasurements {
    private(set) var started: [String] = []
    private let highlights: Int
    init(highlights: Int = 0) { self.highlights = highlights }
    func measure(_ item: PhotoItem) -> QualityCueEvidence {
        started.append(item.id)
        return QualityCueEvidence(item: item,
            analysis: HistogramAnalysis(bins: [], sampleCount: 100,
                shadowCount: 0, highlightCount: highlights, width: 10, height: 10),
            source: .renderedPreview)
    }
}

/// A suspended injected sleeper must honor task cancellation, including the
/// race where cancellation arrives just before continuation registration.
private actor CueSchedulingRestGate {
    struct Snapshot: Sendable {
        let requests: Int
        let waiting: Int
        let cancellations: Int
        let manualReleases: Int
        let durations: [Duration]
    }
    private var order: [UUID] = []
    private var durations: [Duration] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeRegistration = Set<UUID>()
    private var finished = Set<UUID>()
    private var cancellations = 0
    private var manualReleases = 0
    private var closed = false

    var snapshot: Snapshot {
        .init(requests: order.count, waiting: waiters.count, cancellations: cancellations,
              manualReleases: manualReleases, durations: durations)
    }

    func sleep(_ duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                order.append(id)
                durations.append(duration)
                if Task.isCancelled || cancelledBeforeRegistration.remove(id) != nil {
                    cancellations += 1
                    finished.insert(id)
                    continuation.resume()
                } else if closed {
                    finished.insert(id)
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard !finished.contains(id) else { return }
        if let waiter = waiters.removeValue(forKey: id) {
            cancellations += 1
            finished.insert(id)
            waiter.resume()
        } else {
            cancelledBeforeRegistration.insert(id)
        }
    }

    func releaseNext() {
        guard let id = order.first(where: { waiters[$0] != nil }),
              let waiter = waiters.removeValue(forKey: id) else { return }
        manualReleases += 1
        finished.insert(id)
        waiter.resume()
    }

    func close() {
        closed = true
        let remaining = waiters
        waiters.removeAll()
        for (id, waiter) in remaining {
            finished.insert(id)
            waiter.resume()
        }
    }
}
