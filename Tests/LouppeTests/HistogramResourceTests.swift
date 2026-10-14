import Foundation
import XCTest
@testable import Louppe

@MainActor
final class HistogramResourceTests: XCTestCase {
    func testInfoPromotesSharedBackgroundWorkWithoutCancellingItsSurvivor() async throws {
        let queue = OperationQueue()
        queue.isSuspended = true
        defer { queue.isSuspended = false }
        let probe = HistogramWorkerProbe()
        let pipeline = HistogramPipeline(decoder: { url in
            let call = probe.begin(url.lastPathComponent)
            defer { probe.end() }
            return histogramResourceAnalysis(call)
        }, operationQueue: queue)
        let item = photo("shared")
        let background = Task { await pipeline.analysis(for: item, purpose: .backgroundQuality) }
        try await waitUntil { queue.operationCount == 1 }
        let operation = try XCTUnwrap(queue.operations.first)
        XCTAssertEqual(queue.qualityOfService, .utility)
        XCTAssertEqual(queue.maxConcurrentOperationCount, 2)
        XCTAssertEqual(operation.qualityOfService, .utility)
        XCTAssertEqual(operation.queuePriority, .low)

        let info = Task { await pipeline.analysis(for: item) }
        try await waitUntil {
            operation.qualityOfService == .userInitiated && operation.queuePriority == .high
        }
        XCTAssertEqual(queue.operationCount, 1, "Info must join the existing revision's work")
        background.cancel()
        let cancelled = await background.value
        XCTAssertNil(cancelled)
        XCTAssertFalse(operation.isCancelled, "the Info waiter still needs this operation")
        queue.isSuspended = false
        let result = await info.value
        XCTAssertEqual(result?.shadowCount, 1)
        XCTAssertEqual(probe.calls("shared.JPG"), 1)
        let cached = await pipeline.analysis(for: item, purpose: .backgroundQuality)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(probe.calls("shared.JPG"), 1, "purpose must not split the numeric cache")
    }

    func testPromotedInfoStartsBeforeQueuedBackgroundWithoutExceedingTwoWorkers() async throws {
        let queue = OperationQueue()
        let probe = HistogramWorkerProbe()
        let releaseA = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let releaseTarget = DispatchSemaphore(value: 0)
        defer { releaseA.signal(); releaseB.signal(); releaseTarget.signal() }
        let pipeline = HistogramPipeline(decoder: { url in
            let name = url.lastPathComponent
            let call = probe.begin(name)
            defer { probe.end() }
            if name == "blocker-a.JPG" { _ = releaseA.wait(timeout: .now() + 5) }
            if name == "blocker-b.JPG" { _ = releaseB.wait(timeout: .now() + 5) }
            if name == "target.JPG" { _ = releaseTarget.wait(timeout: .now() + 5) }
            return histogramResourceAnalysis(call)
        }, operationQueue: queue)
        let itemA = photo("blocker-a")
        let itemB = photo("blocker-b")
        let lowerItem = photo("lower")
        let targetItem = photo("target")
        let first = Task { await pipeline.analysis(for: itemA, purpose: .backgroundQuality) }
        let second = Task { await pipeline.analysis(for: itemB, purpose: .backgroundQuality) }
        try await waitUntil { probe.active == 2 }
        let lower = Task { await pipeline.analysis(for: lowerItem, purpose: .backgroundQuality) }
        try await waitUntil { queue.operationCount == 3 }
        let backgroundTarget = Task { await pipeline.analysis(for: targetItem, purpose: .backgroundQuality) }
        try await waitUntil { queue.operationCount == 4 }
        let infoTarget = Task { await pipeline.analysis(for: targetItem) }
        try await waitUntil {
            queue.operations.contains { !$0.isExecuting && $0.queuePriority == .high }
        }

        releaseA.signal()
        try await waitUntil { probe.calls("target.JPG") == 1 }
        XCTAssertEqual(probe.calls("lower.JPG"), 0, "the promoted Info request should own the next free lane")
        XCTAssertEqual(probe.maximumConcurrent, 2)
        releaseTarget.signal()
        releaseB.signal()
        let results = await [first.value, second.value, lower.value, backgroundTarget.value, infoTarget.value]
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(probe.calls("target.JPG"), 1, "foreground/background target callers must share one decode")
        XCTAssertEqual(probe.maximumConcurrent, 2)
    }

