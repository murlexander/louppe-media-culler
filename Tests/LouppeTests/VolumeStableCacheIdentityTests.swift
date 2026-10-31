import Foundation
import ImageIO
import XCTest
@testable import Louppe

/// Rebuildable caches follow the same volume rule as the safety validators:
/// a volume UUID supersedes the transient device number (st_dev) and mount
/// root; UUID-less volumes keep requiring both. Content guards still reject
/// replacements. Disposable /private/tmp files and disk images only.
final class VolumeStableCacheIdentityTests: XCTestCase {
    private typealias Identity = FileOperationJournal.FileIdentity
    private typealias Stamp = FileOperationJournal.FileIdentity.Timestamp

    // MARK: Thumbnail keys

    func testThumbnailKeyIgnoresDeviceAndMountRootOnlyForUUIDVolumes() {
        let url = URL(fileURLWithPath: "/Volumes/WORK_FAST_A/2026/DSCF0001.RAF")
        let base = Self.identity()
        let remounted = Self.identity(root: "/Volumes/WORK_FAST_A 1", device: 99)
        XCTAssertEqual(ImagePipeline.cacheKey(for: Self.item(url, base)),
                       ImagePipeline.cacheKey(for: Self.item(url, remounted)))
        XCTAssertEqual(ImagePipeline.cacheKey(for: Self.item(url, base)),
                       ImagePipeline.cacheKey(for: Self.item(url, Self.identity(device: 99))))
        XCTAssertNotEqual(ImagePipeline.v5ThumbnailCacheKey(for: Self.item(url, base)),
                          ImagePipeline.v5ThumbnailCacheKey(for: Self.item(url, remounted)),
                          "v5 bound the device number; that is the defect v6 fixes")
        XCTAssertTrue(ImagePipeline.cacheKey(for: Self.item(url, base)).hasSuffix("|v6"))
        XCTAssertTrue(ImagePipeline.v5ThumbnailCacheKey(for: Self.item(url, base)).hasSuffix("|v5"))

        // UUID-less volumes keep today's stricter rule.
        let plain = Self.identity(uuid: nil)
        XCTAssertNotEqual(ImagePipeline.cacheKey(for: Self.item(url, plain)),
                          ImagePipeline.cacheKey(for: Self.item(url, Self.identity(uuid: nil, device: 99))))
        XCTAssertNotEqual(ImagePipeline.cacheKey(for: Self.item(url, plain)),
                          ImagePipeline.cacheKey(for: Self.item(url, Self.identity(root: "/Volumes/B", uuid: nil))))
        XCTAssertEqual(ImagePipeline.cacheKey(for: Self.item(url, plain)),
                       ImagePipeline.cacheKey(for: Self.item(url, Self.identity(uuid: nil))))
    }

    func testThumbnailKeyStillRejectsReplacementsAndOtherVolumes() {
        let url = URL(fileURLWithPath: "/Volumes/WORK_FAST_A/2026/DSCF0001.RAF")
        let key = ImagePipeline.cacheKey(for: Self.item(url, Self.identity()))
        let variants: [(String, Identity)] = [
            ("inode", Self.identity(inode: 8)),
            ("birth", Self.identity(birth: Stamp(seconds: 50, nanoseconds: 1))),
            ("size", Self.identity(size: 1_001)),
            ("mtime", Self.identity(mtime: Stamp(seconds: 100, nanoseconds: 1))),
            ("ctime", Self.identity(ctime: Stamp(seconds: 200, nanoseconds: 1))),
            ("other UUID", Self.identity(uuid: "OTHER-UUID")),
            ("UUID-less", Self.identity(uuid: nil)),
        ]
        for (label, identity) in variants {
            XCTAssertNotEqual(ImagePipeline.cacheKey(for: Self.item(url, identity)), key, label)
        }
        XCTAssertNotEqual(ImagePipeline.cacheKey(for: Self.item(
            URL(fileURLWithPath: "/Volumes/WORK_FAST_A/2026/Other.RAF"), Self.identity())), key,
            "the byte-exact path component is unchanged")
    }

    // MARK: v5 → v6 promotion

