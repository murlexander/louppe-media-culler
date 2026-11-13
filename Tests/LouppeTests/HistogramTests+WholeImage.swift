import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// Whole-image formats measure the Fit preview. JPEG bytes named `.jxl`
/// exercise the extension rule with a decoder every Mac has.
extension HistogramTests {
    func testWholeImageHistogramUsesCachedFit() async throws {
        let folder = try wholeImageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try wholeImagePhoto(in: folder, name: "cached.jxl")
        let images = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"))
        let fit = await images.fullImage(for: item)
        XCTAssertNotNil(fit)
        let pipeline = HistogramPipeline(imagePipeline: images)
        let analysis = await pipeline.analysis(for: item)
        XCTAssertEqual(analysis?.sampleCount, 64 * 64)
        XCTAssertEqual(pipeline.sourceDecodesForTesting, 0)
        XCTAssertEqual(images.sourceDecodesForTesting.full, 1)
    }

    func testWholeImageHistogramJoinsInFlightFit() async throws {
        let folder = try wholeImageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try wholeImagePhoto(in: folder, name: "decoding.jxl")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let images = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"), fullConcurrency: 1) { url, bound in
            _ = wholeImageWait(release)
            return ImagePipeline.decodeImage(url: url, maxPixel: bound)
        }
        let pipeline = HistogramPipeline(imagePipeline: images)
        let fit = Task { await images.fullImage(for: item) }
        try await wholeImageEventually { images.sourceDecodesForTesting.full == 1 }
        let info = Task { await pipeline.analysis(for: item) }
        try await wholeImageEventually { images.decodeWaiterCountForTesting(for: item, full: true) == 2 }
        XCTAssertEqual(pipeline.waiterCountForTesting(for: item), 0, "nothing is queued on the histogram lane yet")
        release.signal()
        let analysis = await info.value
        let image = await fit.value
        XCTAssertNotNil(image)
        XCTAssertEqual(analysis?.sampleCount, 64 * 64)
        XCTAssertEqual(images.sourceDecodesForTesting.full, 1, "one Fit decode in total")
        XCTAssertEqual(pipeline.sourceDecodesForTesting, 0)
    }

    func testCancelledWholeImageHistogramLeavesFitToItsViewer() async throws {
        let folder = try wholeImageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try wholeImagePhoto(in: folder, name: "left.jxl")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let images = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"), fullConcurrency: 1) { url, bound in
            _ = wholeImageWait(release)
            return ImagePipeline.decodeImage(url: url, maxPixel: bound)
        }
        let pipeline = HistogramPipeline(imagePipeline: images)
        let fit = Task { await images.fullImage(for: item) }
        try await wholeImageEventually { images.sourceDecodesForTesting.full == 1 }
        let info = Task { await pipeline.analysis(for: item) }
        try await wholeImageEventually { images.decodeWaiterCountForTesting(for: item, full: true) == 2 }
        info.cancel()
        let cancelled = await info.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(images.decodeWaiterCountForTesting(for: item, full: true), 1)
        release.signal()
        let image = await fit.value
        XCTAssertNotNil(image)
        XCTAssertEqual(pipeline.sourceDecodesForTesting, 0)
        XCTAssertEqual(pipeline.waiterCountForTesting(for: item), 0)
    }

    func testWholeImageHistogramPathsAgree() async throws {
        let folder = try wholeImageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Larger than the Fit bound, so both the bounded decode and the reduction run.
        let item = try wholeImagePhoto(in: folder, name: "agree.jxl", width: 4800, height: 3200)
        // Grid: no Fit is cached or decoding, and the background walk starts none.
        let gridImages = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("grid-cache"))
        let grid = HistogramPipeline(foregroundWork: ForegroundWorkCoordinator(quietInterval: .zero), imagePipeline: gridImages)
        let walked = await grid.analysis(for: item, purpose: .backgroundQuality)
        XCTAssertEqual(grid.sourceDecodesForTesting, 1)
        XCTAssertEqual(gridImages.sourceDecodesForTesting.full, 0)
        XCTAssertNil(gridImages.cachedFullImage(for: item), "the histogram's own decode is not cached")
        // Gallery: Info measures the preview on screen.
        let galleryImages = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("gallery-cache"))
        let fit = await galleryImages.fullImage(for: item)
        XCTAssertEqual(fit?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 4096)
        let gallery = HistogramPipeline(imagePipeline: galleryImages)
        let shown = await gallery.analysis(for: item)
        XCTAssertEqual(gallery.sourceDecodesForTesting, 0)
        let analysis = try XCTUnwrap(shown)
        XCTAssertEqual(walked, analysis, "equal bins and counts")
        XCTAssertEqual(analysis.width, 1024)
        XCTAssertEqual(analysis.height, 683)
        XCTAssertEqual(analysis.sampleCount, 1024 * 683)
        XCTAssertGreaterThan(analysis.shadowCount, 0)
        XCTAssertGreaterThan(analysis.highlightCount, 0)
    }

    func testOtherFormatsKeepV1Path() async throws {
        let folder = try wholeImageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try wholeImagePhoto(in: folder, name: "plain.jpg", width: 4800, height: 3200)
        let images = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"))
        let fit = await images.fullImage(for: item)
        XCTAssertNotNil(fit)
        let pipeline = HistogramPipeline(imagePipeline: images)
        let analysis = await pipeline.analysis(for: item)
        XCTAssertEqual(pipeline.sourceDecodesForTesting, 1, "only whole-image formats measure the Fit preview")
        let expected = ImagePipeline.decodeImage(url: item.primaryURL, maxPixel: HistogramPipeline.analysisPixelSize)
            .flatMap(ClippingWarningProcessor.analyze)
        XCTAssertNotNil(expected)
        XCTAssertEqual(analysis, expected)
    }
}

private func wholeImageFolder() throws -> URL {
    let folder = URL(fileURLWithPath: "/private/tmp/louppe-whole-image-histogram-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A diagonal ramp with clipped ends, so every bin and both warning zones are populated.
private func wholeImagePhoto(in folder: URL, name: String, width: Int = 64, height: Int = 64) throws -> PhotoItem {
    let url = folder.appendingPathComponent(name)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray
    let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: colors, locations: [0.1, 0.9]))
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return PhotoItem(id: name, primaryURL: url, pairedURL: nil, captureDate: nil,
                     cameraModel: nil, lensModel: nil, fileSize: 1)
}

private func wholeImageWait(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 10)
}

private func wholeImageEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    guard condition() else {
        XCTFail("Timed out waiting for the whole-image histogram state")
        throw NSError(domain: "HistogramTests", code: 1)
    }
}
