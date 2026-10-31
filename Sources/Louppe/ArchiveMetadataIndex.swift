import Foundation
import CryptoKit
import Darwin

/// Homes for rebuildable, identity-validated caches. XCTest and LOUPPE_TESTING
/// processes get one disposable per-process root, so test runs can neither
/// evict nor pollute a person's caches. Packaged builds share the user root.
enum RebuildableCacheLocation {
    static let isTestHost: Bool = {
#if LOUPPE_TESTING
        return true
#else
        return Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || NSClassFromString("XCTestCase") != nil
#endif
    }()

    /// Stable within one process so tests can still observe warm reuse.
    static let root: URL? = {
        if isTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "Louppe-TestCaches-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }()
}

/// Disposable observations, never session/decision or file-operation authority.
/// One compact binary snapshot per folder keeps this optional cache independent
/// of source sidecars. Readers open one bounded snapshot; successful complete
/// scans replace it once.
final class ArchiveMetadataIndex: @unchecked Sendable {
    static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    static let maximumEntries = 250_000
    static let maximumEntryBytes = 16 * 1_024
    /// Count ceiling for unpinned folders. Pinned folders are exempt from it.
    static let maximumFolderSnapshots = 32
    /// Byte ceiling for all snapshots; pinned folders are evicted last.
    static let maximumTotalBytes = 256 * 1_024 * 1_024
    static let maximumProtectedFolders = 512
    /// v1 JSON ceilings. v1 is read only to migrate an existing snapshot once.
    static let maximumLegacySnapshotBytes = 32 * 1_024 * 1_024
    static let maximumLegacyEntries = 40_000
    static let snapshotExtension = "lmi"
    static let protectedListName = "pinned-folders"
    private static let maximumProtectedListBytes = 64 * 1_024
    private static let maintenanceLock = NSLock()
    private static let magic: [UInt8] = [0x4C, 0x50, 0x4D, 0x49] // "LPMI"
    private static let formatVersion: UInt8 = 2
    private static let digestBytes = 32
    private static let fixedEntryCost = 256

    static var defaultDirectory: URL? {
        RebuildableCacheLocation.root?.appendingPathComponent(
            "com.alexandermarkin.louppe/archive-metadata-v2", isDirectory: true)
    }

    static var defaultLegacyDirectory: URL? {
        RebuildableCacheLocation.root?.appendingPathComponent(
            "com.alexandermarkin.louppe/archive-metadata-v1", isDirectory: true)
    }

    static var currentContext: String {
        "\(MetadataExtractor.archiveSchemaVersion)|\(TimeZone.current.identifier)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let context: String
        let entries: [Entry]
    }

    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let identity: FileOperationJournal.FileIdentity
        let metadata: Metadata
    }

    /// Explicitly excludes ratings, review timestamps, recovery and lineage.
    struct Metadata: Codable, Equatable, Sendable {
        let capture: Capture?
        let camera: String?
        let lens: String?
        let film: String?
        let aperture: Double?
        let shutter: Double?
        let iso: Double?
        let duration: Double?
        let width: Double?
        let height: Double?
        let videoCodec: String?
        let frameRate: Double?
        let videoPlayable: Bool
        let audioCodec: String?
        let audioPlayable: Bool

        init(capture: Capture?, camera: String?, lens: String?, film: String?, aperture: Double?,
             shutter: Double?, iso: Double?, duration: Double?, width: Double?, height: Double?,
             videoCodec: String?, frameRate: Double?, videoPlayable: Bool, audioCodec: String?,
             audioPlayable: Bool) {
            self.capture = capture
            self.camera = camera
            self.lens = lens
            self.film = film
            self.aperture = aperture
            self.shutter = shutter
            self.iso = iso
            self.duration = duration
            self.width = width
            self.height = height
            self.videoCodec = videoCodec
            self.frameRate = frameRate
            self.videoPlayable = videoPlayable
            self.audioCodec = audioCodec
            self.audioPlayable = audioPlayable
        }

        init(_ file: PhotoFile) {
            capture = file.captureDateEvidence.map(Capture.init)
            camera = file.cameraModel
            lens = file.lensModel
            film = file.filmSimulation?.rawValue
            aperture = file.aperture
            shutter = file.shutterSpeed
            iso = file.iso
            duration = file.duration
            width = file.videoDimensions.map { Double($0.width) }
            height = file.videoDimensions.map { Double($0.height) }
            videoCodec = file.videoCodec
            frameRate = file.videoFrameRate
            videoPlayable = file.videoIsPlayable
            audioCodec = file.audioCodec
            audioPlayable = file.audioIsPlayable
        }

        func applying(to file: PhotoFile) -> PhotoFile {
            let decision = file.metadataSnapshot
            // Path, type, filesystem fallback dates, size, identity and all
            // decisions always come from this opening's fresh physical record.
            let evidence = capture?.evidence
            let refreshedEvidence = evidence?.source == .fileCreation
                ? file.captureDateEvidence : evidence
            let dimensions: CGSize?
            if let width, let height {
                dimensions = VideoMetadataExtractor.sanitizedDimensions(width: CGFloat(width), height: CGFloat(height))
            } else { dimensions = nil }
            return PhotoFile(
                id: file.id, url: file.url, displayRelativePath: file.legacyPersistenceID,
                captureDate: refreshedEvidence?.date ?? file.captureDate,
                captureDateEvidence: refreshedEvidence ?? file.captureDateEvidence,
                cameraModel: camera, lensModel: lens,
                filmSimulation: film.flatMap(FujiFilmSimulation.init(rawValue:)),
                aperture: MediaNumeric.aperture(aperture), shutterSpeed: MediaNumeric.shutterSpeed(shutter),
                iso: MediaNumeric.iso(iso), mediaKind: file.mediaKind,
                duration: MediaNumeric.duration(duration), videoDimensions: dimensions,
                videoCodec: videoCodec, videoFrameRate: MediaNumeric.frameRate(frameRate),
                videoIsPlayable: videoPlayable, audioCodec: audioCodec, audioIsPlayable: audioPlayable,
                modificationDate: file.modificationDate, fileSize: file.fileSize,
                scannedIdentity: file.scannedIdentity, metadataIsLoaded: true,
                rating: decision.rating, ratedAt: decision.ratedAt,
                starRating: decision.starRating, starsChangedAt: decision.starsChangedAt,
                colorLabel: decision.colorLabel, colorChangedAt: decision.colorChangedAt
            )
        }
    }

