import AppKit
import XCTest
@testable import Louppe

final class HistogramTests: XCTestCase {
    func testAnalysisUsesTheSharedNearBlackAndNearWhiteRanges() throws {
        let image = try makeImage([
            (0, 0, 0),
            (5, 5, 5),
            (128, 128, 128),
            (250, 250, 250),
            (255, 255, 255),
        ])
        let analysis = try XCTUnwrap(
            ClippingWarningProcessor.analyze(image)
        )

        XCTAssertEqual(analysis.sampleCount, 5)
        XCTAssertEqual(analysis.bins[0], 1)
        XCTAssertEqual(analysis.bins[5], 1)
        XCTAssertEqual(analysis.bins[128], 1)
        XCTAssertEqual(analysis.bins[250], 1)
        XCTAssertEqual(analysis.bins[255], 1)
        XCTAssertEqual(analysis.shadowCount, 2)
        XCTAssertEqual(analysis.highlightCount, 2)
        XCTAssertEqual(analysis.shadowPercentage, 40, accuracy: 0.001)
        XCTAssertEqual(analysis.highlightPercentage, 40, accuracy: 0.001)
    }

    func testTranslucentPremultipliedColorsUseStraightLuminanceAndValidOverlay() throws {
        let alphas: [UInt8] = [0, 3, 128, 255]
        let values = alphas.flatMap { alpha in
            [(UInt8(0), UInt8(0), UInt8(0), alpha),
             (alpha, alpha, alpha, alpha),
             (alpha / 2, alpha / 2, alpha / 2, alpha)]
        }
        let image = try makeImage(values)
        let histogram = try XCTUnwrap(ClippingWarningProcessor.analyze(image))
        XCTAssertEqual(histogram.sampleCount, 9)
        XCTAssertEqual(histogram.shadowCount, 3)
        XCTAssertEqual(histogram.highlightCount, 3,
                       "even 3/255-opacity white must remain a highlight")
        let overlay = try XCTUnwrap(ClippingWarningProcessor.overlay(on: image))
        let data = try XCTUnwrap(overlay.dataProvider?.data)
        let bytes = [UInt8](data as Data)
        for (index, original) in values.enumerated() {
            let offset = index * 4
            XCTAssertEqual(bytes[offset + 3], original.3)
            XCTAssertLessThanOrEqual(bytes[offset], original.3)
            XCTAssertLessThanOrEqual(bytes[offset + 1], original.3)
            XCTAssertLessThanOrEqual(bytes[offset + 2], original.3)
            if original.3 == 0 || index % 3 == 2 {
                XCTAssertEqual(Array(bytes[offset..<(offset + 4)]),
                               [original.0, original.1, original.2, original.3],
                               "transparent pixels and midtones stay unchanged")
            }
        }
    }

    func testOnlyValuesAboveTenPercentAreHigh() {
        XCTAssertFalse(HistogramAnalysis.isHighPercentage(9.999))
        XCTAssertFalse(HistogramAnalysis.isHighPercentage(10))
        XCTAssertTrue(HistogramAnalysis.isHighPercentage(10.001))
        XCTAssertTrue(HistogramAnalysis.isHighPercentage(61))
    }

    func testAnalysisIgnoresFullyTransparentPixels() throws {
        let image = try makeImage([
            (0, 0, 0, 0),
            (128, 128, 128, 255),
            (0, 0, 0, 0),
        ])
        let analysis = try XCTUnwrap(
            ClippingWarningProcessor.analyze(image)
        )

        XCTAssertEqual(analysis.sampleCount, 1)
        XCTAssertEqual(analysis.bins[0], 0)
        XCTAssertEqual(analysis.bins[128], 1)
        XCTAssertEqual(analysis.shadowCount, 0)
        XCTAssertEqual(analysis.highlightCount, 0)
    }

    func testOverlayMarksWarningsRedAndLeavesMidtonesUntouched() throws {
        let image = try makeImage([
            (0, 0, 0),
            (128, 128, 128),
            (255, 255, 255),
        ])
        let warned = try XCTUnwrap(
            ClippingWarningProcessor.overlay(on: image)
        )
        let pixels = try pixels(in: warned)

        XCTAssertGreaterThan(pixels[0].0, 170)
        XCTAssertLessThan(pixels[0].1, 10)
        XCTAssertLessThan(pixels[0].2, 10)
        XCTAssertEqual(pixels[1].0, 128, accuracy: 1)
        XCTAssertEqual(pixels[1].1, 128, accuracy: 1)
        XCTAssertEqual(pixels[1].2, 128, accuracy: 1)
        XCTAssertGreaterThan(pixels[2].0, 250)
        XCTAssertLessThan(pixels[2].1, 90)
        XCTAssertLessThan(pixels[2].2, 90)
    }

