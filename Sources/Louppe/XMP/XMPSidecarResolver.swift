import Darwin
import Foundation

struct XMPStemFamilyMember: Equatable, Sendable {
    let mediaPath: XMPExactFileSystemPath
    let mediaKind: MediaKind
    let metadata: XMPPublicationMetadata
    let sessionFileID: String?
    let sessionMetadata: PhotoFileMetadataSnapshot?
    let scannedIdentity: FileOperationJournal.FileIdentity?

    init(
        mediaURL: URL,
        mediaKind: MediaKind = .photo,
        metadata: XMPPublicationMetadata,
        sessionFileID: String? = nil,
        sessionMetadata: PhotoFileMetadataSnapshot? = nil,
        scannedIdentity: FileOperationJournal.FileIdentity? = nil
    ) throws {
        mediaPath = try XMPExactFileSystemPath(url: mediaURL)
        self.mediaKind = mediaKind
        self.metadata = metadata
        self.sessionFileID = sessionFileID
        self.sessionMetadata = sessionMetadata
        self.scannedIdentity = scannedIdentity
    }

    init(
        mediaPath: XMPExactFileSystemPath,
        mediaKind: MediaKind = .photo,
        metadata: XMPPublicationMetadata,
        sessionFileID: String? = nil,
        sessionMetadata: PhotoFileMetadataSnapshot? = nil,
        scannedIdentity: FileOperationJournal.FileIdentity? = nil
    ) {
        self.mediaPath = mediaPath
        self.mediaKind = mediaKind
        self.metadata = metadata
        self.sessionFileID = sessionFileID
        self.sessionMetadata = sessionMetadata
        self.scannedIdentity = scannedIdentity
    }
}

struct XMPSidecarFamilyPlan: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        case publish
        case unsupportedMedia
        case metadataConflict
        case filenameCollision
    }

    let members: [XMPStemFamilyMember]
    let canonicalSidecar: XMPExactFileSystemPath?
    /// Application-owned packets such as IMG_0001.NEF.xmp. Louppe may copy
    /// these byte-for-byte later but never merges its fields into them.
    let extensionQualifiedSidecars: [XMPExactFileSystemPath]
    /// Lightroom Classic 15+ may create a separate heavy-edit packet beside
    /// the original. Louppe never reads, edits, or transfers these files; the
    /// resolver records exact companions only so preflight can warn clearly.
    let excludedACRCompanions: [XMPExactFileSystemPath]
    let metadata: XMPPublicationMetadata?
    let disposition: Disposition
}

enum XMPSidecarResolver {
    enum ResolverError: LocalizedError {
        case mediaFromDifferentDirectories
        case unreadableFilename(XMPExactFileSystemPath)

        var errorDescription: String? {
            switch self {
            case .mediaFromDifferentDirectories:
                return L10n.text("A sidecar family must be resolved within one directory.")
            case .unreadableFilename:
                return L10n.text("A filename is not valid UTF-8 and cannot be matched safely.")
            }
        }
    }

