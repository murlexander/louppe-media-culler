import Darwin
import Foundation

// Darwin exposes both `struct flock` and `flock(2)` under the same C name;
// Swift imports the struct but cannot spell the function unambiguously.
@_silgen_name("flock")
private func louppeFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Small POSIX durability boundary shared by session persistence and file
/// transactions. Foundation's `.atomic` option protects readers from partial
/// JSON, but it does not express the required file-sync -> rename ->
/// directory-sync ordering for sudden power loss.
enum DurableFileIO {
    /// Stable destination selected by the user. Directory timestamps are not
    /// identity: ordinary file creation changes them during every export.
    struct DirectoryBinding: Equatable, Sendable {
        let url: URL
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int

        init(url: URL) throws {
            let descriptor = try openDescriptor(url,
                flags: O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW,
                operation: "open export folder")
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw POSIXError(.EIO)
            }
            self.url = url
            device = status.st_dev
            inode = status.st_ino
            birthSeconds = status.st_birthtimespec.tv_sec
            birthNanoseconds = status.st_birthtimespec.tv_nsec
        }

        fileprivate func matches(_ status: stat) -> Bool {
            status.st_mode & S_IFMT == S_IFDIR
                && status.st_dev == device && status.st_ino == inode
                && status.st_birthtimespec.tv_sec == birthSeconds
                && status.st_birthtimespec.tv_nsec == birthNanoseconds
        }

