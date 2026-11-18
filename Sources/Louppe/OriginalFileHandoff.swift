import AppKit
import Darwin

/// Which originals drag-out and Open With act on. Both share one resolver so
/// the dragged files and the files an editor receives can never differ.
enum OriginalFilesOrigin: Equatable {
    /// File menu and Command Palette: the effective selection, which is the
    /// visible current item when nothing is explicitly selected.
    case selection
    /// A Grid/Browser tile or the Gallery photo. A grabbed item inside the
    /// effective selection carries the whole selection; otherwise only itself.
    /// The revision rejects a reused cell or a menu built for replaced content.
    case item(index: Int, revision: PhotoContentRevision)
}

/// One physical original. A RAW+JPEG pair contributes two of these.
struct OriginalFileTarget: Equatable, Sendable {
    let fileID: String
    let url: URL
    let itemIndex: Int
    /// The scan's physical identity (device, inode, size and timestamps).
    var identity: FileOperationJournal.FileIdentity? = nil

    /// Still the reviewed file: a regular file at the scanned path on the
    /// same volume with the same inode, size, content-modification and birth
    /// times. A same-name replacement counts as missing. The inode change
    /// time is ignored, as in Clean Up's checks: extended attributes macOS
    /// writes on open (`com.apple.lastuseddate#PS`, `com.apple.macl`) and
    /// permission changes bump it without changing the file.
    /// One `lstat` per file serves both the type check and the identity.
    func isCurrentOriginal(volumes: FileOperationJournal.VolumeLookup = .init()) -> Bool {
        guard let status = OriginalFileTargets.regularFileStatus(at: url) else { return false }
        guard let identity else { return true } // Synthetic/legacy items.
        let actual: FileOperationJournal.FileIdentity
        if let volume = volumes.volume(device: status.st_dev, containing: url) {
            actual = FileOperationJournal.identity(from: status, volumeRootPath: volume.rootPath,
                                                   volumeUUIDString: volume.uuid)
        } else {
            // Same fallback as `captureIdentity(at:volumes:)`.
            guard let captured = try? FileOperationJournal.captureIdentity(at: url) else { return false }
            actual = captured
        }
        return FileOperationJournal.identitiesMatch(expected: identity, actual: actual, includeStatusChange: false)
    }
}

/// Cancels one existence sweep from any thread.
final class OriginalFileSweepCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Session-resolved originals in visible order, primary before companion.
/// Resolution reads no files; `existing()` filters off-main before handoff.
struct OriginalFileTargets: Equatable, Sendable {
    let files: [OriginalFileTarget]
    /// The grabbed (or current) item's first file inside `files`.
    let leaderFileIndex: Int

    var urls: [URL] { files.map(\.url) }

    /// Lanes for the per-file check; slow or network volumes overlap their
    /// metadata round trips without an unbounded thread fan-out.
    static let checkConcurrency = 8

    /// Only the reviewed originals still at their scanned paths with their
    /// scanned identity. Missing, offline or replaced files are left out,
    /// never substituted. Checks run on at most `checkConcurrency` lanes; a
    /// cancelled sweep stops at the next file and resolves nothing.
    func existing(isCancelled: @Sendable () -> Bool = { false },
                  isPresent: (@Sendable (OriginalFileTarget) -> Bool)? = nil)
        -> OriginalFileTargets? {
        // One volume lookup per device for the whole sweep.
        let volumes = FileOperationJournal.VolumeLookup()
        let flags = presence(isCancelled: isCancelled,
                             isPresent: isPresent ?? { $0.isCurrentOriginal(volumes: volumes) })
        guard let flags else { return nil }
        let present = files.indices.filter { flags[$0] }.map { files[$0] }
        guard !present.isEmpty else { return nil }
        let leaderID = files.indices.contains(leaderFileIndex) ? files[leaderFileIndex].fileID : nil
        let leader = present.firstIndex { $0.fileID == leaderID } ?? 0
        return OriginalFileTargets(files: present, leaderFileIndex: leader)
    }