    static func resolve(
        members: [XMPStemFamilyMember],
        isCancelled: () -> Bool = { false }
    ) throws -> [XMPSidecarFamilyPlan] {
        try checkCancellation(isCancelled)
        guard let directory = members.first?.mediaPath.parent else { return [] }
        for (index, member) in members.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(isCancelled) }
            guard member.mediaPath.parent == directory else {
                throw ResolverError.mediaFromDifferentDirectories
            }
        }
        let caseSensitive = try XMPFamilyMembership.caseSensitivity(in: directory)
        try checkCancellation(isCancelled)
        let enumerated = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil,
            options: []
        )
        try checkCancellation(isCancelled)
        // Foundation may expose /var as its /private/var alias while listing.
        // Retain only each real entry's exact filename bytes and keep the
        // caller's exact directory prefix as path authority.
        let entries = try enumerated.enumerated().map { index, url in
            if index.isMultiple(of: 32) { try checkCancellation(isCancelled) }
            let path = try XMPExactFileSystemPath(url: url)
            return try directory.appending(componentBytes: path.lastComponentBytes)
        }
        return try resolve(
            members: members,
            directoryEntries: entries,
            caseSensitiveNames: caseSensitive,
            requireLiveEntries: true,
            isCancelled: isCancelled
        )
    }

    /// Pure seam used by case-sensitive/case-insensitive collision tests. The
    /// entries still carry exact bytes captured from concrete filesystem URLs.
    static func resolve(
        members: [XMPStemFamilyMember],
        directoryEntries: [XMPExactFileSystemPath],
        caseSensitiveNames: Bool,
        requireLiveEntries: Bool = false,
        isCancelled: () -> Bool = { false }
    ) throws -> [XMPSidecarFamilyPlan] {
        try checkCancellation(isCancelled)
        guard let directory = members.first?.mediaPath.parent else { return [] }
        for (index, member) in members.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(isCancelled) }
            guard member.mediaPath.parent == directory else {
                throw ResolverError.mediaFromDifferentDirectories
            }
        }

        struct ParsedMember {
            let member: XMPStemFamilyMember
            let filename: String
            let stem: String
            let stemBytes: Data
            let familyKey: String
        }
        let parsed = try members.enumerated().map { index, member in
            if index.isMultiple(of: 32) { try checkCancellation(isCancelled) }
            let filename = try decodedName(member.mediaPath)
            let stem = deletingFinalExtension(filename)
            return ParsedMember(
                member: member,
                filename: filename,
                stem: stem,
                stemBytes: deletingFinalExtension(
                    member.mediaPath.lastComponentBytes
                ),
                familyKey: comparisonKey(
                    stem,
                    caseSensitiveNames: caseSensitiveNames
                )
            )
        }
        // One pass over the listing indexes every recognized packet by the
        // same comparison key the candidate names use. Rescanning the whole
        // directory once per family made a folder that already holds one
        // packet per photo — the Capture One and Lightroom Classic case this
        // feature exists for — quadratic in the photo count, with a Unicode
        // normalization inside the inner loop.
        var xmpEntriesByKey: [String: Set<XMPExactFileSystemPath>] = [:]
        var acrEntriesByKey: [String: Set<XMPExactFileSystemPath>] = [:]
        // A canonical stem can itself be another media file's full name:
        // IMG.NEF.jpg must never adopt IMG.NEF.xmp from IMG.NEF.
        var mediaFilenameKeys: Set<String> = []
        var mediaByStem: [String: Set<XMPExactFileSystemPath>] = [:]
        for (index, path) in directoryEntries.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(isCancelled) }
            let entryName = try decodedName(path)
            let isXMP = recognizedXMPExtension(entryName, caseSensitiveNames)
            let isACR = !isXMP
                && recognizedACRExtension(entryName, caseSensitiveNames)
            if FolderScanner.isRecognizedExtension(path.url.pathExtension) {
                mediaFilenameKeys.insert(comparisonKey(entryName, caseSensitiveNames: caseSensitiveNames))
                mediaByStem[comparisonKey(deletingFinalExtension(entryName), caseSensitiveNames: caseSensitiveNames), default: []].insert(path)
            }
            guard isXMP || isACR else { continue }
            let key = comparisonKey(
                entryName,
                caseSensitiveNames: caseSensitiveNames
            )
            if isXMP {
                xmpEntriesByKey[key, default: []].insert(path)
            } else {
                acrEntriesByKey[key, default: []].insert(path)
            }
        }

        /// Entries matching any candidate spelling, deduplicated because two
        /// candidate spellings collapse to one key on a case-insensitive
        /// volume, and ordered by exact bytes as the plan's fields promise.
        func matchedEntries(
            for candidateNames: Set<String>,
            in index: [String: Set<XMPExactFileSystemPath>]
        ) -> [XMPExactFileSystemPath] {
            var matches: Set<XMPExactFileSystemPath> = []
            for candidate in candidateNames {
                let key = comparisonKey(
                    candidate,
                    caseSensitiveNames: caseSensitiveNames
                )
                if let entries = index[key] { matches.formUnion(entries) }
            }
            return matches.sorted {
                $0.bytes.lexicographicallyPrecedes($1.bytes)
            }
        }

        var groups: [String: [ParsedMember]] = [:]
        for (index, member) in parsed.enumerated() {
            if index.isMultiple(of: 32) { try checkCancellation(isCancelled) }
            groups[member.familyKey, default: []].append(member)
        }
        return try groups.keys.sorted().map { key in
            try checkCancellation(isCancelled)
            let group = groups[key]!.sorted {
                $0.member.mediaPath.bytes.lexicographicallyPrecedes(
                    $1.member.mediaPath.bytes
                )
            }
            let exactStemBytes = Set(group.map(\.stemBytes))
            let media = group.map(\.member)

            let canonicalNames = Set(group.flatMap {
                ["\($0.stem).xmp", "\($0.stem).XMP"]
            })
            let uniqueCanonical = matchedEntries(
                for: canonicalNames,
                in: xmpEntriesByKey
            )

            let qualifiedNames = Set(group.flatMap {
                ["\($0.filename).xmp", "\($0.filename).XMP"]
            })
            let qualifiedMatches = matchedEntries(
                for: qualifiedNames,
                in: xmpEntriesByKey
            )

            // Adobe documents ACR as a packet beside the original but does
            // not promise one spelling for every media type. Recognize both
            // the shared-stem and extension-qualified forms without adopting
            // unrelated prefix matches.
            let acrNames = Set(group.flatMap {
                [
                    "\($0.stem).acr", "\($0.stem).ACR",
                    "\($0.filename).acr", "\($0.filename).ACR",
                ]
            })
            let uniqueACRCompanions = matchedEntries(
                for: acrNames,
                in: acrEntriesByKey
            )

            let canonical: XMPExactFileSystemPath
            if let existing = uniqueCanonical.first {
                canonical = existing
            } else {
                let stemBytes = deletingFinalExtension(
                    group[0].member.mediaPath.lastComponentBytes
                )
                canonical = try directory.appending(
                    componentBytes: stemBytes + Data(".xmp".utf8)
                )
            }

            let actualMedia = mediaByStem[key] ?? []
            let complete = actualMedia == Set(media.map(\.mediaPath))
            let safe = !requireLiveEntries || actualMedia.allSatisfy {
                (try? XMPFamilyMembership.requireRegular($0)) != nil
            }
            let metadataValues = Set(media.map(\.metadata))
            let disposition: XMPSidecarFamilyPlan.Disposition
            if media.contains(where: { $0.mediaKind != .photo }) {
                disposition = .unsupportedMedia
            } else if !complete || !safe || exactStemBytes.count > 1 || uniqueCanonical.count > 1
                        || mediaFilenameKeys.contains(key) {
                disposition = .filenameCollision
            } else if metadataValues.count != 1 {
                disposition = .metadataConflict
            } else {
                disposition = .publish
            }
            return XMPSidecarFamilyPlan(
                members: media,
                // Preserve a unique packet that already exists even when the
                // family cannot be published. Copy/Move's conditional default
                // still needs to report recognized source XMP accurately, but
                // must not invent a writable target for a conflicted family.
                canonicalSidecar: disposition == .publish
                    ? canonical
                    : (uniqueCanonical.count == 1 ? uniqueCanonical[0] : nil),
                extensionQualifiedSidecars: qualifiedMatches,
                excludedACRCompanions: uniqueACRCompanions,
                metadata: disposition == .publish ? metadataValues.first : nil,
                disposition: disposition
            )
        }
    }

    static func checkCancellation(_ isCancelled: () -> Bool) throws {
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
    }

    private static func decodedName(
        _ path: XMPExactFileSystemPath
    ) throws -> String {
        guard let name = String(
            data: path.lastComponentBytes,
            encoding: .utf8
        ) else {
            throw ResolverError.unreadableFilename(path)
        }
        return name
    }

    private static func comparisonKey(
        _ name: String,
        caseSensitiveNames: Bool
    ) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return caseSensitiveNames ? normalized : normalized.lowercased()
    }

    private static func deletingFinalExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."),
              dot != filename.startIndex else { return filename }
        return String(filename[..<dot])
    }

    private static func deletingFinalExtension(_ filename: Data) -> Data {
        guard let dot = filename.lastIndex(of: UInt8(ascii: ".")),
              dot != filename.startIndex else { return filename }
        return filename[..<dot]
    }

    private static func recognizedXMPExtension(
        _ filename: String,
        _ caseSensitiveNames: Bool
    ) -> Bool {
        if caseSensitiveNames {
            return filename.hasSuffix(".xmp") || filename.hasSuffix(".XMP")
        }
        return filename.lowercased().hasSuffix(".xmp")
    }

    private static func recognizedACRExtension(
        _ filename: String,
        _ caseSensitiveNames: Bool
    ) -> Bool {
        if caseSensitiveNames {
            return filename.hasSuffix(".acr") || filename.hasSuffix(".ACR")
        }
        return filename.lowercased().hasSuffix(".acr")
    }
}