    func testRunningCancelledCompletionCannotConsumeRenewedInfoWaiter() async throws {
        let queue = OperationQueue()
        let probe = HistogramWorkerProbe()
        let releaseOld = DispatchSemaphore(value: 0)
        let releaseOther = DispatchSemaphore(value: 0)
        defer { releaseOld.signal(); releaseOther.signal() }
        let pipeline = HistogramPipeline(decoder: { url in
            let name = url.lastPathComponent
            let call = probe.begin(name)
            defer { probe.end() }
            if name == "renewed.JPG", call == 1 { _ = releaseOld.wait(timeout: .now() + 5) }
            if name == "other.JPG" { _ = releaseOther.wait(timeout: .now() + 5) }
            return histogramResourceAnalysis(call)
        }, operationQueue: queue)
        let item = photo("renewed")
        let otherItem = photo("other")
        let old = Task { await pipeline.analysis(for: item, purpose: .info) }
        try await waitUntil { probe.calls("renewed.JPG") == 1 }
        let oldOperation = try XCTUnwrap(queue.operations.first)
        let other = Task { await pipeline.analysis(for: otherItem, purpose: .backgroundQuality) }
        try await waitUntil { probe.active == 2 }
        old.cancel()
        let cancelled = await old.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(oldOperation.isCancelled)
        let renewed = Task { await pipeline.analysis(for: item) }
        try await waitUntil {
            queue.operations.contains { !$0.isExecuting && !$0.isCancelled && $0.queuePriority == .high }
        }
        XCTAssertEqual(probe.calls("renewed.JPG"), 1, "cancellation must not release a lane still inside its worker")
        releaseOld.signal()
        let result = await renewed.value
        XCTAssertEqual(result?.shadowCount, 2, "the cancelled operation must not steal renewed same-key waiters")
        releaseOther.signal()
        let otherResult = await other.value
        XCTAssertNotNil(otherResult)
        let cached = await pipeline.analysis(for: item, purpose: .backgroundQuality)
        XCTAssertEqual(cached?.shadowCount, 2)
        XCTAssertEqual(probe.calls("renewed.JPG"), 2)
        XCTAssertEqual(probe.maximumConcurrent, 2)
    }

    func testCancelledBackgroundJPEGWaitsForNativeExitAndCannotOverwriteRenewedInfo() async throws {
        let probe = HistogramWorkerProbe()
        let releaseOld = DispatchSemaphore(value: 0)
        let settled = DispatchSemaphore(value: 0)
        defer { releaseOld.signal() }
        let pipeline = HistogramPipeline(decoder: { url in
            let call = probe.begin(url.lastPathComponent)
            defer { probe.end() }
            if call == 1 { _ = releaseOld.wait(timeout: .now() + 5) }
            return histogramResourceAnalysis(call)
        })
        let item = photo("background-exit")
        let abandoned = Task {
            let result = await pipeline.analysis(for: item, purpose: .backgroundQuality)
            settled.signal()
            return result
        }
        try await waitUntil { probe.calls("background-exit.JPG") == 1 }
        abandoned.cancel()
        let prematurelySettled = await Task.detached {
            histogramResourceWait(settled, timeout: .now() + 0.05)
        }.value
        XCTAssertEqual(prematurelySettled, .timedOut,
                       "a cancelled quality generation must retain access while its native decoder still runs")
        XCTAssertEqual(probe.active, 1)

        // JPEG has two lanes: renewed work may complete in the other lane while
        // the cancelled native worker still owns its original lane and lease.
        let renewed = await pipeline.analysis(for: item)
        XCTAssertEqual(renewed?.shadowCount, 2)
        XCTAssertEqual(probe.active, 1)
        releaseOld.signal()
        let retired = await abandoned.value
        XCTAssertNil(retired)
        try await waitUntil { probe.active == 0 }
        let cached = await pipeline.analysis(for: item, purpose: .backgroundQuality)
        XCTAssertEqual(cached?.shadowCount, 2,
                       "the old completion must not overwrite the renewed numeric cache")
        XCTAssertEqual(probe.calls("background-exit.JPG"), 2)
        XCTAssertEqual(probe.maximumConcurrent, 2)
    }

