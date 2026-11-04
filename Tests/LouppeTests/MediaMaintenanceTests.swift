import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Louppe

/// AUD-09 live disk-thumbnail enforcement and AUD-10 bounded Info EXIF reads.
/// Disposable roots, injected small limits and gated readers only.
final class MediaMaintenanceTests: XCTestCase {
    // MARK: - AUD-09

    func testSustainedWritesStayNearInjectedLimitAndSurvivorsStayReadable() async throws {
        let limit: Int64 = 600 * 1024, interval: Int64 = 150 * 1024
        let live = try await sustainedWrites(count: 90, limit: limit, interval: interval)
        defer { try? FileManager.default.removeItem(at: live.root) }
        let control = try await sustainedWrites(count: 90, limit: limit, interval: nil)
        defer { try? FileManager.default.removeItem(at: control.root) }

        print("DISK_LIVE limit=\(limit) interval=\(interval) peak=\(live.peakBytes) final=\(live.finalBytes) "
              + "passes=\(live.passes) largest=\(live.largestFile) control-final=\(control.finalBytes)")
        XCTAssertGreaterThan(control.finalBytes, 2 * limit, "without live passes, writes grow past the ceiling")
        XCTAssertGreaterThanOrEqual(live.passes, 2)
        XCTAssertLessThanOrEqual(live.finalBytes, limit)
        // One interval before the first pass, plus at most one file per write that
        // completed while a pass was suspended between admitted batches.
        XCTAssertLessThanOrEqual(live.peakBytes, limit + interval + 2 * live.largestFile,
                                 "peak \(live.peakBytes) largest \(live.largestFile)")
        for url in try jpegFiles(in: live.cache) {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "survivor must decode: \(url.lastPathComponent)")
        }
        // Survivors serve disk hits after memory eviction; evicted ones regenerate.
        let decoder = DecodeCounter()
        let pipeline = ImagePipeline(testingDiskCacheRoot: live.cache, foregroundWork: Self.idle,
                                     decoder: { _, _ in decoder.record(); return Self.noise(seed: 999) })
        for item in live.items.suffix(5) { let image = await pipeline.thumbnail(for: item); XCTAssertNotNil(image) }
        XCTAssertEqual(decoder.count, 0, "newest entries survive eviction")
    }

    func testUnknownTotalWaitsForOneIntervalThenKnownTotalPreventsRepeatedWalks() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit: Int64 = 10 * 1024 * 1024, interval: Int64 = 120 * 1024
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: Self.idle,
                                     diskCacheByteLimit: limit, liveMaintenanceWriteInterval: interval,
                                     decoder: { url, _ in Self.noise(seed: url.lastPathComponent.hashValue) })
        var written: Int64 = 0
        var index = 0
        while written < interval / 2 {
            _ = await pipeline.thumbnail(for: Self.item("A\(index).JPG")); index += 1
            await pipeline.waitForPendingDiskWrites()
            written = try Self.bytes(in: root)
        }
        XCTAssertEqual(pipeline.diskMaintenanceForTesting.passes, 0, "a same-day launch waits for one interval")
        while pipeline.diskMaintenanceForTesting.passes == 0 {
            _ = await pipeline.thumbnail(for: Self.item("A\(index).JPG")); index += 1
            await pipeline.waitForPendingDiskWrites()
            try await settle(pipeline)
            XCTAssertLessThan(index, 400)
        }
        let known = try XCTUnwrap(pipeline.diskMaintenanceForTesting.knownBytes)
        XCTAssertEqual(known, try Self.bytes(in: root))
        // Well below the 10 MiB ceiling: more than another interval of writes
        // must not start a second directory walk.
        for extra in 0..<20 {
            _ = await pipeline.thumbnail(for: Self.item("B\(extra).JPG"))
            await pipeline.waitForPendingDiskWrites()
        }
        try await settle(pipeline)
        XCTAssertEqual(pipeline.diskMaintenanceForTesting.passes, 1)
    }

    func testLaunchPassAndLiveTriggersNeverOverlap() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Interaction pulses make each admitted batch wait, widening overlap windows.
        let coordinator = ForegroundWorkCoordinator(quietInterval: .milliseconds(3), maximumDeferral: .milliseconds(6))
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: coordinator,
                                     diskCacheByteLimit: 96 * 1024, liveMaintenanceWriteInterval: 24 * 1024,
                                     decoder: { url, _ in Self.noise(seed: url.lastPathComponent.hashValue) })
        for index in 0..<60 {
            if index.isMultiple(of: 3) { pipeline.startDiskMaintenanceForTesting() } // launch-pass path
            coordinator.noteInteraction()
            _ = await pipeline.thumbnail(for: Self.item("W\(index).JPG"))
        }
        await pipeline.waitForPendingDiskWrites()
        try await settle(pipeline)
        let state = pipeline.diskMaintenanceForTesting
        XCTAssertGreaterThanOrEqual(pipeline.diskMaintenanceStartsForTesting, 2)
        XCTAssertEqual(state.passes, pipeline.diskMaintenanceStartsForTesting, "every started pass finished")
        XCTAssertEqual(pipeline.diskMaintenancePeakConcurrencyForTesting, 1)
        XCTAssertLessThanOrEqual(try Self.bytes(in: root), 96 * 1024)
    }

    func testProductionTargetsAndTestHostIsolation() async throws {
        XCTAssertEqual(ImagePipeline.diskCacheByteLimit, 512 * 1024 * 1024)
        XCTAssertEqual(ImagePipeline.evictionTarget(limit: ImagePipeline.diskCacheByteLimit, interval: nil),
                       448 * 1024 * 1024)
        XCTAssertEqual(ImagePipeline.evictionTarget(limit: 100, interval: 80), 50)
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Without an injected interval, test instances never prune live.
        let isolated = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: Self.idle, diskCacheByteLimit: 1,
                                     decoder: { url, _ in Self.noise(seed: url.lastPathComponent.hashValue) })
        for index in 0..<3 {
            _ = await isolated.thumbnail(for: Self.item("I\(index).JPG"))
            await isolated.waitForPendingDiskWrites()
        }
        XCTAssertEqual(isolated.diskMaintenanceStartsForTesting, 0)
        XCTAssertEqual(try jpegFiles(in: root).count, 3)
    }

    // MARK: - Failed deletions

    func testBackoffDoublesPerFailureUpToEightIntervals() {
        let interval = ImagePipeline.liveMaintenanceWriteInterval
        XCTAssertEqual(interval, 64 * 1024 * 1024)
        let factors = (0...6).map { ImagePipeline.maintenanceBackoffBytes(interval: interval, consecutiveFailures: $0) / interval }
        XCTAssertEqual(factors, [0, 1, 2, 4, 8, 8, 8])
        XCTAssertEqual(ImagePipeline.maintenanceBackoffBytes(interval: .max / 2, consecutiveFailures: 4), .max)
    }

    func testFailedAgeDeletionStaysCountedAndMarksPassFailed() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try Self.seed(root, count: 2, bytes: 20 * 1024)
        let aged = try Self.seed(root, count: 1, bytes: 20 * 1024, prefix: "aged")[0]
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 24 * 60 * 60)],
                                              ofItemAtPath: aged.path)
        let remover = FaultyRemover()
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: Self.idle,
                                     diskCacheByteLimit: 400 * 1024, liveMaintenanceWriteInterval: 100 * 1024,
                                     diskCacheRemover: { try remover.remove($0) })
        let directPass = await pipeline.pruneDiskCacheForTesting()
        XCTAssertFalse(directPass, "a failed deletion fails the pass")

        pipeline.startDiskMaintenanceForTesting()
        try await settle(pipeline)
        var state = pipeline.diskMaintenanceForTesting
        XCTAssertEqual(state.passes, 1)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertEqual(state.knownBytes, 60 * 1024, "the undeleted aged file stays counted")
        XCTAssertEqual(state.knownBytes, try Self.bytes(in: root))
        XCTAssertEqual(remover.attempts, 2, "one attempt per pass, below the ceiling")

        remover.setFailing(false)
        pipeline.startDiskMaintenanceForTesting()
        try await settle(pipeline)
        state = pipeline.diskMaintenanceForTesting
        XCTAssertEqual(state.passes, 2)
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(state.knownBytes, 40 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aged.path))
        XCTAssertEqual(Set(try jpegFiles(in: root).map(\.lastPathComponent)), Set(fresh.map(\.lastPathComponent)))
    }

    func testFailedEvictionsKeepAccountingBackOffAndRecover() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit: Int64 = 400 * 1024, interval: Int64 = 100 * 1024
        _ = try Self.seed(root, count: 10, bytes: 50 * 1024)
        let remover = FaultyRemover()
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: Self.idle,
                                     diskCacheByteLimit: limit, liveMaintenanceWriteInterval: interval,
                                     decoder: { url, _ in Self.noise(seed: url.lastPathComponent.hashValue) },
                                     diskCacheRemover: { try remover.remove($0) })
        pipeline.startDiskMaintenanceForTesting()
        try await settle(pipeline)
        var state = pipeline.diskMaintenanceForTesting
        XCTAssertEqual(state.consecutiveFailures, 1, "evictions that fail mark the pass failed")
        XCTAssertEqual(state.knownBytes, 500 * 1024, "undeleted files stay in the known total")
        XCTAssertEqual(state.knownBytes, try Self.bytes(in: root))
        XCTAssertEqual(remover.attempts, 10)
        XCTAssertEqual(try jpegFiles(in: root).count, 10)

        // The known total is over the ceiling, so without backoff the first
        // write would rerun the pass. Each failure doubles the wait.
        var index = 0
        for (pass, factor) in [(2, Int64(1)), (3, 2)] {
            let run = try await writeUntilPassStarts(pipeline, remover: remover, pass: pass, index: &index)
            XCTAssertGreaterThan(run.writes, 1)
            XCTAssertLessThan(run.before, factor * interval, "pass \(pass) started before its backoff")
            XCTAssertGreaterThanOrEqual(run.after, factor * interval)
            try await settle(pipeline)
            state = pipeline.diskMaintenanceForTesting
            XCTAssertEqual(state.passes, pass)
            XCTAssertEqual(state.consecutiveFailures, pass)
            XCTAssertEqual(state.knownBytes, try Self.bytes(in: root))
        }

        remover.setFailing(false)
        let recovery = try await writeUntilPassStarts(pipeline, remover: remover, pass: 4, index: &index)
        XCTAssertLessThan(recovery.before, 4 * interval)
        XCTAssertGreaterThanOrEqual(recovery.after, 4 * interval)
        try await settle(pipeline)
        state = pipeline.diskMaintenanceForTesting
        XCTAssertEqual(state.passes, 4)
        XCTAssertEqual(state.consecutiveFailures, 0, "a successful pass resets the backoff")
        let known = try XCTUnwrap(state.knownBytes)
        XCTAssertEqual(known, try Self.bytes(in: root))
        XCTAssertLessThanOrEqual(known, ImagePipeline.evictionTarget(limit: limit, interval: interval))

        // Normal policy again: the next pass waits only for the ceiling.
        let normal = try await writeUntilPassStarts(pipeline, remover: remover, pass: 5, index: &index)
        XCTAssertLessThanOrEqual(known + normal.before, limit)
        XCTAssertGreaterThan(known + normal.after, limit)
        try await settle(pipeline)
        XCTAssertEqual(pipeline.diskMaintenanceForTesting.consecutiveFailures, 0)
        XCTAssertLessThanOrEqual(try Self.bytes(in: root), limit)
        XCTAssertEqual(pipeline.diskMaintenancePeakConcurrencyForTesting, 1)
    }

    func testFailingPassesNeverOverlap() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = FaultyRemover(failsEveryOther: true)
        let coordinator = ForegroundWorkCoordinator(quietInterval: .milliseconds(3), maximumDeferral: .milliseconds(6))
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, foregroundWork: coordinator,
                                     diskCacheByteLimit: 96 * 1024, liveMaintenanceWriteInterval: 24 * 1024,
                                     decoder: { url, _ in Self.noise(seed: url.lastPathComponent.hashValue) },
                                     diskCacheRemover: { try remover.remove($0) })
        for index in 0..<60 {
            if index.isMultiple(of: 3) { pipeline.startDiskMaintenanceForTesting() }
            coordinator.noteInteraction()
            _ = await pipeline.thumbnail(for: Self.item("F\(index).JPG"))
        }
        await pipeline.waitForPendingDiskWrites()
        try await settle(pipeline)
        let state = pipeline.diskMaintenanceForTesting
        XCTAssertGreaterThan(remover.attempts, 1)
        XCTAssertGreaterThanOrEqual(state.consecutiveFailures, 0)
        XCTAssertEqual(state.passes, pipeline.diskMaintenanceStartsForTesting, "every started pass finished")
        XCTAssertEqual(pipeline.diskMaintenancePeakConcurrencyForTesting, 1)
        if let known = state.knownBytes { XCTAssertLessThanOrEqual(known, try Self.bytes(in: root)) }
    }

    /// Writes one thumbnail at a time until pass `pass` claims. Returns bytes
    /// written since the previous pass before and after the claiming write.
    /// Counting removed bytes keeps the measure exact while that pass deletes.
    private func writeUntilPassStarts(_ pipeline: ImagePipeline, remover: FaultyRemover, pass: Int,
                                      index: inout Int) async throws -> (before: Int64, after: Int64, writes: Int) {
        let root = pipeline.diskCacheRootForTesting
        let baseline = try remover.bytesIncludingRemoved(in: root)
        var before: Int64 = 0, writes = 0
        while writes < 300 {
            _ = await pipeline.thumbnail(for: Self.item("P\(index).JPG")); index += 1; writes += 1
            await pipeline.waitForPendingDiskWrites()
            let after = try remover.bytesIncludingRemoved(in: root) - baseline
            // A live pass claims synchronously when the write completes.
            if pipeline.diskMaintenanceStartsForTesting >= pass { return (before, after, writes) }
            before = after
        }
        XCTFail("pass \(pass) never started")
        return (before, before, writes)
    }

    static func seed(_ root: URL, count: Int, bytes: Int, prefix: String = "seed") throws -> [URL] {
        try (0..<count).map { index in
            let url = root.appendingPathComponent("\(prefix)\(index).jpg")
            try Data(repeating: 0xAB, count: bytes).write(to: url)
            return url
        }
    }

    // MARK: - AUD-10

    func testQueuedEXIFReadsRetireUnstartedAndAbandonedReadsStayBounded() async throws {
        let gate = GatedReader()
        defer { gate.open() }
        let pipeline = MetadataDetailPipeline(concurrency: 2) { gate.read($0) }
        var tasks: [Task<[MetadataField]?, Never>] = []
        for index in 0..<10 {
            let item = Self.item("E\(index).JPG")
            tasks.forEach { $0.cancel() }
            tasks.append(Task { await pipeline.fields(for: item, sourceAccess: nil) })
            try await Task.sleep(for: .milliseconds(5))
        }
        try await eventually { gate.started == 2 }
        for task in tasks.dropLast() { let value = await task.value; XCTAssertNil(value) }
        XCTAssertEqual(gate.started, 2, "cancelled queued reads must not start while lanes are busy")
        XCTAssertEqual(pipeline.pendingCountForTesting, 1)
        gate.open()
        let final = await tasks[tasks.count - 1].value
        XCTAssertEqual(final?.first?.value, "E9.JPG")
        await pipeline.waitForIdleForTesting()
        XCTAssertLessThanOrEqual(gate.started, 3)
        XCTAssertEqual(gate.maxConcurrent, 2)
        XCTAssertEqual(pipeline.pendingCountForTesting, 0)
    }

    func testEXIFWorkerOwnsSourceAccessUntilReadExit() async throws {
        let gate = GatedReader()
        defer { gate.open() }
        let scope = ScopeCounter()
        let access = MediaReadAccess(authorizedURL: URL(fileURLWithPath: "/private/tmp/louppe-exif-grant/"),
                                     resourceAccess: scope.access)
        let pipeline = MetadataDetailPipeline(concurrency: 1) { item in
            let fields = gate.read(item)
            scope.note(active: scope.active)
            return fields
        }
        let request = Task { await pipeline.fields(for: Self.item("grant.JPG"), sourceAccess: access) }
        try await eventually { gate.started == 1 }
        XCTAssertEqual(scope.active, 1)
        request.cancel()
        let value = await request.value
        XCTAssertNil(value, "navigation retires the waiter before the read exits")
        XCTAssertEqual(scope.active, 1, "the executing reader retains its own lease")
        gate.open()
        await pipeline.waitForIdleForTesting()
        try await eventually { scope.active == 0 }
        XCTAssertEqual(scope.activeDuringRead, [1])
        // A request cancelled before admission never starts a scope.
        let cancelled = Task { await pipeline.fields(for: Self.item("never.JPG"), sourceAccess: access) }
        cancelled.cancel()
        _ = await cancelled.value
        await pipeline.waitForIdleForTesting()
        XCTAssertEqual(scope.active, 0)
        XCTAssertEqual(gate.started, 1)
    }

    // MARK: - Helpers

    private struct WriteRun {
        let root: URL; let cache: URL; let items: [PhotoItem]
        let peakBytes: Int64; let finalBytes: Int64; let largestFile: Int64; let passes: Int
    }

    private func sustainedWrites(count: Int, limit: Int64, interval: Int64?) async throws -> WriteRun {
        let root = try Self.temporaryRoot()
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let pipeline = ImagePipeline(testingDiskCacheRoot: cache, foregroundWork: Self.idle,
                                     diskCacheByteLimit: limit, liveMaintenanceWriteInterval: interval,
                                     decoder: { url, _ in Self.noise(seed: url.lastPathComponent.hashValue) })
        var peak: Int64 = 0, largest: Int64 = 0
        var items: [PhotoItem] = []
        for index in 0..<count {
            let item = Self.item(String(format: "S%03d.JPG", index))
            items.append(item)
            _ = await pipeline.thumbnail(for: item)
            await pipeline.waitForPendingDiskWrites()
            let files = try jpegFiles(in: cache)
            // A concurrent pass may evict between listing and stat.
            let sizes = files.compactMap { url in
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            }
            peak = max(peak, sizes.reduce(0, +))
            largest = max(largest, sizes.max() ?? 0)
        }
        try await settle(pipeline)
        return WriteRun(root: root, cache: cache, items: items, peakBytes: peak,
                        finalBytes: try Self.bytes(in: cache), largestFile: largest,
                        passes: pipeline.diskMaintenanceForTesting.passes)
    }

    private func settle(_ pipeline: ImagePipeline) async throws {
        try await eventually { !pipeline.diskMaintenanceForTesting.running }
    }

    private func eventually(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("condition timed out"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func jpegFiles(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }
    }

    static let idle = ForegroundWorkCoordinator(quietInterval: .zero, maximumDeferral: .milliseconds(1))

    static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-media-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func bytes(in root: URL) throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "jpg" }
            .reduce(0) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    static func item(_ name: String) -> PhotoItem {
        PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/private/tmp/louppe-media-maintenance-synthetic/\(name)"),
                  pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
    }

    /// High-frequency pixels make realistic 10–40 KiB thumbnail JPEGs.
    static func noise(seed: Int) -> CGImage? {
        let width = 320, height = 213
        var state = UInt64(bitPattern: Int64(seed)) | 1
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
            pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 32)
            pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 40)
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private final class GatedReader: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var isOpen = false
    private var active = 0
    private var starts = 0
    private var peak = 0
    var started: Int { lock.withLock { starts } }
    var maxConcurrent: Int { lock.withLock { peak } }

    func open() {
        let shouldSignal = lock.withLock { () -> Bool in
            defer { isOpen = true }
            return !isOpen
        }
        if shouldSignal { for _ in 0..<16 { gate.signal() } }
    }

    func read(_ item: PhotoItem) -> [MetadataField] {
        let wait = lock.withLock { () -> Bool in
            starts += 1; active += 1; peak = max(peak, active)
            return !isOpen
        }
        if wait { gate.wait() }
        lock.withLock { active -= 1 }
        return [MetadataField(id: "Filename", label: "Filename", value: item.displayName)]
    }
}

