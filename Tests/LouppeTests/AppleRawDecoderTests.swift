import AppKit
import CoreImage
import Darwin
import XCTest
@testable import Louppe

@MainActor
final class AppleRawDecoderTests: XCTestCase {
    func testDefaultPreservesAppleSelectionAndUnknownPreferenceResetsSafely() throws {
        let suite = "LouppeDecoderTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppleRawDecoder.load(from: defaults), .appleDefault)
        XCTAssertNil(try AppleRawDecoder.appleDefault.version(supported: [.version8], supportsRAW9: false))
        defaults.set(AppleRawDecoder.raw9.rawValue, forKey: AppleRawDecoder.preferenceKey)
        XCTAssertEqual(AppleRawDecoder.load(from: defaults), .raw9)
        defaults.set("unknown-future-decoder", forKey: AppleRawDecoder.preferenceKey)
        XCTAssertEqual(AppleRawDecoder.load(from: defaults), .appleDefault)
    }

    func testRAW9RequiresBothSystemAndPerFileSupportIncludingDNG() throws {
        XCTAssertThrowsError(try AppleRawDecoder.raw9.version(supported: [.version9], supportsRAW9: false))
        XCTAssertThrowsError(try AppleRawDecoder.raw9.version(supported: [.version7, .version8], supportsRAW9: true))
        XCTAssertThrowsError(try AppleRawDecoder.raw9.version(supported: [], supportsRAW9: true))
        XCTAssertEqual(try AppleRawDecoder.raw9.version(supported: [.version7, .version8, .version9], supportsRAW9: true), .version9)
        XCTAssertEqual(try AppleRawDecoder.raw9.version(supported: [.version8DNG, .version9DNG], supportsRAW9: true), .version9DNG)
    }

    func testDecoderSeparatesRenderedPreviewsSourcesAndTilesButSharesFastAndJPEG() {
        let raw = item("sample.RAF")
        let jpeg = item("sample.JPG")
        XCTAssertNotEqual(ImagePipeline.fullCacheKey(for: raw, mode: .raw, decoder: .appleDefault), ImagePipeline.fullCacheKey(for: raw, mode: .raw, decoder: .raw9))
        XCTAssertNotEqual(HighResolutionImagePipeline.sourceKey(for: raw, decoder: .appleDefault), HighResolutionImagePipeline.sourceKey(for: raw, decoder: .raw9))
        XCTAssertEqual(ImagePipeline.fullCacheKey(for: raw, mode: .fast, decoder: .appleDefault), ImagePipeline.fullCacheKey(for: raw, mode: .fast, decoder: .raw9))
        XCTAssertEqual(ImagePipeline.fullCacheKey(for: jpeg, mode: .raw, decoder: .appleDefault), ImagePipeline.fullCacheKey(for: jpeg, mode: .raw, decoder: .raw9))
        XCTAssertEqual(HighResolutionImagePipeline.sourceKey(for: jpeg, decoder: .appleDefault), HighResolutionImagePipeline.sourceKey(for: jpeg, decoder: .raw9))
    }