    func testHistogramPipelineIgnoresVideosWithoutReadingThem() async {
        let video = PhotoItem(
            id: "MISSING.MOV",
            primaryURL: URL(fileURLWithPath: "/tmp/MISSING.MOV"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .video,
            duration: 1,
            videoIsPlayable: true,
            fileSize: 1
        )

        let result = await HistogramPipeline.shared.analysis(for: video)
        XCTAssertNil(result)
    }

    func testAnalysisSourceLabelsAreExplicit() {
        XCTAssertEqual(
            HistogramAnalysisSource.renderedPreview.shortLabel,
            "Preview"
        )
        XCTAssertEqual(HistogramAnalysisSource.rawDecode.shortLabel, "RAW")
        XCTAssertEqual(
            HistogramAnalysisSource.rawDecode.detailLabel,
            "RAW decode"
        )
    }

    @MainActor
    func testHistogramLabelsIdentifyRawSourcesOnly() {
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        let analysis = HistogramAnalysis(bins: [1], sampleCount: 1,
                                         shadowCount: 0, highlightCount: 0)
        for ext in ["jpg", "JPEG", "tif", "TIFF", "png", "heic", "RAF", "dng"] {
            let item = photo(path: "/private/tmp/capture.\(ext)")
            for source in [HistogramAnalysisSource.renderedPreview, .rawDecode] {
                let view = HistogramSection(item: item, analysis: analysis, source: source,
                                            loadFailed: false, store: store)
                XCTAssertEqual(view.sourceLabel,
                               ["RAF", "dng"].contains(ext) ? source.shortLabel : nil, ext)
            }
        }
        let pending = HistogramSection(item: photo(path: "/private/tmp/capture.RAF"),
                                       analysis: nil, source: .renderedPreview,
                                       loadFailed: false, store: store)
        XCTAssertNil(pending.sourceLabel, "Pending RAW analysis must not claim a completed source")
        for ext in ["tif", "TIFF"] {
            XCTAssertFalse(RawHistogramPipeline.supportsAnalysis(for: photo(path: "/private/tmp/capture.\(ext)")))
        }
    }

    func testRawProcessorUsesLinearClippingThresholdsAndBoundedBins() throws {
        let analysis = try XCTUnwrap(
            RawHistogramProcessor.analyze(
                rgba: [
                    0, 0, 0, 1,
                    0.001, 0.001, 0.001, 1,
                    0.5, 0.5, 0.5, 1,
                    0.995, 0.995, 0.995, 1,
                    1.2, 1.2, 1.2, 1,
                    .nan, 0, 0, 1,
                    0, 0, 0, 0,
                ],
                width: 7,
                height: 1
            )
        )

        XCTAssertEqual(analysis.sampleCount, 5)
        XCTAssertEqual(analysis.shadowCount, 2)
        XCTAssertEqual(analysis.highlightCount, 2)
        XCTAssertEqual(analysis.bins[0], 2)
        XCTAssertEqual(analysis.bins[127], 1)
        XCTAssertEqual(analysis.bins[253], 1)
        XCTAssertEqual(analysis.bins[255], 1)
    }

    func testRawPipelineEligibilityUsesTheDisplayedPrimaryFile() {
        XCTAssertTrue(
            RawHistogramPipeline.supportsAnalysis(
                for: photo(path: "/tmp/capture.NEF")
            )
        )
        XCTAssertFalse(
            RawHistogramPipeline.supportsAnalysis(
                for: photo(path: "/tmp/capture.JPG")
            )
        )
    }

    func testRawPipelineCoalescesAndCachesContentRevision() async throws {
        let counter = RawDecodeCounter()
        let pipeline = RawHistogramPipeline(
            delayNanoseconds: 0,
            decoder: { _ in counter.decode() }
        )
        let item = photo(path: "/tmp/coalesced.NEF")

        async let first = pipeline.analysis(for: item)
        async let second = pipeline.analysis(for: item)
        let results = await (first, second)

        XCTAssertNotNil(results.0)
        XCTAssertNotNil(results.1)
        XCTAssertEqual(counter.value, 1)
        let cached = await pipeline.analysis(for: item)
        XCTAssertNotNil(cached)
        XCTAssertEqual(counter.value, 1)

        let replacement = PhotoItem(
            id: item.id,
            primaryURL: item.primaryURL,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            primaryModificationDate: Date(timeIntervalSince1970: 1),
            fileSize: 2
        )
        XCTAssertNotEqual(item.contentRevision, replacement.contentRevision)
        let replacementResult = await pipeline.analysis(for: replacement)
        XCTAssertNotNil(replacementResult)
        XCTAssertEqual(counter.value, 2)
    }

    func testCancelledRawCompletionCannotConsumeSameRevisionRerequest() async throws {
        let gate = RawCancellationGate()
        let pipeline = RawHistogramPipeline(delayNanoseconds: 0) { _ in
            let call = gate.nextCall()
            if call == 1 {
                gate.started.signal()
                _ = gate.release.wait(timeout: .now() + 5)
            }
            return HistogramAnalysis(bins: Array(repeating: 0, count: 256),
                                     sampleCount: 1, shadowCount: call == 1 ? 1 : 0,
                                     highlightCount: call == 1 ? 0 : 1)
        }
        let item = photo(path: "/private/tmp/\(UUID())/cancel-rerequest.NEF")
        let first = Task { await pipeline.analysis(for: item) }
        let started = await Task.detached { waitForRawDecode(gate.started) }.value
        XCTAssertEqual(started, .success)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        let renewed = Task { await pipeline.analysis(for: item) }
        try await Task.sleep(for: .milliseconds(50))
        gate.release.signal()
        let result = await renewed.value
        XCTAssertEqual(result?.shadowCount, 0)
        XCTAssertEqual(result?.highlightCount, 1,
                       "the cancelled operation must not steal the new same-key waiters")
        let cached = await pipeline.analysis(for: item)
        XCTAssertEqual(cached?.highlightCount, 1)
        XCTAssertEqual(gate.calls, 2)
    }

    func testRawPipelineCancelsDuringItsDelayWithoutDecoding() async {
        let counter = RawDecodeCounter()
        let pipeline = RawHistogramPipeline(
            delayNanoseconds: 500_000_000,
            decoder: { _ in counter.decode() }
        )
        let item = photo(path: "/tmp/cancelled.NEF")
        let task = Task { await pipeline.analysis(for: item) }

        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(counter.value, 0)
    }

    private func photo(path: String) -> PhotoItem {
        PhotoItem(
            id: URL(fileURLWithPath: path).lastPathComponent,
            primaryURL: URL(fileURLWithPath: path),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
    }

    private func makeImage(
        _ pixels: [(UInt8, UInt8, UInt8)]
    ) throws -> CGImage {
        try makeImage(pixels.map { ($0.0, $0.1, $0.2, UInt8(255)) })
    }

    private func makeImage(
        _ pixels: [(UInt8, UInt8, UInt8, UInt8)]
    ) throws -> CGImage {
        let bytes = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(bytes) as CFData)
        )
        return try XCTUnwrap(
            CGImage(
                width: pixels.count,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: pixels.count * 4,
                space: CGColorSpace(
                    name: CGColorSpace.sRGB
                ) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private func pixels(
        in image: CGImage
    ) throws -> [(Int, Int, Int)] {
        var bytes = Array(
            repeating: UInt8(0),
            count: image.width * image.height * 4
        )
        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let address = rawBytes.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpace(
                        name: CGColorSpace.sRGB
                    ) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:
                        CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
            )
            return true
        }
        XCTAssertTrue(rendered)
        return stride(from: 0, to: bytes.count, by: 4).map {
            (Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2]))
        }
    }
}

private final class RawDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func decode() -> HistogramAnalysis {
        lock.lock()
        count += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        return HistogramAnalysis(
            bins: Array(repeating: 0, count: 256),
            sampleCount: 1,
            shadowCount: 0,
            highlightCount: 0
        )
    }
}

private final class RawCancellationGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func nextCall() -> Int { lock.withLock { count += 1; return count } }
}

private func waitForRawDecode(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 5)
}
