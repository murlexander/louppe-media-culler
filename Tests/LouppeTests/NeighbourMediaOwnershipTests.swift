import AppKit
import CoreImage
import XCTest
@testable import Louppe

/// Fault-injected workers reproduce navigation abandonment without relying on
/// decode speed, NSCache's eviction policy, or a particular camera format.
@MainActor
final class NeighbourMediaOwnershipTests: XCTestCase {
    func testNeighbourAdmissionIsUniqueAndBoundedAndCancellationRetiresQueuedWork() async throws {
        for source in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = NeighbourWorkerGate()
            defer { gate.release.signal() }
            let pipeline = harness(folder: folder, source: source, gate: gate)
            let photos = (0..<20).map { item("\($0).JPG") }
            let lease = pipeline.prefetch([photos[0], photos[0]] + photos)
            try await eventually { gate.calls == 1 && photos.prefix(4).allSatisfy { pipeline.waiters($0) == 1 } }
            XCTAssertTrue(photos.dropFirst(4).allSatisfy { pipeline.waiters($0) == 0 })
            lease.cancel()
            await lease.value
            XCTAssertTrue(photos.allSatisfy { pipeline.waiters($0) == 0 })
            gate.release.signal()
            await pipeline.drain()
            XCTAssertEqual(gate.calls, 1, "cancelled queued neighbours must never enter the worker")
            XCTAssertFalse(pipeline.isCached(photos[0]), "an abandoned running neighbour must not warm memory")
        }
    }

    func testCancellingNeighbourLeavesCoalescedForegroundAlive() async throws {
        for source in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = NeighbourWorkerGate()
            defer { gate.release.signal() }
            let pipeline = harness(folder: folder, source: source, gate: gate)
            let photo = item("shared.JPG")
            let lease = pipeline.prefetch([photo])
            try await eventually { gate.calls == 1 }
            let foreground = Task { await pipeline.load(photo) }
            try await eventually { pipeline.waiters(photo) == 2 }
            lease.cancel()
            await lease.value
            XCTAssertEqual(pipeline.waiters(photo), 1)
            gate.release.signal()
            let width = await foreground.value
            XCTAssertEqual(width, 1)
            XCTAssertTrue(pipeline.isCached(photo))
            XCTAssertEqual(gate.calls, 1)
        }
    }

    func testAbandonedNeighbourKeepsLaneAndCannotConsumeRenewedSameKey() async throws {
        for source in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = NeighbourWorkerGate()
            defer { gate.release.signal() }
            let pipeline = harness(folder: folder, source: source, gate: gate)
            let photo = item("renewed.JPG")
            let lease = pipeline.prefetch([photo])
            try await eventually { gate.calls == 1 }
            lease.cancel()
            await lease.value
            let foreground = Task { await pipeline.load(photo) }
            try await eventually { pipeline.waiters(photo) == 1 }
            // Negative observation while the first synchronous worker is held.
            let premature = await Task.detached { neighbourWait(gate.secondStarted, seconds: 0.08) }.value
            XCTAssertEqual(premature, .timedOut)
            gate.release.signal()
            let width = await foreground.value
            XCTAssertEqual(width, 2, "old completion must not satisfy the renewed request")
            let cachedWidth = await pipeline.load(photo)
            XCTAssertEqual(cachedWidth, 2)
            XCTAssertEqual(gate.maximumConcurrent, 1)
            XCTAssertEqual(gate.calls, 2)
        }
    }

    func testAlreadyCancelledNeighbourTaskDoesNotAdmitWorkers() async throws {
        for source in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = NeighbourWorkerGate()
            let pipeline = harness(folder: folder, source: source, gate: gate)
            // Parent cancellation is checked before returning detached ownership.
            await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await pipeline.prefetch([item("cancelled.JPG")]).value
            }.value
            await pipeline.drain()
            XCTAssertEqual(gate.calls, 0)
        }
    }

    func testSourceMutationDuringRecipeCreationIsRejected() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.JPG")
        try Data("original".utf8).write(to: url)
        let photo = try scannedItem(at: url)
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 1) { revision, key, decoder in
            try? Data("replacement".utf8).write(to: revision.url, options: .atomic)
            return ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                                   pixelSize: CGSize(width: 1, height: 1), sourceRevision: revision, decoder: decoder)
        }
        let result = await pipeline.source(for: photo)
        XCTAssertNil(result)
        XCTAssertFalse(pipeline.sourceIsCachedForTesting(for: photo))
    }

    func testOptionalDiskWritesCoalesceAndRemainBoundedWhileWriterIsStalled() async throws {
        for tiny in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = NeighbourWorkerGate()
            defer { gate.release.signal() }
            let bitmap = try XCTUnwrap(neighbourImage(width: tiny ? 1 : 320, height: tiny ? 1 : 320))
            let pipeline = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"),
                                         testingDiskWriter: { _, _ in
                let call = gate.begin()
                defer { gate.end() }
                if call == 1 { _ = neighbourWait(gate.release, seconds: 10) }
            }, decoder: { _, _ in bitmap })
            let first = item("first.JPG")
            let initial = await pipeline.thumbnail(for: first)
            XCTAssertNotNil(initial)
            try await eventually { gate.calls == 1 }
            let initialState = pipeline.pendingDiskWritesForTesting
            for _ in 0..<4 {
                pipeline.evictThumbnailForTesting(for: first)
                let repeated = await pipeline.thumbnail(for: first)
                XCTAssertNotNil(repeated)
            }
            XCTAssertEqual(pipeline.pendingDiskWritesForTesting.count, initialState.count,
                           "the active key counts toward admission and coalesces repeated writes")
            XCTAssertEqual(pipeline.pendingDiskWritesForTesting.bytes, initialState.bytes)
            for index in 0..<100 {
                let pixels = await pipeline.thumbnail(for: item("queued-\(index).JPG"))
                XCTAssertNotNil(pixels, "disk saturation cannot prevent visible pixels")
                let pending = pipeline.pendingDiskWritesForTesting
                XCTAssertLessThanOrEqual(pending.count, ImagePipeline.pendingDiskWriteCountLimit)
                XCTAssertLessThanOrEqual(pending.bytes, ImagePipeline.pendingDiskWriteByteLimit)
            }
            let saturated = pipeline.pendingDiskWritesForTesting
            if tiny {
                XCTAssertEqual(saturated.count, ImagePipeline.pendingDiskWriteCountLimit)
            } else {
                XCTAssertLessThan(ImagePipeline.pendingDiskWriteByteLimit - saturated.bytes, bitmap.bytesPerRow * bitmap.height)
            }
            gate.release.signal()
            await pipeline.waitForPendingDiskWrites()
            XCTAssertEqual(pipeline.pendingDiskWritesForTesting.count, 0)
            XCTAssertEqual(pipeline.pendingDiskWritesForTesting.bytes, 0)
            let admitted = await pipeline.thumbnail(for: item("after-drain.JPG"))
            XCTAssertNotNil(admitted)
            await pipeline.waitForPendingDiskWrites()
            XCTAssertEqual(gate.calls, saturated.count + 1, "admission recovers after saturation")
        }
    }

    func testDiskCacheWritesLeaveSourceBytesAndIdentityIntact() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original.JPG")
        let bytes = Data("original source bytes".utf8)
        try bytes.write(to: url)
        let photo = try scannedItem(at: url)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"), decoder: { _, _ in neighbourImage(width: 8) })
        let pixels = await pipeline.thumbnail(for: photo)
        XCTAssertNotNil(pixels)
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(MediaSourceRevision(photo).matchesCurrentFile())
        let cacheURL = folder.appendingPathComponent("cache").appendingPathComponent(ImagePipeline.diskFileName(for: ImagePipeline.cacheKey(for: photo)))
        XCTAssertNotNil(ImagePipeline.decodeImage(url: cacheURL, maxPixel: 320))
    }

    func testOversizedOptionalDiskWriteIsDroppedWithoutBlockingPixelsOrLaterWrites() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = NeighbourWorkerGate()
        let oversized = try XCTUnwrap(neighbourImage(width: 2048, height: 2048))
        XCTAssertGreaterThan(oversized.bytesPerRow * oversized.height, ImagePipeline.pendingDiskWriteByteLimit)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, testingDiskWriter: { _, _ in
            _ = gate.begin()
            gate.end()
        }, decoder: { url, _ in
            url.lastPathComponent == "oversized.JPG" ? oversized : neighbourImage(width: 1)
        })
        let largePixels = await pipeline.thumbnail(for: item("oversized.JPG"))
        XCTAssertNotNil(largePixels)
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(gate.calls, 0)
        XCTAssertEqual(pipeline.pendingDiskWritesForTesting.bytes, 0)
        let smallPixels = await pipeline.thumbnail(for: item("small.JPG"))
        XCTAssertNotNil(smallPixels)
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(gate.calls, 1)
    }

    func testRetainedThumbnailPixelsSurviveCacheMissOnlyForMatchingRevision() throws {
        let first = item("first.JPG")
        let second = item("second.JPG")
        let pixels = NSImage(size: CGSize(width: 10, height: 10))
        var retained = ThumbnailImageState(revision: first.contentRevision, image: pixels)
        XCTAssertFalse(retained.prepare(revision: first.contentRevision, cached: nil, hasVisualPreview: true))
        XCTAssertTrue(retained.image === pixels, "task re-entry after NSCache eviction must keep displayed pixels")
        XCTAssertTrue(retained.prepare(revision: second.contentRevision, cached: nil, hasVisualPreview: true))
        XCTAssertNil(retained.image, "a new revision must not inherit the previous photo")
        retained.accept(pixels, revision: first.contentRevision)
        XCTAssertNil(retained.image, "late old-revision completion must be ignored")
        retained.accept(pixels, revision: second.contentRevision)
        XCTAssertTrue(retained.image === pixels)
        XCTAssertFalse(retained.prepare(revision: second.contentRevision, cached: nil, hasVisualPreview: false))
        XCTAssertNil(retained.image)
    }

    private func harness(folder: URL, source: Bool, gate: NeighbourWorkerGate) -> NeighbourPipelineHarness {
        NeighbourPipelineHarness(folder: folder, source: source, gate: gate)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "worker/continuation state did not reach the expected boundary")
        if !condition() { throw NeighbourTestError.boundaryTimeout }
    }

    private func temporaryFolder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("louppe-neighbours-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ name: String) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-synthetic/\(name)"),
                                        captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1, scannedIdentity: nil))
    }

    private func scannedItem(at url: URL) throws -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: url.lastPathComponent, url: url, captureDate: nil, cameraModel: nil,
                                        lensModel: nil, fileSize: 1, scannedIdentity: try FileOperationJournal.captureIdentity(at: url)))
    }
}

