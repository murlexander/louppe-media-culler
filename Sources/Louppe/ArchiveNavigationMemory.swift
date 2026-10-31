import Darwin
import Foundation

/// Optional browsing memory. It never contains decisions, bookmarks or permission
/// authority, and is stored separately from both session sidecars and caches.
struct ArchiveNavigationMemory: Codable, Equatable, Sendable {
    static let maximumEntries = 128
    static let maximumExpandedFolders = 512
    static let maximumDirectoryEvidence = 1_024

    struct Entry: Codable, Equatable, Sendable {
        let folderID: String
        let directoryIdentity: FileOperationJournal.FileIdentity?
        let position: PinnedFolderPosition
    }

    private struct DirectoryEvidence: Codable, Equatable, Sendable {
        let folderID: String
        let identity: FileOperationJournal.FileIdentity
    }

    let selectedFolderID: String
    let includesDescendants: Bool
    let expandedFolderIDs: Set<String>
    /// Most recently visited first; bounded independently of archive size.
    let entries: [Entry]
    private let directoryEvidence: [DirectoryEvidence]

    var selectedDirectoryIdentity: FileOperationJournal.FileIdentity? {
        directoryEvidence.first { $0.folderID == selectedFolderID }?.identity
    }

    init(index: ArchiveFolderIndex, selectedFolderID: String = "",
         includesDescendants: Bool = true, expandedFolderIDs: Set<String> = [""],
         entries: [Entry] = []) {
        let requested = index.node(for: selectedFolderID) == nil ? "" : selectedFolderID
        // Every remembered ancestor needs its own identity. Extremely deep
        // paths simply reopen at the root rather than retaining unbounded state.
        let ancestry = index.breadcrumbs(to: requested)
        let selected = ancestry.count <= Self.maximumDirectoryEvidence
            && (requested.isEmpty || index.node(for: requested)?.identity?.birthTime != nil)
            ? requested : ""
        var seenEntries: Set<String> = []
        var acceptedEntries: [Entry] = []
        acceptedEntries.reserveCapacity(min(entries.count, Self.maximumEntries))
        // Lazy collection predicates may run again while materializing a prefix.
        // Keep deduplication in one explicit pass; revisiting a stateful predicate
        // could otherwise discard every valid position on its second traversal.
        for entry in entries {
            if acceptedEntries.count == Self.maximumEntries { break }
            guard Self.validID(entry.folderID), entry.position.isValid,
                  !seenEntries.contains(entry.folderID),
                  let node = index.node(for: entry.folderID) else { continue }
            if !entry.folderID.isEmpty {
                guard let old = entry.directoryIdentity, let current = node.identity,
                      ArchiveFolderIndex.sameDirectoryIdentity(old, current) else { continue }
            }
            seenEntries.insert(entry.folderID)
            acceptedEntries.append(entry)
        }

        // Keep the shallowest structure when an Expand All exceeds the bound,
        // so a relaunch restores the visible top levels deterministically.
        let expansions = expandedFolderIDs.filter { id in
            id.isEmpty || (Self.validID(id) && index.node(for: id)?.identity?.birthTime != nil)
        }.sorted(by: Self.shallowerFirst)
        let acceptedExpansions = Array(expansions.prefix(Self.maximumExpandedFolders))

        var evidence: [DirectoryEvidence] = []
        var evidenced: Set<String> = []
        func include(_ id: String) {
            guard evidence.count < Self.maximumDirectoryEvidence,
                  evidenced.insert(id).inserted,
                  let identity = index.node(for: id)?.identity,
                  identity.birthTime != nil else { return }
            evidence.append(.init(folderID: id, identity: identity))
        }
        for node in index.breadcrumbs(to: selected) { include(node.id) }
        for entry in acceptedEntries { include(entry.folderID) }
        for id in acceptedExpansions { include(id) }
        self.selectedFolderID = selected
        self.includesDescendants = includesDescendants
        self.entries = acceptedEntries
        self.expandedFolderIDs = Set(acceptedExpansions.filter { $0.isEmpty || evidenced.contains($0) })
        directoryEvidence = evidence
    }

    func position(for folderID: String) -> PinnedFolderPosition? {
        entries.first { $0.folderID == folderID }?.position
    }

