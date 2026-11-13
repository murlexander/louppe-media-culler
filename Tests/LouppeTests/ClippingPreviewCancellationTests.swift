import AppKit
import ImageIO
import XCTest
@testable import Louppe

@MainActor
final class ClippingPreviewCancellationTests: XCTestCase {
    func testAbandonedQueuedTransformsReleaseImagesBeforeRunningLanesExit() async throws {
        let fixture = try ClippingCancellationFixture()
        defer { fixture.remove() }
        let queue = OperationQueue()
        let probe = ClippingCancellationProbe()
        defer { probe.releaseAll() }
        let pipeline = ClippingPreviewPipeline(operationQueue: queue, source: { item in
            fixture.load(item, probe: probe)
        }, transform: { image in
            probe.begin(image.width)
            if image.width <= 12 { probe.wait(image.width) }
            return ClippingWarningProcessor.overlay(on: image)
        })
        let blockers = fixture.items.prefix(2).map { item in Task { await pipeline.image(for: item) } }
        try await waitUntil { probe.callCount == 2 }
        var finished: Set<String> = []
        let abandoned = fixture.items.dropFirst(2).map { item in
            Task {
                let result = await pipeline.image(for: item)
                finished.insert(item.id)
                return result
            }
        }
        try await waitUntil { fixture.items.dropFirst(2).allSatisfy { pipeline.waiterCountForTesting(for: $0) == 1 } }
        for task in abandoned { task.cancel() }
        let retiredBeforeExit = await eventually {
            fixture.items.dropFirst(2).allSatisfy { pipeline.waiterCountForTesting(for: $0) == 0 }
                && finished.count == abandoned.count && probe.releasedWidths.isSuperset(of: Set(13...18))
        }
        XCTAssertTrue(retiredBeforeExit, "Cancelled waiters and queued CGImages must retire while both lanes remain stalled")
        XCTAssertEqual(probe.callCount, 2, "Cancelled queued transforms must not start")
        XCTAssertTrue(queue.operations.filter(\.isExecuting).count == 2, "Stalled workers must still own both lanes")
        probe.releaseAll()
        let results = await abandoned.asyncValues()
        for task in blockers { _ = await task.value }
        await pipeline.waitForWorkForTesting()
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertEqual(probe.callCount, 2, "Abandoned transforms must not run after blockers exit")
        XCTAssertTrue(fixture.items.dropFirst(2).allSatisfy { pipeline.cachedImage(for: $0) == nil })
    }

    func testCancellingOneSharedWaiterPreservesTheOtherAndCachesOnce() async throws {
        let fixture = try ClippingCancellationFixture()
        defer { fixture.remove() }
        let probe = ClippingCancellationProbe()
        let queue = OperationQueue()
        queue.isSuspended = true
        defer { queue.isSuspended = false }
        let pipeline = ClippingPreviewPipeline(operationQueue: queue, source: { item in
            fixture.load(item, probe: probe)
        }, transform: { image in
            probe.begin(image.width)
            return ClippingWarningProcessor.overlay(on: image)
        })
        let item = fixture.items[0]
        let first = Task { await pipeline.image(for: item) }
        let survivor = Task { await pipeline.image(for: item) }
        try await waitUntil { pipeline.waiterCountForTesting(for: item) == 2 }
        first.cancel()
        let retired = await eventually { pipeline.waiterCountForTesting(for: item) == 1 }
        XCTAssertTrue(retired, "Cancellation must remove only its own waiter")
        queue.isSuspended = false
        let firstResult = await first.value
        let survivorResult = await survivor.value
        await pipeline.waitForWorkForTesting()
        XCTAssertNil(firstResult)
        XCTAssertNotNil(survivorResult)
        XCTAssertNotNil(pipeline.cachedImage(for: item))
        XCTAssertEqual(probe.callCount, 1)
    }

    func testCancelledRunningCompletionCannotClobberReplacementOrFreeItsLane() async throws {
        let fixture = try ClippingCancellationFixture()
        defer { fixture.remove() }
        let probe = ClippingCancellationProbe()
        defer { probe.releaseAll() }
        let queue = OperationQueue()
        let pipeline = ClippingPreviewPipeline(operationQueue: queue, source: { item in
            fixture.load(item, probe: probe)
        }, transform: { image in
            let call = probe.begin(image.width)
            if image.width == 11 || image.width == 12 { probe.wait(image.width) }
            // Distinguishable first/replacement results, still real pixel work.
            let width = call == 1 ? 1 : 2
            return ClippingWarningProcessor.overlay(on: image)?.cropping(to: CGRect(x: 0, y: 0, width: width, height: 1))
        })
        let item = fixture.items[0]
        let old = Task { await pipeline.image(for: item) }
        let other = Task { await pipeline.image(for: fixture.items[1]) }
        try await waitUntil { probe.callCount == 2 }
        old.cancel()
        let retired = await eventually { pipeline.waiterCountForTesting(for: item) == 0 }
        XCTAssertTrue(retired)
        let renewed = Task { await pipeline.image(for: item) }
        // Old code retains both waiters on the old request instead of queuing a new operation.
        let queuedReplacement = await eventually { queue.operations.contains { !$0.isExecuting && !$0.isCancelled } }
        XCTAssertTrue(queuedReplacement)
        XCTAssertEqual(probe.calls(11), 1, "Cancellation must not free a lane still inside a native transform")
        probe.release(11)
        try await waitUntil { probe.calls(11) == 2 || pipeline.cachedImage(for: item) != nil }
        if probe.calls(11) == 2 {
            XCTAssertNil(pipeline.cachedImage(for: item), "Retired completion cannot cache or consume replacement waiters")
        }
        probe.releaseAll()
        let oldResult = await old.value
        let result = await renewed.value
        _ = await other.value
        await pipeline.waitForWorkForTesting()
        XCTAssertNil(oldResult)
        XCTAssertEqual(result?.size.width, 2)
        XCTAssertEqual(pipeline.cachedImage(for: item)?.size.width, 2)
        XCTAssertEqual(probe.calls(11), 2)
    }

