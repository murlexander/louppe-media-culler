import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

final class ArchiveMetadataIndexTests: XCTestCase {
    func testTransientFailureRetriesUnchangedRealJPEGThenCachesSuccessfulObservation() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads(failures: 1)
        let first = try XCTUnwrap(fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads).first)
        XCTAssertTrue(first.primaryFile.metadataIsLoaded, "an attempted read can finish progressive readiness")
        XCTAssertNil(first.cameraModel)
        XCTAssertNil(try fixture.index().metadata(for: first.primaryFile), "failure is not a reusable negative observation")
        let second = try XCTUnwrap(fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads).first)
        XCTAssertEqual(second.contentRevision, first.contentRevision, "retry must not require changing the source")
        XCTAssertEqual(second.cameraModel, "Archive camera")
        XCTAssertEqual(second.captureDateEvidence?.source, .exifOriginal)
        XCTAssertEqual(reads.total, 2)
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(reads.total, 2, "successful retry becomes reusable")
        try fixture.assertOriginalBytes()
    }

    func testSuccessfulReadWithNoTagsIsCacheableButImageIOFailureIsNot() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let index = try fixture.index()
        let items = try FolderScanner.prepareMetadata(in: inventory,
            metadataReaderForTesting: { _ in MetadataExtractor.ScanInfo() }, metadataIndex: index)
        XCTAssertNil(items.first?.cameraModel)
        XCTAssertNotNil(try fixture.index().metadata(for: XCTUnwrap(items.first).primaryFile))
        let unreadable = fixture.root.appendingPathComponent("invalid.JPG")
        try Data("not an image header".utf8).write(to: unreadable)
        XCTAssertFalse(MetadataExtractor.scanInfo(for: unreadable).extractionSucceeded)
        XCTAssertTrue(MetadataExtractor.scanInfo(for: fixture.source.appendingPathComponent("A.JPG")).extractionSucceeded)
        try fixture.assertOriginalBytes()
    }

    func testUnchangedCommitSkipsMaintenanceAndChangedFailedIORequestsValidation() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let items = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let index = try fixture.index()
        let bytes = try Data(contentsOf: index.cacheURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: index.cacheURL.path)
        // External siblings distinguish a pure no-op from directory maintenance.
        // Every actual index write remains responsible for aggregate bounds.
        for value in 0..<40 {
            try Data("disposable sibling".utf8).write(to:
                fixture.cache.appendingPathComponent(String(format: "%064x", value) + ".json"))
        }
        XCTAssertFalse(index.commit(items), "false means no cache filesystem work requiring another identity barrier")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count, 41)
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.cacheURL.path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
        let blocked = fixture.root.appendingPathComponent("blocked-cache")
        try Data("not a directory".utf8).write(to: blocked)
        let failedIndex = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: blocked))
        XCTAssertTrue(failedIndex.commit(items), "optional I/O failure still requires post-cache source validation")
        try fixture.assertOriginalBytes()
    }

    func testAVFoundationFailuresDoNotBecomeReusableMovieOrAudioObservations() throws {
        let fixture = try ArchiveMetadataFixture(names: [])
        defer { fixture.remove() }
        let bytes = Data("invalid asset header".utf8)
        let movie = fixture.source.appendingPathComponent("broken.MOV")
        let audio = fixture.source.appendingPathComponent("broken.MP3")
        try bytes.write(to: movie)
        try bytes.write(to: audio)
        XCTAssertFalse(VideoMetadataExtractor.scanInfo(for: movie).extractionSucceeded)
        XCTAssertFalse(AudioMetadataExtractor.scanInfo(for: audio).extractionSucceeded)
        let items = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        XCTAssertEqual(items.count, 2)
        let reopenedIndex = try fixture.index()
        for item in items {
            XCTAssertTrue(item.primaryFile.metadataIsLoaded)
            XCTAssertNil(reopenedIndex.metadata(for: item.primaryFile))
        }
        XCTAssertEqual(try Data(contentsOf: movie), bytes)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }

    func testOversizedEntryIsOmittedAndRetriedWithinSnapshotBounds() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let items = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { _ in
                MetadataExtractor.ScanInfo(cameraModel: String(repeating: "x", count: ArchiveMetadataIndex.maximumEntryBytes))
            }, metadataIndex: fixture.index())
        let index = try fixture.index()
        XCTAssertNil(index.metadata(for: try XCTUnwrap(items.first).primaryFile))
        XCTAssertLessThanOrEqual(try Data(contentsOf: index.cacheURL).count, ArchiveMetadataIndex.maximumSnapshotBytes)
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(reads.total, 1)
        try fixture.assertOriginalBytes()
    }

    func testReopenReusesUnchangedRealJPEGMetadataAndNeverCachesDecisions() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        inventory.items[0].primaryFile.rating = .yes
        let reads = ArchiveMetadataReads()
        let first = try fixture.prepare(inventory, reads: reads)
        XCTAssertEqual(reads.total, 2)
        let revisionByID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0.contentRevision) })
        let reopened = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(reads.total, 2, "unchanged headers must come from the disk observation index")
        XCTAssertTrue(reopened.allSatisfy { $0.cameraModel == "Archive camera" && $0.rating == .undecided })
        for item in reopened {
            XCTAssertEqual(item.contentRevision, revisionByID[item.id], "preview cache keys must survive metadata reuse")
            XCTAssertEqual(item.captureDateEvidence?.source, .exifOriginal)
            XCTAssertEqual(item.captureDateEvidence?.subsecondDigits, "125")
            XCTAssertEqual(item.captureDateEvidence?.utcOffset, "+02:00")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.index().cacheURL)) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let metadata = try XCTUnwrap(entries[0]["metadata"] as? [String: Any])
        for key in ["rating", "ratedAt", "stars", "starRating", "colorLabel", "fileIdentity", "recovery", "lineage"] {
            XCTAssertNil(metadata[key])
        }
        try fixture.assertOriginalBytes()
    }

    func testAtomicSamePathReplacementCannotInheritMetadataEvenWithSameSizeAndMtime() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        let old = try XCTUnwrap(fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads).first)
        let url = fixture.source.appendingPathComponent("A.JPG")
        let replacement = try ArchiveMetadataFixture.jpeg(camera: "Changed camera")
        XCTAssertEqual(Int64(replacement.count), old.fileSize)
        try replacement.write(to: url, options: .atomic)
        if let date = old.primaryModificationDate {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let fresh = try XCTUnwrap(fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads).first)
        XCTAssertEqual(reads.total, 2)
        XCTAssertEqual(fresh.cameraModel, "Changed camera")
        XCTAssertEqual(fresh.id, old.id)
        XCTAssertNotEqual(fresh.contentRevision, old.contentRevision)
        XCTAssertEqual(fresh.rating, .undecided)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
    }

    func testRenameRemovalRefreshPathsMembershipAndPruneOldEntries() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let destination = fixture.source.appendingPathComponent("nested/Renamed.JPG")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("A.JPG"), to: destination)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("B.JPG"))
        let fresh = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(fresh.map(\.id), ["nested/Renamed.JPG"])
        XCTAssertEqual(fresh.first?.displayName, "Renamed.JPG")
        XCTAssertEqual(fresh.first?.subfolder, "nested")
        XCTAssertEqual(reads.total, 3, "renamed paths conservatively refresh their metadata")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.index().cacheURL)) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["path"] as? String, FolderScanner.fileSystemIdentityPath(for: destination))
    }

    func testMissingCorruptSchemaAndOversizedSnapshotsRebuildWithoutSourceWrites() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let cache = try fixture.index().cacheURL
        for damage in 0..<4 {
            switch damage {
            case 0: try FileManager.default.removeItem(at: cache)
            case 1: try Data("{broken".utf8).write(to: cache)
            case 2: try Data("{\"schemaVersion\":999,\"context\":\"old\",\"entries\":[]}".utf8).write(to: cache)
            default:
                let handle = try FileHandle(forWritingTo: cache)
                try handle.truncate(atOffset: UInt64(ArchiveMetadataIndex.maximumSnapshotBytes + 1))
                try handle.close()
            }
            let before = reads.total
            let items = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
            XCTAssertEqual(reads.total, before + 1)
            XCTAssertEqual(items.first?.cameraModel, "Archive camera")
            XCTAssertLessThanOrEqual(try Data(contentsOf: cache).count, ArchiveMetadataIndex.maximumSnapshotBytes)
            try fixture.assertOriginalBytes()
        }
    }

    func testInjectedReadersRemainIsolatedUnlessIndexIsExplicit() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        _ = try FolderScanner.scan(fixture.source) { _ in }
        let reads = ArchiveMetadataReads()
        for _ in 0..<2 {
            let inventory = try FolderScanner.discoverInventory(fixture.source)
            _ = try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { url in reads.read(url) })
        }
        XCTAssertEqual(reads.total, 2)
    }

    func testCancellationAndFailedFinalValidationPreserveCacheAndSidecar() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let index = try fixture.index()
        let previous = try Data(contentsOf: index.cacheURL)
        let sidecar = fixture.source.appendingPathComponent(".louppe_session.json")
        let decisions = Data("preserve exact decisions".utf8)
        try decisions.write(to: sidecar)
        try ArchiveMetadataFixture.jpeg(camera: "Another camera").write(to: fixture.source.appendingPathComponent("B.JPG"))
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let cancelled = FolderScanner.CancelFlag()
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(in: inventory, isCancelled: { cancelled.isSet },
            metadataReaderForTesting: { url in cancelled.set(); return reads.read(url) }, metadataIndex: index)) {
                XCTAssertTrue($0 is CancellationError)
            }
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), previous)
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(in: inventory, beforeFinalIdentityValidation: {
            try Data("replacement after metadata".utf8).write(to: fixture.source.appendingPathComponent("A.JPG"), options: .atomic)
        }, metadataReaderForTesting: { url in reads.read(url) }, metadataIndex: index))
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), previous)
        XCTAssertEqual(try Data(contentsOf: sidecar), decisions)
    }

    func testCacheHitStillRejectsReplacementAfterInventory() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let inventory = try FolderScanner.discoverInventory(fixture.source)
        let index = try fixture.index()
        try Data("same path, different physical file".utf8).write(to: fixture.source.appendingPathComponent("A.JPG"), options: .atomic)
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(in: inventory,
            metadataReaderForTesting: { url in reads.read(url) }, metadataIndex: index))
        XCTAssertEqual(reads.total, 1)
    }

    func testUnchangedPreparedSnapshotStillRequiresFinalSourceIdentityValidation() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let index = try fixture.index()
        let bytes = try Data(contentsOf: index.cacheURL)
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            beforeFinalIdentityValidation: {
                // Preparation already found the unchanged snapshot, but its
                // no-op must not bypass the original complete identity check.
                try ArchiveMetadataFixture.jpeg(camera: "Changed camera").write(
                    to: fixture.source.appendingPathComponent("A.JPG"), options: .atomic)
            }, metadataReaderForTesting: { url in reads.read(url) }, metadataIndex: index))
        XCTAssertEqual(reads.total, 1)
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), bytes)
    }

    func testCacheFailureRemainsOptionalAndCompletePairingAlwaysRunsFresh() throws {
        let fixture = try ArchiveMetadataFixture(names: ["PAIR.RAF", "PAIR.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        let separate = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(separate.count, 2)
        let pairedInventory = try FolderScanner.discoverInventory(fixture.source, pairingMode: .together)
        let paired = try fixture.prepare(pairedInventory, reads: reads)
        XCTAssertEqual(paired.count, 1)
        XCTAssertEqual(paired[0].individualFiles.count, 2)
        XCTAssertFalse(try XCTUnwrap(paired[0].pairedFile).metadataIsLoaded)
        XCTAssertEqual(reads.total, 2)
        let blockedDirectory = fixture.root.appendingPathComponent("unwritable-cache-parent")
        try Data("regular file, not directory".utf8).write(to: blockedDirectory)
        let unavailableIndex = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: blockedDirectory))
        let stillComplete = try FolderScanner.prepareMetadata(in: pairedInventory,
            metadataReaderForTesting: { url in reads.read(url) }, metadataIndex: unavailableIndex)
        XCTAssertEqual(stillComplete.count, 1)
        XCTAssertEqual(stillComplete[0].individualFiles.count, 2)
        try fixture.assertOriginalBytes()
    }

    func testSnapshotMaintenanceCapsFolderCountAndBytes() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        for value in 0..<40 {
            let url = fixture.cache.appendingPathComponent(String(format: "%064x", value) + ".json")
            try Data("old optional observation".utf8).write(to: url)
        }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        var urls = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(urls.count, ArchiveMetadataIndex.maximumFolderSnapshots)
        // Sparse disposable files exercise the byte ceiling without allocating
        // hundreds of MiB of media or touching a source/cache owned by the user.
        for url in urls.prefix(10) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(ArchiveMetadataIndex.maximumSnapshotBytes))
            try handle.close()
        }
        // Maintenance runs when an actual changed snapshot adds/replaces data.
        try ArchiveMetadataFixture.jpeg(camera: "Added camera").write(to: fixture.source.appendingPathComponent("B.JPG"))
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        urls = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try urls.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, ArchiveMetadataIndex.maximumTotalBytes)
    }
}

