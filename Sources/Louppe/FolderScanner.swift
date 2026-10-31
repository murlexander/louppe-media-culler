import Foundation
import Darwin
import OSLog
import UniformTypeIdentifiers

/// Recursively discovers photos in a folder and turns them into `PhotoItem`s:
/// pairs RAW+JPEG shots, reads capture dates, and sorts chronologically.
/// Pure file-system work with no UI state — safe to run on any thread.
enum FolderScanner {
    private static let logger = Logger(
        subsystem: "com.alexandermarkin.louppe",
        category: "Folder scanner"
    )

    enum ScanError: LocalizedError {
        case filesChangedDuringScan
        case fileChangedDuringMetadataLoad
        case unreadableFolder(URL, Error)

        var errorDescription: String? {
            switch self {
            case .filesChangedDuringScan:
                return L10n.text("A media file changed while Louppe was scanning. Nothing was saved; scan the folder again.")
            case .fileChangedDuringMetadataLoad:
                return L10n.text("A media file changed after scanning. Use Rescan Folder before reviewing the files separately.")
            case .unreadableFolder(let url, let error):
                return L10n.text("Couldn't read \(url.path). Nothing was saved. Check folder access and rescan. \(error.localizedDescription)")
            }
        }
    }
    /// Camera RAW formats macOS's ImageIO can decode (verified against
    /// CGImageSourceCopyTypeIdentifiers on this machine).
    static let rawExtensions: Set<String> = [
        "nef", "nrw",               // Nikon
        "raf",                      // Fujifilm
        "dng",                      // Adobe / many cameras
        "cr2", "cr3", "crw",        // Canon
        "arw", "sr2", "srf",        // Sony
        "orf",                      // Olympus
        "rw2", "raw",               // Panasonic / Leica
        "pef",                      // Pentax
        "srw",                      // Samsung
        "3fr", "fff",               // Hasselblad
        "dcr",                      // Kodak
        "mos",                      // Leaf
        "iiq",                      // Phase One
        "mrw",                      // Konica Minolta
        "erf",                      // Epson
        "rwl",                      // Leica
    ]

    /// Types we can actually decode and preview: RAWs above, plus the
    /// still-image formats ImageIO handles.
    static let supportedExtensions: Set<String> = rawExtensions.union([
        "jpg", "jpeg", "tif", "tiff",
        "png", "gif", "bmp", "heic", "heif", "hif",
        "webp", "avif", "jxl", "jp2", "psd", "tga", "ico",
    ])

