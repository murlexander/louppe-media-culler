import Darwin
import Foundation

/// A stored pin or recent-folder bookmark that may cover an ancestor of the
/// opened folder. `path` is the stored spelling and may be stale after a
/// rename; candidates come from the resolved bookmark, verified against the
/// opened folder's physical ancestry.
struct NestedSessionGrant: Equatable, Sendable {
    let path: String
    let bookmark: Data
}

/// Read-only import of decisions saved by other folder sessions that cover the
/// opened folder's files: sidecars of descendant folders found by discovery,
/// and of ancestors an existing pin or recent bookmark already grants.
///
/// Each field (decision, stars, color) independently takes the value with the
/// latest change date. The opened folder's restored value wins an exact tie;
/// among other copies the folder closest to the file wins. Undated foreign
/// fields are skipped. A value applies only to the same verified physical file
/// (exact rebased path plus schema ≥4 identity); recovery history never
/// applies. Foreign sidecars are only read; nothing here writes, prompts or
/// creates save authority. Runs on the opening worker before any preview.
enum NestedSessionMerge {
    struct Summary: Equatable, Sendable {
        /// Physical files whose decision, stars or color, or its date,
        /// changed; hard links to one file count once.
        var changedFiles = 0
        /// Foreign sidecars that supplied at least one of those changes.
        var contributingSessions = 0
        /// Checked off-main only after a change: false keeps the session
        /// clean, as a read-only folder's own open would be.
        var rootIsWritable = true
    }

