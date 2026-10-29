#if DEBUG
import AppKit
import CoreImage
import XCTest
@testable import Louppe

@MainActor
final class ReadyMediaAccessTests: XCTestCase {
    func testCancelledReadyWorkersKeepExactIndependentAccessAcrossCloseAndSwitch() async throws {
        for kind in ReadyAccessHarness.Kind.allCases {
            let fixture = try fixture(raw: kind == .raw)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let scope = ReadyScopeProbe()
            let exact = fixture.root.appendingPathComponent("picker/../", isDirectory: true)
            let owner = SecurityScopedFolderAccess(url: exact, resourceAccess: scope.access)
            XCTAssertNotEqual(exact.absoluteString, owner.url.absoluteString)
            let worker = ReadyAccessWorker(scope: scope)
            defer { worker.release.signal() }
            let harness = ReadyAccessHarness(kind: kind, root: fixture.root, worker: worker)
            let request = Task { await harness.load(fixture.photo, access: owner.makeReadAuthority()) }
            defer { request.cancel() }
            try await boundary { worker.calls == 1 }
            XCTAssertEqual(scope.active, 2, "session and worker must own separate starts: \(kind)")
            request.cancel()
            let result = await request.value
            XCTAssertNil(result)
            owner.stop() // Close the original session while native work is held.
            let nextOwner = SecurityScopedFolderAccess(
                url: fixture.root.appendingPathComponent("new-picker/../", isDirectory: true),
                resourceAccess: scope.access
            )
            nextOwner.stop() // A later session's lease cannot be the worker's lease.
            XCTAssertEqual(scope.active, 1)
            XCTAssertEqual(scope.starts.filter { $0 == exact.absoluteString }.count, 2)
            XCTAssertEqual(scope.stops.filter { $0 == exact.absoluteString }.count, 1)
            worker.release.signal()
            try await boundary { scope.active == 0 }
            XCTAssertEqual(worker.unprotectedReads, 0)
            XCTAssertEqual(worker.failedReads, 0)
            XCTAssertEqual(scope.starts.sorted(), scope.stops.sorted())
            let exit = try XCTUnwrap(scope.events.firstIndex(of: "read-exit-1"))
            let finalStop = try XCTUnwrap(scope.events.lastIndex(of: "stop " + exact.absoluteString))
            XCTAssertLessThan(exit, finalStop, "exact worker grant must stop after native read exit")
        }
    }

    func testForegroundJoinSuppliesMissingAuthorityToDeferredFullAndHistogramWork() async throws {
        for kind in [ReadyAccessHarness.Kind.full, .rendered, .raw] {
            let fixture = try fixture(raw: kind == .raw)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let scope = ReadyScopeProbe()
            let owner = SecurityScopedFolderAccess(url: fixture.root.appendingPathComponent("grant/../"), resourceAccess: scope.access)
            let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
            let demand = coordinator.beginForegroundDemand()
            defer { demand.finish() }
            let worker = ReadyAccessWorker(scope: scope)
            defer { worker.release.signal() }
            let harness = ReadyAccessHarness(kind: kind, root: fixture.root, worker: worker, coordinator: coordinator)
            let background = harness.background(fixture.photo) // Deliberately has no authority.
            defer { background.cancel() }
            try await boundary { coordinator.waitingCountForTesting == 1 }
            XCTAssertEqual(worker.calls, 0)
            let visible = Task { await harness.load(fixture.photo, access: owner.makeReadAuthority()) }
            defer { visible.cancel() }
            try await boundary { worker.calls == 1 && harness.waiters(fixture.photo) == 2 }
            XCTAssertEqual(scope.active, 2)
            background.cancel()
            visible.cancel()
            owner.stop()
            try await boundary { harness.waiters(fixture.photo) == 0 }
            XCTAssertEqual(scope.active, 1)
            worker.release.signal()
            await background.value
            let result = await visible.value
            XCTAssertNil(result)
            try await boundary { scope.active == 0 }
            XCTAssertEqual(worker.calls, 1, "promotion must preserve coalescing")
            XCTAssertEqual(worker.unprotectedReads, 0)
            XCTAssertEqual(worker.failedReads, 0)
            XCTAssertEqual(scope.starts.sorted(), scope.stops.sorted())
        }
    }

