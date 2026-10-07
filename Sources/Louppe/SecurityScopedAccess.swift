import Foundation

/// Foundation's scope operations stay injectable so tests can enforce balanced
/// ownership without pretending an unsandboxed test process has picker grants.
struct SecurityScopedResourceAccess: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Holds a sandbox extension for one user-selected folder. `NSOpenPanel` and
/// Finder drops grant short-lived access; keeping this token alive lets the
/// scanner, media readers, and journalled file operations finish safely.
@MainActor
final class SecurityScopedFolderAccess {
    let url: URL
    private let resourceAccess: SecurityScopedResourceAccess
    private let resourceURL: URL
    private var didStartAccess = false

    init(url: URL, resourceAccess: SecurityScopedResourceAccess = .live) {
        // The selected/resolved URL owns the sandbox extension; a normalized
        // URL is only an identity key, never a replacement for that authority.
        let started = resourceAccess.start(url)
        self.url = url.standardizedFileURL
        self.resourceURL = url
        self.resourceAccess = resourceAccess
        didStartAccess = started
    }

    /// A detached task owns its own start/stop pair after the UI lease ends.
    func makeIndependentAccess() -> SecurityScopedFolderAccess {
        SecurityScopedFolderAccess(url: resourceURL, resourceAccess: resourceAccess)
    }

    /// The bound destination owns the stored path; the retained URL creates
    /// its bookmark. Callers first verify that both name the same directory.
    func recordRecoveryDestination(
        for destination: URL,
        in defaults: UserDefaults = .standard,
        operations: SecurityScopedFolderBookmarks.Operations = .live
    ) {
        SecurityScopedFolderBookmarks.recordRecoveryDestination(
            destination, authorityURL: resourceURL,
            in: defaults, operations: operations
        )
    }

    func stop() {
        guard didStartAccess else { return }
        resourceAccess.stop(resourceURL)
        didStartAccess = false
    }

    deinit {
        if didStartAccess {
            resourceAccess.stop(resourceURL)
        }
    }
}

/// Persists only folders explicitly selected by the photographer. Failed
/// resolution or bookmark refresh never discards the stored access record.
enum SecurityScopedFolderBookmarks {
    private static let recentsKey = "recentFolderBookmarks"
    private static let legacyPathsKey = "recentFolders"
    private static let recoveryDestinationsKey = "recoveryExportDestinations"

    struct Resolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    struct Operations: Sendable {
        let resolve: @Sendable (Data) throws -> Resolution
        let create: @Sendable (URL) throws -> Data
        let exists: @Sendable (URL) -> Bool
        let access: SecurityScopedResourceAccess

        static let live = Self(
            resolve: { data in
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return Resolution(url: url, isStale: isStale)
            },
            create: {
                try $0.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            access: .live
        )
    }

    private struct Entry: Codable, Equatable {
        let path: String
        let bookmark: Data?
    }

    static func load(
        from defaults: UserDefaults = .standard,
        operations: Operations = .live
    ) -> [URL] {
        let entries = storedEntries(forKey: recentsKey, from: defaults)
            ?? (defaults.stringArray(forKey: legacyPathsKey) ?? []).map {
                Entry(path: $0, bookmark: nil)
            }
        var updated = entries
        var seen = Set<String>()
        var urls: [URL] = []
        for (index, entry) in entries.enumerated() {
            let resolved = withResolvedEntry(entry, operations: operations) { url, refreshed in
                updated[index] = refreshed
                // A resolved bookmark supplies authority only while its scope
                // is active. Checking before starting it hides valid recents.
                return operations.exists(url) ? url : nil
            }
            if let url = resolved ?? nil, seen.insert(url.standardizedFileURL.path).inserted {
                urls.append(url)
            }
        }
        if updated != entries {
            store(updated, forKey: recentsKey, to: defaults)
            defaults.set(updated.map(\.path), forKey: legacyPathsKey)
        }
        return urls
    }

