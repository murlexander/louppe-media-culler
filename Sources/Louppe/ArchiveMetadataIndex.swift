import Foundation
import CryptoKit
import Darwin

/// Disposable observations, never session/decision or file-operation authority.
/// Whole-folder JSON keeps this optional cache independent of source sidecars.
/// Readers open one bounded snapshot; successful complete scans replace it once.
final class ArchiveMetadataIndex: @unchecked Sendable {
    static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    static let maximumEntries = 40_000
    static let maximumEntryBytes = 16 * 1_024
    static let maximumFolderSnapshots = 32
    static let maximumTotalBytes = 256 * 1_024 * 1_024
    private static let maintenanceLock = NSLock()

    private struct Envelope: Codable {
        let schemaVersion: Int
        let context: String
        let entries: [Entry]
    }

    private struct Entry: Codable, Equatable {
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
        let date: Date
        let source: String
        let rawDateTime: String?
        let subsecondDigits: String?
        let utcOffset: String?
        let assumedTimeZoneIdentifier: String?

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
    private let folder: URL
    private let folderIdentity: SessionPersistence.SourceFolderIdentity
    private let context: String
    private let entries: [String: Entry]
    private let extractionLock = NSLock()
    private var failedExtractions: Set<String> = []
    private var failureTrackingOverflowed = false

    init?(folder: URL,
          folderIdentity: SessionPersistence.SourceFolderIdentity? = nil,
          cacheDirectory: URL? = nil,
          isCancelled: @Sendable () -> Bool = { false }) {
        guard !isCancelled(),
              let identity = folderIdentity ?? (try? SessionPersistence.SourceFolderIdentity.capture(at: folder)),
              let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("com.alexandermarkin.louppe/archive-metadata-v1", isDirectory: true)
        else { return nil }
        self.folder = folder
        self.folderIdentity = identity
        // Folder timestamps change when its sidecar is saved. Stable identity
        // plus exact path binds the bucket without invalidating on every save.
        let folderKey = [FolderScanner.fileSystemIdentityPath(for: folder), identity.volumeUUIDString ?? identity.volumeRootPath,
            String(identity.systemNumber), String(identity.fileNumber), String(identity.birthTime.seconds),
            String(identity.birthTime.nanoseconds)].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(folderKey.utf8)).map { String(format: "%02x", $0) }.joined()
        cacheURL = directory.appendingPathComponent(digest + ".json")
        context = "\(MetadataExtractor.archiveSchemaVersion)|\(TimeZone.current.identifier)|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        entries = Self.load(cacheURL, context: context, isCancelled: isCancelled)
    }

    func metadata(for file: PhotoFile) -> Metadata? {
        guard let expected = file.scannedIdentity,
              let entry = entries[FolderScanner.fileSystemIdentityPath(for: file.url)],
              entry.identity == expected else { return nil }
        return entry.metadata
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
        if unchanged && candidates.count == entries.count { return nil }
        let encoder = JSONEncoder()
        guard let encodedContext = try? encoder.encode(context) else { return nil }
        var data = Data("{\"schemaVersion\":1,\"context\":".utf8)
        data.append(encodedContext)
        data.append(Data(",\"entries\":[".utf8))
        var count = 0
        for entry in candidates {
            if isCancelled() { return nil }
            guard let encoded = try? encoder.encode(entry), encoded.count <= Self.maximumEntryBytes else { continue }
            guard data.count + encoded.count + 3 <= Self.maximumSnapshotBytes else { break }
            if count > 0 { data.append(44) }
            data.append(encoded)
            count += 1
        }
        data.append(Data("]}".utf8))
        guard !isCancelled() else { return nil }
        return PreparedCommit(index: self, data: data)
    }

    private func commit(data: Data, isCancelled: @Sendable () -> Bool) -> Bool {
        guard !isCancelled() else { return false }
        Self.maintenanceLock.lock()
        defer { Self.maintenanceLock.unlock() }
        guard !isCancelled() else { return false }
        guard folderIdentity.matches(folder: folder) else { return true }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // No fsync/sidecar lock: this is rebuildable data, never a durable decision.
            try data.write(to: cacheURL, options: .atomic)
            Self.maintain(directory: cacheURL.deletingLastPathComponent(), preserving: cacheURL)
            return true
        } catch { return true } // Failed optional I/O still requires source revalidation.
    }

    private static func load(_ url: URL, context: String, isCancelled: @Sendable () -> Bool) -> [String: Entry] {
        guard !isCancelled() else { return [:] }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return [:] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0, status.st_size <= Int64(maximumSnapshotBytes) else { return [:] }
        // Bounded descriptor read also handles growth/replacement during reading.
        guard let data = try? handle.read(upToCount: maximumSnapshotBytes + 1),
              data.count <= maximumSnapshotBytes, !isCancelled(),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1, envelope.context == context,
              envelope.entries.count <= maximumEntries else { return [:] }
        var result: [String: Entry] = [:]
        result.reserveCapacity(envelope.entries.count)
        for entry in envelope.entries {
            if isCancelled() { return [:] }
            guard entry.path.utf8.allSatisfy({ $0 < 128 }),
                  result.updateValue(entry, forKey: entry.path) == nil,
                  entry.metadata.capture.map({ $0.evidence != nil }) ?? true
            else { return [:] }
        }
        return result
    }

    private static func maintain(directory: URL, preserving current: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        // Only our own flat digest filenames, never source files or other caches.
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            guard inspected <= 512 else { break }
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", stem.count == 64,
                  stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        files.sort { $0.date < $1.date }
        var count = files.count
        var bytes = files.reduce(0) { $0 + $1.size }
        for file in files where file.url != current {
            guard count > maximumFolderSnapshots || bytes > maximumTotalBytes else { break }
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                count -= 1
                bytes -= file.size
            }
        }
    }
}
