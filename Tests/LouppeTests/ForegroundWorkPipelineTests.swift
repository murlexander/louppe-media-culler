import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ForegroundWorkPipelineTests: XCTestCase {
    func testVisibleFullImagePromotesDeferredNeighbourAndCancellationPreservesForeground() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let worker = BrowsingWorkerProbe(stallsFirst: true)
        defer { worker.release.signal() }
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 1,
                                     foregroundWork: coordinator) { _, _ in
            browsingPixels(width: worker.work())
        }
        let photo = item("promoted.JPG")
        let neighbours = pipeline.prefetchFullImages(items: [photo])
        defer { neighbours.cancel() }
        try await boundary { coordinator.waitingCountForTesting == 1 }
        XCTAssertEqual(worker.calls, 0)
        let foreground = Task { await pipeline.fullImage(for: photo) }
        defer { foreground.cancel() }
        try await boundary { worker.calls == 1 && pipeline.decodeWaiterCountForTesting(for: photo, full: true) == 2 }
        neighbours.cancel()
        await neighbours.value
        XCTAssertEqual(pipeline.decodeWaiterCountForTesting(for: photo, full: true), 1)
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
        worker.release.signal()
        let pixels = await foreground.value
        XCTAssertEqual(pixels?.size.width, 1)
        XCTAssertEqual(worker.calls, 1, "foreground must promote the existing decode")
        XCTAssertNotNil(pipeline.cachedFullImage(for: photo))
    }

    func testDeferredNeighbourPopulationIsBoundedAndRetirementCannotConsumeRenewedKey() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let worker = BrowsingWorkerProbe()
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, foregroundWork: coordinator) { _, _ in
            browsingPixels(width: worker.work())
        }
        let photos = (0..<30).map { item("\($0).JPG") }
        let neighbours = pipeline.prefetchFullImages(items: [photos[0]] + photos)
        try await boundary { coordinator.waitingCountForTesting == ImagePipeline.neighbourPrefetchLimit }
        XCTAssertEqual(worker.calls, 0)
        XCTAssertTrue(photos.dropFirst(4).allSatisfy { pipeline.decodeWaiterCountForTesting(for: $0, full: true) == 0 })
        neighbours.cancel()
        await neighbours.value
        try await boundary { coordinator.waitingCountForTesting == 0 }
        XCTAssertTrue(photos.allSatisfy { pipeline.decodeWaiterCountForTesting(for: $0, full: true) == 0 })
        let pixels = await pipeline.fullImage(for: photos[0])
        XCTAssertNotNil(pixels)
        XCTAssertEqual(worker.calls, 1, "obsolete deferred work must never enter the decoder")
    }

    func testInfoPromotesDeferredRenderedAndRawHistogramsAndBackgroundWaitsForExit() async throws {
        for raw in [false, true] {
            let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
            let demand = coordinator.beginForegroundDemand()
            defer { demand.finish() }
            let worker = BrowsingWorkerProbe(stallsFirst: true)
            defer { worker.release.signal() }
            let harness = BrowsingHistogramHarness(raw: raw, coordinator: coordinator, worker: worker)
            let photo = item(raw ? "promoted.RAF" : "promoted.JPG")
            let background = Task { await harness.analysis(photo, background: true) }
            defer { background.cancel() }
            try await boundary { coordinator.waitingCountForTesting == 1 }
            XCTAssertEqual(worker.calls, 0)
            let info = Task { await harness.analysis(photo, background: false) }
            defer { info.cancel() }
            try await boundary { worker.calls == 1 && harness.waiters(photo) == 2 }
            background.cancel()
            try await boundary { harness.waiters(photo) == 1 }
            worker.release.signal()
            let abandoned = await background.value
            let foreground = await info.value
            XCTAssertNil(abandoned)
            XCTAssertNotNil(foreground)
            XCTAssertEqual(worker.calls, 1)
            XCTAssertEqual(coordinator.waitingCountForTesting, 0)
        }
    }

    func testCancelledHistogramAdmissionNeverDecodesAndRenewedInfoStillWorks() async throws {
        for raw in [false, true] {
            let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
            let demand = coordinator.beginForegroundDemand()
            defer { demand.finish() }
            let worker = BrowsingWorkerProbe()
            let harness = BrowsingHistogramHarness(raw: raw, coordinator: coordinator, worker: worker)
            let photo = item(raw ? "retired.RAF" : "retired.JPG")
            let background = Task { await harness.analysis(photo, background: true) }
            try await boundary { coordinator.waitingCountForTesting == 1 }
            background.cancel()
            let retired = await background.value
            XCTAssertNil(retired)
            try await boundary { coordinator.waitingCountForTesting == 0 }
            XCTAssertEqual(worker.calls, 0)
            XCTAssertEqual(harness.waiters(photo), 0)
            let renewed = await harness.analysis(photo, background: false)
            XCTAssertNotNil(renewed)
            XCTAssertEqual(worker.calls, 1)
        }
    }

    func testThumbnailPixelsPublishWhileBoundedOptionalDiskDrainWaitsForAdmission() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let writer = BrowsingWorkerProbe()
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, foregroundWork: coordinator,
                                     testingDiskWriter: { _, _ in _ = writer.work() },
                                     decoder: { _, _ in browsingPixels(width: 2) })
        for index in 0..<40 {
            let pixels = await pipeline.thumbnail(for: item("disk-\(index).JPG"))
            XCTAssertNotNil(pixels)
        }
        try await boundary { coordinator.waitingCountForTesting == 1 }
        XCTAssertEqual(writer.calls, 0)
        XCTAssertEqual(pipeline.pendingDiskWritesForTesting.count, ImagePipeline.pendingDiskWriteCountLimit)
        XCTAssertLessThanOrEqual(pipeline.pendingDiskWritesForTesting.bytes, ImagePipeline.pendingDiskWriteByteLimit)
        demand.finish()
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(writer.calls, ImagePipeline.pendingDiskWriteCountLimit)
        XCTAssertEqual(pipeline.pendingDiskWritesForTesting.count, 0)
        XCTAssertEqual(pipeline.pendingDiskWritesForTesting.bytes, 0)
    }

    private func item(_ name: String) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-browsing-synthetic/\(name)"),
                                        captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1, scannedIdentity: nil))
    }

    private func temporaryFolder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp/louppe-browsing-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func boundary(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "worker/admission did not reach the expected boundary")
        if !condition() { throw BrowsingPipelineTestError.boundaryTimeout }
    }
}