    struct Capture: Codable, Equatable, Sendable {
        /// Index order is the v2 on-disk source code. Append only.
        fileprivate static let sources = ["exifOriginal", "exifDigitized", "tiff", "fileCreation",
                                          "photosLibrary", "unspecified"]
        let date: Date
        let source: String
        let rawDateTime: String?
        let subsecondDigits: String?
        let utcOffset: String?
        let assumedTimeZoneIdentifier: String?

        init(date: Date, source: String, rawDateTime: String?, subsecondDigits: String?,
             utcOffset: String?, assumedTimeZoneIdentifier: String?) {
            self.date = date
            self.source = source
            self.rawDateTime = rawDateTime
            self.subsecondDigits = subsecondDigits
            self.utcOffset = utcOffset
            self.assumedTimeZoneIdentifier = assumedTimeZoneIdentifier
        }

        init(_ evidence: CaptureDateEvidence) {
            date = evidence.date
            switch evidence.source {
            case .exifOriginal: source = "exifOriginal"
            case .exifDigitized: source = "exifDigitized"
            case .tiff: source = "tiff"
            case .fileCreation: source = "fileCreation"
            case .photosLibrary: source = "photosLibrary"
            case .unspecified: source = "unspecified"
            }
            rawDateTime = evidence.rawDateTime
            subsecondDigits = evidence.subsecondDigits
            utcOffset = evidence.utcOffset
            assumedTimeZoneIdentifier = evidence.assumedTimeZoneIdentifier
        }

        var evidence: CaptureDateEvidence? {
            let kind: CaptureDateEvidence.Source
            switch source {
            case "exifOriginal": kind = .exifOriginal
            case "exifDigitized": kind = .exifDigitized
            case "tiff": kind = .tiff
            case "fileCreation": kind = .fileCreation
            case "photosLibrary": kind = .photosLibrary
            case "unspecified": kind = .unspecified
            default: return nil
            }
            guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return CaptureDateEvidence(date: date, source: kind, rawDateTime: rawDateTime,
                subsecondDigits: subsecondDigits, utcOffset: utcOffset,
                assumedTimeZoneIdentifier: assumedTimeZoneIdentifier)
        }
    }

    let cacheURL: URL
    /// Mirrors `PinnedFolderIdentity` equality; also the snapshot filename prefix.
    let protectionKey: String
    private let folder: URL
    private let folderPath: String
    /// Volume/folder evidence that owns the bucket; see `folderBinding(for:path:)`.
    private let folderBinding: String
    private let folderIdentity: SessionPersistence.SourceFolderIdentity
    private let context: String
    private let entries: [String: Entry]
    private let extractionLock = NSLock()
    private var failedExtractions: Set<String> = []
    private var failureTrackingOverflowed = false
    /// v1 snapshot that supplied `entries`; removed after v2 is written.
    private var migrationSource: URL?
    /// The v2 file this instance read (nil: absent). A commit writes only if
    /// it is still that file, so an older producer never replaces a newer
    /// snapshot. Guarded by `maintenanceLock` after initialization.
    private var loadedRevision: SnapshotRevision?

    private struct SnapshotRevision: Equatable {
        let device: Int64, inode: UInt64, size: Int64
        let modified: Int64, modifiedNanoseconds: Int
        let changed: Int64, changedNanoseconds: Int

        /// `lstat`: a symlink at the cache path is its own revision, never followed.
        init?(at url: URL) {
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ $0.map { Darwin.lstat($0, &info) } ?? -1 }) == 0
            else { return nil }
            device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changed = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// `cacheDirectory` holds v2 snapshots. Only the default location, or an
    /// explicit `legacyCacheDirectory`, migrates a v1 snapshot once.
    init?(folder: URL,
          folderIdentity: SessionPersistence.SourceFolderIdentity? = nil,
          cacheDirectory: URL? = nil,
          legacyCacheDirectory: URL? = nil,
          interpretationContext: String? = nil,
          isCancelled: @Sendable () -> Bool = { false }) {
        guard !isCancelled(),
              let identity = folderIdentity ?? (try? SessionPersistence.SourceFolderIdentity.capture(at: folder)),
              let directory = cacheDirectory ?? Self.defaultDirectory
        else { return nil }
        let legacyDirectory = legacyCacheDirectory ?? (cacheDirectory == nil ? Self.defaultLegacyDirectory : nil)
        self.folder = folder
        self.folderIdentity = identity
        let folderPath = FolderScanner.fileSystemIdentityPath(for: folder)
        self.folderPath = folderPath
        let folderBinding = Self.folderBinding(volumeRootPath: identity.volumeRootPath,
            volumeUUIDString: identity.volumeUUIDString, systemNumber: identity.systemNumber,
            fileNumber: identity.fileNumber, birthTime: identity.birthTime, path: folderPath)
        self.folderBinding = folderBinding
        let digest = Self.hex(SHA256.hash(data: Data(folderBinding.utf8)))
        protectionKey = Self.protectionKey(volumeRootPath: identity.volumeRootPath,
            volumeUUIDString: identity.volumeUUIDString, systemNumber: identity.systemNumber,
            fileNumber: identity.fileNumber, birthTime: identity.birthTime)
        cacheURL = directory.appendingPathComponent("\(protectionKey)-\(digest).\(Self.snapshotExtension)")
        let context = interpretationContext ?? Self.currentContext
        self.context = context
        // Taken before reading: a replacement during the read only makes a
        // later commit skip conservatively.
        loadedRevision = SnapshotRevision(at: cacheURL)
        if let current = Self.read(cacheURL, limit: Self.maximumSnapshotBytes, isCancelled: isCancelled)
            .flatMap({ Self.decode($0, context: context, folderPath: folderPath, folderBinding: folderBinding,
                                   isCancelled: isCancelled) }) {
            entries = current
        } else if let legacyURL = legacyDirectory?.appendingPathComponent(
                    Self.legacyBucket(for: identity, path: folderPath) + ".json"),
                  let legacy = Self.read(legacyURL, limit: Self.maximumLegacySnapshotBytes, isCancelled: isCancelled)
                    .flatMap({ Self.decodeLegacy($0, context: context, isCancelled: isCancelled) }) {
            // Only reached when v2 is missing or invalid: one extra open attempt.
            entries = legacy
            migrationSource = legacyURL
        } else {
            entries = [:]
        }
    }

