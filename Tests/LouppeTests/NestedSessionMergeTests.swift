import Darwin
import XCTest
@testable import Louppe

/// Decisions saved by other folder sessions merge into the opened folder:
/// real disposable trees, real sidecars and the normal opening/save paths.
@MainActor
final class NestedSessionMergeTests: XCTestCase {
    /// base/Archive/{Day1/{A,B,Sub/C}, Day2/D, Day10/E, Trip/Inner/F}.png
    private struct Tree {
        let base: URL
        let backups: URL
        let pins: URL
        var archive: URL { base.appendingPathComponent("Archive") }
        var day1: URL { archive.appendingPathComponent("Day1") }
        var sub: URL { day1.appendingPathComponent("Sub") }
        var day2: URL { archive.appendingPathComponent("Day2") }
        var day10: URL { archive.appendingPathComponent("Day10") }
        var trip: URL { archive.appendingPathComponent("Trip") }
        var a: URL { day1.appendingPathComponent("A.png") }
        var b: URL { day1.appendingPathComponent("B.png") }
        var c: URL { sub.appendingPathComponent("C.png") }
        var d: URL { day2.appendingPathComponent("D.png") }
        var e: URL { day10.appendingPathComponent("E.png") }
        var f: URL { trip.appendingPathComponent("Inner/F.png") }
    }

