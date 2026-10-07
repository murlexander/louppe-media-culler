import Darwin
import Foundation

// Darwin imports `struct statfs` under the same Swift name as statfs(2), so
// spell the C function explicitly while retaining exact filesystem paths.
@_silgen_name("statfs")
private func louppeStatFS(
    _ path: UnsafePointer<CChar>,
    _ information: UnsafeMutablePointer<Darwin.statfs>
) -> Int32

/// Read-only export preflight. It rejects destinations that would make copied
/// or moved media reappear inside the active session, and catches basic
/// permission/capacity problems before a long filesystem operation starts.
enum ExportDestinationValidator {
    enum ValidationError: LocalizedError, Equatable {
        case missingSourceFolder
        case sourceFolder
        case insideSourceFolder
        case crossVolumeMove
        case notDirectory
        case notWritable
        case duplicateMultiDestination
        case collisionSafePublicationUnavailable
        case insufficientSpace(required: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .missingSourceFolder:
                return L10n.text("The source folder is no longer open.")
            case .sourceFolder:
                return L10n.text("Choose a destination outside the folder you are reviewing.")
            case .insideSourceFolder:
                return L10n.text("Choose a destination outside the reviewed folder. Copies in its subfolders would reappear in this session.")
            case .crossVolumeMove:
                return L10n.text("Move requires the same storage volume. Use Copy for another drive or card to protect originals during interruption.")
            case .notDirectory:
                return L10n.text("The selected destination is not a folder.")
            case .notWritable:
                return L10n.text("Louppe does not have permission to write to that destination.")
            case .duplicateMultiDestination:
                return L10n.text("Each route needs a separate destination folder.")
            case .collisionSafePublicationUnavailable:
                return L10n.text("This destination cannot safely prevent export collisions. Choose an APFS folder on your Mac or another supported drive.")
            case .insufficientSpace(let required, let available):
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let requiredText = formatter.string(fromByteCount: required)
                let availableText = formatter.string(fromByteCount: available)
                return L10n.text("Not enough destination space: \(requiredText) required, \(availableText) available.")
            }
        }
    }

    /// One independently selected destination in the copy-only routing flow.
    /// Route IDs preserve the UI's explicit mapping while this validator
    /// resolves aliases and returns the exact directory the worker must use.
    struct MultiDestinationRequest: Sendable {
        let routeID: UUID
        let destination: URL
        let items: [PhotoItem]
    }

    struct ValidatedDestination: Sendable {
        let url: URL
        let binding: DurableFileIO.DirectoryBinding
    }

    @discardableResult
    static func validate(
        sourceFolder: URL?, destination: URL, items: [PhotoItem], mode: ExportMode
    ) throws -> URL {
        try validateBound(sourceFolder: sourceFolder, destination: destination,
            items: items, mode: mode).url
    }

    @discardableResult
    static func validateBound(
        sourceFolder: URL?,
        destination: URL,
        items: [PhotoItem],
        mode: ExportMode
    ) throws -> ValidatedDestination {
        guard let sourceFolder else {
            throw ValidationError.missingSourceFolder
        }

        guard let resolvedSource = try? FileOperationJournal
            .resolvingSymlinksExactly(sourceFolder),
              let sourcePath = FileOperationJournal.exactPathBytes(
                for: resolvedSource
              ) else {
            throw ValidationError.missingSourceFolder
        }
        // Freeze the symlink-resolved directory selected during preflight.
        // Workers receive this exact path, so retargeting the original alias
        // after the dialog closes cannot redirect an export into the source
        // tree or onto a different volume.
        guard let validatedDestination = try? FileOperationJournal
            .resolvingSymlinksExactly(destination),
              let destinationPath = FileOperationJournal.exactPathBytes(
                for: validatedDestination
              ) else {
            throw ValidationError.notDirectory
        }
        let binding = try DurableFileIO.DirectoryBinding(url: validatedDestination)
        if destinationPath == sourcePath
            || directoriesReferToSameEntry(
                resolvedSource,
                validatedDestination
            ) {
            throw ValidationError.sourceFolder
        }
        var sourcePrefix = sourcePath
        if sourcePrefix.count > 1 {
            sourcePrefix.append(UInt8(ascii: "/"))
        }
        if destinationPath.starts(with: sourcePrefix) {
            throw ValidationError.insideSourceFolder
        }

        let values = try? validatedDestination.resourceValues(forKeys: [
            .isDirectoryKey,
            .volumeIdentifierKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard values?.isDirectory == true else {
            throw ValidationError.notDirectory
        }
        guard isWritableDirectory(validatedDestination) else {
            throw ValidationError.notWritable
        }

        let required = items.reduce(Int64(0)) { partial, item in
            let (sum, overflowed) = partial.addingReportingOverflow(item.totalFileSize)
            return overflowed ? Int64.max : sum
        }
        let canRenameWithinVolume = mode == .move
            && moveCanUseAtomicRename(
                items: items,
                destinationVolumeIdentifier:
                    values?.volumeIdentifier as? AnyHashable
            )
        if mode == .move, !canRenameWithinVolume {
            throw ValidationError.crossVolumeMove
        }
        let importantUsageCapacity: Int64? =
            values?.volumeAvailableCapacityForImportantUsage
        let availableCapacity = effectiveAvailableCapacity(
            importantUsage: importantUsageCapacity,
            fileSystem: fileSystemAvailableCapacity(at: validatedDestination)
        )
        if !canRenameWithinVolume,
           required > 0,
           let available = availableCapacity,
           available < required {
            throw ValidationError.insufficientSpace(
                required: required,
                available: available
            )
        }
        try requireCollisionSafePublication(at: binding)
        return ValidatedDestination(url: validatedDestination, binding: binding)
    }

    /// Copy and Export Move publish with RENAME_EXCL. Ask the selected
    /// folder's held volume for that capability before a journal or temporary
    /// media file exists. ExFAT advertises it as unsupported; unknown capability
    /// retains the existing syscall check instead of rejecting whole formats.
    static func requireCollisionSafePublication(
        at binding: DurableFileIO.DirectoryBinding
    ) throws {
        try binding.requireCurrentPath()
        let descriptor = binding.url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_dev == binding.device,
              status.st_ino == binding.inode,
              status.st_birthtimespec.tv_sec == binding.birthSeconds,
              status.st_birthtimespec.tv_nsec == binding.birthNanoseconds else {
            throw DurableFileIO.DestinationChanged()
        }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES)
        // getattrlist's length word followed by vol_capabilities_attr_t:
        // four capability words, then four validity-mask words (all UInt32).
        var words = [UInt32](repeating: 0, count: 9)
        let result = words.withUnsafeMutableBytes { buffer in
            Darwin.fgetattrlist(descriptor, &attributes, buffer.baseAddress!, buffer.count, 0)
        }
        let interfaceIndex = Int(VOL_CAPABILITIES_INTERFACES)
        let unsupported = result == 0
            && words[0] >= UInt32(words.count * MemoryLayout<UInt32>.size)
            && exclusiveRenameIsUnsupported(
                capabilities: words[1 + interfaceIndex],
                valid: words[5 + interfaceIndex]
            )
        try binding.requireCurrentPath()
        if unsupported {
            throw ValidationError.collisionSafePublicationUnavailable
        }
    }

    static func exclusiveRenameIsUnsupported(
        capabilities: UInt32,
        valid: UInt32
    ) -> Bool {
        let exclusiveRename = UInt32(VOL_CAP_INT_RENAME_EXCL)
        return valid & exclusiveRename != 0 && capabilities & exclusiveRename == 0
    }

    /// Validates every route before a multi-destination journal can be
    /// planned. Each route carries its own capacity requirement, and two
    /// aliases to the same folder are refused: allowing them would make two
    /// visible routes share a collision namespace.
    static func validateMultiple(
        sourceFolder: URL?,
        requests: [MultiDestinationRequest]
    ) throws -> [ValidatedDestination] {
        var validated: [ValidatedDestination] = []
        validated.reserveCapacity(requests.count)
        for request in requests {
            let destination = try validateBound(
                sourceFolder: sourceFolder,
                destination: request.destination,
                items: request.items,
                mode: .copy
            )
            if validated.contains(where: {
                FileOperationJournal.exactPathsEqual($0.url, destination.url)
                    || directoriesReferToSameEntry($0.url, destination.url)
            }) {
                throw ValidationError.duplicateMultiDestination
            }
            validated.append(destination)
        }
        try validateCombinedCopyCapacity(
            requests: requests,
            destinations: validated.map(\.url)
        )
        return validated
    }

    /// Routes can deliberately target different directories on the same
    /// storage volume. Per-route checks alone would let two individually
    /// affordable copies collectively overfill that volume, so the routing
    /// preflight also reserves their combined media size wherever macOS can
    /// identify the destination volume and report usable capacity.
    private static func validateCombinedCopyCapacity(
        requests: [MultiDestinationRequest],
        destinations: [URL]
    ) throws {
        var requiredByVolume: [AnyHashable: Int64] = [:]
        var sampleDestinationByVolume: [AnyHashable: URL] = [:]
        for (request, destination) in zip(requests, destinations) {
            guard let volume = volumeIdentifier(at: destination) else { continue }
            let required = requiredCapacity(for: request.items)
            let current = requiredByVolume[volume, default: 0]
            requiredByVolume[volume] = combinedRequiredCapacity([current, required])
            sampleDestinationByVolume[volume] = destination
        }
        for (volume, required) in requiredByVolume {
            guard required > 0,
                  let destination = sampleDestinationByVolume[volume]
            else { continue }
            let values = try? destination.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
            ])
            let available = effectiveAvailableCapacity(
                importantUsage: values?.volumeAvailableCapacityForImportantUsage,
                fileSystem: fileSystemAvailableCapacity(at: destination)
            )
            if let available, available < required {
                throw ValidationError.insufficientSpace(
                    required: required,
                    available: available
                )
            }
        }
    }

    private static func requiredCapacity(for items: [PhotoItem]) -> Int64 {
        items.reduce(Int64(0)) { partial, item in
            let (sum, overflowed) = partial.addingReportingOverflow(item.totalFileSize)
            return overflowed ? Int64.max : sum
        }
    }

    /// Kept separate from filesystem probing so multi-route capacity arithmetic
    /// stays deterministic and covers overflow without ever wrapping smaller.
    static func combinedRequiredCapacity(_ requirements: [Int64]) -> Int64 {
        requirements.reduce(Int64(0)) { partial, next in
            let (sum, overflowed) = partial.addingReportingOverflow(next)
            return overflowed ? Int64.max : sum
        }
    }

    /// `volumeAvailableCapacityForImportantUsage` can transiently report zero
    /// for File Provider-managed folders even while the underlying volume has
    /// ample space. A positive value is authoritative; zero is cross-checked
    /// against statfs. If neither API can provide a usable answer, Copy is
    /// allowed to proceed and the filesystem remains the final authority.
    static func effectiveAvailableCapacity(
        importantUsage: Int64?,
        fileSystem: Int64?
    ) -> Int64? {
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        if let fileSystem, fileSystem >= 0 {
            return fileSystem
        }
        return nil
    }

    private static func fileSystemAvailableCapacity(at url: URL) -> Int64? {
        var information = Darwin.statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return louppeStatFS(path, &information)
        }
        guard result == 0 else { return nil }
        let (bytes, overflowed) = UInt64(information.f_bavail)
            .multipliedReportingOverflow(by: UInt64(information.f_bsize))
        return overflowed ? Int64.max : Int64(clamping: bytes)
    }

    static func directoriesReferToSameEntry(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = directoryIdentity(at: lhs),
              let right = directoryIdentity(at: rhs) else {
            return false
        }
        return left.device == right.device && left.inode == right.inode
    }

    private static func directoryIdentity(
        at url: URL
    ) -> (device: UInt64, inode: UInt64)? {
        var info = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.fstatat(AT_FDCWD, path, &info, 0)
        }
        guard result == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return nil
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return Darwin.access(path, W_OK) == 0
        }
    }

    /// Move currently relies on inode-preserving renames. Unknown or mixed
    /// volume identity fails closed; Copy can cross volumes.
    static func moveCanUseAtomicRename(
        items: [PhotoItem],
        destination: URL
    ) -> Bool {
        return moveCanUseAtomicRename(
            items: items,
            destinationVolumeIdentifier: volumeIdentifier(at: destination)
        )
    }

    static func volumeIdentifiersAllowAtomicMove(
        source: [AnyHashable?],
        destination: AnyHashable?
    ) -> Bool {
        guard !source.isEmpty, let destination else { return false }
        return source.allSatisfy { $0 == destination }
    }

    private static func moveCanUseAtomicRename(
        items: [PhotoItem],
        destinationVolumeIdentifier: AnyHashable?
    ) -> Bool {
        let sourceIdentifiers = items
            .flatMap(\.allURLs)
            .map { volumeIdentifier(at: $0) }
        return volumeIdentifiersAllowAtomicMove(
            source: sourceIdentifiers,
            destination: destinationVolumeIdentifier
        )
    }

    private static func volumeIdentifier(at url: URL) -> AnyHashable? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ),
        let identifier = values.volumeIdentifier else {
            return nil
        }
        return identifier as? AnyHashable
    }
}
