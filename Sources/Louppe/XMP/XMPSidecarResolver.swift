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
        members: [XMPStemFamilyMember]
    ) throws -> [XMPSidecarFamilyPlan] {
        guard let directory = members.first?.mediaPath.parent else { return [] }
        guard members.allSatisfy({ $0.mediaPath.parent == directory }) else {
            throw ResolverError.mediaFromDifferentDirectories
        }
        // A volume that will not answer is treated as case-sensitive on
        // purpose: that only ever *narrows* which existing packets Louppe
        // adopts, so a differently-cased third-party file is never merged
        // into. The opposite default could claim `img_0001.xmp` for
        // `IMG_0001.NEF` on a genuinely case-sensitive volume. Nothing is
        // lost on a case-insensitive volume either — the constructed
        // canonical path still resolves to the existing inode, so
        // `XMPMetadataStore.prepareWrite` sees it and merges instead of
        // creating.
        let caseSensitive = try directory.url.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames ?? true
        let enumerated = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: nil,
            options: []
        ).map(XMPExactFileSystemPath.init(url:))
        // Foundation may expose /var as its /private/var alias while listing.
        // Retain only each real entry's exact filename bytes and keep the
        // caller's exact directory prefix as path authority.
        let entries = try enumerated.map {
            try directory.appending(componentBytes: $0.lastComponentBytes)
        }
        return try resolve(
            members: members,
            directoryEntries: entries,
            caseSensitiveNames: caseSensitive
        )
    }

    /// Pure seam used by case-sensitive/case-insensitive collision tests. The
    /// entries still carry exact bytes captured from concrete filesystem URLs.
    static func resolve(
        members: [XMPStemFamilyMember],
        directoryEntries: [XMPExactFileSystemPath],
        caseSensitiveNames: Bool
    ) throws -> [XMPSidecarFamilyPlan] {
        guard let directory = members.first?.mediaPath.parent else { return [] }
        guard members.allSatisfy({ $0.mediaPath.parent == directory }) else {
            throw ResolverError.mediaFromDifferentDirectories
        }

        struct ParsedMember {
            let member: XMPStemFamilyMember
            let filename: String
            let stem: String
            let stemBytes: Data
            let familyKey: String
        }
        let parsed = try members.map { member in
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
        for path in directoryEntries {
            let entryName = try decodedName(path)
            let isXMP = recognizedXMPExtension(entryName, caseSensitiveNames)
            let isACR = !isXMP
                && recognizedACRExtension(entryName, caseSensitiveNames)
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

        let groups = Dictionary(grouping: parsed, by: \ParsedMember.familyKey)
        return try groups.keys.sorted().map { key in
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

            let metadataValues = Set(media.map(\.metadata))
            let disposition: XMPSidecarFamilyPlan.Disposition
            if media.contains(where: { $0.mediaKind != .photo }) {
                disposition = .unsupportedMedia
            } else if exactStemBytes.count > 1 || uniqueCanonical.count > 1 {
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