    func metadata(for file: PhotoFile) -> Metadata? {
        guard let expected = file.scannedIdentity,
              let entry = entries[FolderScanner.fileSystemIdentityPath(for: file.url)],
              Self.cachedIdentity(entry.identity, matches: expected) else { return nil }
        return entry.metadata
    }

    /// A disposable browse projection, possibly incomplete or out of date.
    /// It never supplies inventory, decisions or identity evidence to Ready.
    func openingItems(pairingMode: RawJPEGPairingMode,
                      isCancelled: @Sendable () -> Bool) throws -> [PhotoItem] {
        try FolderScanner.cachedOpeningItems(Array(entries.values), root: folder,
            pairingMode: pairingMode, isCancelled: isCancelled)
    }

    // MARK: - Volume-stable identity

    /// Folder timestamps change when its sidecar is saved, so stable folder
    /// identity owns the bucket. macOS may remount a UUID volume with another
    /// device number or at `/Volumes/<name> 1`; the UUID, folder inode and
    /// birth time then supersede both and the path. UUID-less volumes keep
    /// the exact path, mount root and device number.
    static func folderBinding(volumeRootPath: String, volumeUUIDString: String?, systemNumber: UInt64,
                              fileNumber: UInt64, birthTime: FileOperationJournal.FileIdentity.Timestamp,
                              path: String) -> String {
        let folder = "\(fileNumber)\n\(birthTime.seconds)\n\(birthTime.nanoseconds)"
        if let volumeUUIDString {
            return "louppe-archive-folder-v2\nuuid\n\(volumeUUIDString)\n\(folder)"
        }
        // Length prefixes keep arbitrary mount-root bytes unambiguous.
        return "louppe-archive-folder-v2\ndevice\n\(systemNumber)\n\(volumeRootPath.utf8.count):\(volumeRootPath)"
            + "\n\(path.utf8.count):\(path)\n\(folder)"
    }

    /// v1 bucket name: the current mount's path and device, exactly as v1 wrote it.
    static func legacyBucket(for identity: SessionPersistence.SourceFolderIdentity, path: String) -> String {
        let key = [path, identity.volumeUUIDString ?? identity.volumeRootPath,
            String(identity.systemNumber), String(identity.fileNumber), String(identity.birthTime.seconds),
            String(identity.birthTime.nanoseconds)].joined(separator: "\n")
        return hex(SHA256.hash(data: Data(key.utf8)))
    }

    /// Mirrors `FileOperationJournal.identitiesMatch` for volumes, but every
    /// recorded content guard, including ctime, must be exactly equal. A UUID
    /// replaces the transient device number and mount root.
    static func cachedIdentity(_ cached: FileOperationJournal.FileIdentity,
                               matches current: FileOperationJournal.FileIdentity) -> Bool {
        let sameVolume: Bool
        if let uuid = current.volumeUUIDString {
            sameVolume = cached.volumeUUIDString == uuid
        } else {
            sameVolume = cached.volumeUUIDString == nil
                && cached.volumeRootPath == current.volumeRootPath
                && cached.systemNumber == current.systemNumber
        }
        return sameVolume
            && cached.fileNumber == current.fileNumber
            && cached.logicalSize == current.logicalSize
            && cached.modificationTime == current.modificationTime
            && cached.statusChangeTime == current.statusChangeTime
            && cached.birthTime == current.birthTime
    }

    /// Readiness means the scan attempted the read, not that a failed decoder
    /// produced reusable evidence. Keep this state in the per-scan cache owner
    /// rather than adding cache policy to physical files or session decisions.
    func recordExtraction(for file: PhotoFile, succeeded: Bool) {
        let path = FolderScanner.fileSystemIdentityPath(for: file.url)
        extractionLock.lock()
        defer { extractionLock.unlock() }
        if succeeded {
            failedExtractions.remove(path)
        } else if failedExtractions.count < Self.maximumEntries {
            failedExtractions.insert(path)
        } else {
            // Excess failures make this optional commit unavailable; tracking
            // must not grow with an unbounded source inventory.
            failureTrackingOverflowed = true
        }
    }

    /// Optional cache errors must never alter a successful source scan. Caller
    /// invokes only after its complete validation barrier, off the main actor.
    /// Returns whether cache filesystem work was attempted (even if it failed),
    /// requiring another source identity barrier. False never replaces the
    /// caller's original final file/folder validation or cancellation checks.
    @discardableResult
    func commit(_ items: [PhotoItem], isCancelled: @Sendable () -> Bool = { false }) -> Bool {
        prepareCommit(items, isCancelled: isCancelled)?.commit(isCancelled: isCancelled) ?? false
    }

    struct PreparedCommit: Sendable {
        fileprivate let index: ArchiveMetadataIndex
        fileprivate let data: Data

        /// True includes optional I/O failure: validate source identities again.
        @discardableResult
        func commit(isCancelled: @Sendable () -> Bool = { false }) -> Bool {
            index.commit(data: data, isCancelled: isCancelled)
        }
    }