/// A fresh observation, not an atomic exclusion of external writers. Exact
/// bytes own membership; normalized keys are used only to find possible owners.
struct XMPFamilyMembership: Equatable, Sendable {
    let parent: DurableFileIO.DirectoryBinding
    let paths: Set<XMPExactFileSystemPath>
    let identities: [XMPExactFileSystemPath: FileOperationJournal.FileIdentity]

    init(members: [XMPStemFamilyMember]) throws {
        guard let first = members.first else { throw Changed() }
        parent = try DurableFileIO.DirectoryBinding(url: first.mediaPath.parent.url)
        paths = Set(members.map(\.mediaPath))
        guard paths.count == members.count else { throw Changed() }
        identities = try Dictionary(uniqueKeysWithValues: members.map {
            ($0.mediaPath, try $0.scannedIdentity ?? FileOperationJournal.captureIdentity(at: $0.mediaPath.url))
        })
    }

    struct Changed: LocalizedError {
        var errorDescription: String? {
            L10n.text("The sidecar's media family changed or could not be verified. Rescan the folder before changing XMP.")
        }
    }

    func validate(removing moved: Set<XMPExactFileSystemPath> = [],
                  isCancelled: () -> Bool = { false },
                  measured: (Int, Int) -> Void = { _, _ in }) throws {
        try parent.requireCurrentPath()
        let directory = try XMPExactFileSystemPath(url: parent.url)
        let sensitive = try Self.caseSensitivity(in: directory)
        let stems = try Set(paths.map { Self.key(Self.stem(try Self.name($0)), sensitive) })
        let keys = try Set(paths.flatMap { path -> [String] in
            let name = try Self.name(path)
            return [Self.key(Self.stem(name), sensitive), Self.key(name, sensitive)]
        })
        // The second key detects a newly introduced nested-stem owner, e.g.
        // PAIR.NEF.jpg competing for the application packet PAIR.NEF.xmp.
        let actual = try Self.census(directory: directory, sensitive: sensitive,
                                      isCancelled: isCancelled, measured: measured) { name in
            keys.contains(Self.key(Self.stem(name), sensitive))
                || stems.contains(Self.key(name, sensitive))
        }
        guard actual == paths.subtracting(moved) else { throw Changed() }
        for (index, path) in actual.enumerated() {
            if index.isMultiple(of: 32) { try XMPSidecarResolver.checkCancellation(isCancelled) }
            guard let expected = identities[path],
                  try FileOperationJournal.captureIdentity(at: path.url) == expected else { throw Changed() }
        }
        try parent.requireCurrentPath()
    }