    /// Ancestor bookmark resolution and scope. Injectable for tests.
    /// Pin and recent bookmarks always carry a security scope; in both builds
    /// a grant whose scope does not start confers nothing. Reading without
    /// it could raise a macOS privacy prompt in the Developer ID build.
    struct GrantAccess: Sendable {
        var resolve: @Sendable (Data) throws -> URL
        var access: SecurityScopedResourceAccess
        /// The volume a bookmark recorded, read from the bookmark bytes alone
        /// (no disk or network lookup). Only bookmarks on the opened folder's
        /// volume are resolved at all.
        var bookmarkVolume: @Sendable (Data) -> Volume? = { data in
            URL.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey], fromBookmarkData: data)
                .flatMap { Volume(uuid: $0.volumeUUIDString, path: $0.volume?.standardizedFileURL.path) }
        }

        static let live = GrantAccess(
            resolve: { data in
                var isStale = false
                // Never mounts a volume, shows UI or refreshes the bookmark.
                return try URL(resolvingBookmarkData: data,
                               options: [.withSecurityScope, .withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &isStale)
            },
            access: .live
        )
    }

    /// A volume by UUID, or by mount path when a UUID is unavailable.
    struct Volume: Equatable, Sendable {
        let uuid: String?
        let path: String?

        init?(uuid: String?, path: String?) {
            guard uuid?.isEmpty == false || path?.isEmpty == false else { return nil }
            self.uuid = uuid?.isEmpty == false ? uuid : nil
            self.path = path?.isEmpty == false ? path : nil
        }

        /// The opened folder's volume, looked up on the opening worker.
        init?(of folder: URL) {
            let values = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
            self.init(uuid: values?.volumeUUIDString, path: values?.volume?.standardizedFileURL.path)
        }

        /// Unknown never matches: a bookmark on a different or unknown volume
        /// is skipped rather than resolved.
        func isSame(as other: Volume) -> Bool {
            if let uuid, let otherUUID = other.uuid { return uuid == otherUUID }
            if let path, let otherPath = other.path { return path == otherPath }
            return false
        }
    }

    struct Environment: Sendable {
        /// Pin and recent bookmarks captured for this open.
        var grants: @Sendable () async -> [NestedSessionGrant] = { [] }
        var grantAccess: GrantAccess = .live
        #if LOUPPE_TEST_SEAMS
        /// Runs before each foreign sidecar is opened; a thrown error counts
        /// as that sidecar being unreadable.
        var willReadSidecar: (@Sendable (URL) throws -> Void)? = nil
        /// Raw-byte bound of one decode batch.
        var maximumBatchBytes = Batch.defaultMaximumBytes
        /// Reports the raw bytes of each batch as it is decoded.
        var didFlushBatch: (@Sendable (Int) -> Void)? = nil
        #endif

        func permitsRead(of sidecar: URL) -> Bool {
            #if LOUPPE_TEST_SEAMS
            guard let willReadSidecar else { return true }
            return (try? willReadSidecar(sidecar)) != nil
            #else
            true
            #endif
        }

        fileprivate func makeBatch() -> Batch {
            #if LOUPPE_TEST_SEAMS
            Batch(maximumBytes: maximumBatchBytes, didFlush: didFlushBatch)
            #else
            Batch(maximumBytes: Batch.defaultMaximumBytes)
            #endif
        }
    }

    static func apply(
        to items: [PhotoItem],
        root: URL,
        rootIdentity: SessionPersistence.SourceFolderIdentity,
        descendants: [FolderScanner.SessionSidecarFolder],
        environment: Environment,
        isCancelled: @Sendable () -> Bool
    ) async throws -> Summary {
        let reducer = Reducer(items: items)
        var batch = environment.makeBatch()
        for folder in descendants {
            if isCancelled() { throw CancellationError() }
            let sidecar = folder.url.appendingPathComponent(SessionConstants.sidecarName)
            guard environment.permitsRead(of: sidecar) else { continue }
            guard let data = try readSidecar(inFolder: folder.url, identity: folder.identity,
                                             isCancelled: isCancelled) else { continue }
            let depth = folder.directoryID.split(separator: "/", omittingEmptySubsequences: false).count
            try batch.append(data, rebase: .descendant(folder.directoryID + "/"), closeness: depth,
                             reducer: reducer, isCancelled: isCancelled)
        }
        let grants = await environment.grants()
        if isCancelled() { throw CancellationError() }
        if !grants.isEmpty {
            try readAncestorSidecars(root: root, rootIdentity: rootIdentity, grants: grants,
                                     environment: environment, isCancelled: isCancelled) { ancestor in
                try batch.append(ancestor.data, rebase: .ancestor(ancestor.prefix), closeness: -ancestor.distance,
                                 reducer: reducer, isCancelled: isCancelled)
            }
        }
        try batch.flush(into: reducer, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        var summary = reducer.apply()
        if summary.changedFiles > 0 { summary.rootIsWritable = isWritableDirectory(root) }
        return summary
    }

    /// The same permission and read-only-volume check the sidecar write would
    /// meet, without writing anything.
    private static func isWritableDirectory(_ folder: URL) -> Bool {
        folder.withUnsafeFileSystemRepresentation { path in
            path.map { faccessat(AT_FDCWD, $0, W_OK, AT_EACCESS) == 0 } ?? false
        }
    }

    /// Sidecars read but not yet decoded. JSON decoding dominates nested
    /// merging; a batch decodes on four workers (more add contention, not
    /// speed) and each worker folds its document as soon as it is decoded, so
    /// decoded copies never accumulate. A batch flushes before a sidecar would
    /// take it past 64 MiB of raw bytes; an oversized valid sidecar goes alone.
    /// Descendant and ancestor sidecars both enter as they are read.
    fileprivate struct Batch {
        static let maximumCount = 32
        static let decodeWorkers = 4
        static let defaultMaximumBytes = 64 * 1_024 * 1_024
        let maximumBytes: Int
        #if LOUPPE_TEST_SEAMS
        var didFlush: (@Sendable (Int) -> Void)? = nil
        #endif
        private var pending: [(data: Data, rebase: Rebase, closeness: Int)] = []
        private var bytes = 0
        private var nextSource = 0

        mutating func append(_ data: Data, rebase: Rebase, closeness: Int, reducer: Reducer,
                             isCancelled: @Sendable () -> Bool) throws {
            if !pending.isEmpty, bytes + data.count > maximumBytes {
                try flush(into: reducer, isCancelled: isCancelled)
            }
            pending.append((data, rebase, closeness))
            bytes += data.count
            if pending.count >= Self.maximumCount || bytes >= maximumBytes {
                try flush(into: reducer, isCancelled: isCancelled)
            }
        }

        mutating func flush(into reducer: Reducer, isCancelled: @Sendable () -> Bool) throws {
            guard !pending.isEmpty else { return }
            let inputs = pending
            let firstSource = nextSource
            nextSource += inputs.count
            pending.removeAll()
            #if LOUPPE_TEST_SEAMS
            didFlush?(bytes)
            #endif
            bytes = 0
            let workers = min(Self.decodeWorkers, inputs.count)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for index in stride(from: worker, to: inputs.count, by: workers) {
                    guard !reducer.hasFailed,
                          let session = SessionPersistence.decodeForeignSnapshot(inputs[index].data) else { continue }
                    reducer.fold(session, rebase: inputs[index].rebase, closeness: inputs[index].closeness,
                                 source: firstSource + index, isCancelled: isCancelled)
                }
            }
            try reducer.throwIfFailed()
        }
    }

    // MARK: Reducer

    fileprivate enum Rebase {
        /// Descendant folder ID plus "/", prepended to each entry key.
        case descendant(String)
        /// Path from the ancestor to the opened folder plus "/", stripped.
        case ancestor(String)
    }

    private struct Candidate<Value> {
        let value: Value
        let date: Date
        let closeness: Int
        let source: Int

        func beats(_ other: Self?) -> Bool {
            guard let other else { return true }
            return date != other.date ? date > other.date : closeness > other.closeness
        }
    }

    private struct Pending {
        let file: Int
        var decision: Candidate<Rating>?
        var stars: Candidate<StarRating?>?
        var color: Candidate<PhotoColorLabel?>?

        mutating func take(rating: Rating, ratedAt: Date?, stars: StarRating?, starsAt: Date?,
                           color colorLabel: PhotoColorLabel?, colorAt: Date?, closeness: Int, source: Int) {
            if let ratedAt {
                let candidate = Candidate(value: rating, date: ratedAt, closeness: closeness, source: source)
                if candidate.beats(decision) { decision = candidate }
            }
            if let starsAt {
                let candidate = Candidate(value: stars, date: starsAt, closeness: closeness, source: source)
                if candidate.beats(self.stars) { self.stars = candidate }
            }
            if let colorAt {
                let candidate = Candidate(value: colorLabel, date: colorAt, closeness: closeness, source: source)
                if candidate.beats(color) { color = candidate }
            }
        }
    }

    /// Sparse: only verified files with a dated foreign field are retained.
    /// Decode workers fold under one lock; the result is independent of
    /// fold order (latest date, then closeness; sources only counted).
    fileprivate final class Reducer: @unchecked Sendable {
        let items: [PhotoItem]
        private let lock = NSLock()
        private var files: [PhotoFile] = []
        private var fileIndexByID: [String: Int]?
        private var pending: [Int: Pending] = [:]
        private var failure: Error?

        init(items: [PhotoItem]) { self.items = items }

        var hasFailed: Bool { lock.withLock { failure != nil } }

        func throwIfFailed() throws {
            if let failure = lock.withLock({ failure }) { throw failure }
        }

        func fold(_ session: SessionFile, rebase: Rebase, closeness: Int, source: Int,
                  isCancelled: () -> Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard failure == nil else { return }
            do { try foldLocked(session, rebase: rebase, closeness: closeness, source: source,
                                isCancelled: isCancelled) }
            catch { failure = error }
        }

        private func foldLocked(_ session: SessionFile, rebase: Rebase, closeness: Int, source: Int,
                                isCancelled: () -> Bool) throws {
            guard session.version >= 4,
                  session.fileIDEncoding == .percentEncodedFileSystemPath else { return }
            let hasNativeMetadata = session.version >= 5
            for (offset, entry) in session.entries.enumerated() {
                if offset % 1_024 == 0, isCancelled() { throw CancellationError() }
                let ratedAt = entry.ratedAt
                let starsAt = hasNativeMetadata ? entry.starsChangedAt : nil
                let colorAt = hasNativeMetadata ? entry.colorChangedAt : nil
                guard ratedAt != nil || starsAt != nil || colorAt != nil,
                      let expected = entry.fileIdentity,
                      let rating = Rating(rawValue: entry.rating) else { continue }
                let fileID: String
                switch rebase {
                case .descendant(let prefix):
                    fileID = prefix + entry.filename
                case .ancestor(let prefix):
                    // Percent-encoded IDs are ASCII: byte and character counts agree.
                    guard entry.filename.utf8.count > prefix.utf8.count,
                          entry.filename.utf8.starts(with: prefix.utf8) else { continue }
                    fileID = String(entry.filename.dropFirst(prefix.count))
                }
                if fileIndexByID == nil { buildIndex() }
                guard let index = fileIndexByID?[fileID], let actual = files[index].scannedIdentity,
                      SessionRatingIndex.persistedIdentityMatches(expected: expected, actual: actual)
                else { continue }
                pending[index, default: Pending(file: index)].take(
                    rating: rating, ratedAt: ratedAt, stars: entry.stars, starsAt: starsAt,
                    color: entry.colorLabel, colorAt: colorAt, closeness: closeness, source: source)
            }
        }

        private func buildIndex() {
            var index: [String: Int] = [:]
            index.reserveCapacity(items.count)
            for item in items {
                for file in item.individualFiles {
                    index[file.id] = files.count
                    files.append(file)
                }
            }
            fileIndexByID = index
        }

        /// A foreign field wins only with a strictly later date than the
        /// restored local field, or over an undated local field.
        func apply() -> Summary {
            lock.lock()
            defer { lock.unlock() }
            var summary = Summary()
            var contributing = Set<Int>()
            var changedFiles = Set<SessionRatingIndex.PersistedIdentityKey>()
            for record in pending.values {
                let file = files[record.file]
                let base = file.metadataSnapshot
                func wins(_ date: Date, over local: Date?) -> Bool { local.map { date > $0 } ?? true }
                var rating = base.rating, ratedAt = base.ratedAt
                var stars = base.starRating, starsAt = base.starsChangedAt
                var color = base.colorLabel, colorAt = base.colorChangedAt
                var used: [Int] = []
                if let decision = record.decision, wins(decision.date, over: ratedAt) {
                    rating = decision.value; ratedAt = decision.date; used.append(decision.source)
                }
                if let candidate = record.stars, wins(candidate.date, over: starsAt) {
                    stars = candidate.value; starsAt = candidate.date; used.append(candidate.source)
                }
                if let candidate = record.color, wins(candidate.date, over: colorAt) {
                    color = candidate.value; colorAt = candidate.date; used.append(candidate.source)
                }
                guard !used.isEmpty else { continue }
                file.restoreMetadata(PhotoFileMetadataSnapshot(
                    fileID: base.fileID, rating: rating, ratedAt: ratedAt,
                    starRating: stars, starsChangedAt: starsAt,
                    colorLabel: color, colorChangedAt: colorAt))
                // Each name is applied on its own exact path; the notice
                // counts physical files, so hard links count once.
                if let identity = file.scannedIdentity {
                    changedFiles.insert(SessionRatingIndex.PersistedIdentityKey(identity))
                }
                contributing.formUnion(used)
            }
            summary.changedFiles = changedFiles.count
            summary.contributingSessions = contributing.count
            return summary
        }
    }

    // MARK: Reading

    /// Opens the folder without following a final symlink and requires the
    /// identity discovery captured, then reads its sidecar leaf.
    private static func readSidecar(
        inFolder folder: URL,
        identity: FileOperationJournal.FileIdentity,
        isCancelled: () -> Bool
    ) throws -> Data? {
        let descriptor = folder.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              UInt64(info.st_dev) == identity.systemNumber,
              UInt64(info.st_ino) == identity.fileNumber else { return nil }
        return try readLeaf(in: descriptor, isCancelled: isCancelled)
    }

    /// A bounded, no-follow read of `.louppe_session.json` relative to a held
    /// folder descriptor. Missing, unreadable, nonregular, oversized or
    /// changed-while-reading files contribute nothing.
    private static func readLeaf(in directory: Int32, isCancelled: () -> Bool) throws -> Data? {
        let descriptor = SessionConstants.sidecarName.withCString { name in
            var result: Int32
            repeat {
                result = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            } while result < 0 && errno == EINTR
            return result
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= Int64(SessionPersistence.maximumForeignSnapshotBytes) else { return nil }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            if isCancelled() { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= Int(before.st_size) else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              data.count == Int(before.st_size) else { return nil }
        return data
    }

    private struct AncestorSidecar {
        let data: Data
        /// Exact relative ID of the opened folder under the ancestor, plus "/".
        let prefix: String
        /// Folder levels between the ancestor and the opened folder (≥ 1).
        let distance: Int
    }

    /// Reads sidecars on the opened folder's physical ancestor chain, only
    /// from each granted folder down, and hands each one to `accept` as soon
    /// as it is read, so ancestors stay within the decode batch bound. A
    /// grant counts only after it resolves silently, starts its security
    /// scope, and a no-follow descent from it that reads nothing reaches the
    /// opened folder's own identity; a second descent then reads each level,
    /// stopping at the first directory whose identity differs from the
    /// first. Nothing above the highest such grant, and no sibling, is ever
    /// opened.
    private static func readAncestorSidecars(
        root: URL,
        rootIdentity: SessionPersistence.SourceFolderIdentity,
        grants: [NestedSessionGrant],
        environment: Environment,
        isCancelled: () -> Bool,
        accept: (AncestorSidecar) throws -> Void
    ) throws {
        guard let rootPath = physicalPath(of: root), rootPath.count > 1 else { return }
        let rootSpellings = Set([String(decoding: rootPath, as: UTF8.self), root.standardizedFileURL.path,
                                 root.resolvingSymlinksInPath().path])
        func mayCover(_ path: String) -> Bool {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return path.hasPrefix("/") && rootSpellings.contains { $0.hasPrefix(prefix) }
        }
        // A pinned or recent parent may have been renamed since its path was
        // stored, so its bookmark is resolved rather than its path trusted.
        // Only bookmarks that record the opened folder's own volume are
        // resolved (read from the bookmark bytes, no disk lookup): another
        // or an unknown volume, such as an unreachable network mount, is
        // never touched. Resolution is silent and never mounts or refreshes;
        // only a resolved location that can hold the opened folder is scoped
        // and verified below.
        guard let rootVolume = Volume(of: root) else { return }
        var candidates: [URL] = []
        for grant in grants {
            if isCancelled() { throw CancellationError() }
            guard environment.grantAccess.bookmarkVolume(grant.bookmark)?.isSame(as: rootVolume) == true else {
                continue
            }
            let resolved = try? environment.grantAccess.resolve(grant.bookmark)
            if isCancelled() { throw CancellationError() }
            guard let url = resolved,
                  mayCover(url.path) || mayCover(url.standardizedFileURL.path) else { continue }
            candidates.append(url)
        }
        candidates.sort { $0.standardizedFileURL.pathComponents.count < $1.standardizedFileURL.pathComponents.count }
        guard !candidates.isEmpty else { return }
        let encodedRoot = encodedPath(rootPath)
        var settledDistances = Set<Int>()
        for grantURL in candidates {
            if isCancelled() { throw CancellationError() }
            let access = environment.grantAccess.access
            let started = access.start(grantURL)
            defer { if started { access.stop(grantURL) } }
            guard started else { continue }
            let top = openDirectory(grantURL)
            guard top >= 0 else { continue }
            guard let grantPath = descriptorPath(top),
                  let components = components(of: rootPath, below: grantPath) else {
                close(top)
                continue
            }
            // Verify first: the chain must reach the opened folder itself.
            var levels: [DirectoryIdentity] = []
            let reachesRoot = descend(from: top, through: components, to: rootIdentity) { _, directory in
                guard let identity = DirectoryIdentity(directory) else { return false }
                levels.append(identity)
                return true
            }
            guard reachesRoot else { continue }
            let again = openDirectory(grantURL)
            guard again >= 0 else { continue }
            var levelPath = grantPath
            _ = try descend(from: again, through: components, to: rootIdentity) { index, directory in
                guard DirectoryIdentity(directory) == levels[index] else { return false }
                defer { levelPath += [47] + components[index] }
                let distance = components.count - index
                guard !settledDistances.contains(distance) else { return true }
                let sidecar = url(levelPath + Array("/\(SessionConstants.sidecarName)".utf8), isDirectory: false)
                guard environment.permitsRead(of: sidecar) else { return true }
                let data = try readLeaf(in: directory, isCancelled: isCancelled)
                // An absent sidecar is settled; a refused one may still be
                // readable under another grant.
                if data != nil || leafIsAbsent(in: directory) { settledDistances.insert(distance) }
                guard let data else { return true }
                let levelBytes = Array(rootPath.prefix(rootPath.count
                    - components.suffix(distance).reduce(0) { $0 + $1.count + 1 }))
                let encodedLevel = encodedPath(levelBytes)
                let dropped = encodedLevel == "/" ? 1 : encodedLevel.count + 1
                guard encodedRoot.hasPrefix(encodedLevel), encodedRoot.count > dropped else { return true }
                try accept(AncestorSidecar(data: data, prefix: String(encodedRoot.dropFirst(dropped)) + "/",
                                           distance: distance))
                return true
            }
        }
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init?(_ descriptor: Int32) {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return nil }
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    private static func openDirectory(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
    }

    /// Descends `components` from `descriptor`, which it takes over, without
    /// following links: one descriptor at a time, closed on every exit,
    /// cancellation included. `visit` sees each level above the opened
    /// folder, the grant first (index 0), and stops the descent by returning
    /// false. True only when the descent ends at the opened folder itself.
    private static func descend(
        from descriptor: Int32,
        through components: [[UInt8]],
        to rootIdentity: SessionPersistence.SourceFolderIdentity,
        visit: (_ index: Int, _ directory: Int32) throws -> Bool
    ) rethrows -> Bool {
        var current = descriptor
        defer { if current >= 0 { close(current) } }
        for (index, component) in components.enumerated() {
            guard try visit(index, current) else { return false }
            var name = component
            name.append(0)
            let parent = current
            let next = name.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) {
                    openat(parent, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            close(current)
            current = next
            guard current >= 0 else { return false }
        }
        var info = stat()
        return fstat(current, &info) == 0
            && UInt64(info.st_dev) == rootIdentity.systemNumber
            && UInt64(info.st_ino) == rootIdentity.fileNumber
    }

    private static func leafIsAbsent(in directory: Int32) -> Bool {
        var info = stat()
        let status = SessionConstants.sidecarName.withCString {
            fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        return status != 0 && errno == ENOENT
    }

    /// Path components of `path` strictly below `ancestor`, or nil.
    private static func components(of path: [UInt8], below ancestor: [UInt8]) -> [[UInt8]]? {
        let base = ancestor == [47] ? [] : ancestor
        guard path.count > base.count + 1, path.starts(with: base), path[base.count] == 47 else { return nil }
        let parts = path[(base.count + 1)...].split(separator: 47, omittingEmptySubsequences: false).map(Array.init)
        return parts.contains(where: \.isEmpty) ? nil : parts
    }

    private static func physicalPath(of folder: URL) -> [UInt8]? {
        let descriptor = openDirectory(folder)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return descriptorPath(descriptor)
    }

    private static func descriptorPath(_ descriptor: Int32) -> [UInt8]? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return bytes.first == 47 ? bytes : nil
    }

    /// The scanner's spelling: CoreFoundation's file URL constructor from raw
    /// bytes, then the percent-encoded path. Percent-encoding is per byte, so
    /// an ancestor's spelling is a prefix of the opened folder's.
    private static func encodedPath(_ bytes: [UInt8]) -> String {
        url(bytes, isDirectory: false).path(percentEncoded: true)
    }

    private static func url(_ bytes: [UInt8], isDirectory: Bool) -> URL {
        var terminated = bytes
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                NSURL(fileURLWithFileSystemRepresentation: $0.baseAddress!, isDirectory: isDirectory,
                      relativeTo: nil) as URL
            }
        }
    }
}

@MainActor
extension SessionStore {
    /// Ancestor grants: stored pins plus the recents captured before this
    /// open. Test hooks may replace resolution, scope and reads.
    func nestedSessionEnvironment(recents: [NestedSessionGrant]) -> NestedSessionMerge.Environment {
        let pins = pinnedFolders
        var environment = NestedSessionMerge.Environment(grants: { await pins.nestedSessionGrants() + recents })
        #if LOUPPE_TEST_SEAMS
        let hooks = openingWorkerHooksForTesting
        environment.grantAccess = hooks.nestedSessionGrantAccess ?? .live
        environment.willReadSidecar = hooks.willReadNestedSession
        #endif
        return environment
    }

    var nestedSessionMergeNotice: String? {
        guard case .ready = phase, let summary = nestedSessionMergeSummary,
              summary.changedFiles > 0 else { return nil }
        return L10n.plural("Included %lld decisions from %lld earlier folder sessions.",
                           counts: [summary.changedFiles, summary.contributingSessions])
    }

    func dismissNestedSessionMergeNotice() {
        nestedSessionMergeSummary = nil
    }
}