    func testV5ThumbnailPromotesByRenameWithoutDecodingOrReencoding() async throws {
        let folder = try Self.temporaryFolder("promote")
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try Self.invalidSourceItem(in: folder, name: "A.JPG")
        let root = folder.appendingPathComponent("cache", isDirectory: true)
        let decoder = CountingDecoder()
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, decoder: decoder.decode)
        let v5URL = Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: item), root)
        let v6URL = Self.cacheURL(ImagePipeline.cacheKey(for: item), root)
        try Self.copyFixture(to: v5URL)
        let fixture = try Data(contentsOf: v5URL)

        let thumbnail = await pipeline.thumbnail(for: item)
        XCTAssertNotNil(thumbnail, "invalid source bytes prove the pixels came from v5")
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(decoder.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v5URL.path))
        XCTAssertEqual(try Data(contentsOf: v6URL), fixture, "renamed, not re-encoded")
        XCTAssertEqual(pipeline.pendingDiskWritesForTesting.count, 0)

        // A fresh pipeline (empty memory cache) reads the promoted v6 entry.
        let reopened = await ImagePipeline(testingDiskCacheRoot: root, decoder: decoder.decode).thumbnail(for: item)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(decoder.count, 0)
    }

    func testIdentitylessV5AlsoPromotes() async throws {
        let folder = try Self.temporaryFolder("promote-identityless")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("A.JPG")
        try Data("invalid image bytes".utf8).write(to: url)
        let item = PhotoItem(primaryFile: PhotoFile(id: "A.JPG", url: url, captureDate: nil, cameraModel: nil,
            lensModel: nil, modificationDate: Date(timeIntervalSince1970: 1_650_000_000), fileSize: 19,
            scannedIdentity: nil))
        let root = folder.appendingPathComponent("cache", isDirectory: true)
        let v5URL = Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: item), root)
        try Self.copyFixture(to: v5URL)
        let thumbnail = await ImagePipeline(testingDiskCacheRoot: root).thumbnail(for: item)
        XCTAssertNotNil(thumbnail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v5URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.cacheURL(ImagePipeline.cacheKey(for: item), root).path))
    }

    func testV5EntryOfReplacedFileIsNeverPromoted() async throws {
        let folder = try Self.temporaryFolder("promote-replacement")
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Self.invalidSourceItem(in: folder, name: "A.JPG")
        let root = folder.appendingPathComponent("cache", isDirectory: true)
        let v5URL = Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: original), root)
        try Self.copyFixture(to: v5URL)

        // Same path, size and mtime; a new inode/birth/ctime.
        let url = original.primaryURL
        let mtime = try XCTUnwrap(original.primaryModificationDate)
        try FileManager.default.removeItem(at: url)
        try await Task.sleep(for: .milliseconds(20))
        try Data("invalid image bytes".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let replacement = Self.item(url, try FileOperationJournal.captureIdentity(at: url), mtime: mtime, size: 19)
        XCTAssertNotEqual(ImagePipeline.cacheKey(for: original), ImagePipeline.cacheKey(for: replacement))
        XCTAssertNotEqual(ImagePipeline.v5ThumbnailCacheKey(for: original),
                          ImagePipeline.v5ThumbnailCacheKey(for: replacement))

        let decoder = CountingDecoder()
        let thumbnail = await ImagePipeline(testingDiskCacheRoot: root, decoder: decoder.decode)
            .thumbnail(for: replacement)
        XCTAssertNil(thumbnail, "a replacement must not display the old file's pixels")
        XCTAssertEqual(decoder.count, 1, "the replacement decodes its own source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v5URL.path), "unrelated v5 entries stay untouched")
    }

    func testConcurrentCoalescedAndRacingPromotionsAllReturnPixelsOnce() async throws {
        let folder = try Self.temporaryFolder("promote-race")
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try Self.invalidSourceItem(in: folder, name: "A.JPG")
        let root = folder.appendingPathComponent("cache", isDirectory: true)
        let v5URL = Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: item), root)
        let v6URL = Self.cacheURL(ImagePipeline.cacheKey(for: item), root)
        try Self.copyFixture(to: v5URL)
        let decoder = CountingDecoder()
        // Separate pipelines share one disk root, so their operations race on
        // the same rename; each pipeline also coalesces its own callers.
        let pipelines = (0..<4).map { _ in
            ImagePipeline(testingDiskCacheRoot: root, thumbnailConcurrency: 4, decoder: decoder.decode)
        }
        let results = await withTaskGroup(of: (Bool, Bool).self) { group in
            for index in 0..<48 {
                let pipeline = pipelines[index % pipelines.count]
                let task = Task { await pipeline.thumbnail(for: item) }
                let cancelled = index % 5 == 0
                if cancelled { task.cancel() }
                group.addTask { (cancelled, await task.value != nil) }
            }
            var collected: [(Bool, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (cancelled, loaded) in results where !cancelled {
            XCTAssertTrue(loaded, "every live waiter receives promoted pixels")
        }
        for pipeline in pipelines {
            await pipeline.waitForPendingDiskWrites()
            XCTAssertEqual(pipeline.decodeWaiterCountForTesting(for: item), 0, "waiters are retired")
        }
        XCTAssertEqual(decoder.count, 0, "no racing operation fell back to a source decode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v5URL.path))
        XCTAssertTrue(Self.isDecodableImage(at: v6URL))
    }

    func testRetiredQueuedWaiterLeavesV5ForTheNextRequest() async throws {
        let folder = try Self.temporaryFolder("promote-retire")
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try Self.invalidSourceItem(in: folder, name: "A.JPG")
        let blocker = try Self.invalidSourceItem(in: folder, name: "B.JPG")
        let root = folder.appendingPathComponent("cache", isDirectory: true)
        let v5URL = Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: item), root)
        try Self.copyFixture(to: v5URL)
        let decoder = CountingDecoder(blocking: blocker.primaryURL)
        let pipeline = ImagePipeline(testingDiskCacheRoot: root, thumbnailConcurrency: 1, decoder: decoder.decode)

        let blocking = Task { await pipeline.thumbnail(for: blocker) }
        try await Self.waitUntil { decoder.blockedEntered }
        let queued = Task { await pipeline.thumbnail(for: item) }
        try await Self.waitUntil { pipeline.decodeWaiterCountForTesting(for: item) == 1 }
        queued.cancel()
        let retired = await queued.value
        XCTAssertNil(retired)
        XCTAssertEqual(pipeline.decodeWaiterCountForTesting(for: item), 0)
        decoder.release()
        _ = await blocking.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: v5URL.path), "a retired queued operation never ran")

        let loaded = await pipeline.thumbnail(for: item)
        XCTAssertNotNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v5URL.path))
        XCTAssertEqual(decoder.count, 1, "only the blocker decoded its source")
    }

    // MARK: Metadata index identity

    func testMetadataEntryMatchIgnoresDeviceAndRootOnlyForUUIDVolumes() {
        let match = ArchiveMetadataIndex.cachedIdentity
        let base = Self.identity()
        XCTAssertTrue(match(base, base))
        XCTAssertTrue(match(base, Self.identity(root: "/Volumes/WORK_FAST_A 1", device: 99)))
        XCTAssertFalse(match(base, Self.identity(uuid: "OTHER-UUID")))
        XCTAssertFalse(match(base, Self.identity(uuid: nil)))
        XCTAssertFalse(match(Self.identity(uuid: nil), base))
        for (label, changed) in [("inode", Self.identity(inode: 8)),
                                 ("birth", Self.identity(birth: Stamp(seconds: 50, nanoseconds: 1))),
                                 ("size", Self.identity(size: 1_001)),
                                 ("mtime", Self.identity(mtime: Stamp(seconds: 100, nanoseconds: 1))),
                                 ("ctime", Self.identity(ctime: Stamp(seconds: 200, nanoseconds: 1)))] {
            XCTAssertFalse(match(base, changed), label)
        }
        let plain = Self.identity(uuid: nil)
        XCTAssertTrue(match(plain, plain))
        XCTAssertFalse(match(plain, Self.identity(uuid: nil, device: 99)))
        XCTAssertFalse(match(plain, Self.identity(root: "/Volumes/B", uuid: nil)))
    }

    func testFolderBindingAndLegacyV1BucketName() throws {
        let birth = Stamp(seconds: 10, nanoseconds: 20)
        func binding(_ root: String, _ uuid: String?, _ device: UInt64, _ path: String, inode: UInt64 = 7) -> String {
            ArchiveMetadataIndex.folderBinding(volumeRootPath: root, volumeUUIDString: uuid, systemNumber: device,
                                               fileNumber: inode, birthTime: birth, path: path)
        }
        XCTAssertEqual(binding("/Volumes/A", "U", 1, "/Volumes/A/Photos/"),
                       binding("/Volumes/A 1", "U", 2, "/Volumes/A%201/Photos/"))
        XCTAssertNotEqual(binding("/Volumes/A", "U", 1, "/p/"), binding("/Volumes/A", "V", 1, "/p/"))
        XCTAssertNotEqual(binding("/Volumes/A", "U", 1, "/p/"), binding("/Volumes/A", "U", 1, "/p/", inode: 8))
        XCTAssertNotEqual(binding("/Volumes/A", nil, 1, "/p/"), binding("/Volumes/A", nil, 2, "/p/"))
        XCTAssertNotEqual(binding("/Volumes/A", nil, 1, "/p/"), binding("/Volumes/B", nil, 1, "/p/"))
        XCTAssertNotEqual(binding("/Volumes/A", nil, 1, "/p/"), binding("/Volumes/A", nil, 1, "/q/"))
        XCTAssertNotEqual(binding("/Volumes/A", nil, 1, "/p/"), binding("/Volumes/A", "U", 1, "/p/"))

        // v1 named buckets from the mount's own path and device; migration
        // must keep finding that exact name.
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: fixture.source)
        let path = FolderScanner.fileSystemIdentityPath(for: fixture.source)
        let v1Key = [path, identity.volumeUUIDString ?? identity.volumeRootPath, String(identity.systemNumber),
                     String(identity.fileNumber), String(identity.birthTime.seconds),
                     String(identity.birthTime.nanoseconds)].joined(separator: "\n")
        XCTAssertEqual(try fixture.index().legacySnapshotNameForTesting,
                       Self.hex(TestDigest.of(Data(v1Key.utf8))) + ".json")
    }

    func testSnapshotDecodeRebasesOnlyForMatchingBinding() throws {
        let old = "/Volumes/WORK_FAST_A/Photos/", new = "/Volumes/WORK_FAST_A%201/Photos/"
        let entries = SyntheticArchiveEntries.make(count: 50, root: String(old.dropLast()))
        let data = try XCTUnwrap(ArchiveMetadataIndex.encode(entries, context: "c", folderPath: old,
                                                             folderBinding: "B"))
        let same = try XCTUnwrap(ArchiveMetadataIndex.decode(data, context: "c", folderPath: old, folderBinding: "B"))
        XCTAssertEqual(Set(same.keys), Set(entries.map(\.path)))
        let moved = try XCTUnwrap(ArchiveMetadataIndex.decode(data, context: "c", folderPath: new, folderBinding: "B"))
        XCTAssertEqual(moved.count, entries.count)
        for entry in entries {
            let rebased = new + String(entry.path.dropFirst(old.count))
            XCTAssertEqual(moved[rebased]?.identity, entry.identity)
            XCTAssertEqual(moved[rebased]?.metadata, entry.metadata)
            XCTAssertEqual(moved[rebased]?.path, rebased)
        }
        XCTAssertNil(ArchiveMetadataIndex.decode(data, context: "c", folderPath: new, folderBinding: "other"))
        XCTAssertNil(ArchiveMetadataIndex.decode(data, context: "c", folderPath: old),
                     "a path-bound reader does not accept another binding")
    }

    func testRemappedDeviceNumberHitsAndOtherVolumeMisses() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        let scannedFile = try XCTUnwrap(fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
            .first).primaryFile
        let scanned = try XCTUnwrap(scannedFile.scannedIdentity)
        try XCTSkipIf(scanned.volumeUUIDString == nil, "the temporary volume exposes no UUID")
        let folder = try SessionPersistence.SourceFolderIdentity.capture(at: fixture.source)
        let remapped = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.source,
            folderIdentity: folder.remappingSourceSystemNumberForTesting(to: folder.systemNumber &+ 7),
            cacheDirectory: fixture.cache))
        XCTAssertEqual(remapped.cacheURL, try fixture.index().cacheURL, "same bucket after an st_dev change")

        func file(_ identity: Identity) -> PhotoFile {
            PhotoFile(id: scannedFile.id, url: scannedFile.url, captureDate: nil, cameraModel: nil, lensModel: nil,
                      modificationDate: scannedFile.modificationDate, fileSize: scannedFile.fileSize,
                      scannedIdentity: identity)
        }
        func with(root: String? = nil, uuid: String?? = nil, device: UInt64? = nil, inode: UInt64? = nil) -> Identity {
            Identity(volumeRootPath: root ?? scanned.volumeRootPath,
                     volumeUUIDString: uuid ?? scanned.volumeUUIDString,
                     systemNumber: device ?? scanned.systemNumber, fileNumber: inode ?? scanned.fileNumber,
                     logicalSize: scanned.logicalSize, modificationTime: scanned.modificationTime,
                     statusChangeTime: scanned.statusChangeTime, birthTime: scanned.birthTime)
        }
        XCTAssertNotNil(remapped.metadata(for: file(with(root: "/Volumes/Moved", device: scanned.systemNumber &+ 7))))
        XCTAssertNil(remapped.metadata(for: file(with(uuid: .some("00000000-0000-0000-0000-000000000000")))))
        XCTAssertNil(remapped.metadata(for: file(with(uuid: .some(nil)))))
        XCTAssertNil(remapped.metadata(for: file(with(inode: scanned.fileNumber &+ 1))))
        XCTAssertEqual(reads.total, 1)
    }

    func testMovedFolderOnSameUUIDVolumeReusesRebasedSnapshot() throws {
        let fixture = try ArchiveMetadataFixture(names: ["A.JPG", "Sub folder/B.JPG"])
        defer { fixture.remove() }
        let reads = ArchiveMetadataReads()
        _ = try fixture.prepare(FolderScanner.discoverInventory(fixture.source), reads: reads)
        XCTAssertEqual(reads.total, 2)
        let original = try fixture.index()
        try XCTSkipIf(try SessionPersistence.SourceFolderIdentity.capture(at: fixture.source).volumeUUIDString == nil,
                      "the temporary volume exposes no UUID")

        // Same directory inode and birth at a new path, like /Volumes/X → /Volumes/X 1.
        let moved = fixture.root.appendingPathComponent("moved source", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        let index = try XCTUnwrap(ArchiveMetadataIndex(folder: moved, cacheDirectory: fixture.cache))
        XCTAssertEqual(index.cacheURL, original.cacheURL)
        let items = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(moved),
            metadataReaderForTesting: { reads.read($0) }, metadataIndex: index)
        XCTAssertEqual(reads.total, 2, "no EXIF rereads after the path prefix changed")
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.cameraModel == "Archive camera" })
        let stored = try XCTUnwrap(ArchiveMetadataIndex(folder: moved, cacheDirectory: fixture.cache)?
            .storedEntriesForTesting())
        let movedPath = FolderScanner.fileSystemIdentityPath(for: moved)
        XCTAssertTrue(stored.allSatisfy { $0.path.hasPrefix(movedPath) })
    }

    // MARK: Real remount (exFAT disk image)

    /// Detaching and re-attaching with another image holding the old device
    /// node gives the same exFAT volume UUID a new st_dev, like Alex's USB
    /// drive. A third attach changes the mount path as `/Volumes/X 1` does.
    func testRealExFATRemountKeepsMetadataAndThumbnailCaches() async throws {
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Louppe-Remount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let images = DiskImages(base: base)
        defer { images.cleanUp() }
        let image = base.appendingPathComponent("volume.dmg")
        let blockerImage = base.appendingPathComponent("blocker.dmg")
        do {
            try images.create(image, name: "LVREMOUNT", megabytes: 20)
            try images.create(blockerImage, name: "LVBLOCK", megabytes: 2)
        } catch {
            throw XCTSkip("hdiutil unavailable: \(error)")
        }
        let mount = base.appendingPathComponent("mnt", isDirectory: true)
        try images.attach(image, at: mount)
        let source = mount.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try ArchiveMetadataFixture.jpeg(camera: "Archive camera").write(to: source.appendingPathComponent("A.JPG"))

        let cache = base.appendingPathComponent("metadata", isDirectory: true)
        let thumbnails = base.appendingPathComponent("thumbnails", isDirectory: true)
        let reads = ArchiveMetadataReads()
        let decoder = CountingDecoder()
        func open(_ folder: URL) throws -> (ArchiveMetadataIndex, PhotoItem) {
            let index = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache))
            let items = try FolderScanner.prepareMetadata(in: FolderScanner.discoverInventory(folder),
                metadataReaderForTesting: { reads.read($0) }, metadataIndex: index)
            return (index, try XCTUnwrap(items.first))
        }

        let (firstIndex, first) = try open(source)
        let firstIdentity = try XCTUnwrap(first.primaryFile.scannedIdentity)
        try XCTSkipIf(firstIdentity.volumeUUIDString == nil, "exFAT image exposes no volume UUID")
        XCTAssertEqual(reads.total, 1)
        let firstThumbnail = await ImagePipeline(testingDiskCacheRoot: thumbnails, decoder: decoder.decode)
            .thumbnail(for: first)
        XCTAssertNotNil(firstThumbnail)
        XCTAssertEqual(decoder.count, 1)
        try await waitForFile(Self.cacheURL(ImagePipeline.cacheKey(for: first), thumbnails))

        // Same mount point, new device number.
        try images.detach(mount)
        try images.attach(blockerImage, at: base.appendingPathComponent("blocker", isDirectory: true))
        try images.attach(image, at: mount)
        let (secondIndex, second) = try open(source)
        let secondIdentity = try XCTUnwrap(second.primaryFile.scannedIdentity)
        try XCTSkipIf(secondIdentity.systemNumber == firstIdentity.systemNumber,
                      "macOS reused the device number; remount could not be forced")
        XCTAssertEqual(secondIdentity.volumeUUIDString, firstIdentity.volumeUUIDString)
        XCTAssertEqual(secondIdentity.fileNumber, firstIdentity.fileNumber)
        XCTAssertEqual(secondIndex.cacheURL, firstIndex.cacheURL)
        XCTAssertEqual(reads.total, 1, "metadata survives an st_dev change")
        XCTAssertEqual(second.cameraModel, "Archive camera")
        XCTAssertEqual(ImagePipeline.cacheKey(for: second), ImagePipeline.cacheKey(for: first))
        XCTAssertNotEqual(ImagePipeline.v5ThumbnailCacheKey(for: second), ImagePipeline.v5ThumbnailCacheKey(for: first))
        let secondThumbnail = await ImagePipeline(testingDiskCacheRoot: thumbnails, decoder: decoder.decode)
            .thumbnail(for: second)
        XCTAssertNotNil(secondThumbnail)
        XCTAssertEqual(decoder.count, 1, "thumbnail survives an st_dev change")

        // New mount path (and possibly device): metadata survives; the
        // thumbnail key's byte-exact path component still changes.
        try images.detach(mount)
        let renamedMount = base.appendingPathComponent("mnt 1", isDirectory: true)
        try images.attach(image, at: renamedMount)
        let movedSource = renamedMount.appendingPathComponent("source", isDirectory: true)
        let (thirdIndex, third) = try open(movedSource)
        XCTAssertEqual(thirdIndex.cacheURL, firstIndex.cacheURL)
        XCTAssertEqual(reads.total, 1, "metadata survives a mount-path change")
        XCTAssertEqual(third.cameraModel, "Archive camera")

        // Replacement on the real volume still rereads.
        let target = movedSource.appendingPathComponent("A.JPG")
        let staged = movedSource.appendingPathComponent("staged.tmp")
        try ArchiveMetadataFixture.jpeg(camera: "Replacement camera body").write(to: staged)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staged, to: target)
        let (_, replaced) = try open(movedSource)
        XCTAssertEqual(reads.total, 2)
        XCTAssertEqual(replaced.cameraModel, "Replacement camera body")
    }

    // MARK: Real archive (opt-in, read-only source)

    /// LOUPPE_REAL_ARCHIVE_FOLDER=<archive folder>, with COPIES (under
    /// /private/tmp) of the thumbnail cache in LOUPPE_REAL_THUMBNAIL_CACHE_COPY
    /// and of archive-metadata-v1 in LOUPPE_REAL_METADATA_V1_COPY. The source
    /// is only enumerated and stat'ed; no EXIF reads, no writes.
    func testRealArchiveCacheCopiesPromoteAndMigrate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folderPath = environment["LOUPPE_REAL_ARCHIVE_FOLDER"],
              let thumbnailPath = environment["LOUPPE_REAL_THUMBNAIL_CACHE_COPY"],
              let v1Path = environment["LOUPPE_REAL_METADATA_V1_COPY"] else {
            throw XCTSkip("Set LOUPPE_REAL_ARCHIVE_FOLDER and cache copies to check real reuse.")
        }
        for copy in [thumbnailPath, v1Path] {
            XCTAssertTrue(copy.hasPrefix("/private/tmp/"), "experiment only on copies")
            guard copy.hasPrefix("/private/tmp/") else { return }
        }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let thumbnails = URL(fileURLWithPath: thumbnailPath, isDirectory: true)
        let started = Date()
        let inventory = try FolderScanner.discoverInventory(folder)
        let discovery = Date().timeIntervalSince(started)
        let items = inventory.items
        let standalone = items.flatMap(\.individualFiles).map { PhotoItem(primaryFile: $0) }
        let candidates = items + standalone
        var v5Hits: [PhotoItem] = [], v6Hits = 0, seen = Set<String>()
        for item in candidates where seen.insert(ImagePipeline.cacheKey(for: item)).inserted {
            if FileManager.default.fileExists(atPath: Self.cacheURL(ImagePipeline.cacheKey(for: item), thumbnails).path) {
                v6Hits += 1
            } else if FileManager.default.fileExists(
                atPath: Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: item), thumbnails).path) {
                v5Hits.append(item)
            }
        }
        let decoder = CountingDecoder()
        let pipeline = ImagePipeline(testingDiskCacheRoot: thumbnails, decoder: decoder.decode)
        let sample = Array(v5Hits.prefix(300))
        var promoted = 0
        for item in sample {
            if await pipeline.thumbnail(for: item) != nil,
               FileManager.default.fileExists(atPath: Self.cacheURL(ImagePipeline.cacheKey(for: item), thumbnails).path),
               !FileManager.default.fileExists(
                atPath: Self.cacheURL(ImagePipeline.v5ThumbnailCacheKey(for: item), thumbnails).path) {
                promoted += 1
            }
        }
        await pipeline.waitForPendingDiskWrites()
        XCTAssertEqual(decoder.count, 0, "promotion never decodes a source")
        XCTAssertEqual(promoted, sample.count)

        let v2 = URL(fileURLWithPath: v1Path).deletingLastPathComponent()
            .appendingPathComponent("v2-\(UUID().uuidString)", isDirectory: true)
        let index = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: v2,
            legacyCacheDirectory: URL(fileURLWithPath: v1Path, isDirectory: true)))
        let migrating = index.isMigratingForTesting
        let files = items.flatMap(\.individualFiles)
        let metadataHits = files.filter { index.metadata(for: $0) != nil }.count
        // Write v2 to the disposable directory (this removes the v1 copy).
        XCTAssertTrue(index.commit(items))
        let folderIdentity = try SessionPersistence.SourceFolderIdentity.capture(at: folder)
        let remapped = try XCTUnwrap(ArchiveMetadataIndex(folder: folder,
            folderIdentity: folderIdentity.remappingSourceSystemNumberForTesting(to: folderIdentity.systemNumber &+ 2),
            cacheDirectory: v2))
        XCTAssertEqual(remapped.cacheURL, index.cacheURL)
        let remappedHits = files.filter { file in
            guard let identity = file.scannedIdentity else { return false }
            let moved = Identity(volumeRootPath: identity.volumeRootPath + " 1",
                volumeUUIDString: identity.volumeUUIDString, systemNumber: identity.systemNumber &+ 2,
                fileNumber: identity.fileNumber, logicalSize: identity.logicalSize,
                modificationTime: identity.modificationTime, statusChangeTime: identity.statusChangeTime,
                birthTime: identity.birthTime)
            return remapped.metadata(for: PhotoFile(id: file.id, url: file.url, captureDate: nil, cameraModel: nil,
                lensModel: nil, modificationDate: file.modificationDate, fileSize: file.fileSize,
                scannedIdentity: moved)) != nil
        }.count
        print(String(format: "REAL_CACHE discovery_s=%.1f items=%d files=%d thumbnail_v6=%d thumbnail_v5=%d "
            + "promoted_sample=%d/%d metadata_migrating=%@ metadata_hits=%d remapped_hits=%d",
            discovery, items.count, files.count, v6Hits, v5Hits.count, promoted, sample.count,
            migrating ? "yes" : "no", metadataHits, remappedHits))
        XCTAssertTrue(migrating, "the v1 bucket for the current mount is found")
        XCTAssertEqual(remappedHits, metadataHits, "an st_dev and mount-root change keeps every hit")
        try? FileManager.default.removeItem(at: v2)
    }

    // MARK: Helpers

    private func waitForFile(_ url: URL) async throws {
        try await Self.waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was not reached")
        throw CancellationError()
    }

    private static func identity(root: String = "/Volumes/WORK_FAST_A", uuid: String? = "E639F2A1-UUID",
                                 device: UInt64 = 16_777_239, inode: UInt64 = 7, size: Int64? = 1_000,
                                 mtime: Stamp? = Stamp(seconds: 100, nanoseconds: 0),
                                 ctime: Stamp? = Stamp(seconds: 200, nanoseconds: 0),
                                 birth: Stamp? = Stamp(seconds: 50, nanoseconds: 0)) -> Identity {
        Identity(volumeRootPath: root, volumeUUIDString: uuid, systemNumber: device, fileNumber: inode,
                 logicalSize: size, modificationTime: mtime, statusChangeTime: ctime, birthTime: birth)
    }

    private static func item(_ url: URL, _ identity: Identity,
                             mtime: Date = Date(timeIntervalSince1970: 100), size: Int64 = 1_000) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: url.lastPathComponent, url: url, captureDate: nil, cameraModel: nil,
            lensModel: nil, modificationDate: mtime, fileSize: size, scannedIdentity: identity))
    }

    private static func invalidSourceItem(in folder: URL, name: String) throws -> PhotoItem {
        let url = folder.appendingPathComponent(name)
        try Data("invalid image bytes".utf8).write(to: url)
        let mtime = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return item(url, try FileOperationJournal.captureIdentity(at: url), mtime: mtime, size: 19)
    }

    private static func temporaryFolder(_ name: String) throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("louppe-volume-cache-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func cacheURL(_ key: String, _ root: URL) -> URL {
        root.appendingPathComponent(ImagePipeline.diskFileName(for: key))
    }

    private static func copyFixture(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AppIcon/AppIcon.iconset/icon_128x128.png")
        try FileManager.default.copyItem(at: fixture, to: destination)
    }

    private static func isDecodableImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Counts source decodes; optionally holds one URL's decode until released.