    func testAuthorizedPrefetchKeepsGrantWhenNilForegroundJoinsAfterOwnerCloses() async throws {
        for kind in [ReadyAccessHarness.Kind.full, .source] {
            let fixture = try fixture(raw: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let scope = ReadyScopeProbe()
            let owner = SecurityScopedFolderAccess(url: fixture.root.appendingPathComponent("prefetch/../"), resourceAccess: scope.access)
            let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
            let demand = coordinator.beginForegroundDemand()
            defer { demand.finish() }
            let worker = ReadyAccessWorker(scope: scope)
            defer { worker.release.signal() }
            let harness = ReadyAccessHarness(kind: kind, root: fixture.root, worker: worker, coordinator: coordinator)
            let prefetch = kind == .full
                ? harness.image.prefetchFullImages(items: [fixture.photo], sourceAccess: owner.makeReadAuthority())
                : harness.high.prefetchSources(items: [fixture.photo], sourceAccess: owner.makeReadAuthority())
            defer { prefetch.cancel() }
            try await boundary { harness.waiters(fixture.photo) == 1 && scope.active == 2 }
            owner.stop()
            XCTAssertEqual(scope.active, 1, "even deferred/queued prefetch owns its grant independently")
            let visible = Task { await harness.load(fixture.photo, access: nil) }
            defer { visible.cancel() }
            try await boundary { worker.calls == 1 && harness.waiters(fixture.photo) == 2 }
            XCTAssertEqual(scope.active, 1, "nil joins must never replace an existing grant")
            prefetch.cancel()
            visible.cancel()
            await prefetch.value
            _ = await visible.value
            XCTAssertEqual(scope.active, 1)
            worker.release.signal()
            try await boundary { scope.active == 0 }
            XCTAssertEqual(worker.calls, 1)
            XCTAssertEqual(worker.unprotectedReads, 0)
            XCTAssertEqual(worker.failedReads, 0)
            XCTAssertEqual(scope.starts.sorted(), scope.stops.sorted())
        }
    }

    func testQueuedRenewedRequestOwnsAccessAndOldExitCannotConsumeIt() async throws {
        for kind in [ReadyAccessHarness.Kind.full, .source] {
            let fixture = try fixture(raw: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let scope = ReadyScopeProbe()
            let original = SecurityScopedFolderAccess(url: fixture.root.appendingPathComponent("old/../"), resourceAccess: scope.access)
            let worker = ReadyAccessWorker(scope: scope)
            defer { worker.release.signal() }
            let harness = ReadyAccessHarness(kind: kind, root: fixture.root, worker: worker)
            let obsolete = Task { await harness.load(fixture.photo, access: original.makeReadAuthority()) }
            defer { obsolete.cancel() }
            try await boundary { worker.calls == 1 }
            obsolete.cancel()
            _ = await obsolete.value
            original.stop()
            let replacement = SecurityScopedFolderAccess(url: fixture.root.appendingPathComponent("new/../"), resourceAccess: scope.access)
            let renewed = Task { await harness.load(fixture.photo, access: replacement.makeReadAuthority()) }
            defer { renewed.cancel() }
            try await boundary { harness.waiters(fixture.photo) == 1 && scope.active == 3 }
            replacement.stop()
            XCTAssertEqual(scope.active, 2, "queued and executing operations each retain their own exact grant")
            let premature = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: worker.secondEntered.wait(timeout: .now() + 0.05))
                }
            }
            XCTAssertEqual(premature, .timedOut, "cancellation must not free the occupied lane")
            worker.release.signal()
            let result = await renewed.value
            XCTAssertEqual(result, 2, "obsolete completion cannot satisfy the renewed request")
            try await boundary { scope.active == 0 }
            XCTAssertEqual(worker.maximumActive, 1)
            XCTAssertEqual(worker.unprotectedReads, 0)
            XCTAssertEqual(worker.failedReads, 0)
            XCTAssertEqual(scope.starts.sorted(), scope.stops.sorted())
        }
    }

    func testLazyTileKeepsScopeAndIdentityWhenCancelledAndRenewed() async throws {
        let fixture = try fixture(raw: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scope = ReadyScopeProbe()
        let owner = SecurityScopedFolderAccess(url: fixture.root.appendingPathComponent("tile-grant/../"), resourceAccess: scope.access)
        let worker = ReadyAccessWorker(scope: scope)
        defer { worker.release.signal() }
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 1, tileRenderer: { source, coordinate in
            let call = worker.read(tryURL: source.sourceRevision!.url)
            return readyPixels(width: call).map {
                ZoomImageTile(coordinate: coordinate, pixelRect: CGRect(x: 0, y: 0, width: CGFloat(call), height: 1), image: $0)
            }
        }, source: { revision, key, decoder in
            ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 1)),
                            pixelSize: CGSize(width: 2, height: 1), sourceRevision: revision, decoder: decoder)
        })
        let loadedSource = await pipeline.source(for: fixture.photo, sourceAccess: owner.makeReadAuthority())
        let source = try XCTUnwrap(loadedSource)
        try await boundary { scope.active == 1 }
        XCTAssertEqual(source.sourceAccess?.authorizedURL.absoluteString, owner.makeReadAuthority().authorizedURL.absoluteString)
        let coordinate = ZoomTileCoordinate(column: 0, row: 0)
        let obsolete = Task { await pipeline.tile(for: source, coordinate: coordinate) }
        try await boundary { worker.calls == 1 }
        pipeline.cancelTileRequests(exceptSourceKey: nil)
        let cancelledTile = await obsolete.value
        XCTAssertNil(cancelledTile)
        let renewed = Task { await pipeline.tile(for: source, coordinate: coordinate) }
        try await boundary { scope.active == 3 }
        owner.stop()
        XCTAssertEqual(scope.active, 2)
        worker.release.signal()
        let tile = await renewed.value
        XCTAssertEqual(tile?.image.width, 2, "old tile completion must not retire the renewed tile")
        try await boundary { scope.active == 0 }
        XCTAssertEqual(worker.maximumActive, 1)
        XCTAssertEqual(worker.unprotectedReads, 0)
        XCTAssertEqual(worker.failedReads, 0)
        XCTAssertEqual(scope.starts.sorted(), scope.stops.sorted())
    }

    func testCachePruningYieldsBetweenBoundedBatchesAndCannotBeStarved() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-prune-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<130 {
            let url = root.appendingPathComponent("\(index).jpg")
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: url.path)
        }
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .milliseconds(40))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let batches = ReadyBatchProbe()
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: coordinator)
        let prune = Task {
            await pipeline.pruneDiskCacheForTesting { count in
                batches.record(count)
                coordinator.noteInteraction()
            }
        }
        try await boundary { coordinator.waitingCountForTesting == 1 }
        XCTAssertEqual(batches.counts.count, 0)
        let pruned = await prune.value // Held foreground demand exercises each fixed deadline.
        XCTAssertTrue(pruned)
        XCTAssertGreaterThanOrEqual(batches.counts.count, 3)
        XCTAssertTrue(batches.counts.allSatisfy { $0 <= 64 })
        XCTAssertEqual(batches.counts.reduce(0, +), 130)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func fixture(raw: Bool) throws -> (root: URL, photo: PhotoItem) {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-ready-access-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(raw ? "photo.RAF" : "photo.JPG")
        try Data("disposable source".utf8).write(to: url)
        return (root, PhotoItem(primaryFile: PhotoFile(id: url.lastPathComponent, url: url, captureDate: nil,
            cameraModel: nil, lensModel: nil, fileSize: 17, scannedIdentity: try FileOperationJournal.captureIdentity(at: url))))
    }

    private func boundary(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        guard condition() else { XCTFail("worker/access boundary timed out"); throw ReadyAccessError.timeout }
    }
}