    /// Pure preparation belongs BEFORE the caller's final file/folder barrier.
    /// Nil means unchanged/unavailable/cancelled; it never grants publication.
    /// Keeping comparison and encoding here prevents an unvalidated O(n) gap
    /// after that barrier on warm opens that need no cache filesystem work.
    func prepareCommit(_ items: [PhotoItem], isCancelled: @Sendable () -> Bool = { false }) -> PreparedCommit? {
        guard !isCancelled() else { return nil }
        extractionLock.lock()
        let failed = failedExtractions
        let overflowed = failureTrackingOverflowed
        let migrating = migrationSource != nil
        extractionLock.unlock()
        guard !overflowed else { return nil }
        var candidates: [Entry] = []
        candidates.reserveCapacity(min(items.count, Self.maximumEntries))
        var seen: Set<String> = []
        var unchanged = true
        scan: for item in items {
            for file in item.individualFiles {
                if isCancelled() { return nil }
                guard seen.count < Self.maximumEntries else { break scan }
                guard let identity = file.scannedIdentity else { continue }
                let path = FolderScanner.fileSystemIdentityPath(for: file.url)
                guard seen.insert(path).inserted, !failed.contains(path) else { continue }
                // Keep already-known hidden JPEGs without ever opening them.
                guard let metadata = file.metadataIsLoaded ? Metadata(file) : self.metadata(for: file) else { continue }
                let entry = Entry(path: path, identity: identity, metadata: metadata)
                if entries[path] != entry { unchanged = false }
                candidates.append(entry)
            }
        }
        guard !isCancelled() else { return nil }
        // Loaded snapshots already obey the snapshot/entry-count ceilings.
        // No encoding, directory maintenance or disk probes for an unchanged set.
        // Storage cannot grow on this path; every write still runs maintenance.
        // A migrated v1 snapshot is written once in v2 even when unchanged.
        if unchanged && candidates.count == entries.count && !migrating { return nil }
        guard let data = Self.encode(candidates, context: context, folderPath: folderPath,
                                     folderBinding: folderBinding, isCancelled: isCancelled) else { return nil }
        guard !isCancelled() else { return nil }
        return PreparedCommit(index: self, data: data)
    }

