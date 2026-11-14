import Foundation
import CryptoKit
import Darwin

/// Rebuildable clipping evidence, one snapshot per opened folder, so a reopen
/// measures only new or changed photos. Disposable observations, never
/// decision authority: counts and dimensions only, kept apart from source
/// folders and sidecars. Readers apply the thresholds, so changing them never
/// invalidates an entry. An exact entry is never replaced by an estimate.
final class QualityCueEvidenceCache: @unchecked Sendable {
    static let maximumSnapshotBytes = 16 * 1_024 * 1_024
    static let maximumEntries = 250_000
    static let maximumPathBytes = 4 * 1_024
    static let maximumFolderSnapshots = 256
    static let maximumTotalBytes = 64 * 1_024 * 1_024
    static let snapshotExtension = "lqc"
    private static let maintenanceLock = NSLock()
    private static let magic: [UInt8] = [0x4C, 0x50, 0x51, 0x43] // "LPQC"
    private static let formatVersion: UInt8 = 1
    private static let digestBytes = 32
    private static let maximumCount = 1 << 40

    static var defaultDirectory: URL? {
        RebuildableCacheLocation.root?.appendingPathComponent(
            "com.alexandermarkin.louppe/quality-cue-evidence-v1", isDirectory: true)
    }

    /// What the stored counts mean: analyzer versions and the clipping zones.
    /// A different value discards the snapshot.
    static var analyzerContext: String {
        ["cue-evidence-1",
         RawHistogramPipeline.analysisVersion,
         "\(RawHistogramProcessor.shadowLuminanceUpperBound)-\(RawHistogramProcessor.highlightLuminanceLowerBound)",
         HistogramPipeline.analysisVersion, HistogramPipeline.wholeImageAnalysisVersion,
         HistogramPipeline.approximateAnalysisVersion,
         "\(HistogramAnalysis.nearBlackUpperBound)-\(HistogramAnalysis.nearWhiteLowerBound)",
        ].joined(separator: "|")
    }