private final class CountingDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var entered = false
    private let blockedURL: URL?
    private let gate = DispatchSemaphore(value: 0)

    init(blocking url: URL? = nil) { blockedURL = url }

    var count: Int { lock.withLock { calls } }
    var blockedEntered: Bool { lock.withLock { entered } }
    func release() { gate.signal() }

    var decode: @Sendable (URL, CGFloat) -> CGImage? {
        { [self] url, size in
            lock.withLock { calls += 1 }
            if url == blockedURL {
                lock.withLock { entered = true }
                gate.wait()
            }
            return ImagePipeline.decodeImage(url: url, maxPixel: size)
        }
    }
}

/// Disposable disk images under one /private/tmp folder. Never touches other volumes.
private final class DiskImages {
    private let base: URL
    private var mounts: [URL] = []

    init(base: URL) { self.base = base }

    func create(_ image: URL, name: String, megabytes: Int) throws {
        try run(["create", "-quiet", "-size", "\(megabytes)m", "-fs", "ExFAT", "-volname", name,
                 "-layout", "MBRSPUD", image.path])
    }

    func attach(_ image: URL, at mount: URL) throws {
        precondition(mount.path.hasPrefix(base.path + "/"))
        try run(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        mounts.append(mount)
    }

    /// Spotlight or fseventsd can briefly hold a fresh mount; retry, then force.
    func detach(_ mount: URL) throws {
        var detached = false
        for _ in 0..<3 where !detached {
            detached = (try? run(["detach", "-quiet", mount.path])) != nil
            if !detached { Thread.sleep(forTimeInterval: 0.5) }
        }
        if !detached { try run(["detach", "-quiet", "-force", mount.path]) }
        mounts.removeAll { $0 == mount }
    }

    func cleanUp() {
        for mount in mounts.reversed() {
            if (try? run(["detach", "-quiet", mount.path])) == nil {
                try? run(["detach", "-quiet", "-force", mount.path])
            }
        }
        mounts.removeAll()
        try? FileManager.default.removeItem(at: base)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "hdiutil", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: arguments.joined(separator: " ")])
        }
    }
}
