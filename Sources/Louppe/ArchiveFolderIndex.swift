import Foundation

/// A read-only folder projection of one complete archive inventory. Directory
/// paths are exact ASCII percent-encoded identities, never display strings.
/// Decisions and file-operation authority remain with the archive session.
struct ArchiveFolderIndex: Sendable {
    struct Directory: Equatable, Sendable {
        let id: String
        let parentID: String?
        let name: String
        let identity: FileOperationJournal.FileIdentity?

        init(id: String, parentID: String?, name: String,
             identity: FileOperationJournal.FileIdentity? = nil) {
            self.id = id
            self.parentID = parentID
            self.name = name
            self.identity = identity
        }
    }

    struct Node: Identifiable, Equatable, Sendable {
        let id: String
        let parentID: String?
        let name: String
        let identity: FileOperationJournal.FileIdentity?
        let children: [String]
        let directCount: Int
        let subtreeCount: Int
    }

    let generation: UUID
    let root: URL
    let rootID = ""
    let directories: [Directory]
    let nodes: [String: Node]
    /// Folders with children, in outline pre-order. Expand All uses this
    /// prepared list instead of walking every node on the main actor.
    let expandableFolderIDs: [String]
    /// Folder ordinals in outline pre-order; ordinal 0 is All Media.
    let orderedFolderIDs: [String]
    /// Parent ordinal of each folder (All Media points to itself).
    let parentOrdinals: [Int32]
    /// Each item's physical parent folders, flattened: item `i` owns
    /// `itemFolderOrdinals[itemFolderOffsets[i]..<itemFolderOffsets[i + 1]]`.
    let itemFolderOffsets: [Int32]
    let itemFolderOrdinals: [Int32]
    private let ordinalByID: [String: Int]
    private let subtreeEnds: [Int]
    /// Each physical parent contributes one posting. Paired files in the same
    /// parent contribute once, so storage is bounded by physical membership.
    private let postings: [(folder: Int, item: Int)]
    private let directRanges: [Range<Int>]
    private let itemCount: Int

    init(root: URL, directories: [Directory], items: [PhotoItem]) {
        generation = UUID()
        self.root = root
        itemCount = items.count
        var entries: [String: Directory] = [
            "": Directory(id: "", parentID: nil, name: root.lastPathComponent)
        ]
        // Infer only missing ancestors and item parents. Scanned entries retain
        // their stable identities; inferred structure never grants disk access.
        func include(_ id: String) {
            var current = id
            while entries[current] == nil {
                let parent = Self.parent(of: current)
                entries[current] = Directory(id: current, parentID: parent,
                    name: Self.component(of: current).removingPercentEncoding ?? Self.component(of: current))
                guard let parent else { break }
                current = parent
            }
        }
        for directory in directories where Self.isValidID(directory.id) {
            include(directory.id)
            entries[directory.id] = Directory(id: directory.id,
                parentID: Self.parent(of: directory.id), name: directory.name, identity: directory.identity)
        }
        var physicalParents: [[String]] = []
        physicalParents.reserveCapacity(items.count)
        for item in items {
            var parents: [String] = []
            for file in item.individualFiles {
                // Physical IDs already carry exact relative filesystem bytes.
                // Using displayRelativePath would merge Unicode spellings.
                let parent = Self.parent(of: file.id) ?? ""
                guard Self.isValidID(parent) else { continue }
                include(parent)
                if !parents.contains(parent) { parents.append(parent) }
            }
            physicalParents.append(parents)
        }
        var children: [String: [String]] = [:]
        for entry in entries.values {
            if let parent = entry.parentID { children[parent, default: []].append(entry.id) }
        }
        for parent in Array(children.keys) {
            children[parent]?.sort { left, right in
                let order = entries[left]!.name.localizedStandardCompare(entries[right]!.name)
                return order == .orderedSame ? left < right : order == .orderedAscending
            }
        }
        // Iterative DFS supports deep archives without recursive stack growth.
        var ordered: [String] = []
        var ordinals: [String: Int] = [:]
        var ends: [Int] = []
        var parents: [Int] = []
        var depths: [Int] = []
        var stack: [(id: String, parent: Int, exiting: Bool)] = [("", 0, false)]
        while let entry = stack.popLast() {
            if entry.exiting {
                ends[ordinals[entry.id]!] = ordered.count
                continue
            }
            let ordinal = ordered.count
            ordinals[entry.id] = ordinal
            ordered.append(entry.id)
            ends.append(ordinal + 1)
            parents.append(entry.parent)
            depths.append(ordinal == 0 ? 0 : depths[entry.parent] + 1)
            stack.append((entry.id, entry.parent, true))
            for child in (children[entry.id] ?? []).reversed() {
                stack.append((child, ordinal, false))
            }
        }
        // Binary ancestors make paired-parent de-duplication logarithmic in
        // tree depth instead of retaining every item's ancestor memberships.
        var ancestors = [parents]
        var span = 1
        let maximumDepth = depths.max() ?? 0
        while span <= maximumDepth / 2 {
            let previous = ancestors.last!
            ancestors.append(parents.indices.map { previous[previous[$0]] })
            span *= 2
        }
        func commonAncestor(_ first: Int, _ second: Int) -> Int {
            var left = first, right = second
            if depths[left] < depths[right] { swap(&left, &right) }
            var difference = depths[left] - depths[right]
            var level = 0
            while difference > 0 {
                if difference & 1 == 1 { left = ancestors[level][left] }
                difference >>= 1
                level += 1
            }
            if left == right { return left }
            for level in ancestors.indices.reversed() where ancestors[level][left] != ancestors[level][right] {
                left = ancestors[level][left]
                right = ancestors[level][right]
            }
            return parents[left]
        }
        var direct = Array(repeating: 0, count: ordered.count)
        var counts = Array(repeating: 0, count: ordered.count)
        var bindings: [(folder: Int, item: Int)] = []
        bindings.reserveCapacity(items.count)
        var folderOffsets: [Int32] = [0]
        folderOffsets.reserveCapacity(items.count + 1)
        var folderMemberships: [Int32] = []
        folderMemberships.reserveCapacity(items.count)
        for (item, folderIDs) in physicalParents.enumerated() {
            let folders = folderIDs.compactMap { ordinals[$0] }.sorted()
            folderMemberships.append(contentsOf: folders.map(Int32.init))
            folderOffsets.append(Int32(folderMemberships.count))
            for folder in folders {
                direct[folder] += 1
                counts[folder] += 1
                bindings.append((folder, item))
            }
            // Adjacent DFS memberships subtract exactly their overlapping
            // ancestry. The root/parent counts count review items, not files.
            for position in folders.indices.dropFirst() {
                counts[commonAncestor(folders[position - 1], folders[position])] -= 1
            }
        }
        for ordinal in ordered.indices.reversed() where ordinal != 0 {
            counts[parents[ordinal]] += counts[ordinal]
        }
        bindings.sort { $0.folder == $1.folder ? $0.item < $1.item : $0.folder < $1.folder }
        var ranges: [Range<Int>] = []
        var offset = 0
        for count in direct {
            ranges.append(offset..<(offset + count))
            offset += count
        }
        var preparedNodes: [String: Node] = [:]
        preparedNodes.reserveCapacity(ordered.count)
        for (ordinal, id) in ordered.enumerated() {
            let directory = entries[id]!
            preparedNodes[id] = Node(id: id, parentID: directory.parentID, name: directory.name,
                identity: directory.identity, children: children[id] ?? [],
                directCount: direct[ordinal], subtreeCount: counts[ordinal])
        }
        self.directories = ordered.map { entries[$0]! }
        nodes = preparedNodes
        expandableFolderIDs = ordered.filter { children[$0]?.isEmpty == false }
        orderedFolderIDs = ordered
        parentOrdinals = parents.map(Int32.init)
        itemFolderOffsets = folderOffsets
        itemFolderOrdinals = folderMemberships
        ordinalByID = ordinals
        subtreeEnds = ends
        postings = bindings
        directRanges = ranges
    }

