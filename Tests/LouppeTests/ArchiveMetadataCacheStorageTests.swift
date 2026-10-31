import CryptoKit
import Foundation
import XCTest
@testable import Louppe

/// Compact v2 snapshots, v1 migration, pinned-folder protection and test-host
/// isolation. Disposable /private/tmp folders only; sparse files exercise byte
/// ceilings without allocating real storage.
final class ArchiveMetadataCacheStorageTests: XCTestCase {
    // MARK: Test-host isolation

    func testTestHostCachesUseDisposableRootsNotUserCaches() throws {
        XCTAssertTrue(RebuildableCacheLocation.isTestHost)
        let root = try XCTUnwrap(RebuildableCacheLocation.root).standardizedFileURL.path
        let userCaches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .standardizedFileURL.path
        XCTAssertFalse(root.hasPrefix(userCaches))
        XCTAssertTrue(root.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        for url in [ArchiveMetadataIndex.defaultDirectory, ArchiveMetadataIndex.defaultLegacyDirectory,
                    ImagePipeline.sharedDiskCacheRoot, ImagePipeline.shared.diskCacheRootForTesting] {
            XCTAssertTrue(try XCTUnwrap(url).standardizedFileURL.path.hasPrefix(root + "/"))
        }

        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        // The ordinary scanner path creates its own default index.
        _ = try FolderScanner.scan(fixture.source) { _ in }
        let index = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source))
        XCTAssertTrue(index.cacheURL.standardizedFileURL.path.hasPrefix(root + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.cacheURL.path))
        XCTAssertNotNil(index.metadata(for: try XCTUnwrap(
            FolderScanner.discoverInventory(fixture.source).items.first).primaryFile))
        let userSnapshot = URL(fileURLWithPath: userCaches)
            .appendingPathComponent("com.alexandermarkin.louppe/archive-metadata-v2")
            .appendingPathComponent(index.cacheURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userSnapshot.path))
    }

    // MARK: Pinned protection

    func testPinnedSnapshotSurvivesFortyOneOtherFoldersRelaunchAndIsEvictableAfterUnpin() async throws {
        let pinned = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { pinned.remove() }
        let cache = pinned.cache
        let worker = PinnedFoldersPersistence(storageDirectory: pinned.root.appendingPathComponent("Support"),
                                              operations: Self.bookmarks(), archiveMetadataProtection: cache)
        let (pinID, snapshot) = try await worker.pinSelectedFolder(url: pinned.source)
        ArchiveMetadataIndex.waitForProtectionPublicationForTesting()
        let key = try XCTUnwrap(snapshot.folders.first).identity.archiveMetadataProtectionKey
        XCTAssertEqual(ArchiveMetadataIndex.protectedKeys(in: cache), [key])

        _ = try pinned.prepare(FolderScanner.discoverInventory(pinned.source), reads: ArchiveMetadataReads())
        let pinnedURL = try pinned.index().cacheURL
        XCTAssertTrue(pinnedURL.lastPathComponent.hasPrefix(key + "-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))

        let jpeg = try ArchiveMetadataFixture.jpeg(camera: "Other camera")
        var opened = 0
        func openOtherFolder() throws {
            let folder = pinned.root.appendingPathComponent("others/\(opened)", isDirectory: true)
            opened += 1
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: folder.appendingPathComponent("A.JPG"))
            let index = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache))
            let items = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(folder),
                metadataReaderForTesting: { MetadataExtractor.scanInfo(for: $0) }, metadataIndex: index)
            XCTAssertEqual(items.first?.cameraModel, "Other camera")
            XCTAssertTrue(FileManager.default.fileExists(atPath: index.cacheURL.path))
        }
        for _ in 0..<41 { try openOtherFolder() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path),
                      "41 other folder snapshots must not evict a pinned folder")
        XCTAssertEqual(try Self.snapshotNames(in: cache).count, ArchiveMetadataIndex.maximumFolderSnapshots + 1)
        let reads = ArchiveMetadataReads()
        _ = try pinned.prepare(FolderScanner.discoverInventory(pinned.source), reads: reads)
        XCTAssertEqual(reads.total, 0, "the pinned folder reopens without EXIF reads")

        // A relaunch has no in-memory publication yet: the persisted list applies.
        ArchiveMetadataIndex.forgetPublishedProtectionForTesting(in: cache)
        XCTAssertEqual(ArchiveMetadataIndex.protectedKeys(in: cache), [key])
        for _ in 0..<5 { try openOtherFolder() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))

        _ = try await worker.unpin(id: pinID)
        ArchiveMetadataIndex.waitForProtectionPublicationForTesting()
        XCTAssertEqual(ArchiveMetadataIndex.protectedKeys(in: cache), [])
        ArchiveMetadataIndex.forgetPublishedProtectionForTesting(in: cache)
        XCTAssertEqual(ArchiveMetadataIndex.protectedKeys(in: cache), [], "unpin is persisted too")
        try openOtherFolder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinnedURL.path),
                       "an unpinned folder returns to ordinary oldest-first eviction")
        XCTAssertEqual(try Self.snapshotNames(in: cache).count, ArchiveMetadataIndex.maximumFolderSnapshots)
        try pinned.assertOriginalBytes()
    }

    func testBytePressureEvictsUnpinnedFirstThenOnlyTheOldestPin() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let cache = fixture.cache
        let pins = (1...3).map { String(format: "%032x", 0xA0 + $0) }
        ArchiveMetadataIndex.publishProtectedFolders(Set(pins), in: cache)
        let mebibyte = 1_024 * 1_024
        func sparse(_ name: String, mebibytes: Int, age: TimeInterval) throws -> URL {
            let url = cache.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(mebibytes * mebibyte))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: url.path)
            return url
        }
        // Unpinned snapshots are newer, so mtime order alone would evict pins first.
        let oldestPin = try sparse(ArchiveMetadataFixture.snapshotName(1, protection: pins[0]), mebibytes: 100, age: 400)
        let newerPin = try sparse(ArchiveMetadataFixture.snapshotName(2, protection: pins[1]), mebibytes: 100, age: 300)
        let olderUnpinned = try sparse(ArchiveMetadataFixture.snapshotName(3), mebibytes: 60, age: 200)
        let newerUnpinned = try sparse(ArchiveMetadataFixture.snapshotName(4), mebibytes: 60, age: 100)
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        let current = try fixture.index().cacheURL
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        XCTAssertFalse(exists(olderUnpinned))
        XCTAssertFalse(exists(newerUnpinned))
        XCTAssertTrue(exists(oldestPin))
        XCTAssertTrue(exists(newerPin))
        XCTAssertTrue(exists(current))

        // Pins alone now exceed the budget: only the oldest pin goes.
        let thirdPin = try sparse(ArchiveMetadataFixture.snapshotName(5, protection: pins[2]), mebibytes: 100, age: 50)
        try ArchiveMetadataFixture.jpeg(camera: "Added camera").write(to: fixture.source.appendingPathComponent("B.JPG"))
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        XCTAssertFalse(exists(oldestPin))
        XCTAssertTrue(exists(newerPin))
        XCTAssertTrue(exists(thirdPin))
        XCTAssertTrue(exists(current))
        let total = try Self.snapshotNames(in: cache).reduce(0) {
            $0 + (try cache.appendingPathComponent($1).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, ArchiveMetadataIndex.maximumTotalBytes)
    }

    func testOnlyNewestSnapshotPerPinIsProtectedSoStaleCopiesAgeOut() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let pin = String(format: "%032x", 0xB1)
        ArchiveMetadataIndex.publishProtectedFolders([pin], in: fixture.cache)
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let url = fixture.cache.appendingPathComponent(name)
            try Data("optional observation".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: url.path)
            return url
        }
        // The same pinned folder at an older path/device, then its current bucket.
        let stale = try file(ArchiveMetadataFixture.snapshotName(1, protection: pin), age: 1_000)
        let newest = try file(ArchiveMetadataFixture.snapshotName(2, protection: pin), age: 900)
        for value in 0..<ArchiveMetadataIndex.maximumFolderSnapshots {
            _ = try file(ArchiveMetadataFixture.snapshotName(100 + value), age: 500 - Double(value))
        }
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: ArchiveMetadataReads())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.cache.appendingPathComponent(ArchiveMetadataFixture.snapshotName(100)).path))
        XCTAssertEqual(try Self.snapshotNames(in: fixture.cache).count, ArchiveMetadataIndex.maximumFolderSnapshots + 1)
    }

    func testProtectionKeyMatchesPinnedFolderEquality() throws {
        let stamp = FileOperationJournal.FileIdentity.Timestamp(seconds: 10, nanoseconds: 20)
        func key(_ root: String, _ uuid: String?, _ device: UInt64, _ inode: UInt64 = 7) -> String {
            ArchiveMetadataIndex.protectionKey(volumeRootPath: root, volumeUUIDString: uuid, systemNumber: device,
                                               fileNumber: inode, birthTime: stamp)
        }
        // UUID volumes keep their pin across remounts at another device/mount point.
        XCTAssertEqual(key("/Volumes/A", "UUID-1", 1), key("/Volumes/A 1", "UUID-1", 2))
        XCTAssertNotEqual(key("/Volumes/A", "UUID-1", 1), key("/Volumes/A", "UUID-2", 1))
        XCTAssertNotEqual(key("/Volumes/A", nil, 1), key("/Volumes/A", nil, 2))
        XCTAssertNotEqual(key("/Volumes/A", nil, 1), key("/Volumes/B", nil, 1))
        XCTAssertNotEqual(key("/Volumes/A", "UUID-1", 1), key("/Volumes/A", "UUID-1", 1, 8))
        XCTAssertNotNil(ArchiveMetadataIndex.snapshotProtectionKey(fileName: ArchiveMetadataFixture.snapshotName(3)))
        for name in ["pinned-folders", String(format: "%064x", 1) + ".json",
                     ArchiveMetadataFixture.snapshotName(3).uppercased(), ArchiveMetadataFixture.snapshotName(3) + "x"] {
            XCTAssertNil(ArchiveMetadataIndex.snapshotProtectionKey(fileName: name), name)
        }
    }

    // MARK: v1 migration

    func testV1SnapshotMigratesOnceWithoutRereadingThenIsRemoved() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "B.JPG"])
        defer { fixture.remove() }
        let legacy = fixture.root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(reads.total, 2)
        let index = try fixture.index()
        let entries = try XCTUnwrap(index.storedEntriesForTesting())
        let legacyURL = legacy.appendingPathComponent(index.legacySnapshotNameForTesting)
        try SyntheticArchiveEntries.legacyJSON(entries, context: ArchiveMetadataIndex.currentContext).write(to: legacyURL)
        try FileManager.default.removeItem(at: index.cacheURL)

        func migratingIndex() throws -> ArchiveMetadataIndex {
            try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
                                               legacyCacheDirectory: legacy))
        }
        let migrating = try migratingIndex()
        XCTAssertTrue(migrating.isMigratingForTesting)
        let items = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { reads.read($0) }, metadataIndex: migrating)
        XCTAssertEqual(reads.total, 2, "v1 observations are reused, not reread")
        XCTAssertTrue(items.allSatisfy { $0.cameraModel == "Archive camera" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.cacheURL.path), "unchanged v1 still writes v2 once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try migratingIndex().storedEntriesForTesting(), entries)
        XCTAssertFalse(try migratingIndex().isMigratingForTesting)
        let bytes = try Data(contentsOf: index.cacheURL)
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { reads.read($0) }, metadataIndex: migratingIndex())
        XCTAssertEqual(reads.total, 2)
        XCTAssertEqual(try Data(contentsOf: index.cacheURL), bytes, "warm v2 reopen skips encoding and I/O")
        try fixture.assertOriginalBytes()
    }

    func testV1MigrationRejectsForeignContextAndIgnoresLegacyWhenV2IsValid() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let legacy = fixture.root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let index = try fixture.index()
        let entries = try XCTUnwrap(index.storedEntriesForTesting())
        let legacyURL = legacy.appendingPathComponent(index.legacySnapshotNameForTesting)
        try SyntheticArchiveEntries.legacyJSON(entries, context: ArchiveMetadataIndex.currentContext).write(to: legacyURL)
        let withValidV2 = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
                                                             legacyCacheDirectory: legacy))
        XCTAssertFalse(withValidV2.isMigratingForTesting)

        try FileManager.default.removeItem(at: index.cacheURL)
        try SyntheticArchiveEntries.legacyJSON(entries, context: "1|Mars/Olympus|Version 1").write(to: legacyURL)
        let foreign = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
                                                         legacyCacheDirectory: legacy))
        XCTAssertFalse(foreign.isMigratingForTesting)
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { reads.read($0) }, metadataIndex: foreign)
        XCTAssertEqual(reads.total, 2, "a foreign-context v1 snapshot is not reused")
    }

    // MARK: v2 validation

    func testV2ContextMismatchRereadsAndRewritesForNewContext() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        let first = try XCTUnwrap(fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads).first)
        XCTAssertNotNil(try fixture.index().metadata(for: first.primaryFile))
        let other = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source, cacheDirectory: fixture.cache,
                                                       interpretationContext: "2|Pacific/Auckland|Version 99"))
        XCTAssertNil(other.metadata(for: first.primaryFile))
        _ = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(fixture.source),
            metadataReaderForTesting: { reads.read($0) }, metadataIndex: other)
        XCTAssertEqual(reads.total, 2)
        XCTAssertNil(try fixture.index().metadata(for: first.primaryFile), "current context no longer matches")
    }

    func testCorruptTruncatedUnsupportedAndOversizedV2NeverDecodeOrCrash() throws {
        let context = "ctx", folder = "/Volumes/Archive/Photos"
        let entries = SyntheticArchiveEntries.make(count: 300, root: folder)
        let data = try XCTUnwrap(ArchiveMetadataIndex.encode(entries, context: context, folderPath: folder))
        let decoded = try XCTUnwrap(ArchiveMetadataIndex.decode(data, context: context, folderPath: folder))
        XCTAssertEqual(decoded.count, entries.count)
        for entry in entries { XCTAssertEqual(decoded[entry.path], entry) }
        XCTAssertNil(ArchiveMetadataIndex.decode(data, context: "other", folderPath: folder))
        XCTAssertNil(ArchiveMetadataIndex.decode(data, context: context, folderPath: folder + "2"))
        for length in stride(from: 0, to: data.count, by: max(1, data.count / 997)) {
            XCTAssertNil(ArchiveMetadataIndex.decode(data.prefix(length), context: context, folderPath: folder))
        }
        var generator = SyntheticArchiveEntries.Generator(seed: 7)
        for _ in 0..<500 {
            var damaged = data
            let offset = Int(generator.next() % UInt64(damaged.count))
            damaged[offset] ^= UInt8(1 + generator.next() % 255)
            XCTAssertNil(ArchiveMetadataIndex.decode(damaged, context: context, folderPath: folder))
        }
        var unsupported = data
        unsupported[4] = 3
        XCTAssertNil(ArchiveMetadataIndex.decode(unsupported, context: context, folderPath: folder))
        var oversized = data
        oversized.append(Data(count: ArchiveMetadataIndex.maximumSnapshotBytes + 1 - data.count))
        XCTAssertNil(ArchiveMetadataIndex.decode(oversized, context: context, folderPath: folder))

        // Payloads with a valid digest but arbitrary contents still fail closed.
        let header = Data(data.prefix(5))
        for _ in 0..<2_000 {
            var payload = header
            let length = Int(generator.next() % 160)
            for _ in 0..<length { payload.append(UInt8(truncatingIfNeeded: generator.next())) }
            if generator.next() % 2 == 0 { payload.replaceSubrange(5..<5, with: data[5..<min(data.count - 32, 40)]) }
            payload.append(contentsOf: TestDigest.of(payload))
            _ = ArchiveMetadataIndex.decode(payload, context: context, folderPath: folder)
        }
        // A digest-valid header claiming more entries than the cap is rejected.
        XCTAssertNil(ArchiveMetadataIndex.decode(
            SyntheticArchiveEntries.forgedCount(ArchiveMetadataIndex.maximumEntries + 1, context: context, folder: folder),
            context: context, folderPath: folder))
    }

    /// An opening's post-Ready commit and background pin preparation can both
    /// write one folder's snapshot; the producer that read an older snapshot
    /// must not replace a newer one.
    func testOlderProducerNeverReplacesANewerSnapshot() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppeStaleCommit-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let cache = root.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("A.JPG"))
        let reader: @Sendable (URL) throws -> MetadataExtractor.ScanInfo = { _ in .init(cameraModel: "Probe") }
        func scan(_ index: ArchiveMetadataIndex) throws -> [PhotoItem] {
            try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(folder),
                metadataReaderForTesting: reader, metadataIndex: index, commitsMetadataIndex: false)
        }
        let older = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache))
        let olderItems = try scan(older)
        try Data("b".utf8).write(to: folder.appendingPathComponent("B.JPG"))
        let newer = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache))
        XCTAssertTrue(newer.commit(try scan(newer)))
        XCTAssertFalse(older.commit(olderItems), "a superseded producer wrote over a newer snapshot")
        let stored = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache)?.storedEntriesForTesting())
        XCTAssertEqual(stored.count, 2)
        // A producer that read the current snapshot may still replace it.
        try Data("c".utf8).write(to: folder.appendingPathComponent("C.JPG"))
        let current = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache))
        XCTAssertTrue(current.commit(try scan(current)))
        XCTAssertEqual(try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache)?.storedEntriesForTesting()).count, 3)
    }

    func testDigestValidOversizedTablesAreRejectedBeforeAllocation() throws {
        let context = "test-context", folder = "/private/tmp/forged-tables"
        // At the bound: ten strings per possible entry still decode (empty).
        let atBound = SyntheticArchiveEntries.forgedStringTable(
            ArchiveMetadataIndex.maximumEntries * 10, context: context, folder: folder)
        XCTAssertNotNil(ArchiveMetadataIndex.decode(atBound, context: context, folderPath: folder))
        // One more than any valid snapshot can reference is refused.
        let beyond = SyntheticArchiveEntries.forgedStringTable(
            ArchiveMetadataIndex.maximumEntries * 10 + 1, context: context, folder: folder)
        XCTAssertNil(ArchiveMetadataIndex.decode(beyond, context: context, folderPath: folder))
    }

    func testCorruptOnDiskV2RebuildsWithoutSourceWrites() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        let cache = try fixture.index().cacheURL
        var bytes = try Data(contentsOf: cache)
        bytes[bytes.count / 2] ^= 0x5A
        try bytes.write(to: cache)
        let items = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(reads.total, 2)
        XCTAssertEqual(items.first?.cameraModel, "Archive camera")
        XCTAssertNotNil(try fixture.index().storedEntriesForTesting(), "the rebuilt snapshot is valid v2")
        try fixture.assertOriginalBytes()
    }

    // MARK: Capacity and size

    func testEntryCapExceedsOldFortyThousandAndStaysBounded() throws {
        let folder = "/Volumes/Archive/Big"
        let entries = SyntheticArchiveEntries.make(count: 45_000, root: folder)
        let data = try XCTUnwrap(ArchiveMetadataIndex.encode(entries, context: "c", folderPath: folder))
        XCTAssertLessThanOrEqual(data.count, ArchiveMetadataIndex.maximumSnapshotBytes)
        let decoded = try XCTUnwrap(ArchiveMetadataIndex.decode(data, context: "c", folderPath: folder))
        XCTAssertEqual(decoded.count, 45_000, "v1 kept at most 40,000 entries")
        XCTAssertGreaterThanOrEqual(ArchiveMetadataIndex.maximumEntries, 200_000)
        XCTAssertLessThan(Double(data.count) / Double(entries.count), 100, "about 10x smaller than v1's ~775 B")
        XCTAssertGreaterThanOrEqual(Double(try SyntheticArchiveEntries.legacyJSON(Array(entries.prefix(2_000)),
            context: "c").count) / Double(try XCTUnwrap(ArchiveMetadataIndex.encode(Array(entries.prefix(2_000)),
            context: "c", folderPath: folder)).count), 8)
    }

    func testEncoderStopsAtEntryCap() throws {
        let folder = "/V/F"
        let entries = SyntheticArchiveEntries.make(count: ArchiveMetadataIndex.maximumEntries + 25, root: folder)
        let data = try XCTUnwrap(ArchiveMetadataIndex.encode(entries, context: "c", folderPath: folder))
        XCTAssertLessThanOrEqual(data.count, ArchiveMetadataIndex.maximumSnapshotBytes)
        XCTAssertEqual(ArchiveMetadataIndex.decode(data, context: "c", folderPath: folder)?.count,
                       ArchiveMetadataIndex.maximumEntries)
    }

    // MARK: Measurements (opt-in)

    /// LOUPPE_ARCHIVE_INDEX_BENCHMARK=1 measures synthetic 17k/100k sets.
    /// LOUPPE_ARCHIVE_INDEX_REAL_V1=<copy of a v1 snapshot> adds a real file.
    func testCompactFormatBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOUPPE_ARCHIVE_INDEX_BENCHMARK"] == "1" else {
            throw XCTSkip("Set LOUPPE_ARCHIVE_INDEX_BENCHMARK=1 to measure the metadata snapshot format.")
        }
        func median(_ body: () throws -> Void) rethrows -> Double {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                try body()
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.seconds) * 1_000
                               + Double(elapsed.components.attoseconds) / 1e15)
            }
            return samples.sorted()[2]
        }
        func report(_ label: String, entries: [ArchiveMetadataIndex.Entry], v1: Data, context: String, folder: String) throws {
            var legacyCount = 0
            let v1Parse = try median {
                legacyCount = try JSONDecoder().decode(LegacyEnvelope.self, from: v1).entries.count
            }
            var v2: Data?
            let encode = median { v2 = ArchiveMetadataIndex.encode(entries, context: context, folderPath: folder) }
            let data = try XCTUnwrap(v2)
            var decoded: [String: ArchiveMetadataIndex.Entry]?
            let decode = median { decoded = ArchiveMetadataIndex.decode(data, context: context, folderPath: folder) }
            XCTAssertEqual(decoded?.count, entries.count)
            for entry in entries { XCTAssertEqual(decoded?[entry.path], entry) }
            print(String(format: "ARCHIVE_INDEX %@ entries=%d v1_bytes=%d v1_per_entry=%.0f v1_parse_ms=%.1f "
                + "v2_bytes=%d v2_per_entry=%.1f ratio=%.1fx v2_encode_ms=%.1f v2_decode_ms=%.1f",
                label, entries.count, v1.count, Double(v1.count) / Double(max(1, legacyCount)), v1Parse,
                data.count, Double(data.count) / Double(entries.count), Double(v1.count) / Double(data.count),
                encode, decode))
        }
        for count in [17_000, 100_000] {
            let folder = "/Volumes/WORK_FAST_A/2023-2026%20archive"
            let entries = SyntheticArchiveEntries.make(count: count, root: folder)
            let context = ArchiveMetadataIndex.currentContext
            try report("synthetic", entries: entries,
                       v1: SyntheticArchiveEntries.legacyJSON(entries, context: context), context: context, folder: folder)
        }
        if let path = environment["LOUPPE_ARCHIVE_INDEX_REAL_V1"] {
            let v1 = try Data(contentsOf: URL(fileURLWithPath: path))
            let envelope = try JSONDecoder().decode(LegacyEnvelope.self, from: v1)
            var legacy: [String: ArchiveMetadataIndex.Entry]?
            let production = try median {
                legacy = ArchiveMetadataIndex.decodeLegacy(v1, context: envelope.context, isCancelled: { false })
            }
            let entries = try XCTUnwrap(legacy).values.sorted { $0.path < $1.path }
            print(String(format: "ARCHIVE_INDEX real v1_production_load_ms=%.1f", production))
            try report("real", entries: entries, v1: v1, context: envelope.context, folder: "/Volumes/WORK_FAST_A")
        }
    }

    // MARK: Helpers

    private struct LegacyEnvelope: Decodable {
        let schemaVersion: Int
        let context: String
        let entries: [ArchiveMetadataIndex.Entry]
    }

    static func bookmarks() -> SecurityScopedFolderBookmarks.Operations {
        .init(resolve: { data in
            guard let string = String(data: data, encoding: .utf8), let url = URL(string: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return .init(url: url, isStale: false)
        }, create: { Data($0.absoluteString.utf8) },
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        access: .init(start: { _ in true }, stop: { _ in }))
    }

    static func snapshotNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { ArchiveMetadataIndex.snapshotProtectionKey(fileName: $0) != nil }
    }

    static func bucket(of snapshot: URL) throws -> String {
        let stem = snapshot.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        return String(try XCTUnwrap(parts.last))
    }
}