    /// Foreign-read observations and scope balance for one test.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _reads: [String] = []
        private var _starts = 0
        private var _stops = 0
        var refused: Set<String> = []
        var startSucceeds = true
        var reads: [String] { lock.withLock { _reads } }
        var starts: Int { lock.withLock { _starts } }
        var stops: Int { lock.withLock { _stops } }
        func read(_ url: URL) throws {
            let path = url.resolvingSymlinksInPath().path
            lock.withLock { _reads.append(path) }
            if lock.withLock({ refused.contains(path) }) { throw POSIXError(.EACCES) }
        }
        /// Counts only scopes that started, which alone need a stop.
        func start() -> Bool {
            lock.withLock {
                if startSucceeds { _starts += 1 }
                return startSucceeds
            }
        }
        func stop() { lock.withLock { _stops += 1 } }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: Int) -> Date { Self.t0.addingTimeInterval(TimeInterval(seconds)) }

    private func makeTree() throws -> Tree {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-Nested-\(UUID().uuidString)")
        let tree = Tree(base: base, backups: base.appendingPathComponent("Backups"), pins: base.appendingPathComponent("Pins"))
        let png = try Data(contentsOf: URL(fileURLWithPath: "Packaging/AppIcon/AppIcon.iconset/icon_16x16.png"))
        for file in [tree.a, tree.b, tree.c, tree.d, tree.e, tree.f] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file)
        }
        addTeardownBlock {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.archive.path)
            for name in ["Day1", "Day2", "Trip", "Day1/Sub"] {
                _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath:
                    tree.archive.appendingPathComponent(name).appendingPathComponent(SessionConstants.sidecarName).path)
            }
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath:
                tree.archive.appendingPathComponent(SessionConstants.sidecarName).path)
            try? FileManager.default.removeItem(at: base)
        }
        return tree
    }

    private func entry(_ url: URL, _ name: String, rating: Rating = .undecided, ratedAt: Date? = nil,
                       stars: StarRating? = nil, starsAt: Date? = nil,
                       color: PhotoColorLabel? = nil, colorAt: Date? = nil,
                       identity: FileOperationJournal.FileIdentity? = nil) throws -> SessionEntry {
        SessionEntry(filename: name, pairedFilename: nil, rating: rating.rawValue, ratedAt: ratedAt,
                     stars: stars, starsChangedAt: starsAt, colorLabel: color, colorChangedAt: colorAt,
                     fileIdentity: try identity ?? FileOperationJournal.captureIdentity(at: url))
    }

    /// Writes a current sidecar through the real persistence writer.
    private func save(_ entries: [SessionEntry], in folder: URL, tree: Tree,
                      records: [SessionRecoveryEntry]? = nil) async throws {
        let result = await SessionPersistence(backupDirectory: tree.backups).save(
            SessionFile(version: 7, sourcePath: folder.path, scannedAt: at(0), entries: entries,
                        fileIDEncoding: .percentEncodedFileSystemPath, recoveryEntries: records),
            for: folder, sequence: 1)
        XCTAssertEqual(result, .savedToSidecar)
    }

    /// Exact bytes for schemas the current writer no longer produces.
    private func write(_ session: SessionFile, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: sidecar(folder))
    }

    private func sidecar(_ folder: URL) -> URL { folder.appendingPathComponent(SessionConstants.sidecarName) }

    private func bytes(_ folders: [URL]) -> [String: Data?] {
        Dictionary(uniqueKeysWithValues: folders.map { ($0.path, try? Data(contentsOf: sidecar($0))) })
    }

    /// Real (unscoped) bookmarks follow renames; path bytes stand in otherwise.
    /// Real bookmarks report their recorded volume; path stand-ins use the
    /// volume of the path they name.
    nonisolated private static func testBookmarkVolume(_ data: Data) -> NestedSessionMerge.Volume? {
        NestedSessionMerge.GrantAccess.live.bookmarkVolume(data)
            ?? NestedSessionMerge.Volume(of: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)))
    }

    nonisolated private static func resolveTestBookmark(_ data: Data) -> URL {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        return URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
    }

    private func pinOperations(realBookmarks: Bool = false) -> SecurityScopedFolderBookmarks.Operations {
        .init(resolve: { .init(url: Self.resolveTestBookmark($0), isStale: false) },
              create: { realBookmarks ? try $0.bookmarkData() : Data($0.path.utf8) },
              exists: { FileManager.default.fileExists(atPath: $0.path) },
              access: .init(start: { _ in true }, stop: { _ in }))
    }

    private func store(_ tree: Tree, spy: Spy, recents: [URL] = [],
                       recentBookmarks: [(path: String, bookmark: Data)] = [],
                       resolves: Bool = true,
                       persistence: (any SessionPersistenceClient)? = nil) -> SessionStore {
        let defaults = UserDefaults(suiteName: "NestedSessionMergeTests-\(UUID())")!
        let stored = recents.map { ($0.path, Data($0.path.utf8)) } + recentBookmarks.map { ($0.path, $0.bookmark) }
        if !stored.isEmpty {
            struct Entry: Codable { let path: String; let bookmark: Data? }
            defaults.set(try! JSONEncoder().encode(stored.map { Entry(path: $0.0, bookmark: $0.1) }),
                         forKey: "recentFolderBookmarks")
        }
        let pins = PinnedFoldersStore(persistence: PinnedFoldersPersistence(storageDirectory: tree.pins,
                                                                             operations: pinOperations()),
                                      observesSystemChanges: false)
        let store = SessionStore(persistence: persistence ?? SessionPersistence(backupDirectory: tree.backups),
                                 reviewDefaults: defaults, pinnedFolders: pins)
        store.openingWorkerHooksForTesting.nestedSessionGrantAccess = .init(
            resolve: { data in
                guard resolves else { throw CocoaError(.fileReadNoSuchFile) }
                return Self.resolveTestBookmark(data)
            },
            access: .init(start: { _ in spy.start() }, stop: { _ in spy.stop() }),
            bookmarkVolume: Self.testBookmarkVolume)
        store.openingWorkerHooksForTesting.willReadNestedSession = { try spy.read($0) }
        return store
    }

    private func pin(_ folder: URL, tree: Tree, realBookmark: Bool = false) async throws {
        _ = try await PinnedFoldersPersistence(storageDirectory: tree.pins,
                                               operations: pinOperations(realBookmarks: realBookmark))
            .pinSelectedFolder(url: folder)
    }

    private func open(_ store: SessionStore, _ folder: URL) async throws {
        store.openFolder(folder)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if case .ready = store.phase { break }
            if case .welcome = store.phase, store.scanError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready = store.phase else { return XCTFail("Not Ready: \(store.scanError ?? "timeout")") }
        let idle1 = await store.waitForPersistenceIdleForTesting(timeout: .seconds(10))
        XCTAssertTrue(idle1)
    }

    private func metadata(_ store: SessionStore, _ id: String) throws -> PhotoFileMetadataSnapshot {
        let file = store.items.flatMap(\.individualFiles).first { $0.id == id }
        return try XCTUnwrap(file, "missing \(id)").metadataSnapshot
    }

    private func saved(_ folder: URL) throws -> [String: SessionEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(SessionFile.self, from: Data(contentsOf: sidecar(folder)))
        return Dictionary(uniqueKeysWithValues: session.entries.map { ($0.filename, $0) })
    }

    private func ancestorReads(_ spy: Spy, outside root: URL) -> [String] {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return spy.reads.filter { !$0.hasPrefix(prefix) }
    }

    // MARK: Parent after child

    func testParentMergesDescendantSessionsAndLeavesThemByteForByte() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10), stars: .four, starsAt: at(10)),
                        try entry(tree.b, "B.png", rating: .no, ratedAt: at(10)),
                        try entry(tree.c, "Sub/C.png", rating: .yes, ratedAt: at(10))], in: tree.day1, tree: tree)
        // The deeper session saw C later.
        try await save([try entry(tree.c, "C.png", rating: .no, ratedAt: at(20))], in: tree.sub, tree: tree)
        // A sidecar beside no direct media still counts.
        try await save([try entry(tree.f, "Inner/F.png", color: .red, colorAt: at(30))], in: tree.trip, tree: tree)
        let foreign = [tree.day1, tree.sub, tree.trip]
        let before = bytes(foreign)

        let spy = Spy()
        let store = store(tree, spy: spy)
        try await open(store, tree.archive)
        let a = try metadata(store, "Day1/A.png")
        XCTAssertEqual(a.rating, .yes)
        XCTAssertEqual(a.ratedAt, at(10))
        XCTAssertEqual(a.starRating, .four)
        XCTAssertEqual(try metadata(store, "Day1/B.png").rating, .no)
        XCTAssertEqual(try metadata(store, "Day1/Sub/C.png").rating, .no)
        XCTAssertEqual(try metadata(store, "Day1/Sub/C.png").ratedAt, at(20))
        XCTAssertEqual(try metadata(store, "Trip/Inner/F.png").colorLabel, .red)
        XCTAssertEqual(try metadata(store, "Day2/D.png").ratedAt, nil)
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 4, contributingSessions: 3))
        XCTAssertNotNil(store.openingMetrics?.secondsByStage[.nestedSessionMerge])
        XCTAssertEqual(store.nestedSessionMergeNotice, "Included 4 decisions from 3 earlier folder sessions.")
        XCTAssertNil(store.persistenceWarning)
        XCTAssertTrue(store.pendingSessionRecoveryEntries.isEmpty)

        // Only the opened folder's sidecar is written.
        let root = try saved(tree.archive)
        XCTAssertEqual(root["Day1/A.png"]?.rating, Rating.yes.rawValue)
        XCTAssertEqual(root["Day1/A.png"]?.starsChangedAt, at(10))
        XCTAssertEqual(root["Day1/Sub/C.png"]?.ratedAt, at(20))
        XCTAssertEqual(root["Trip/Inner/F.png"]?.colorLabel, .red)
        XCTAssertEqual(bytes(foreign), before)
        XCTAssertTrue(ancestorReads(spy, outside: tree.archive).isEmpty)

        // Reopening finds nothing new.
        let rootBytes = try Data(contentsOf: sidecar(tree.archive))
        let again = self.store(tree, spy: Spy())
        try await open(again, tree.archive)
        XCTAssertNil(again.nestedSessionMergeSummary)
        XCTAssertNil(again.nestedSessionMergeNotice)
        XCTAssertEqual(try metadata(again, "Day1/Sub/C.png").rating, .no)
        XCTAssertEqual(try saved(tree.archive)["Day1/A.png"]?.ratedAt, at(10))
        XCTAssertEqual(try saved(tree.archive).mapValues(\.rating), try JSONDecoderSessionEntries(rootBytes).mapValues(\.rating))
        XCTAssertEqual(bytes(foreign), before)
    }

    private func JSONDecoderSessionEntries(_ data: Data) throws -> [String: SessionEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Dictionary(uniqueKeysWithValues: try decoder.decode(SessionFile.self, from: data).entries.map { ($0.filename, $0) })
    }

    // MARK: Child after parent

    func testChildReadsOnlyAncestorsAnExistingGrantCovers() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(20)),
                        try entry(tree.e, "Day10/E.png", rating: .yes, ratedAt: at(20)),
                        try entry(tree.d, "Day2/D.png", rating: .no, ratedAt: at(20))], in: tree.archive, tree: tree)
        try await save([try entry(tree.b, "Archive/Day1/B.png", rating: .no, ratedAt: at(30))], in: tree.base, tree: tree)
        let foreign = [tree.archive, tree.base]
        let before = bytes(foreign)

        // No grant: no ancestor is opened at all.
        let ungranted = Spy()
        let plain = store(tree, spy: ungranted)
        try await open(plain, tree.day1)
        XCTAssertNil(try metadata(plain, "A.png").ratedAt)
        XCTAssertTrue(ancestorReads(ungranted, outside: tree.day1).isEmpty)
        XCTAssertEqual(ungranted.starts, 0)

        // A pin on Archive grants Archive only; nothing above it is probed.
        try FileManager.default.removeItem(at: sidecar(tree.day1))
        try await pin(tree.archive, tree: tree)
        let spy = Spy()
        let pinned = store(tree, spy: spy, recents: [tree.archive])
        try await open(pinned, tree.day1)
        XCTAssertEqual(try metadata(pinned, "A.png").rating, .yes)
        XCTAssertEqual(try metadata(pinned, "A.png").ratedAt, at(20))
        XCTAssertNil(try metadata(pinned, "B.png").ratedAt)
        XCTAssertEqual(pinned.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        // Pin and recent overlap: one read of the covered ancestor.
        XCTAssertEqual(ancestorReads(spy, outside: tree.day1),
                       [sidecar(tree.archive).resolvingSymlinksInPath().path])
        XCTAssertGreaterThan(spy.starts, 0)
        XCTAssertEqual(spy.starts, spy.stops)
        XCTAssertEqual(try saved(tree.day1)["A.png"]?.ratedAt, at(20))
        XCTAssertNil(try saved(tree.day1)["E.png"])
        XCTAssertEqual(bytes(foreign), before)

        // A higher grant covers both ancestors. Day1's own backup already
        // holds A, so only B is new.
        try FileManager.default.removeItem(at: sidecar(tree.day1))
        let wide = Spy()
        let widened = store(tree, spy: wide, recents: [tree.base])
        try await open(widened, tree.day1)
        XCTAssertEqual(try metadata(widened, "B.png").rating, .no)
        XCTAssertEqual(try metadata(widened, "A.png").rating, .yes)
        XCTAssertEqual(widened.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        XCTAssertEqual(Set(ancestorReads(wide, outside: tree.day1)),
                       Set([tree.archive, tree.base].map { sidecar($0).resolvingSymlinksInPath().path }))
        XCTAssertEqual(wide.starts, wide.stops)
        XCTAssertEqual(bytes(foreign), before)
    }

    // MARK: Ties, clears and dated nil values

    func testTiesKeepTheOpenedCopyThenTheClosestFolder() async throws {
        let tree = try makeTree()
        // Opened Archive copy: A yes at 10, color red at 5; F yes at 40.
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(10), color: .red, colorAt: at(5)),
                        try entry(tree.f, "Trip/Inner/F.png", rating: .yes, ratedAt: at(40))],
                       in: tree.archive, tree: tree)
        try await save([try entry(tree.f, "F.png", rating: .no, ratedAt: at(40))],
                       in: tree.trip.appendingPathComponent("Inner"), tree: tree)
        // Day1 ties on A's decision, adds dated stars, renews the same color.
        try await save([try entry(tree.a, "A.png", rating: .no, ratedAt: at(10), stars: .five, starsAt: at(10),
                                  color: .red, colorAt: at(15)),
                        try entry(tree.c, "Sub/C.png", rating: .yes, ratedAt: at(40))], in: tree.day1, tree: tree)
        // Sub ties Day1 on C: the closer folder wins.
        try await save([try entry(tree.c, "C.png", rating: .no, ratedAt: at(40))], in: tree.sub, tree: tree)
        let store = store(tree, spy: Spy())
        try await open(store, tree.archive)
        let a = try metadata(store, "Day1/A.png")
        XCTAssertEqual(a.rating, .yes)
        XCTAssertEqual(a.ratedAt, at(10))
        XCTAssertEqual(a.starRating, .five)
        XCTAssertEqual(a.colorLabel, .red)
        XCTAssertEqual(a.colorChangedAt, at(15))
        XCTAssertEqual(try metadata(store, "Day1/Sub/C.png").rating, .no)
        XCTAssertEqual(try metadata(store, "Trip/Inner/F.png").rating, .yes)
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 2, contributingSessions: 2))
        XCTAssertEqual(try saved(tree.archive)["Day1/A.png"]?.colorChangedAt, at(15))

        // Opening Trip, an ancestor (Archive) and a descendant (Inner) tie
        // on F: the descendant is closer to the file.
        let child = self.store(tree, spy: Spy(), recents: [tree.archive])
        try await open(child, tree.trip)
        XCTAssertEqual(try metadata(child, "Inner/F.png").rating, .no)
        XCTAssertEqual(child.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
    }

    func testNewerClearBeatsOlderYesAndDatedNilValuesClear() async throws {
        let tree = try makeTree()
        let old = Date(timeIntervalSinceNow: -3_600).rounded
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: old, stars: .four, starsAt: old,
                                  color: .green, colorAt: old),
                        try entry(tree.b, "Day1/B.png", rating: .yes, ratedAt: old)], in: tree.archive, tree: tree)
        // A real child session clears A's decision through Clear All; dated
        // nil stars/color clear too, and an undated default changes nothing.
        let child = store(tree, spy: Spy())
        try await open(child, tree.day1)
        child.rate(.yes, at: child.items.firstIndex { $0.primaryFile.id == "A.png" }!)
        child.clearAllRatings()
        _ = await child.saveSessionForTermination()
        let idle2 = await child.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle2)
        var day1 = try saved(tree.day1)
        let cleared = try XCTUnwrap(day1["A.png"]?.ratedAt)
        XCTAssertEqual(day1["A.png"]?.rating, Rating.undecided.rawValue)
        day1["A.png"]?.stars = nil
        day1["A.png"]?.starsChangedAt = cleared
        day1["A.png"]?.colorLabel = nil
        day1["A.png"]?.colorChangedAt = cleared
        day1["B.png"] = try entry(tree.b, "B.png")
        try FileManager.default.removeItem(at: sidecar(tree.day1))
        try await save(Array(day1.values), in: tree.day1, tree: tree)

        let parent = store(tree, spy: Spy())
        try await open(parent, tree.archive)
        let a = try metadata(parent, "Day1/A.png")
        XCTAssertEqual(a.rating, .undecided)
        XCTAssertEqual(a.ratedAt, cleared)
        XCTAssertNil(a.starRating)
        XCTAssertEqual(a.starsChangedAt, cleared)
        XCTAssertNil(a.colorLabel)
        XCTAssertEqual(try metadata(parent, "Day1/B.png").rating, .yes)
        XCTAssertEqual(parent.nestedSessionMergeSummary?.changedFiles, 1)

        let reopened = store(tree, spy: Spy())
        try await open(reopened, tree.archive)
        XCTAssertEqual(try metadata(reopened, "Day1/A.png").rating, .undecided)
        XCTAssertNil(reopened.nestedSessionMergeSummary)
    }

    // MARK: Identity and document admission

    func testReplacedFileIsSkippedWhileItsNeighbourMerges() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10)),
                        try entry(tree.b, "B.png", rating: .no, ratedAt: at(10))], in: tree.day1, tree: tree)
        let before = bytes([tree.day1])
        let original = try Data(contentsOf: tree.a)
        try FileManager.default.moveItem(at: tree.a, to: tree.base.appendingPathComponent("Old-A.png"))
        try original.write(to: tree.a)
        let store = store(tree, spy: Spy())
        try await open(store, tree.archive)
        XCTAssertEqual(try metadata(store, "Day1/A.png").rating, .undecided)
        XCTAssertNil(try metadata(store, "Day1/A.png").ratedAt)
        XCTAssertEqual(try metadata(store, "Day1/B.png").rating, .no)
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        XCTAssertTrue(store.pendingSessionRecoveryEntries.isEmpty)
        XCTAssertNil(store.scanError)
        XCTAssertEqual(bytes([tree.day1]), before)
    }

    func testUnreadableCorruptLinkedAndNonregularSidecarsContributeNothing() async throws {
        let tree = try makeTree()
        try Data("{ not json".utf8).write(to: sidecar(tree.day1))
        try await save([try entry(tree.d, "D.png", rating: .yes, ratedAt: at(10))], in: tree.day2, tree: tree)
        try await save([try entry(tree.f, "Inner/F.png", rating: .yes, ratedAt: at(10))], in: tree.trip, tree: tree)
        XCTAssertEqual(chmod(sidecar(tree.trip).path, 0o000), 0)
        try FileManager.default.createSymbolicLink(at: sidecar(tree.sub), withDestinationURL: sidecar(tree.day2))
        XCTAssertEqual(mkfifo(sidecar(tree.day10).path, 0o644), 0)
        let foreign = [tree.day1, tree.day2]
        let before = bytes(foreign)
        let store = store(tree, spy: Spy())
        try await open(store, tree.archive)
        XCTAssertEqual(try metadata(store, "Day2/D.png").rating, .yes)
        XCTAssertNil(try metadata(store, "Trip/Inner/F.png").ratedAt)
        XCTAssertNil(try metadata(store, "Day1/Sub/C.png").ratedAt)
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        XCTAssertNil(store.persistenceWarning)
        XCTAssertNil(store.scanError)
        XCTAssertTrue(store.pendingSessionRecoveryEntries.isEmpty)
        XCTAssertEqual(bytes(foreign), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sidecar(tree.sub).path),
                       sidecar(tree.day2).path)
    }

    func testLegacySchemasAndRecoveryHistoryNeverBecomeLiveDecisions() async throws {
        let tree = try makeTree()
        // v1 combined and v3 exact-path entries carry no physical identity.
        try write(SessionFile(version: 1, sourcePath: tree.day1.path, scannedAt: at(0), entries: [
            SessionEntry(filename: "A.png", pairedFilename: nil, rating: Rating.yes.rawValue, ratedAt: at(10))]),
                  in: tree.day1)
        try write(SessionFile(version: 3, sourcePath: tree.day2.path, scannedAt: at(0), entries: [
            SessionEntry(filename: "D.png", pairedFilename: nil, rating: Rating.yes.rawValue, ratedAt: at(10))],
                              fileIDEncoding: .percentEncodedFileSystemPath), in: tree.day2)
        // v4 supplies a dated decision only.
        try write(SessionFile(version: 4, sourcePath: tree.trip.path, scannedAt: at(0), entries: [
            try entry(tree.f, "Inner/F.png", rating: .no, ratedAt: at(10))],
                              fileIDEncoding: .percentEncodedFileSystemPath), in: tree.trip)
        // v7 history and an entry for a missing original stay out.
        try await save([try entry(tree.c, "C.png"),
                        try entry(tree.c, "Gone.png", rating: .yes, ratedAt: at(10))], in: tree.sub, tree: tree,
                       records: [SessionRecoveryEntry(entry: try entry(tree.c, "C.png", rating: .yes, ratedAt: at(50)))])
        let foreign = [tree.day1, tree.day2, tree.trip, tree.sub]
        let before = bytes(foreign)
        let store = store(tree, spy: Spy())
        try await open(store, tree.archive)
        XCTAssertNil(try metadata(store, "Day1/A.png").ratedAt)
        XCTAssertNil(try metadata(store, "Day2/D.png").ratedAt)
        XCTAssertNil(try metadata(store, "Day1/Sub/C.png").ratedAt)
        XCTAssertEqual(try metadata(store, "Trip/Inner/F.png").rating, .no)
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        XCTAssertFalse(store.isLegacySessionMigrationConfirmationPresented)
        XCTAssertTrue(store.pendingSessionRecoveryEntries.isEmpty)
        XCTAssertNil(try saved(tree.archive)["Day1/Sub/Gone.png"])
        XCTAssertEqual(bytes(foreign), before)
    }

    // MARK: Sandbox-style ancestor access

    func testMissingAncestorAccessNeverReadsOrPrompts() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(10))], in: tree.archive, tree: tree)
        let before = bytes([tree.archive])
        let archiveSidecar = sidecar(tree.archive).resolvingSymlinksInPath().path
        func expectUnmerged(_ store: SessionStore, _ spy: Spy, reads: Int,
                            file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertNil(try metadata(store, "A.png").ratedAt, file: file, line: line)
            XCTAssertNil(store.nestedSessionMergeSummary, file: file, line: line)
            XCTAssertNil(store.scanError, file: file, line: line)
            XCTAssertNil(store.persistenceWarning, file: file, line: line)
            XCTAssertEqual(ancestorReads(spy, outside: tree.day1).count, reads, file: file, line: line)
            XCTAssertEqual(spy.starts, spy.stops, file: file, line: line)
        }
        // A search-only parent and no grant: no ancestor read attempt.
        XCTAssertEqual(chmod(tree.archive.path, 0o111), 0)
        let none = Spy()
        let plain = store(tree, spy: none)
        try await open(plain, tree.day1)
        try expectUnmerged(plain, none, reads: 0)
        XCTAssertEqual(chmod(tree.archive.path, 0o755), 0)

        try await pin(tree.archive, tree: tree)
        for (resolves, scope) in [(false, true), (true, false)] {
            try? FileManager.default.removeItem(at: sidecar(tree.day1))
            let spy = Spy()
            spy.startSucceeds = scope
            let denied = store(tree, spy: spy, resolves: resolves)
            try await open(denied, tree.day1)
            try expectUnmerged(denied, spy, reads: 0)
        }
        // The read itself is refused (injected, then real POSIX EACCES).
        try? FileManager.default.removeItem(at: sidecar(tree.day1))
        let refusedSpy = Spy()
        refusedSpy.refused = [archiveSidecar]
        let refused = store(tree, spy: refusedSpy)
        try await open(refused, tree.day1)
        try expectUnmerged(refused, refusedSpy, reads: 1)
        try? FileManager.default.removeItem(at: sidecar(tree.day1))
        XCTAssertEqual(chmod(sidecar(tree.archive).path, 0o000), 0)
        let posixSpy = Spy()
        let posix = store(tree, spy: posixSpy)
        try await open(posix, tree.day1)
        try expectUnmerged(posix, posixSpy, reads: 1)
        XCTAssertEqual(chmod(sidecar(tree.archive).path, 0o644), 0)

        // Positive control: the same grant, readable and scoped.
        try? FileManager.default.removeItem(at: sidecar(tree.day1))
        let granted = Spy()
        let store = store(tree, spy: granted)
        try await open(store, tree.day1)
        XCTAssertEqual(try metadata(store, "A.png").rating, .yes)
        XCTAssertEqual(granted.starts, granted.stops)
        XCTAssertEqual(bytes([tree.archive]), before)
    }

    // MARK: Sources and commands that never merge

    func testPhotosSourcesAndOpenAsNewSessionNeverMerge() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10))], in: tree.day1, tree: tree)
        func prepare(replace: Bool, photos: Bool) async throws -> SessionOpeningPreparation {
            let batch = PhotosReviewBatch(folder: tree.archive,
                snapshot: .init(id: UUID(), count: 1, title: "Disposable Photos", query: .init()),
                range: .init(entireSelection: 1), assetIDsByPath: [:], decisions: [:], captureDatesByPath: [:])
            return try await SessionOpeningWorker.prepare(
                folder: tree.archive, pairingMode: .separate,
                persistence: SessionPersistence(backupDirectory: tree.backups),
                replaceSavedSession: replace, recorder: SessionOpeningRecorder(), allowsPreview: false,
                photosBatch: photos ? batch : nil)
        }
        for (replace, photos) in [(true, false), (false, true)] {
            let result = try await prepare(replace: replace, photos: photos)
            XCTAssertEqual(result.restoration.nestedSessionMerge, .init())
            XCTAssertTrue(result.restoration.items.flatMap(\.individualFiles).allSatisfy { $0.ratedAt == nil })
        }
        let control = try await prepare(replace: false, photos: false)
        XCTAssertEqual(control.restoration.nestedSessionMerge, .init(changedFiles: 1, contributingSessions: 1))
    }

    func testArchiveNavigationDoesNotReopenOrMerge() async throws {
        let tree = try makeTree()
        let spy = Spy()
        let store = store(tree, spy: spy)
        try await open(store, tree.archive)
        XCTAssertNil(store.nestedSessionMergeSummary)
        // A sidecar that appears later is not read by browsing a subfolder.
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10))], in: tree.day1, tree: tree)
        let readsBefore = spy.reads.count
        store.selectArchiveFolder("Day1")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(spy.reads.count, readsBefore)
        XCTAssertNil(try metadata(store, "Day1/A.png").ratedAt)
        // A real rescan is an open and merges.
        store.rescan()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while store.nestedSessionMergeSummary == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        XCTAssertEqual(try metadata(store, "Day1/A.png").rating, .yes)
    }

    // MARK: Worker-level faults

    private func fakeGrantAccess(_ spy: Spy) -> NestedSessionMerge.GrantAccess {
        .init(resolve: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) },
              access: .init(start: { _ in spy.start() }, stop: { _ in spy.stop() }),
              bookmarkVolume: Self.testBookmarkVolume)
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    func testCancellingDuringAncestorReadClosesDescriptorsAndScopes() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(10))], in: tree.archive, tree: tree)
        try await save([try entry(tree.b, "Archive/Day1/B.png", rating: .no, ratedAt: at(10))], in: tree.base, tree: tree)
        let inventory = try FolderScanner.discoverInventory(tree.day1)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: tree.day1)
        let spy = Spy()
        let grant = NestedSessionGrant(path: tree.base.path, bookmark: Data(tree.base.path.utf8))
        let before = openDescriptorCount()
        let attempts = 20
        for _ in 0..<attempts {
            let cancel = FolderScanner.CancelFlag()
            // Cancels while the first covered ancestor's sidecar is open.
            let environment = NestedSessionMerge.Environment(
                grants: { [grant] }, grantAccess: fakeGrantAccess(spy), willReadSidecar: { _ in cancel.set() })
            do {
                _ = try await NestedSessionMerge.apply(to: inventory.items, root: tree.day1, rootIdentity: identity,
                    descendants: [], environment: environment, isCancelled: { cancel.isSet })
                XCTFail("expected cancellation")
            } catch is CancellationError {}
        }
        XCTAssertLessThan(openDescriptorCount() - before, attempts / 2)
        XCTAssertEqual(spy.starts, attempts)
        XCTAssertEqual(spy.stops, attempts)
        XCTAssertNil(inventory.items.flatMap(\.individualFiles).first { $0.ratedAt != nil })
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        func append(_ event: String) { lock.withLock { _events.append(event) } }
    }

    func testAncestorSidecarsEnterTheBoundedBatchAsTheyAreRead() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(10))], in: tree.archive, tree: tree)
        try await save([try entry(tree.b, "Archive/Day1/B.png", rating: .no, ratedAt: at(10))], in: tree.base, tree: tree)
        let sizes = try [tree.base, tree.archive].map { try Data(contentsOf: sidecar($0)).count }
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: tree.day1)
        let grant = NestedSessionGrant(path: tree.base.path, bookmark: Data(tree.base.path.utf8))
        let (base, archive) = (tree.base.lastPathComponent, tree.archive.lastPathComponent)

        func merge(maximumBatchBytes: Int) async throws -> [String] {
            let inventory = try FolderScanner.discoverInventory(tree.day1)
            let log = EventLog()
            var environment = NestedSessionMerge.Environment(
                grants: { [grant] }, grantAccess: fakeGrantAccess(Spy()),
                willReadSidecar: { log.append("read \($0.deletingLastPathComponent().lastPathComponent)") })
            environment.maximumBatchBytes = maximumBatchBytes
            environment.didFlushBatch = { log.append("flush \($0)") }
            let summary = try await NestedSessionMerge.apply(to: inventory.items, root: tree.day1, rootIdentity: identity,
                descendants: [], environment: environment, isCancelled: { false })
            XCTAssertEqual(summary, .init(changedFiles: 2, contributingSessions: 2))
            let files = inventory.items.flatMap(\.individualFiles)
            XCTAssertEqual(files.first { $0.id == "A.png" }?.rating, .yes)
            XCTAssertEqual(files.first { $0.id == "B.png" }?.rating, .no)
            return log.events
        }

        // Within the bound, both ancestors share one batch.
        let shared = try await merge(maximumBatchBytes: 64 * 1_024 * 1_024)
        XCTAssertEqual(shared, ["read \(base)", "read \(archive)", "flush \(sizes[0] + sizes[1])"])
        // Each one alone reaches the bound: the first is decoded and released
        // before the second is read.
        let alone = try await merge(maximumBatchBytes: sizes.min()!)
        XCTAssertEqual(alone, ["read \(base)", "flush \(sizes[0])", "read \(archive)", "flush \(sizes[1])"])
    }

    func testDescendantFolderReplacedBeforeItsReadIsSkipped() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10))], in: tree.day1, tree: tree)
        try await save([try entry(tree.d, "D.png", rating: .yes, ratedAt: at(10))], in: tree.day2, tree: tree)
        let inventory = try FolderScanner.discoverInventory(tree.archive)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: tree.archive)
        let day1 = tree.day1, moved = tree.base.appendingPathComponent("Day1-old")
        let environment = NestedSessionMerge.Environment(willReadSidecar: { url in
            guard url.deletingLastPathComponent().lastPathComponent == "Day1" else { return }
            // Same name, same sidecar bytes, different folder.
            try FileManager.default.moveItem(at: day1, to: moved)
            try FileManager.default.copyItem(at: moved, to: day1)
        })
        let summary = try await NestedSessionMerge.apply(to: inventory.items, root: tree.archive, rootIdentity: identity,
            descendants: inventory.sessionSidecarFolders, environment: environment, isCancelled: { false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(summary, .init(changedFiles: 1, contributingSessions: 1))
        let files = inventory.items.flatMap(\.individualFiles)
        XCTAssertNil(files.first { $0.id == "Day1/A.png" }?.ratedAt)
        XCTAssertEqual(files.first { $0.id == "Day2/D.png" }?.rating, .yes)
    }

    // MARK: Exact spellings

    private func metadata(_ store: SessionStore, named name: String) throws -> PhotoFileMetadataSnapshot {
        let file = store.items.flatMap(\.individualFiles).first {
            $0.url.lastPathComponent.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping
        }
        return try XCTUnwrap(file, "missing \(name)").metadataSnapshot
    }

    private func index(_ store: SessionStore, named name: String) throws -> Int {
        try XCTUnwrap(store.items.firstIndex {
            $0.primaryFile.url.lastPathComponent.precomposedStringWithCanonicalMapping
                == name.precomposedStringWithCanonicalMapping
        })
    }

    func testDecomposedSpacedAndReservedNamesMergeInBothDirections() async throws {
        let tree = try makeTree()
        // NFD é, spaces, % and # in both the folder and the file names. A `;`
        // name cannot be saved at all yet (the snapshot validator rebuilds
        // IDs with Swift's URL, which keeps `;`, while the scanner writes %3B).
        let child = tree.archive.appendingPathComponent("E\u{301}te\u{301} #1 50% x")
        let cafe = "Cafe\u{301} #2 %.png", spaced = "b b.png"
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for name in [cafe, spaced] { try FileManager.default.copyItem(at: tree.a, to: child.appendingPathComponent(name)) }

        // Child first: a real session rates the café photo.
        let first = store(tree, spy: Spy())
        try await open(first, child)
        first.rate(.yes, at: try index(first, named: cafe))
        _ = await first.saveSessionForTermination()
        let firstIdle = await first.waitForPersistenceIdleForTesting()
        XCTAssertTrue(firstIdle)

        // Parent after child.
        let parent = store(tree, spy: Spy())
        try await open(parent, tree.archive)
        XCTAssertEqual(try metadata(parent, named: cafe).rating, .yes)
        XCTAssertEqual(parent.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        parent.rate(.no, at: try index(parent, named: spaced))
        _ = await parent.saveSessionForTermination()
        let parentIdle = await parent.waitForPersistenceIdleForTesting()
        XCTAssertTrue(parentIdle)

        // Child after parent, through a recent grant.
        let spy = Spy()
        let reopened = store(tree, spy: spy, recents: [tree.archive])
        try await open(reopened, child)
        XCTAssertEqual(try metadata(reopened, named: spaced).rating, .no)
        XCTAssertEqual(try metadata(reopened, named: cafe).rating, .yes)
        XCTAssertEqual(reopened.nestedSessionMergeSummary, .init(changedFiles: 1, contributingSessions: 1))
        XCTAssertEqual(spy.starts, spy.stops)
    }

    // MARK: Save failure and retry

    // MARK: Council fixes

    func testRenamedPinnedOrRecentParentStillMerges() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(20)),
                        try entry(tree.b, "Day1/B.png", rating: .no, ratedAt: at(20))], in: tree.archive, tree: tree)
        try await pin(tree.archive, tree: tree, realBookmark: true)
        let recentBookmark = try tree.archive.bookmarkData()
        let renamed = tree.base.appendingPathComponent("Archive renamed")
        try FileManager.default.moveItem(at: tree.archive, to: renamed)
        let child = renamed.appendingPathComponent("Day1")
        let before = bytes([renamed])

        // The pin's stored path is stale; its bookmark still finds the parent.
        let pinSpy = Spy()
        let pinned = store(tree, spy: pinSpy)
        try await open(pinned, child)
        XCTAssertEqual(try metadata(pinned, "A.png").rating, .yes)
        XCTAssertEqual(try metadata(pinned, "A.png").ratedAt, at(20))
        XCTAssertEqual(pinned.nestedSessionMergeSummary, .init(changedFiles: 2, contributingSessions: 1))
        XCTAssertEqual(ancestorReads(pinSpy, outside: child), [sidecar(renamed).resolvingSymlinksInPath().path])
        XCTAssertEqual(pinSpy.starts, pinSpy.stops)

        // The same through a recent whose stored path is stale.
        try FileManager.default.removeItem(at: tree.pins)
        try FileManager.default.removeItem(at: sidecar(child))
        try FileManager.default.removeItem(at: tree.backups)
        let recentSpy = Spy()
        let recent = store(tree, spy: recentSpy, recentBookmarks: [(tree.archive.path, recentBookmark)])
        try await open(recent, child)
        XCTAssertEqual(try metadata(recent, "B.png").rating, .no)
        XCTAssertEqual(recent.nestedSessionMergeSummary, .init(changedFiles: 2, contributingSessions: 1))
        XCTAssertEqual(recentSpy.starts, recentSpy.stops)
        XCTAssertEqual(bytes([renamed]), before)
    }

    func testBookmarkResolvingOutsideTheAncestryIsNeverRead() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(20))], in: tree.archive, tree: tree)
        try await save([try entry(tree.d, "D.png", rating: .yes, ratedAt: at(20))], in: tree.day2, tree: tree)
        // Stored path claims the parent; the bookmark resolves to a sibling.
        let spy = Spy()
        let store = store(tree, spy: spy, recentBookmarks: [(tree.archive.path, try tree.day2.bookmarkData())])
        try await open(store, tree.day1)
        XCTAssertNil(try metadata(store, "A.png").ratedAt)
        XCTAssertNil(store.nestedSessionMergeSummary)
        XCTAssertTrue(ancestorReads(spy, outside: tree.day1).isEmpty)
        XCTAssertEqual(spy.starts, 0)
    }

    func testBookmarksOnOtherOrUnknownVolumesAreNeverResolved() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "Day1/A.png", rating: .yes, ratedAt: at(20))], in: tree.archive, tree: tree)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: tree.day1)
        let inventory = try FolderScanner.discoverInventory(tree.day1)
        let local = try XCTUnwrap(NestedSessionMerge.Volume(of: tree.day1))
        // Real bookmarks record the local volume.
        let realBookmark = try tree.archive.bookmarkData()
        XCTAssertEqual(NestedSessionMerge.GrantAccess.live.bookmarkVolume(realBookmark)?.isSame(as: local), true)
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int { lock.withLock { _count } }
            func hit() { lock.withLock { _count += 1 } }
        }
        let otherVolume = Data("other".utf8), unknownVolume = Data("unknown".utf8)
        for (volume, expectedResolves) in [(otherVolume, 0), (unknownVolume, 0), (Data("local".utf8), 1)] {
            let resolves = Counter()
            let spy = Spy()
            let access = NestedSessionMerge.GrantAccess(
                resolve: { _ in resolves.hit(); return tree.archive },
                access: .init(start: { _ in spy.start() }, stop: { _ in spy.stop() }),
                bookmarkVolume: { _ in
                    switch volume {
                    case otherVolume: return .init(uuid: "00000000-0000-0000-0000-000000000000", path: "/Volumes/Share")
                    case unknownVolume: return nil
                    default: return local
                    }
                })
            let summary = try await NestedSessionMerge.apply(
                to: inventory.items, root: tree.day1, rootIdentity: identity, descendants: [],
                environment: .init(grants: { [NestedSessionGrant(path: tree.archive.path, bookmark: realBookmark)] },
                                   grantAccess: access),
                isCancelled: { false })
            XCTAssertEqual(resolves.count, expectedResolves, String(decoding: volume, as: UTF8.self))
            XCTAssertEqual(summary.changedFiles, expectedResolves, String(decoding: volume, as: UTF8.self))
            XCTAssertEqual(spy.starts, spy.stops)
            inventory.items.flatMap(\.individualFiles).forEach {
                $0.restoreMetadata(PhotoFileMetadataSnapshot(fileID: $0.id, rating: .undecided, ratedAt: nil))
            }
        }
        // A retired open resolves nothing.
        let resolves = Counter()
        do {
            _ = try await NestedSessionMerge.apply(
                to: inventory.items, root: tree.day1, rootIdentity: identity, descendants: [],
                environment: .init(grants: { [NestedSessionGrant(path: tree.archive.path, bookmark: realBookmark)] },
                                   grantAccess: .init(resolve: { _ in resolves.hit(); return tree.archive },
                                                      access: .init(start: { _ in true }, stop: { _ in }))),
                isCancelled: { true })
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(resolves.count, 0)
    }

    func testHardLinksCountOncePerPhysicalFile() async throws {
        let tree = try makeTree()
        let link = tree.day1.appendingPathComponent("A link.png")
        XCTAssertEqual(Darwin.link(tree.a.path, link.path), 0)
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10)),
                        try entry(link, "A%20link.png", rating: .yes, ratedAt: at(10)),
                        try entry(tree.b, "B.png", rating: .no, ratedAt: at(10))], in: tree.day1, tree: tree)
        let store = store(tree, spy: Spy())
        try await open(store, tree.archive)
        XCTAssertEqual(try metadata(store, "Day1/A.png").rating, .yes)
        XCTAssertEqual(try metadata(store, "Day1/A%20link.png").rating, .yes)
        XCTAssertEqual(store.nestedSessionMergeSummary, .init(changedFiles: 2, contributingSessions: 1))
        XCTAssertEqual(store.nestedSessionMergeNotice, "Included 2 decisions from 1 earlier folder session.")
    }

    func testReadOnlyRootWarnsAndQuitsAsWithoutNestedSessions() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10))], in: tree.day1, tree: tree)
        let child = bytes([tree.day1])
        try FileManager.default.removeItem(at: sidecar(tree.day1))
        func openReadOnly(withBackup: Bool) async throws -> (SessionStore, SessionPersistence.SaveResult?) {
            try? FileManager.default.removeItem(at: tree.backups)
            try FileManager.default.createDirectory(at: tree.backups, withIntermediateDirectories: true)
            XCTAssertEqual(chmod(tree.backups.path, withBackup ? 0o755 : 0o555), 0)
            XCTAssertEqual(chmod(tree.archive.path, 0o555), 0)
            defer {
                chmod(tree.archive.path, 0o755)
                chmod(tree.backups.path, 0o755)
            }
            let store = store(tree, spy: Spy())
            try await open(store, tree.archive)
            return (store, await store.saveSessionForTermination())
        }
        for withBackup in [true, false] {
            let plain = try await openReadOnly(withBackup: withBackup)
            XCTAssertNil(plain.0.nestedSessionMergeSummary)
            if let bytes = child[tree.day1.path] ?? nil { try bytes.write(to: sidecar(tree.day1)) }
            let merged = try await openReadOnly(withBackup: withBackup)
            try FileManager.default.removeItem(at: sidecar(tree.day1))
            // Merged values and notice, but no new warning and no blocked Quit.
            XCTAssertEqual(try metadata(merged.0, "Day1/A.png").rating, .yes)
            XCTAssertEqual(merged.0.nestedSessionMergeSummary?.rootIsWritable, false)
            XCTAssertNotNil(merged.0.nestedSessionMergeNotice)
            XCTAssertEqual(merged.0.persistenceWarning, plain.0.persistenceWarning, "backup: \(withBackup)")
            XCTAssertNil(plain.1)
            XCTAssertNil(merged.1, "backup: \(withBackup)")
        }
    }

    func testMergedValuesStayDirtyThroughRootSaveFailureAndRetry() async throws {
        let tree = try makeTree()
        try await save([try entry(tree.a, "A.png", rating: .yes, ratedAt: at(10))], in: tree.day1, tree: tree)
        let before = bytes([tree.day1])
        let persistence = FlakySavePersistence(inner: SessionPersistence(backupDirectory: tree.backups))
        let store = store(tree, spy: Spy(), persistence: persistence)
        try await open(store, tree.archive)
        XCTAssertEqual(try metadata(store, "Day1/A.png").rating, .yes)
        XCTAssertNotNil(store.persistenceWarning)
        XCTAssertTrue(store.canRetryPersistence)
        let failedSaves = await persistence.saves
        XCTAssertGreaterThanOrEqual(failedSaves, 1)
        // Dirty: Quit must try again rather than discard the merge.
        let quit = await store.saveSessionForTermination()
        XCTAssertEqual(quit?.canDiscardInMemoryState, false)
        let quitSaves = await persistence.saves
        XCTAssertGreaterThan(quitSaves, failedSaves)
        XCTAssertNil(try? Data(contentsOf: sidecar(tree.archive)))

        await persistence.setFailing(false)
        store.retryPersistence()
        let idle3 = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle3)
        XCTAssertNil(store.persistenceWarning)
        XCTAssertEqual(try saved(tree.archive)["Day1/A.png"]?.rating, Rating.yes.rawValue)
        XCTAssertEqual(try saved(tree.archive)["Day1/A.png"]?.ratedAt, at(10))
        XCTAssertEqual(bytes([tree.day1]), before)
    }
}

private actor FlakySavePersistence: SessionPersistenceClient {
    let inner: SessionPersistence
    private(set) var saves = 0
    private var failing = true

    init(inner: SessionPersistence) { self.inner = inner }

    func setFailing(_ value: Bool) { failing = value }

    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        saves += 1
        if failing { return .failed(.init(sidecar: .permissionDenied, backup: .permissionDenied)) }
        return await inner.save(session, for: folder, sequence: sequence, access: access)
    }

    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?
    ) async -> SessionPersistence.ReadResult {
        await inner.read(for: folder, folderIdentity: folderIdentity,
                         legacySidecarRelocationAuthorization: legacySidecarRelocationAuthorization)
    }
}

private extension Date {
    /// Sidecars store whole-second ISO 8601 dates.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
