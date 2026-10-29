import AppKit
import Combine
import Foundation

/// Durable identity, independent of mount point and spelling. UUID-less volumes
/// deliberately require the original device/root; uncertainty never adopts a pin.
struct PinnedFolderIdentity: Codable, Equatable, Sendable {
    let volumeRootPath: String
    let volumeUUIDString: String?
    let systemNumber: UInt64
    let fileNumber: UInt64
    let birthTime: FileOperationJournal.FileIdentity.Timestamp

    init(source: SessionPersistence.SourceFolderIdentity) {
        volumeRootPath = source.volumeRootPath
        volumeUUIDString = source.volumeUUIDString
        systemNumber = source.systemNumber
        fileNumber = source.fileNumber
        birthTime = source.birthTime
    }

    func matches(_ source: SessionPersistence.SourceFolderIdentity) -> Bool {
        self == Self(source: source)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let sameVolume = lhs.volumeUUIDString.map { rhs.volumeUUIDString == $0 }
            ?? (rhs.volumeUUIDString == nil && lhs.systemNumber == rhs.systemNumber
                && lhs.volumeRootPath == rhs.volumeRootPath)
        return sameVolume && lhs.fileNumber == rhs.fileNumber && lhs.birthTime == rhs.birthTime
    }
}

/// Construct from frozen scan evidence, never from a pathname or item index.
/// Include the complete scan revision. An external file rename can change
/// ctime; conservatively fall back unless a later session captured that revision.
struct PinnedFolderFileAnchor: Codable, Equatable, Sendable {
    let physicalFileID: String
    let identity: FileOperationJournal.FileIdentity

    var isValid: Bool {
        !physicalFileID.isEmpty && physicalFileID.utf8.count <= 16_384
            && identity.birthTime != nil && identity.modificationTime != nil && identity.statusChangeTime != nil
            && (identity.logicalSize.map { $0 >= 0 } ?? false)
    }

    func matches(_ other: Self) -> Bool {
        guard isValid, other.isValid else { return false }
        let lhs = identity, rhs = other.identity
        let sameVolume = lhs.volumeUUIDString.map { rhs.volumeUUIDString == $0 }
            ?? (rhs.volumeUUIDString == nil && lhs.systemNumber == rhs.systemNumber
                && lhs.volumeRootPath == rhs.volumeRootPath)
        return sameVolume && lhs.fileNumber == rhs.fileNumber && lhs.birthTime == rhs.birthTime
            && lhs.logicalSize == rhs.logicalSize && lhs.modificationTime == rhs.modificationTime
            && lhs.statusChangeTime == rhs.statusChangeTime
    }
}

struct PinnedFolderViewport: Codable, Equatable, Sendable {
    let anchor: PinnedFolderFileAnchor
    let topOffset: Double

    var isValid: Bool { anchor.isValid && topOffset.isFinite && abs(topOffset) <= 10_000_000 }
}

struct PinnedFolderRestoredViewport: Equatable, Sendable {
    let physicalFileID: String
    let topOffset: Double
}

struct PinnedFolderRestoredPosition: Equatable, Sendable {
    let currentPhysicalFileID: String?
    let browser: PinnedFolderRestoredViewport?
    let grid: PinnedFolderRestoredViewport?
}

struct PinnedFolderPosition: Codable, Equatable, Sendable {
    let current: PinnedFolderFileAnchor?
    let browser: PinnedFolderViewport?
    let grid: PinnedFolderViewport?

    var isValid: Bool {
        (current?.isValid ?? true) && (browser?.isValid ?? true) && (grid?.isValid ?? true)
    }