    private func commit(data: Data, isCancelled: @Sendable () -> Bool) -> Bool {
        guard !isCancelled() else { return false }
        Self.maintenanceLock.lock()
        defer { Self.maintenanceLock.unlock() }
        guard !isCancelled() else { return false }
        guard folderIdentity.matches(folder: folder) else { return true }
        // The identity check is I/O: a cancellation during it still writes nothing.
        guard !isCancelled() else { return false }
        // Another producer (an opening's post-Ready commit or background pin
        // preparation) replaced the snapshot after this one was read: its
        // entries may be newer, so skip. A skipped write costs only misses.
        guard SnapshotRevision(at: cacheURL) == loadedRevision else { return false }
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // No fsync/sidecar lock: this is rebuildable data, never a durable decision.
            try data.write(to: cacheURL, options: .atomic)
            loadedRevision = SnapshotRevision(at: cacheURL)
            extractionLock.lock()
            let migrated = migrationSource
            migrationSource = nil
            extractionLock.unlock()
            if let migrated {
                // unlink never follows a final symlink; absence is fine.
                _ = migrated.withUnsafeFileSystemRepresentation { $0.map { Darwin.unlink($0) } }
            }
            Self.maintain(directory: directory, preserving: cacheURL.lastPathComponent)
            return true
        } catch { return true } // Failed optional I/O still requires source revalidation.
    }

    // MARK: - Pinned-folder protection

    /// Mirrors `PinnedFolderIdentity` equality: UUID volumes ignore mount point
    /// and device; UUID-less volumes require both. 128 bits of SHA-256.
    static func protectionKey(volumeRootPath: String, volumeUUIDString: String?, systemNumber: UInt64,
                              fileNumber: UInt64, birthTime: FileOperationJournal.FileIdentity.Timestamp) -> String {
        let volume = volumeUUIDString.map { "uuid\n\($0)" } ?? "device\n\(systemNumber)\n\(volumeRootPath)"
        let key = "louppe-pin-v1\n\(volume)\n\(fileNumber)\n\(birthTime.seconds)\n\(birthTime.nanoseconds)"
        return hex(SHA256.hash(data: Data(key.utf8)).prefix(16))
    }

    private final class ProtectionRegistry: @unchecked Sendable {
        let lock = NSLock()
        var published: [String: Set<String>] = [:]
    }
    private static let protection = ProtectionRegistry()
    private static let protectionQueue = DispatchQueue(label: "louppe.archive-metadata.protection", qos: .utility)

    /// Publishes the complete pinned set. In-memory comparison only; changed
    /// sets are written asynchronously to a tiny list beside the snapshots so
    /// maintenance in a later launch honours pins before Pinned Folders loads.
    static func publishProtectedFolders(_ keys: Set<String>, in directory: URL? = defaultDirectory) {
        guard let directory else { return }
        let valid = Set(keys.filter(isProtectionKey).sorted().prefix(maximumProtectedFolders))
        let id = directory.standardizedFileURL.path
        let changed = protection.lock.withLock { () -> Bool in
            guard protection.published[id] != valid else { return false }
            protection.published[id] = valid
            return true
        }
        guard changed else { return }
        protectionQueue.async {
            // A newer publication supersedes this one and writes its own set.
            guard protection.lock.withLock({ protection.published[id] }) == valid else { return }
            let text = (["LPIN1"] + valid.sorted()).joined(separator: "\n")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: directory.appendingPathComponent(protectedListName), options: .atomic)
        }
    }

    static func protectedKeys(in directory: URL) -> Set<String> {
        let id = directory.standardizedFileURL.path
        if let published = protection.lock.withLock({ protection.published[id] }) { return published }
        guard let data = read(directory.appendingPathComponent(protectedListName),
                              limit: maximumProtectedListBytes, isCancelled: { false }) else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "LPIN1" else { return [] }
        return Set(lines.dropFirst().prefix(maximumProtectedFolders).map(String.init).filter(isProtectionKey))
    }

    private static func isProtectionKey(_ key: String) -> Bool {
        key.utf8.count == 32 && key.utf8.allSatisfy(isLowerHex)
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    /// `<32 hex protection>-<64 hex bucket>.lmi`; nil for every other name.
    static func snapshotProtectionKey(fileName name: String) -> String? {
        let bytes = Array(name.utf8)
        let suffix = Array(".\(snapshotExtension)".utf8)
        guard bytes.count == 32 + 1 + 64 + suffix.count, bytes[32] == 45,
              Array(bytes[(97)...]) == suffix,
              bytes[0..<32].allSatisfy(isLowerHex), bytes[33..<97].allSatisfy(isLowerHex) else { return nil }
        return String(decoding: bytes[0..<32], as: UTF8.self)
    }

    #if DEBUG
    static func waitForProtectionPublicationForTesting() { protectionQueue.sync {} }
    /// Simulates a relaunch: maintenance falls back to the persisted list.
    static func forgetPublishedProtectionForTesting(in directory: URL) {
        let id = directory.standardizedFileURL.path
        _ = protection.lock.withLock { protection.published.removeValue(forKey: id) }
    }
    func storedEntriesForTesting() -> [Entry]? {
        Self.read(cacheURL, limit: Self.maximumSnapshotBytes, isCancelled: { false })
            .flatMap { Self.decode($0, context: context, folderPath: folderPath, folderBinding: folderBinding,
                                   isCancelled: { false }) }
            .map { $0.values.sorted { $0.path < $1.path } }
    }
    var isMigratingForTesting: Bool { extractionLock.withLock { migrationSource != nil } }
    /// The v1 JSON filename this folder's current mount would migrate from.
    var legacySnapshotNameForTesting: String { Self.legacyBucket(for: folderIdentity, path: folderPath) + ".json" }
    #endif

    // MARK: - Maintenance

    /// Runs only after a snapshot write. Unpinned snapshots obey the count
    /// ceiling oldest-first; bytes evict unpinned first, then the oldest pins.
    private static func maintain(directory: URL, preserving current: String) {
        let protected = protectedKeys(in: directory)
        guard let stream = directory.withUnsafeFileSystemRepresentation({ $0.map { opendir($0) } }),
              let stream else { return }
        defer { closedir(stream) }
        let descriptor = dirfd(stream)
        struct File { let name: String; let size: Int64; let date: Double; var isProtected: Bool; let key: String }
        var files: [File] = []
        var inspected = 0
        // Only our own flat digest filenames, never source files or other caches.
        while let entry = readdir(stream) {
            inspected += 1
            guard inspected <= 1_024 else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard let key = snapshotProtectionKey(fileName: name) else { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            let date = Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9
            files.append(File(name: name, size: Int64(status.st_size), date: date,
                              isProtected: protected.contains(key), key: key))
        }
        files.sort { $0.date < $1.date }
        // A moved or remounted UUID-less pin gets a new bucket with the same key; only its
        // newest snapshot stays protected, so stale copies age out normally.
        var newestProtected: Set<String> = []
        for index in files.indices.reversed() where files[index].isProtected {
            files[index].isProtected = newestProtected.insert(files[index].key).inserted
        }
        var unprotectedCount = files.filter { !$0.isProtected }.count
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }
        for pass in [false, true] {
            for file in files where file.isProtected == pass && file.name != current {
                let overCount = !pass && unprotectedCount > maximumFolderSnapshots
                guard overCount || bytes > Int64(maximumTotalBytes) else { continue }
                if unlinkat(descriptor, file.name, 0) == 0 {
                    if !pass { unprotectedCount -= 1 }
                    bytes -= file.size
                }
            }
        }
    }

    // MARK: - Bounded reads

    private static func read(_ url: URL, limit: Int, isCancelled: @Sendable () -> Bool) -> Data? {
        guard !isCancelled() else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0, status.st_size <= Int64(limit) else { return nil }
        // Bounded descriptor read also handles growth/replacement during reading.
        guard let data = try? handle.read(upToCount: limit + 1),
              data.count <= limit, !isCancelled() else { return nil }
        return data
    }

    static func decodeLegacy(_ data: Data, context: String, isCancelled: @Sendable () -> Bool) -> [String: Entry]? {
        guard data.count <= maximumLegacySnapshotBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1, envelope.context == context,
              envelope.entries.count <= maximumLegacyEntries else { return nil }
        var result: [String: Entry] = [:]
        result.reserveCapacity(envelope.entries.count)
        for entry in envelope.entries {
            if isCancelled() { return nil }
            guard entry.path.utf8.allSatisfy({ $0 < 128 }),
                  result.updateValue(entry, forKey: entry.path) == nil,
                  entry.metadata.capture.map({ $0.evidence != nil }) ?? true
            else { return nil }
        }
        return result
    }

    // MARK: - v2 binary format
    //
    // "LPMI", version 2, then varint-framed: context, folder binding, the
    // writer's folder path (for rebasing after a remount), volume table
    // (root, optional UUID, device), string table, Double bit-pattern table,
    // entry count and entries sorted by path bytes. Each entry front-codes its
    // path, delta-codes its inode and ctime/birth seconds against mtime, and
    // references tables for volumes, strings and Doubles. A SHA-256 of all
    // preceding bytes ends the file. Nothing here is a decision or lineage.

    private struct VolumeKey: Hashable {
        let root: String
        let uuid: String?
        let device: UInt64
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
                value >>= 7
            }
            bytes.append(UInt8(value))
        }

        mutating func count(_ value: Int) { varint(UInt64(value)) }
        mutating func signed(_ value: Int64) { varint(UInt64(bitPattern: (value << 1) ^ (value >> 63))) }

        mutating func string(_ value: String) {
            count(value.utf8.count)
            bytes.append(contentsOf: value.utf8)
        }

        mutating func raw64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func frontCoded(_ value: [UInt8], after previous: inout [UInt8]) {
            var shared = 0
            let limit = min(value.count, previous.count)
            while shared < limit && value[shared] == previous[shared] { shared += 1 }
            count(shared)
            count(value.count - shared)
            bytes.append(contentsOf: value[shared...])
            previous = value
        }
    }

    private struct DecodeFailure: Error {}

    private struct Reader {
        let base: UnsafeRawBufferPointer
        var offset: Int
        let end: Int

        var remaining: Int { end - offset }

        mutating func byte() throws -> UInt8 {
            guard offset < end else { throw DecodeFailure() }
            defer { offset += 1 }
            return base[offset]
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try byte()
                guard shift < 63 || byte <= 1 else { throw DecodeFailure() }
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }

        mutating func count(limit: Int) throws -> Int {
            let value = try varint()
            guard limit >= 0, value <= UInt64(limit) else { throw DecodeFailure() }
            return Int(value)
        }

        mutating func signed() throws -> Int64 {
            let value = try varint()
            return Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
        }

        mutating func slice(_ count: Int) throws -> UnsafeRawBufferPointer {
            guard count >= 0, count <= remaining else { throw DecodeFailure() }
            defer { offset += count }
            return UnsafeRawBufferPointer(rebasing: base[offset..<(offset + count)])
        }

        mutating func string(limit: Int) throws -> String {
            let length = try count(limit: min(limit, remaining))
            return String(decoding: try slice(length), as: UTF8.self)
        }

        mutating func raw64() throws -> UInt64 {
            let bytes = try slice(8)
            var value: UInt64 = 0
            for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[index]) }
            return value
        }
    }

    private static func strings(of metadata: Metadata) -> [String] {
        [metadata.camera, metadata.lens, metadata.film, metadata.videoCodec, metadata.audioCodec,
         metadata.capture?.subsecondDigits, metadata.capture?.utcOffset,
         metadata.capture?.assumedTimeZoneIdentifier].compactMap { $0 }
    }

    private static func doubles(of metadata: Metadata) -> [Double] {
        [metadata.aperture, metadata.shutter, metadata.iso, metadata.duration, metadata.width,
         metadata.height, metadata.frameRate].compactMap { $0 }
    }

    /// Conservative upper bound for one entry, excluding first table use.
    private static func cost(of entry: Entry) -> Int? {
        guard entry.path.utf8.allSatisfy({ $0 < 128 }),
              doubles(of: entry.metadata).allSatisfy(\.isFinite) else { return nil }
        if let capture = entry.metadata.capture {
            guard Capture.sources.contains(capture.source),
                  capture.date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        }
        return fixedEntryCost + entry.path.utf8.count + (entry.metadata.capture?.rawDateTime?.utf8.count ?? 0)
            + strings(of: entry.metadata).reduce(0) { $0 + $1.utf8.count }
    }

    /// Keeps the first encodable candidates in scan order up to the entry cap,
    /// then writes them sorted by path. Byte accounting is exact: each entry is
    /// admitted only while its worst case still fits the snapshot cap.
    /// `folderBinding` defaults to `folderPath` for path-bound callers.
    static func encode(_ candidates: [Entry], context: String, folderPath: String, folderBinding: String? = nil,
                       isCancelled: @Sendable () -> Bool = { false }) -> Data? {
        var selected: [Entry] = []
        selected.reserveCapacity(min(candidates.count, maximumEntries))
        for entry in candidates {
            if isCancelled() { return nil }
            guard selected.count < maximumEntries else { break }
            guard let cost = cost(of: entry), cost <= maximumEntryBytes else { continue }
            selected.append(entry)
        }
        // Percent-encoded ASCII paths: String order equals byte order.
        selected.sort { $0.path < $1.path }
        for index in selected.indices.dropFirst() where selected[index - 1].path == selected[index].path {
            return nil // Callers deduplicate; never write an ambiguous snapshot.
        }
        var stringIndex: [String: Int] = [:], stringTable = Writer()
        var doubleIndex: [UInt64: Int] = [:], doubleTable = Writer()
        var volumeIndex: [VolumeKey: Int] = [:], volumeTable = Writer()
        var body = Writer()
        body.bytes.reserveCapacity(min(selected.count * 96, maximumSnapshotBytes))
        var header = Writer()
        header.bytes.append(contentsOf: magic)
        header.bytes.append(formatVersion)
        header.string(context)
        header.string(folderBinding ?? folderPath)
        header.string(folderPath)
        // Five table/entry count varints are at most 10 bytes each.
        let fixed = header.bytes.count + 5 * 10 + digestBytes
        var written = 0
        var previousPath: [UInt8] = []
        var previousRaw: [UInt8] = []
        var previousFile: UInt64 = 0
        func stringReference(_ value: String?) {
            guard let value else { return }
            if let index = stringIndex[value] { body.count(index); return }
            stringIndex[value] = stringIndex.count
            stringTable.string(value)
            body.count(stringIndex.count - 1)
        }
        func doubleReference(_ value: Double?) {
            guard let value else { return }
            if let index = doubleIndex[value.bitPattern] { body.count(index); return }
            doubleIndex[value.bitPattern] = doubleIndex.count
            doubleTable.raw64(value.bitPattern)
            body.count(doubleIndex.count - 1)
        }
        for entry in selected {
            if written % 1_024 == 0 && isCancelled() { return nil }
            let identity = entry.identity
            let volume = VolumeKey(root: identity.volumeRootPath, uuid: identity.volumeUUIDString,
                                   device: identity.systemNumber)
            // Worst case: fixed fields, full path, every string/Double new.
            let entryCost: Int = cost(of: entry) ?? maximumEntryBytes
            let tableCost: Int = strings(of: entry.metadata).reduce(0) { $0 + 10 + $1.utf8.count }
            let volumeCost: Int = 32 + volume.root.utf8.count + (volume.uuid?.utf8.count ?? 0)
            let worstCase: Int = entryCost + 8 * 10 + 7 * 8 + tableCost + volumeCost
            let tables: Int = stringTable.bytes.count + doubleTable.bytes.count + volumeTable.bytes.count
            let used: Int = fixed + tables + body.bytes.count
            guard used + worstCase <= maximumSnapshotBytes else { break }
            written += 1
            body.frontCoded(Array(entry.path.utf8), after: &previousPath)
            if let index = volumeIndex[volume] {
                body.count(index)
            } else {
                volumeIndex[volume] = volumeIndex.count
                volumeTable.string(volume.root)
                volumeTable.bytes.append(volume.uuid == nil ? 0 : 1)
                if let uuid = volume.uuid { volumeTable.string(uuid) }
                volumeTable.varint(volume.device)
                body.count(volumeIndex.count - 1)
            }
            body.signed(Int64(bitPattern: identity.fileNumber &- previousFile))
            previousFile = identity.fileNumber
            var flags: UInt8 = 0
            if identity.logicalSize != nil { flags |= 1 }
            if identity.modificationTime != nil { flags |= 2 }
            if identity.statusChangeTime != nil { flags |= 4 }
            if identity.birthTime != nil { flags |= 8 }
            body.bytes.append(flags)
            if let size = identity.logicalSize { body.signed(size) }
            let base = identity.modificationTime?.seconds ?? 0
            if let time = identity.modificationTime { body.signed(time.seconds); body.signed(time.nanoseconds) }
            for time in [identity.statusChangeTime, identity.birthTime].compactMap({ $0 }) {
                body.signed(time.seconds &- base)
                body.signed(time.nanoseconds)
            }
            let metadata = entry.metadata
            let present: [Bool] = [metadata.capture != nil, metadata.camera != nil, metadata.lens != nil,
                metadata.film != nil, metadata.aperture != nil, metadata.shutter != nil, metadata.iso != nil,
                metadata.duration != nil, metadata.width != nil, metadata.height != nil,
                metadata.videoCodec != nil, metadata.frameRate != nil, metadata.videoPlayable,
                metadata.audioCodec != nil, metadata.audioPlayable]
            var mask: UInt64 = 0
            for (bit, isPresent) in present.enumerated() where isPresent { mask |= 1 << UInt64(bit) }
            body.varint(mask)
            stringReference(metadata.camera)
            stringReference(metadata.lens)
            stringReference(metadata.film)
            for value in [metadata.aperture, metadata.shutter, metadata.iso, metadata.duration,
                          metadata.width, metadata.height] { doubleReference(value) }
            stringReference(metadata.videoCodec)
            doubleReference(metadata.frameRate)
            stringReference(metadata.audioCodec)
            if let capture = metadata.capture {
                let interval = capture.date.timeIntervalSinceReferenceDate
                let integral = interval.rounded(.towardZero) == interval && abs(interval) < 9.0e15
                var captureFlags = UInt8(Capture.sources.firstIndex(of: capture.source) ?? 0)
                if integral { captureFlags |= 1 << 3 }
                if capture.rawDateTime != nil { captureFlags |= 1 << 4 }
                if capture.subsecondDigits != nil { captureFlags |= 1 << 5 }
                if capture.utcOffset != nil { captureFlags |= 1 << 6 }
                if capture.assumedTimeZoneIdentifier != nil { captureFlags |= 1 << 7 }
                body.bytes.append(captureFlags)
                if integral { body.signed(Int64(interval)) } else { body.raw64(interval.bitPattern) }
                if let raw = capture.rawDateTime { body.frontCoded(Array(raw.utf8), after: &previousRaw) }
                stringReference(capture.subsecondDigits)
                stringReference(capture.utcOffset)
                stringReference(capture.assumedTimeZoneIdentifier)
            }
        }
        var output = header
        output.bytes.reserveCapacity(fixed + volumeTable.bytes.count + stringTable.bytes.count
                                     + doubleTable.bytes.count + body.bytes.count)
        output.count(volumeIndex.count)
        output.bytes.append(contentsOf: volumeTable.bytes)
        output.count(stringIndex.count)
        output.bytes.append(contentsOf: stringTable.bytes)
        output.count(doubleIndex.count)
        output.bytes.append(contentsOf: doubleTable.bytes)
        output.count(written)
        output.bytes.append(contentsOf: body.bytes)
        output.bytes.append(contentsOf: SHA256.hash(data: output.bytes))
        guard output.bytes.count <= maximumSnapshotBytes, !isCancelled() else { return nil }
        return Data(output.bytes)
    }

    /// Nil for corrupt, oversized, unsupported or foreign-context data. A
    /// snapshot whose binding matches but whose writer path differs (a UUID
    /// volume remounted elsewhere) returns paths rebased onto `folderPath`.
    static func decode(_ data: Data, context: String, folderPath: String, folderBinding: String? = nil,
                       isCancelled: @Sendable () -> Bool = { false }) -> [String: Entry]? {
        guard data.count >= magic.count + 1 + digestBytes, data.count <= maximumSnapshotBytes else { return nil }
        return data.withUnsafeBytes { raw -> [String: Entry]? in
            let payloadEnd = raw.count - digestBytes
            guard raw.prefix(magic.count).elementsEqual(magic), raw[magic.count] == formatVersion,
                  SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[0..<payloadEnd]))
                    .elementsEqual(raw[payloadEnd...]) else { return nil }
            var reader = Reader(base: raw, offset: magic.count + 1, end: payloadEnd)
            return try? decodePayload(&reader, context: context, folderPath: folderPath,
                                      folderBinding: folderBinding ?? folderPath, isCancelled: isCancelled)
        }
    }

    /// Directory URLs may end in "/"; compare paths below the folder without it.
    private static func pathPrefix(_ folderPath: String) -> String {
        folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
    }

    private static func decodePayload(_ reader: inout Reader, context: String, folderPath: String,
                                      folderBinding: String,
                                      isCancelled: @Sendable () -> Bool) throws -> [String: Entry]? {
        guard try reader.string(limit: maximumEntryBytes) == context,
              try reader.string(limit: maximumEntryBytes) == folderBinding else { return nil }
        let writerPath = try reader.string(limit: maximumEntryBytes)
        // Only entries below the writer's folder can be rebased; others keep
        // their stored path and simply miss.
        let rebase: (old: [UInt8], new: [UInt8])? = writerPath == folderPath
            ? nil : (Array(pathPrefix(writerPath).utf8), Array(pathPrefix(folderPath).utf8))
        // Tables precede the entry count, so bound each by what the entry cap
        // can reference (at most one volume, ten strings and seven numbers per
        // entry), not just by remaining bytes, and poll cancellation.
        var volumes: [VolumeKey] = []
        let volumeCount = try reader.count(limit: min(reader.remaining / 3, maximumEntries))
        for index in 0..<volumeCount {
            if index % 4_096 == 0 && isCancelled() { return nil }
            let root = try reader.string(limit: maximumEntryBytes)
            let hasUUID = try reader.byte()
            guard hasUUID <= 1 else { throw DecodeFailure() }
            let uuid = hasUUID == 1 ? try reader.string(limit: maximumEntryBytes) : nil
            volumes.append(VolumeKey(root: root, uuid: uuid, device: try reader.varint()))
        }
        var strings: [String] = []
        let stringCount = try reader.count(limit: min(reader.remaining, maximumEntries * 10))
        for index in 0..<stringCount {
            if index % 4_096 == 0 && isCancelled() { return nil }
            strings.append(try reader.string(limit: maximumEntryBytes))
        }
        var doubles: [Double] = []
        let doubleCount = try reader.count(limit: min(reader.remaining / 8, maximumEntries * 7))
        for index in 0..<doubleCount {
            if index % 4_096 == 0 && isCancelled() { return nil }
            doubles.append(Double(bitPattern: try reader.raw64()))
        }
        let entryLimit = min(maximumEntries, reader.remaining / 8)
        let count = try reader.count(limit: entryLimit)
        var result: [String: Entry] = [:]
        result.reserveCapacity(count)
        var previousPath: [UInt8] = []
        var previousRaw: [UInt8] = []
        var previousFile: UInt64 = 0
        func frontCoded(_ previous: inout [UInt8], requireIncreasing: Bool, ascii: Bool) throws {
            let shared = try reader.count(limit: previous.count)
            let length = try reader.count(limit: maximumEntryBytes)
            let suffix = try reader.slice(length)
            if ascii { guard suffix.allSatisfy({ $0 < 128 }) else { throw DecodeFailure() } }
            if requireIncreasing {
                // Canonical strictly increasing order also proves uniqueness.
                guard let first = suffix.first, shared == previous.count || first > previous[shared] else {
                    throw DecodeFailure()
                }
            }
            previous.removeSubrange(shared...)
            previous.append(contentsOf: suffix)
            guard previous.count <= maximumEntryBytes else { throw DecodeFailure() }
        }
        func string(_ present: Bool) throws -> String? {
            present ? strings[try reader.count(limit: strings.count - 1)] : nil
        }
        func double(_ present: Bool) throws -> Double? {
            present ? doubles[try reader.count(limit: doubles.count - 1)] : nil
        }
        for offset in 0..<count {
            if offset % 1_024 == 0 && isCancelled() { return nil }
            try frontCoded(&previousPath, requireIncreasing: offset > 0, ascii: true)
            guard offset > 0 || !previousPath.isEmpty else { throw DecodeFailure() }
            let path: String
            if let rebase, previousPath.starts(with: rebase.old) {
                path = String(decoding: rebase.new + previousPath[rebase.old.count...], as: UTF8.self)
            } else {
                path = String(decoding: previousPath, as: UTF8.self)
            }
            let volume = volumes[try reader.count(limit: volumes.count - 1)]
            let fileNumber = previousFile &+ UInt64(bitPattern: try reader.signed())
            previousFile = fileNumber
            let flags = try reader.byte()
            guard flags <= 15 else { throw DecodeFailure() }
            let size: Int64? = flags & 1 != 0 ? try reader.signed() : nil
            let modification: FileOperationJournal.FileIdentity.Timestamp? = flags & 2 != 0
                ? .init(seconds: try reader.signed(), nanoseconds: try reader.signed()) : nil
            let base = modification?.seconds ?? 0
            let change: FileOperationJournal.FileIdentity.Timestamp? = flags & 4 != 0
                ? .init(seconds: base &+ (try reader.signed()), nanoseconds: try reader.signed()) : nil
            let birth: FileOperationJournal.FileIdentity.Timestamp? = flags & 8 != 0
                ? .init(seconds: base &+ (try reader.signed()), nanoseconds: try reader.signed()) : nil
            let identity = FileOperationJournal.FileIdentity(volumeRootPath: volume.root,
                volumeUUIDString: volume.uuid, systemNumber: volume.device, fileNumber: fileNumber,
                logicalSize: size, modificationTime: modification, statusChangeTime: change, birthTime: birth)
            let mask = try reader.varint()
            guard mask < 1 << 15 else { throw DecodeFailure() }
            func has(_ bit: UInt64) -> Bool { mask & (1 << bit) != 0 }
            let camera = try string(has(1)), lens = try string(has(2)), film = try string(has(3))
            let aperture = try double(has(4)), shutter = try double(has(5)), iso = try double(has(6))
            let duration = try double(has(7)), width = try double(has(8)), height = try double(has(9))
            let videoCodec = try string(has(10)), frameRate = try double(has(11))
            let audioCodec = try string(has(13))
            var capture: Capture?
            if has(0) {
                let captureFlags = try reader.byte()
                let sourceCode = Int(captureFlags & 7)
                guard sourceCode < Capture.sources.count else { throw DecodeFailure() }
                let interval = captureFlags & (1 << 3) != 0
                    ? Double(try reader.signed()) : Double(bitPattern: try reader.raw64())
                guard interval.isFinite else { throw DecodeFailure() }
                var raw: String?
                if captureFlags & (1 << 4) != 0 {
                    try frontCoded(&previousRaw, requireIncreasing: false, ascii: false)
                    raw = String(decoding: previousRaw, as: UTF8.self)
                }
                capture = Capture(date: Date(timeIntervalSinceReferenceDate: interval),
                    source: Capture.sources[sourceCode], rawDateTime: raw,
                    subsecondDigits: try string(captureFlags & (1 << 5) != 0),
                    utcOffset: try string(captureFlags & (1 << 6) != 0),
                    assumedTimeZoneIdentifier: try string(captureFlags & (1 << 7) != 0))
            }
            let metadata = Metadata(capture: capture, camera: camera, lens: lens, film: film,
                aperture: aperture, shutter: shutter, iso: iso, duration: duration, width: width,
                height: height, videoCodec: videoCodec, frameRate: frameRate, videoPlayable: has(12),
                audioCodec: audioCodec, audioPlayable: has(14))
            // Rebasing could only collide for paths outside the folder.
            guard result.updateValue(Entry(path: path, identity: identity, metadata: metadata),
                                     forKey: path) == nil else { throw DecodeFailure() }
        }
        guard reader.remaining == 0 else { return nil }
        return result
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 15)])
        }
        return String(decoding: result, as: UTF8.self)
    }
}
