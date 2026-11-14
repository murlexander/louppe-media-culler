import AppKit
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// Source decodes per visited photo, counted by the pipelines themselves.
/// JPEG bytes named `.jxl` exercise the whole-image extension rule.
@MainActor
final class DecodeBudgetTests: XCTestCase {
    // MARK: Whole budget

    func testVisitedWholeImagePhotoDecodesItsSourceTwice() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount Gallery") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = try jpegItem(in: root, name: "visited.jxl")
        let pipeline = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache"))
        let histograms = HistogramPipeline(imagePipeline: pipeline)
        // The mounted view dwells on the shared recipe pipeline.
        let recipes = HighResolutionImagePipeline.shared
        recipes.forgetWholeImageZoomForTesting()
        let recipesBefore = recipes.recipeBuildsForTesting
        let tile = Task { await pipeline.thumbnail(for: photo) }
        var representations: [PhotoRepresentation] = []
        let host = NSHostingView(rootView: FullImageView(
            item: photo, zoomMode: .constant(.fit), actualSizeViewport: ActualSizeViewport(),
            onZoomToActual: { _ in }, onZoomToFit: {},
            onRepresentation: { representation, _ in representations.append(representation) }, imagePipeline: pipeline))
        let window = mount(host)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return representations.last == .preview
        }
        // Info asks once the photo has settled.
        let histogram = await histograms.analysis(for: photo)
        XCTAssertNotNil(histogram)
        _ = await tile.value
        // Stay well past the 500 ms recipe dwell.
        try await Task.sleep(for: .milliseconds(900))
        await recipes.waitForSourceWorkForTesting()
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(pipeline.sourceDecodesForTesting.thumbnail, 1)
        XCTAssertEqual(pipeline.sourceDecodesForTesting.full, 1)
        XCTAssertEqual(histograms.sourceDecodesForTesting, 0, "Info must measure the Fit preview")
        XCTAssertEqual(recipes.recipeBuildsForTesting - recipesBefore, 0, "no 100% recipe before 100% is used")
    }

    func testExactCueAskedBeforeGalleryRegistersItsFitDecodesNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FitDecodeGate()
        defer { gate.releaseAll() }
        let pipeline = gatedPipeline(root: root.appendingPathComponent("cache"), gate: gate)
        let histograms = HistogramPipeline(imagePipeline: pipeline)
        let photo = try jpegItem(in: root, name: "ordered.jxl")
        // The cue asks first: no Fit to share, and no decode of its own.
        guard case .noFit = await histograms.sharedFitAnalysis(for: photo) else {
            return XCTFail("Nothing is cached or decoding yet")
        }
        XCTAssertEqual(histograms.waiterCountForTesting(for: photo), 0)
        // Gallery registers its Fit; the cue asks again while it decodes.
        let gallery = Task { await pipeline.fullImage(for: photo) != nil }
        try await waitUntil { gate.started == ["ordered.jxl"] }
        let cue = Task { await histograms.sharedFitAnalysis(for: photo) }
        try await waitUntil { pipeline.decodeWaiterCountForTesting(for: photo, full: true) == 2 }
        // A photo no longer shown gives its place up without a decode.
        let retired = Task { await histograms.sharedFitAnalysis(for: photo) }
        try await waitUntil { pipeline.decodeWaiterCountForTesting(for: photo, full: true) == 3 }
        retired.cancel()
        guard case .noFit = await retired.value else { return XCTFail("A retired request measures nothing") }
        XCTAssertEqual(pipeline.decodeWaiterCountForTesting(for: photo, full: true), 2)
        gate.releaseAll()
        guard case .measured(let analysis) = await cue.value else { return XCTFail("The shared Fit is measured") }
        XCTAssertGreaterThan(analysis.sampleCount, 0)
        let shown = await gallery.value
        XCTAssertTrue(shown)
        XCTAssertEqual(gate.started, ["ordered.jxl"])
        XCTAssertEqual(pipeline.sourceDecodesForTesting.full, 1)
        XCTAssertEqual(histograms.sourceDecodesForTesting, 0, "The cue measured Gallery's pixels")
    }

    // MARK: 100% recipe dwell

    func testFitDwellBuildsNoWholeImageRecipeBeforeZoom() async {
        let pipeline = recipePipeline()
        let photo = item("dwell.jxl")
        await pipeline.warmSource(for: photo)
        await pipeline.waitForSourceWorkForTesting()
        XCTAssertEqual(pipeline.recipeBuildsForTesting, 0)
        XCTAssertFalse(pipeline.sourceIsCachedForTesting(for: photo))
    }

    func testFitDwellWarmsAfterFirstZoom() async {
        let pipeline = recipePipeline()
        let zoomed = await pipeline.source(for: item("zoomed.jxl"))
        XCTAssertNotNil(zoomed)
        let next = item("next.jxl")
        await pipeline.warmSource(for: next)
        XCTAssertEqual(pipeline.recipeBuildsForTesting, 2)
        XCTAssertTrue(pipeline.sourceIsCachedForTesting(for: next))
    }

    func testFitDwellStillWarmsLazyFormats() async {
        let pipeline = recipePipeline()
        let photos = [item("lazy.JPG"), item("lazy.RAF"), item("lazy.HEIC")]
        for photo in photos { await pipeline.warmSource(for: photo) }
        XCTAssertEqual(pipeline.recipeBuildsForTesting, 3)
        XCTAssertTrue(photos.allSatisfy { pipeline.sourceIsCachedForTesting(for: $0) })
    }

    // MARK: Fit request debounce

    func testIsolatedStepRequestsFitImmediately() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount Gallery") }
        // A debounced request could not register within this test's deadlines.
        FullImageView.fitRequestTimingForTesting = (debounceNanoseconds: 30_000_000_000, isolatedStepInterval: .milliseconds(150))
        defer { FullImageView.fitRequestTimingForTesting = nil }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FitDecodeGate()
        defer { gate.releaseAll() }
        let pipeline = gatedPipeline(root: root, gate: gate)
        let first = item("first.jxl"), second = item("second.jxl")
        let host = NSHostingView(rootView: view(first, pipeline: pipeline))
        let window = mount(host)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return pipeline.decodeWaiterCountForTesting(for: first, full: true) == 1
        }
        try await Task.sleep(for: .milliseconds(250))
        host.rootView = view(second, pipeline: pipeline)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return pipeline.decodeWaiterCountForTesting(for: second, full: true) == 1
        }
        XCTAssertEqual(gate.started, ["first.jxl", "second.jxl"])
    }

    func testKeyRepeatStartsAtMostTwoFitDecodes() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount Gallery") }
        // Stretched so slow steps on a busy machine still count as key repeat.
        FullImageView.fitRequestTimingForTesting = (debounceNanoseconds: 1_000_000_000, isolatedStepInterval: .seconds(60))
        defer { FullImageView.fitRequestTimingForTesting = nil }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FitDecodeGate()
        defer { gate.releaseAll() }
        let pipeline = gatedPipeline(root: root, gate: gate)
        let photos = (1...5).map { item("step-\($0).jxl") }
        // The first step is isolated: it decodes at once and keeps its lane.
        let host = NSHostingView(rootView: view(photos[0], pipeline: pipeline))
        let window = mount(host)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return gate.started == ["step-1.jxl"]
        }
        for photo in photos.dropFirst() {
            try await Task.sleep(for: .milliseconds(20))
            host.rootView = view(photo, pipeline: pipeline)
            host.layoutSubtreeIfNeeded()
        }
        // Of the repeated steps only the last outlives its debounce.
        try await waitUntil { gate.started.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(gate.started, ["step-1.jxl", "step-5.jxl"])
        XCTAssertEqual(pipeline.sourceDecodesForTesting.full, 2)
    }

    // MARK: Helpers

    private func view(_ photo: PhotoItem, pipeline: ImagePipeline) -> FullImageView {
        FullImageView(item: photo, zoomMode: .constant(.fit), actualSizeViewport: ActualSizeViewport(),
                      onZoomToActual: { _ in }, onZoomToFit: {}, imagePipeline: pipeline)
    }

    private func gatedPipeline(root: URL, gate: FitDecodeGate) -> ImagePipeline {
        ImagePipeline(testingDiskCacheRoot: root, fullConcurrency: 2) { url, bound in
            bound == ImagePipeline.fullPixelSize ? gate.decode(url) : decodeBudgetImage()
        }
    }

    private func recipePipeline() -> HighResolutionImagePipeline {
        HighResolutionImagePipeline(testingSourceConcurrency: 2) { revision, key, decoder in
            ZoomImageSource(key: key, image: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
                            pixelSize: CGSize(width: 1, height: 1), sourceRevision: revision, decoder: decoder)
        }
    }

    private func item(_ name: String, url: URL? = nil) -> PhotoItem {
        PhotoItem(id: name, primaryURL: url ?? URL(fileURLWithPath: "/private/tmp/louppe-decode-budget-synthetic/\(name)"),
                  pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
    }

    private func jpegItem(in root: URL, name: String) throws -> PhotoItem {
        let source = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(decodeBudgetImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return item(name, url: source)
    }

    private func mount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        return window
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/louppe-decode-budget-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Decode condition did not settle before deadline")
                throw NSError(domain: "DecodeBudgetTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Each Fit decode records its file and blocks until the test ends.
private final class FitDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var released = false
    var started: [String] { lock.withLock { order } }

    func decode(_ url: URL) -> CGImage? {
        lock.withLock { order.append(url.lastPathComponent) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !lock.withLock({ released }) { usleep(500) }
        return decodeBudgetImage()
    }

    func releaseAll() { lock.withLock { released = true } }
}

private func decodeBudgetImage() -> CGImage? {
    guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return context.makeImage()
}