private enum BrowsingPipelineTestError: Error { case boundaryTimeout }

private final class BrowsingHistogramHarness: @unchecked Sendable {
    let rendered: HistogramPipeline
    let raw: RawHistogramPipeline
    let usesRaw: Bool

    init(raw: Bool, coordinator: ForegroundWorkCoordinator, worker: BrowsingWorkerProbe) {
        usesRaw = raw
        let decoder: HistogramPipeline.Decoder = { _ in
            let count = worker.work()
            return HistogramAnalysis(bins: Array(repeating: 0, count: 256), sampleCount: count,
                                     shadowCount: 0, highlightCount: 0, width: 1, height: 1)
        }
        rendered = HistogramPipeline(decoder: decoder, foregroundWork: coordinator)
        self.raw = RawHistogramPipeline(delayNanoseconds: 0, foregroundWork: coordinator, decoder: decoder)
    }

    func analysis(_ item: PhotoItem, background: Bool) async -> HistogramAnalysis? {
        if usesRaw { return await raw.analysis(for: item, purpose: background ? .backgroundQuality : .info) }
        return await rendered.analysis(for: item, purpose: background ? .backgroundQuality : .info)
    }

    func waiters(_ item: PhotoItem) -> Int {
        usesRaw ? raw.waiterCountForTesting(for: item) : rendered.waiterCountForTesting(for: item)
    }
}

private final class BrowsingWorkerProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private let stallsFirst: Bool
    var calls: Int { lock.withLock { count } }
    init(stallsFirst: Bool = false) { self.stallsFirst = stallsFirst }
    func work() -> Int {
        let call = lock.withLock { count += 1; return count }
        if stallsFirst, call == 1 { _ = release.wait(timeout: .now() + 10) }
        return call
    }
}

private func browsingPixels(width: Int) -> CGImage? {
    let bytes = Data(repeating: 127, count: width * 4)
    guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
    return CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