    /// Movie extensions commonly found on cameras, phones, drones, and web
    /// downloads. `isVideoExtension` also asks Uniform Type Identifiers, so
    /// formats added by macOS media extensions are discovered automatically.
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg", "wmv", "flv",
        "webm", "3gp", "3g2", "mts", "m2ts", "m2v", "hevc", "insv",
    ]

    /// Common sound recordings and audio exports. `isAudioExtension` also
    /// consults Uniform Type Identifiers so formats supplied by macOS media
    /// extensions appear without a Louppe update.
    static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "amr", "caf", "flac", "m4a", "m4b",
        "mp3", "oga", "ogg", "opus", "wav", "wma",
    ]

    /// Explicit document formats; XMP remains a metadata companion, never a review item.
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "xml", "json", "csv", "tsv",
        "log", "yaml", "yml",
    ]

    static func isTextExtension(_ ext: String) -> Bool {
        textExtensions.contains(ext.lowercased())
    }

    /// Visual files we recognise but can't preview — RAW formats ImageIO
    /// doesn't decode. They show up in the session as a grey
    /// "file isn't supported" placeholder instead of being silently dropped.
    static let unsupportedVisualExtensions: Set<String> = [
        // RAW formats ImageIO can't decode
        "x3f", "kdc", "mef", "gpr",
    ]

    /// Everything we surface in a session — previewable or placeholder.
    static let recognizedExtensions: Set<String> = supportedExtensions
        .union(unsupportedVisualExtensions)
        .union(videoExtensions)
        .union(audioExtensions)
        .union(textExtensions)

    static func isVideoExtension(_ ext: String) -> Bool {
        isVideoExtension(lowercased: ext.lowercased())
    }

    private static func isVideoExtension(lowercased normalized: String) -> Bool {
        if videoExtensions.contains(normalized) { return true }
        // Known still-image formats never need a Uniform Type Identifier
        // lookup. Pairing and metadata construction ask this repeatedly, so
        // keep their common photo path to two in-memory Set lookups.
        if supportedExtensions.contains(normalized)
            || unsupportedVisualExtensions.contains(normalized)
            || audioExtensions.contains(normalized)
            || textExtensions.contains(normalized) {
            return false
        }
        return UTType(filenameExtension: normalized)?.conforms(to: .movie) == true
    }

    static func isAudioExtension(_ ext: String) -> Bool {
        isAudioExtension(lowercased: ext.lowercased())
    }

    private static func isAudioExtension(lowercased normalized: String) -> Bool {
        if audioExtensions.contains(normalized) { return true }
        if supportedExtensions.contains(normalized)
            || unsupportedVisualExtensions.contains(normalized)
            || videoExtensions.contains(normalized)
            || textExtensions.contains(normalized) {
            return false
        }
        guard let type = UTType(filenameExtension: normalized) else {
            return false
        }
        return type.conforms(to: .audio) && !type.conforms(to: .movie)
    }

    static func isRecognizedExtension(_ ext: String) -> Bool {
        recognizedExtensions.contains(ext.lowercased())
            || isVideoExtension(ext)
            || isAudioExtension(ext)
    }

    fileprivate struct FileFacts: Sendable {
        let size: Int64
        let creationDate: Date?
        let modificationDate: Date?
        let identity: FileOperationJournal.FileIdentity
    }

    /// Complete traversal and globally resolved pairing, before metadata I/O.
    /// The same physical pairs are reused by the opening projection and UI
    /// commands; ambiguous stems never acquire a provisional partner.
    struct Inventory: Sendable {
        let root: URL
        let items: [PhotoItem]
        let rawJPEGFileIDs: [(raw: String, jpeg: String)]
        let directories: [ArchiveFolderIndex.Directory]

        init(root: URL, items: [PhotoItem], rawJPEGFileIDs: [(raw: String, jpeg: String)],
             directories: [ArchiveFolderIndex.Directory] = []) {
            self.root = root
            self.items = items
            self.rawJPEGFileIDs = rawJPEGFileIDs
            self.directories = directories
        }
        var physicalFileCount: Int {
            items.reduce(0) { $0 + $1.individualFiles.count }
        }

        func physicalPairs(in preparedItems: [PhotoItem]) -> [(raw: PhotoFile, jpeg: PhotoFile)] {
            var files: [String: PhotoFile] = [:]
            files.reserveCapacity(physicalFileCount)
            for item in preparedItems {
                for file in item.individualFiles { files[file.id] = file }
            }
            return rawJPEGFileIDs.compactMap { pair in
                guard let raw = files[pair.raw], let jpeg = files[pair.jpeg] else { return nil }
                return (raw, jpeg)
            }
        }
    }

    /// Thread-safe cancellation signal for a scan. `Task.isCancelled` only
    /// reflects cancellation on the task's own thread; the scan's parallel
    /// metadata workers run on GCD threads, so callers bridge task
    /// cancellation through this flag (see `SessionStore.openFolder`).
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }

    struct PairingProjection: Sendable {
        let items: [PhotoItem]
        /// Every physical file id resolves to the displayed item that owns it.
        /// This keeps the current photo and selection stable when a JPEG item
        /// is folded into its RAW partner.
        let itemIDByFileID: [String: String]
        /// Number of hidden partner files whose metadata had to be opened.
        /// Exposed for deterministic regression checks and progress decisions.
        let enrichedFileCount: Int
    }

    /// Filename-stem equality used only for RAW+JPEG pairing.
    ///
    /// A case-insensitive volume may equate `SHOT` and `shot`, but it does not
    /// equate genuinely different accented names such as `cafe` and `café`.
    /// Unknown volume capabilities deliberately use case-sensitive matching:
    /// failing to form a real pair is safer than grouping unrelated originals.
    struct PairingFilenamePolicy: Equatable, Sendable {
        let caseSensitiveNames: Bool

        fileprivate struct Key: Hashable, Comparable {
            /// Conservative stem equality across the whole opened folder:
            /// exact bytes on case-sensitive or unknown volumes, ASCII case
            /// folding only when the volume explicitly reports
            /// case-insensitive names. A group is paired only when it contains
            /// exactly one RAW and one JPEG, so repeated camera filenames in
            /// different subfolders remain safely independent.
            let stemBytes: Data

            /// Unsigned byte order, shorter prefix first: the same order as
            /// `lexicographicallyPrecedes`, compared with `memcmp`.
            static func < (lhs: Key, rhs: Key) -> Bool {
                lhs.stemBytes.withUnsafeBytes { left in
                    rhs.stemBytes.withUnsafeBytes { right in
                        let shared = min(left.count, right.count)
                        let order = shared == 0 ? 0 : memcmp(left.baseAddress!, right.baseAddress!, shared)
                        return order != 0 ? order < 0 : left.count < right.count
                    }
                }
            }
        }

        init(caseSensitiveNames: Bool) {
            self.caseSensitiveNames = caseSensitiveNames
        }

        init(volumeSupportsCaseSensitiveNames: Bool?) {
            caseSensitiveNames = volumeSupportsCaseSensitiveNames ?? true
        }

        /// The stem of the URL's filesystem representation (its
        /// percent-encoded path when it has none), read in place.
        fileprivate func key(for url: URL) -> Key {
            url.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else {
                    return key(stemOf: Array(url.path(percentEncoded: true).utf8))
                }
                return key(stemOf: UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
            }
        }

        private func key<Path: BidirectionalCollection>(stemOf path: Path) -> Key
        where Path.Element == UInt8, Path.Index == Int {
            let filenameStart = path.lastIndex(of: 47).map { $0 + 1 } ?? path.startIndex
            let stemEnd = path[filenameStart...].lastIndex(of: 46) ?? path.endIndex
            var stem = Data(path[filenameStart..<stemEnd])
            if !caseSensitiveNames {
                for index in stem.indices where (65...90).contains(stem[index]) { stem[index] += 32 }
            }
            return Key(stemBytes: stem)
        }
    }

    /// `progress` is called periodically with the running file count. The
    /// cancellation hook lets a superseded scan stop before it walks or opens
    /// the rest of a large card; it is polled from concurrent metadata
    /// workers too, so it must be safe to call from any thread.
    static func scan(
        _ root: URL,
        pairingMode: RawJPEGPairingMode = .separate,
        isCancelled: @Sendable () -> Bool = { false },
        beforeFinalIdentityValidation: () throws -> Void = {},
        progress: (Int) -> Void
    ) throws -> [PhotoItem] {
        let recorder = SessionOpeningRecorder()
        let inventory = try discoverInventory(
            root, pairingMode: pairingMode, isCancelled: isCancelled,
            recorder: recorder, progress: progress
        )
        return try prepareMetadata(
            in: inventory, isCancelled: isCancelled,
            beforeFinalIdentityValidation: beforeFinalIdentityValidation,
            recorder: recorder
        )
    }

    /// Walks `root` and pairs its media without reading metadata.
    ///
    /// A bounded parallel name-first walk (`DiscoveryWalk`) lists each folder
    /// once and runs `lstat` only for folders and recognized media files. Its
    /// result matches the FileManager enumerator it replaced (see
    /// `legacyEnumeratorInventoryForTesting`) byte for byte: URLs, IDs,
    /// display paths, facts, identities, folder order and pairing, except that
    /// app-managed cache folders (`isAppManagedCacheFolder`) are skipped.
    /// `beforeEnumeratingURLForTesting` sees each included folder and media
    /// file in traversal order after the walk and before pairing.
    /// `walkWorkers` and `walkQoS` bound background callers (pinned-folder
    /// preparation); they never change the result.
    static func discoverInventory(
        _ root: URL,
        pairingMode: RawJPEGPairingMode = .separate,
        isCancelled: @Sendable () -> Bool = { false },
        recorder: SessionOpeningRecorder? = nil,
        beforeEnumeratingURLForTesting: ((URL) throws -> Void)? = nil,
        stageWillBegin: (SessionOpeningStage) throws -> Void = { _ in },
        walkWorkers: Int? = nil,
        walkQoS: DispatchQoS.QoSClass = .userInitiated,
        progress: (Int) -> Void = { _ in }
    ) throws -> Inventory {
        try stageWillBegin(.discovery)
        let discoveryStart = ProcessInfo.processInfo.systemUptime
        recorder?.progress(.discovery, completed: 0)
        if isCancelled() { throw CancellationError() }
        let rootDirectory = ArchiveFolderIndex.Directory(id: "", parentID: nil,
            name: root.lastPathComponent, identity: try FileOperationJournal.captureIdentity(at: root))
        let walk = DiscoveryWalk(root: root, workers: walkWorkers ?? DiscoveryWalk.maximumWorkers, qos: walkQoS)
        try walk.run(isCancelled: isCancelled) { count in
            progress(count)
            recorder?.progress(.discovery, completed: count)
        }
        var files: [URL] = []
        var facts: [FileFacts?] = []
        var directories = [rootDirectory]
        try walk.assemble(isCancelled: isCancelled) { entry in
            try beforeEnumeratingURLForTesting?(entry.url)
            switch entry {
            case .directory(let url, let identity):
                directories.append(directoryRecord(url: url, identity: identity, root: root))
            case .file(let url, let fileFacts):
                files.append(url)
                facts.append(fileFacts)
            }
        }
        if isCancelled() { throw CancellationError() }
        return try pairInventory(
            root: root, files: files, facts: facts, directories: directories,
            pairingMode: pairingMode, isCancelled: isCancelled, recorder: recorder,
            discoveryStart: discoveryStart, stageWillBegin: stageWillBegin, progress: progress
        )
    }

    /// The FileManager-enumerator discovery used before 30 October 2026.
    /// Test-only reference for proving `discoverInventory` equivalent; it is
    /// slow on FSKit volumes and does not skip app-managed cache folders.
    /// `usesLegacyPairing` also replaces pairing with the code used before
    /// the 30 October 2026 pairing optimization (`legacyPairInventory`).
    static func legacyEnumeratorInventoryForTesting(
        _ root: URL,
        pairingMode: RawJPEGPairingMode = .separate,
        isCancelled: @Sendable () -> Bool = { false },
        recorder: SessionOpeningRecorder? = nil,
        usesLegacyPairing: Bool = false
    ) throws -> Inventory {
        let discoveryStart = ProcessInfo.processInfo.systemUptime
        let fm = FileManager.default
        var enumerationError: ScanError?
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .volumeURLKey,
                .volumeUUIDStringKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationError = .unreadableFolder(url, error)
                return false
            }
        ) else {
            throw NSError(domain: "Louppe", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Could not read that folder.")])
        }
        if isCancelled() { throw CancellationError() }

        var files: [URL] = []
        var facts: [FileFacts?] = []
        var directories = [ArchiveFolderIndex.Directory(id: "", parentID: nil,
            name: root.lastPathComponent, identity: try FileOperationJournal.captureIdentity(at: root))]
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let navigationValues = try? url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey,
            ])
            // DirectoryEnumerator does not descend symbolic links and already
            // excludes package descendants through its options. Calling
            // skipDescendants() for either of these already-skipped entries
            // can suppress the next real sibling directory's children.
            if navigationValues?.isSymbolicLink == true {
                continue
            }
            if navigationValues?.isDirectory == true {
                if navigationValues?.isPackage == true {
                    continue
                }
                let values = try url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
                let identity = try FileOperationJournal.captureIdentity(at: url,
                    volumeRoot: values.volume, volumeUUIDString: values.volumeUUIDString)
                directories.append(directoryRecord(url: url, identity: identity, root: root))
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard isRecognizedExtension(ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .volumeURLKey,
                    .volumeUUIDStringKey,
                  ]) else {
                throw ScanError.filesChangedDuringScan
            }
            guard values.isRegularFile == true else { continue }
            guard let identity = try? FileOperationJournal.captureIdentity(
                    at: url,
                    volumeRoot: values.volume,
                    volumeUUIDString: values.volumeUUIDString
                  ) else {
                throw ScanError.filesChangedDuringScan
            }
            files.append(url)
            facts.append(FileFacts(
                size: Int64(values.fileSize ?? 0),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate,
                identity: identity
            ))
        }
        if isCancelled() { throw CancellationError() }
        if let enumerationError { throw enumerationError }
        if usesLegacyPairing {
            return legacyPairInventory(root: root, files: files, facts: facts, directories: directories,
                                       pairingMode: pairingMode)
        }
        return try pairInventory(
            root: root, files: files, facts: facts, directories: directories,
            pairingMode: pairingMode, isCancelled: isCancelled, recorder: recorder,
            discoveryStart: discoveryStart, stageWillBegin: { _ in }, progress: { _ in }
        )
    }

    /// Test-only reference: the pairing and lightweight-record code exactly as
    /// it was before the 30 October 2026 optimization (URL-keyed facts,
    /// per-call path work, serial construction). Equivalence tests compare
    /// `pairInventory` against it.
    private static func legacyPairInventory(
        root: URL, files: [URL], facts: [FileFacts?], directories: [ArchiveFolderIndex.Directory],
        pairingMode: RawJPEGPairingMode
    ) -> Inventory {
        var factsByURL: [URL: FileFacts] = [:]
        for (url, fact) in zip(files, facts) { factsByURL[url] = fact }
        let filenamePolicy = pairingFilenamePolicy(at: root)
        var pairIDs: [(raw: String, jpeg: String)] = []
        func key(for url: URL) -> Data {
            let path: [UInt8] = url.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else { return Array(url.path(percentEncoded: true).utf8) }
                var count = 0
                while pointer[count] != 0 { count += 1 }
                return UnsafeBufferPointer(start: pointer, count: count).map(UInt8.init(bitPattern:))
            }
            let filenameStart = path.lastIndex(of: 47).map { $0 + 1 } ?? path.startIndex
            let stemEnd = path[filenameStart...].lastIndex(of: 46) ?? path.endIndex
            let stem = Array(path[filenameStart..<stemEnd])
            return filenamePolicy.caseSensitiveNames ? Data(stem)
                : Data(stem.map { (65...90).contains($0) ? $0 + 32 : $0 })
        }
        var groups: [Data: [URL]] = [:]
        for url in files { groups[key(for: url), default: []].append(url) }
        var pairs: [(primary: URL, paired: URL?)] = []
        for groupKey in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let grouped = groups[groupKey] else { continue }
            let urls = grouped.sorted(by: stableURLOrder)
            var independentMedia: [URL] = []
            var images: [URL] = []
            for url in urls {
                if isVideoExtension(url.pathExtension)
                    || isAudioExtension(url.pathExtension)
                    || isTextExtension(url.pathExtension) {
                    independentMedia.append(url)
                } else {
                    images.append(url)
                }
            }
            for media in independentMedia { pairs.append((media, nil)) }
            let raws = images.filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            let jpegs = images.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            if raws.count == 1, jpegs.count == 1, let raw = raws.first, let jpeg = jpegs.first {
                pairIDs.append((relativeFileIdentity(of: raw, under: root),
                                relativeFileIdentity(of: jpeg, under: root)))
            }
            if pairingMode == .together, raws.count == 1, jpegs.count == 1,
               let raw = raws.first, let jpeg = jpegs.first {
                pairs.append((raw, jpeg))
                for extra in images where extra != raw && extra != jpeg { pairs.append((extra, nil)) }
            } else {
                for url in images { pairs.append((url, nil)) }
            }
        }
        func lightweight(_ url: URL) -> PhotoFile {
            let facts = factsByURL[url]
            return PhotoFile(
                id: relativeFileIdentity(of: url, under: root),
                url: url,
                displayRelativePath: relativeDisplayPath(of: url, under: root),
                captureDate: facts?.creationDate,
                captureDateEvidence: facts?.creationDate.map { CaptureDateEvidence(date: $0, source: .fileCreation) },
                cameraModel: nil,
                lensModel: nil,
                mediaKind: isTextExtension(url.pathExtension) ? .text
                    : (isVideoExtension(url.pathExtension) ? .video
                        : (isAudioExtension(url.pathExtension) ? .audio : .photo)),
                modificationDate: facts?.modificationDate,
                fileSize: facts?.size ?? 0,
                scannedIdentity: facts?.identity,
                metadataIsLoaded: false
            )
        }
        let items = pairs.map { PhotoItem(primaryFile: lightweight($0.primary), pairedFile: $0.paired.map(lightweight)) }
        return Inventory(root: root, items: items, rawJPEGFileIDs: pairIDs, directories: directories)
    }

    private static func directoryRecord(url: URL, identity: FileOperationJournal.FileIdentity,
                                        root: URL) -> ArchiveFolderIndex.Directory {
        var id = relativeFileIdentity(of: url, under: root)
        // Directory URL spellings may carry a trailing separator;
        // IDs use the same parent spelling as physical-file IDs.
        while id.hasSuffix("/") { id.removeLast() }
        let parent = id.lastIndex(of: "/").map { String(id[..<$0]) } ?? ""
        return .init(id: id, parentID: parent, name: url.lastPathComponent, identity: identity)
    }

    /// Reconstructs only a read-only opening projection from cached facts.
    /// No enumeration, file checks or metadata reads; discovery still runs in full.
    static func cachedOpeningItems(
        _ entries: [ArchiveMetadataIndex.Entry], root: URL,
        pairingMode: RawJPEGPairingMode, isCancelled: @Sendable () -> Bool
    ) throws -> [PhotoItem] {
        if isCancelled() { throw CancellationError() }
        guard !entries.isEmpty else { return [] }
        let prefix = fileSystemIdentityPath(for: root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rootedPrefix = "/" + prefix + "/"
        var files: [URL] = []
        var facts: [FileFacts?] = []
        var metadata: [String: ArchiveMetadataIndex.Metadata] = [:]
        for entry in entries {
            if isCancelled() { throw CancellationError() }
            guard entry.path.hasPrefix(rootedPrefix),
                  let url = URL(string: "file://" + entry.path), url.isFileURL,
                  fileSystemIdentityPath(for: url) == entry.path,
                  entry.path.split(separator: "/").allSatisfy({ part in
                      guard let decoded = String(part).removingPercentEncoding else { return false }
                      return decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\0")
                  }),
                  isRecognizedExtension(url.pathExtension) else { continue }
            files.append(url)
            func date(_ time: FileOperationJournal.FileIdentity.Timestamp?) -> Date? {
                time.map { Date(timeIntervalSince1970: Double($0.seconds) + Double($0.nanoseconds) / 1e9) }
            }
            facts.append(FileFacts(size: entry.identity.logicalSize ?? 0,
                creationDate: date(entry.identity.birthTime), modificationDate: date(entry.identity.modificationTime),
                identity: entry.identity))
            metadata[entry.path] = entry.metadata
        }
        let inventory = try pairInventory(root: root, files: files, facts: facts, directories: [],
            pairingMode: pairingMode, isCancelled: isCancelled, recorder: nil,
            discoveryStart: 0, stageWillBegin: { _ in }, progress: { _ in })
        func enriched(_ file: PhotoFile) -> PhotoFile {
            metadata[fileSystemIdentityPath(for: file.url)]?.applying(to: file) ?? file
        }
        if isCancelled() { throw CancellationError() }
        return sortItems(inventory.items.map {
            PhotoItem(primaryFile: enriched($0.primaryFile), pairedFile: $0.pairedFile.map(enriched))
        })
    }

    /// Shared tail of both discovery implementations: global pairing and
    /// lightweight items from the facts captured during traversal.
    /// `facts[i]` belongs to `files[i]`. Each file's path, extension and IDs
    /// are computed once; lightweight records are built in parallel into
    /// fixed slots, so the result never depends on worker timing.
    private static func pairInventory(
        root: URL,
        files: [URL],
        facts: [FileFacts?],
        directories: [ArchiveFolderIndex.Directory],
        pairingMode: RawJPEGPairingMode,
        isCancelled: @Sendable () -> Bool,
        recorder: SessionOpeningRecorder?,
        discoveryStart: TimeInterval,
        stageWillBegin: (SessionOpeningStage) throws -> Void,
        progress: (Int) -> Void
    ) throws -> Inventory {
        try stageWillBegin(.pairing)
        recorder?.progress(.pairing, completed: files.count, total: files.count)
        recorder?.record(.discovery, seconds: ProcessInfo.processInfo.systemUptime - discoveryStart)
        let pairingStart = ProcessInfo.processInfo.systemUptime
        let filenamePolicy = pairingFilenamePolicy(at: root)

        let candidates = files.map(PairingCandidate.init)
        var physicalPairs: [(raw: Int, jpeg: Int)] = []
        let pairs = pairCandidates(candidates, pairingMode: pairingMode, filenamePolicy: filenamePolicy,
                                   physicalPair: { physicalPairs.append(($0, $1)) })
        if isCancelled() { throw CancellationError() }

        let paths = RelativePaths(root: root)
        let built = try buildLightweightFiles(candidates, facts: facts, paths: paths, isCancelled: isCancelled)
        var items: [PhotoItem] = []
        items.reserveCapacity(pairs.count)
        for pair in pairs {
            items.append(PhotoItem(primaryFile: built[pair.primary], pairedFile: pair.paired.map { built[$0] }))
        }
        let pairIDs = physicalPairs.map { (raw: built[$0.raw].id, jpeg: built[$0.jpeg].id) }
        recorder?.record(.pairing, seconds: ProcessInfo.processInfo.systemUptime - pairingStart)
        recorder?.setCounts(physical: files.count, items: items.count)
        progress(files.count)
        if isCancelled() { throw CancellationError() }
        return Inventory(root: root, items: items, rawJPEGFileIDs: pairIDs, directories: directories)
    }

    /// One `lightweightFile` per candidate, in candidate order. Small inputs
    /// run on the calling thread.
    private static func buildLightweightFiles(
        _ candidates: [PairingCandidate],
        facts: [FileFacts?],
        paths: RelativePaths,
        isCancelled: @Sendable () -> Bool
    ) throws -> [PhotoFile] {
        let slots = PhotoFileSlots(count: candidates.count)
        try forEachInParallel(count: candidates.count, minimumChunk: 512, isCancelled: isCancelled) { index in
            slots.set(lightweightFile(candidates[index], facts: facts[index], paths: paths), at: index)
        }
        return slots.files()
    }

    /// Folders written by photo applications for their own caches. Their
    /// contents are previews and settings, never originals, and listing them
    /// dominated opening on large Capture One archives.
    ///
    /// - Lightroom Classic `*.lrdata` folders hold previews and smart-preview
    ///   DNGs that would otherwise appear as photos.
    /// - Capture One's per-folder `CaptureOne` folder, only when every visible
    ///   entry is a `Cache` or `Settings<digits>` folder. Anything else inside,
    ///   such as photos a user saved there, keeps the folder visible.
    static func isAppManagedCacheFolder(name: String, visibleChildren: [(name: String, isDirectory: Bool)]?) -> Bool {
        if (name as NSString).pathExtension.caseInsensitiveCompare("lrdata") == .orderedSame {
            return true
        }
        guard name.caseInsensitiveCompare("CaptureOne") == .orderedSame,
              let visibleChildren, !visibleChildren.isEmpty else {
            return false
        }
        return visibleChildren.allSatisfy { child in
            guard child.isDirectory else { return false }
            if child.name.caseInsensitiveCompare("Cache") == .orderedSame { return true }
            let prefix = "settings"
            guard child.name.count > prefix.count,
                  child.name.lowercased().hasPrefix(prefix) else { return false }
            return child.name.dropFirst(prefix.count).allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// Bounded long-lived workers claim deterministic slots. Cancellation
    /// stops new reads; results remain private until both identity barriers.
    ///
    /// Cache hits do no filesystem I/O; misses check identity before and
    /// after their read. A complete file and folder barrier must therefore
    /// follow before results gain any authority. `validatesIdentities` runs
    /// it here; pass false only when the caller runs its own final barrier
    /// after all later slow work (`SessionOpeningWorker`).
    static func prepareMetadata(
        in inventory: Inventory,
        isCancelled: @Sendable () -> Bool = { false },
        beforeFinalIdentityValidation: () throws -> Void = {},
        recorder: SessionOpeningRecorder? = nil,
        stageWillBegin: (SessionOpeningStage) throws -> Void = { _ in },
        metadataReaderForTesting: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)? = nil,
        metadataIndex: ArchiveMetadataIndex? = nil,
        commitsMetadataIndex: Bool = true,
        validatesIdentities: Bool = true,
        metadataReady: (@Sendable (OpeningMetadataUpdate) -> Void)? = nil,
        metadataInterest: OpeningMetadataInterest? = nil,
        metadataWorkers: Int? = nil
    ) throws -> [PhotoItem] {
        try stageWillBegin(.metadata)
        let workers = min(maxMetadataConcurrency, max(1, metadataWorkers ?? maxMetadataConcurrency))
        // Injected readers stay isolated from application caches by default.
        let index = metadataIndex ?? (metadataReaderForTesting == nil
            ? ArchiveMetadataIndex(folder: inventory.root, isCancelled: isCancelled) : nil)
        let result: [PhotoItem]
        if let recorder {
            result = try recorder.measure(.metadata) {
                try makeItems(for: inventory.items, isCancelled: isCancelled,
                              recorder: recorder, metadataReaderForTesting: metadataReaderForTesting,
                              metadataIndex: index, metadataReady: metadataReady, metadataInterest: metadataInterest,
                              workers: workers)
            }
        } else {
            result = try makeItems(for: inventory.items, isCancelled: isCancelled,
                                   recorder: nil, metadataReaderForTesting: metadataReaderForTesting,
                                   metadataIndex: index, metadataReady: metadataReady, metadataInterest: metadataInterest,
                                   workers: workers)
        }
        try stageWillBegin(.chronologicalSort)
        let sorted = recorder.map { $0.measure(.chronologicalSort) { sortItems(result) } } ?? sortItems(result)
        let metadataCommit = commitsMetadataIndex ? index?.prepareCommit(sorted, isCancelled: isCancelled) : nil
        try beforeFinalIdentityValidation()
        try stageWillBegin(.metadataIdentityValidation)
        if !validatesIdentities {
            precondition(metadataCommit == nil, "a cache commit needs this function's identity barrier")
            if isCancelled() { throw CancellationError() }
            return sorted
        }
        if let recorder {
            try recorder.measure(.metadataIdentityValidation) {
                try validateScannedIdentities(sorted, isCancelled: isCancelled)
                try validateDirectories(in: inventory, isCancelled: isCancelled)
            }
        } else {
            try validateScannedIdentities(sorted, isCancelled: isCancelled)
            try validateDirectories(in: inventory, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }
        if metadataCommit?.commit(isCancelled: isCancelled) == true {
            // Optional cache I/O must not move the publication boundary ahead
            // of a source replacement that happens while the JSON is written.
            try validateScannedIdentities(sorted, isCancelled: isCancelled)
            try validateDirectories(in: inventory, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }
        return sorted
    }

    /// Empty directories need identity validation too: otherwise a same-path
    /// replacement could inherit a remembered folder/viewport after opening.
    /// Directory contents and timestamps may legitimately change; only stable
    /// directory identity participates, never the optional navigation state.
    /// One `lstat` per directory; volumes come from a fresh per-pass lookup.
    static func validateDirectories(in inventory: Inventory,
                                    isCancelled: @Sendable () -> Bool = { false },
                                    volumes: FileOperationJournal.VolumeLookup? = nil) throws {
        let base = inventory.root.absoluteString
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let volumes = volumes ?? FileOperationJournal.VolumeLookup()
        let directories = inventory.directories
        do {
            try forEachInParallel(count: directories.count, minimumChunk: 64, isCancelled: isCancelled) { index in
                let directory = directories[index]
                guard let expected = directory.identity,
                      let url = directory.id.isEmpty ? inventory.root : URL(string: prefix + directory.id) else {
                    throw IdentityMismatch(url: nil, expected: directory.identity, actual: nil)
                }
                var info = Darwin.stat()
                let result = url.withUnsafeFileSystemRepresentation { path in
                    path.map { Darwin.lstat($0, &info) } ?? -1
                }
                guard result == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw IdentityMismatch(url: url, expected: expected, actual: nil)
                }
                let current = volumes.volume(device: info.st_dev, containing: url).map {
                    FileOperationJournal.identity(from: info, volumeRootPath: $0.rootPath, volumeUUIDString: $0.uuid)
                } ?? (try? FileOperationJournal.captureIdentity(at: url))
                guard let current, ArchiveFolderIndex.sameDirectoryIdentity(expected, current) else {
                    throw IdentityMismatch(url: url, expected: expected, actual: current)
                }
            }
        } catch let mismatch as IdentityMismatch {
            mismatch.log()
            throw ScanError.filesChangedDuringScan
        }
    }

    /// Metadata decoding can take seconds for a large card. Re-stat every
    /// pathname after that work so an atomic replacement cannot combine old
    /// identity/rating state with newly substituted bytes.
    ///
    /// Up to eight workers check contiguous item ranges (inputs under 256
    /// items stay serial and in order). Cancellation is polled before every
    /// file and before an empty pass; the first mismatch wins and is the
    /// only one logged. `beforeIdentityProbeForTesting` may run concurrently.
    static func validateScannedIdentities(
        _ items: [PhotoItem],
        isCancelled: @Sendable () -> Bool = { false },
        volumes: FileOperationJournal.VolumeLookup? = nil,
        beforeIdentityProbeForTesting: ((PhotoFile) -> Void)? = nil
    ) throws {
        let volumes = volumes ?? FileOperationJournal.VolumeLookup()
        let probe = UncheckedProbe(body: beforeIdentityProbeForTesting)
        do {
            try forEachInParallel(count: items.count, minimumChunk: 256, isCancelled: isCancelled) { index in
                for file in items[index].individualFiles {
                    if isCancelled() { throw CancellationError() }
                    probe.body?(file)
                    let expected = file.scannedIdentity
                    let current = try? FileOperationJournal.captureIdentity(at: file.url, volumes: volumes)
                    guard let expected,
                          let current,
                          FileOperationJournal.identitiesMatch(
                            expected: expected,
                            actual: current,
                            includeStatusChange: true
                          ) else {
                        throw IdentityMismatch(url: file.url, expected: expected, actual: current)
                    }
                }
            }
        } catch let mismatch as IdentityMismatch {
            mismatch.log()
            throw ScanError.filesChangedDuringScan
        }
    }

    /// Test-only probe; callers accept that it may run concurrently.
    private struct UncheckedProbe: @unchecked Sendable {
        let body: ((PhotoFile) -> Void)?
    }

    /// The failed boundary of a parallel identity pass, logged once.
    private struct IdentityMismatch: Error {
        let url: URL?
        let expected: FileOperationJournal.FileIdentity?
        let actual: FileOperationJournal.FileIdentity?

        func log() {
            FolderScanner.logger.error(
                "Media identity mismatch at \(url?.path ?? "<invalid>", privacy: .private); expected \(String(reflecting: expected), privacy: .private); actual \(String(reflecting: actual), privacy: .private)"
            )
        }
    }

    /// Deterministic RAW+JPEG pairing independent of filesystem enumerator and
    /// Dictionary iteration order. Internal so the ordering contract can be
    /// regression tested without scanning real media.
    static func pairFiles(
        _ files: [URL],
        pairingMode: RawJPEGPairingMode,
        caseSensitiveNames: Bool
    ) -> [(primary: URL, paired: URL?)] {
        pairFiles(
            files,
            pairingMode: pairingMode,
            filenamePolicy: PairingFilenamePolicy(
                caseSensitiveNames: caseSensitiveNames
            )
        )
    }

    static func pairFiles(
        _ files: [URL],
        pairingMode: RawJPEGPairingMode,
        filenamePolicy: PairingFilenamePolicy,
        physicalPair: ((URL, URL) -> Void)? = nil
    ) -> [(primary: URL, paired: URL?)] {
        let candidates = files.map(PairingCandidate.init)
        return pairCandidates(candidates, pairingMode: pairingMode, filenamePolicy: filenamePolicy,
                              physicalPair: physicalPair.map { report in { report(files[$0], files[$1]) } })
            .map { (files[$0.primary], $0.paired.map { files[$0] }) }
    }

    /// One file's pairing facts, computed once: the stable sort path and the
    /// classification that `pairFiles` and `lightweightFile` both use.
    fileprivate struct PairingCandidate {
        enum Role { case independent, raw, jpeg, otherImage }

        let url: URL
        /// `fileSystemIdentityPath(for: url)`.
        let identityPath: String
        let role: Role
        let mediaKind: MediaKind

        init(url: URL) {
            self.url = url
            identityPath = FolderScanner.fileSystemIdentityPath(for: url)
            let lowered = url.pathExtension.lowercased()
            let isText = FolderScanner.textExtensions.contains(lowered)
            let isVideo = FolderScanner.isVideoExtension(lowercased: lowered)
            let isAudio = FolderScanner.isAudioExtension(lowercased: lowered)
            mediaKind = isText ? .text : (isVideo ? .video : (isAudio ? .audio : .photo))
            if isVideo || isAudio || isText {
                role = .independent
            } else {
                role = FolderScanner.rawExtensions.contains(lowered) ? .raw
                    : (lowered == "jpg" || lowered == "jpeg" ? .jpeg : .otherImage)
            }
        }
    }

    /// Index form of `pairFiles`: results and callbacks name positions in
    /// `candidates`.
    private static func pairCandidates(
        _ candidates: [PairingCandidate],
        pairingMode: RawJPEGPairingMode,
        filenamePolicy: PairingFilenamePolicy,
        physicalPair: ((Int, Int) -> Void)? = nil
    ) -> [(primary: Int, paired: Int?)] {
        var groups: [PairingFilenamePolicy.Key: [Int]] = [:]
        groups.reserveCapacity(candidates.count)
        // Sorted stem keys and per-group paths completely determine output.
        // Sorting the whole input first repeats work without changing a group.
        for index in candidates.indices {
            groups[filenamePolicy.key(for: candidates[index].url), default: []].append(index)
        }

        var pairs: [(primary: Int, paired: Int?)] = []
        pairs.reserveCapacity(candidates.count)
        for key in groups.keys.sorted() {
            guard let grouped = groups[key] else { continue }
            let members = grouped.count == 1 ? grouped
                : grouped.sorted { candidates[$0].identityPath < candidates[$1].identityPath }
            // Video and audio are always independent media, even when a
            // camera gives them the same base name as a RAW. Only RAW + JPEG
            // is a pair; grouping any other format would hide an original
            // from the review session.
            var images: [Int] = []
            var raws: [Int] = []
            var jpegs: [Int] = []
            for index in members {
                switch candidates[index].role {
                case .independent: pairs.append((index, nil))
                case .raw: images.append(index); raws.append(index)
                case .jpeg: images.append(index); jpegs.append(index)
                case .otherImage: images.append(index)
                }
            }

            if raws.count == 1, jpegs.count == 1 {
                physicalPair?(raws[0], jpegs[0])
            }

            // A shared stem is not enough evidence when more than one file
            // could fill either side. Never let sort order arbitrarily decide
            // which original owns a JPEG: ambiguous groups stay independent.
            if pairingMode == .together, raws.count == 1, jpegs.count == 1 {
                let raw = raws[0], jpeg = jpegs[0]
                pairs.append((raw, jpeg))
                // Other image formats sharing the stem remain independent.
                for extra in images where extra != raw && extra != jpeg {
                    pairs.append((extra, nil))
                }
            } else {
                for index in images { pairs.append((index, nil)) }
            }
        }
        return pairs
    }

    /// Resolves the same unambiguous one-RAW/one-JPEG relationships used by
    /// the grouped review projection while retaining the complete scanned
    /// physical-file records needed by pair-member Clean Up.
    static func rawJPEGPairs(
        from items: [PhotoItem],
        root: URL
    ) -> [(raw: PhotoFile, jpeg: PhotoFile)] {
        var filesByPath: [String: PhotoFile] = [:]
        for file in items.flatMap(\.individualFiles) {
            filesByPath[fileSystemIdentityPath(for: file.url)] = file
        }
        return pairFiles(
            filesByPath.values.map(\.url),
            pairingMode: .together,
            filenamePolicy: pairingFilenamePolicy(at: root)
        ).compactMap { pair in
            guard let jpegURL = pair.paired,
                  let raw = filesByPath[fileSystemIdentityPath(for: pair.primary)],
                  let jpeg = filesByPath[fileSystemIdentityPath(for: jpegURL)]
            else { return nil }
            return (raw, jpeg)
        }
    }

    /// Reprojects the already-discovered physical files without walking the
    /// source folder again. Separating a paired session opens metadata only
    /// for lightweight JPEG partners; every later toggle reuses those records.
    /// A completed file operation may preserve prior identity-bound placeholder
    /// records without reading metadata when a survivor changed; it supplies
    /// `loadMissingMetadata: false` and presents a Rescan remedy.
    static func projectPairingMode(
        _ pairingMode: RawJPEGPairingMode,
        from items: [PhotoItem],
        root: URL,
        isCancelled: @Sendable () -> Bool = { false },
        loadMissingMetadata: Bool = true,
        metadataReaderForTesting: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)? = nil
    ) throws -> PairingProjection {
        var fileByPath: [String: PhotoFile] = [:]
        for item in items {
            for file in item.individualFiles {
                fileByPath[fileSystemIdentityPath(for: file.url)] = file
            }
        }
        var files = fileByPath.values.sorted { stableURLOrder($0.url, $1.url) }
        let missingMetadataCount: Int
        if pairingMode == .separate && loadMissingMetadata {
            missingMetadataCount = files.count { !$0.metadataIsLoaded }
            files = try prepareMissingMetadata(
                in: files,
                isCancelled: isCancelled,
                metadataReaderForTesting: metadataReaderForTesting,
                metadataIndex: metadataReaderForTesting == nil ? ArchiveMetadataIndex(folder: root, isCancelled: isCancelled) : nil
            )
        } else {
            missingMetadataCount = 0
        }
        if isCancelled() { throw CancellationError() }

        let filesByPath = Dictionary(
            uniqueKeysWithValues: files.map {
                (fileSystemIdentityPath(for: $0.url), $0)
            }
        )
        let pairs = pairFiles(
            files.map(\.url),
            pairingMode: pairingMode,
            filenamePolicy: pairingFilenamePolicy(at: root)
        )
        var projected: [PhotoItem] = []
        projected.reserveCapacity(pairs.count)
        var itemIDByFileID: [String: String] = [:]
        for pair in pairs {
            guard let primary = filesByPath[
                fileSystemIdentityPath(for: pair.primary)
            ] else {
                continue
            }
            let paired = pair.paired.flatMap {
                filesByPath[fileSystemIdentityPath(for: $0)]
            }
            let item = PhotoItem(primaryFile: primary, pairedFile: paired)
            projected.append(item)
            for file in item.individualFiles {
                itemIDByFileID[file.id] = item.id
            }
        }
        return PairingProjection(
            items: sortItems(projected),
            itemIDByFileID: itemIDByFileID,
            enrichedFileCount: missingMetadataCount
        )
    }

    private static func stableURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        fileSystemIdentityPath(for: lhs)
            < fileSystemIdentityPath(for: rhs)
    }

    private static func pairingFilenamePolicy(
        at root: URL
    ) -> PairingFilenamePolicy {
        let capability = try? root.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames
        return PairingFilenamePolicy(
            volumeSupportsCaseSensitiveNames: capability
        )
    }

    /// `PreparedSessionIndex` validates and caches this chronological order.
    /// Keep the scanner and UI comparator shared, including exact name/ID ties.
    static func sortItems(_ items: [PhotoItem]) -> [PhotoItem] {
        let defaultSort = PhotoSort()
        return items.sorted(by: defaultSort.areInOrder)
    }

    /// How many EXIF readers run at once during a scan. Header parsing mixes
    /// file I/O with CPU work, so a handful of workers saturates it without
    /// competing with the rest of the system.
    private static let maxMetadataConcurrency = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Each long-lived worker claims the next inventory slot, avoiding slow
    /// chunks on mixed-media folders. One writer fills each slot; chronological
    /// sorting sees the same deterministic input as a serial metadata pass.
    private static func makeItems(
        for inventoryItems: [PhotoItem],
        isCancelled: @Sendable () -> Bool,
        recorder: SessionOpeningRecorder?,
        metadataReaderForTesting: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)?,
        metadataIndex: ArchiveMetadataIndex?,
        metadataReady: (@Sendable (OpeningMetadataUpdate) -> Void)?,
        metadataInterest: OpeningMetadataInterest?,
        workers: Int = maxMetadataConcurrency
    ) throws -> [PhotoItem] {
        if isCancelled() { throw CancellationError() }
        guard !inventoryItems.isEmpty else { return [] }
        let results = MetadataSlots(count: inventoryItems.count)
        let slotByPhysicalID = metadataInterest.map { _ in
            Dictionary(uniqueKeysWithValues: inventoryItems.enumerated().flatMap { slot, item in
                item.individualFiles.map { ($0.id, slot) }
            })
        }
        recorder?.progress(.metadata, completed: 0, total: inventoryItems.count)
        DispatchQueue.concurrentPerform(iterations: min(workers, inventoryItems.count)) { _ in
            while !isCancelled() {
                let preferred = metadataInterest?.currentPhysicalFileID.flatMap { slotByPhysicalID?[$0] }
                guard let slot = results.claim(prioritizing: preferred) else { return }
                do {
                    let source = inventoryItems[slot]
                    let file = try autoreleasepool {
                        try enrichMetadata(for: source.primaryFile, metadataReaderForTesting: metadataReaderForTesting,
                                           metadataIndex: metadataIndex, checksCacheHits: false,
                                           isCancelled: isCancelled)
                    }
                    if isCancelled() { return }
                    let item = PhotoItem(primaryFile: file, pairedFile: source.pairedFile)
                    let completed = results.store(item, at: slot)
                    metadataReady?(OpeningMetadataUpdate(item: item))
                    if completed % 25 == 0 || completed == inventoryItems.count {
                        recorder?.progress(.metadata, completed: completed, total: inventoryItems.count)
                    }
                } catch {
                    results.record(error)
                    return
                }
            }
        }
        if isCancelled() { throw CancellationError() }
        return try results.finished()
    }

    /// A hidden JPEG needs only facts already returned by folder enumeration.
    /// Its EXIF remains unopened until the user asks to review the files
    /// separately, keeping the common paired scan as fast as before.
    private static func lightweightFile(
        _ candidate: PairingCandidate,
        facts: FileFacts?,
        paths: RelativePaths
    ) -> PhotoFile {
        PhotoFile(
            id: paths.identity(of: candidate.url, identityPath: candidate.identityPath),
            url: candidate.url,
            displayRelativePath: paths.display(of: candidate.url),
            captureDate: facts?.creationDate,
            captureDateEvidence: facts?.creationDate.map {
                CaptureDateEvidence(date: $0, source: .fileCreation)
            },
            cameraModel: nil,
            lensModel: nil,
            mediaKind: candidate.mediaKind,
            modificationDate: facts?.modificationDate,
            fileSize: facts?.size ?? 0,
            scannedIdentity: facts?.identity,
            metadataIsLoaded: false
        )
    }

    /// `relativeFileIdentity` and `relativeDisplayPath` for many files under
    /// one root, with the root prefixes computed once. Paths outside the
    /// prefix take the original functions, including their symlink fallback.
    fileprivate struct RelativePaths {
        let root: URL
        private let identityPrefix: String
        private let displayPrefix: String

        init(root: URL) {
            self.root = root
            identityPrefix = Self.rootedPrefix(FolderScanner.fileSystemIdentityPath(for: root))
            displayPrefix = Self.rootedPrefix(root.path)
        }

        func identity(of url: URL, identityPath: String) -> String {
            identityPath.hasPrefix(identityPrefix)
                ? String(identityPath.dropFirst(identityPrefix.count))
                : FolderScanner.relativeFileIdentity(of: url, under: root)
        }

        func display(of url: URL) -> String {
            let path = url.path
            return path.hasPrefix(displayPrefix)
                ? String(path.dropFirst(displayPrefix.count))
                : FolderScanner.relativeDisplayPath(of: url, under: root)
        }

        /// The first prefix `relativePath` tries.
        fileprivate static func rootedPrefix(_ rootPath: String) -> String {
            let root = rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return root.isEmpty ? "/" : "/\(root)/"
        }
    }

    /// Fixed result slots for `buildLightweightFiles`; each index is written
    /// by exactly one worker before `files()` reads them all.
    private final class PhotoFileSlots: @unchecked Sendable {
        private let storage: UnsafeMutablePointer<PhotoFile?>
        private let count: Int

        init(count: Int) {
            self.count = count
            storage = .allocate(capacity: max(count, 1))
            storage.initialize(repeating: nil, count: count)
        }

        deinit {
            storage.deinitialize(count: count)
            storage.deallocate()
        }

        func set(_ file: PhotoFile, at index: Int) { storage[index] = file }

        func files() -> [PhotoFile] {
            UnsafeBufferPointer(start: storage, count: count).map { $0! }
        }
    }

    /// Runs `body` for `0..<count` on at most `maxMetadataConcurrency`
    /// workers, each over one contiguous range of at least `minimumChunk`
    /// indices, so small inputs stay on the calling thread in order.
    /// Cancellation is polled before every index and before an empty pass.
    /// The first error wins and stops the other workers at their next index.
    private static func forEachInParallel(
        count: Int,
        minimumChunk: Int,
        isCancelled: @Sendable () -> Bool,
        _ body: @Sendable (Int) throws -> Void
    ) throws {
        if isCancelled() { throw CancellationError() }
        guard count > 0 else { return }
        let chunkSize = max(minimumChunk, (count + maxMetadataConcurrency - 1) / maxMetadataConcurrency)
        let chunks = (count + chunkSize - 1) / chunkSize
        let failure = FirstFailure()
        if chunks == 1 {
            runChunk(0, chunkSize: chunkSize, count: count, failure: failure, isCancelled: isCancelled, body)
        } else {
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                runChunk(chunk, chunkSize: chunkSize, count: count, failure: failure, isCancelled: isCancelled, body)
            }
        }
        if let error = failure.error { throw error }
        if isCancelled() { throw CancellationError() }
    }

    private static func runChunk(_ chunk: Int, chunkSize: Int, count: Int, failure: FirstFailure,
                                 isCancelled: @Sendable () -> Bool, _ body: @Sendable (Int) throws -> Void) {
        for index in (chunk * chunkSize)..<min(count, (chunk + 1) * chunkSize) {
            if failure.hasFailed { return }
            if isCancelled() { failure.record(CancellationError()); return }
            do { try body(index) } catch { failure.record(error); return }
        }
    }

    private final class FirstFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Error?

        var hasFailed: Bool { lock.lock(); defer { lock.unlock() }; return first != nil }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return first }

        /// Returns true for the first error only.
        @discardableResult
        func record(_ error: Error) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard first == nil else { return false }
            first = error
            return true
        }
    }

    private static func prepareMissingMetadata(
        in files: [PhotoFile],
        isCancelled: @Sendable () -> Bool,
        metadataReaderForTesting: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)? = nil,
        metadataIndex: ArchiveMetadataIndex? = nil
    ) throws -> [PhotoFile] {
        guard files.contains(where: { !$0.metadataIsLoaded }) else {
            return files
        }
        let chunkSize = max(
            1,
            (files.count + maxMetadataConcurrency - 1) / maxMetadataConcurrency
        )
        let chunkStarts = Array(stride(from: 0, to: files.count, by: chunkSize))
        let results = FileChunkResults(count: chunkStarts.count)
        DispatchQueue.concurrentPerform(iterations: chunkStarts.count) { chunkIndex in
            let start = chunkStarts[chunkIndex]
            let end = min(start + chunkSize, files.count)
            var prepared: [PhotoFile] = []
            prepared.reserveCapacity(end - start)
            for file in files[start..<end] {
                if isCancelled() { return }
                do {
                    prepared.append(
                        file.metadataIsLoaded ? file : try enrichMetadata(
                            for: file,
                            metadataReaderForTesting: metadataReaderForTesting,
                            metadataIndex: metadataIndex, isCancelled: isCancelled
                        )
                    )
                } catch {
                    results.record(error)
                    return
                }
            }
            results.store(prepared, at: chunkIndex)
        }
        if isCancelled() { throw CancellationError() }
        return try results.flattened()
    }

    /// Prepares a previously lightweight JPEG partner to become a visible
    /// standalone item after its RAW counterpart is removed. Callers run this
    /// off the main actor because it may read image metadata from disk.
    static func prepareStandaloneFiles(
        _ files: [PhotoFile]
    ) throws -> [PhotoFile] {
        try prepareMissingMetadata(in: files, isCancelled: { false })
    }

    /// A miss waits for admission, then checks identity, reads, and checks
    /// again: the bytes read belong to the scanned file. A cache hit is keyed
    /// by the scanned identity and reads nothing; with `checksCacheHits`
    /// false it does no I/O at all, so the caller's later complete barrier
    /// must reject a replacement (opening and `prepareMetadata`). Lazy
    /// enrichment has no later barrier and checks hits before and after.
    private static func enrichMetadata(
        for file: PhotoFile,
        metadataReaderForTesting: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)?,
        metadataIndex: ArchiveMetadataIndex? = nil,
        checksCacheHits: Bool = true,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> PhotoFile {
        if isCancelled() { throw CancellationError() }
        if let cached = metadataIndex?.metadata(for: file) {
            if checksCacheHits { try validateMetadataSource(file) }
            let ready = cached.applying(to: file)
            if checksCacheHits { try validateMetadataSource(file) }
            if isCancelled() { throw CancellationError() }
            return ready
        }
        if metadataReaderForTesting == nil {
            // Only background workers call this synchronous boundary. Give
            // interaction a quiet window, with the coordinator's hard deadline
            // preventing continuous navigation from starving a complete scan.
            let deferredSince = ContinuousClock.now
            while !ForegroundWorkCoordinator.shared.shouldAdmitBackgroundWork(deferredSince: deferredSince) {
                if isCancelled() { throw CancellationError() }
                Thread.sleep(forTimeInterval: 0.015)
            }
            if isCancelled() { throw CancellationError() }
        }
        try validateMetadataSource(file)
        let metadata = file.metadataSnapshot
        let isVideo = isVideoExtension(file.url.pathExtension)
        let isAudio = isAudioExtension(file.url.pathExtension)
        let isText = isTextExtension(file.url.pathExtension)
        let info: MetadataExtractor.ScanInfo
        if isVideo || isAudio || isText {
            info = MetadataExtractor.ScanInfo()
        } else if let metadataReaderForTesting {
            info = try metadataReaderForTesting(file.url)
        } else {
            info = MetadataExtractor.scanInfo(for: file.url)
        }
        let videoInfo = isVideo
            ? VideoMetadataExtractor.scanInfo(for: file.url)
            : nil
        let audioInfo = isAudio
            ? AudioMetadataExtractor.scanInfo(for: file.url)
            : nil
        try validateMetadataSource(file)
        if isCancelled() { throw CancellationError() }
        metadataIndex?.recordExtraction(for: file,
            succeeded: info.extractionSucceeded
                && (videoInfo?.extractionSucceeded ?? true)
                && (audioInfo?.extractionSucceeded ?? true))
        return PhotoFile(
            id: file.id,
            url: file.url,
            displayRelativePath: file.legacyPersistenceID,
            captureDate: info.captureDate ?? file.captureDate,
            captureDateEvidence: info.captureDateEvidence
                ?? (info.captureDate == nil ? file.captureDateEvidence : nil),
            cameraModel: info.cameraModel,
            lensModel: info.lensModel,
            filmSimulation: info.filmSimulation,
            aperture: info.aperture,
            shutterSpeed: info.shutterSpeed,
            iso: info.iso,
            mediaKind: isText ? .text : (isVideo ? .video : (isAudio ? .audio : .photo)),
            duration: videoInfo?.duration ?? audioInfo?.duration,
            videoDimensions: videoInfo?.dimensions,
            videoCodec: videoInfo?.codec,
            videoFrameRate: videoInfo?.frameRate,
            videoIsPlayable: videoInfo?.isPlayable ?? false,
            audioCodec: audioInfo?.codec,
            audioIsPlayable: audioInfo?.isPlayable ?? false,
            modificationDate: file.modificationDate,
            fileSize: file.fileSize,
            scannedIdentity: file.scannedIdentity,
            metadataIsLoaded: true,
            rating: metadata.rating,
            ratedAt: metadata.ratedAt,
            starRating: metadata.starRating,
            starsChangedAt: metadata.starsChangedAt,
            colorLabel: metadata.colorLabel,
            colorChangedAt: metadata.colorChangedAt
        )
    }

    /// A cached physical-file record must never adopt metadata from a
    /// replacement at the same path. Synthetic/legacy records retain their
    /// existing identity-less API; production scans always capture identity.
    private static func validateMetadataSource(_ file: PhotoFile) throws {
        guard let expected = file.scannedIdentity else { return }
        let actual = try? FileOperationJournal.captureIdentity(at: file.url)
        guard let actual,
              FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: actual,
                includeStatusChange: true
              ) else {
            logIdentityMismatch(file, expected: expected, actual: actual)
            throw ScanError.fileChangedDuringMetadataLoad
        }
    }

    /// Log only the failed boundary, never the normal per-file scan loop.
    /// Paths and exact filesystem metadata remain private in unified logging.
    private static func logIdentityMismatch(
        _ file: PhotoFile,
        expected: FileOperationJournal.FileIdentity?,
        actual: FileOperationJournal.FileIdentity?
    ) {
        logger.error(
            "Media identity mismatch at \(file.url.path, privacy: .private); expected \(String(reflecting: expected), privacy: .private); actual \(String(reflecting: actual), privacy: .private)"
        )
    }

    /// Fixed slots and at most eight workers, with no task per photo and no
    /// chunk imbalance when videos/RAWs take longer than JPEG headers.
    private final class MetadataSlots: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PhotoItem?]
        private var next = 0
        private var claimed: [Bool]
        private var completed = 0
        private var firstError: Error?

        init(count: Int) {
            values = Array(repeating: nil, count: count)
            claimed = Array(repeating: false, count: count)
        }

        func claim(prioritizing preferred: Int?) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard firstError == nil else { return nil }
            if let preferred, values.indices.contains(preferred), !claimed[preferred] {
                claimed[preferred] = true
                return preferred
            }
            while next < values.count, claimed[next] { next += 1 }
            guard next < values.count else { return nil }
            claimed[next] = true
            defer { next += 1 }
            return next
        }

        func store(_ item: PhotoItem, at index: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            values[index] = item
            completed += 1
            return completed
        }

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if firstError == nil { firstError = error }
        }

        func finished() throws -> [PhotoItem] {
            lock.lock()
            defer { lock.unlock() }
            if let firstError { throw firstError }
            guard completed == values.count else { throw CancellationError() }
            return values.compactMap { $0 }
        }
    }

    private final class FileChunkResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[PhotoFile]]
        private var firstError: Error?

        init(count: Int) {
            values = [[PhotoFile]](repeating: [], count: count)
        }

        func store(_ files: [PhotoFile], at index: Int) {
            lock.lock()
            values[index] = files
            lock.unlock()
        }

        func record(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if firstError == nil { firstError = error }
        }

        func flattened() throws -> [PhotoFile] {
            lock.lock()
            defer { lock.unlock() }
            if let firstError { throw firstError }
            return values.flatMap { $0 }
        }
    }

    /// Lossless, persistence-friendly path identity. Foundation `String`
    /// equality treats canonically equivalent Unicode spellings as equal,
    /// while a normalization-sensitive filesystem can store both. Percent-
    /// encoded URL paths remain ASCII and retain their exact filesystem bytes.
    static func fileSystemIdentityPath(for url: URL) -> String {
        url.path(percentEncoded: true)
    }

    static func relativeFileIdentity(of url: URL, under root: URL) -> String {
        let path = fileSystemIdentityPath(for: url)
        let rootPath = fileSystemIdentityPath(for: root)
        if let relative = relativePath(path, under: rootPath) {
            return relative
        }
        // FileManager can enumerate the physical spelling of a path while a
        // user-selected root retains its logical spelling (for example
        // /tmp versus /private/tmp). Compare both resolved paths only as a
        // containment fallback; the returned name still comes from the
        // original percent-encoded filesystem path.
        let resolvedPath = fileSystemIdentityPath(
            for: url.resolvingSymlinksInPath()
        )
        let resolvedRootPath = fileSystemIdentityPath(
            for: root.resolvingSymlinksInPath()
        )
        if let relative = relativePath(
            resolvedPath,
            under: resolvedRootPath
        ) {
            return relative
        }
        return path.split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
            ?? path
    }

    fileprivate static func relativeDisplayPath(
        of url: URL,
        under root: URL
    ) -> String {
        let path = url.path
        let rootPath = root.path
        if let relative = relativePath(path, under: rootPath) {
            return relative
        }
        let resolvedPath = url.resolvingSymlinksInPath().path
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        if let relative = relativePath(
            resolvedPath,
            under: resolvedRootPath
        ) {
            return relative
        }
        return url.lastPathComponent
    }

    private static func relativePath(
        _ path: String,
        under rootPath: String
    ) -> String? {
        let root = rootPath.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let rootedPrefix = root.isEmpty ? "/" : "/\(root)/"
        if path.hasPrefix(rootedPrefix) {
            return String(path.dropFirst(rootedPrefix.count))
        }
        let absoluteRoot = root.isEmpty ? "/" : "/\(root)"
        if path.hasPrefix(absoluteRoot + "/") {
            return String(path.dropFirst(absoluteRoot.count + 1))
        }
        return nil
    }
}