    func testCancelledBackgroundRAWWaitsForNativeExitBeforeRenewedSerialDecode() async throws {
        let probe = HistogramWorkerProbe()
        let releaseOld = DispatchSemaphore(value: 0)
        let settled = DispatchSemaphore(value: 0)
        defer { releaseOld.signal() }
        let pipeline = RawHistogramPipeline(delayNanoseconds: 0, decoder: { url in
            let call = probe.begin(url.lastPathComponent)
            defer { probe.end() }
            if call == 1 { _ = releaseOld.wait(timeout: .now() + 5) }
            return histogramResourceAnalysis(call)
        })
        let item = photo(at: URL(fileURLWithPath: "/private/tmp/louppe-histogram-uncreated-\(UUID())/background-exit.NEF"))
        let abandoned = Task {
            let result = await pipeline.analysis(for: item, purpose: .backgroundQuality)
            settled.signal()
            return result
        }
        try await waitUntil { probe.calls("background-exit.NEF") == 1 }
        abandoned.cancel()
        let renewed = Task { await pipeline.analysis(for: item) }
        let prematurelySettled = await Task.detached {
            histogramResourceWait(settled, timeout: .now() + 0.05)
        }.value
        XCTAssertEqual(prematurelySettled, .timedOut,
                       "RAW cancellation must not settle until the native decoder releases its lease")
        XCTAssertEqual(probe.calls("background-exit.NEF"), 1,
                       "the cancelled RAW worker keeps the only lane until exit")
        releaseOld.signal()
        let retired = await abandoned.value
        let result = await renewed.value
        XCTAssertNil(retired)
        XCTAssertEqual(result?.shadowCount, 2,
                       "old native completion must not consume the renewed same-key waiter")
        let cached = await pipeline.analysis(for: item, purpose: .backgroundQuality)
        XCTAssertEqual(cached?.shadowCount, 2)
        XCTAssertEqual(probe.calls("background-exit.NEF"), 2)
        XCTAssertEqual(probe.maximumConcurrent, 1)
    }

    func testRunningBackgroundCancellationWaitsForSharedInfoWorkerExit() async throws {
        let queue = OperationQueue()
        let probe = HistogramWorkerProbe()
        let release = DispatchSemaphore(value: 0)
        let settled = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pipeline = HistogramPipeline(decoder: { url in
            let call = probe.begin(url.lastPathComponent)
            defer { probe.end() }
            _ = release.wait(timeout: .now() + 5)
            return histogramResourceAnalysis(call)
        }, operationQueue: queue)
        let item = photo("shared-exit")
        let background = Task {
            let result = await pipeline.analysis(for: item, purpose: .backgroundQuality)
            settled.signal()
            return result
        }
        try await waitUntil { probe.active == 1 }
        let operation = try XCTUnwrap(queue.operations.first)
        let info = Task { await pipeline.analysis(for: item) }
        try await waitUntil { operation.queuePriority == .high }
        background.cancel()
        let prematurelySettled = await Task.detached {
            histogramResourceWait(settled, timeout: .now() + 0.05)
        }.value
        XCTAssertEqual(prematurelySettled, .timedOut)
        XCTAssertFalse(operation.isCancelled, "the remaining Info waiter still needs the shared worker")
        release.signal()
        let cancelled = await background.value
        let infoResult = await info.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(infoResult?.shadowCount, 1)
        XCTAssertEqual(probe.calls("shared-exit.JPG"), 1)
    }

