import Combine
import Darwin
import Foundation
import XCTest
@testable import Louppe

@MainActor
final class LouppeSpeedQualityResourceTests: XCTestCase {
    func testEvidenceAccumulationCPUAndPublicationCost() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "quality-resource")
        for count in SpeedBenchmark.sizes {
            let items = (0..<count).map { index in
                let id = "RESOURCE_\(index).JPG"
                return PhotoItem(primaryFile: PhotoFile(
                    id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-quality-resource-synthetic/\(id)"),
                    captureDate: Date(timeIntervalSince1970: Double(index)),
                    cameraModel: nil, lensModel: nil, shutterSpeed: 0.001,
                    iso: 100, fileSize: 1))
            }
            var wallSamples: [Double] = []
            var cpuSamples: [Double] = []
            for trial in 0...SpeedBenchmark.repetitions {
                let name = "LouppeSpeedQualityResource.\(UUID())"
                let defaults = UserDefaults(suiteName: name)!
                defer { defaults.removePersistentDomain(forName: name) }
                let store = SessionStore(reviewDefaults: defaults, qualityCueMeasurement: { item in
                    QualityCueEvidence(item: item, analysis: HistogramAnalysis(
                        bins: [], sampleCount: 100, shadowCount: 20, highlightCount: 30,
                        width: 10, height: 10), source: .renderedPreview)
                }, qualityCueResources: { .init(lowPower: false, thermal: .nominal) },
                   qualityCueRest: { _ in })
                store.items = items
                store.rebuildDerivedDataForTesting()
                store.phase = .ready
                // Large selection exercises the retained priority frontier.
                store.setSelection(Set(items.indices))
                var publications = 0
                let completion = QualityBenchmarkCompletion()
                let lastBatchSize = count.isMultiple(of: 2) ? 2 : 1
                let subscription = store.objectWillChange.sink { _ in
                    publications += 1
                    // willChange precedes mutation. Schedule one final observer
                    // turn rather than busy-polling and charging harness CPU to
                    // the scheduler under test.
                    if store.qualityCueEvidence.count == count - lastBatchSize,
                       !store.qualityCueCheckingIDs.isEmpty {
                        Task { @MainActor in
                            if store.qualityCueEvidence.count == count { completion.finish(true) }
                        }
                    }
                }
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(90)) }
                    catch { return }
                    completion.finish(false)
                }
                defer {
                    timeout.cancel()
                    subscription.cancel()
                    store.beginTerminationPreparation()
                }
                let cpuStart = try processCPUMilliseconds()
                let start = ContinuousClock.now
                store.startQualityCueAnalysis()
                let completed = await completion.wait()
                let wall = SpeedBenchmark.milliseconds(start)
                let cpu = try processCPUMilliseconds() - cpuStart
                guard completed else {
                    XCTFail("Quality scheduler did not complete the bounded fixture")
                    throw NSError(domain: "LouppeSpeedQualityResource", code: 1)
                }
                XCTAssertEqual(store.qualityCueEvidence.count, count)
                XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, count)
                XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, count)
                XCTAssertTrue(store.qualityCueCheckingIDs.isEmpty)
                XCTAssertLessThanOrEqual(store.qualityCueSelectionProbesForTesting, count)
                XCTAssertLessThanOrEqual(publications, count + 2,
                    "At most one admission and one coherent-result publication per pair")
                for item in items {
                    XCTAssertEqual(store.qualityEvidence(for: item)?.revision, item.contentRevision)
                }
                subscription.cancel()
                store.beginTerminationPreparation()
                if trial > 0 { wallSamples.append(wall); cpuSamples.append(cpu) }
            }
            try report.recordSamples(name: "quality.evidence.complete.wall", count: count, samplesMS: wallSamples)
            try report.recordSamples(name: "quality.evidence.complete.process-cpu", count: count, samplesMS: cpuSamples)
        }
        try report.finish()
    }

    private func processCPUMilliseconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }
}

@MainActor
private final class QualityBenchmarkCompletion {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            if let result { continuation.resume(returning: result) }
            else { waiter = continuation }
        }
    }
}