    /// Candidates must be the complete freshly scanned physical files (including
    /// hidden pair partners), projected back to displayed items by SessionStore.
    /// Ambiguous hard links and changed revisions are intentionally not restored.
    func restored(
        for folder: PinnedFolderIdentity,
        expectedFolder: PinnedFolderIdentity,
        candidates: [PinnedFolderFileAnchor]
    ) -> PinnedFolderRestoredPosition? {
        guard folder == expectedFolder, isValid else { return nil }
        func matching(_ anchor: PinnedFolderFileAnchor?) -> String? {
            guard let anchor else { return nil }
            var result: String?
            for candidate in candidates where anchor.matches(candidate) {
                guard result == nil else { return nil }
                result = candidate.physicalFileID
            }
            return result
        }
        func viewport(_ receipt: PinnedFolderViewport?) -> PinnedFolderRestoredViewport? {
            guard let receipt, let id = matching(receipt.anchor) else { return nil }
            return .init(physicalFileID: id, topOffset: receipt.topOffset)
        }
        let browser = viewport(self.browser), grid = viewport(self.grid)
        return .init(currentPhysicalFileID: matching(current) ?? browser?.physicalFileID ?? grid?.physicalFileID,
                     browser: browser, grid: grid)
    }
}

enum PinnedFolderAvailability: Equatable, Sendable {
    case available, unavailable, needsReconnect

    var status: String {
        switch self {
        case .available: L10n.text("Available")
        case .unavailable: L10n.text("Unavailable — reconnect the drive or locate the folder")
        case .needsReconnect: L10n.text("Access needed — locate the folder")
        }
    }
}

struct PinnedFolder: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let identity: PinnedFolderIdentity
    let availability: PinnedFolderAvailability
}

struct PinnedFolderOpenRequest: Sendable {
    let pinID: UUID
    /// Keep this exact bookmark/picker URL for scope authority. Never rebuild it
    /// from `path`. The opening worker must recheck expectedIdentity before read.
    let authorityURL: URL
    let expectedIdentity: PinnedFolderIdentity
}

enum PinnedFolderError: LocalizedError {
    case changedIdentity, bookmarkUnavailable, capacity, invalidStorage, invalidPosition

    var errorDescription: String? {
        switch self {
        case .changedIdentity:
            L10n.text("This is a different folder or drive. Locate the original pinned folder.")
        case .bookmarkUnavailable:
            L10n.text("Folder access could not be saved. Locate the folder and try again.")
        case .capacity:
            L10n.text("Pinned-folder storage is full. Unpin a folder and try again.")
        case .invalidStorage:
            L10n.text("Pinned folders could not be read. Previous records are retained. Try again.")
        case .invalidPosition:
            L10n.text("The browsing position could not be saved. Previous positions are retained.")
        }
    }
}