    func testCancellationDuringSourceLoadNeverRegistersATransform() async throws {
        let fixture = try ClippingCancellationFixture()
        defer { fixture.remove() }
        let probe = ClippingCancellationProbe()
        let gate = ClippingSourceGate()
        defer { gate.release() }
        let pipeline = ClippingPreviewPipeline(operationQueue: OperationQueue(), source: { item in
            let image = fixture.load(item, probe: probe)
            await gate.wait()
            return image
        }, transform: { image in
            probe.begin(image.width)
            return ClippingWarningProcessor.overlay(on: image)
        })
        let item = fixture.items[0]
        let task = Task { await pipeline.image(for: item) }
        try await waitUntil { gate.isWaiting }
        task.cancel()
        gate.release()
        let result = await task.value
        await pipeline.waitForWorkForTesting()
        XCTAssertNil(result)
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertEqual(pipeline.waiterCountForTesting(for: item), 0)
        XCTAssertNil(pipeline.cachedImage(for: item))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        guard await eventually(condition) else {
            XCTFail("Timed out waiting for clipping transform state")
            throw NSError(domain: "ClippingPreviewCancellationTests", code: 1)
        }
    }
}

private extension Array where Element == Task<NSImage?, Never> {
    @MainActor func asyncValues() async -> [NSImage?] {
        var values: [NSImage?] = []
        for task in self { values.append(await task.value) }
        return values
    }
}

private final class ClippingCancellationFixture: @unchecked Sendable {
    let folder: URL
    let items: [PhotoItem]

    @MainActor init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipping-cancellation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = self.folder
        items = try (11...18).map { width in
            let url = folder.appendingPathComponent("\(width).jpg")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            memset(try XCTUnwrap(bitmap.bitmapData), 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
            try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
            return PhotoItem(primaryFile: PhotoFile(id: UUID().uuidString, url: url, captureDate: nil,
                                                   cameraModel: nil, lensModel: nil, fileSize: 1))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func load(_ item: PhotoItem, probe: ClippingCancellationProbe) -> CGImage? {
        // Real ImageIO I/O, with a provider whose release callback measures the
        // exact lifetime of these decoded source pixels (not a weak wrapper).
        guard let source = CGImageSourceCreateWithURL(item.primaryURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data,
              let bytes = malloc(CFDataGetLength(data)) else { return nil }
        memcpy(bytes, CFDataGetBytePtr(data), CFDataGetLength(data))
        let token = Unmanaged.passRetained(ClippingSourceRelease(width: image.width, probe: probe))
        guard let provider = CGDataProvider(dataInfo: token.toOpaque(), data: bytes, size: CFDataGetLength(data), releaseData: { info, bytes, _ in
            if let info {
                let token = Unmanaged<ClippingSourceRelease>.fromOpaque(info).takeRetainedValue()
                token.probe.released(token.width)
            }
            free(UnsafeMutableRawPointer(mutating: bytes))
        }) else { token.release(); free(bytes); return nil }
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                       bytesPerRow: image.bytesPerRow, space: image.colorSpace!, bitmapInfo: image.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private final class ClippingSourceRelease {
    let width: Int
    let probe: ClippingCancellationProbe
    init(width: Int, probe: ClippingCancellationProbe) { self.width = width; self.probe = probe }
}

private final class ClippingCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int: Int] = [:]
    private var releases: Set<Int> = []
    private let gates = [11: DispatchSemaphore(value: 0), 12: DispatchSemaphore(value: 0)]
    var callCount: Int { lock.withLock { counts.values.reduce(0, +) } }
    var releasedWidths: Set<Int> { lock.withLock { releases } }
    func calls(_ width: Int) -> Int { lock.withLock { counts[width, default: 0] } }
    @discardableResult func begin(_ width: Int) -> Int {
        lock.withLock { counts[width, default: 0] += 1; return counts[width]! }
    }
    func released(_ width: Int) { lock.withLock { _ = releases.insert(width) } }
    func wait(_ width: Int) { _ = gates[width]?.wait(timeout: .now() + 8) }
    func release(_ width: Int) { gates[width]?.signal() }
    func releaseAll() { for _ in 0..<10 { gates.values.forEach { $0.signal() } } }
}

private final class ClippingSourceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }
    func release() {
        let waiter = lock.withLock {
            let result = continuation
            continuation = nil
            return result
        }
        waiter?.resume()
    }
}