    func remembering(_ position: PinnedFolderPosition, for folderID: String,
                     in index: ArchiveFolderIndex) -> ArchiveNavigationMemory {
        guard position.isValid, let node = index.node(for: folderID) else { return self }
        let fresh = Entry(folderID: folderID, directoryIdentity: node.identity, position: position)
        return ArchiveNavigationMemory(index: index, selectedFolderID: selectedFolderID,
            includesDescendants: includesDescendants, expandedFolderIDs: expandedFolderIDs,
            entries: [fresh] + entries.filter { $0.folderID != folderID })
    }

    /// No I/O: compare saved evidence with the complete freshly validated scan.
    /// A replacement at the same path never inherits navigation state. Search
    /// only actual path ancestors; a prefix sibling is never a fallback.
    func reconciled(with index: ArchiveFolderIndex) -> ArchiveNavigationMemory {
        guard isValid else { return ArchiveNavigationMemory(index: index) }
        let evidence = Dictionary(uniqueKeysWithValues: directoryEvidence.map { ($0.folderID, $0.identity) })
        func matches(_ id: String) -> Bool {
            if id.isEmpty { return index.node(for: "") != nil }
            guard let old = evidence[id], let current = index.node(for: id)?.identity else { return false }
            return ArchiveFolderIndex.sameDirectoryIdentity(old, current)
        }
        var selected = selectedFolderID
        while !matches(selected), !selected.isEmpty {
            selected = selected.lastIndex(of: "/").map { String(selected[..<$0]) } ?? ""
        }
        return ArchiveNavigationMemory(index: index, selectedFolderID: selected,
            includesDescendants: includesDescendants,
            expandedFolderIDs: Set(expandedFolderIDs.filter(matches)), entries: entries)
    }

    fileprivate var isValid: Bool {
        guard Self.validID(selectedFolderID), entries.count <= Self.maximumEntries,
              expandedFolderIDs.count <= Self.maximumExpandedFolders,
              directoryEvidence.count <= Self.maximumDirectoryEvidence,
              Set(entries.map(\.folderID)).count == entries.count,
              Set(directoryEvidence.map(\.folderID)).count == directoryEvidence.count,
              expandedFolderIDs.allSatisfy(Self.validID),
              directoryEvidence.allSatisfy({ Self.validID($0.folderID) && $0.identity.birthTime != nil }),
              entries.allSatisfy({ Self.validID($0.folderID) && $0.position.isValid
                  && ($0.folderID.isEmpty || $0.directoryIdentity?.birthTime != nil) }) else { return false }
        let evidenced = Set(directoryEvidence.map(\.folderID))
        return (selectedFolderID.isEmpty || evidenced.contains(selectedFolderID))
            && expandedFolderIDs.allSatisfy { $0.isEmpty || evidenced.contains($0) }
    }

    static func shallowerFirst(_ left: String, _ right: String) -> Bool {
        let leftDepth = left.isEmpty ? 0 : left.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
        let rightDepth = right.isEmpty ? 0 : right.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
        return leftDepth == rightDepth ? left < right : leftDepth < rightDepth
    }

    private static func validID(_ id: String) -> Bool {
        id.utf8.count <= 16_384 && (id.isEmpty || (
            id.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
            && !id.hasPrefix("/") && !id.hasSuffix("/")
            && !id.split(separator: "/", omittingEmptySubsequences: false).contains {
                $0.isEmpty || $0 == "." || $0 == ".."
            }))
    }
}

enum ArchiveNavigationError: LocalizedError, Equatable {
    case invalidStorage, capacity, changedStorage

    var errorDescription: String? {
        switch self {
        case .invalidStorage:
            L10n.text("Folder navigation could not be restored. Previous positions are retained.")
        case .capacity, .changedStorage:
            L10n.text("Folder navigation could not be saved. Previous positions are retained.")
        }
    }
}