    func testDecoderSwitchRejectsLateSourceAndRetryRestartsSamePhoto() async throws {
        var pending: [AppleRawDecoder: [CheckedContinuation<ZoomImageSource?, Never>]] = [:]
        var resumedCount: [AppleRawDecoder: Int] = [:]
        var returnedCancellation: [AppleRawDecoder: [Bool]] = [:]
        var renderingFailed = false
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let scroll = ActualSizeScrollView { _, decoder in
            let source = await withCheckedContinuation {
                pending[decoder, default: []].append($0)
            }
            returnedCancellation[decoder, default: []].append(Task.isCancelled)
            return source
        }
        defer {
            scroll.prepareForRemoval()
            for (decoder, continuations) in pending {
                for continuation in continuations.dropFirst(resumedCount[decoder, default: 0]) {
                    continuation.resume(returning: nil)
                }
            }
        }
        let photo = item("switch.RAF")
        let viewport = ActualSizeViewport()
        func configure(_ decoder: AppleRawDecoder, retry: UInt64 = 0) {
            scroll.configure(item: photo, preview: nil, showsClippingWarnings: false,
                             viewport: viewport, onLoading: { _ in }, zoomScale: 0.5,
                             decoder: decoder, retryGeneration: retry,
                             onRenderingFailure: { renderingFailed = $0 })
        }
        func source(_ decoder: AppleRawDecoder) -> ZoomImageSource {
            let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            return ZoomImageSource(key: HighResolutionImagePipeline.sourceKey(for: photo, decoder: decoder),
                                   image: image, pixelSize: image.extent.size, decoder: decoder)
        }
        func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
            while !condition() {
                guard clock.now < deadline else {
                    XCTFail(message)
                    throw NSError(domain: "AppleRawDecoderTests", code: 1)
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        configure(.appleDefault)
        try await waitUntil("Default decoder did not start loading") {
            pending[.appleDefault]?.count == 1
        }
        configure(.raw9)
        try await waitUntil("RAW 9 did not start loading") {
            pending[.raw9]?.count == 1
        }
        let old = try XCTUnwrap(pending[.appleDefault]?.first)
        let current = try XCTUnwrap(pending[.raw9]?.first)
        let raw9Source = source(.raw9)
        resumedCount[.appleDefault] = 1
        old.resume(returning: source(.appleDefault))
        try await waitUntil("Older decoder did not return after cancellation") {
            returnedCancellation[.appleDefault]?.count == 1
        }
        XCTAssertEqual(returnedCancellation[.appleDefault]?.first, true)
        XCTAssertNil(scroll.displayedSourceKey, "Older decoder must not publish after switching")
        resumedCount[.raw9] = 1
        current.resume(returning: raw9Source)
        try await waitUntil("RAW 9 source did not publish") {
            scroll.displayedSourceKey == raw9Source.key
        }
        XCTAssertEqual(scroll.displayedSourceKey, raw9Source.key)
        renderingFailed = false
        configure(.raw9, retry: 1)
        XCTAssertNil(scroll.displayedSourceKey, "Retry retires failed tiles and the old source")
        try await waitUntil("Retry did not restart the same RAW 9 photo") {
            pending[.raw9]?.count == 2
        }
        XCTAssertEqual(pending[.raw9]?.count, 2)
        resumedCount[.raw9] = 2
        pending[.raw9]?.last?.resume(returning: nil)
        try await waitUntil("Retry failure did not publish") {
            returnedCancellation[.raw9]?.count == 2 && renderingFailed
        }
        XCTAssertNil(scroll.displayedSourceKey)
    }

    /// Run each decoder in a separate test process so peak RSS is comparable.
    /// Reads original RAFs; never writes to the media folder.
    func testFujiDecoderBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LOUPPE_RAW_BENCHMARK_FOLDER"],
              let choice = env["LOUPPE_RAW_BENCHMARK_DECODER"],
              let decoder = AppleRawDecoder(rawValue: choice) else {
            throw XCTSkip("Set RAW benchmark folder and decoder to benchmark real RAFs")
        }
        let folder = URL(fileURLWithPath: path)
        let names = ["XT508475.RAF", "XT508539.RAF", "XT508553.RAF"]
        for name in names {
            let url = folder.appendingPathComponent(name)
            let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
            print("RAW-BENCH \(name) default=\(filter.decoderVersion.rawValue) supported=\(filter.supportedDecoderVersions.map(\.rawValue)) selected=\(decoder.rawValue)")
            for size in [1024, 4096] {
                let started = Date()
                let result = await Task.detached {
                    autoreleasepool { RawImageRendering.preview(url: url, maximumPixelSize: CGFloat(size), decoder: decoder) }
                }.value
                let image = try XCTUnwrap(result)
                XCTAssertLessThanOrEqual(max(image.width, image.height), size + 1)
                print("RAW-BENCH \(name) \(size)px \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
            }
            let photo = item(name, url: url)
            let sourceStarted = Date()
            let loaded = await HighResolutionImagePipeline.shared.source(for: photo, decoder: decoder)
            let source = try XCTUnwrap(loaded)
            XCTAssertEqual(source.key, HighResolutionImagePipeline.sourceKey(for: photo, decoder: decoder))
            print("RAW-BENCH \(name) source \(String(format: "%.3f", Date().timeIntervalSince(sourceStarted)))s \(source.pixelSize)")
            let coordinate = ZoomTileCoordinate(column: Int(source.pixelSize.width / 2048), row: Int(source.pixelSize.height / 2048))
            let tileStarted = Date()
            let tile = await HighResolutionImagePipeline.shared.tile(for: source, coordinate: coordinate)
            XCTAssertNotNil(tile)
            print("RAW-BENCH \(name) central1024tile \(String(format: "%.3f", Date().timeIntervalSince(tileStarted)))s")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("RAW-BENCH peakRSSMiB=\(Double(usage.ru_maxrss) / 1048576)")
    }

    private func item(_ name: String, url: URL? = nil) -> PhotoItem {
        PhotoItem(id: name, primaryURL: url ?? URL(fileURLWithPath: "/tmp/" + name), pairedURL: nil,
                  captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
    }
}