enum TestDigest {
    static func of(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

/// Realistic archive-like entries: one volume, sorted camera folders, a few
/// cameras/lenses, repeating exposure values and EXIF capture dates.
enum SyntheticArchiveEntries {
    struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    static func make(count: Int, root: String) -> [ArchiveMetadataIndex.Entry] {
        var generator = Generator(seed: 42)
        let cameras = ["X-T50", "NIKON Z 6_2", "X100VI", "ILCE-7M4"]
        let lenses = ["XF16-50mmF2.8-4.8 R LM WR", "NIKKOR Z 24-70mm f/4 S", "XF23mmF2 R WR", "FE 35mm F1.8"]
        let films = ["Classic Chrome", "Provia/Standard", "Acros"]
        let apertures = [1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0]
        let shutters = [1.0 / 4000, 1.0 / 1000, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30]
        let isos = [125.0, 200, 400, 800, 1600, 3200, 6400]
        let extensions = ["RAF", "NEF", "jxl", "JPG"]
        var entries: [ArchiveMetadataIndex.Entry] = []
        entries.reserveCapacity(count)
        var inode: UInt64 = 3_000_000
        for index in 0..<count {
            let roll = generator.next()
            inode &+= 1 + roll % 3
            let reference = 600_000_000 + Double(index * 7)
            let unix = Int64(reference) + 978_307_200
            var time = time_t(unix)
            var parts = tm()
            gmtime_r(&time, &parts)
            let raw = String(format: "%04d:%02d:%02d %02d:%02d:%02d", parts.tm_year + 1900, parts.tm_mon + 1,
                             parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec)
            let folder = String(format: "%04d/%02d%%20shoot%%20%04d", parts.tm_year + 1900, parts.tm_mon + 1, index / 400)
            let path = "\(root)/\(folder)/DSCF\(String(format: "%06d", index)).\(extensions[index % 4])"
            let copied = 1_700_000_000 + Int64(index / 10)
            let identity = FileOperationJournal.FileIdentity(volumeRootPath: "/Volumes/WORK_FAST_A",
                volumeUUIDString: "E639F2A1-9378-30D5-9F66-48893D73FC6C", systemNumber: 16_777_239,
                fileNumber: inode, logicalSize: 20_000_000 + Int64(roll % 40_000_000),
                modificationTime: .init(seconds: unix, nanoseconds: 0),
                statusChangeTime: .init(seconds: copied, nanoseconds: 0),
                birthTime: .init(seconds: copied, nanoseconds: 0))
            let usesFileDate = index % 10 == 9
            let capture = ArchiveMetadataIndex.Capture(
                date: Date(timeIntervalSinceReferenceDate: usesFileDate ? reference : reference + 0.125),
                source: usesFileDate ? "fileCreation" : "exifOriginal",
                rawDateTime: usesFileDate ? nil : raw, subsecondDigits: usesFileDate ? nil : "125",
                utcOffset: usesFileDate ? nil : "+01:00", assumedTimeZoneIdentifier: nil)
            let camera = index % 4
            let metadata = ArchiveMetadataIndex.Metadata(capture: capture,
                camera: usesFileDate ? nil : cameras[camera], lens: usesFileDate ? nil : lenses[camera],
                film: camera == 0 || camera == 2 ? films[Int(roll % 3)] : nil,
                aperture: usesFileDate ? nil : apertures[Int(roll % 7)],
                shutter: usesFileDate ? nil : shutters[Int((roll >> 8) % 6)],
                iso: usesFileDate ? nil : isos[Int((roll >> 16) % 7)],
                duration: nil, width: nil, height: nil, videoCodec: nil, frameRate: nil,
                videoPlayable: false, audioCodec: nil, audioPlayable: false)
            entries.append(.init(path: path, identity: identity, metadata: metadata))
        }
        return entries
    }

    /// The exact v1 writer layout: one JSON envelope with encoded entries.
    static func legacyJSON(_ entries: [ArchiveMetadataIndex.Entry], context: String) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data("{\"schemaVersion\":1,\"context\":".utf8)
        data.append(try encoder.encode(context))
        data.append(Data(",\"entries\":[".utf8))
        for (offset, entry) in entries.enumerated() {
            if offset > 0 { data.append(44) }
            data.append(try encoder.encode(entry))
        }
        data.append(Data("]}".utf8))
        return data
    }

    /// Valid magic/version/digest with empty tables and a forged entry count.
    static func forgedCount(_ count: Int, context: String, folder: String) -> Data {
        var bytes: [UInt8] = [0x4C, 0x50, 0x4D, 0x49, 2]
        func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 { bytes.append(UInt8(truncatingIfNeeded: value) | 0x80); value >>= 7 }
            bytes.append(UInt8(value))
        }
        // Context, folder binding (path-bound default) and writer folder path.
        for string in [context, folder, folder] { varint(UInt64(string.utf8.count)); bytes += Array(string.utf8) }
        varint(0); varint(0); varint(0)
        varint(UInt64(count))
        bytes += [UInt8](repeating: 0, count: 64)
        bytes += TestDigest.of(Data(bytes))
        return Data(bytes)
    }

    /// Digest-valid snapshot whose string table holds `count` empty strings
    /// and no entries: small on disk, large once decoded.
    static func forgedStringTable(_ count: Int, context: String, folder: String) -> Data {
        var bytes: [UInt8] = [0x4C, 0x50, 0x4D, 0x49, 2]
        func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 { bytes.append(UInt8(truncatingIfNeeded: value) | 0x80); value >>= 7 }
            bytes.append(UInt8(value))
        }
        for string in [context, folder, folder] { varint(UInt64(string.utf8.count)); bytes += Array(string.utf8) }
        varint(0)
        varint(UInt64(count))
        bytes += [UInt8](repeating: 0, count: count)
        varint(0); varint(0)
        bytes += TestDigest.of(Data(bytes))
        return Data(bytes)
    }
}