// MARK: - Discovery walk

extension FolderScanner {
    /// Bounded parallel, name-first folder walk for `discoverInventory`.
    ///
    /// FileManager's enumerator asks for every entry's attributes. On
    /// FSKit-mounted exFAT that bulk listing took 14–16 s for an archive whose
    /// names alone list in about half a second. This walk reads names with
    /// `readdir` and inspects only folders and recognized media files.
    ///
    /// Equivalence with `.skipsHiddenFiles`, `.skipsPackageDescendants` and
    /// the enumerator's URLs:
    /// - Hidden means a leading dot, `UF_HIDDEN`, or the Finder invisible bit.
    ///   APFS and HFS+ mirror that bit into `UF_HIDDEN`, so `lstat` decides.
    ///   Volumes that emulate extended attributes (exFAT, FAT) keep Finder
    ///   info only in a `._name` sibling; only entries with one are asked for
    ///   `isHiddenKey`. On any other filesystem every entry is asked.
    /// - A folder is a package only through a package-type extension or the
    ///   Finder bundle bit. `isPackageKey` is asked unless the folder has no
    ///   extension and, on an emulating volume, no `._name` sibling.
    /// - Symbolic links are never followed, including the root.
    /// - URLs are the root's physical path (`F_GETPATH`, as the enumerator
    ///   resolves `/tmp` and letter case) plus exact on-disk name bytes, built
    ///   with CoreFoundation's constructor and a trailing slash for folders.
    /// - Output follows the enumerator's pre-order and each folder's on-disk
    ///   order, independent of worker timing.
    fileprivate final class DiscoveryWalk: @unchecked Sendable {
        enum Entry {
            case directory(URL, FileOperationJournal.FileIdentity)
            case file(URL, FileFacts)

            var url: URL {
                switch self {
                case .directory(let url, _), .file(let url, _): return url
                }
            }
        }

        private enum Child {
            case directory(Int)
            case file(Int)
        }

        private struct Node {
            let path: [UInt8]
            var included = false
            var url: URL?
            var identity: FileOperationJournal.FileIdentity?
            var children: [Child] = []
        }

        private struct FileResult {
            let url: URL
            let facts: FileFacts
        }

        private struct ListedEntry {
            let path: [UInt8]
            let url: URL
            var appleDoubleSibling = false
        }

        /// A directory to inspect and list, or a batch of media files to stat.
        private enum Work {
            case directory(index: Int, entry: ListedEntry, parentDevice: dev_t)
            case files(slots: [(slot: Int, entry: ListedEntry)], parentDevice: dev_t)
        }

        private struct Listing {
            var directories: [ListedEntry] = []
            var files: [ListedEntry] = []
            /// Visible children in on-disk order, for building `Node.children`.
            var order: [(isDirectory: Bool, index: Int)] = []
            /// Visible files, links and other non-folder entries of any kind.
            var visibleNonDirectoryCount = 0

            var visibleChildren: [(name: String, isDirectory: Bool)] {
                directories.map { (String(decoding: $0.path.lastComponent, as: UTF8.self), true) }
                    + Array(repeating: ("", false), count: visibleNonDirectoryCount)
            }
        }

        /// Where a volume keeps the Finder flags that `lstat` cannot see.
        private enum FinderInfoStorage {
            /// APFS and HFS+ report the invisible bit as `UF_HIDDEN`.
            case invisibleBitInFileFlags
            /// Emulated extended attributes: only in a `._name` sibling.
            case appleDoubleSibling
            /// Anything else: ask Foundation for every entry.
            case unknown
        }

        private struct Volume {
            let root: URL?
            /// `root.standardizedFileURL.path`, as `captureIdentity` stores it.
            let rootPath: String?
            let uuid: String?
            let finderInfo: FinderInfoStorage
        }

        static let maximumWorkers = min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
        private static let filesPerBatch = 64
        private static let progressInterval: TimeInterval = 0.02

        private let root: URL
        private let workerCount: Int
        private let workerQoS: DispatchQoS.QoSClass
        private let condition = NSCondition()
        // Guarded by `condition`.
        private var nodes: [Node] = []
        private var fileResults: [FileResult?] = []
        private var pending: [Work] = []
        private var activeUnits = 0
        private var liveWorkers = 0
        private var stopping = false
        private var discoveredFiles = 0
        private var failures: [(path: [UInt8], error: Error)] = []
        // Guarded by `volumeLock`.
        private let volumeLock = NSLock()
        private var volumes: [dev_t: Volume] = [:]

        init(root: URL, workers: Int = maximumWorkers, qos: DispatchQoS.QoSClass = .userInitiated) {
            self.root = root
            workerCount = min(Self.maximumWorkers, max(1, workers))
            workerQoS = qos
        }

        // MARK: Coordinator

        /// Lists the root on the calling thread, then lets bounded workers
        /// finish the tree. The calling thread alone polls `isCancelled` and
        /// reports progress, so neither closure escapes to a worker.
        func run(isCancelled: @Sendable () -> Bool, progress: (Int) -> Void) throws {
            let rootPath = try openRoot()
            var rootInfo = stat()
            guard Self.lstat(rootPath, &rootInfo) == 0 else {
                throw ScanError.unreadableFolder(root, Self.readError(errno, url: root))
            }
            nodes.append(Node(path: rootPath, included: true))
            let rootListing: Listing
            do {
                rootListing = try list(directory: rootPath, isCancelled: isCancelled)
            } catch let failure as ListingFailure {
                // FileManager reports root failures with the caller's URL.
                throw ScanError.unreadableFolder(root, failure.error)
            }
            if isCancelled() { throw CancellationError() }
            condition.lock()
            schedule(rootListing, into: 0, device: rootInfo.st_dev)
            let workers = workerCount
            liveWorkers = workers
            condition.unlock()
            for _ in 0..<workers {
                DispatchQueue.global(qos: workerQoS).async { self.workerLoop() }
            }

            var reported = 0
            var cancelled = false
            condition.lock()
            while liveWorkers > 0 {
                _ = condition.wait(until: Date(timeIntervalSinceNow: Self.progressInterval))
                let count = discoveredFiles
                condition.unlock()
                if !cancelled, isCancelled() {
                    cancelled = true
                    condition.lock()
                    stopping = true
                    condition.broadcast()
                    condition.unlock()
                }
                let milestone = count - count % 25
                if milestone > reported {
                    reported = milestone
                    progress(milestone)
                }
                condition.lock()
            }
            // With several failures, report the first by path so the message
            // does not depend on worker timing.
            let failure = failures.min { $0.path.lexicographicallyPrecedes($1.path) }?.error
            condition.unlock()
            if cancelled || isCancelled() { throw CancellationError() }
            if let failure { throw failure }
        }

        /// Visits included folders and files in the enumerator's pre-order.
        func assemble(isCancelled: @Sendable () -> Bool, _ visit: (Entry) throws -> Void) throws {
            condition.lock()
            let nodes = self.nodes
            let files = self.fileResults
            condition.unlock()
            var stack: [(node: Int, next: Int)] = [(0, 0)]
            while let top = stack.last {
                let children = nodes[top.node].children
                guard top.next < children.count else {
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                switch children[top.next] {
                case .directory(let index):
                    let node = nodes[index]
                    guard node.included, let url = node.url, let identity = node.identity else { continue }
                    if isCancelled() { throw CancellationError() }
                    try visit(.directory(url, identity))
                    stack.append((index, 0))
                case .file(let slot):
                    guard let result = files[slot] else { continue }
                    if isCancelled() { throw CancellationError() }
                    try visit(.file(result.url, result.facts))
                }
            }
        }

        /// The enumerator lists the root's physical path: `/tmp` becomes
        /// `/private/tmp` and a differently cased spelling takes the on-disk
        /// case. A symbolic-link root is not followed.
        private func openRoot() throws -> [UInt8] {
            let descriptor = root.withUnsafeFileSystemRepresentation { path in
                path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
            }
            guard descriptor >= 0 else {
                throw ScanError.unreadableFolder(root, Self.readError(errno, url: root))
            }
            defer { close(descriptor) }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
                throw ScanError.unreadableFolder(root, Self.readError(errno, url: root))
            }
            return buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        }

        // MARK: Workers

        private func workerLoop() {
            while let work = take() {
                let outcome: Result<Void, Error>
                let path: [UInt8]
                switch work {
                case .directory(let index, let entry, let parentDevice):
                    path = entry.path
                    outcome = Result { try visitDirectory(index: index, entry: entry, parentDevice: parentDevice) }
                case .files(let slots, let parentDevice):
                    path = slots.first?.entry.path ?? []
                    outcome = Result { try statFiles(slots, parentDevice: parentDevice) }
                }
                condition.lock()
                if case .failure(let error) = outcome, !(error is CancellationError) {
                    failures.append((path, error))
                    stopping = true
                }
                activeUnits -= 1
                condition.broadcast()
                condition.unlock()
            }
            condition.lock()
            liveWorkers -= 1
            condition.broadcast()
            condition.unlock()
        }

        private func take() -> Work? {
            condition.lock()
            defer { condition.unlock() }
            while pending.isEmpty, activeUnits > 0, !stopping {
                condition.wait()
            }
            guard !stopping, let work = pending.popLast() else {
                condition.broadcast()
                return nil
            }
            activeUnits += 1
            return work
        }

        private var shouldStop: Bool {
            condition.lock()
            defer { condition.unlock() }
            return stopping
        }

        private func visitDirectory(index: Int, entry: ListedEntry, parentDevice: dev_t) throws {
            let path = entry.path
            let url = entry.url
            var info = stat()
            guard Self.lstat(path, &info) == 0 else {
                throw Self.entryFailure(errno, path: path)
            }
            // Replaced by a link or file since listing: the enumerator would
            // not have descended either.
            guard info.st_mode & S_IFMT == S_IFDIR,
                  info.st_flags & UInt32(UF_HIDDEN) == 0 else { return }
            let name = String(decoding: path.lastComponent, as: UTF8.self)
            if isAppManagedCacheFolder(name: name, visibleChildren: nil) { return }
            let volume = self.volume(for: info.st_dev, url: url)
            // A mount point's Finder info belongs to the mounted volume.
            let finderInfoUnknown = info.st_dev != parentDevice
                || Self.mayHaveHiddenFinderInfo(entry, on: volume)
            var keys: Set<URLResourceKey> = []
            if finderInfoUnknown || volume.finderInfo == .invisibleBitInFileFlags
                || entry.appleDoubleSibling || path.lastComponent.contains(46) {
                keys.insert(.isPackageKey)
            }
            if finderInfoUnknown { keys.insert(.isHiddenKey) }
            if !keys.isEmpty {
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isPackage == true || values?.isHidden == true { return }
            }
            let identity = try Self.identity(from: info, url: url, volume: volume)
            let listing: Listing
            do {
                listing = try list(directory: path, isCancelled: { self.shouldStop })
            } catch let failure as ListingFailure {
                throw ScanError.unreadableFolder(Self.url(path, isDirectory: false), failure.error)
            }
            if name.caseInsensitiveCompare("CaptureOne") == .orderedSame,
               isAppManagedCacheFolder(name: name, visibleChildren: listing.visibleChildren) {
                return
            }
            condition.lock()
            nodes[index].included = true
            nodes[index].url = url
            nodes[index].identity = identity
            schedule(listing, into: index, device: info.st_dev)
            condition.unlock()
        }

        /// Records a listed folder's children and queues their work. Called
        /// with `condition` held.
        private func schedule(_ listing: Listing, into parent: Int, device: dev_t) {
            var directoryNodes: [Int] = []
            directoryNodes.reserveCapacity(listing.directories.count)
            for directory in listing.directories {
                directoryNodes.append(nodes.count)
                nodes.append(Node(path: directory.path))
            }
            let firstSlot = fileResults.count
            fileResults.append(contentsOf: repeatElement(nil, count: listing.files.count))
            nodes[parent].children = listing.order.map { entry in
                entry.isDirectory ? .directory(directoryNodes[entry.index]) : .file(firstSlot + entry.index)
            }
            var batchStart = 0
            while batchStart < listing.files.count {
                let end = min(batchStart + Self.filesPerBatch, listing.files.count)
                pending.append(.files(slots: (batchStart..<end).map { (firstSlot + $0, listing.files[$0]) },
                                      parentDevice: device))
                batchStart = end
            }
            // Folders are queued last so workers take them first (LIFO): the
            // walk stays wide while file batches fill idle workers.
            for (offset, directory) in listing.directories.enumerated().reversed() {
                pending.append(.directory(index: directoryNodes[offset], entry: directory, parentDevice: device))
            }
            condition.broadcast()
        }

        private func statFiles(_ slots: [(slot: Int, entry: ListedEntry)], parentDevice: dev_t) throws {
            var results: [(Int, FileResult)] = []
            results.reserveCapacity(slots.count)
            for (slot, entry) in slots {
                if shouldStop { throw CancellationError() }
                var info = stat()
                guard Self.lstat(entry.path, &info) == 0 else {
                    let code = errno
                    if code == EACCES || code == EPERM { throw Self.entryFailure(code, path: entry.path) }
                    throw ScanError.filesChangedDuringScan
                }
                guard info.st_mode & S_IFMT == S_IFREG,
                      info.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
                let volume = self.volume(for: info.st_dev, url: entry.url)
                // Only Finder info that `lstat` cannot see needs Foundation.
                // Later identity barriers use their own per-pass volume lookup.
                if info.st_dev != parentDevice || Self.mayHaveHiddenFinderInfo(entry, on: volume),
                   (try? entry.url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true {
                    continue
                }
                guard let identity = try? Self.identity(from: info, url: entry.url, volume: volume) else {
                    throw ScanError.filesChangedDuringScan
                }
                results.append((slot, FileResult(url: entry.url, facts: Self.facts(for: entry.url, identity: identity))))
            }
            condition.lock()
            for (slot, result) in results { fileResults[slot] = result }
            discoveredFiles += results.count
            condition.unlock()
        }

        /// The identity `captureIdentity(at:)` would return, from the `lstat`
        /// the walk already made. Without known volume facts it asks
        /// `captureIdentity` itself, which looks them up.
        private static func identity(from info: stat, url: URL, volume: Volume) throws -> FileOperationJournal.FileIdentity {
            guard let rootPath = volume.rootPath, volume.root != nil else {
                return try FileOperationJournal.captureIdentity(at: url)
            }
            return FileOperationJournal.identity(from: info, volumeRootPath: rootPath, volumeUUIDString: volume.uuid)
        }

        /// Whether a Finder invisible bit could hide this entry without
        /// showing in `st_flags`.
        private static func mayHaveHiddenFinderInfo(_ entry: ListedEntry, on volume: Volume) -> Bool {
            switch volume.finderInfo {
            case .invisibleBitInFileFlags: return false
            case .appleDoubleSibling: return entry.appleDoubleSibling
            case .unknown: return true
            }
        }

        /// FileFacts come from the identity's own `lstat`, converted exactly
        /// as Foundation converts `timespec` values for resource keys. A zero
        /// timestamp may mean the filesystem lacks that field, so those rare
        /// files ask Foundation directly.
        private static func facts(for url: URL, identity: FileOperationJournal.FileIdentity) -> FileFacts {
            let zero = FileOperationJournal.FileIdentity.Timestamp(seconds: 0, nanoseconds: 0)
            if identity.birthTime ?? zero == zero || identity.modificationTime ?? zero == zero {
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
                return FileFacts(size: Int64(values?.fileSize ?? Int(identity.logicalSize ?? 0)),
                                 creationDate: values?.creationDate,
                                 modificationDate: values?.contentModificationDate, identity: identity)
            }
            return FileFacts(size: identity.logicalSize ?? 0,
                             creationDate: identity.birthTime.map(date),
                             modificationDate: identity.modificationTime.map(date),
                             identity: identity)
        }

        /// Matches Foundation's resource-value dates bit for bit (verified
        /// against random nanosecond timestamps on APFS and exFAT).
        static func date(_ time: FileOperationJournal.FileIdentity.Timestamp) -> Date {
            Date(timeIntervalSinceReferenceDate:
                (Double(time.seconds) - Date.timeIntervalBetween1970AndReferenceDate)
                    + 1.0e-9 * Double(time.nanoseconds))
        }

        // MARK: Listing

        private struct ListingFailure: Error {
            let error: NSError
        }

        /// Reads one folder's names. Leading-dot names are hidden; other
        /// hiding needs `lstat` or Finder info and is checked per child.
        private func list(directory path: [UInt8], isCancelled: () -> Bool) throws -> Listing {
            let descriptor = Self.withCPath(path) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else {
                throw ListingFailure(error: Self.readError(errno, url: Self.url(path, isDirectory: false)))
            }
            guard let stream = fdopendir(descriptor) else {
                let code = errno
                close(descriptor)
                throw ListingFailure(error: Self.readError(code, url: Self.url(path, isDirectory: false)))
            }
            defer { closedir(stream) }
            var listing = Listing()
            var appleDoubleNames = Set<String>()
            var count = 0
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 {
                        throw ListingFailure(error: Self.readError(errno, url: Self.url(path, isDirectory: false)))
                    }
                    break
                }
                count += 1
                // Frequent enough for slow network listings; the check is a flag read.
                if count % 32 == 0, isCancelled() { throw CancellationError() }
                let name = Self.name(of: entry)
                guard let first = name.first else { continue }
                if first == 46 { // "."
                    if name.count > 2, name[1] == 95 { // "._"
                        appleDoubleNames.insert(Self.foldedName(name.dropFirst(2)))
                    }
                    continue
                }
                let childPath = path.appendingComponent(name)
                var type = Int32(entry.pointee.d_type)
                if type == DT_UNKNOWN {
                    var info = stat()
                    // Never classify an uninspected entry: it could be a
                    // folder of originals. Only a vanished unrecognized name
                    // is safe to skip; the rest fails visibly, as before.
                    guard Self.lstat(childPath, &info) == 0 else {
                        let code = errno
                        if code == EACCES || code == EPERM { throw Self.entryFailure(code, path: childPath) }
                        let ext = String(decoding: childPath.lastComponent, as: UTF8.self)
                        if code == ENOENT, !isRecognizedExtension((ext as NSString).pathExtension.lowercased()) {
                            continue
                        }
                        throw ScanError.filesChangedDuringScan
                    }
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR: type = DT_DIR
                    case S_IFREG: type = DT_REG
                    default: type = DT_LNK
                    }
                }
                if type == DT_DIR {
                    listing.order.append((true, listing.directories.count))
                    listing.directories.append(ListedEntry(path: childPath, url: Self.url(childPath, isDirectory: true)))
                    continue
                }
                listing.visibleNonDirectoryCount += 1
                guard type == DT_REG else { continue }
                let url = Self.url(childPath, isDirectory: false)
                guard isRecognizedExtension(url.pathExtension.lowercased()) else { continue }
                listing.order.append((false, listing.files.count))
                listing.files.append(ListedEntry(path: childPath, url: url))
            }
            if !appleDoubleNames.isEmpty {
                for index in listing.directories.indices
                where appleDoubleNames.contains(Self.foldedName(listing.directories[index].path.lastComponent)) {
                    listing.directories[index].appleDoubleSibling = true
                }
                for index in listing.files.indices
                where appleDoubleNames.contains(Self.foldedName(listing.files[index].path.lastComponent)) {
                    listing.files[index].appleDoubleSibling = true
                }
            }
            return listing
        }

        // MARK: Volumes

        /// One volume and capability lookup per device, shared by folders and
        /// files. A device number names one mounted volume during the walk.
        private func volume(for device: dev_t, url: URL) -> Volume {
            volumeLock.lock()
            if let known = volumes[device] {
                volumeLock.unlock()
                return known
            }
            volumeLock.unlock()
            let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
            let volume = Volume(root: values?.volume, rootPath: values?.volume?.standardizedFileURL.path,
                                uuid: values?.volumeUUIDString, finderInfo: Self.finderInfoStorage(at: url))
            // A failed lookup is not cached; captureIdentity then performs its
            // own per-entry fallback exactly as before.
            guard values?.volume != nil else { return volume }
            volumeLock.lock()
            defer { volumeLock.unlock() }
            if let known = volumes[device] { return known }
            volumes[device] = volume
            return volume
        }

        private static func finderInfoStorage(at url: URL) -> FinderInfoStorage {
            var fileSystem = statfs()
            let typeName: String? = url.withUnsafeFileSystemRepresentation { path in
                guard let path, statfs(path, &fileSystem) == 0 else { return nil }
                return withUnsafeBytes(of: fileSystem.f_fstypename) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            if typeName == "apfs" || typeName == "hfs" { return .invisibleBitInFileFlags }
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
            struct Reply {
                var length: UInt32
                var capabilities: vol_capabilities_attr_t
            }
            var reply = Reply(length: 0, capabilities: vol_capabilities_attr_t())
            let status = url.withUnsafeFileSystemRepresentation { path in
                path.map { getattrlist($0, &request, &reply, MemoryLayout<Reply>.size, 0) } ?? -1
            }
            guard status == 0 else { return .unknown }
            let flag = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
            let offset = Int(VOL_CAPABILITIES_INTERFACES) * MemoryLayout<UInt32>.size
            let valid = withUnsafeBytes(of: reply.capabilities.valid) { $0.load(fromByteOffset: offset, as: UInt32.self) }
            let native = withUnsafeBytes(of: reply.capabilities.capabilities) { $0.load(fromByteOffset: offset, as: UInt32.self) }
            return valid & flag != 0 && native & flag == 0 ? .appleDoubleSibling : .unknown
        }

        // MARK: Paths and errors

        private static func name(of entry: UnsafeMutablePointer<dirent>) -> [UInt8] {
            let length = Int(entry.pointee.d_namlen)
            return withUnsafeBytes(of: &entry.pointee.d_name) { Array($0.prefix(length)) }
        }

        /// Conservative name match for AppleDouble siblings: case and Unicode
        /// normalization differences only add a query, never skip one.
        private static func foldedName(_ bytes: ArraySlice<UInt8>) -> String {
            String(decoding: bytes, as: UTF8.self).decomposedStringWithCanonicalMapping.lowercased()
        }

        /// CoreFoundation's constructor, as the enumerator uses: Swift's
        /// `URL(fileURLWithFileSystemRepresentation:)` leaves `;` unescaped
        /// where the enumerator writes `%3B`, which would change file IDs.
        static func url(_ path: [UInt8], isDirectory: Bool) -> URL {
            withCPath(path) { NSURL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory, relativeTo: nil) as URL }
        }

        private static func lstat(_ path: [UInt8], _ info: inout stat) -> Int32 {
            withCPath(path) { Darwin.lstat($0, &info) }
        }

        private static func withCPath<T>(_ path: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
            var terminated = path
            terminated.append(0)
            return terminated.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) { body($0.baseAddress!) }
            }
        }

        /// The same Cocoa error FileManager's enumerator reports.
        static func readError(_ code: Int32, url: URL) -> NSError {
            let cocoaCode: Int
            switch code {
            case ENOENT: cocoaCode = NSFileReadNoSuchFileError
            case EACCES, EPERM: cocoaCode = NSFileReadNoPermissionError
            default: cocoaCode = NSFileReadUnknownError
            }
            return NSError(domain: NSCocoaErrorDomain, code: cocoaCode, userInfo: [
                NSFilePathErrorKey: url.path,
                NSURLErrorKey: url,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
            ])
        }

        /// A child that cannot be inspected. Permission errors belong to the
        /// unsearchable parent folder, as the enumerator reports them; a
        /// vanished child is reported like a failed descent.
        private static func entryFailure(_ code: Int32, path: [UInt8]) -> Error {
            let reported = url(code == EACCES || code == EPERM ? path.dropLastComponent : path, isDirectory: false)
            return ScanError.unreadableFolder(reported, readError(code, url: reported))
        }
    }
}

private extension Array where Element == UInt8 {
    var lastComponent: ArraySlice<UInt8> {
        let start = lastIndex(of: 47).map { $0 + 1 } ?? startIndex
        return self[start...]
    }

    var dropLastComponent: [UInt8] {
        guard let slash = lastIndex(of: 47) else { return [] }
        return slash == startIndex ? [47] : Array(self[..<slash])
    }

    func appendingComponent(_ name: [UInt8]) -> [UInt8] {
        var path = self
        if path.last != 47 { path.append(47) }
        path.append(contentsOf: name)
        return path
    }
}
