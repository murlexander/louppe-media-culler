import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import XCTest
@testable import Louppe

/// Opt-in measurements use disposable JPEGs and isolated cache roots. Generation
/// and source identity capture are outside the timed operations. ImageIO source
/// decodes bypass Louppe's caches; they do not flush the operating system cache.
@MainActor
final class LouppeSpeedMediaTests: XCTestCase {
    func testMediaDecodeAndCachePaths() async throws {
        try SpeedBenchmark.requireEnabled()
        let fixture = try makeFixture(count: 16)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let report = SpeedReport(suite: "media-cache")
        let item = try XCTUnwrap(fixture.items.first)

        for bound in [ImagePipeline.thumbPixelSize, ImagePipeline.fullPixelSize] {
            try report.measure(name: "jpeg_source_decode_\(Int(bound))px_os_cache_warm", count: 1) {
                try autoreleasepool {
                    let image = try XCTUnwrap(ImagePipeline.decodeImage(url: item.primaryURL, maxPixel: bound))
                    XCTAssertEqual(max(image.width, image.height), Int(bound))
                    XCTAssertGreaterThan(image.width, 0)
                    XCTAssertGreaterThan(image.height, 0)
                }
            }
        }

        let warmRoot = fixture.root.appendingPathComponent("warm-cache", isDirectory: true)
        let warm = ImagePipeline(testingDiskCacheRoot: warmRoot)
        for value in fixture.items {
            let image = await warm.thumbnail(for: value)
            XCTAssertNotNil(image)
        }
        await warm.waitForPendingDiskWrites()
        for value in fixture.items {
            let filename = ImagePipeline.diskFileName(for: ImagePipeline.cacheKey(for: value))
            let cached = try XCTUnwrap(ImagePipeline.decodeImage(
                url: warmRoot.appendingPathComponent(filename), maxPixel: ImagePipeline.thumbPixelSize
            ), "the disk-hit benchmark requires a readable current-revision cache entry")
            XCTAssertEqual(max(cached.width, cached.height), Int(ImagePipeline.thumbPixelSize))
        }
        let full = await warm.fullImage(for: item)
        XCTAssertNotNil(full)

        try report.measure(name: "thumbnail_memory_hit_1000", count: 1_000) {
            var hits = 0
            for _ in 0..<1_000 {
                if warm.cachedThumbnail(for: item) != nil { hits += 1 }
            }
            XCTAssertEqual(hits, 1_000)
        }
        try report.measure(name: "full_memory_hit_1000", count: 1_000) {
            var hits = 0
            for _ in 0..<1_000 {
                if warm.cachedFullImage(for: item) != nil { hits += 1 }
            }
            XCTAssertEqual(hits, 1_000)
        }

        try await report.measureAsync(name: "thumbnail_disk_hit_16_including_pipeline_init", count: fixture.items.count) {
            let pipeline = ImagePipeline(testingDiskCacheRoot: warmRoot)
            var hits = 0
            for value in fixture.items {
                if await pipeline.thumbnail(for: value) != nil { hits += 1 }
            }
            XCTAssertEqual(hits, fixture.items.count)
        }
        try await report.measureAsync(name: "thumbnail_source_16_including_pipeline_init_and_disk_drain", count: fixture.items.count) {
            let root = fixture.root.appendingPathComponent("cold-cache-\(UUID())", isDirectory: true)
            let pipeline = ImagePipeline(testingDiskCacheRoot: root)
            var hits = 0
            for value in fixture.items {
                if await pipeline.thumbnail(for: value) != nil { hits += 1 }
            }
            await pipeline.waitForPendingDiskWrites()
            XCTAssertEqual(hits, fixture.items.count)
            XCTAssertEqual(try self.cacheEntryCount(at: root), fixture.items.count)
            try FileManager.default.removeItem(at: root)
        }
        try assertSourcesUnchanged(fixture)
        try report.finish()
    }