    /// One flag per file, or nil when cancelled.
    func presence(isCancelled: @Sendable () -> Bool,
                  isPresent: @Sendable (OriginalFileTarget) -> Bool) -> [Bool]? {
        guard !files.isEmpty else { return [] }
        let lanes = min(Self.checkConcurrency, files.count)
        var flags = [Bool](repeating: false, count: files.count)
        let cancelled = OriginalFileSweepCancellation()
        flags.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let output = buffer
            let files = self.files
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                // Interleaved lanes; each index is written by exactly one lane.
                var index = lane
                while index < files.count {
                    if cancelled.isCancelled || isCancelled() { cancelled.cancel(); return }
                    output[index] = isPresent(files[index])
                    index += lanes
                }
            }
        }
        return cancelled.isCancelled ? nil : flags
    }

    #if LOUPPE_TEST_SEAMS
    /// Counts `lstat` calls made by the existence checks.
    nonisolated(unsafe) static var statCallsForTesting: Int = 0
    private static let statCounterLock = NSLock()
    #endif

    /// The `lstat` of a regular file at the URL's exact filesystem path, or
    /// nil for a missing file, a symlink or any other file type.
    static func regularFileStatus(at url: URL) -> Darwin.stat? {
        #if LOUPPE_TEST_SEAMS
        statCounterLock.withLock { statCallsForTesting += 1 }
        #endif
        var status = Darwin.stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return status
    }

}

extension SessionStore {
    /// In-memory availability for drag-out and Open With. Apple Photos
    /// sources are excluded: their synthetic URLs are cache keys, not files.
    /// This performs no I/O, so menus and tiles may evaluate it freely.
    var canHandOffOriginals: Bool {
        guard case .ready = phase else { return false }
        return photosBatch == nil
            && !items.isEmpty
            && !isFileOperationRunning
            && !isLegacySessionMigrationConfirmationPresented
    }

    /// Constant-time menu enablement: `origin` names at least one visible
    /// local item. Tiles evaluate this per redraw, so it never expands the
    /// selection or touches the filesystem; actions check existence later.
    func canHandOffOriginals(_ origin: OriginalFilesOrigin) -> Bool {
        switch origin {
        case .selection:
            return canHandOffOriginals && !effectiveSelection.isEmpty
        case .item(let index, let revision):
            return canDragOriginal(at: index) && items[index].contentRevision == revision
        }
    }

    /// True for a local (non-Photos) item, independent of selection.
    func canDragOriginal(at index: Int) -> Bool {
        canHandOffOriginals
            && items.indices.contains(index)
            && items[index].primaryFile.photosMedia == nil
            && visiblePosition(ofItem: index) != nil
    }

    /// Resolves the originals for one drag or Open With request without
    /// changing selection, current item or follow-scroll.
    func originalFileTargets(for origin: OriginalFilesOrigin) -> OriginalFileTargets? {
        guard canHandOffOriginals else { return nil }
        let selection = effectiveSelection
        let indices: [Int]
        let leaderItem: Int?
        switch origin {
        case .selection:
            indices = Array(selection)
            leaderItem = selection.contains(currentIndex) ? currentIndex : nil
        case .item(let index, let revision):
            guard items.indices.contains(index),
                  items[index].contentRevision == revision,
                  visiblePosition(ofItem: index) != nil else { return nil }
            indices = selection.contains(index) ? Array(selection) : [index]
            leaderItem = index
        }
        let ordered = indices
            .compactMap { index -> (position: Int, index: Int)? in
                guard items.indices.contains(index),
                      let position = visiblePosition(ofItem: index) else { return nil }
                return (position, index)
            }
            .sorted { $0.position < $1.position }
            .map(\.index)
        var seen = Set<String>()
        var files: [OriginalFileTarget] = []
        var leaderFileIndex: Int?
        files.reserveCapacity(ordered.count)
        for index in ordered {
            for file in items[index].individualFiles
            where file.photosMedia == nil && file.url.isFileURL && seen.insert(file.id).inserted {
                if index == leaderItem, leaderFileIndex == nil { leaderFileIndex = files.count }
                files.append(OriginalFileTarget(fileID: file.id, url: file.url, itemIndex: index,
                                                identity: file.scannedIdentity))
            }
        }
        guard !files.isEmpty else { return nil }
        return OriginalFileTargets(files: files, leaderFileIndex: leaderFileIndex ?? 0)
    }
}
