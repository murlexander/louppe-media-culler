import Foundation
import XCTest
@testable import Louppe

/// Real SessionStore classification/projection over injected numeric evidence.
/// There are no source images or native decoder results in these fixtures.
/// Fixture creation, scheduler filling and correctness assertions are untimed.
@MainActor
final class LouppeSpeedClippingFilterTests: XCTestCase {
    func testCompletedClippingEvidenceWarmSwitchesUnionAndFirstUse() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "clipping-filter")
        let highlights = histogram(highlights: 30)
        let shadows = histogram(shadows: 20)
        for count in SpeedBenchmark.sizes {
            let suite = "LouppeSpeedClippingFilter.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            clippingPreferences().save(to: defaults)
            let calls = ClippingFilterCallCounter()
            let store = SessionStore(reviewDefaults: defaults, qualityCueMeasurement: { item in
                calls.record()
                return QualityCueEvidence(item: item,
                    analysis: item.id.hasSuffix("-H.JPG") ? highlights : shadows,
                    source: .renderedPreview)
            }, qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
               qualityCueRest: { _ in await Task.yield() })
            prepare(store, items: fixture(count: count))
            do {
                try await fillAcceptedEvidence(store, count: count)
                store.pauseQualityCueAnalysis(userInitiated: true)
                XCTAssertEqual(calls.value, count)
                XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, count)
                XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, count)
                XCTAssertTrue(store.qualityCueCheckingIDs.isEmpty)
                let highIndices = Array(stride(from: 0, to: count, by: 2))
                let shadowIndices = Array(stride(from: 1, to: count, by: 2))
                let allIndices = Array(0..<count)
                let initialBuilds = store.qualityCueMatchBuildsForTesting
                let initialUpdates = store.qualityCueMatchUpdatesForTesting
                store.filter.selectedQualityCues = [.highlightClipping]
                XCTAssertEqual(store.visibleIndices, highIndices)
                let warmBuilds = store.qualityCueMatchBuildsForTesting
                XCTAssertEqual(warmBuilds, initialBuilds + 1)

                let workloads: [(String, Set<QualityCueKind>, Set<QualityCueKind>, [Int])] = [
                    ("highlights", [.shadowClipping], [.highlightClipping], highIndices),
                    ("shadows", [.highlightClipping], [.shadowClipping], shadowIndices),
                    ("either-clipping", [.highlightClipping], [.highlightClipping, .shadowClipping], allIndices)
                ]
                for (name, previous, requested, expected) in workloads {
                    try report.measure(name: "clipping.warm-switch.\(name)", count: count, prepare: {
                        store.filter.selectedQualityCues = previous
                    }) {
                        store.filter.selectedQualityCues = requested
                    }
                    XCTAssertEqual(store.visibleIndices, expected)
                    XCTAssertEqual(store.visibleGroups.flatMap(\.indices), expected)
                    XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmBuilds,
                                   "Warm clipping switches must reuse the accepted-evidence mask.")
                }
                XCTAssertEqual(store.qualityCueMatchUpdatesForTesting, initialUpdates)

                // Each preparation invalidates classification through a real
                // preference change while the neutral filter is active. Both
                // thresholds stay below the fixed 20%/30% fixture evidence.
                var useFractionalThreshold = false
                var firstUses = 0
                try report.measure(name: "clipping.first-use.highlights.after-threshold-change", count: count, prepare: {
                    store.filter.selectedQualityCues = []
                    useFractionalThreshold.toggle()
                    var preferences = store.qualityCuePreferences
                    preferences.highlightPercentageThreshold = useFractionalThreshold ? 10.01 : 10
                    preferences.shadowPercentageThreshold = useFractionalThreshold ? 10.01 : 10
                    store.updateQualityCuePreferences(preferences)
                    firstUses += 1
                }) {
                    store.filter.selectedQualityCues = [.highlightClipping]
                }
                XCTAssertEqual(store.visibleIndices, highIndices)
                XCTAssertEqual(store.visibleGroups.flatMap(\.indices), highIndices)
                XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmBuilds + firstUses,
                               "Each invalidated first use must rebuild exactly once.")
                XCTAssertEqual(store.qualityCueMatchUpdatesForTesting, initialUpdates)
                XCTAssertEqual(calls.value, count, "Threshold changes must reuse numeric evidence without remeasurement.")
                store.beginTerminationPreparation()
                // All measurement functions have returned before evidence is
                // accepted. Let the scheduler's final rest/defer retire as well.
                for _ in 0..<8 { await Task.yield() }
                XCTAssertEqual(calls.value, count)
            } catch {
                store.beginTerminationPreparation()
                throw error
            }
        }
        try report.finish()
    }

    func testFirstAcceptedClippingPairsUpdateOnlyTheirSlots() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "clipping-filter-arrivals")
        let analysis = histogram(highlights: 30)
        for count in SpeedBenchmark.sizes {
            let suite = "LouppeSpeedClippingArrivals.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            clippingPreferences().save(to: defaults)
            let gate = ClippingFilterMeasurementGate(analysis: analysis)
            let items = fixture(count: count)
            let store = SessionStore(reviewDefaults: defaults,
                qualityCueMeasurement: { await gate.measure($0) },
                qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
                qualityCueRest: { _ in await Task.yield() })
            prepare(store, items: items)
            do {
                let current = store.currentIndex
                let initialBuilds = store.qualityCueMatchBuildsForTesting
                let initialUpdates = store.qualityCueMatchUpdatesForTesting
                store.filter.selectedQualityCues = [.highlightClipping]
                XCTAssertTrue(store.visibleIndices.isEmpty)
                let warmedBuilds = store.qualityCueMatchBuildsForTesting
                XCTAssertEqual(warmedBuilds, initialBuilds + 1)
                store.startQualityCueAnalysis()
                try await waitUntil {
                    let state = await gate.snapshot
                    return state.admitted == 2 && state.active == 2 && state.waiting.count == 2
                }

                var latencies: [Double] = []
                // Defaults to the first eight accepted pairs: one warmup and
                // seven measured samples. Custom repetitions retain that ratio.
                for trial in 0...SpeedBenchmark.repetitions {
                    let accepted = (trial + 1) * 2
                    let waiting = await gate.snapshot.waiting
                    XCTAssertEqual(Set(waiting), Set(items[(accepted - 2)..<accepted].map(\.id)))
                    let start = ContinuousClock.now
                    await gate.releasePair()
                    // The following pair is held in the gate. Its admission
                    // proves the prior pair completed its projection turn.
                    // This timing includes gate dispatch, scheduler application,
                    // next admission, and up to 1 ms polling/scheduling latency.
                    try await waitUntil {
                        let state = await gate.snapshot
                        return state.admitted == accepted + 2 && state.active == 2 && state.waiting.count == 2
                            && store.visibleIndices.count == accepted
                    }
                    let elapsed = SpeedBenchmark.milliseconds(start)
                    if trial > 0 { latencies.append(elapsed) }

                    let expected = Array(0..<accepted)
                    XCTAssertEqual(store.visibleIndices, expected)
                    XCTAssertEqual(store.visibleGroups.flatMap(\.indices), expected)
                    XCTAssertEqual(store.qualityCueEvidence.count, accepted)
                    XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, accepted)
                    XCTAssertEqual(store.currentIndex, current, "Background evidence must preserve the current index.")
                    XCTAssertEqual(store.currentItem?.id, items[current].id)
                    XCTAssertTrue(store.selectedIndices.isEmpty)
                    XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds,
                                   "Accepted pairs must not trigger an N-item classification rebuild.")
                    XCTAssertEqual(store.qualityCueMatchUpdatesForTesting, initialUpdates + accepted,
                                   "Each accepted pair may update exactly two mask slots.")
                }
                try report.recordSamples(name: "clipping.accepted-pair.release-to-projection-next-admission.poll-1ms",
                    count: count, samplesMS: latencies)
                let acceptedBeforePause = store.qualityCueEvidence.count
                try await drain(store, gate: gate)
                XCTAssertEqual(store.qualityCueEvidence.count, acceptedBeforePause,
                               "Released cancelled gate results must not publish across the generation boundary.")
                XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds)
                XCTAssertEqual(store.qualityCueMatchUpdatesForTesting, initialUpdates + acceptedBeforePause)
                XCTAssertEqual(store.currentIndex, current)
            } catch {
                try? await drain(store, gate: gate)
                throw error
            }
        }
        try report.finish()
    }

    private func clippingPreferences() -> CameraQualityWarningPreferences {
        CameraQualityWarningPreferences(isHighISOEnabled: false, isSlowShutterEnabled: false,
            isClippingEnabled: true, highlightPercentageThreshold: 10, shadowPercentageThreshold: 10)
    }

    private func histogram(shadows: Int = 0, highlights: Int = 0) -> HistogramAnalysis {
        HistogramAnalysis(bins: [], sampleCount: 100, shadowCount: shadows,
                          highlightCount: highlights, width: 10, height: 10)
    }

    private func fixture(count: Int) -> [PhotoItem] {
        (0..<count).map { index in
            let id = "CLIPPING_\(index)-\(index.isMultiple(of: 2) ? "H" : "S").JPG"
            return PhotoItem(primaryFile: PhotoFile(id: id,
                url: URL(fileURLWithPath: "/private/tmp/louppe-clipping-filter-synthetic/\(id)"),
                captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                cameraModel: nil, lensModel: nil, shutterSpeed: 0.001, iso: 100, fileSize: 1))
        }
    }

    private func prepare(_ store: SessionStore, items: [PhotoItem]) {
        store.showMetadataPanel = false
        store.isGroupingEnabled = true
        store.items = items
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
    }

    private func fillAcceptedEvidence(_ store: SessionStore, count: Int) async throws {
        store.startQualityCueAnalysis()
        // Untimed fill uses 5 ms polling; measured pair latencies below use 1 ms.
        try await waitUntil(timeout: .seconds(120), poll: .milliseconds(5)) {
            store.qualityCueEvidence.count == count && store.qualityCueCheckingIDs.isEmpty
        }
    }

    private func drain(_ store: SessionStore, gate: ClippingFilterMeasurementGate) async throws {
        store.pauseQualityCueAnalysis(userInitiated: true)
        await gate.close()
        try await waitUntil {
            let state = await gate.snapshot
            return state.waiting.isEmpty && state.active == 0 && state.completed == state.admitted
        }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(store.qualityCueCheckingIDs.isEmpty)
    }

    private func waitUntil(timeout: Duration = .seconds(10), poll: Duration = .milliseconds(1),
                           _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: poll)
        }
        guard await predicate() else {
            XCTFail("Clipping benchmark did not reach the requested gate/projection state.")
            throw ClippingFilterBenchmarkError.timeout
        }
    }
}