/// A separate Application Support document, never a decision sidecar or cache.
/// All reads, bookmark resolution/refresh, identity I/O and durable writes are
/// serialized here. Failed writes never publish a successfully saved snapshot.
actor PinnedFoldersPersistence {
    static let maximumBytes = 2 * 1_024 * 1_024
    static let maximumPins = 128
    static let maximumRecords = 256
    private static let maximumBookmarkBytes = 64 * 1_024

    struct Record: Codable, Equatable, Sendable {
        var id: UUID
        var identity: PinnedFolderIdentity
        var name: String
        var path: String
        var bookmark: Data?
        var isPinned: Bool
        var position: PinnedFolderPosition?
        var updated: Date
    }

    private struct Document: Codable {
        let version: Int
        let records: [Record]
    }

    struct Snapshot: Sendable {
        let revision: UInt64
        let folders: [PinnedFolder]
        let message: String?
    }

    private let fileURL: URL
    private let operations: SecurityScopedFolderBookmarks.Operations
    private let write: @Sendable (Data, URL) throws -> Void
    private var records: [Record] = []
    private var loaded = false
    private var revision: UInt64 = 0

    init(
        storageDirectory: URL,
        operations: SecurityScopedFolderBookmarks.Operations = .live,
        write: @escaping @Sendable (Data, URL) throws -> Void = {
            try DurableFileIO.atomicWrite($0, to: $1, fullSync: true)
        }
    ) {
        fileURL = storageDirectory.appendingPathComponent("PinnedFolders.json")
        self.operations = operations
        self.write = write
    }

    private var previousURL: URL { fileURL.appendingPathExtension("previous") }

    private func read(_ url: URL) throws -> [Record] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumBytes else {
            throw PinnedFolderError.invalidStorage
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw PinnedFolderError.invalidStorage }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.records.count <= Self.maximumRecords,
              document.records.filter(\.isPinned).count <= Self.maximumPins,
              Set(document.records.map(\.id)).count == document.records.count else {
            throw PinnedFolderError.invalidStorage
        }
        for (index, record) in document.records.enumerated() {
            guard record.name.utf8.count <= 16_384, record.path.utf8.count <= 32_768,
                  (record.bookmark?.count ?? 0) <= Self.maximumBookmarkBytes,
                  !record.isPinned || (record.bookmark != nil && !record.path.isEmpty),
                  record.position?.isValid ?? true,
                  !document.records.prefix(index).contains(where: { $0.identity == record.identity }) else {
                throw PinnedFolderError.invalidStorage
            }
        }
        return document.records
    }

    private func load() throws {
        guard !loaded else { return }
        do {
            records = try read(fileURL)
            loaded = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A surviving previous copy proves this is not a first launch.
            if FileManager().fileExists(atPath: previousURL.path) {
                records = (try? read(previousURL)) ?? records
                throw PinnedFolderError.invalidStorage
            }
            loaded = true
        } catch {
            // Show the last good records but block mutations until the primary
            // can be read again. Never overwrite an unreadable document as empty.
            records = (try? read(previousURL)) ?? records
            throw PinnedFolderError.invalidStorage
        }
    }

    private func encoded(_ records: [Record]) throws -> Data {
        guard records.count <= Self.maximumRecords,
              records.filter(\.isPinned).count <= Self.maximumPins else {
            throw PinnedFolderError.capacity
        }
        for record in records {
            guard record.name.utf8.count <= 16_384, record.path.utf8.count <= 32_768,
                  (record.bookmark?.count ?? 0) <= Self.maximumBookmarkBytes,
                  record.position?.isValid ?? true else {
                throw PinnedFolderError.capacity
            }
        }
        let data = try JSONEncoder().encode(Document(version: 1, records: records))
        guard data.count <= Self.maximumBytes else { throw PinnedFolderError.capacity }
        return data
    }

    private func commit(_ proposed: [Record]) throws {
        guard proposed != records else { return }
        let data = try encoded(proposed)
        try FileManager().createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep prior bytes even if the new rename succeeds but directory sync
        // fails. The visible store remains unchanged and reports the failure.
        if loaded { try write(try encoded(records), previousURL) }
        try write(data, fileURL)
        records = proposed
    }

    private func withScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let started = operations.access.start(url)
        defer { if started { operations.access.stop(url) } }
        return try body()
    }

    private func resolve(_ record: Record) throws -> (URL, Bool) {
        guard let bookmark = record.bookmark else { throw PinnedFolderError.bookmarkUnavailable }
        let result = try operations.resolve(bookmark)
        return (result.url, result.isStale)
    }

    private func verified(_ url: URL, identity: PinnedFolderIdentity) throws {
        guard identity.matches(try SessionPersistence.SourceFolderIdentity.capture(at: url)) else {
            throw PinnedFolderError.changedIdentity
        }
    }

    private func snapshot(message: String? = nil) -> Snapshot {
        revision &+= 1
        let folders = records.filter(\.isPinned).map { record -> PinnedFolder in
            let availability: PinnedFolderAvailability
            if let (url, _) = try? resolve(record) {
                availability = (try? withScope(url) { try verified(url, identity: record.identity) }) != nil
                    ? .available : .unavailable
            } else {
                availability = .needsReconnect
            }
            return PinnedFolder(id: record.id, name: record.name, path: record.path,
                                identity: record.identity, availability: availability)
        }
        return .init(revision: revision, folders: folders, message: message)
    }

    func refresh() -> Snapshot {
        do {
            try load()
            var proposed = records
            for index in proposed.indices where proposed[index].isPinned {
                guard let (url, stale) = try? resolve(proposed[index]) else { continue }
                let old = proposed[index]
                try? withScope(url) {
                    try verified(url, identity: old.identity)
                    let fresh = stale ? (try? operations.create(url)) : nil
                    let bookmark = fresh.flatMap { !$0.isEmpty && $0.count <= Self.maximumBookmarkBytes ? $0 : nil }
                        ?? old.bookmark
                    try verified(url, identity: old.identity)
                    proposed[index].path = url.path
                    proposed[index].name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
                    proposed[index].bookmark = bookmark
                }
            }
            try commit(proposed)
            return snapshot()
        } catch { return snapshot(message: error.localizedDescription) }
    }

    /// Welcome's picker needs no open session or scan evidence. Capture fresh
    /// directory identity off-main, retaining the exact grant through checked pinning.
    func pinSelectedFolder(url: URL) throws -> (UUID, Snapshot) {
        try withScope(url) {
            let identity = PinnedFolderIdentity(source: try .capture(at: url))
            return try pin(url: url, expectedIdentity: identity)
        }
    }

    func pin(url: URL, expectedIdentity: PinnedFolderIdentity) throws -> (UUID, Snapshot) {
        try load()
        let bookmark = try withScope(url) {
            try verified(url, identity: expectedIdentity)
            let data = try operations.create(url)
            guard !data.isEmpty, data.count <= Self.maximumBookmarkBytes else {
                throw PinnedFolderError.bookmarkUnavailable
            }
            try verified(url, identity: expectedIdentity)
            return data
        }
        var proposed = records
        let previous = proposed.first { $0.identity == expectedIdentity }
        guard previous?.isPinned == true || proposed.filter(\.isPinned).count < Self.maximumPins else {
            throw PinnedFolderError.capacity
        }
        let id = previous?.id ?? UUID()
        proposed.removeAll { $0.identity == expectedIdentity }
        proposed.insert(Record(id: id, identity: expectedIdentity,
                               name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                               path: url.path, bookmark: bookmark, isPinned: true,
                               position: previous?.position, updated: Date()), at: 0)
        trimUnpinned(&proposed)
        try commit(proposed)
        return (id, snapshot())
    }

    func unpin(id: UUID) throws -> Snapshot {
        try load()
        var proposed = records
        if let index = proposed.firstIndex(where: { $0.id == id }) {
            proposed[index].isPinned = false
            proposed[index].bookmark = nil
            proposed[index].updated = Date()
        }
        try commit(proposed)
        return snapshot()
    }

    func prepareOpen(id: UUID, reconnectingWith selected: URL? = nil) throws -> (PinnedFolderOpenRequest, Snapshot) {
        try load()
        guard let index = records.firstIndex(where: { $0.id == id && $0.isPinned }) else {
            throw PinnedFolderError.bookmarkUnavailable
        }
        let record = records[index]
        let (url, stale) = try selected.map { ($0, true) } ?? resolve(record)
        var proposed = records
        try withScope(url) {
            try verified(url, identity: record.identity)
            if stale {
                // A picker grant must become durable before reconnect succeeds.
                // A stale bookmark may continue with its prior working bytes.
                let bookmark: Data?
                if selected != nil { bookmark = try operations.create(url) }
                else { bookmark = (try? operations.create(url)) ?? record.bookmark }
                guard let bookmark, !bookmark.isEmpty, bookmark.count <= Self.maximumBookmarkBytes else {
                    throw PinnedFolderError.bookmarkUnavailable
                }
                proposed[index].bookmark = bookmark
            }
            try verified(url, identity: record.identity)
            proposed[index].path = url.path
            proposed[index].name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
        try commit(proposed)
        return (.init(pinID: id, authorityURL: url, expectedIdentity: record.identity), snapshot())
    }

    func savePosition(_ position: PinnedFolderPosition, for identity: PinnedFolderIdentity) throws -> Snapshot {
        try load()
        guard position.isValid else { throw PinnedFolderError.invalidPosition }
        var proposed = records
        if let index = proposed.firstIndex(where: { $0.identity == identity }) {
            proposed[index].position = position
            proposed[index].updated = Date()
        } else {
            proposed.append(Record(id: UUID(), identity: identity, name: "", path: "", bookmark: nil,
                                   isPinned: false, position: position, updated: Date()))
        }
        trimUnpinned(&proposed)
        try commit(proposed)
        // Position traffic must not re-resolve every pin or publish UI changes.
        return .init(revision: revision, folders: [], message: nil)
    }

    func position(for identity: PinnedFolderIdentity) throws -> PinnedFolderPosition? {
        try load()
        return records.first { $0.identity == identity }?.position
    }

    private func trimUnpinned(_ proposed: inout [Record]) {
        while proposed.count > Self.maximumRecords,
              let oldest = proposed.indices.filter({ !proposed[$0].isPinned })
                .min(by: { proposed[$0].updated < proposed[$1].updated }) {
            proposed.remove(at: oldest)
        }
    }
}

