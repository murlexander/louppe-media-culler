import AppKit
import ImageIO
import SwiftUI
import CoreImage
import XCTest
@testable import Louppe

final class FocusPeakingTests: XCTestCase {
    // MARK: Mask quality

    func testSharpDetailLightsUpWhileBlurredDetailAndSmoothGradientsStayDark() throws {
        let sharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 1200, height: 800))
        let slightlySoft = try XCTUnwrap(FocusPeakingFixture.blurred(sharp, sigma: 1.5))
        let soft = try XCTUnwrap(FocusPeakingFixture.blurred(sharp, sigma: 3))
        let gradient = try XCTUnwrap(FocusPeakingFixture.gradient(width: 1200, height: 800))

        let sharpCoverage = try coverage(of: sharp)
        let slightlySoftCoverage = try coverage(of: slightlySoft)
        let softCoverage = try coverage(of: soft)
        let gradientCoverage = try coverage(of: gradient)
        print(String(format: "FOCUS PEAKING coverage sharp %.2f%% soft1.5 %.2f%% soft3 %.2f%% gradient %.3f%%",
                     sharpCoverage, slightlySoftCoverage, softCoverage, gradientCoverage))
        XCTAssertGreaterThan(sharpCoverage, 3, "Crisp edges must light up")
        XCTAssertLessThan(slightlySoftCoverage, sharpCoverage / 4, "A 1.5-pixel blur must lose most strokes")
        XCTAssertLessThan(softCoverage, 0.05, "A clearly soft photo shows next to nothing")
        XCTAssertEqual(gradientCoverage, 0, accuracy: 0.001, "Smooth tones never mark")
    }

    func testFineSharpTextureIsMarkedButBlurredTextureAndGrainAreNot() throws {
        let (width, height) = (600, 400)
        let texture = try XCTUnwrap(FocusPeakingFixture.checkerboard(width: width, height: height, cell: 2,
                                                                     base: 0.42, contrast: 0.3))
        let sharp = try coverage(of: texture)
        let blurred = try [1.5, 2, 3].map { try coverage(of: XCTUnwrap(FocusPeakingFixture.blurred(texture, sigma: $0))) }
        // (0.10, 0.047) matches the per-pixel grain measured in deep shadows
        // of an ISO 6400 RAW at native size, where 100% tiles measure.
        let grain = try [(0.42, 0.025), (0.42, 0.04), (0.12, 0.04), (0.10, 0.047), (0.05, 0.047)].map {
            try coverage(of: XCTUnwrap(FocusPeakingFixture.flat(width: width, height: height, gray: $0.0, noise: $0.1)))
        }
        print("FOCUS PEAKING 2px texture sharp \(sharp)% blurred 1.5/2/3 \(blurred)% grain \(grain)%")
        XCTAssertGreaterThan(sharp, 50, "Sharp 2-pixel texture lights up")
        for value in blurred { XCTAssertLessThan(value, 0.1, "The same texture blurred 1.5–3 px stays dark") }
        for value in grain { XCTAssertLessThan(value, 0.1, "High-ISO-like grain on a flat field stays dark") }

        // The same patch inside the photo-like chart, measured region by region.
        let chart = try XCTUnwrap(FocusPeakingFixture.detail(width: 1200, height: 800))
        let patch = FocusPeakingFixture.fineTextureRect(width: 1200, height: 800)
        let inChart = try coverage(of: chart, in: patch)
        let inSoftChart = try coverage(of: XCTUnwrap(FocusPeakingFixture.blurred(chart, sigma: 1.5)), in: patch)
        print("FOCUS PEAKING chart fine patch sharp \(inChart)% soft1.5 \(inSoftChart)%")
        XCTAssertGreaterThan(inChart, 50)
        XCTAssertLessThan(inSoftChart, 1)
    }

    func testThinDarkLashesStayMarkedDespiteTheShadowGrainFloor() throws {
        // A one-pixel diagonal eyelash in a low-key portrait: far above grain,
        // but in the tones where the shadow floor rises.
        for (line, base) in [(0.03, 0.23), (0.05, 0.18)] {
            let lash = try XCTUnwrap(FocusPeakingFixture.lash(width: 160, height: 128, line: line, base: base))
            let pixels = try XCTUnwrap(FocusPeakingFixture.rgba(XCTUnwrap(FocusPeakingProcessor.mask(for: lash))))
            var markedRows = 0
            for row in 12..<116 where (0..<160).contains(where: { pixels[(row * 160 + $0) * 4 + 3] >= 200 }) {
                markedRows += 1
            }
            XCTAssertEqual(markedRows, 104, "Lash \(line) on \(base) is marked along its length")
        }
    }

    func testHighISONoiseStaysDarkButDoesNotHideSharpEdges() throws {
        let noisyGradient = try XCTUnwrap(FocusPeakingFixture.gradient(width: 1200, height: 800, noise: 0.025))
        let noisySharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 1200, height: 800, noise: 0.025))
        let noisySoft = try XCTUnwrap(FocusPeakingFixture.blurred(FocusPeakingFixture.detail(width: 1200, height: 800),
                                                                  sigma: 3, noise: 0.025))
        let gradientCoverage = try coverage(of: noisyGradient)
        let softCoverage = try coverage(of: noisySoft)
        let sharpCoverage = try coverage(of: noisySharp)
        print(String(format: "FOCUS PEAKING noisy gradient %.3f%% noisy soft %.3f%% noisy sharp %.2f%%",
                     gradientCoverage, softCoverage, sharpCoverage))
        XCTAssertLessThan(gradientCoverage, 0.2, "Grain must not light up smooth areas")
        XCTAssertLessThan(softCoverage, 0.3, "Grain must not make a soft photo look sharp")
        XCTAssertGreaterThan(sharpCoverage, 3)
    }

    func testStrokesAreTheOpaqueAccentTintAndEverythingElseIsTransparent() throws {
        let sharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 600, height: 400))
        let mask = try XCTUnwrap(FocusPeakingProcessor.mask(for: sharp))
        XCTAssertEqual(mask.width, 600)
        XCTAssertEqual(mask.height, 400)
        let pixels = try XCTUnwrap(FocusPeakingFixture.rgba(mask))
        var opaque = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] == 255 {
            opaque += 1
            XCTAssertEqual(Int(pixels[index]), 0xEB, accuracy: 2)
            XCTAssertEqual(Int(pixels[index + 1]), 0x80, accuracy: 2)
            XCTAssertEqual(Int(pixels[index + 2]), 0xFF, accuracy: 2)
            if opaque > 2_000 { break }
        }
        XCTAssertGreaterThan(opaque, 500)
        let flat = try XCTUnwrap(FocusPeakingFixture.gradient(width: 300, height: 200))
        let flatPixels = try XCTUnwrap(FocusPeakingFixture.rgba(XCTUnwrap(FocusPeakingProcessor.mask(for: flat))))
        XCTAssertTrue(flatPixels.allSatisfy { $0 == 0 }, "No stroke means fully transparent pixels")
    }

    // MARK: 100% tiles

    func testPeakingTilesMeetTheWholeImageAcrossTileSeams() async throws {
        let sharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 2048, height: 1024))
        let image = CIImage(cgImage: sharp)
        let source = ZoomImageSource(key: "peaking-seams-\(UUID())", image: image, pixelSize: image.extent.size)
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 2, source: { _, _, _ in nil })
        let leftTile = await pipeline.tile(for: source, coordinate: .init(column: 0, row: 0), showsFocusPeaking: true)
        let rightTile = await pipeline.tile(for: source, coordinate: .init(column: 1, row: 0), showsFocusPeaking: true)
        let plainTile = await pipeline.tile(for: source, coordinate: .init(column: 0, row: 0))
        let left = try XCTUnwrap(leftTile)
        let right = try XCTUnwrap(rightTile)
        let plain = try XCTUnwrap(plainTile)
        XCTAssertNotEqual(FocusPeakingFixture.rgba(left.image), FocusPeakingFixture.rgba(plain.image),
                          "Peaking is part of the tile key and its pixels")

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let whole = try XCTUnwrap(context.createCGImage(FocusPeakingProcessor.overlay(for: image).composited(over: image),
                                                        from: image.extent, format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let wholePixels = try XCTUnwrap(FocusPeakingFixture.rgba(whole))
        let leftPixels = try XCTUnwrap(FocusPeakingFixture.rgba(left.image))
        let rightPixels = try XCTUnwrap(FocusPeakingFixture.rgba(right.image))
        var largest = 0
        var strokesNearSeam = 0
        for row in 0..<1024 {
            for column in 1016..<1032 {
                let tile = column < 1024 ? leftPixels : rightPixels
                let tileColumn = column < 1024 ? column : column - 1024
                for channel in 0..<4 {
                    let a = Int(tile[(row * 1024 + tileColumn) * 4 + channel])
                    let b = Int(wholePixels[(row * 2048 + column) * 4 + channel])
                    largest = max(largest, abs(a - b))
                }
                let index = (row * 1024 + tileColumn) * 4
                if tile[index] == 0xEB, tile[index + 1] == 0x80 { strokesNearSeam += 1 }
            }
        }
        XCTAssertGreaterThan(strokesNearSeam, 20, "The fixture crosses the seam with crisp edges")
        XCTAssertLessThanOrEqual(largest, 3, "Tiles see their neighbours, so the seam is invisible")
    }

    func testClippingAndPeakingTogetherKeepBothMarks() async throws {
        let sharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 1024, height: 1024))
        let image = CIImage(cgImage: sharp)
        let source = ZoomImageSource(key: "peaking-clipping-\(UUID())", image: image, pixelSize: image.extent.size)
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 2, source: { _, _, _ in nil })
        let rendered = await pipeline.tile(for: source, coordinate: .init(column: 0, row: 0),
                                           showsClippingWarnings: true, showsFocusPeaking: true)
        let tile = try XCTUnwrap(rendered)
        let pixels = try XCTUnwrap(FocusPeakingFixture.rgba(tile.image))
        var strokes = 0
        var tinted = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let (red, green, blue) = (pixels[index], pixels[index + 1], pixels[index + 2])
            if abs(Int(red) - 0xEB) <= 2, abs(Int(green) - 0x80) <= 2, abs(Int(blue) - 0xFF) <= 2 { strokes += 1 }
            // ClippingWarningProcessor blends 72% red into near-white and near-black.
            if red > 180, green < 80, blue < 80 { tinted += 1 }
        }
        XCTAssertGreaterThan(strokes, 1_000, "Strokes stay on top of the clipping tint")
        XCTAssertGreaterThan(tinted, 10_000, "Clipping tint remains readable around strokes")
    }

    // MARK: Zoom canvas below 100%

    @MainActor
    func testZoomCanvasBelowActualSizeDrawsFitStrokesOverPreviewPixels() async throws {
        _ = NSApplication.shared
        let sharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 800, height: 600))
        let preview = NSImage(cgImage: sharp, size: .zero)
        let layer = NSImage(cgImage: try XCTUnwrap(FocusPeakingProcessor.mask(for: sharp)), size: .zero)
        let source = ZoomImageSource(key: "below-100-\(UUID())", image: CIImage(cgImage: sharp),
                                     pixelSize: CGSize(width: 800, height: 600))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: 450),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scrollView = ActualSizeScrollView(sourceLoader: { _, _ in source })
        scrollView.frame = window.contentView!.bounds
        window.contentView = scrollView
        defer { scrollView.prepareForRemoval(); window.close() }
        let item = PhotoItem(id: "BELOW.JPG", primaryURL: URL(fileURLWithPath: "/tmp/BELOW.JPG"), pairedURL: nil,
                             captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        func configure(peaking: Bool) {
            scrollView.configure(item: item, preview: preview, showsClippingWarnings: false,
                                 showsFocusPeaking: peaking, peakingLayer: layer,
                                 viewport: ActualSizeViewport(), onLoading: { _ in }, zoomScale: 0.5)
            scrollView.layoutSubtreeIfNeeded()
        }
        configure(peaking: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while scrollView.displayedSourceKey == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(scrollView.displayedSourceKey, source.key)
        XCTAssertLessThan(scrollView.magnification, 1, "Below 100% the canvas draws preview pixels, not tiles")
        XCTAssertGreaterThan(try strokePixels(in: scrollView), 1_000, "Peaking must show below 100%")
        configure(peaking: false)
        XCTAssertEqual(try strokePixels(in: scrollView), 0, "Off draws no strokes")
    }

    /// A pinch from 100% to 99.95% switches the canvas to preview pixels,
    /// while the store ignores a change that small: strokes must still show.
    @MainActor
    func testPinchJustBelowActualSizeShowsStrokesWithoutAStoreZoomChange() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FocusPeaking-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("PINCH.jpg")
        let chart = try XCTUnwrap(FocusPeakingFixture.detail(width: 1200, height: 800))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, chart, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let item = PhotoItem(id: "PINCH.jpg", primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil,
                             lensModel: nil, primaryModificationDate: values.contentModificationDate,
                             fileSize: Int64(try XCTUnwrap(values.fileSize)))
        let view = FullImageView(item: item, zoomMode: .constant(.actual), showsFocusPeaking: true,
                                 actualSizeViewport: ActualSizeViewport(), zoomScale: 1,
                                 onZoomToActual: { _ in }, onZoomToFit: {},
                                 onZoomScaleChanged: { _, _ in })   // the store keeps 100%
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        defer { window.contentView = nil; window.close() }

        func scrollView() -> ActualSizeScrollView? {
            var stack: [NSView] = [window.contentView].compactMap { $0 }
            while let next = stack.popLast() {
                if let found = next as? ActualSizeScrollView { return found }
                stack += next.subviews
            }
            return nil
        }
        func eventually(_ condition: () throws -> Bool) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                if try condition() { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        let loaded = try await eventually { scrollView()?.displayedSourceKey != nil }
        XCTAssertTrue(loaded, "The 100% source loads")
        let scroll = try XCTUnwrap(scrollView())
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.0001)
        scroll.setMagnification(0.9995, centeredAt: CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
        scroll.didChangeNativeMagnification(ended: false)
        scroll.didChangeNativeMagnification(ended: true)
        XCTAssertLessThan(scroll.magnification, 1)
        let marked = try await eventually { try strokePixels(in: scroll) > 1_000 }
        XCTAssertTrue(marked, "Strokes appear over preview pixels just below 100%")
    }

    @MainActor
    private func strokePixels(in scrollView: NSScrollView) throws -> Int {
        let view = try XCTUnwrap(scrollView.documentView)
        view.display()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let converted = try XCTUnwrap(rep.cgImage)
        let pixels = try XCTUnwrap(FocusPeakingFixture.rgba(converted))
        var count = 0
        // The preview is neutral gray; scaled strokes stay strongly purple.
        for index in stride(from: 0, to: pixels.count, by: 4)
            where Int(pixels[index + 2]) - Int(pixels[index + 1]) > 60 { count += 1 }
        return count
    }

    // MARK: Pipeline

    func testRetiredOnlyWaiterDropsQueuedWorkAndALaterRequestComputesOnceThenHitsTheCache() async throws {
        let sharp = try XCTUnwrap(FocusPeakingFixture.detail(width: 300, height: 200))
        let calls = FocusPeakingCallCounter()
        let queue = OperationQueue()
        queue.isSuspended = true
        let pipeline = FocusPeakingPipeline(operationQueue: queue) { image in
            calls.increment()
            return FocusPeakingProcessor.mask(for: image)
        }
        let key = FocusPeakingPipeline.key(representation: "item|rev", source: sharp)
        XCTAssertTrue(key.hasSuffix("|300x200"), "Keys carry the pixel size the layer was measured on")
        let abandoned = Task { await pipeline.mask(forKey: key, source: sharp) }
        try await waitUntil { pipeline.waiterCountForTesting(key: key) == 1 }
        abandoned.cancel()
        let abandonedResult = await abandoned.value
        XCTAssertNil(abandonedResult)
        XCTAssertEqual(pipeline.waiterCountForTesting(key: key), 0)
        queue.isSuspended = false
        await pipeline.waitForWorkForTesting()
        XCTAssertEqual(calls.value, 0, "A retired request never renders")
        XCTAssertNil(pipeline.cachedMask(forKey: key))

        let first = await pipeline.mask(forKey: key, source: sharp)
        let second = await pipeline.mask(forKey: key, source: sharp)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertTrue(pipeline.cachedMask(forKey: key) === first)
        XCTAssertEqual(calls.value, 1)
    }

    // MARK: Speed

    func testPeakingComputeTimeAtDisplaySizes() throws {
        var report: [String] = []
        for (width, height) in [(2560, 1707), (4096, 2731), (5120, 3413)] {
            let source = try XCTUnwrap(FocusPeakingFixture.detail(width: width, height: height))
            _ = FocusPeakingProcessor.mask(for: source)   // first use builds the context
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                XCTAssertNotNil(FocusPeakingProcessor.mask(for: source))
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            let median = samples.sorted()[2]
            report.append(String(format: "%dx%d median %.1f ms (min %.1f)", width, height, median, samples.min() ?? 0))
            XCTAssertLessThan(median, CITimingBudget.scaled(400, onCI: 5), "\(width)x\(height)")
        }
        print("FOCUS PEAKING compute: " + report.joined(separator: "; "))
    }

    // MARK: Helpers

    private func coverage(of image: CGImage, in region: CGRect? = nil) throws -> Double {
        let mask = try XCTUnwrap(FocusPeakingProcessor.mask(for: image))
        let pixels = try XCTUnwrap(FocusPeakingFixture.rgba(mask))
        let area = region ?? CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        // Bitmap rows run top-down; regions use Core Graphics' bottom-left origin.
        var marked = 0, total = 0
        for row in (mask.height - Int(area.maxY))..<(mask.height - Int(area.minY)) {
            for column in Int(area.minX)..<Int(area.maxX) {
                total += 1
                if pixels[(row * mask.width + column) * 4 + 3] >= 128 { marked += 1 }
            }
        }
        return Double(marked) * 100 / Double(total)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class FocusPeakingCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Deterministic photo-like content: edges, fine lines, text, circles and
/// texture at several contrasts over a mid-tone background.
enum FocusPeakingFixture {
    static func detail(width: Int, height: Int, noise: Double = 0, bright: Bool = false) -> CGImage? {
        guard let context = bitmap(width: width, height: height) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(gray: bright ? 0.82 : 0.42, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Large tonal blocks, including near-white and near-black for clipping.
        context.setFillColor(gray: 0.98, alpha: 1)
        context.fill(CGRect(x: w * 0.05, y: h * 0.55, width: w * 0.25, height: h * 0.35))
        context.setFillColor(gray: 0.02, alpha: 1)
        context.fill(CGRect(x: w * 0.68, y: h * 0.08, width: w * 0.24, height: h * 0.3))
        // Stripes from 1 to 6 pixels wide at two contrasts.
        var x = w * 0.35
        for width in 1...6 {
            for contrast in [0.15, 0.5] {
                context.setFillColor(gray: (bright ? 0.82 : 0.42) + (bright ? -contrast : contrast), alpha: 1)
                context.fill(CGRect(x: x, y: h * 0.1, width: CGFloat(width), height: h * 0.8))
                x += CGFloat(width) * 4 + 6
            }
        }
        // Lines and circles across the whole frame, crossing every tile seam.
        context.setLineWidth(2)
        for index in 0..<24 {
            let t = CGFloat(index) / 24
            context.setStrokeColor(gray: index.isMultiple(of: 2) ? 0.1 : 0.9, alpha: 1)
            context.move(to: CGPoint(x: 0, y: h * t))
            context.addLine(to: CGPoint(x: w, y: h * (1 - t) * 0.9))
            context.strokePath()
            context.strokeEllipse(in: CGRect(x: w * t, y: h * 0.5 * t, width: 40 + 120 * t, height: 40 + 120 * t))
        }
        // Checker texture.
        for row in 0..<20 {
            for column in 0..<40 where (row + column).isMultiple(of: 2) {
                context.setFillColor(gray: 0.7, alpha: 1)
                context.fill(CGRect(x: w * 0.4 + CGFloat(column) * 6, y: h * 0.62 + CGFloat(row) * 6, width: 6, height: 6))
            }
        }
        // Fine texture: a 2-pixel checkerboard, the scale of fabric or hair.
        let fine = fineTextureRect(width: width, height: height)
        context.setFillColor(gray: bright ? 0.82 : 0.42, alpha: 1)
        context.fill(fine)
        context.setFillColor(gray: bright ? 0.52 : 0.72, alpha: 1)
        for y in stride(from: Int(fine.minY), to: Int(fine.maxY), by: 2) {
            for x in stride(from: Int(fine.minX), to: Int(fine.maxX), by: 2) where ((x + y) / 2).isMultiple(of: 2) {
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        // Text.
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(18, h * 0.05)),
                                                         .foregroundColor: NSColor(white: 0.05, alpha: 1)]
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for line in 0..<4 {
            NSAttributedString(string: "Louppe focus check 0123456789", attributes: attributes)
                .draw(at: CGPoint(x: w * 0.06, y: h * (0.12 + CGFloat(line) * 0.08)))
        }
        NSGraphicsContext.restoreGraphicsState()
        if noise > 0 { addNoise(context, amount: noise) }
        return context.makeImage()
    }

    /// The chart's fine-texture patch, in Core Graphics (bottom-left) pixels.
    static func fineTextureRect(width: Int, height: Int) -> CGRect {
        func even(_ value: Int) -> Int { value / 2 * 2 }
        return CGRect(x: even(width * 62 / 100), y: even(height * 44 / 100),
                      width: even(width * 12 / 100), height: even(height * 10 / 100))
    }

    static func checkerboard(width: Int, height: Int, cell: Int, base: Double, contrast: Double) -> CGImage? {
        guard let context = bitmap(width: width, height: height) else { return nil }
        context.setFillColor(gray: base, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: base + contrast, alpha: 1)
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) where ((x + y) / cell).isMultiple(of: 2) {
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return context.makeImage()
    }

    /// A one-pixel diagonal line of sRGB gray `line` on `base`.
    static func lash(width: Int, height: Int, line: Double, base: Double) -> CGImage? {
        guard let context = bitmap(width: width, height: height) else { return nil }
        context.setFillColor(red: base, green: base, blue: base, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: line, green: line, blue: line, alpha: 1)
        for step in 8..<(height - 8) { context.fill(CGRect(x: step + 20, y: step, width: 1, height: 1)) }
        return context.makeImage()
    }

    static func flat(width: Int, height: Int, gray: Double, noise: Double) -> CGImage? {
        guard let context = bitmap(width: width, height: height) else { return nil }
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        addNoise(context, amount: noise)
        return context.makeImage()
    }

    static func gradient(width: Int, height: Int, noise: Double = 0) -> CGImage? {
        guard let context = bitmap(width: width, height: height),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [NSColor(srgbRed: 0.05, green: 0.08, blue: 0.2, alpha: 1).cgColor,
                                                 NSColor(srgbRed: 0.95, green: 0.85, blue: 0.7, alpha: 1).cgColor] as CFArray,
                                        locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // A soft glow that fades to nothing: no hard rim.
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [NSColor(white: 1, alpha: 0.5).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            let center = CGPoint(x: width / 3, y: height / 2)
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(height) / 2, options: [])
        }
        if noise > 0 { addNoise(context, amount: noise) }
        return context.makeImage()
    }

    static func blurred(_ image: CGImage?, sigma: Double, noise: Double = 0) -> CGImage? {
        guard let image else { return nil }
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        guard let blurred = CIContext().createCGImage(output, from: input.extent, format: .RGBA8,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        guard noise > 0, let context = bitmap(width: image.width, height: image.height) else { return blurred }
        context.draw(blurred, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        addNoise(context, amount: noise)
        return context.makeImage()
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        guard let context = bitmap(width: image.width, height: image.height, clear: true) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    private static func bitmap(width: Int, height: Int, clear: Bool = false) -> CGContext? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        if clear { context?.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        return context
    }

    /// Gaussian luminance noise of standard deviation `amount` (0...1), seeded.
    private static func addNoise(_ context: CGContext, amount: Double) {
        guard let data = context.data else { return }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for pixel in 0..<(context.width * context.height) {
            let gaussian = sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform())
            let delta = gaussian * amount * 255
            for channel in 0..<3 {
                let index = pixel * 4 + channel
                bytes[index] = UInt8(max(0, min(255, Double(bytes[index]) + delta)))
            }
        }
    }
}