private enum NeighbourTestError: Error { case boundaryTimeout }

private final class NeighbourPipelineHarness: @unchecked Sendable {
    let full: ImagePipeline
    let high: HighResolutionImagePipeline
    let usesSource: Bool

    init(folder: URL, source: Bool, gate: NeighbourWorkerGate) {
        usesSource = source
        full = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 1) { _, _ in
            let call = gate.work()
            return neighbourImage(width: call)
        }
        high = HighResolutionImagePipeline(testingSourceConcurrency: 1) { revision, key, decoder in
            let call = gate.work()
            return ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(call), height: 1)),
                                   pixelSize: CGSize(width: CGFloat(call), height: 1), sourceRevision: revision, decoder: decoder)
        }
    }

    func prefetch(_ items: [PhotoItem]) -> Task<Void, Never> {
        usesSource ? high.prefetchSources(items: items) : full.prefetchFullImages(items: items)
    }
    func waiters(_ item: PhotoItem) -> Int {
        usesSource ? high.sourceWaiterCountForTesting(for: item) : full.decodeWaiterCountForTesting(for: item, full: true)
    }
    func load(_ item: PhotoItem) async -> CGFloat? {
        if usesSource { return await high.source(for: item)?.pixelSize.width }
        return await full.fullImage(for: item)?.size.width
    }
    func isCached(_ item: PhotoItem) -> Bool {
        usesSource ? high.sourceIsCachedForTesting(for: item) : full.cachedFullImage(for: item) != nil
    }
    func drain() async {
        if usesSource { await high.waitForSourceWorkForTesting() }
        else { await full.waitForFullWorkForTesting() }
    }
}

private final class NeighbourWorkerGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let secondStarted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var maximum = 0
    var calls: Int { lock.withLock { count } }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    func begin() -> Int { lock.withLock { count += 1; active += 1; maximum = max(maximum, active); return count } }
    func end() { lock.withLock { active -= 1 } }
    func work() -> Int {
        let call = begin()
        defer { end() }
        if call == 1 { _ = neighbourWait(release, seconds: 10) }
        else { secondStarted.signal() }
        return call
    }
}

private func neighbourWait(_ semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + seconds)
}

private func neighbourImage(width: Int, height: Int = 1) -> CGImage? {
    let bytes = Data(repeating: 127, count: width * height * 4)
    guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