    /// Numeric OS version and build. RawCamera ships with the system, so a
    /// different value discards RAW-decode entries only.
    static let decoderContext: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var build = ""
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0, size <= 1_024 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 {
                build = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)|\(build)"
    }()

    struct Record: Equatable, Sendable {
        /// 128 bits of SHA-256 over volume, inode, size, mtime, ctime and birth.
        let identityHigh: UInt64
        let identityLow: UInt64
        let source: HistogramAnalysisSource
        let isApproximate: Bool
        let width: Int
        let height: Int
        let sampleCount: Int
        let shadowCount: Int
        let highlightCount: Int
    }

    let cacheURL: URL
    let folder: URL
    let folderIdentity: SessionPersistence.SourceFolderIdentity
    private let requestedDirectory: URL?
    /// The folder's own spelling, then its physical one: enumeration can
    /// return `/private/tmp/…` under a logical root `/tmp`.
    private let folderPrefixes: [String]
    private let folderBinding: String
    private let analyzerContext: String
    private let decoderContext: String
    private let lock = NSLock()
    private var entries: [String: Record]
    /// Keys matched by the latest lookup pass or recorded since. Only these
    /// are written, so entries of removed or replaced files age out.
    private var liveKeys: Set<String> = []
    private var isDirty = false
    #if LOUPPE_TEST_SEAMS
    private(set) var snapshotReadsForTesting = 0
    private var snapshotWrites = 0
    var snapshotWritesForTesting: Int { lock.withLock { snapshotWrites } }
    #endif

    /// Reads at most one bounded snapshot; a missing, corrupt, oversized or
    /// foreign file is an empty cache. Call off the main actor.
    init?(folder: URL,
          folderIdentity: SessionPersistence.SourceFolderIdentity? = nil,
          cacheDirectory: URL? = nil,
          analyzerContext: String? = nil,
          decoderContext: String? = nil) {
        guard let identity = folderIdentity ?? (try? SessionPersistence.SourceFolderIdentity.capture(at: folder)),
              let directory = cacheDirectory ?? Self.defaultDirectory else { return nil }
        self.folder = folder
        self.folderIdentity = identity
        requestedDirectory = cacheDirectory
        let folderPath = FolderScanner.fileSystemIdentityPath(for: folder)
        // realpath, not `resolvingSymlinksInPath`, which drops `/private`.
        let physicalPath = folder.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return FolderScanner.fileSystemIdentityPath(
                for: URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil))
        }
        var prefixes: [String] = []
        for path in [folderPath, physicalPath].compactMap({ $0 }) {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        folderPrefixes = prefixes
        // Same binding as the metadata index: a volume UUID supersedes the
        // device number and mount root, so a remounted drive keeps its entries.
        folderBinding = ArchiveMetadataIndex.folderBinding(volumeRootPath: identity.volumeRootPath,
            volumeUUIDString: identity.volumeUUIDString, systemNumber: identity.systemNumber,
            fileNumber: identity.fileNumber, birthTime: identity.birthTime, path: folderPath)
        cacheURL = directory.appendingPathComponent(
            Self.hex(SHA256.hash(data: Data(folderBinding.utf8))) + "." + Self.snapshotExtension)
        let analyzer = analyzerContext ?? Self.analyzerContext
        let decoder = decoderContext ?? Self.decoderContext
        self.analyzerContext = analyzer
        self.decoderContext = decoder
        #if LOUPPE_TEST_SEAMS
        snapshotReadsForTesting = 1
        #endif
        let binding = folderBinding
        entries = Self.read(cacheURL, limit: Self.maximumSnapshotBytes).flatMap {
            Self.decode($0, analyzerContext: analyzer, decoderContext: decoder, folderBinding: binding)
        } ?? [:]
    }

    var hasUnsavedChanges: Bool { lock.withLock { isDirty } }

    func serves(folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity?, cacheDirectory: URL?) -> Bool {
        self.folder == folder && (folderIdentity == nil || folderIdentity == self.folderIdentity)
            && cacheDirectory == requestedDirectory
    }

    // MARK: - Lookup and recording

    /// The folder-relative percent-encoded path: exact filesystem bytes.
    private func key(for item: PhotoItem) -> String? {
        let path = FolderScanner.fileSystemIdentityPath(for: item.primaryURL)
        guard path.utf8.allSatisfy({ $0 < 128 }),
              let prefix = folderPrefixes.first(where: { path.hasPrefix($0) }),
              path.utf8.count > prefix.utf8.count,
              path.utf8.count - prefix.utf8.count <= Self.maximumPathBytes else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Nil without a scanned identity: timestamps alone cannot prove which
    /// file produced an entry. A UUID replaces the device number and mount root.
    static func identityDigest(of revision: PhotoContentRevision) -> (high: UInt64, low: UInt64)? {
        guard let file = revision.stableFileIdentity else { return nil }
        func time(_ value: PhotoContentRevision.Timestamp?) -> String {
            value.map { "\($0.seconds):\($0.nanoseconds)" } ?? "-"
        }
        let volume = file.volumeUUIDString.map { "uuid\n\($0)" }
            ?? "device\n\(file.systemNumber)\n\(file.volumeRootPath.utf8.count):\(file.volumeRootPath)"
        let text = [volume, String(file.fileNumber), file.logicalSize.map { String($0) } ?? "-",
                    time(file.modificationTime), time(file.statusChangeTime), time(file.birthTime),
                    String(revision.fileSize), revision.modificationTimeBits.map { String($0) } ?? "-",
                    revision.mediaKind.rawValue].joined(separator: "\n")
        let digest = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        func word(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
        return (word(digest[0..<8]), word(digest[8..<16]))
    }

    /// The source an exact measurement of this item reports today.
    private static func exactSource(for item: PhotoItem) -> HistogramAnalysisSource {
        RawHistogramPipeline.supportsAnalysis(for: item) ? .rawDecode : .renderedPreview
    }

    private static func evidence(for item: PhotoItem, key: String, in entries: [String: Record]) -> QualityCueEvidence? {
        guard let record = entries[key],
              let digest = Self.identityDigest(of: item.contentRevision),
              record.identityHigh == digest.high, record.identityLow == digest.low,
              record.source == (record.isApproximate ? .renderedPreview : exactSource(for: item))
        else { return nil }
        let analysis = HistogramAnalysis(bins: [], sampleCount: record.sampleCount,
            shadowCount: record.shadowCount, highlightCount: record.highlightCount,
            width: record.width, height: record.height)
        return QualityCueEvidence(item: item, analysis: analysis, source: record.source,
                                  isApproximate: record.isApproximate)
    }

    /// One pass over the session: every current photo with a valid entry.
    /// `known` items are matched but not returned. Entries the pass did not
    /// match stop being written.
    func evidence(for items: [PhotoItem], excluding known: [String: QualityCueEvidence] = [:],
                  isCancelled: @Sendable () -> Bool = { false }) -> [(String, QualityCueEvidence)] {
        var hits: [(String, QualityCueEvidence)] = []
        var live: Set<String> = []
        // A borrowed copy: the pass never holds the lock.
        let entries = lock.withLock { self.entries }
        guard !entries.isEmpty else { return [] }
        for (offset, item) in items.enumerated() {
            if offset % 1_024 == 0 && isCancelled() { return [] }
            guard item.mediaKind == .photo, item.isSupported, let key = key(for: item),
                  let evidence = Self.evidence(for: item, key: key, in: entries) else { continue }
            live.insert(key)
            if known[item.id] == nil { hits.append((item.id, evidence)) }
        }
        lock.withLock { liveKeys = live }
        return hits
    }

    /// Keeps complete measurements only: a failed or fallback one is retried.
    func record(_ evidence: QualityCueEvidence, for item: PhotoItem) {
        guard evidence.sampleCount > 0, !evidence.rawFallback,
              evidence.shadowCount >= 0, evidence.shadowCount <= evidence.sampleCount,
              evidence.highlightCount >= 0, evidence.highlightCount <= evidence.sampleCount,
              evidence.sampleCount <= Self.maximumCount,
              (0...Self.maximumCount).contains(evidence.width), (0...Self.maximumCount).contains(evidence.height),
              evidence.revision == item.contentRevision,
              evidence.source == (evidence.isApproximate ? .renderedPreview : Self.exactSource(for: item)),
              let key = key(for: item), let digest = Self.identityDigest(of: evidence.revision) else { return }
        let record = Record(identityHigh: digest.high, identityLow: digest.low, source: evidence.source,
            isApproximate: evidence.isApproximate, width: evidence.width, height: evidence.height,
            sampleCount: evidence.sampleCount, shadowCount: evidence.shadowCount,
            highlightCount: evidence.highlightCount)
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[key] {
            let sameFile = existing.identityHigh == record.identityHigh && existing.identityLow == record.identityLow
            // An estimate never replaces exact evidence of the same file.
            if sameFile && !existing.isApproximate && record.isApproximate {
                liveKeys.insert(key)
                return
            }
            if existing == record, liveKeys.contains(key) { return }
        } else if entries.count >= Self.maximumEntries {
            return
        }
        entries[key] = record
        liveKeys.insert(key)
        isDirty = true
    }

    // MARK: - Writing

    /// Writes the live entries when something was recorded since the last
    /// write. Atomic, no fsync: this is rebuildable data. Off the main actor.
    @discardableResult
    func flush() -> Bool {
        Self.maintenanceLock.lock()
        defer { Self.maintenanceLock.unlock() }
        lock.lock()
        guard isDirty else {
            lock.unlock()
            return false
        }
        let live = entries.filter { liveKeys.contains($0.key) }
        isDirty = false
        lock.unlock()
        guard let data = Self.encode(live, analyzerContext: analyzerContext, decoderContext: decoderContext,
                                     folderBinding: folderBinding) else { return false }
        do {
            let directory = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            #if LOUPPE_TEST_SEAMS
            lock.withLock { snapshotWrites += 1 }
            #endif
            Self.maintain(directory: directory, preserving: cacheURL.lastPathComponent)
            return true
        } catch {
            // A failed optional write only costs measurements after a reopen;
            // the next recorded entry writes the whole snapshot again.
            return false
        }
    }

    /// Refreshes the eviction age at most daily, so folders in use age out last.
    func noteUsed() {
        Self.maintenanceLock.lock()
        defer { Self.maintenanceLock.unlock() }
        var status = stat()
        guard cacheURL.withUnsafeFileSystemRepresentation({ $0.map { Darwin.lstat($0, &status) } ?? -1 }) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Date().timeIntervalSince1970 - Double(status.st_mtimespec.tv_sec) >= 24 * 60 * 60 else { return }
        // O_NOFOLLOW at the last component: a symlink there is never touched.
        _ = cacheURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return -1 }
            defer { Darwin.close(descriptor) }
            return futimes(descriptor, nil)
        }
    }

    /// Runs only after a snapshot write: oldest snapshots go first, by count
    /// and then by total bytes. Only our own flat digest filenames are touched.
    private static func maintain(directory: URL, preserving current: String) {
        guard let stream = directory.withUnsafeFileSystemRepresentation({ $0.map { opendir($0) } }),
              let stream else { return }
        defer { closedir(stream) }
        let descriptor = dirfd(stream)
        struct File { let name: String; let size: Int64; let date: Double }
        var files: [File] = []
        var inspected = 0
        let suffix = "." + snapshotExtension
        while let entry = readdir(stream) {
            inspected += 1
            guard inspected <= 1_024 else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.utf8.count == 64 + suffix.utf8.count, name.hasSuffix(suffix),
                  name.utf8.prefix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { continue }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            files.append(File(name: name, size: Int64(status.st_size),
                              date: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1e9))
        }
        files.sort { $0.date < $1.date }
        var count = files.count
        var bytes = files.reduce(Int64(0)) { $0 + $1.size }
        for file in files where file.name != current {
            guard count > maximumFolderSnapshots || bytes > Int64(maximumTotalBytes) else { break }
            if unlinkat(descriptor, file.name, 0) == 0 {
                count -= 1
                bytes -= file.size
            }
        }
    }

    // MARK: - Snapshot format
    //
    // "LPQC", version 1, then varint-framed: analyzer context, decoder
    // context, folder binding, entry count and entries sorted by path bytes.
    // Each entry front-codes its folder-relative path and stores the 16-byte
    // file identity digest, a flags byte (bit 0 RAW decode, bit 1 estimate)
    // and width, height, sample, shadow and highlight counts. A SHA-256 of all
    // preceding bytes ends the file.

    private static func read(_ url: URL, limit: Int) -> Data? {
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
        // The bounded read also covers growth or replacement while reading.
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    private static func appendVarint(_ value: UInt64, to bytes: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    private static func appendString(_ value: String, to bytes: inout [UInt8]) {
        appendVarint(UInt64(value.utf8.count), to: &bytes)
        bytes.append(contentsOf: value.utf8)
    }

    static func encode(_ entries: [String: Record], analyzerContext: String, decoderContext: String,
                       folderBinding: String) -> Data? {
        var bytes = magic
        bytes.append(formatVersion)
        appendString(analyzerContext, to: &bytes)
        appendString(decoderContext, to: &bytes)
        appendString(folderBinding, to: &bytes)
        // Percent-encoded ASCII paths: String order equals byte order.
        var keys = entries.keys.sorted()
        // Worst case per entry: two path varints, the path, digest, flags and
        // five count varints. Excess entries are simply measured again.
        var budget = maximumSnapshotBytes - bytes.count - 10 - digestBytes
        var kept = 0
        for key in keys.prefix(maximumEntries) {
            budget -= key.utf8.count + 20 + 16 + 1 + 50
            guard budget >= 0 else { break }
            kept += 1
        }
        keys.removeSubrange(kept...)
        appendVarint(UInt64(keys.count), to: &bytes)
        bytes.reserveCapacity(bytes.count + keys.count * 48 + digestBytes)
        var previous: [UInt8] = []
        for key in keys {
            guard let record = entries[key] else { return nil }
            let path = Array(key.utf8)
            var shared = 0
            let limit = min(path.count, previous.count)
            while shared < limit && path[shared] == previous[shared] { shared += 1 }
            appendVarint(UInt64(shared), to: &bytes)
            appendVarint(UInt64(path.count - shared), to: &bytes)
            bytes.append(contentsOf: path[shared...])
            previous = path
            for word in [record.identityHigh, record.identityLow] {
                for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
            }
            bytes.append((record.source == .rawDecode ? 1 : 0) | (record.isApproximate ? 2 : 0))
            for value in [record.width, record.height, record.sampleCount, record.shadowCount, record.highlightCount] {
                guard value >= 0 else { return nil }
                appendVarint(UInt64(value), to: &bytes)
            }
        }
        bytes.append(contentsOf: SHA256.hash(data: bytes))
        guard bytes.count <= maximumSnapshotBytes else { return nil }
        return Data(bytes)
    }

    private struct DecodeFailure: Error {}

    private struct Reader {
        let base: UnsafeRawBufferPointer
        var offset: Int
        let end: Int

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

        mutating func slice(_ count: Int) throws -> UnsafeRawBufferPointer {
            guard count >= 0, count <= end - offset else { throw DecodeFailure() }
            defer { offset += count }
            return UnsafeRawBufferPointer(rebasing: base[offset..<(offset + count)])
        }

        mutating func string(limit: Int) throws -> String {
            String(decoding: try slice(try count(limit: min(limit, end - offset))), as: UTF8.self)
        }

        mutating func word() throws -> UInt64 {
            try slice(8).reduce(0) { $0 << 8 | UInt64($1) }
        }
    }

    /// Nil for corrupt, truncated, oversized, unsupported or foreign data.
    /// Entries decoded under another OS build lose their RAW-decode results.
    static func decode(_ data: Data, analyzerContext: String, decoderContext: String,
                       folderBinding: String) -> [String: Record]? {
        guard data.count >= magic.count + 1 + digestBytes, data.count <= maximumSnapshotBytes else { return nil }
        return data.withUnsafeBytes { raw -> [String: Record]? in
            let payloadEnd = raw.count - digestBytes
            guard raw.prefix(magic.count).elementsEqual(magic), raw[magic.count] == formatVersion,
                  SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[0..<payloadEnd]))
                    .elementsEqual(raw[payloadEnd...]) else { return nil }
            var reader = Reader(base: raw, offset: magic.count + 1, end: payloadEnd)
            return try? decodePayload(&reader, analyzerContext: analyzerContext,
                                      decoderContext: decoderContext, folderBinding: folderBinding)
        }
    }

    private static func decodePayload(_ reader: inout Reader, analyzerContext: String, decoderContext: String,
                                      folderBinding: String) throws -> [String: Record]? {
        guard try reader.string(limit: maximumPathBytes) == analyzerContext else { return nil }
        let sameDecoder = try reader.string(limit: maximumPathBytes) == decoderContext
        guard try reader.string(limit: 4 * maximumPathBytes) == folderBinding else { return nil }
        let count = try reader.count(limit: min(maximumEntries, (reader.end - reader.offset) / 24))
        var result: [String: Record] = [:]
        result.reserveCapacity(count)
        var path: [UInt8] = []
        for offset in 0..<count {
            let shared = try reader.count(limit: path.count)
            let suffix = try reader.slice(try reader.count(limit: maximumPathBytes))
            // Canonical strictly increasing order also proves uniqueness.
            guard suffix.allSatisfy({ $0 < 128 }), let first = suffix.first,
                  offset == 0 || shared == path.count || first > path[shared] else { throw DecodeFailure() }
            path.removeSubrange(shared...)
            path.append(contentsOf: suffix)
            guard path.count <= maximumPathBytes else { throw DecodeFailure() }
            let high = try reader.word(), low = try reader.word()
            let flags = try reader.byte()
            guard flags < 3 else { throw DecodeFailure() }
            let width = try reader.count(limit: maximumCount), height = try reader.count(limit: maximumCount)
            let samples = try reader.count(limit: maximumCount)
            guard samples > 0 else { throw DecodeFailure() }
            let shadows = try reader.count(limit: samples), highlights = try reader.count(limit: samples)
            let source: HistogramAnalysisSource = flags & 1 != 0 ? .rawDecode : .renderedPreview
            if source == .rawDecode && !sameDecoder { continue }
            result[String(decoding: path, as: UTF8.self)] = Record(identityHigh: high, identityLow: low,
                source: source, isApproximate: flags & 2 != 0, width: width, height: height,
                sampleCount: samples, shadowCount: shadows, highlightCount: highlights)
        }
        guard reader.offset == reader.end else { return nil }
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

    #if LOUPPE_TEST_SEAMS
    /// The entries a reopen would decode from disk, sorted by path.
    func storedRecordsForTesting() -> [(path: String, record: Record)]? {
        Self.read(cacheURL, limit: Self.maximumSnapshotBytes)
            .flatMap { Self.decode($0, analyzerContext: analyzerContext, decoderContext: decoderContext,
                                   folderBinding: folderBinding) }
            .map { $0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
    }
    #endif
}