private enum ClippingFilterBenchmarkError: Error { case timeout }

private final class ClippingFilterCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

/// Only the two admitted measurement continuations are retained; this is not a
/// per-photo task queue. Closing the gate releases cancellation cleanup as well.
private actor ClippingFilterMeasurementGate {
    struct Snapshot: Sendable {
        let admitted: Int
        let completed: Int
        let active: Int
        let waiting: [String]
    }
    private let analysis: HistogramAnalysis
    private var admitted = 0
    private var completed = 0
    private var active = 0
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var closed = false

    init(analysis: HistogramAnalysis) { self.analysis = analysis }

    var snapshot: Snapshot {
        Snapshot(admitted: admitted, completed: completed, active: active, waiting: Array(waiters.keys))
    }

    func measure(_ item: PhotoItem) async -> QualityCueEvidence {
        admitted += 1
        active += 1
        await withCheckedContinuation { continuation in
            if closed { continuation.resume() }
            else { waiters[item.id] = continuation }
        }
        let evidence = QualityCueEvidence(item: item, analysis: analysis, source: .renderedPreview)
        active -= 1
        completed += 1
        return evidence
    }

    func releasePair() {
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        for waiter in pending { waiter.resume() }
    }

    func close() {
        closed = true
        releasePair()
    }
}