    func testConcurrentSameRevisionThumbnailRequests() async throws {
        try SpeedBenchmark.requireEnabled()
        let fixture = try makeFixture(count: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let item = try XCTUnwrap(fixture.items.first)
        let report = SpeedReport(suite: "media-fanout")
        let requestCount = 32
        try await report.measureAsync(name: "same_revision_32_thumbnail_waiters_including_disk_drain", count: requestCount) {
            let root = fixture.root.appendingPathComponent("fanout-\(UUID())", isDirectory: true)
            let pipeline = ImagePipeline(testingDiskCacheRoot: root)
            let identities = await withTaskGroup(of: ObjectIdentifier?.self) { group in
                for _ in 0..<requestCount {
                    group.addTask {
                        guard let image = await pipeline.thumbnail(for: item) else { return nil }
                        return ObjectIdentifier(image)
                    }
                }
                var identities: [ObjectIdentifier] = []
                for await value in group {
                    if let value { identities.append(value) }
                }
                return identities
            }
            await pipeline.waitForPendingDiskWrites()
            XCTAssertEqual(identities.count, requestCount)
            XCTAssertEqual(Set(identities).count, 1, "all same-revision waiters should share the resulting image")
            XCTAssertEqual(try self.cacheEntryCount(at: root), 1)
            try FileManager.default.removeItem(at: root)
        }
        try assertSourcesUnchanged(fixture)
        try report.finish()
    }

    /// Production cancellation must prevent admission and cache writes for
    /// already-cancelled callers; live coalesced waiters are covered separately.
    func testAlreadyCancelledThumbnailWork() async throws {
        try SpeedBenchmark.requireEnabled()
        let fixture = try makeFixture(count: 32)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let report = SpeedReport(suite: "media-cancellation")
        var completions: [Int] = []
        var writes: [Int] = []
        try await report.measureAsync(name: "already_cancelled_32_unique_thumbnails_including_disk_drain", count: fixture.items.count) {
            let root = fixture.root.appendingPathComponent("cancelled-\(UUID())", isDirectory: true)
            let pipeline = ImagePipeline(testingDiskCacheRoot: root)
            let completed = await withTaskGroup(of: Bool.self) { group in
                for item in fixture.items {
                    group.addTask {
                        withUnsafeCurrentTask { task in task?.cancel() }
                        return await pipeline.thumbnail(for: item) != nil
                    }
                }
                var completed = 0
                for await succeeded in group { if succeeded { completed += 1 } }
                return completed
            }
            await pipeline.waitForPendingDiskWrites()
            let entries = try self.cacheEntryCount(at: root)
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(entries, 0)
            completions.append(completed)
            writes.append(entries)
            try FileManager.default.removeItem(at: root)
        }
        print("MEDIA_CANCELLATION already_cancelled_unique_requests=32 completed_per_sample=\(completions) disk_entries_per_sample=\(writes)")
        try assertSourcesUnchanged(fixture)
        try report.finish()
    }

    /// Retain the legacy await-thumbnail-then-full diagnostic for comparison
    /// with the saved baseline, then measure actual mounted FullImageView.
    /// The legacy mirror does not measure a display frame. The task-start counter
    /// runs immediately before the public thumbnail call, not inside the private
    /// OperationQueue, so exact enqueue order remains scheduling-dependent.
    func testGalleryThumbnailDependencyUnderBacklog() async throws {
        try SpeedBenchmark.requireEnabled()
        guard NSScreen.main != nil else { throw XCTSkip("Mounted Gallery speed checks require a WindowServer screen") }
        let backlogCount = 128
        let fixture = try makeFixture(count: backlogCount + 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = try XCTUnwrap(fixture.items.last)
        let report = SpeedReport(suite: "media-gallery-backlog")

        for count in [0, backlogCount] {
            var fullTimes: [Double] = []
            var thumbnailTimes: [Double] = []
            var publicationTimes: [Double] = []
            var delaysAfterFull: [Double] = []
            try await report.measureAsync(name: "mirrored_gallery_backlog_\(count)_with_init_drain_cleanup", count: count + 1) {
                let root = fixture.root.appendingPathComponent("backlog-\(UUID())", isDirectory: true)
                let pipeline = ImagePipeline(testingDiskCacheRoot: root)
                let started = SpeedMediaDecodeCounter()
                let background = fixture.items.prefix(count).map { item in
                    Task.detached {
                        started.record()
                        return await pipeline.thumbnail(for: item) != nil
                    }
                }
                // Bound the admission barrier without blocking any decode lane.
                // Counter observation permits the tasks to enter their next call;
                // it does not claim deterministic private-queue insertion order.
                let admissionStart = ContinuousClock.now
                while started.value < count,
                      admissionStart.duration(to: .now) < .seconds(10) {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                XCTAssertEqual(started.value, count)
                await Task.yield()

                let requestedAt = ContinuousClock.now
                let full = Task.detached { () -> (Bool, Double) in
                    let ready = await pipeline.fullImage(for: target) != nil
                    return (ready, Self.milliseconds(since: requestedAt))
                }
                let thumbnail = Task.detached { () -> (Bool, Double) in
                    let ready = await pipeline.thumbnail(for: target) != nil
                    return (ready, Self.milliseconds(since: requestedAt))
                }
                // This is the relevant FullImageView dependency: even when the
                // full task has completed, publication awaits thumbnail first.
                let thumbnailResult = await thumbnail.value
                let fullResult = await full.value
                let publication = max(fullResult.1, thumbnailResult.1)
                fullTimes.append(fullResult.1)
                thumbnailTimes.append(thumbnailResult.1)
                publicationTimes.append(publication)
                delaysAfterFull.append(max(0, publication - fullResult.1))
                XCTAssertTrue(fullResult.0)
                XCTAssertTrue(thumbnailResult.0)

                var completed = 0
                for request in background { if await request.value { completed += 1 } }
                await pipeline.waitForPendingDiskWrites()
                XCTAssertEqual(completed, count)
                XCTAssertEqual(try self.cacheEntryCount(at: root), count + 1)
                try FileManager.default.removeItem(at: root)
            }
            try report.recordSamples(name: "gallery.full-ready.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(fullTimes.dropFirst()))
            try report.recordSamples(name: "gallery.thumbnail-ready.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(thumbnailTimes.dropFirst()))
            try report.recordSamples(name: "gallery.mirrored-publication.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(publicationTimes.dropFirst()))
            try report.recordSamples(name: "gallery.delay-after-full.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(delaysAfterFull.dropFirst()))
            print("MEDIA_BACKLOG mirrored_orchestration=true task_start_counter=true deterministic_queue_order=false backlog=\(count) full_ready_ms=\(fullTimes) thumbnail_ready_ms=\(thumbnailTimes) publication_ms=\(publicationTimes) delay_after_full_ms=\(delaysAfterFull)")
        }
        for count in [0, backlogCount] {
            var fullTimes: [Double] = []
            var thumbnailTimes: [Double] = []
            var publicationTimes: [Double] = []
            var delaysAfterFull: [Double] = []
            try await report.measureAsync(name: "mounted_gallery_backlog_\(count)_with_init_drain_cleanup", count: count + 1) {
                let root = fixture.root.appendingPathComponent("mounted-backlog-\(UUID())", isDirectory: true)
                let pipeline = ImagePipeline(testingDiskCacheRoot: root)
                let started = SpeedMediaDecodeCounter()
                let background = fixture.items.prefix(count).map { item in
                    Task.detached {
                        started.record()
                        return await pipeline.thumbnail(for: item) != nil
                    }
                }
                let admissionStart = ContinuousClock.now
                while started.value < count, admissionStart.duration(to: .now) < .seconds(10) {
                    try await Task.sleep(for: .milliseconds(1))
                }
                XCTAssertEqual(started.value, count)
                await Task.yield()
                let requestedAt = ContinuousClock.now
                let thumbnail = Task.detached { () -> (Bool, Double) in
                    let ready = await pipeline.thumbnail(for: target) != nil
                    return (ready, Self.milliseconds(since: requestedAt))
                }
                var beganLoading = false
                var settled = false
                let view = FullImageView(item: target, zoomMode: .constant(.fit), actualSizeViewport: ActualSizeViewport(),
                                         onZoomToActual: { _ in }, onZoomToFit: {},
                                         onLoading: { loading in
                                             if loading { beganLoading = true }
                                             if beganLoading, !loading { settled = true }
                                         }, imagePipeline: pipeline)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                var fullReady: Double?
                var displayed: Double?
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while displayed == nil, ContinuousClock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    if fullReady == nil, pipeline.cachedFullImage(for: target) != nil {
                        fullReady = Self.milliseconds(since: requestedAt)
                    }
                    if fullReady != nil, settled, self.hasFittedSurface(host) {
                        displayed = Self.milliseconds(since: requestedAt)
                    }
                    if displayed == nil { try await Task.sleep(for: .milliseconds(1)) }
                }
                let ready = try XCTUnwrap(fullReady, "Full preview did not become ready")
                let publication = try XCTUnwrap(displayed, "Mounted full preview did not appear")
                fullTimes.append(ready)
                publicationTimes.append(publication)
                delaysAfterFull.append(max(0, publication - ready))
                let thumbnailResult = await thumbnail.value
                thumbnailTimes.append(thumbnailResult.1)
                XCTAssertTrue(thumbnailResult.0)
                var completed = 0
                for request in background { if await request.value { completed += 1 } }
                await pipeline.waitForPendingDiskWrites()
                XCTAssertEqual(completed, count)
                XCTAssertEqual(try self.cacheEntryCount(at: root), count + 1)
                try FileManager.default.removeItem(at: root)
            }
            try report.recordSamples(name: "gallery.production-full-ready.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(fullTimes.dropFirst()))
            try report.recordSamples(name: "gallery.production-thumbnail-ready.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(thumbnailTimes.dropFirst()))
            try report.recordSamples(name: "gallery.production-mounted-publication.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(publicationTimes.dropFirst()))
            try report.recordSamples(name: "gallery.production-delay-after-full.backlog-\(count)", count: count + 1,
                                     samplesMS: Array(delaysAfterFull.dropFirst()))
            print("MEDIA_MOUNTED_BACKLOG production_view=true displayed_surface_and_settled=true frame_measurement=false poll_ms=1 backlog=\(count) full_ready_ms=\(fullTimes) thumbnail_ready_ms=\(thumbnailTimes) publication_ms=\(publicationTimes) delay_after_full_ms=\(delaysAfterFull)")
        }
        try assertSourcesUnchanged(fixture)
        try report.finish()
    }

    /// Existing RAW Decoder injection isolates the scheduling floor. This does
    /// not benchmark a real RAW decoder, storage, or the session/UI scheduler.
    /// Mirrors its two-item barrier with fresh pipeline caches per operation.
    func testRawHistogramBatchDwellFloor() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "media-raw-dwell")
        let items = (0..<4).map { offset in
            PhotoItem(id: "sample-\(offset).NEF",
                      primaryURL: URL(fileURLWithPath: "/private/tmp/louppe-speed-nonexistent-\(UUID())/sample-\(offset).NEF"),
                      pairedURL: nil, captureDate: nil, cameraModel: nil,
                      lensModel: nil, fileSize: 1)
        }
        let schedules: [(String, UInt64, RawHistogramPipeline.RequestPurpose)] = [
            ("synthetic_raw_4_in_2_item_batches_dwell_700ms", RawHistogramPipeline.analysisDelayNanoseconds, .info),
            ("synthetic_raw_4_in_2_item_batches_dwell_0ms", 0, .info),
            ("synthetic_raw_4_in_2_item_batches_production_background", RawHistogramPipeline.analysisDelayNanoseconds, .backgroundQuality)
        ]
        for (name, delay, purpose) in schedules {
            try await report.measureAsync(name: name, count: items.count) {
                let counter = SpeedMediaDecodeCounter()
                let pipeline = RawHistogramPipeline(delayNanoseconds: delay) { _ in
                    counter.record()
                    return HistogramAnalysis(bins: Array(repeating: 0, count: 256), sampleCount: 1,
                                             shadowCount: 0, highlightCount: 0, width: 1, height: 1)
                }
                var completed = 0
                for start in stride(from: 0, to: items.count, by: 2) {
                    let batch = Array(items[start..<min(start + 2, items.count)])
                    completed += await withTaskGroup(of: Bool.self) { group in
                        for item in batch {
                            group.addTask { await pipeline.analysis(for: item, purpose: purpose) != nil }
                        }
                        var count = 0
                        for await value in group { if value { count += 1 } }
                        return count
                    }
                }
                XCTAssertEqual(completed, items.count)
                XCTAssertEqual(counter.value, items.count)
            }
        }
        try report.finish()
    }

    private func hasFittedSurface(_ view: NSView) -> Bool {
        view is FittedImageDoubleClickView || view.subviews.contains { hasFittedSurface($0) }
    }

    private struct Fixture {
        let root: URL
        let items: [PhotoItem]
        let bytes: Data
    }

    private func makeFixture(count: Int) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("louppe-speed-media-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let bytes = try jpegData(width: 4_096, height: 2_731)
            let items = try (0..<count).map { offset in
                let url = root.appendingPathComponent(String(format: "sample-%04d.JPG", offset))
                try bytes.write(to: url)
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let item = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
                                     captureDate: nil, cameraModel: nil, lensModel: nil,
                                     primaryModificationDate: values.contentModificationDate,
                                     fileSize: Int64(values.fileSize ?? 0))
                XCTAssertNotNil(item.primaryFile.scannedIdentity,
                                "real JPEG measurements must exercise the production source-identity checks")
                return item
            }
            return Fixture(root: root, items: items, bytes: bytes)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func jpegData(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Smooth gradients plus high-frequency stripes avoid an unrealistically
        // flat compressed image while keeping fixture generation deterministic.
        for row in 0..<64 {
            context.setFillColor(red: CGFloat(row % 17) / 16,
                                 green: CGFloat((row * 7) % 31) / 30,
                                 blue: CGFloat(63 - row) / 63, alpha: 1)
            context.fill(CGRect(x: 0, y: CGFloat(row * height) / 64,
                                width: CGFloat(width), height: CGFloat(height) / 64 + 1))
        }
        context.setFillColor(CGColor(red: 0.13, green: 0.27, blue: 0.43, alpha: 1))
        for column in stride(from: 0, to: width, by: 19) {
            context.fill(CGRect(x: CGFloat(column), y: 0, width: 3, height: CGFloat(height)))
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func cacheEntryCount(at root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.count
    }

    private func assertSourcesUnchanged(_ fixture: Fixture) throws {
        for item in fixture.items {
            XCTAssertEqual(try Data(contentsOf: item.primaryURL), fixture.bytes)
            XCTAssertTrue(MediaSourceRevision(item).matchesCurrentFile())
        }
    }

    nonisolated private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }
}

private final class SpeedMediaDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
