import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// AUD-09/10/11/29 measurements. Opt-in through Tests/run_speed_tests.sh.
/// Disk and EXIF rows use disposable fixtures; RAW rows need
/// LOUPPE_SPEED_RAW_FOLDER, whose files are cloned/copied before decoding.
final class LouppeSpeedMediaResponsivenessTests: XCTestCase {
    // MARK: - AUD-10 Info EXIF readers

    /// Navigation at key-repeat cadence over slow EXIF reads. "mirrored-detached"
    /// reproduces the former view pattern: dwell, then an unstructured detached
    /// read whose cancellation only suppresses publication.
    @MainActor
    func testAbandonedEXIFReadersDuringRapidNavigation() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "media-exif-navigation")
        let items = (0..<40).map { syntheticItem("EXIF_\($0).JPG") }
        for model in [ReadModel.parallel, .serialDevice] {
            for interval in [90, 120] {
                var rows: [String: [Double]] = [:]
                var summaries: [String: [ExifNavigationResult]] = [:]
                for repetition in 0..<(SpeedBenchmark.repetitions + 1) {
                    for variant in ExifVariant.allCases.rotated(by: repetition) {
                        let result = await navigate(items: items, intervalMS: interval,
                                                    readMS: 300, model: model, variant: variant)
                        guard repetition > 0 else { continue }
                        rows[variant.rawValue, default: []].append(result.finalLatencyMS)
                        summaries[variant.rawValue, default: []].append(result)
                    }
                }
                for variant in ExifVariant.allCases {
                    let name = "exif.\(model.rawValue).nav-\(interval)ms.read-300ms.\(variant.rawValue)"
                    try report.recordSamples(name: name + ".final-fields", count: items.count,
                                             samplesMS: rows[variant.rawValue] ?? [])
                    let results = summaries[variant.rawValue] ?? []
                    print("EXIF_COUNTS \(name) started=\(results.map(\.started)) "
                          + "maxConcurrent=\(results.map(\.maxConcurrent)) "
                          + "abandoned=\(results.map(\.abandoned)) stalePublications=\(results.map(\.stalePublications))")
                    XCTAssertTrue(results.allSatisfy { $0.stalePublications == 0 })
                    if variant != .mirroredDetached {
                        XCTAssertTrue(results.allSatisfy { $0.maxConcurrent <= variant.lanes })
                    }
                }
            }
        }
        try report.finish()
    }

    private enum ReadModel: String { case parallel, serialDevice = "serial-device" }

    private enum ExifVariant: String, CaseIterable {
        case mirroredDetached = "mirrored-detached"
        case boundedOneLane = "bounded-1-lane"
        case boundedTwoLanes = "bounded-2-lanes"
        var lanes: Int { self == .boundedOneLane ? 1 : 2 }
    }

    private struct ExifNavigationResult {
        let started: Int
        let maxConcurrent: Int
        let abandoned: Int
        let stalePublications: Int
        let finalLatencyMS: Double
    }

    @MainActor
    private func navigate(items: [PhotoItem], intervalMS: Int, readMS: Int,
                          model: ReadModel, variant: ExifVariant) async -> ExifNavigationResult {
        let probe = ExifReaderProbe(readMS: readMS, serialDevice: model == .serialDevice)
        let pipeline = MetadataDetailPipeline(concurrency: variant.lanes) { probe.read($0) }
        var current: PhotoItem?
        var task: Task<Void, Never>?
        var stale = 0
        var published: (PhotoContentRevision, ContinuousClock.Instant)?
        var lastNavigation = ContinuousClock.now
        for item in items {
            task?.cancel()
            current = item
            lastNavigation = .now
            let requested = item.contentRevision
            task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                let loaded: [MetadataField]?
                switch variant {
                case .mirroredDetached:
                    loaded = await Task.detached(priority: .userInitiated) { probe.read(item) }.value
                case .boundedOneLane, .boundedTwoLanes:
                    loaded = await pipeline.fields(for: item, sourceAccess: nil)
                }
                guard !Task.isCancelled, loaded != nil else { return }
                if current?.contentRevision != requested { stale += 1 }
                published = (requested, .now)
            }
            try? await Task.sleep(for: .milliseconds(intervalMS))
        }
        await task?.value
        let final = items[items.count - 1].contentRevision
        // Unstructured abandoned readers keep running after the final result.
        await probe.waitForIdle()
        let latency = published.map { $0.0 == final ? lastNavigation.duration(to: $0.1) : .seconds(-1) }
            ?? .seconds(-1)
        let parts = latency.components
        return ExifNavigationResult(
            started: probe.started, maxConcurrent: probe.maxConcurrent,
            abandoned: probe.started - 1, stalePublications: stale,
            finalLatencyMS: Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }

    // MARK: - AUD-09 disk thumbnails

    /// Prune-walk cost, per-batch disk-queue hold, and disk-hit thumbnail
    /// latency with no maintenance, flat-out maintenance and production admission.
    func testDiskThumbnailMaintenanceCostAndForegroundLatency() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = await SpeedReport(suite: "media-disk-maintenance")
        let root = URL(fileURLWithPath: "/private/tmp/louppe-speed-disk-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fillerCount = 20_000
        let filler = Data(repeating: 0x5a, count: 64)
        for index in 0..<fillerCount {
            try filler.write(to: cache.appendingPathComponent(String(format: "f%015x.jpg", index)))
        }
        let sources = try (0..<200).map { index -> PhotoItem in
            let url = root.appendingPathComponent("SRC_\(index).JPG")
            try Self.jpegData(width: 1_600, height: 1_067, seed: index).write(to: url)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil,
                             cameraModel: nil, lensModel: nil,
                             primaryModificationDate: values.contentModificationDate,
                             fileSize: Int64(values.fileSize ?? 0))
        }
        let idle = ForegroundWorkCoordinator(quietInterval: .zero, maximumDeferral: .milliseconds(1))
        let warm = ImagePipeline(testingDiskCacheRoot: cache, foregroundWork: idle)
        for item in sources { _ = await warm.thumbnail(for: item) }
        await warm.waitForPendingDiskWrites()
        let thumbnailBytes = sources.compactMap { item -> Int? in
            let url = cache.appendingPathComponent(ImagePipeline.diskFileName(for: ImagePipeline.cacheKey(for: item)))
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        XCTAssertEqual(thumbnailBytes.count, sources.count)
        print("DISK_THUMBNAIL_BYTES synthetic-jpeg median=\(thumbnailBytes.sorted()[thumbnailBytes.count / 2]) "
              + "mean=\(thumbnailBytes.reduce(0, +) / max(1, thumbnailBytes.count))")

        var walk: [Double] = []
        var batches = 0
        for _ in 0..<(SpeedBenchmark.repetitions + 1) {
            let counter = BatchCounter()
            let pipeline = ImagePipeline(testingDiskCacheRoot: cache, foregroundWork: idle)
            let start = ContinuousClock.now
            let succeeded = await pipeline.pruneDiskCacheForTesting { counter.record($0) }
            walk.append(SpeedBenchmark.milliseconds(start))
            XCTAssertTrue(succeeded)
            batches = counter.batches
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: cache.path).count
        XCTAssertEqual(entries, fillerCount + sources.count, "a pass below the byte limit must not evict")
        try await report.recordSamples(name: "disk.prune-walk.idle-admission", count: entries, samplesMS: Array(walk.dropFirst()))
        print("DISK_PRUNE_BATCHES \(batches) for \(entries) entries; mean batch hold "
              + String(format: "%.3f ms", (walk.dropFirst().sorted()[walk.count / 2]) / Double(max(1, batches))))

        // A: no maintenance. B: maintenance with immediate admission (worst case).
        // C: production admission timings with the same foreground demand.
        var latencies: [String: [Double]] = [:]
        for repetition in 0..<(SpeedBenchmark.repetitions + 1) {
            for variant in ["no-maintenance", "maintenance.immediate-admission", "maintenance.production-admission"]
                .rotated(by: repetition) {
                let coordinator = variant.hasSuffix("production-admission") ? ForegroundWorkCoordinator() : idle
                let pipeline = ImagePipeline(testingDiskCacheRoot: cache, foregroundWork: coordinator)
                let prune: Task<Bool, Never>? = variant == "no-maintenance" ? nil
                    : Task.detached { await pipeline.pruneDiskCacheForTesting() }
                if prune != nil { try await Task.sleep(for: .milliseconds(5)) }
                var samples: [Double] = []
                for item in sources.prefix(100) {
                    let start = ContinuousClock.now
                    let image = await pipeline.thumbnail(for: item)
                    samples.append(SpeedBenchmark.milliseconds(start))
                    XCTAssertNotNil(image)
                }
                prune?.cancel()
                _ = await prune?.value
                guard repetition > 0 else { continue }
                latencies[variant, default: []].append(samples.sorted()[samples.count / 2])
                latencies[variant + ".p95", default: []].append(samples.sorted()[Int(Double(samples.count) * 0.95) - 1])
            }
        }
        for (name, samples) in latencies.sorted(by: { $0.key < $1.key }) {
            try await report.recordSamples(name: "disk.thumbnail-hit.\(name)", count: 100, samplesMS: samples)
        }
        try await report.finish()
    }

    // MARK: - AUD-11/19 cold RAW Fit and 100%

    /// Each round assigns alternating files to variants, so first-touch decoder
    /// costs are compared across different captures rather than a warm repeat.
    func testColdRAWFitRecipeAndActualSizeTiles() async throws {
        try SpeedBenchmark.requireEnabled()
        let files = try Self.rawFixtureCopies()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let report = await SpeedReport(suite: "media-raw-fit-actual")
        let idleBefore = ProcessSample.capture()
        try await Task.sleep(for: .seconds(3))
        let idleBeforeEnd = ProcessSample.capture()

        var rows: [String: [Double]] = [:]
        for (round, mode) in [RawDisplayMode.fast, .raw, .fast, .raw].enumerated() {
            for (index, item) in files.items.enumerated() {
                let withRecipe = (index + round).isMultiple(of: 2)
                let images = ImagePipeline(testingDiskCacheRoot: files.root.appendingPathComponent("c-\(UUID())"))
                let zoom = Self.zoomPipeline()
                let start = ContinuousClock.now
                let recipe: Task<Double, Never>? = withRecipe ? Task.detached {
                    let recipeStart = ContinuousClock.now
                    _ = await zoom.source(for: item)
                    return SpeedBenchmark.milliseconds(recipeStart)
                } : nil
                let full = await images.fullImage(for: item, mode: mode)
                let fullMS = SpeedBenchmark.milliseconds(start)
                XCTAssertNotNil(full)
                let pass = round < 2 ? "first-touch" : "second-touch"
                let label = "raw.\(mode.rawValue).fit-full.\(pass).\(withRecipe ? "with-recipe" : "preview-only")"
                rows[label, default: []].append(fullMS)
                if let recipe { rows["raw.recipe.concurrent-with-\(mode.rawValue).\(pass)", default: []].append(await recipe.value) }
            }
        }

        // 100%: recipe, central tile, its 8-tile ring, then a one-tile pan.
        for item in files.items {
            let zoom = Self.zoomPipeline()
            var start = ContinuousClock.now
            let source = await zoom.source(for: item)
            rows["actual.recipe", default: []].append(SpeedBenchmark.milliseconds(start))
            let recipe = try XCTUnwrap(source)
            let columns = Int(ceil(recipe.pixelSize.width / 1_024)), rowsCount = Int(ceil(recipe.pixelSize.height / 1_024))
            let center = ZoomTileCoordinate(column: columns / 2, row: rowsCount / 2)
            start = .now
            let first = await zoom.tile(for: recipe, coordinate: center)
            rows["actual.first-center-tile", default: []].append(SpeedBenchmark.milliseconds(start))
            XCTAssertNotNil(first)
            start = .now
            await withTaskGroup(of: Void.self) { group in
                for dc in -1...1 { for dr in -1...1 where dc != 0 || dr != 0 {
                    group.addTask { _ = await zoom.tile(for: recipe, coordinate: ZoomTileCoordinate(column: center.column + dc, row: center.row + dr)) }
                } }
            }
            rows["actual.ring-8-tiles", default: []].append(SpeedBenchmark.milliseconds(start))
            start = .now
            await withTaskGroup(of: Void.self) { group in
                for dr in -1...1 {
                    group.addTask { _ = await zoom.tile(for: recipe, coordinate: ZoomTileCoordinate(column: center.column + 2, row: center.row + dr)) }
                }
            }
            rows["actual.warm-pan-3-new-tiles", default: []].append(SpeedBenchmark.milliseconds(start))
            XCTAssertLessThanOrEqual(zoom.cachedTileCost, HighResolutionImagePipeline.tileCacheCostLimit)
        }

        let footprintBefore = ProcessSample.capture().footprint
        let holder = Self.zoomPipeline()
        for item in files.items.prefix(4) { _ = await holder.source(for: item) }
        let footprintRecipes = ProcessSample.capture().footprint
        print(String(format: "RAW_RECIPE_FOOTPRINT four-recipes delta=%.1f MiB",
                     Double(Int64(footprintRecipes) - Int64(footprintBefore)) / 1_048_576))

        for (name, samples) in rows.sorted(by: { $0.key < $1.key }) {
            print("RAW_ROW \(name) n=\(samples.count) median=\(String(format: "%.1f", Self.median(samples))) "
                  + "min=\(String(format: "%.1f", samples.min() ?? 0)) max=\(String(format: "%.1f", samples.max() ?? 0))")
        }

        // AUD-29: idle after the RAW work drains, compared with idle before it.
        try await Task.sleep(for: .seconds(2))
        let idleAfter = ProcessSample.capture()
        try await Task.sleep(for: .seconds(3))
        let idleAfterEnd = ProcessSample.capture()
        print("IDLE_BEFORE " + idleBefore.delta(to: idleBeforeEnd))
        print("IDLE_AFTER_DRAIN " + idleAfter.delta(to: idleAfterEnd))
        try Self.assertCopiesIntact(files)
        try await report.finish()
    }

    // MARK: - AUD-21 movie scan bridge

    /// Movie header loads through the finite semaphore bridge on synchronous
    /// scanner-style workers (1 and 8 lanes, matching FolderScanner's ceiling).
    /// Per-file latency bounds scanner cancellation, which is checked per file.
    func testMovieScanBridgeThroughputOnBoundedWorkers() throws {
        try SpeedBenchmark.requireEnabled()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AccessibilityMedia/captioned-described.mov")
        let root = URL(fileURLWithPath: "/private/tmp/louppe-speed-movies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<96).map { index -> URL in
            let url = root.appendingPathComponent("CLIP_\(index).mov")
            try FileManager.default.copyItem(at: fixture, to: url)
            return url
        }
        let report = MainActor.assumeIsolated { SpeedReport(suite: "media-movie-scan") }
        for workers in [1, 8] {
            let perFile = LatencyBox()
            try MainActor.assumeIsolated {
                try report.measure(name: "movie.scan-info.\(workers)-workers", count: urls.count) {
                    let next = ManagedCounter()
                    DispatchQueue.concurrentPerform(iterations: workers) { _ in
                        while let index = next.claim(limit: urls.count) {
                            let start = ContinuousClock.now
                            let info = VideoMetadataExtractor.scanInfo(for: urls[index])
                            perFile.append(SpeedBenchmark.milliseconds(start))
                            precondition(info.extractionSucceeded && info.duration != nil)
                        }
                    }
                }
            }
            let sorted = perFile.values.sorted()
            print(String(format: "MOVIE_SCAN workers=%d per-file median=%.2fms p95=%.2fms max=%.2fms", workers,
                         sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0))
        }
        try MainActor.assumeIsolated { try report.finish() }
    }

    // MARK: - Helpers

    private static func zoomPipeline() -> HighResolutionImagePipeline {
        HighResolutionImagePipeline(testingSourceConcurrency: 2) { revision, key, decoder in
            guard let image = RawImageRendering.image(url: revision.url, decoder: decoder) else { return nil }
            return ZoomImageSource(key: key, image: image, pixelSize: image.extent.integral.size,
                                   sourceRevision: revision, decoder: decoder)
        }
    }

    struct RawFixture { let root: URL; let items: [PhotoItem]; let sizes: [URL: Int] }

    static func rawFixtureCopies() throws -> RawFixture {
        guard let folder = ProcessInfo.processInfo.environment["LOUPPE_SPEED_RAW_FOLDER"] else {
            throw XCTSkip("Set LOUPPE_SPEED_RAW_FOLDER to local RAWs; only disposable copies are decoded")
        }
        let sources = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { FolderScanner.rawExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sources.isEmpty else { throw XCTSkip("No RAW files in LOUPPE_SPEED_RAW_FOLDER") }
        let root = URL(fileURLWithPath: "/private/tmp/louppe-speed-rawset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sizes: [URL: Int] = [:]
        let items = try sources.enumerated().map { index, source -> PhotoItem in
            let url = root.appendingPathComponent(String(format: "RAW_%02d", index)).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: url)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            sizes[url] = values.fileSize ?? 0
            return PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil,
                             cameraModel: nil, lensModel: nil,
                             primaryModificationDate: values.contentModificationDate,
                             fileSize: Int64(values.fileSize ?? 0))
        }
        return RawFixture(root: root, items: items, sizes: sizes)
    }

    static func assertCopiesIntact(_ fixture: RawFixture) throws {
        for item in fixture.items {
            XCTAssertTrue(MediaSourceRevision(item).matchesCurrentFile())
            XCTAssertEqual(try item.primaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, fixture.sizes[item.primaryURL])
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }

    private func syntheticItem(_ name: String) -> PhotoItem {
        PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/private/tmp/louppe-exif-synthetic/\(name)"),
                  pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
    }

    static func jpegData(width: Int, height: Int, seed: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var state = UInt64(seed &+ 1) &* 6364136223846793005
        for _ in 0..<600 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat(state % UInt64(width)), y = CGFloat((state >> 20) % UInt64(height))
            context.setFillColor(red: CGFloat(state >> 40 & 0xff) / 255, green: CGFloat(state >> 48 & 0xff) / 255,
                                 blue: CGFloat(state >> 56) / 255, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: CGFloat(20 + state % 140), height: CGFloat(20 + (state >> 8) % 140)))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

extension Array {
    func rotated(by offset: Int) -> [Element] {
        guard !isEmpty else { return self }
        let shift = offset % count
        return Array(self[shift...] + self[..<shift])
    }
}

/// Simulated slow EXIF source. A serial device models one-request-at-a-time
/// removable media; the parallel model gives each read independent latency.
final class ExifReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let device = NSLock()
    private let readMS: Int
    private let serialDevice: Bool
    private var active = 0
    private(set) var started = 0
    private(set) var maxConcurrent = 0

    init(readMS: Int, serialDevice: Bool) {
        self.readMS = readMS
        self.serialDevice = serialDevice
    }

    func read(_ item: PhotoItem) -> [MetadataField] {
        lock.withLock {
            started += 1
            active += 1
            maxConcurrent = max(maxConcurrent, active)
        }
        if serialDevice { device.lock() }
        Thread.sleep(forTimeInterval: Double(readMS) / 1_000)
        if serialDevice { device.unlock() }
        lock.withLock { active -= 1 }
        return [MetadataField(id: "Filename", label: "Filename", value: item.displayName)]
    }

    func waitForIdle() async {
        while lock.withLock({ active }) > 0 { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

final class LatencyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    var values: [Double] { lock.withLock { samples } }
    func append(_ value: Double) { lock.withLock { samples.append(value) } }
}

final class ManagedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    func claim(limit: Int) -> Int? {
        lock.withLock {
            guard next < limit else { return nil }
            defer { next += 1 }
            return next
        }
    }
}

final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var batches: Int { lock.withLock { count } }
    func record(_ entries: Int) { lock.withLock { count += 1 } }
}

