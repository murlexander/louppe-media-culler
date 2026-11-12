import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SwiftUI
@testable import Louppe

/// Fit sizing tiers, header-sized zoom readout and ordered, one-lane
/// neighbour prefetch. Workers are fault-injected; decodes use real files.
@MainActor
final class NextPhotoSpeedTests: XCTestCase {
    // MARK: Fit sizing

    func testExactScaleCoversDisplayWithinHardBound() {
        let laptop = CGSize(width: 3024, height: 1964)
        let fiveK = CGSize(width: 5120, height: 2880)
        let landscape = CGSize(width: 7728, height: 5152)
        // Half covers a laptop's fitted 2,946 pixels; a quarter (1,932) would not.
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: landscape, coverage: laptop), 3864)
        // 5K needs 4,320; half misses it, so the bounded request stays.
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: landscape, coverage: fiveK), ImagePipeline.fullPixelSize)
        // A portrait photo on 5K is height-limited (2,880): half covers.
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: CGSize(width: 5152, height: 7728), coverage: fiveK), 3864)
        // Within the hard bound, native size avoids resampling.
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: CGSize(width: 4500, height: 3000), coverage: laptop), 4500)
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: CGSize(width: 4000, height: 3000), coverage: laptop), ImagePipeline.fullPixelSize)
        // A half-scale below the custom-zoom floor uses the bounded request.
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: CGSize(width: 6001, height: 4001), coverage: laptop), ImagePipeline.fullPixelSize)
        // A small display must retain the same detail floor as the laptop.
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(orientedSize: landscape, coverage: CGSize(width: 1920, height: 1080)), 3864)
        for size in [landscape, CGSize(width: 9000, height: 6000), CGSize(width: 20000, height: 400)] {
            for coverage in [laptop, fiveK, CGSize(width: 7680, height: 4320)] {
                XCTAssertLessThanOrEqual(ImagePipeline.exactScalePixelSize(orientedSize: size, coverage: coverage), ImagePipeline.fitOutputPixelBound)
            }
        }
    }

    func testSmallDisplaysKeepCustomZoomDetailFloorAndLaptopHalfScale() {
        for coverage in [CGSize(width: 1280, height: 800), CGSize(width: 1920, height: 1080), CGSize(width: 3024, height: 1964)] {
            for longEdge: CGFloat in [4000, 4800, 6001, 7728, 9000, 16000] {
                let result = ImagePipeline.exactScalePixelSize(
                    orientedSize: CGSize(width: longEdge, height: longEdge * 2 / 3), coverage: coverage)
                XCTAssertGreaterThanOrEqual(result, min(longEdge, 3840))
                XCTAssertLessThanOrEqual(result, ImagePipeline.fitOutputPixelBound)
            }
        }
        XCTAssertEqual(ImagePipeline.exactScalePixelSize(
            orientedSize: CGSize(width: 7728, height: 5152), coverage: CGSize(width: 3024, height: 1964)), 3864)
    }

    func testMountedPreviewReloadsDisplayTierAndRejectsRetiredCompletion() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required") }
        let originalCoverage = ImagePipeline.displayCoverage
        defer { ImagePipeline.setDisplayCoverageForTesting(originalCoverage) }
        let laptop = CGSize(width: 3024, height: 1964)
        ImagePipeline.setDisplayCoverageForTesting(laptop)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("display.jpg")
        try writeJPEG(to: url, width: 300, height: 200, orientation: 1)
        let photo = try scannedItem(at: url)
        let gate = OrderedGate(timeout: 30)
        defer { gate.releaseAll() }
        let calls = CallCounter()
        let fullPixels = try solidImage(width: 64, height: 64, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let thumbnailPixels = try solidImage(width: 8, height: 8, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache")) { _, bound in
            guard bound == ImagePipeline.fullPixelSize else { return thumbnailPixels }
            let call = calls.next()
            _ = gate.work("fit-\(call)")
            return call == 2 ? nil : fullPixels
        }
        _ = await pipeline.thumbnail(for: photo)
        gate.release("fit-1")
        let warm = await pipeline.fullImage(for: photo)
        XCTAssertNotNil(warm)
        var reports: [PhotoRepresentation] = []
        let host = NSHostingView(rootView: FullImageView(
            item: photo, zoomMode: .constant(.fit), actualSizeViewport: ActualSizeViewport(),
            onZoomToActual: { _ in }, onZoomToFit: {},
            onRepresentation: { representation, _ in reports.append(representation) }, imagePipeline: pipeline))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Mount offscreen below existing windows; never activate or take focus.
        window.order(.below, relativeTo: 0)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await eventually { host.layoutSubtreeIfNeeded(); return reports.last == .preview }
        let initialPixels = try assertFullPreviewPixels(in: host)
        ImagePipeline.setDisplayCoverageForTesting(CGSize(width: 5120, height: 2880))
        try await eventually { host.layoutSubtreeIfNeeded(); return calls.value == 2 && reports.last == .loadingPreview }
        XCTAssertNil(pipeline.cachedFullImage(for: photo), "the smaller tier must not satisfy a larger display")
        // The full image is blue, its cached thumbnail red. Sample the mounted
        // pixels so a blank pane or thumbnail-quality flash fails this test.
        try assertFullPreviewPixels(in: host, matching: initialPixels)
        try await Task.sleep(for: .milliseconds(60))
        try assertFullPreviewPixels(in: host, matching: initialPixels)
        // Return to the warm tier while the large-tier worker is still blocked.
        ImagePipeline.setDisplayCoverageForTesting(laptop)
        try await eventually { host.layoutSubtreeIfNeeded(); return reports.last == .preview }
        let settledCount = reports.count
        gate.release("fit-2")
        await pipeline.waitForFullWorkForTesting()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(reports.last, .preview, "the retired tier's late failure must not replace the warm preview")
        XCTAssertEqual(reports.count, settledCount)
        XCTAssertEqual(calls.value, 2)
        try assertFullPreviewPixels(in: host, matching: initialPixels)
        await pipeline.waitForPendingDiskWrites()
    }

    func testFullCacheKeysCarrySizeTierAndKeepRevisionAndDecoderIdentity() {
        let laptop = CGSize(width: 3024, height: 1964)
        let jpeg = item("a.JPG"), raf = item("a.RAF"), jxl = item("a.jxl"), heic = item("a.HEIC")
        func key(_ item: PhotoItem, _ mode: RawDisplayMode = .fast, _ coverage: CGSize? = laptop, _ decoder: AppleRawDecoder = .appleDefault) -> String {
            ImagePipeline.fullCacheKey(for: item, mode: mode, decoder: decoder,
                                       sizing: FitDecodeSizing(item: item, mode: mode, coverage: coverage))
        }
        for item in [jpeg, raf, jxl, heic] { XCTAssertTrue(key(item).hasPrefix(ImagePipeline.cacheKey(for: item))) }
        // Only a display change, never a window resize, changes the JPEG tier.
        XCTAssertNotEqual(key(jpeg), key(jpeg, .fast, CGSize(width: 5120, height: 2880)))
        XCTAssertEqual(key(jpeg, .fast, nil), ImagePipeline.cacheKey(for: jpeg))
        XCTAssertEqual(key(raf), key(raf, .fast, nil), "RAF previews do not depend on the display")
        XCTAssertNotEqual(key(raf), ImagePipeline.cacheKey(for: raf))
        // Formats without a measured gain keep their keys and bounded decode.
        XCTAssertEqual(key(jxl), ImagePipeline.cacheKey(for: jxl))
        XCTAssertEqual(key(heic), ImagePipeline.cacheKey(for: heic))
        XCTAssertEqual(FitDecodeSizing(item: jxl, mode: .fast, coverage: laptop), .bounded)
        // RAW renders keep the decoder-specific key and the bounded request.
        XCTAssertEqual(FitDecodeSizing(item: raf, mode: .raw, coverage: laptop), .bounded)
        XCTAssertNotEqual(key(raf, .raw, laptop, .appleDefault), key(raf, .raw, laptop, .raw9))
        let replaced = PhotoItem(primaryFile: PhotoFile(id: "a.JPG", url: jpeg.primaryURL, captureDate: nil, cameraModel: nil,
                                                        lensModel: nil, fileSize: 2, scannedIdentity: nil))
        XCTAssertNotEqual(key(jpeg), key(replaced), "content revision stays in the key")
    }

    func testExactScaleDecodeAppliesOrientation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Stored 7680×5120, EXIF orientation 6: displayed 5120×7680.
        let url = folder.appendingPathComponent("rotated.jpg")
        try writeJPEG(to: url, width: 7680, height: 5120, orientation: 6)
        let image = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: .exactScale(coverage: CGSize(width: 3024, height: 1964))))
        XCTAssertEqual(image.width, 2560)
        XCTAssertEqual(image.height, 3840)
        let bounded = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: .bounded))
        XCTAssertEqual(bounded.width, 2731)
        XCTAssertEqual(bounded.height, 4096)
    }

    func testEmbeddedPreviewSizingKeepsUndersizedFallback() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("thumbnail.jpg")
        try writeJPEG(to: url, width: 3000, height: 2000, orientation: 1, embedThumbnail: true)
        let image = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: .embeddedPreview))
        XCTAssertEqual(image.width, 3000, "a tiny embedded thumbnail must fall back to a full decode")
    }

    func testReducedFitRejectsEmbeddedPreviewBelowOldAcceptanceThreshold() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("medium-preview.jpg")
        try writeJPEGWithEmbeddedPreview(to: url, previewWidth: 3500)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let embedded = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ] as CFDictionary))
        XCTAssertEqual(embedded.width, 3500, "fixture must exercise the old 90%-of-reduced-request hole")
        let fit = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: .exactScale(coverage: CGSize(width: 3024, height: 1964))))
        XCTAssertEqual(fit.width, 3840, "reject the embedded 3,500 pixels and decode the exact half scale")
        XCTAssertGreaterThanOrEqual(CGFloat(fit.width), 0.9 * ImagePipeline.fullPixelSize)
    }

    func testRAFFastSizingStillReturnsLargeEmbeddedPreviewWithoutResampling() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Exercise RAF's ImageIO preview branch with a synthetic embedded JPEG.
        let url = folder.appendingPathComponent("camera-preview.jpg")
        try writeJPEGWithEmbeddedPreview(to: url, previewWidth: 4416)
        let fit = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: .embeddedPreview))
        XCTAssertEqual(fit.width, 4416, "the camera preview must still bypass the 4,096-pixel full fallback")
    }

    // MARK: Zoom readout

    func testHeaderPixelSizeMatchesOrientedRecipeWithoutBuildingIt() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for orientation in [1, 3, 6, 8] {
            let url = folder.appendingPathComponent("o\(orientation).jpg")
            try writeJPEG(to: url, width: 300, height: 200, orientation: orientation)
            let recipe = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
            XCTAssertEqual(HighResolutionImagePipeline.orientedPixelSize(url: url), recipe.extent.integral.size, "orientation \(orientation)")
        }
        let url = folder.appendingPathComponent("o6.jpg")
        let photo = try scannedItem(at: url)
        let recipes = CallCounter()
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 1) { _, _, _ in
            recipes.increment()
            return nil
        }
        let size = await pipeline.pixelSize(for: photo)
        XCTAssertEqual(size, CGSize(width: 200, height: 300))
        XCTAssertEqual(recipes.value, 0, "the readout must not build a recipe")
        XCTAssertFalse(pipeline.sourceIsCachedForTesting(for: photo))
    }

    func testHeaderPixelSizeRejectsFileReplacedAfterScan() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("replaced.jpg")
        try writeJPEG(to: url, width: 300, height: 200, orientation: 1)
        let photo = try scannedItem(at: url)
        let replacement = folder.appendingPathComponent("new.jpg")
        try writeJPEG(to: replacement, width: 600, height: 200, orientation: 1)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 1) { _, _, _ in nil }
        let size = await pipeline.pixelSize(for: photo)
        XCTAssertNil(size)
    }

    // MARK: Ordered, one-lane prefetch

    func testFullPrefetchRunsInCallerOrderOnOneLane() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OrderedGate()
        defer { gate.releaseAll() }
        let coordinator = ForegroundWorkCoordinator(quietInterval: .zero)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 2, foregroundWork: coordinator) { url, _ in
            gate.work(url.lastPathComponent)
        }
        let photos = ["p1.JPG", "p2.JPG", "p3.JPG", "m1.JPG"].map(item)
        let lease = pipeline.prefetchFullImages(items: photos)
        defer { lease.cancel() }
        for expected in 1...4 {
            try await eventually { gate.started.count == expected }
            XCTAssertEqual(gate.active, 1, "neighbours never hold both lanes")
            gate.releaseOne()
        }
        await lease.value
        XCTAssertEqual(gate.started, ["p1.JPG", "p2.JPG", "p3.JPG", "m1.JPG"])
    }

    func testAbandonedNeighbourKeepsOnlyOneLaneAndForegroundUsesTheOther() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OrderedGate()
        defer { gate.releaseAll() }
        let coordinator = ForegroundWorkCoordinator(quietInterval: .zero)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 2, foregroundWork: coordinator) { url, _ in
            gate.work(url.lastPathComponent)
        }
        let first = pipeline.prefetchFullImages(items: [item("old.JPG")])
        try await eventually { gate.started == ["old.JPG"] }
        first.cancel()
        await first.value
        // The cancelled decode still executes; the next neighbour parks.
        let second = pipeline.prefetchFullImages(items: [item("next.JPG")])
        defer { second.cancel() }
        try await eventually { pipeline.prefetchLaneForTesting.parked == 1 }
        let current = Task { await pipeline.fullImage(for: item("current.JPG")) }
        try await eventually { gate.started == ["old.JPG", "current.JPG"] }
        gate.release("current.JPG")
        _ = await current.value
        XCTAssertEqual(gate.started, ["old.JPG", "current.JPG"])
        gate.release("old.JPG")
        try await eventually { gate.started == ["old.JPG", "current.JPG", "next.JPG"] }
        gate.release("next.JPG")
        await second.value
        try await eventually { !pipeline.prefetchLaneForTesting.held }
    }

    func testPromotedNeighbourFreesTheLaneForTheNext() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OrderedGate()
        defer { gate.releaseAll() }
        let coordinator = ForegroundWorkCoordinator(quietInterval: .zero)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 2, foregroundWork: coordinator) { url, _ in
            gate.work(url.lastPathComponent)
        }
        let a = pipeline.prefetchFullImages(items: [item("a.JPG")])
        try await eventually { gate.started == ["a.JPG"] }
        let b = pipeline.prefetchFullImages(items: [item("b.JPG")])
        defer { a.cancel(); b.cancel() }
        try await eventually { pipeline.prefetchLaneForTesting.parked == 1 }
        // Navigating onto the running neighbour promotes it.
        let current = Task { await pipeline.fullImage(for: item("a.JPG")) }
        try await eventually { gate.started == ["a.JPG", "b.JPG"] }
        gate.releaseAll()
        _ = await current.value
        await a.value
        await b.value
    }

    func testReplacingWindowJoinsRunningDecodeBeforeReleasingPrevious() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OrderedGate()
        defer { gate.releaseAll() }
        let coordinator = ForegroundWorkCoordinator(quietInterval: .zero)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 2, foregroundWork: coordinator) { url, _ in
            gate.work(url.lastPathComponent)
        }
        let next = item("next.JPG")
        let old = pipeline.prefetchFullImages(items: [next])
        try await eventually { gate.started == ["next.JPG"] }
        // Navigation onto the running neighbour: the new window owns it first.
        let window = pipeline.prefetchFullImages(items: [], after: next, replacing: old)
        await old.value
        XCTAssertEqual(pipeline.decodeWaiterCountForTesting(for: next, full: true), 1)
        gate.releaseAll()
        await window.value
        XCTAssertNotNil(pipeline.cachedFullImage(for: next))
        XCTAssertEqual(gate.started, ["next.JPG"], "the running decode must not be discarded and repeated")
    }

    func testCancellationBetweenHandoffAndSubmissionStartsThirdWaiter() async throws {
        for sources in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let workers = OrderedGate(), handoff = OrderedGate()
            defer { workers.releaseAll(); handoff.releaseAll() }
            let coordinator = ForegroundWorkCoordinator(quietInterval: .zero)
            let prefetch: ([PhotoItem]) -> Task<Void, Never>
            let lane: () -> (held: Bool, parked: Int)
            let drain: () async -> Void
            if sources {
                let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 2, foregroundWork: coordinator) { revision, key, decoder in
                    _ = workers.work(revision.url.lastPathComponent)
                    return ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                                           pixelSize: CGSize(width: 1, height: 1), sourceRevision: revision, decoder: decoder)
                }
                pipeline.beforePrefetchHandoffSubmissionForTesting = { _ = handoff.work("handoff") }
                prefetch = { pipeline.prefetchSources(items: $0, decoder: .appleDefault) }
                lane = { pipeline.prefetchLaneForTesting }
                drain = { await pipeline.waitForSourceWorkForTesting() }
            } else {
                let pipeline = ImagePipeline(testingDiskCacheRoot: folder, fullConcurrency: 2, foregroundWork: coordinator) { url, _ in
                    workers.work(url.lastPathComponent)
                }
                pipeline.beforePrefetchHandoffSubmissionForTesting = { _ = handoff.work("handoff") }
                prefetch = { pipeline.prefetchFullImages(items: $0) }
                lane = { pipeline.prefetchLaneForTesting }
                drain = { await pipeline.waitForFullWorkForTesting() }
            }
            let a = prefetch([item("a.JPG")])
            let b: Task<Void, Never>, c: Task<Void, Never>
            defer { a.cancel() }
            try await eventually { workers.started == ["a.JPG"] }
            b = prefetch([item("b.JPG")])
            defer { b.cancel() }
            try await eventually { lane().parked == 1 }
            c = prefetch([item("c.JPG")])
            defer { c.cancel() }
            try await eventually { lane().parked == 2 }
            workers.release("a.JPG")
            try await eventually { handoff.started == ["handoff"] }
            // B owns the lane but has not reached submit. C is still parked.
            b.cancel()
            await b.value
            try await eventually { workers.started == ["a.JPG", "c.JPG"] }
            handoff.releaseAll()
            workers.releaseAll()
            await a.value
            await c.value
            await drain()
            try await eventually { !lane().held && lane().parked == 0 }
            XCTAssertFalse(workers.started.contains("b.JPG"))
        }
    }

    func testLeavingGalleryAndRetiringSessionClearYieldImmediately() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "louppe-yield-\(UUID())"))
        let store = SessionStore(reviewDefaults: defaults)
        let pipeline = ImagePipeline.shared
        defer { pipeline.cancelWholeImageThumbnailYield() }
        store.viewMode = .gallery
        pipeline.yieldWholeImageThumbnails(to: item("grid-transition.jxl"), mode: .fast, decoder: .appleDefault)
        XCTAssertNotNil(pipeline.wholeImageYieldForTesting.generation)
        store.viewMode = .grid
        XCTAssertNil(pipeline.wholeImageYieldForTesting.generation)
        XCTAssertEqual(pipeline.wholeImageYieldForTesting.width, ImagePipeline.thumbnailLaneWidth)
        store.viewMode = .gallery
        pipeline.yieldWholeImageThumbnails(to: item("session-transition.jxl"), mode: .fast, decoder: .appleDefault)
        XCTAssertNotNil(pipeline.wholeImageYieldForTesting.generation)
        store.phase = .scanning(found: 0)
        XCTAssertNil(pipeline.wholeImageYieldForTesting.generation)
        XCTAssertEqual(pipeline.wholeImageYieldForTesting.width, ImagePipeline.thumbnailLaneWidth)
    }

    func testYieldDeadlineWidensBacklogDuringActiveFitAndRejectsOldGeneration() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OrderedGate()
        defer { gate.releaseAll() }
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder) { url, _ in gate.work(url.lastPathComponent) }
        let photo = item("current.jxl")
        pipeline.yieldWholeImageThumbnails(to: photo, mode: .fast, decoder: .appleDefault)
        let oldGeneration = try XCTUnwrap(pipeline.wholeImageYieldForTesting.generation)
        let current = Task { await pipeline.fullImage(for: photo) }
        defer { current.cancel() }
        try await eventually { gate.started == ["current.jxl"] }
        pipeline.yieldWholeImageThumbnails(to: item("new-current.jxl"), mode: .fast, decoder: .appleDefault)
        let generation = try XCTUnwrap(pipeline.wholeImageYieldForTesting.generation)
        let thumbs = ["a.jxl", "b.jxl"].map { name in Task { await pipeline.thumbnail(for: item(name)) } }
        defer { thumbs.forEach { $0.cancel() } }
        try await eventually { gate.started.count == 2 }
        pipeline.expireWholeImageYieldForTesting(generation: oldGeneration)
        XCTAssertEqual(pipeline.wholeImageYieldForTesting.generation, generation)
        XCTAssertEqual(pipeline.wholeImageYieldForTesting.width, 1)
        pipeline.expireWholeImageYieldForTesting(generation: generation)
        try await eventually { gate.started.count == 3 }
        XCTAssertNil(pipeline.wholeImageYieldForTesting.generation)
        XCTAssertEqual(gate.active, 3, "the deadline widens the backlog while Fit is still executing")
        gate.releaseAll()
        _ = await current.value
        for task in thumbs { _ = await task.value }
        await pipeline.waitForPendingDiskWrites()
    }

    func testGalleryNavigationYieldsWholeImageThumbnailsUntilDeadline() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OrderedGate()
        defer { gate.releaseAll() }
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder) { url, _ in gate.work(url.lastPathComponent) }
        pipeline.yieldWholeImageThumbnails(to: item("current.jxl"), mode: .fast, decoder: .appleDefault)
        let thumbnails = ["a.jxl", "b.jxl", "c.jxl"].map { name in Task { await pipeline.thumbnail(for: item(name)) } }
        defer { thumbnails.forEach { $0.cancel() } }
        try await eventually { gate.started.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(gate.active, 1, "whole-image thumbnails start one at a time while the visible photo decodes")
        // No visible decode arrives: the one-second cap restores the lane,
        // which is only two wide on small machines such as CI runners.
        let restored = min(3, ImagePipeline.thumbnailLaneWidth)
        try await eventually { gate.started.count == restored }
        XCTAssertEqual(gate.active, restored)
        gate.releaseAll()
        for task in thumbnails { _ = await task.value }
        // Other formats never yield.
        pipeline.yieldWholeImageThumbnails(to: item("current2.jxl"), mode: .fast, decoder: .appleDefault)
        let jpegs = ["d.JPG", "e.JPG"].map { name in Task { await pipeline.thumbnail(for: item(name)) } }
        for task in jpegs { _ = await task.value }
    }

    func testSourcePrefetchWaitsForAdmissionAndRunsOnOneLane() async throws {
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
        let demand = coordinator.beginForegroundDemand()
        let gate = OrderedGate()
        defer { gate.releaseAll(); demand.finish() }
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 2, foregroundWork: coordinator) { revision, key, decoder in
            _ = gate.work(revision.url.lastPathComponent)
            return ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                                   pixelSize: CGSize(width: 1, height: 1), sourceRevision: revision, decoder: decoder)
        }
        let photos = ["p1.JPG", "p2.JPG", "m1.JPG"].map(item)
        let lease = pipeline.prefetchSources(items: photos, decoder: .appleDefault)
        defer { lease.cancel() }
        try await eventually { coordinator.waitingCountForTesting == 1 }
        XCTAssertTrue(gate.started.isEmpty, "neighbour recipes wait for background admission")
        demand.finish()
        for expected in 1...3 {
            try await eventually { gate.started.count == expected }
            XCTAssertEqual(gate.active, 1)
            gate.releaseOne()
        }
        await lease.value
        XCTAssertEqual(gate.started, ["p1.JPG", "p2.JPG", "m1.JPG"])
    }

    func testNeighbourWindowFollowsDirectionOfTravel() {
        XCTAssertEqual(SessionStore.neighbourOffsets(direction: 1), [1, 2, 3, -1])
        XCTAssertEqual(SessionStore.neighbourOffsets(direction: -1), [-1, -2, -3, 1])
    }

    // MARK: Helpers

    private func item(_ name: String) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-next-photo-synthetic/\(name)"),
                                        captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1, scannedIdentity: nil))
    }

    private func scannedItem(at url: URL) throws -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: url.lastPathComponent, url: url, captureDate: nil, cameraModel: nil,
                                        lensModel: nil, fileSize: 1, scannedIdentity: try FileOperationJournal.captureIdentity(at: url)))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("louppe-next-photo-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeJPEG(to url: URL, width: Int, height: Int, orientation: Int, embedThumbnail: Bool = false) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if embedThumbnail {
            properties[kCGImageDestinationEmbedThumbnail] = true
            properties[kCGImageDestinationImageMaxPixelSize] = max(width, height)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func solidImage(width: Int, height: Int, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @discardableResult
    private func assertFullPreviewPixels(in view: NSView, matching expected: NSColor? = nil,
                                         file: StaticString = #filePath, line: UInt = #line) throws -> NSColor {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), file: file, line: line)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertGreaterThan(color.blueComponent, 0.9, "full-preview pixels must stay visible", file: file, line: line)
        // Color management can add a small red component to device-RGB blue.
        XCTAssertLessThan(color.redComponent, 0.2, "must not show the cached thumbnail", file: file, line: line)
        XCTAssertGreaterThan(color.alphaComponent, 0.9, "must not blank the pane", file: file, line: line)
        if let expected {
            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.02, file: file, line: line)
            XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.02, file: file, line: line)
            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.02, file: file, line: line)
        }
        return color
    }

    /// JPEG EXIF's IFD1 contains an independently encoded preview. ImageIO's
    /// automatic thumbnail writer chooses a tiny size, so construct that IFD
    /// explicitly to exercise the medium-size acceptance boundary.
    private func writeJPEGWithEmbeddedPreview(to url: URL, previewWidth: Int) throws {
        try writeJPEG(to: url, width: 7680, height: 1024, orientation: 1)
        let destinationData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(destinationData, UTType.jpeg.identifier as CFString, 1, nil))
        let previewHeight = Int((Double(previewWidth) * 1024 / 7680).rounded())
        CGImageDestinationAddImage(destination, try solidImage(width: previewWidth, height: previewHeight,
                                                              color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                                  [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let preview = destinationData as Data
        var tiff = Data()
        func u16(_ value: UInt16) { tiff.append(UInt8(value & 255)); tiff.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
        func entry(_ tag: UInt16, _ type: UInt16, _ value: UInt32) { u16(tag); u16(type); u32(1); u32(value) }
        tiff.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
        u16(1); entry(274, 3, 1); u32(26) // IFD0 orientation, then IFD1.
        u16(5)
        entry(256, 4, UInt32(previewWidth)); entry(257, 4, UInt32(previewHeight))
        entry(259, 3, 6) // JPEG compression.
        entry(513, 4, 92); entry(514, 4, UInt32(preview.count)); u32(0)
        XCTAssertEqual(tiff.count, 92)
        tiff.append(preview)
        var payload = Data([0x45, 0x78, 0x69, 0x66, 0, 0]); payload.append(tiff)
        let segmentLength = try XCTUnwrap(UInt16(exactly: payload.count + 2), "embedded JPEG must fit one APP1 segment")
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(segmentLength >> 8), UInt8(segmentLength & 255)])
        jpeg.append(payload)
        // Drop the original APP1 so there is exactly one EXIF thumbnail source.
        let original = try Data(contentsOf: url)
        var offset = 2
        while offset + 4 <= original.count, original[offset] == 0xFF {
            let marker = original[offset + 1]
            if marker == 0xDA { break }
            let length = Int(original[offset + 2]) << 8 | Int(original[offset + 3])
            if marker != 0xE1 { jpeg.append(original[offset..<(offset + 2 + length)]) }
            offset += 2 + length
        }
        jpeg.append(original[offset...])
        try jpeg.write(to: url)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "pipeline did not reach the expected boundary")
        if !condition() { throw NextPhotoTestError.boundaryTimeout }
    }
}

private enum NextPhotoTestError: Error { case boundaryTimeout }

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Each worker blocks until its name is released, recording start order.
private final class OrderedGate: @unchecked Sendable {
    private let timeout: TimeInterval
    init(timeout: TimeInterval = 10) { self.timeout = timeout }
    private let lock = NSLock()
    private var order: [String] = []
    private var running = 0
    private var released: Set<String> = []
    private var releaseEverything = false
    var started: [String] { lock.withLock { order } }
    var active: Int { lock.withLock { running } }

    func work(_ name: String) -> CGImage? {
        lock.withLock { order.append(name); running += 1 }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !lock.withLock({ releaseEverything || released.contains(name) }) {
            usleep(500)
        }
        lock.withLock { running -= 1 }
        let bytes = Data(repeating: 127, count: 4)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func release(_ name: String) { lock.withLock { _ = released.insert(name) } }
    func releaseOne() { lock.withLock { if let last = order.last { released.insert(last) } } }
    func releaseAll() { lock.withLock { releaseEverything = true } }
}