    static func save(
        _ urls: [URL],
        to defaults: UserDefaults = .standard,
        operations: Operations = .live
    ) {
        let previous = storedEntries(forKey: recentsKey, from: defaults) ?? []
        let saved = entries(for: urls, preserving: previous, operations: operations)
        store(saved, forKey: recentsKey, to: defaults)
        defaults.set(saved.map(\.path), forKey: legacyPathsKey)
    }

    /// Retain a destination only while a journal could need it after an
    /// interruption. A later destination must not erase an inaccessible one.
    static func recordRecoveryDestination(
        _ url: URL,
        authorityURL: URL? = nil,
        in defaults: UserDefaults = .standard,
        operations: Operations = .live
    ) {
        var saved = refreshedEntries(
            forKey: recoveryDestinationsKey,
            from: defaults,
            operations: operations
        )
        let selected = url.standardizedFileURL
        let original = authorityURL ?? url
        let started = operations.access.start(original)
        defer { if started { operations.access.stop(original) } }
        let bookmark = (try? operations.create(original))
            ?? saved.first(where: { $0.path == selected.path })?.bookmark
        saved.removeAll { $0.path == selected.path }
        store(
            [Entry(path: selected.path, bookmark: bookmark)] + saved,
            forKey: recoveryDestinationsKey, to: defaults
        )
    }

    @MainActor
    static func beginRecoveryDestinationAccesses(
        from defaults: UserDefaults = .standard,
        operations: Operations = .live
    ) -> [SecurityScopedFolderAccess] {
        let saved = refreshedEntries(
            forKey: recoveryDestinationsKey,
            from: defaults,
            operations: operations
        )
        return saved.compactMap { entry in
            let url: URL
            if let bookmark = entry.bookmark {
                guard let resolution = try? operations.resolve(bookmark) else { return nil }
                url = resolution.url
            } else {
                url = URL(fileURLWithPath: entry.path)
            }
            return SecurityScopedFolderAccess(url: url, resourceAccess: operations.access)
        }
    }

    static func clearRecoveryDestinations(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: recoveryDestinationsKey)
    }

    private static func entries(
        for urls: [URL],
        preserving previous: [Entry],
        operations: Operations
    ) -> [Entry] {
        var seen = Set<String>()
        return urls.compactMap { original in
            let url = original.standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            let started = operations.access.start(original)
            defer { if started { operations.access.stop(original) } }
            let bookmark = (try? operations.create(original))
                ?? previous.first(where: { $0.path == url.path })?.bookmark
            return Entry(path: url.path, bookmark: bookmark)
        }
    }

    /// Run refresh and inspection under one temporary scope, then return an
    /// inactive URL. The open session or recovery worker owns its next lease.
    private static func withResolvedEntry<T>(
        _ entry: Entry,
        operations: Operations,
        inspect: (URL, Entry) -> T
    ) -> T? {
        let resolution = entry.bookmark.flatMap { try? operations.resolve($0) }
        // A pathname cannot substitute for a failed security-scoped bookmark.
        // Preserve its bytes for a later reconnect or explicit folder chooser.
        if entry.bookmark != nil && resolution == nil { return nil }
        let url = resolution?.url ?? URL(fileURLWithPath: entry.path)
        let started = operations.access.start(url)
        defer { if started { operations.access.stop(url) } }
        let refreshed: Entry
        if let resolution {
            let bookmark = resolution.isStale
                ? (try? operations.create(url)) ?? entry.bookmark
                : entry.bookmark
            refreshed = Entry(path: url.standardizedFileURL.path, bookmark: bookmark)
        } else {
            refreshed = entry
        }
        return inspect(url, refreshed)
    }

    private static func refreshedEntries(
        forKey key: String,
        from defaults: UserDefaults,
        operations: Operations
    ) -> [Entry] {
        let saved = storedEntries(forKey: key, from: defaults) ?? []
        let refreshed = saved.map { entry in
            withResolvedEntry(entry, operations: operations) { _, refreshed in refreshed } ?? entry
        }
        if refreshed != saved { store(refreshed, forKey: key, to: defaults) }
        return refreshed
    }

    private static func storedEntries(
        forKey key: String,
        from defaults: UserDefaults
    ) -> [Entry]? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    private static func store(_ entries: [Entry], forKey key: String, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