/// Process-wide CPU, wakeups and footprint. XCTest's own runloop contributes
/// to both samples; compare before/after rather than reading absolute idle.
struct ProcessSample {
    let cpuNanoseconds: UInt64
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
    let footprint: UInt64
    let threads: Int32
    let at: ContinuousClock.Instant

    static func capture() -> ProcessSample {
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
        var task = proc_taskinfo()
        _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        return ProcessSample(cpuNanoseconds: cpu, idleWakeups: info.ri_pkg_idle_wkups,
                             interruptWakeups: info.ri_interrupt_wkups, footprint: info.ri_phys_footprint,
                             threads: task.pti_threadnum, at: .now)
    }

    func delta(to end: ProcessSample) -> String {
        let seconds = Double(at.duration(to: end.at).components.seconds)
            + Double(at.duration(to: end.at).components.attoseconds) / 1e18
        let cpu = Double(end.cpuNanoseconds - cpuNanoseconds) / 1e9
        return String(format: "window=%.2fs cpu=%.1f%% idleWakeups/s=%.1f interruptWakeups/s=%.1f footprint=%.1fMiB threads=%d",
                      seconds, cpu / seconds * 100,
                      Double(end.idleWakeups - idleWakeups) / seconds,
                      Double(end.interruptWakeups - interruptWakeups) / seconds,
                      Double(end.footprint) / 1_048_576, end.threads)
    }
}
