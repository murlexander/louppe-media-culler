import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class LouppeSpeedIOTests: XCTestCase {
    func testRealJPEGScanAndDurableSaveReopen() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "io-scan-save")
        let root = URL(fileURLWithPath: "/private/tmp/louppe-speed-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.jpg")
        try writeJPEG(to: seed)
        let seedBytes = try Data(contentsOf: seed)
        let sizes = Array(Set(SpeedBenchmark.sizes.map { min(1_000, max(100, $0 / 10)) })).sorted()
        for count in sizes {
            let folder = root.appendingPathComponent("photos-\(count)", isDirectory: true)
            let backups = root.appendingPathComponent("backups-\(count)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<count {
                let url = folder.appendingPathComponent(String(format: "FRAME_%06d.JPG", i))
                try seedBytes.write(to: url)
            }
            var items: [PhotoItem] = []
            try report.measure(name: "scan.jpeg.warm-filesystem", count: count) {
                items = try FolderScanner.scan(folder, progress: { _ in })
            }
            XCTAssertEqual(items.count, count)
            XCTAssertEqual(Set(items.map(\.id)).count, count)
            XCTAssertTrue(items.allSatisfy { $0.primaryFile.scannedIdentity != nil })
            items[0].rating = .yes
            let persistence = SessionPersistence(backupDirectory: backups)
            let initialRead = await persistence.read(for: folder)
            let access = try XCTUnwrap(initialRead.access)
            var sequence: UInt64 = 0
            var results: [SessionPersistence.SaveResult] = []
            try await report.measureAsync(name: "save.durable-sidecar-and-backup", count: count) {
                sequence += 1
                let session = SessionSnapshotCapture(sourcePath: folder.path, items: items, retainedEntries: [], originPaths: [:]).makeSession()
                results.append(await persistence.save(session, for: folder, sequence: sequence, access: access))
            }
            XCTAssertTrue(results.allSatisfy { $0 == .savedToSidecar })
            let backupFiles = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            XCTAssertEqual(backupFiles.count, 1, "the sidecar-and-backup workload must actually save both copies")
            let backup = try XCTUnwrap(backupFiles.first)
            XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: SessionPersistence.sidecarURL(for: folder)))
            var read = await persistence.read(for: folder)
            try await report.measureAsync(name: "reopen.durable-session", count: count) {
                read = await persistence.read(for: folder)
            }
            XCTAssertEqual(read.session?.entries.count, count)
            XCTAssertEqual(read.session?.entries.first?.rating, Rating.yes.rawValue)
            for item in items { XCTAssertEqual(try Data(contentsOf: item.primaryURL), seedBytes) }
        }
        try report.finish()
    }

    private func writeJPEG(to url: URL) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_024, height: 768,
            bitsPerComponent: 8, bytesPerRow: 1_024 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 768))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