private enum ReadyAccessError: Error { case timeout }

private final class ReadyAccessHarness: @unchecked Sendable {
    enum Kind: CaseIterable { case thumbnail, full, source, rendered, raw }
    let kind: Kind
    let image: ImagePipeline
    let high: HighResolutionImagePipeline
    let histogram: HistogramPipeline
    let raw: RawHistogramPipeline

    init(kind: Kind, root: URL, worker: ReadyAccessWorker, coordinator: ForegroundWorkCoordinator = ForegroundWorkCoordinator()) {
        self.kind = kind
        image = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache"), thumbnailConcurrency: 1,
                              fullConcurrency: 1, foregroundWork: coordinator) { url, _ in
            readyPixels(width: worker.read(tryURL: url))
        }
        high = HighResolutionImagePipeline(testingSourceConcurrency: 1) { revision, key, decoder in
            let call = worker.read(tryURL: revision.url)
            return ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(call), height: 1)),
                                   pixelSize: CGSize(width: CGFloat(call), height: 1), sourceRevision: revision, decoder: decoder)
        }
        let analyze: @Sendable (URL) -> HistogramAnalysis? = { url in
            let call = worker.read(tryURL: url)
            return HistogramAnalysis(bins: [1], sampleCount: 1, shadowCount: 0, highlightCount: 0, width: call, height: 1)
        }
        histogram = HistogramPipeline(decoder: analyze, foregroundWork: coordinator)
        raw = RawHistogramPipeline(delayNanoseconds: 0, foregroundWork: coordinator, decoder: analyze)
    }

    func load(_ photo: PhotoItem, access: MediaReadAccess?) async -> Int? {
        switch kind {
        case .thumbnail: return await image.thumbnail(for: photo, sourceAccess: access).map { Int($0.size.width) }
        case .full: return await image.fullImage(for: photo, sourceAccess: access).map { Int($0.size.width) }
        case .source: return await high.source(for: photo, sourceAccess: access).map { Int($0.pixelSize.width) }
        case .rendered: return await histogram.analysis(for: photo, sourceAccess: access)?.width
        case .raw: return await raw.analysis(for: photo, sourceAccess: access)?.width
        }
    }

    func background(_ photo: PhotoItem) -> Task<Void, Never> {
        switch kind {
        case .full: return image.prefetchFullImages(items: [photo])
        case .rendered: return Task { _ = await histogram.analysis(for: photo, purpose: .backgroundQuality) }
        case .raw: return Task { _ = await raw.analysis(for: photo, purpose: .backgroundQuality) }
        default: preconditionFailure("unsupported background harness")
        }
    }

    func waiters(_ photo: PhotoItem) -> Int {
        switch kind {
        case .source: return high.sourceWaiterCountForTesting(for: photo)
        case .rendered: return histogram.waiterCountForTesting(for: photo)
        case .raw: return raw.waiterCountForTesting(for: photo)
        default: return image.decodeWaiterCountForTesting(for: photo, full: kind == .full)
        }
    }
}

