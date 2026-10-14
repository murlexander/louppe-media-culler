import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class MediaPerformanceTests: XCTestCase {
    func testOneCancelledCoalescedWaiterPreservesLiveWaiterInBothLanes() async throws {
        for full in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = MediaDecodeGate()
            defer { gate.release.signal() }
            let pipeline = ImagePipeline(testingDiskCacheRoot: root, thumbnailConcurrency: 1, fullConcurrency: 1) { _, _ in
                let call = gate.begin()
                defer { gate.end() }
                gate.started.signal()
                _ = mediaWait(gate.release, seconds: 5)
                return mediaImage(width: call)
            }
            let photo = item("coalesced.JPG")
            let cancelled = Task { await self.load(photo, pipeline: pipeline, full: full) }
            try await waitUntil { gate.calls == 1 }
            let live = Task { await self.load(photo, pipeline: pipeline, full: full) }
            try await waitUntil { pipeline.decodeWaiterCountForTesting(for: photo, full: full) == 2 }
            cancelled.cancel()
            let cancelledResult = await cancelled.value
            XCTAssertNil(cancelledResult)
            XCTAssertEqual(pipeline.decodeWaiterCountForTesting(for: photo, full: full), 1)
            gate.release.signal()
            let result = await live.value
            XCTAssertNotNil(result)
            let cached = await load(photo, pipeline: pipeline, full: full)
            XCTAssertTrue(result === cached)
            XCTAssertEqual(gate.calls, 1)
            await pipeline.waitForPendingDiskWrites()
        }
    }

    func testAllCancelledQueuedWaitersNeverDecodeOrWriteInBothLanes() async throws {
        for full in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = MediaDecodeGate()
            defer { gate.release.signal() }
            let pipeline = ImagePipeline(testingDiskCacheRoot: root, thumbnailConcurrency: 1, fullConcurrency: 1) { _, _ in
                let call = gate.begin()
                defer { gate.end() }
                gate.started.signal()
                _ = mediaWait(gate.release, seconds: 5)
                return mediaImage(width: call)
            }
            let occupying = item("occupying.JPG")
            let queued = item("queued.JPG")
            let first = Task { await self.load(occupying, pipeline: pipeline, full: full) }
            try await waitUntil { gate.calls == 1 }
            let abandoned = Task { await self.load(queued, pipeline: pipeline, full: full) }
            try await waitUntil { pipeline.decodeWaiterCountForTesting(for: queued, full: full) == 1 }
            abandoned.cancel()
            let result = await abandoned.value
            XCTAssertNil(result)
            gate.release.signal()
            _ = await first.value
            await pipeline.waitForPendingDiskWrites()
            XCTAssertEqual(gate.calls, 1)
            XCTAssertNil(full ? pipeline.cachedFullImage(for: queued) : pipeline.cachedThumbnail(for: queued))
            let filename = ImagePipeline.diskFileName(for: ImagePipeline.cacheKey(for: queued))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path))
        }
    }

    func testAbandonedWorkerKeepsLaneUntilExitAndCannotConsumeSameKeyRerequest() async throws {
        for full in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = MediaDecodeGate()
            defer { gate.release.signal() }
            let pipeline = ImagePipeline(testingDiskCacheRoot: root, thumbnailConcurrency: 1, fullConcurrency: 1) { _, _ in
                let call = gate.begin()
                defer { gate.end() }
                if call == 1 {
                    gate.started.signal()
                    _ = mediaWait(gate.release, seconds: 5)
                }
                return mediaImage(width: call)
            }
            let photo = item("renewed.JPG")
            let old = Task { await self.load(photo, pipeline: pipeline, full: full) }
            try await waitUntil { gate.calls == 1 }
            old.cancel()
            let oldResult = await old.value
            XCTAssertNil(oldResult)
            let renewed = Task { await self.load(photo, pipeline: pipeline, full: full) }
            try await waitUntil { pipeline.decodeWaiterCountForTesting(for: photo, full: full) == 1 }
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(gate.calls, 1, "the executing block must retain its bounded lane")
            gate.release.signal()
            let result = await renewed.value
            XCTAssertEqual(result?.size.width, 2, "obsolete completion must not consume renewed waiters")
            let cached = await load(photo, pipeline: pipeline, full: full)
            XCTAssertEqual(cached?.size.width, 2, "abandoned pixels must never enter memory cache")
            XCTAssertEqual(gate.maximumConcurrent, 1)
            XCTAssertEqual(gate.calls, 2)
            await pipeline.waitForPendingDiskWrites()
        }
    }

    func testAlreadyCancelledCallersEnterNeitherLane() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = MediaDecodeGate()
        let pipeline = ImagePipeline(testingDiskCacheRoot: root) { _, _ in
            _ = gate.begin()
            defer { gate.end() }
            return mediaImage(width: 1)
        }
        let photo = item("already-cancelled.JPG")
        for full in [false, true] {
            let result = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await self.load(photo, pipeline: pipeline, full: full)
            }.value
            XCTAssertNil(result)
        }
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(gate.calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testMountedFullImagePublishesWhileRealThumbnailLaneIsBlocked() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount Gallery") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.JPG")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(mediaImage(width: 64)), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = item("photo.JPG", url: source)
        let gate = MediaDecodeGate()
        defer { gate.release.signal() }
        let pipeline = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache"), thumbnailConcurrency: 1) { url, bound in
            if bound == ImagePipeline.thumbPixelSize {
                _ = gate.begin()
                defer { gate.end() }
                gate.started.signal()
                _ = mediaWait(gate.release, seconds: 5)
            }
            return ImagePipeline.decodeImage(url: url, maxPixel: bound)
        }
        let occupying = Task { await pipeline.thumbnail(for: photo) }
        try await waitUntil { gate.calls == 1 }
        var loading: [Bool] = []
        let view = FullImageView(item: photo, zoomMode: .constant(.fit), actualSizeViewport: ActualSizeViewport(),
                                 onZoomToActual: { _ in }, onZoomToFit: {},
                                 onLoading: { loading.append($0) }, imagePipeline: pipeline)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return self.hasFittedSurface(host) && loading == [true, false]
        }
        XCTAssertNil(pipeline.cachedThumbnail(for: photo), "the thumbnail is still in its real decode lane")
        XCTAssertNotNil(pipeline.cachedFullImage(for: photo))
        XCTAssertEqual(gate.calls, 1)
        try await waitUntil { pipeline.decodeWaiterCountForTesting(for: photo) == 1 }
        gate.release.signal()
        let thumbnail = await occupying.value
        XCTAssertNotNil(thumbnail)
        await pipeline.waitForPendingDiskWrites()
    }

    func testBackgroundRAWBypassesDwellWhileInfoRetainsItAndJPEGUsesIndependentLane() async throws {
        let gate = MediaDecodeGate()
        defer { gate.release.signal() }
        let raw = RawHistogramPipeline(delayNanoseconds: 500_000_000) { _ in
            _ = gate.begin()
            defer { gate.end() }
            gate.started.signal()
            _ = mediaWait(gate.release, seconds: 5)
            return HistogramAnalysis(bins: [], sampleCount: 1, shadowCount: 0, highlightCount: 0, width: 1, height: 1)
        }
        let info = Task { await raw.analysis(for: self.item("info.NEF")) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(gate.calls, 0, "Info must retain its navigation dwell")
        info.cancel()
        let infoResult = await info.value
        XCTAssertNil(infoResult)
        let background = Task { await raw.analysis(for: self.item("background.NEF"), purpose: .backgroundQuality) }
        try await waitUntil(timeout: .milliseconds(300)) { gate.calls == 1 }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = ImagePipeline(testingDiskCacheRoot: root) { _, _ in mediaImage(width: 1) }
        let jpegImage = await jpeg.fullImage(for: item("foreground.JPG"))
        XCTAssertNotNil(jpegImage, "a RAW background worker must not occupy JPEG's full-image lane")
        gate.release.signal()
        let evidence = await background.value
        XCTAssertEqual(evidence?.sampleCount, 1)
        XCTAssertEqual(gate.maximumConcurrent, 1)
    }

    private func load(_ item: PhotoItem, pipeline: ImagePipeline, full: Bool) async -> NSImage? {
        if full { return await pipeline.fullImage(for: item) }
        return await pipeline.thumbnail(for: item)
    }

    private func item(_ name: String, url: URL? = nil) -> PhotoItem {
        PhotoItem(id: name, primaryURL: url ?? URL(fileURLWithPath: "/private/tmp/\(UUID())/\(name)"),
                  pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/louppe-media-performance-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Media condition did not settle before deadline")
                throw NSError(domain: "MediaPerformanceTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func hasFittedSurface(_ view: NSView) -> Bool {
        view is FittedImageDoubleClickView || view.subviews.contains { hasFittedSurface($0) }
    }
}

private final class MediaDecodeGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var maximum = 0
    var calls: Int { lock.withLock { count } }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    func begin() -> Int {
        lock.withLock { count += 1; active += 1; maximum = max(maximum, active); return count }
    }
    func end() { lock.withLock { active -= 1 } }
}

private func mediaWait(_ semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + seconds)
}

private func mediaImage(width: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: width))
    return context.makeImage()
}
