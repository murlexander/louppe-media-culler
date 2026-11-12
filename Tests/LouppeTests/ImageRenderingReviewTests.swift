import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

final class ImageRenderingReviewTests: XCTestCase {
    func testFitDecodesAllEXIFOrientationsIncludingMirroredCorners() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Indices in top-left, top-right, bottom-left, bottom-right order.
        let cornerOrders = [
            [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
            [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2],
        ]
        let normalURL = folder.appendingPathComponent("normal.jpg")
        try writeImage(to: normalURL, type: .jpeg, width: 768, height: 512)
        let normal = try XCTUnwrap(ImagePipeline.decodeFitImage(url: normalURL, sizing: .bounded))
        let originalCorners = try corners(of: normal)
        for orientation in 1...8 {
            let url = folder.appendingPathComponent("orientation-\(orientation).jpg")
            try writeImage(to: url, type: .jpeg, width: 768, height: 512, orientation: orientation)
            for sizing in [FitDecodeSizing.bounded, .exactScale(coverage: CGSize(width: 3024, height: 1964))] {
                let decoded = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: sizing))
                let transposed = orientation >= 5
                XCTAssertEqual(decoded.width, transposed ? 512 : 768, "EXIF \(orientation)")
                XCTAssertEqual(decoded.height, transposed ? 768 : 512, "EXIF \(orientation)")
                let actual = try corners(of: decoded)
                for (index, sourceIndex) in cornerOrders[orientation - 1].enumerated() {
                    let expected = originalCorners[sourceIndex]
                    XCTAssertEqual(actual[index].redComponent, expected.redComponent, accuracy: 0.03, "EXIF \(orientation), corner \(index)")
                    XCTAssertEqual(actual[index].greenComponent, expected.greenComponent, accuracy: 0.03, "EXIF \(orientation), corner \(index)")
                    XCTAssertEqual(actual[index].blueComponent, expected.blueComponent, accuracy: 0.03, "EXIF \(orientation), corner \(index)")
                }
            }
        }
    }

    func testFitBoundsRealTinyPanoramaTallAndNonJPEGImages() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [(UTType, Int, Int)] = [
            (.jpeg, 1, 1), (.jpeg, 37, 17), (.jpeg, 4200, 2), (.jpeg, 2, 4200),
            (.jpeg, 18000, 120), (.jpeg, 120, 18000), (.jpeg, 6001, 4001),
            (.png, 4200, 128), (.tiff, 128, 4200), (.heic, 4500, 3000),
        ]
        for (index, entry) in cases.enumerated() {
            try autoreleasepool {
                let (type, width, height) = entry
                let url = folder.appendingPathComponent("shape-\(index).\(type.preferredFilenameExtension!)")
                try writeImage(to: url, type: type, width: width, height: height)
                let item = PhotoItem(primaryFile: PhotoFile(
                    id: url.lastPathComponent, url: url, captureDate: nil, cameraModel: nil,
                    lensModel: nil, fileSize: 1,
                    scannedIdentity: try FileOperationJournal.captureIdentity(at: url)))
                for coverage in [CGSize(width: 1920, height: 1080), CGSize(width: 3024, height: 1964), CGSize(width: 5120, height: 2880)] {
                    let sizing = FitDecodeSizing(item: item, mode: .fast, coverage: coverage)
                    let decoded = try XCTUnwrap(ImagePipeline.decodeFitImage(url: url, sizing: sizing), "\(type), \(width)×\(height)")
                    let bound = type == .jpeg ? ImagePipeline.fitOutputPixelBound : ImagePipeline.fullPixelSize
                    XCTAssertLessThanOrEqual(CGFloat(max(decoded.width, decoded.height)), bound)
                    XCTAssertLessThanOrEqual(decoded.width, width, "Do not upscale tiny originals")
                    XCTAssertLessThanOrEqual(decoded.height, height, "Do not upscale tiny originals")
                    let scale = min(1, CGFloat(max(decoded.width, decoded.height)) / CGFloat(max(width, height)))
                    XCTAssertEqual(CGFloat(decoded.width), CGFloat(width) * scale, accuracy: 1)
                    XCTAssertEqual(CGFloat(decoded.height), CGFloat(height) * scale, accuracy: 1)
                }
            }
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("louppe-render-review-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeImage(to url: URL, type: UTType, width: Int, height: Int, orientation: Int = 1) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors: [CGColor] = [
            CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
            CGColor(red: 0.1, green: 0.9, blue: 0.1, alpha: 1),
            CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1),
            CGColor(red: 0.9, green: 0.9, blue: 0.1, alpha: 1),
        ]
        context.setFillColor(colors[0])
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<2 {
            for column in 0..<2 {
                context.setFillColor(colors[row * 2 + column])
                context.fill(CGRect(x: CGFloat(column * width) / 2, y: CGFloat(row * height) / 2,
                                    width: CGFloat(width) / 2, height: CGFloat(height) / 2))
            }
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func corners(of image: CGImage) throws -> [NSColor] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try [(1, 1), (3, 1), (1, 3), (3, 3)].map { x, y in
            try XCTUnwrap(bitmap.colorAt(x: image.width * x / 4, y: image.height * y / 4)?.usingColorSpace(.deviceRGB))
        }
    }
}