    /// Recovery has no reviewed membership to adopt. Any possible canonical or
    /// extension-qualified owner requires preserving the original packet.
    static func hasPossibleOwners(packet: XMPExactFileSystemPath) throws -> Bool {
        let binding = try DurableFileIO.DirectoryBinding(url: packet.parent.url)
        try binding.requireCurrentPath()
        let sensitive = try caseSensitivity(in: packet.parent)
        let packetStem = key(stem(try name(packet)), sensitive)
        let found = try census(directory: packet.parent, sensitive: sensitive) { name in
            key(stem(name), sensitive) == packetStem || key(name, sensitive) == packetStem
        }
        try binding.requireCurrentPath()
        return !found.isEmpty
    }

    /// Return true when a current owner requires the canonical packet. Never
    /// adopt a foreign collision, or discard the only packet from an old plan.
    static func retainPacketIfOwned(packet: XMPExactFileSystemPath,
                                    artifact: URL?,
                                    identity: FileOperationJournal.FileIdentity,
                                    digest: Data?) throws -> Bool {
        guard try hasPossibleOwners(packet: packet) else { return false }
        let binding = try DurableFileIO.DirectoryBinding(url: packet.parent.url)
        let canonicalExists = packet.entryExists
        guard !(canonicalExists && artifact != nil) else { throw Changed() }
        let location = canonicalExists ? packet.url : artifact
        guard let location, let digest else { throw Changed() }
        try FileOperationJournal.requireIdentity(identity, at: location, includeStatusChange: false)
        guard try FileOperationJournal.contentDigest(at: location) == digest else { throw Changed() }
        let directory = try DurableFileIO.BoundDirectory(binding)
        if !canonicalExists {
            try directory.move(location, to: packet.url, in: directory, strategy: .exclusivePOSIX)
        }
        try directory.syncRename(to: directory, policy: .required)
        try binding.requireCurrentPath()
        try FileOperationJournal.requireIdentity(identity, at: packet.url, includeStatusChange: false)
        guard try FileOperationJournal.contentDigest(at: packet.url) == digest else { throw Changed() }
        return true
    }