struct ArchiveMetadataFixture {
    let root: URL
    let source: URL
    let cache: URL
    let originals: [String: Data]

    init(names: [String]) throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("Louppe-Archive-\(UUID())", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let bytes = try Self.jpeg(camera: "Archive camera")
        var originals: [String: Data] = [:]
        for name in names {
            let url = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            originals[name] = bytes
        }
        self.originals = originals
    }

    func index() throws -> ArchiveMetadataIndex {
        try XCTUnwrap(ArchiveMetadataIndex(folder: source, cacheDirectory: cache))
    }

    func prepare(_ inventory: FolderScanner.Inventory, reads: ArchiveMetadataReads) throws -> [PhotoItem] {
        try FolderScanner.prepareMetadata(in: inventory, metadataReaderForTesting: { url in reads.read(url) }, metadataIndex: index())
    }

    func assertOriginalBytes(file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, bytes) in originals {
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), bytes, file: file, line: line)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func jpeg(camera: String) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: camera],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Archive lens", kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifDateTimeOriginal: "2026:10:24 13:14:15",
                kCGImagePropertyExifSubsecTimeOriginal: "125", kCGImagePropertyExifOffsetTimeOriginal: "+02:00"
            ]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class ArchiveMetadataReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failuresRemaining: Int
    init(failures: Int = 0) { failuresRemaining = failures }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read(_ url: URL) -> MetadataExtractor.ScanInfo {
        lock.lock()
        count += 1
        let fails = failuresRemaining > 0
        if fails { failuresRemaining -= 1 }
        lock.unlock()
        if fails { return MetadataExtractor.ScanInfo(extractionSucceeded: false) }
        return MetadataExtractor.scanInfo(for: url)
    }
}