    func node(for id: String) -> Node? { nodes[id] }
    func ordinal(for id: String) -> Int? { ordinalByID[id] }
    var indexedItemCount: Int { itemCount }

    /// The folder's location for Finder. IDs keep exact percent-encoded
    /// filesystem bytes, so the path is rebuilt without decoding.
    func url(for id: String) -> URL? {
        guard nodes[id] != nil else { return nil }
        guard !id.isEmpty else { return root }
        var base = root.path(percentEncoded: true)
        if !base.hasSuffix("/") { base += "/" }
        var components = URLComponents()
        components.scheme = "file"
        components.percentEncodedPath = base + id + "/"
        return components.url
    }
    func children(of id: String) -> [String] { nodes[id]?.children ?? [] }

    func breadcrumbs(to id: String) -> [Node] {
        var result: [Node] = []
        var current = nodes[id]
        while let node = current {
            result.append(node)
            current = node.parentID.flatMap { nodes[$0] }
        }
        return result.reversed()
    }

    /// O(log directories + scoped physical memberships), independent of the
    /// rest of the archive. No directory walk, media read, or metadata request.
    func itemIndices(in id: String, includingDescendants: Bool) -> [Int] {
        guard let ordinal = ordinalByID[id] else { return [] }
        if id.isEmpty, includingDescendants { return Array(0..<itemCount) }
        let range: Range<Int>
        if includingDescendants {
            range = directRanges[ordinal].lowerBound..<postingOffset(for: subtreeEnds[ordinal])
        } else { range = directRanges[ordinal] }
        var seen: Set<Int> = []
        var result: [Int] = []
        result.reserveCapacity(includingDescendants ? nodes[id]!.subtreeCount : nodes[id]!.directCount)
        for posting in postings[range] where seen.insert(posting.item).inserted { result.append(posting.item) }
        return result
    }

    func reproject(items: [PhotoItem]) -> ArchiveFolderIndex {
        ArchiveFolderIndex(root: root, directories: directories, items: items)
    }

    static func sameDirectoryIdentity(_ left: FileOperationJournal.FileIdentity,
                                      _ right: FileOperationJournal.FileIdentity) -> Bool {
        let sameVolume = left.volumeUUIDString.map { right.volumeUUIDString == $0 }
            ?? (right.volumeUUIDString == nil && left.systemNumber == right.systemNumber
                && left.volumeRootPath == right.volumeRootPath)
        return sameVolume && left.fileNumber == right.fileNumber
            && left.birthTime != nil && left.birthTime == right.birthTime
    }

    private func postingOffset(for ordinal: Int) -> Int {
        ordinal < directRanges.count ? directRanges[ordinal].lowerBound : postings.count
    }

    private static func parent(of id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return id.lastIndex(of: "/").map { String(id[..<$0]) } ?? ""
    }

    private static func component(of id: String) -> String {
        id.lastIndex(of: "/").map { String(id[id.index(after: $0)...]) } ?? id
    }

    private static func isValidID(_ id: String) -> Bool {
        id.isEmpty || (id.utf8.allSatisfy { $0 < 128 } && !id.hasPrefix("/") && !id.hasSuffix("/")
            && !id.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}
