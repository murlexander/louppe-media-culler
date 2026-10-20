import Foundation
import ImageIO
import XCTest
@testable import Louppe

final class ModernImageFormatTests: XCTestCase {
    private let formats = [
        (ext: "jxl", type: "public.jpeg-xl"),
        (ext: "avif", type: "public.avif"),
        (ext: "webp", type: "org.webmproject.webp"),
    ]

    func testScanningRecognizesLowercaseAndUppercaseAsStandalonePhotos() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in formats {
            for (index, ext) in [format.ext, format.ext.uppercased()].enumerated() {
                let url = folder.appendingPathComponent("image-\(index).\(ext)")
                try FileManager.default.copyItem(at: fixture(format.ext), to: url)
            }
        }
        let items = try FolderScanner.scan(folder, progress: { _ in })
        XCTAssertEqual(items.count, 6)
        for item in items {
            XCTAssertEqual(item.mediaKind, .photo)
            XCTAssertTrue(item.isSupported)
            XCTAssertFalse(item.isRaw)
            XCTAssertNil(item.pairedURL)
        }
    }

    func testJPEGXLRendering() async throws { try await checkRendering(ext: "jxl") }
    func testAVIFRendering() async throws { try await checkRendering(ext: "avif") }
    func testWebPRendering() async throws { try await checkRendering(ext: "webp") }

    private func checkRendering(ext: String) async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("square.\(ext)")
        try FileManager.default.copyItem(at: fixture(ext), to: url)
        let original = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, formats.first { $0.ext == ext }?.type)
        let item = try XCTUnwrap(FolderScanner.scan(folder, progress: { _ in }).first)
        let pipeline = ImagePipeline(testingDiskCacheRoot: folder.appendingPathComponent("cache"))
        let thumbnail = await pipeline.thumbnail(for: item)
        let preview = await pipeline.fullImage(for: item)
        XCTAssertNotNil(thumbnail, "\(ext) thumbnail")
        XCTAssertNotNil(preview, "\(ext) Gallery preview")
        let loadedZoom = await HighResolutionImagePipeline.shared.source(for: item)
        let zoom = try XCTUnwrap(loadedZoom)
        XCTAssertEqual(zoom.pixelSize.width, 8)
        XCTAssertEqual(zoom.pixelSize.height, 8)
        let tile = await HighResolutionImagePipeline.shared.tile(
            for: zoom, coordinate: ZoomTileCoordinate(column: 0, row: 0)
        )
        XCTAssertEqual(tile?.image.width, 8, "\(ext) actual-size tile")
        XCTAssertEqual(tile?.image.height, 8)
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(try Data(contentsOf: url), original, "Review must preserve original bytes")
    }

    private func fixture(_ ext: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ModernImages/square.\(ext)")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe-ModernImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
