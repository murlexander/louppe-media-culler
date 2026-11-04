import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class RawDisplayTests: XCTestCase {
    func testRAWModeCannotReuseOrSilentlyFallbackToAnImageIOPreview() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A readable JPEG masquerading as a RAW exercises a working preview
        // with a failing RAW decoder, rather than an entirely unreadable file.
        let url = folder.appendingPathComponent("unsupported.RAF")
        let image = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)),
            from: CGRect(x: 0, y: 0, width: 64, height: 64)
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let item = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"))
        let fast = await pipeline.fullImage(for: item)
        XCTAssertNotNil(fast)
        XCTAssertNil(pipeline.cachedFullImage(for: item, mode: .raw))
        let raw = await pipeline.fullImage(for: item, mode: .raw)
        XCTAssertNil(raw)
        XCTAssertNil(RawHistogramProcessor.analyze(url: url))
        XCTAssertNotNil(pipeline.cachedFullImage(for: item))
        XCTAssertNotEqual(ImagePipeline.fullCacheKey(for: item, mode: .fast), ImagePipeline.fullCacheKey(for: item, mode: .raw))
        let source = await HighResolutionImagePipeline.shared.source(for: item)
        XCTAssertNil(source, "100% must not disguise ImageIO fallback as RAW")
    }

    func testPresentationCacheIdentityKeepsNonRAWImagesShared() {
        let item = PhotoItem(id: "photo.JPG", primaryURL: URL(fileURLWithPath: "/tmp/photo.JPG"), pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        XCTAssertEqual(ImagePipeline.fullCacheKey(for: item, mode: .fast), ImagePipeline.fullCacheKey(for: item, mode: .raw))
    }

    func testViewportLabelTracksVisiblePixelsAndExplicitRAWStandIn() {
        XCTAssertEqual(PhotoRepresentation.viewport(hasSource: true, usesTiles: true, visibleTilesReady: false, hasPreview: true, previewIsRAW: false, failed: false), .preview)
        XCTAssertEqual(PhotoRepresentation.viewport(hasSource: true, usesTiles: true, visibleTilesReady: true, hasPreview: true, previewIsRAW: false, failed: false), .raw)
        XCTAssertEqual(PhotoRepresentation.viewport(hasSource: true, usesTiles: false, visibleTilesReady: true, hasPreview: true, previewIsRAW: false, failed: false), .preview)
        XCTAssertEqual(PhotoRepresentation.viewport(hasSource: true, usesTiles: false, visibleTilesReady: false, hasPreview: true, previewIsRAW: true, failed: false), .raw)
        XCTAssertEqual(PhotoRepresentation.viewport(hasSource: false, usesTiles: true, visibleTilesReady: false, hasPreview: false, previewIsRAW: true, failed: false), .loadingRAW)
        XCTAssertEqual(PhotoRepresentation.viewport(hasSource: false, usesTiles: true, visibleTilesReady: false, hasPreview: false, previewIsRAW: true, failed: true), .unavailable)
    }

    func testStoreRejectsARepresentationFromThePreviousPhoto() {
        let store = SessionStore()
        store.items = ["a.RAF", "b.RAF"].map {
            PhotoItem(id: $0, primaryURL: URL(fileURLWithPath: "/tmp/" + $0), pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        let first = store.items[0].contentRevision
        store.reportPhotoRepresentation(.raw, revision: first)
        XCTAssertEqual(store.currentPhotoRepresentation, .raw)
        store.setIndex(1)
        store.reportPhotoRepresentation(.preview, revision: first)
        XCTAssertNil(store.currentPhotoRepresentation)
        store.reportPhotoRepresentation(.loadingPreview, revision: first)
        XCTAssertNil(store.currentPhotoRepresentation)
        store.reportPhotoRepresentation(.unavailable, revision: first)
        XCTAssertNil(store.currentPhotoRepresentation)
        store.reportPhotoRepresentation(.preview, revision: store.items[1].contentRevision)
        XCTAssertEqual(store.currentPhotoRepresentation, .preview)
    }

    func testRealRAWPreviewIsBoundedAnd100PercentUsesNativePixels() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_RAW_TEST_FILE"] else {
            throw XCTSkip("Set LOUPPE_RAW_TEST_FILE to exercise a real camera RAW")
        }
        let url = URL(fileURLWithPath: path)
        let item = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        let preview = try XCTUnwrap(RawImageRendering.preview(url: url, maximumPixelSize: 1024))
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 1025)
        let loadedSource = await HighResolutionImagePipeline.shared.source(for: item)
        let source = try XCTUnwrap(loadedSource)
        XCTAssertGreaterThan(max(source.pixelSize.width, source.pixelSize.height), 1024)
        let tile = await HighResolutionImagePipeline.shared.tile(for: source, coordinate: ZoomTileCoordinate(column: 0, row: 0))
        XCTAssertNotNil(tile)
        XCTAssertEqual(tile?.image.width, 1024)
        let pipeline = ImagePipeline(testingDiskCacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let raw = await pipeline.fullImage(for: item, mode: .raw)
        let bitmap = try XCTUnwrap(raw?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 4097)
        XCTAssertNil(pipeline.cachedFullImage(for: item, mode: .fast))
        XCTAssertNotNil(pipeline.cachedFullImage(for: item, mode: .raw))
    }
}