private final class ScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var during: [Int] = []
    var active: Int { lock.withLock { count } }
    var activeDuringRead: [Int] { lock.withLock { during } }
    func note(active: Int) { lock.withLock { during.append(active) } }
    var access: SecurityScopedResourceAccess {
        .init(start: { _ in self.lock.withLock { self.count += 1 }; return true },
              stop: { _ in self.lock.withLock { self.count -= 1 } })
    }
}

/// Disk-cache deletion fault injection. Removal and its byte count share the
/// lock, so `bytesIncludingRemoved` is exact even while a pass deletes.
private final class FaultyRemover: @unchecked Sendable {
    private let lock = NSLock()
    private let failsEveryOther: Bool
    private var failing: Bool
    private var attemptCount = 0
    private var removedBytes: Int64 = 0
    var attempts: Int { lock.withLock { attemptCount } }

    init(failsEveryOther: Bool = false) {
        self.failsEveryOther = failsEveryOther
        failing = !failsEveryOther
    }

    func setFailing(_ value: Bool) { lock.withLock { failing = value } }

    func remove(_ url: URL) throws {
        try lock.withLock {
            attemptCount += 1
            if failing || (failsEveryOther && attemptCount.isMultiple(of: 2)) {
                throw CocoaError(.fileWriteNoPermission)
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try FileManager.default.removeItem(at: url)
            removedBytes += Int64(size)
        }
    }

    func bytesIncludingRemoved(in root: URL) throws -> Int64 {
        try lock.withLock { try MediaMaintenanceTests.bytes(in: root) + removedBytes }
    }
}