private final class ReadyScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var stopped: [String] = []
    private var recordedEvents: [String] = []
    var events: [String] { lock.withLock { recordedEvents } }
    func event(_ value: String) { lock.withLock { recordedEvents.append(value) } }
    var starts: [String] { lock.withLock { started } }
    var stops: [String] { lock.withLock { stopped } }
    var active: Int { lock.withLock { started.count - stopped.count } }
    var access: SecurityScopedResourceAccess {
        .init(start: { url in self.lock.withLock { self.started.append(url.absoluteString); self.recordedEvents.append("start " + url.absoluteString) }; return true },
              stop: { url in self.lock.withLock { self.stopped.append(url.absoluteString); self.recordedEvents.append("stop " + url.absoluteString) } })
    }
}

private final class ReadyAccessWorker: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    private let scope: ReadyScopeProbe
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var maximum = 0
    private var unprotected = 0
    private var failed = 0
    var calls: Int { lock.withLock { count } }
    var maximumActive: Int { lock.withLock { maximum } }
    var unprotectedReads: Int { lock.withLock { unprotected } }
    var failedReads: Int { lock.withLock { failed } }
    init(scope: ReadyScopeProbe) { self.scope = scope }
    func read(tryURL url: URL) -> Int {
        let call = lock.withLock { count += 1; active += 1; maximum = max(maximum, active); return count }
        if call == 1 { _ = release.wait(timeout: .now() + 10) }
        else { secondEntered.signal() }
        if scope.active <= 0 { lock.withLock { unprotected += 1 } }
        if (try? Data(contentsOf: url)) != Data("disposable source".utf8) { lock.withLock { failed += 1 } }
        lock.withLock { active -= 1 }
        scope.event("read-exit-\(call)")
        return call
    }
}

private final class ReadyBatchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var counts: [Int] { lock.withLock { values } }
    func record(_ value: Int) { lock.withLock { values.append(value) } }
}

private func readyPixels(width: Int) -> CGImage? {
    CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
}
#endif
