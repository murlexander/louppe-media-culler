import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class LouppeSpeedRAWTests: XCTestCase {
    func testOptInRealRAWPreviewAndHistogram() async throws {
        try SpeedBenchmark.requireEnabled()
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_SPEED_RAW_FILE"] else {
            throw XCTSkip("Set LOUPPE_SPEED_RAW_FILE to a local RAW; only a disposable copy is decoded")
        }
        let source = URL(fileURLWithPath: path)
        let identity = try FileOperationJournal.captureIdentity(at: source)
        let originalHash = try digest(source)
        let root = URL(fileURLWithPath: "/private/tmp/louppe-speed-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture").appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: url)
        XCTAssertEqual(try digest(url), originalHash)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let item = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
                             captureDate: nil, cameraModel: nil, lensModel: nil,
                             primaryModificationDate: values.contentModificationDate,
                             fileSize: Int64(values.fileSize ?? 0))
        XCTAssertTrue(RawHistogramPipeline.supportsAnalysis(for: item))
        XCTAssertNotNil(item.primaryFile.scannedIdentity)
        let report = SpeedReport(suite: "media-real-raw")
        var image: CGImage?
        try await report.measureAsync(name: "raw.fast-preview.320px", count: 1) {
            image = await Task.detached {
                autoreleasepool { ImagePipeline.decodeImage(url: url, maxPixel: 320) }
            }.value
        }
        XCTAssertNotNil(image)
        for bound in [1_024, 4_096] {
            try await report.measureAsync(name: "raw.apple-default.preview.\(bound)px", count: 1) {
                image = await Task.detached {
                    autoreleasepool { RawImageRendering.preview(url: url, maximumPixelSize: CGFloat(bound), decoder: .appleDefault) }
                }.value
            }
            let rendered = try XCTUnwrap(image)
            XCTAssertLessThanOrEqual(max(rendered.width, rendered.height), bound + 1)
        }
        var analysis: HistogramAnalysis?
        let schedules: [(String, UInt64, RawHistogramPipeline.RequestPurpose)] = [
            ("raw.apple-default.histogram.dwell-700ms", RawHistogramPipeline.analysisDelayNanoseconds, .info),
            ("raw.apple-default.histogram.dwell-0ms", 0, .info),
            ("raw.apple-default.histogram.production-background", RawHistogramPipeline.analysisDelayNanoseconds, .backgroundQuality)
        ]
        for (name, delay, purpose) in schedules {
            try await report.measureAsync(name: name, count: 1) {
                let pipeline = RawHistogramPipeline(delayNanoseconds: delay)
                analysis = await pipeline.analysis(for: item, purpose: purpose)
            }
            let measured = try XCTUnwrap(analysis)
            XCTAssertGreaterThan(measured.sampleCount, 0)
            XCTAssertLessThanOrEqual(max(measured.width, measured.height), 1_025)
        }
        let jpegURL = root.appendingPathComponent("foreground.JPG")
        let jpegPixels = try XCTUnwrap(ImagePipeline.decodeImage(url: url, maxPixel: 1_024))
        let jpegDestination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(jpegDestination, jpegPixels, nil)
        XCTAssertTrue(CGImageDestinationFinalize(jpegDestination))
        let jpeg = PhotoItem(id: jpegURL.lastPathComponent, primaryURL: jpegURL, pairedURL: nil,
                             captureDate: nil, cameraModel: nil, lensModel: nil,
                             fileSize: Int64(try jpegURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        var jpegTimes: [Double] = []
        try await report.measureAsync(name: "raw.production-background.with-foreground-jpeg", count: 2) {
            let started = SpeedRAWStartCounter()
            let pipeline = RawHistogramPipeline { rawURL in
                started.record()
                return RawHistogramProcessor.analyze(url: rawURL)
            }
            let rawTask = Task { await pipeline.analysis(for: item, purpose: .backgroundQuality) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while started.value == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertEqual(started.value, 1)
            let cacheRoot = root.appendingPathComponent("jpeg-cache-\(UUID())", isDirectory: true)
            let images = ImagePipeline(testingDiskCacheRoot: cacheRoot)
            let jpegStart = ContinuousClock.now
            let foreground = await images.fullImage(for: jpeg)
            let elapsed = jpegStart.duration(to: .now).components
            jpegTimes.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertNotNil(foreground)
            let evidence = await rawTask.value
            XCTAssertGreaterThan(evidence?.sampleCount ?? 0, 0)
            XCTAssertLessThanOrEqual(max(evidence?.width ?? 0, evidence?.height ?? 0), 1_025)
            try FileManager.default.removeItem(at: cacheRoot)
        }
        try report.recordSamples(name: "jpeg.foreground-full-during-production-background-raw", count: 1,
                                 samplesMS: Array(jpegTimes.dropFirst()))
        XCTAssertEqual(try digest(url), originalHash)
        XCTAssertEqual(try digest(source), originalHash)
        XCTAssertEqual(try FileOperationJournal.captureIdentity(at: source), identity)
        try report.finish()
    }

    private func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        return hash.finalize()
    }
}

private final class SpeedRAWStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}