/// Child views observe this owner directly; SessionStore need not forward its
/// publications. Inject a worker or storageDirectory for isolated session tests.
@MainActor
final class PinnedFoldersStore: ObservableObject {
    @Published private(set) var folders: [PinnedFolder] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isWorking = false
    private let persistence: PinnedFoldersPersistence
    private var revision: UInt64 = 0
    private var activeRequests = 0
    private var observations: [AnyCancellable] = []
    private var refreshTask: Task<Void, Never>?

    static var defaultStorageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.alexandermarkin.louppe", isDirectory: true)
    }

    init(storageDirectory: URL? = nil,
         persistence: PinnedFoldersPersistence? = nil,
         observesSystemChanges: Bool = true) {
        self.persistence = persistence ?? PinnedFoldersPersistence(storageDirectory: storageDirectory ?? Self.defaultStorageDirectory)
        if observesSystemChanges {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                         NSWorkspace.didRenameVolumeNotification] {
                observations.append(workspace.publisher(for: name).sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleRefresh() }
                })
            }
            observations.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor [weak self] in self?.scheduleRefresh() } })
            scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await self?.refresh()
        }
    }

    func refresh() async { apply(await persistence.refresh()) }

    @discardableResult
    func pinSelectedFolder(url: URL) async -> UUID? {
        beginRequest()
        defer { endRequest() }
        do {
            let (id, snapshot) = try await persistence.pinSelectedFolder(url: url)
            apply(snapshot)
            return id
        } catch { statusMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func pin(url: URL, expectedIdentity: PinnedFolderIdentity) async -> UUID? {
        beginRequest()
        defer { endRequest() }
        do {
            let (id, snapshot) = try await persistence.pin(url: url, expectedIdentity: expectedIdentity)
            apply(snapshot)
            return id
        } catch { statusMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func unpin(id: UUID) async -> Bool {
        beginRequest()
        defer { endRequest() }
        do { apply(try await persistence.unpin(id: id)); return true }
        catch { statusMessage = error.localizedDescription; return false }
    }

    func prepareOpen(id: UUID, reconnectingWith url: URL? = nil) async -> PinnedFolderOpenRequest? {
        beginRequest()
        defer { endRequest() }
        do {
            let (request, snapshot) = try await persistence.prepareOpen(id: id, reconnectingWith: url)
            apply(snapshot)
            return request
        } catch {
            apply(await persistence.refresh())
            statusMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func savePosition(_ position: PinnedFolderPosition, for identity: PinnedFolderIdentity) async -> Bool {
        do { _ = try await persistence.savePosition(position, for: identity); return true }
        catch { statusMessage = error.localizedDescription; return false }
    }

    func position(for identity: PinnedFolderIdentity) async -> PinnedFolderPosition? {
        do { return try await persistence.position(for: identity) }
        catch { statusMessage = error.localizedDescription; return nil }
    }

    private func apply(_ snapshot: PinnedFoldersPersistence.Snapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        folders = snapshot.folders
        statusMessage = snapshot.message
    }

    func reportPositionFailure() { statusMessage = PinnedFolderError.invalidPosition.localizedDescription }

    private func beginRequest() { activeRequests += 1; isWorking = true; statusMessage = nil }
    private func endRequest() { activeRequests -= 1; isWorking = activeRequests > 0 }
}
