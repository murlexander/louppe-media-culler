import Foundation
import ImageIO
import XCTest
@testable import Louppe

/// Regression for the 1.7–1.14 bug where any `;` in a file name blocked
/// saving the whole folder: the scanner spells `;` as `%3B` in file IDs, but
/// the snapshot validator rebuilt IDs with Swift's URL, which keeps `;`.
/// Real folders, real sidecars and backups, and the normal
/// open → rate → autosave → reopen path.
@MainActor
final class SemicolonFileNameSessionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let photos: URL
        let backup: URL
        var sidecar: URL { photos.appendingPathComponent(SessionConstants.sidecarName) }
    }

    private enum WaitError: Error {
        case timedOut(String)
    }

    /// Forwards to the real actor and records each finished autosave.
    private actor RecordingPersistence: SessionPersistenceClient {
        private let disk: SessionPersistence
        private var completed: [(ratings: [String: String], result: SessionPersistence.SaveResult)] = []

        init(backup: URL) {
            disk = SessionPersistence(backupDirectory: backup)
        }

        func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
                  legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?) async
            -> SessionPersistence.ReadResult {
            await disk.read(for: folder, folderIdentity: folderIdentity,
                            legacySidecarRelocationAuthorization: legacySidecarRelocationAuthorization)
        }

        func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
                  access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
            let result = await disk.save(session, for: folder, sequence: sequence, access: access)
            let ratings = Dictionary(uniqueKeysWithValues: session.entries.map { ($0.filename, $0.rating) })
            completed.append((ratings, result))
            return result
        }

        func result(for ratings: [String: String]) -> SessionPersistence.SaveResult? {
            completed.first { $0.ratings == ratings }?.result
        }
    }

    // MARK: Regression

    func testFolderWithSemicolonFileNameSavesAndReopensBothRatings() async throws {
        let fixture = try makeFixture()
        try jpeg().write(to: fixture.photos.appendingPathComponent("a;b.jpg"))
        let persistence = RecordingPersistence(backup: fixture.backup)
        let store = makeStore(fixture, persistence: persistence)
        try await open(store, fixture, expectedItems: 2)
        XCTAssertNotNil(try readSidecar(fixture), "the opening checkpoint must save")

        // The scanner's IDs are unchanged.
        let odd = try index(store, id: "a%3Bb.jpg")
        let plain = try index(store, id: "c.jpg")
        store.rate(.yes, at: odd)
        store.rate(.no, at: plain)
        let ratings = ["a%3Bb.jpg": Rating.yes.rawValue, "c.jpg": Rating.no.rawValue]
        try await wait("rated autosave") { await persistence.result(for: ratings) != nil }
        let autosave = await persistence.result(for: ratings)
        XCTAssertEqual(autosave, .savedToSidecar)
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        XCTAssertEqual(store.sessionSaveStatus, L10n.text("Saved"))
        XCTAssertNil(store.persistenceWarning)
        XCTAssertEqual(try savedRatings(fixture), ["a%3Bb.jpg=yes", "c.jpg=no"])
        XCTAssertEqual(try backupCopies(fixture).count, 1)

        let reopened = makeStore(fixture)
        try await open(reopened, fixture, expectedItems: 2)
        XCTAssertEqual(reopened.items[try index(reopened, id: "a%3Bb.jpg")].rating, .yes)
        XCTAssertEqual(reopened.items[try index(reopened, id: "c.jpg")].rating, .no)
    }

    func testExistingCopiesAreReplacedOnceASemicolonFileAppears() async throws {
        let fixture = try makeFixture()
        let first = makeStore(fixture)
        try await open(first, fixture, expectedItems: 1)
        first.rate(.yes, at: 0)
        _ = await first.saveSessionForTermination()
        let firstIdle = await first.waitForPersistenceIdleForTesting()
        XCTAssertTrue(firstIdle)
        let previousSidecar = try Data(contentsOf: fixture.sidecar)
        let previousBackup = try backupCopies(fixture)

        try jpeg().write(to: fixture.photos.appendingPathComponent("a;b.jpg"))
        let second = makeStore(fixture)
        try await open(second, fixture, expectedItems: 2)
        XCTAssertEqual(second.items[try index(second, id: "c.jpg")].rating, .yes)
        second.rate(.yes, at: try index(second, id: "a%3Bb.jpg"))
        second.rate(.no, at: try index(second, id: "c.jpg"))
        let result = await second.saveSessionForTermination()
        XCTAssertEqual(result, .savedToSidecar)
        let idle = await second.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        XCTAssertNotEqual(try Data(contentsOf: fixture.sidecar), previousSidecar)
        XCTAssertNotEqual(try backupCopies(fixture), previousBackup)
        XCTAssertEqual(try savedRatings(fixture), ["a%3Bb.jpg=yes", "c.jpg=no"])
        XCTAssertGreaterThan(try readSidecar(fixture)?.snapshotGeneration ?? 0,
                             try decode(previousSidecar).snapshotGeneration ?? 0)
    }

    func testSemicolonsInASubfolderAndFileNameSaveAndReopen() async throws {
        let fixture = try makeFixture()
        let folder = fixture.photos.appendingPathComponent("Day;1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg().write(to: folder.appendingPathComponent("x;y.jpg"))
        try jpeg().write(to: folder.appendingPathComponent("z.jpg"))
        let store = makeStore(fixture)
        try await open(store, fixture, expectedItems: 3)
        // An unrelated rating while the `;` files stay unrated must save too.
        store.rate(.no, at: try index(store, id: "c.jpg"))
        let firstSave = await store.saveSessionForTermination()
        XCTAssertEqual(firstSave, .savedToSidecar)
        store.rate(.yes, at: try index(store, id: "Day%3B1/x%3By.jpg"))
        store.rate(.yes, at: try index(store, id: "Day%3B1/z.jpg"))
        let result = await store.saveSessionForTermination()
        XCTAssertEqual(result, .savedToSidecar)
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        XCTAssertEqual(try savedRatings(fixture), ["Day%3B1/x%3By.jpg=yes", "Day%3B1/z.jpg=yes", "c.jpg=no"])

        let reopened = makeStore(fixture)
        try await open(reopened, fixture, expectedItems: 3)
        XCTAssertEqual(reopened.items[try index(reopened, id: "Day%3B1/x%3By.jpg")].rating, .yes)
        XCTAssertEqual(reopened.items[try index(reopened, id: "Day%3B1/z.jpg")].rating, .yes)
        XCTAssertEqual(reopened.items[try index(reopened, id: "c.jpg")].rating, .no)
    }

    // MARK: Compatibility with literal-`;` IDs

    /// 1.7–1.14 accepted only a literal `;` in exact IDs. Schema 3 has no
    /// physical identity to fall back on, so the alias must map by name.
    func testSchema3SidecarWithALiteralSemicolonStillRestores() async throws {
        let fixture = try makeFixture()
        try jpeg().write(to: fixture.photos.appendingPathComponent("a;b.jpg"))
        try write(SessionFile(version: 3, sourcePath: fixture.photos.path, scannedAt: Date(),
                              entries: [SessionEntry(filename: "a;b.jpg", pairedFilename: nil,
                                                     rating: Rating.yes.rawValue, ratedAt: Date()),
                                        SessionEntry(filename: "c.jpg", pairedFilename: nil,
                                                     rating: Rating.no.rawValue, ratedAt: Date())],
                              fileIDEncoding: .percentEncodedFileSystemPath), to: fixture)
        let read = await SessionPersistence(backupDirectory: fixture.backup).read(for: fixture.photos)
        XCTAssertEqual(read.session?.entries.map(\.filename).sorted(), ["a%3Bb.jpg", "c.jpg"])

        let store = makeStore(fixture)
        try await open(store, fixture, expectedItems: 2)
        XCTAssertEqual(store.items[try index(store, id: "a%3Bb.jpg")].rating, .yes)
        XCTAssertEqual(store.items[try index(store, id: "c.jpg")].rating, .no)
        store.rate(.no, at: try index(store, id: "a%3Bb.jpg"))
        let result = await store.saveSessionForTermination()
        XCTAssertEqual(result, .savedToSidecar)
        XCTAssertEqual(try savedRatings(fixture), ["a%3Bb.jpg=no", "c.jpg=no"])
    }

    /// A schema-7 sidecar with the literal spelling, recovery history and a
    /// resolved recovery ID: readable, restored, and re-saved as `%3B`.
    func testSchema7SidecarWithLiteralSemicolonsRestoresAndSaves() async throws {
        let fixture = try makeFixture()
        let odd = fixture.photos.appendingPathComponent("a;b.jpg")
        try jpeg().write(to: odd)
        let identity = try FileOperationJournal.captureIdentity(at: odd)
        let current = SessionEntry(filename: "a;b.jpg", pairedFilename: nil, rating: Rating.yes.rawValue,
                                   ratedAt: Date(), fileIdentity: identity)
        let history = SessionRecoveryEntry(entry: SessionEntry(filename: "a;b.jpg", pairedFilename: nil,
                                                               rating: Rating.no.rawValue, ratedAt: Date(),
                                                               fileIdentity: identity),
                                           resolvedFileID: "a;b.jpg")
        try write(SessionFile(version: SessionConstants.currentSchemaVersion, sourcePath: fixture.photos.path,
                              scannedAt: Date(), entries: [current], fileIDEncoding: .percentEncodedFileSystemPath,
                              snapshotGeneration: 1, recoveryEntries: [history]), to: fixture)
        let read = await SessionPersistence(backupDirectory: fixture.backup).read(for: fixture.photos)
        let session = try XCTUnwrap(read.session)
        XCTAssertEqual(session.entries.map(\.filename), ["a%3Bb.jpg"])
        XCTAssertEqual(session.recoveryEntries?.first?.entry.filename, "a%3Bb.jpg")
        XCTAssertEqual(session.recoveryEntries?.first?.resolvedFileID, "a%3Bb.jpg")

        let store = makeStore(fixture)
        try await open(store, fixture, expectedItems: 2)
        XCTAssertEqual(store.items[try index(store, id: "a%3Bb.jpg")].rating, .yes)
        XCTAssertEqual(store.sessionSaveStatus, L10n.text("Saved"))
        store.rate(.no, at: try index(store, id: "c.jpg"))
        let result = await store.saveSessionForTermination()
        XCTAssertEqual(result, .savedToSidecar)
        let saved = try XCTUnwrap(readSidecar(fixture))
        XCTAssertEqual(saved.entries.map { "\($0.filename)=\($0.rating)" }.sorted(), ["a%3Bb.jpg=yes", "c.jpg=no"])
        XCTAssertEqual(saved.recoveryEntries?.map(\.id), [history.id])
        XCTAssertEqual(saved.recoveryEntries?.first?.entry.filename, "a%3Bb.jpg")
    }

    /// A literal-`;` backup (sidecar gone) is read the same way.
    func testLiteralSemicolonBackupStillRestores() async throws {
        let fixture = try makeFixture()
        let odd = fixture.photos.appendingPathComponent("a;b.jpg")
        try jpeg().write(to: odd)
        let first = makeStore(fixture)
        try await open(first, fixture, expectedItems: 2)
        first.rate(.yes, at: try index(first, id: "a%3Bb.jpg"))
        _ = await first.saveSessionForTermination()
        let idle = await first.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        // Rewrite the backup in the old spelling and remove the sidecar.
        let backups = try backupFiles(fixture)
        XCTAssertEqual(backups.count, 1)
        var old = try decode(Data(contentsOf: backups[0]))
        old.entries = old.entries.map { var entry = $0; entry.filename = entry.filename.replacingOccurrences(of: "%3B", with: ";"); return entry }
        XCTAssertTrue(old.entries.contains { $0.filename == "a;b.jpg" })
        try encode(old).write(to: backups[0])
        try FileManager.default.removeItem(at: fixture.sidecar)

        let reopened = makeStore(fixture)
        try await open(reopened, fixture, expectedItems: 2)
        XCTAssertEqual(reopened.items[try index(reopened, id: "a%3Bb.jpg")].rating, .yes)
    }

    // MARK: Guard stays strict

    func testLiteralAndEncodedSpellingsOfOneFileCannotBothBeSaved() async throws {
        let fixture = try makeFixture()
        let odd = fixture.photos.appendingPathComponent("a;b.jpg")
        try jpeg().write(to: odd)
        let identity = try FileOperationJournal.captureIdentity(at: odd)
        let entries = ["a;b.jpg", "a%3Bb.jpg"].map {
            SessionEntry(filename: $0, pairedFilename: nil, rating: Rating.yes.rawValue, ratedAt: Date(),
                         fileIdentity: identity)
        }
        let disk = SessionPersistence(backupDirectory: fixture.backup)
        let result = await disk.save(SessionFile(version: SessionConstants.currentSchemaVersion,
                                                 sourcePath: fixture.photos.path, scannedAt: Date(),
                                                 entries: entries, fileIDEncoding: .percentEncodedFileSystemPath),
                                     for: fixture.photos, sequence: 1)
        XCTAssertEqual(result, .rejectedInvalidSnapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sidecar.path))
    }

    /// A file literally named `a%3Bb.jpg` stays a different file from `a;b.jpg`.
    func testLiteralPercentNameStaysDistinctFromSemicolonName() async throws {
        let fixture = try makeFixture()
        try jpeg().write(to: fixture.photos.appendingPathComponent("a;b.jpg"))
        try jpeg().write(to: fixture.photos.appendingPathComponent("a%3Bb.jpg"))
        let store = makeStore(fixture)
        try await open(store, fixture, expectedItems: 3)
        store.rate(.yes, at: try index(store, id: "a%3Bb.jpg"))
        store.rate(.no, at: try index(store, id: "a%253Bb.jpg"))
        let result = await store.saveSessionForTermination()
        XCTAssertEqual(result, .savedToSidecar)
        XCTAssertEqual(try savedRatings(fixture), ["a%253Bb.jpg=no", "a%3Bb.jpg=yes", "c.jpg=undecided"])
        let reopened = makeStore(fixture)
        try await open(reopened, fixture, expectedItems: 3)
        XCTAssertEqual(reopened.items[try index(reopened, id: "a%3Bb.jpg")].rating, .yes)
        XCTAssertEqual(reopened.items[try index(reopened, id: "a%253Bb.jpg")].rating, .no)
    }

    func testCanonicalExactFileIDAcceptsOnlyTheScannerAndLegacySemicolonSpellings() {
        let accepted: [String: String] = [
            "a%3Bb.jpg": "a%3Bb.jpg",
            "a;b.jpg": "a%3Bb.jpg",
            "Day%3B1/x%3By.jpg": "Day%3B1/x%3By.jpg",
            "Day;1/x;y.jpg": "Day%3B1/x%3By.jpg",
            "a%253Bb.jpg": "a%253Bb.jpg",
            "a%20b.jpg": "a%20b.jpg",
            "ae%CC%81b.jpg": "ae%CC%81b.jpg",
            "a:b.jpg": "a:b.jpg",
        ]
        for (id, key) in accepted {
            XCTAssertEqual(SessionPersistence.canonicalExactFileID(id), key, id)
        }
        for id in ["Day%3B1/x;y.jpg", "a%3bb.jpg", "a b.jpg", "a%2Fb.jpg", "a%00b.jpg", "a%E5b.jpg",
                   "a%EF%BF%BDb.jpg".replacingOccurrences(of: "%EF%BF%BD", with: "\u{FFFD}"),
                   "a%3Gb.jpg", "a%3", "./a.jpg", "a/../b.jpg", "a%25%3", "é.jpg"] {
            XCTAssertNil(SessionPersistence.canonicalExactFileID(id), id)
        }
    }

    /// The no-URL fast path must give exactly the scanner's spelling, and
    /// refuse exactly what the full check refuses.
    func testFastPathMatchesTheScannerSpellingForUnreservedNames() {
        func scannerSpelling(_ id: String) -> String {
            ("/" + id).withCString {
                String(FolderScanner.scannerURL(fileSystemRepresentation: $0, isDirectory: false)
                    .path(percentEncoded: true).dropFirst())
            }
        }
        let unreserved = (0x21...0x7E).compactMap(Unicode.Scalar.init).map(String.init).filter {
            $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } || "-._~".contains($0)
        }
        XCTAssertEqual(unreserved.count, 66)
        for character in unreserved {
            for id in ["a\(character)b.jpg", "Day\(character)1/x\(character).jpg", "\(character)\(character)\(character)"] {
                XCTAssertEqual(scannerSpelling(id), id, id)
                XCTAssertEqual(SessionPersistence.canonicalExactFileID(id), id, id)
            }
        }
        for id in ["", ".", "..", "a/./b", "a/../b", "a//b", "a/", "/a", "./a", "a/.."] {
            XCTAssertNil(SessionPersistence.canonicalExactFileID(id), id)
        }
        for id in ["...", "a/.../b", ".hidden", "a..b", "~/x"] {
            XCTAssertEqual(SessionPersistence.canonicalExactFileID(id), id, id)
        }
    }

    // MARK: Other characters

    /// The research survey: every other embeddable printable ASCII character,
    /// plus the spellings that once needed care, saves and reopens.
    func testOddFileNameCharactersSaveAndReopen() async throws {
        let listed = [";", "%", "#", "?", "[", "]", "@", ":", "+", "&", "=", ",", " ", "e\u{0301}", "🙂"]
        let printable = (32...126).compactMap(Unicode.Scalar.init)
            .filter { !CharacterSet.alphanumerics.contains($0) && $0 != "/" }
            .map(String.init)
            .filter { !listed.contains($0) }
        let cases = listed + printable + ["%3B", "\u{00E9}"]
        XCTAssertEqual(cases.count, 36)
        for characters in cases {
            let name = "a\(characters)b.jpg"
            let fixture = try makeFixture()
            try jpeg().write(to: fixture.photos.appendingPathComponent(name))
            let store = makeStore(fixture)
            try await open(store, fixture, expectedItems: 2)
            let odd = try XCTUnwrap(store.items.firstIndex { $0.primaryURL.lastPathComponent == name }, name)
            let oddID = store.items[odd].primaryFile.id
            store.rate(.yes, at: odd)
            store.rate(.no, at: try index(store, id: "c.jpg"))
            let result = await store.saveSessionForTermination()
            XCTAssertEqual(result, .savedToSidecar, name)
            let idle = await store.waitForPersistenceIdleForTesting()
            XCTAssertTrue(idle, name)
            XCTAssertEqual(store.sessionSaveStatus, L10n.text("Saved"), name)
            XCTAssertEqual(try savedRatings(fixture), ["\(oddID)=yes", "c.jpg=no"].sorted(), name)

            let reopened = makeStore(fixture)
            try await open(reopened, fixture, expectedItems: 2)
            XCTAssertEqual(reopened.items.first { $0.primaryFile.id == oddID }?.rating, .yes, name)
            XCTAssertEqual(reopened.items.first { $0.primaryFile.id == "c.jpg" }?.rating, .no, name)
        }
    }

    // MARK: Helpers

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-Semicolon-\(UUID())", isDirectory: true)
        let fixture = Fixture(root: root, photos: root.appendingPathComponent("Photos", isDirectory: true),
                              backup: root.appendingPathComponent("Backup", isDirectory: true))
        try FileManager.default.createDirectory(at: fixture.photos, withIntermediateDirectories: true)
        try jpeg().write(to: fixture.photos.appendingPathComponent("c.jpg"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return fixture
    }

    private func jpeg() throws -> Data {
        let path = URL(fileURLWithPath: "Packaging/AppIcon/AppIcon.iconset/icon_16x16.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(path as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeStore(_ fixture: Fixture, persistence: (any SessionPersistenceClient)? = nil) -> SessionStore {
        SessionStore(persistence: persistence ?? SessionPersistence(backupDirectory: fixture.backup),
                     saveTrailingDelay: 0.05, saveMaximumDelay: 0.25)
    }

    private func open(_ store: SessionStore, _ fixture: Fixture, expectedItems: Int) async throws {
        store.openFolder(fixture.photos)
        try await wait("ready session with \(expectedItems) items") {
            guard case .ready = store.phase else { return false }
            return !store.isSessionTransitioning && store.items.count == expectedItems
        }
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
    }

    private func index(_ store: SessionStore, id: String) throws -> Int {
        try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == id }, "missing \(id)")
    }

    private func wait(_ description: String, until predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut(description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func decode(_ data: Data) throws -> SessionFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionFile.self, from: data)
    }

    private func encode(_ session: SessionFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(session)
    }

    /// Exact bytes as an earlier version could have left them.
    private func write(_ session: SessionFile, to fixture: Fixture) throws {
        try encode(session).write(to: fixture.sidecar)
    }

    private func readSidecar(_ fixture: Fixture) throws -> SessionFile? {
        guard FileManager.default.fileExists(atPath: fixture.sidecar.path) else { return nil }
        return try decode(Data(contentsOf: fixture.sidecar))
    }

    private func savedRatings(_ fixture: Fixture) throws -> [String] {
        try XCTUnwrap(readSidecar(fixture)).entries.map { "\($0.filename)=\($0.rating)" }.sorted()
    }

    private func backupFiles(_ fixture: Fixture) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: fixture.backup.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: fixture.backup, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func backupCopies(_ fixture: Fixture) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: backupFiles(fixture).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