    static func caseSensitivity(in directory: XMPExactFileSystemPath) throws -> Bool {
        try requireKnownCaseSensitivity(directory.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames)
    }

    static func requireKnownCaseSensitivity(_ value: Bool?) throws -> Bool {
        guard let value else { throw Changed() }
        return value
    }

    static func census(directory: XMPExactFileSystemPath, sensitive: Bool,
                       isCancelled: () -> Bool = { false },
                       measured: (Int, Int) -> Void = { _, _ in },
                       matches: (String) -> Bool) throws -> Set<XMPExactFileSystemPath> {
        try autoreleasepool {
            try XMPSidecarResolver.checkCancellation(isCancelled)
            let entries = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            var result = Set<XMPExactFileSystemPath>()
            for (index, entry) in entries.enumerated() {
                if index.isMultiple(of: 32) { try XMPSidecarResolver.checkCancellation(isCancelled) }
                // Capture raw entry bytes before any string comparison. Only
                // possible owners need a full exact-path round trip and lstat.
                let component = try entry.withUnsafeFileSystemRepresentation { pointer -> Data in
                    guard let pointer else { throw Changed() }
                    let bytes = UnsafeRawBufferPointer(start: pointer, count: strlen(pointer))
                    guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { throw Changed() }
                    return Data(bytes[(slash + 1)...])
                }
                guard let name = String(data: component, encoding: .utf8) else { throw Changed() }
                guard matches(name),
                      FolderScanner.isRecognizedExtension((name as NSString).pathExtension) else { continue }
                let path = try directory.appending(componentBytes: component)
                try requireRegular(path)
                result.insert(path)
            }
            try XMPSidecarResolver.checkCancellation(isCancelled)
            measured(entries.count, result.count)
            return result
        }
    }

    static func requireRegular(_ path: XMPExactFileSystemPath) throws {
        var info = Darwin.stat()
        guard path.withFileSystemRepresentation({ Darwin.lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              path.withFileSystemRepresentation({ Darwin.access($0, R_OK) }) == 0 else { throw Changed() }
    }
    static func name(_ path: XMPExactFileSystemPath) throws -> String {
        guard let result = String(data: path.lastComponentBytes, encoding: .utf8) else { throw Changed() }
        return result
    }
    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
    static func key(_ name: String, _ sensitive: Bool) -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        return sensitive ? normalized : normalized.lowercased()
    }
}