        func requireCurrentPath() throws {
            var status = stat()
            let result = url.withUnsafeFileSystemRepresentation {
                $0.map { lstat($0, &status) } ?? -1
            }
            guard result == 0, matches(status) else {
                throw DestinationChanged()
            }
        }
    }

    struct DestinationChanged: LocalizedError {
        var errorDescription: String? {
            L10n.text("The destination folder changed or disconnected. Choose the folder again and retry. Your originals are unchanged.")
        }
    }

    /// Keeps writes attached to the selected directory even if another process
    /// replaces a path component after our check. No polling or global lock.
    final class BoundDirectory: @unchecked Sendable {
        let binding: DirectoryBinding
        private let descriptor: Int32

        init(_ binding: DirectoryBinding) throws {
            self.binding = binding
            descriptor = try openDescriptor(binding.url,
                flags: O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW,
                operation: "open export folder")
            var status = stat()
            guard fstat(descriptor, &status) == 0, binding.matches(status) else {
                Darwin.close(descriptor)
                throw DestinationChanged()
            }
        }

        deinit { Darwin.close(descriptor) }

        private func withName<T>(_ url: URL, _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
            let path = try XMPExactFileSystemPath(url: url)
            guard path.parent.bytes == FileOperationJournal.exactPathBytes(for: binding.url) else {
                throw DestinationChanged()
            }
            let name = path.lastComponentBytes
            guard !name.contains(0), !name.contains(UInt8(ascii: "/")),
                  name != Data(".".utf8), name != Data("..".utf8) else {
                throw DestinationChanged()
            }
            return try (Array(name) + [0]).withUnsafeBytes {
                try body($0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        }

        private func create(_ url: URL) throws -> Int32 {
            try binding.requireCurrentPath()
            let fd = try withName(url) {
                openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return fd
        }

        func copy(from source: URL, to temporary: URL,
                  afterDestinationOpened: () -> Void = {}) throws {
            let sourceFD = try openDescriptor(source,
                flags: O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                operation: "open source for copy")
            defer { Darwin.close(sourceFD) }
            try requireDescriptorType(sourceFD, type: mode_t(S_IFREG),
                path: source.path, operation: "verify copy source")
            let targetFD = try create(temporary)
            defer { Darwin.close(targetFD) }
            afterDestinationOpened()
            // Apple's descriptor copy preserves file metadata and resource
            // forks while never resolving the destination path again.
            guard fcopyfile(sourceFD, targetFD, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try syncDescriptor(targetFD, path: temporary.path, fullSync: true)
            try binding.requireCurrentPath()
        }

        func write(_ data: Data, to temporary: URL) throws {
            let fd = try create(temporary)
            defer { Darwin.close(fd) }
            try writeAll(data, descriptor: fd, path: temporary.path)
            try syncDescriptor(fd, path: temporary.path, fullSync: true)
            try binding.requireCurrentPath()
        }

        func publish(from temporary: URL, to target: URL) throws {
            try binding.requireCurrentPath()
            let result = try withName(temporary) { sourceName in
                try withName(target) { targetName in
                    renameatx_np(descriptor, sourceName, descriptor, targetName, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try syncDescriptor(descriptor, path: binding.url.path, fullSync: true)
            try binding.requireCurrentPath()
        }

        /// XMP publication holds the original parent through temporary write,
        /// final source/packet validation, rename, cleanup, and directory flush.
        func atomicWrite(_ data: Data, to target: URL, exclusive: Bool,
                         validateBeforePublish: () throws -> Void) throws {
            let temporary = binding.url.appendingPathComponent(
                ".louppe-write-\(UUID().uuidString.lowercased()).tmp"
            )
            let fd = try create(temporary)
            defer { Darwin.close(fd) }
            var owned = stat()
            guard fstat(fd, &owned) == 0 else { throw POSIXError(.EIO) }
            var shouldRemoveTemporary = true
            defer {
                if shouldRemoveTemporary {
                    // Inspect and unlink through the held directory. A replaced
                    // pathname must never redirect cleanup into another folder.
                    _ = try? withName(temporary) { name in
                        var live = stat()
                        guard fstatat(descriptor, name, &live, AT_SYMLINK_NOFOLLOW) == 0,
                              live.st_mode & S_IFMT == S_IFREG,
                              live.st_dev == owned.st_dev, live.st_ino == owned.st_ino else { return }
                        _ = unlinkat(descriptor, name, 0)
                    }
                }
            }
            try writeAll(data, descriptor: fd, path: temporary.path)
            try syncDescriptor(fd, path: temporary.path, fullSync: true)
            var flushed = stat()
            guard fstat(fd, &flushed) == 0 else { throw POSIXError(.EIO) }
            try validateBeforePublish()
            try binding.requireCurrentPath()
            let result = try withName(temporary) { sourceName in
                var named = stat()
                guard fstatat(descriptor, sourceName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_mode & S_IFMT == S_IFREG,
                      named.st_dev == flushed.st_dev, named.st_ino == flushed.st_ino,
                      named.st_size == flushed.st_size,
                      named.st_birthtimespec.tv_sec == flushed.st_birthtimespec.tv_sec,
                      named.st_birthtimespec.tv_nsec == flushed.st_birthtimespec.tv_nsec,
                      named.st_mtimespec.tv_sec == flushed.st_mtimespec.tv_sec,
                      named.st_mtimespec.tv_nsec == flushed.st_mtimespec.tv_nsec,
                      named.st_ctimespec.tv_sec == flushed.st_ctimespec.tv_sec,
                      named.st_ctimespec.tv_nsec == flushed.st_ctimespec.tv_nsec else {
                    throw DestinationChanged()
                }
                return try withName(target) { targetName in
                    renameatx_np(descriptor, sourceName, descriptor, targetName,
                                 exclusive ? UInt32(RENAME_EXCL) : 0)
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            shouldRemoveTemporary = false
            try syncDescriptor(descriptor, path: binding.url.path, fullSync: true)
            try binding.requireCurrentPath()
        }

        /// Rename through held parent directories. A path component swapped
        /// after these descriptors were opened cannot redirect the move.
        func move(
            _ source: URL,
            to target: URL,
            in targetDirectory: BoundDirectory,
            strategy: NoOverwriteRenameStrategy
        ) throws {
            try binding.requireCurrentPath()
            try targetDirectory.binding.requireCurrentPath()
            switch strategy {
            case .exclusivePOSIX:
                let result = try withName(source) { sourceName in
                    try targetDirectory.withName(target) { targetName in
                        renameatx_np(
                            descriptor, sourceName,
                            targetDirectory.descriptor, targetName,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard result == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            case .foundation:
                // ExFAT lacks RENAME_EXCL. Its probed Foundation fallback is
                // still path-based, so refuse a known parent replacement.
                try DurableFileIO.renameWithoutOverwrite(
                    from: source, to: target, strategy: strategy
                )
            }
            // The caller records the side effect immediately after return.
            // A post-rename path check here would throw before it could know
            // that the source entry has already moved.
        }

        func syncRename(
            to targetDirectory: BoundDirectory,
            policy: DirectorySyncPolicy
        ) throws {
            // Durability order is destination, then source. Keep syncing the
            // held folders even if one of their pathnames was replaced.
            try targetDirectory.sync(policy: policy)
            if targetDirectory.binding != binding {
                try sync(policy: policy)
            }
        }

        private func sync(policy: DirectorySyncPolicy) throws {
            do {
                try DurableFileIO.syncDescriptor(
                    descriptor, path: binding.url.path, fullSync: true
                )
            } catch {
                guard DurableFileIO.shouldIgnoreUnsupportedDirectorySync(
                    error, policy: policy
                ) else { throw error }
            }
        }
    }


    /// Some removable filesystems implement atomic renames but reject fsync
    /// on directory descriptors. Source Organization may opt into the weaker
    /// boundary only after identifying that exact filesystem and warning the
    /// photographer. Every other file operation remains strict by default.
    enum DirectorySyncPolicy: Equatable, Sendable {
        case required
        case allowUnsupported
    }

    enum NoOverwriteRenameStrategy: Equatable, Sendable {
        case exclusivePOSIX
        case foundation
    }

    enum IOError: LocalizedError {
        case system(operation: String, path: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .system(let operation, let path, let code):
                let message = String(cString: strerror(code))
                return L10n.text("\(operation) failed for \(path) (\(code): \(message)).")
            }
        }
    }

    /// Serializes a filesystem transaction across every Louppe process that
    /// uses the same lock-file path. The descriptor stays open for the entire
    /// body, so process exit also releases the advisory lock automatically.
    ///
    /// Keep the lock file outside the photographer's folder: a read-only card
    /// must still be able to serialize a fallback save in Application Support.
    static func withExclusiveFileLock<Result>(
        at lockFile: URL,
        timeout: TimeInterval = 2,
        beforeLock: () -> Void = {},
        perform body: () throws -> Result
    ) throws -> Result {
        let parent = lockFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let descriptor = try openLockFile(lockFile)
        defer { Darwin.close(descriptor) }
        try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFREG),
            path: lockFile.path,
            operation: "verify persistence lock"
        )

        // This hook exists solely so the two-persistence-instance durability
        // test can prove that its second writer reached the actual lock wait.
        beforeLock()
        // Never let a stale or wedged second Louppe process freeze saving,
        // folder changes, or Quit forever. The transaction remains exclusive,
        // but a contended caller gets a normal retryable save failure after a
        // short bounded wait.
        let boundedTimeout: TimeInterval
        if timeout.isFinite {
            boundedTimeout = min(max(0, timeout), 60)
        } else {
            boundedTimeout = 2
        }
        let timeoutNanoseconds = UInt64(
            boundedTimeout * 1_000_000_000
        )
        let deadline = DispatchTime.now().uptimeNanoseconds
            + timeoutNanoseconds
        while true {
            if louppeFlock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                break
            }
            let failure = errno
            guard failure == EINTR
                    || failure == EWOULDBLOCK
                    || failure == EAGAIN else {
                throw IOError.system(
                    operation: "acquire persistence lock",
                    path: lockFile.path,
                    code: failure
                )
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw IOError.system(
                    operation: "wait for persistence lock",
                    path: lockFile.path,
                    code: EWOULDBLOCK
                )
            }
            if failure == EINTR {
                continue
            }
            let remainingMicroseconds = (deadline - now) / 1_000
            usleep(useconds_t(max(1, min(25_000, remainingMicroseconds))))
        }
        defer {
            while louppeFlock(descriptor, LOCK_UN) != 0 && errno == EINTR {}
        }
        return try body()
    }

    /// Writes a new file in the destination directory, flushes its contents,
    /// atomically replaces the destination, then flushes the directory entry.
    /// `fullSync` additionally asks macOS to push device write caches before
    /// returning; use it for commit records and photographer-visible state.
    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        fullSync: Bool,
        validateBeforeReplace: () throws -> Void = {},
        afterReplaceForTesting: () throws -> Void = {}
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".louppe-write-\(UUID().uuidString.lowercased()).tmp"
        )
        var shouldRemoveTemporary = false
        defer {
            if shouldRemoveTemporary {
                try? unlinkRegularFile(at: temporary)
            }
        }

        let descriptor = try openFileForCreation(temporary)
        shouldRemoveTemporary = true
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        do {
            try writeAll(data, descriptor: descriptor, path: temporary.path)
            try syncDescriptor(
                descriptor,
                path: temporary.path,
                fullSync: fullSync
            )
            let closeResult = Darwin.close(descriptor)
            let closeFailure = errno
            closeNeeded = false
            guard closeResult == 0 else {
                throw IOError.system(
                    operation: "close",
                    path: temporary.path,
                    code: closeFailure
                )
            }
        } catch {
            throw error
        }

        // Run compare-and-swap guards only after the potentially slow write
        // and hardware flush. This narrows an external-edit race to the final
        // validation/rename syscall boundary while still leaving the existing
        // destination untouched when validation fails.
        try validateBeforeReplace()
        try replaceByRename(from: temporary, to: destination)
        shouldRemoveTemporary = false
        // Deterministic tests use this boundary to model an error after rename
        // committed but before the parent-directory sync returned.
        try afterReplaceForTesting()
        try syncDirectory(parent, fullSync: fullSync)
    }

    /// Publishes a brand-new file without ever replacing an entry that appears
    /// after preflight. XMP sidecar creation uses this instead of
    /// `atomicWrite`, because a concurrent application may create the packet
    /// between planning and the final rename.
    static func atomicCreate(
        _ data: Data,
        at destination: URL,
        fullSync: Bool,
        validateBeforePublish: () throws -> Void = {}
    ) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".louppe-write-\(UUID().uuidString.lowercased()).tmp"
        )
        var shouldRemoveTemporary = false
        defer {
            if shouldRemoveTemporary {
                try? unlinkRegularFile(at: temporary)
            }
        }

        let descriptor = try openFileForCreation(temporary)
        shouldRemoveTemporary = true
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        try writeAll(data, descriptor: descriptor, path: temporary.path)
        try syncDescriptor(
            descriptor,
            path: temporary.path,
            fullSync: fullSync
        )
        let closeResult = Darwin.close(descriptor)
        let closeFailure = errno
        closeNeeded = false
        guard closeResult == 0 else {
            throw IOError.system(
                operation: "close",
                path: temporary.path,
                code: closeFailure
            )
        }

        try validateBeforePublish()
        try atomicExclusiveRename(from: temporary, to: destination)
        shouldRemoveTemporary = false
        try syncDirectory(parent, fullSync: fullSync)
    }

    /// Writes a brand-new operation-owned file at one exact, preplanned path.
    /// Unlike `atomicCreate`, this intentionally has no second hidden
    /// temporary: the file-operation journal already reserves `destination`
    /// and must be able to account for every artifact after a crash. If a
    /// write fails, the partial is left in place so its inode can be recorded
    /// and reconciled rather than guessed away by pathname.
    static func writeNewFile(
        _ data: Data,
        to destination: URL,
        fullSync: Bool,
        directorySyncPolicy: DirectorySyncPolicy = .required
    ) throws {
        let descriptor = try openFileForCreation(destination)
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        try writeAll(data, descriptor: descriptor, path: destination.path)
        try syncDescriptor(
            descriptor,
            path: destination.path,
            fullSync: fullSync
        )
        let closeResult = Darwin.close(descriptor)
        let closeFailure = errno
        closeNeeded = false
        guard closeResult == 0 else {
            throw IOError.system(
                operation: "close",
                path: destination.path,
                code: closeFailure
            )
        }
        try syncDirectory(
            destination.deletingLastPathComponent(),
            fullSync: fullSync,
            policy: directorySyncPolicy
        )
    }

    /// Capability probes are disposable and deliberately do not claim power-
    /// loss durability. They exist only to prove the volume's rename behavior
    /// before any photographer-owned file is touched.
    static func writeCapabilityProbeFile(
        _ data: Data,
        to destination: URL
    ) throws {
        let descriptor = try openFileForCreation(destination)
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        try writeAll(data, descriptor: descriptor, path: destination.path)
        let closeResult = Darwin.close(descriptor)
        let closeFailure = errno
        closeNeeded = false
        guard closeResult == 0 else {
            throw IOError.system(
                operation: "close capability probe",
                path: destination.path,
                code: closeFailure
            )
        }
    }

    static func syncFile(at url: URL, fullSync: Bool) throws {
        let descriptor = try openDescriptor(
            url,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            operation: "open file for sync"
        )
        defer { Darwin.close(descriptor) }
        try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFREG),
            path: url.path,
            operation: "verify regular file"
        )
        try syncDescriptor(
            descriptor,
            path: url.path,
            fullSync: fullSync
        )
    }

    @discardableResult
    static func syncDirectory(
        _ url: URL,
        fullSync: Bool = false,
        policy: DirectorySyncPolicy = .required
    ) throws -> Bool {
        let descriptor = try openDescriptor(
            url,
            flags: O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW,
            operation: "open directory for sync"
        )
        defer { Darwin.close(descriptor) }
        try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFDIR),
            path: url.path,
            operation: "verify directory"
        )
        do {
            try syncDescriptor(
                descriptor,
                path: url.path,
                fullSync: fullSync
            )
            return true
        } catch {
            guard shouldIgnoreUnsupportedDirectorySync(
                error,
                policy: policy
            ) else { throw error }
            return false
        }
    }

    /// Persists both directory-entry changes made by a successful rename.
    /// Call this immediately after the rename syscall and before checkpointing
    /// the new journal state.
    @discardableResult
    static func syncRenameDirectories(
        from source: URL,
        to destination: URL,
        fullSync: Bool = false,
        policy: DirectorySyncPolicy = .required
    ) throws -> Bool {
        let sourceParent = source.deletingLastPathComponent()
        let destinationParent = destination.deletingLastPathComponent()
        if destinationParent.path(percentEncoded: true)
            == sourceParent.path(percentEncoded: true) {
            return try syncDirectory(
                destinationParent,
                fullSync: fullSync,
                policy: policy
            )
        } else {
            // Make the new name durable before the old name's removal. If
            // sudden power loss lands between these flushes, two names are a
            // recoverable ambiguity; zero names could lose the only path to an
            // original photograph.
            let destinationSynced = try syncDirectory(
                destinationParent,
                fullSync: fullSync,
                policy: policy
            )
            let sourceSynced = try syncDirectory(
                sourceParent,
                fullSync: fullSync,
                policy: policy
            )
            return destinationSynced && sourceSynced
        }
    }

    @discardableResult
    static func syncRemoval(
        of url: URL,
        fullSync: Bool = false,
        policy: DirectorySyncPolicy = .required
    ) throws -> Bool {
        try syncDirectory(
            url.deletingLastPathComponent(),
            fullSync: fullSync,
            policy: policy
        )
    }

    static func shouldIgnoreUnsupportedDirectorySync(
        _ error: Error,
        policy: DirectorySyncPolicy
    ) -> Bool {
        guard policy == .allowUnsupported else { return false }
        let unsupportedCodes = [Int(EINVAL), Int(ENOTSUP), Int(ENOTTY)]
        if case IOError.system(_, _, let code) = error {
            return unsupportedCodes.contains(Int(code))
        }
        let cocoa = error as NSError
        return cocoa.domain == NSPOSIXErrorDomain
            && unsupportedCodes.contains(cocoa.code)
    }

    /// Exclusive, same-volume rename syscall. Directory syncing stays
    /// separate so callers can record that the side effect happened even if a
    /// later flush fails.
    static func atomicExclusiveRename(from source: URL, to destination: URL) throws {
        var failure: Int32 = 0
        let result: Int32 = source.withUnsafeFileSystemRepresentation {
            sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                guard let sourcePath, let destinationPath else {
                    failure = EINVAL
                    return Int32(-1)
                }
                var status: Int32
                repeat {
                    status = Darwin.renamex_np(
                        sourcePath,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                } while status != 0 && errno == EINTR
                if status != 0 { failure = errno }
                return status
            }
        }
        guard result == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: failure) ?? .EIO
            )
        }
    }

    /// Moves one same-volume entry without replacing an existing destination.
    /// APFS and other capable filesystems use the race-free POSIX primitive.
    /// ExFAT uses Foundation's documented no-overwrite move contract after a
    /// disposable probe has proved that it is an inode-preserving rename on
    /// the exact mounted volume.
    static func renameWithoutOverwrite(
        from source: URL,
        to destination: URL,
        strategy: NoOverwriteRenameStrategy
    ) throws {
        switch strategy {
        case .exclusivePOSIX:
            try atomicExclusiveRename(from: source, to: destination)
        case .foundation:
            let sourceDevice = try deviceNumber(
                at: source,
                expectedType: mode_t(S_IFREG)
            )
            let destinationDevice = try deviceNumber(
                at: destination.deletingLastPathComponent(),
                expectedType: mode_t(S_IFDIR)
            )
            guard sourceDevice == destinationDevice else {
                throw IOError.system(
                    operation: "verify same-volume move",
                    path: destination.path,
                    code: EXDEV
                )
            }
            try FileManager().moveItem(at: source, to: destination)
        }
    }

    /// Reads a bounded regular file without following a leaf symlink. Journal
    /// recovery uses this instead of `Data(contentsOf:)` so a malformed entry
    /// cannot redirect the reader or allocate unbounded memory at launch.
    static func readRegularFile(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw IOError.system(
                operation: "validate read limit",
                path: url.path,
                code: EINVAL
            )
        }
        let descriptor = try openDescriptor(
            url,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            operation: "open regular file for read"
        )
        defer { Darwin.close(descriptor) }
        let info = try requireDescriptorType(
            descriptor,
            type: mode_t(S_IFREG),
            path: url.path,
            operation: "verify regular file"
        )
        guard info.st_size >= 0,
              info.st_size <= Int64(maximumBytes) else {
            throw IOError.system(
                operation: "bound regular-file read",
                path: url.path,
                code: EFBIG
            )
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if result == 0 { return data }
            if result < 0 {
                if errno == EINTR { continue }
                throw IOError.system(
                    operation: "read",
                    path: url.path,
                    code: errno
                )
            }
            let count = Int(result)
            guard count <= maximumBytes - data.count else {
                throw IOError.system(
                    operation: "bound regular-file read",
                    path: url.path,
                    code: EFBIG
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// Removes exactly one regular-file directory entry. Unlike
    /// `FileManager.removeItem`, this can never recurse through a directory if
    /// a recovery candidate is swapped after it was first inspected.
    static func unlinkRegularFile(at url: URL) throws {
        var info = Darwin.stat()
        var status: Int32 = -1
        var failure: Int32 = 0
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return
            }
            repeat {
                status = Darwin.lstat(path, &info)
            } while status != 0 && errno == EINTR
            if status != 0 {
                failure = errno
                return
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                failure = EFTYPE
                status = -1
                return
            }
            repeat {
                status = Darwin.unlink(path)
            } while status != 0 && errno == EINTR
            if status != 0 { failure = errno }
        }
        guard status == 0 else {
            throw IOError.system(
                operation: "unlink regular file",
                path: url.path,
                code: failure
            )
        }
    }

    private static func openFileForCreation(_ url: URL) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            } while value < 0 && errno == EINTR
            if value < 0 { failure = errno }
            return value
        }
        guard descriptor >= 0 else {
            throw IOError.system(
                operation: "create temporary file",
                path: url.path,
                code: failure
            )
        }
        return descriptor
    }

    private static func deviceNumber(
        at url: URL,
        expectedType: mode_t
    ) throws -> dev_t {
        var info = Darwin.stat()
        var failure: Int32 = 0
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.lstat(path, &info)
            } while value != 0 && errno == EINTR
            if value != 0 { failure = errno }
            return value
        }
        guard result == 0 else {
            throw IOError.system(
                operation: "inspect move volume",
                path: url.path,
                code: failure
            )
        }
        guard info.st_mode & mode_t(S_IFMT) == expectedType else {
            throw IOError.system(
                operation: "verify move entry type",
                path: url.path,
                code: EFTYPE
            )
        }
        return info.st_dev
    }

    private static func openLockFile(_ url: URL) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.open(
                    path,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            } while value < 0 && errno == EINTR
            if value < 0 { failure = errno }
            return value
        }
        guard descriptor >= 0 else {
            throw IOError.system(
                operation: "open persistence lock",
                path: url.path,
                code: failure
            )
        }
        return descriptor
    }

    private static func openDescriptor(
        _ url: URL,
        flags: Int32,
        operation: String
    ) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                failure = EINVAL
                return Int32(-1)
            }
            var value: Int32
            repeat {
                value = Darwin.open(path, flags)
            } while value < 0 && errno == EINTR
            if value < 0 { failure = errno }
            return value
        }
        guard descriptor >= 0 else {
            throw IOError.system(
                operation: operation,
                path: url.path,
                code: failure
            )
        }
        return descriptor
    }

    @discardableResult
    private static func requireDescriptorType(
        _ descriptor: Int32,
        type: mode_t,
        path: String,
        operation: String
    ) throws -> Darwin.stat {
        var info = Darwin.stat()
        var result: Int32
        repeat {
            result = Darwin.fstat(descriptor, &info)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw IOError.system(
                operation: operation,
                path: path,
                code: errno
            )
        }
        guard info.st_mode & mode_t(S_IFMT) == type else {
            throw IOError.system(
                operation: operation,
                path: path,
                code: EFTYPE
            )
        }
        return info
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    let code = result == 0 ? EIO : errno
                    throw IOError.system(
                        operation: "write",
                        path: path,
                        code: code
                    )
                }
            }
        }
    }

    private static func syncDescriptor(
        _ descriptor: Int32,
        path: String,
        fullSync: Bool
    ) throws {
        if fullSync {
            var result: Int32
            repeat {
                result = Darwin.fcntl(descriptor, F_FULLFSYNC)
            } while result != 0 && errno == EINTR
            if result == 0 { return }
            let code = errno
            // Some filesystems and directory descriptors do not implement
            // F_FULLFSYNC. `fsync` is still the strongest available contract.
            if code != EINVAL && code != ENOTSUP && code != ENOTTY {
                throw IOError.system(
                    operation: "full sync",
                    path: path,
                    code: code
                )
            }
        }
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw IOError.system(
                operation: "sync",
                path: path,
                code: errno
            )
        }
    }

    private static func replaceByRename(from source: URL, to destination: URL) throws {
        var failure: Int32 = 0
        let result: Int32 = source.withUnsafeFileSystemRepresentation {
            sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                guard let sourcePath, let destinationPath else {
                    failure = EINVAL
                    return Int32(-1)
                }
                var status: Int32
                repeat {
                    status = Darwin.rename(sourcePath, destinationPath)
                } while status != 0 && errno == EINTR
                if status != 0 { failure = errno }
                return status
            }
        }
        guard result == 0 else {
            throw IOError.system(
                operation: "atomic replace",
                path: destination.path,
                code: failure
            )
        }
    }
}