/// One actor owns bounded, durable UI snapshots. Root identity is checked before
/// querying memory; a different drive/folder at the same path finds no record.
actor ArchiveNavigationPersistence {
    static let maximumRoots = 32
    static let maximumBytes = 4 * 1_024 * 1_024

    private struct Record: Codable, Equatable, Sendable {
        let root: PinnedFolderIdentity
        let memory: ArchiveNavigationMemory
    }
    private struct Document: Codable {
        let version: Int
        let records: [Record]
    }

    private let fileURL: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private var records: [Record] = []
    private var loaded = false
    private var revision: Data?

    init(fileURL: URL? = nil,
         write: @escaping @Sendable (Data, URL) throws -> Void = {
             try DurableFileIO.atomicWrite($0, to: $1, fullSync: true)
         }) {
#if LOUPPE_TESTING
        let defaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe-TestNavigation-\(UUID()).json")
#else
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let isTestHost = Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || NSClassFromString("XCTestCase") != nil
        let domain = Bundle.main.bundleIdentifier.flatMap {
            $0.hasPrefix("com.alexandermarkin.louppe") ? $0 : nil
        } ?? "com.alexandermarkin.louppe"
        // Hidden XCTest windows must not evict a person's remembered folders.
        // Packaged review builds retain their own independent UI memory.
        let defaultURL = isTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-TestNavigation-\(UUID()).json")
            : support.appendingPathComponent(domain + "/ArchiveNavigation.json")
#endif
        self.fileURL = fileURL ?? defaultURL
        self.write = write
    }

    private var previousURL: URL { fileURL.appendingPathExtension("previous") }

    func load(for root: PinnedFolderIdentity) throws -> ArchiveNavigationMemory? {
        try readIfNeeded()
        return records.first { $0.root == root }?.memory
    }

    func save(_ memory: ArchiveNavigationMemory, for root: PinnedFolderIdentity) throws {
        guard memory.isValid else { throw ArchiveNavigationError.capacity }
        try readIfNeeded()
        guard records.first(where: { $0.root == root })?.memory != memory else { return }
        let proposed = Array(([Record(root: root, memory: memory)]
            + records.filter { $0.root != root }).prefix(Self.maximumRoots))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, records: proposed))
        guard data.count <= Self.maximumBytes else { throw ArchiveNavigationError.capacity }
        // Refuse an external writer or unreadable primary instead of replacing
        // it with this actor's older view. No source media is read here.
        let currentBytes = try readBytes(fileURL)
        let ownInterruptedWrite = currentBytes == data ? try readBytes(previousURL) == revision : false
        guard currentBytes == revision || ownInterruptedWrite else {
            throw ArchiveNavigationError.changedStorage
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let revision { try write(revision, previousURL) }
        try write(data, fileURL)
        records = proposed
        revision = data
    }

    /// Explicit recovery for optional UI memory. Never follows a state-file
    /// symlink or replaces its target; preserve both leaves before starting over.
    /// Partial failures leave every moved file intact in the recovery directory.
    func resetPreservingEvidence() throws {
        let manager = FileManager.default
        let candidates = [fileURL, previousURL]
        var existing: [URL] = []
        for url in candidates {
            do {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard let type = attributes[.type] as? FileAttributeType,
                      type == .typeRegular || type == .typeSymbolicLink else {
                    throw ArchiveNavigationError.invalidStorage
                }
                existing.append(url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { continue }
        }
        if !existing.isEmpty {
            let recovery = fileURL.deletingLastPathComponent()
                .appendingPathComponent("ArchiveNavigation.recovered-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: recovery, withIntermediateDirectories: false)
            for url in existing {
                try manager.moveItem(at: url, to: recovery.appendingPathComponent(url.lastPathComponent))
            }
        }
        records = []
        revision = nil
        loaded = true
    }

    private func readIfNeeded() throws {
        guard !loaded else { return }
        do {
            let data = try readBytes(fileURL)
            guard let data else {
                // A prior copy means that losing the primary was not a clean
                // first launch. Preserve evidence rather than overwrite it.
                guard try readBytes(previousURL) == nil else { throw ArchiveNavigationError.invalidStorage }
                loaded = true
                return
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, document.records.count <= Self.maximumRoots else {
                throw ArchiveNavigationError.invalidStorage
            }
            for (index, record) in document.records.enumerated() {
                guard record.memory.isValid,
                      !document.records.prefix(index).contains(where: { $0.root == record.root }) else {
                    throw ArchiveNavigationError.invalidStorage
                }
            }
            records = document.records
            revision = data
            loaded = true
        } catch { throw ArchiveNavigationError.invalidStorage }
    }

    /// Open the leaf without following symlinks and cap reads even if the file
    /// grows after fstat. Nonblocking open also rejects FIFO/device surprises.
    private func readBytes(_ url: URL) throws -> Data? {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ArchiveNavigationError.invalidStorage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0, status.st_size <= Self.maximumBytes else {
            throw ArchiveNavigationError.invalidStorage
        }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw ArchiveNavigationError.invalidStorage }
        return data
    }
}