    func testLastQueuedWaiterCancellationDoesNoDecode() async throws {
        let queue = OperationQueue()
        queue.isSuspended = true
        defer { queue.isSuspended = false }
        let probe = HistogramWorkerProbe()
        let pipeline = HistogramPipeline(decoder: { url in
            let call = probe.begin(url.lastPathComponent)
            defer { probe.end() }
            return histogramResourceAnalysis(call)
        }, operationQueue: queue)
        let item = photo("cancelled")
        let request = Task { await pipeline.analysis(for: item, purpose: .backgroundQuality) }
        try await waitUntil { queue.operationCount == 1 }
        let operation = try XCTUnwrap(queue.operations.first)
        request.cancel()
        let cancelled = await request.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(operation.isCancelled)
        queue.isSuspended = false
        try await waitUntil { queue.operationCount == 0 }
        XCTAssertEqual(probe.calls("cancelled.JPG"), 0)
    }

    func testRevisionValidationStillWrapsTheInjectedWorker() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-histogram-revision-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.JPG")
        try Data("original fixture".utf8).write(to: url)
        let original = photo(at: url)
        XCTAssertNotNil(original.primaryFile.scannedIdentity)
        let queue = OperationQueue()
        queue.isSuspended = true
        defer { queue.isSuspended = false }
        let probe = HistogramWorkerProbe()
        let pipeline = HistogramPipeline(decoder: { url in
            let call = probe.begin(url.lastPathComponent)
            defer { probe.end() }
            return histogramResourceAnalysis(call)
        }, operationQueue: queue)
        let stale = Task { await pipeline.analysis(for: original, purpose: .backgroundQuality) }
        try await waitUntil { queue.operationCount == 1 }
        try FileManager.default.removeItem(at: url)
        try Data("replacement fixture".utf8).write(to: url)
        queue.isSuspended = false
        let rejected = await stale.value
        XCTAssertNil(rejected)
        XCTAssertEqual(probe.calls("source.JPG"), 0)
        let replacement = photo(at: url)
        XCTAssertNotEqual(original.contentRevision, replacement.contentRevision)
        let fresh = await pipeline.analysis(for: replacement)
        XCTAssertNotNil(fresh)
        XCTAssertEqual(probe.calls("source.JPG"), 1)
    }

    private func photo(_ stem: String) -> PhotoItem {
        photo(at: URL(fileURLWithPath: "/private/tmp/louppe-histogram-uncreated-\(UUID())/\(stem).JPG"))
    }

    private func photo(at url: URL) -> PhotoItem {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
                         captureDate: nil, cameraModel: nil, lensModel: nil,
                         primaryModificationDate: values?.contentModificationDate,
                         fileSize: Int64(values?.fileSize ?? 1))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard condition() else {
            XCTFail("Timed out waiting for the histogram worker state")
            throw NSError(domain: "HistogramResourceTests", code: 1)
        }
    }
}

private final class HistogramWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var running = 0
    private var maximum = 0
    var active: Int { lock.withLock { running } }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    func calls(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
    func begin(_ name: String) -> Int {
        lock.withLock {
            counts[name, default: 0] += 1
            running += 1
            maximum = max(maximum, running)
            return counts[name, default: 0]
        }
    }
    func end() { lock.withLock { running -= 1 } }
}

private func histogramResourceAnalysis(_ marker: Int) -> HistogramAnalysis {
    HistogramAnalysis(bins: Array(repeating: 0, count: 256), sampleCount: 100,
                      shadowCount: marker, highlightCount: 0, width: 10, height: 10)
}

private func histogramResourceWait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}
