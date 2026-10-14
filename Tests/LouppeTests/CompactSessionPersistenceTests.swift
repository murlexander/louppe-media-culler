import Foundation
import XCTest
@testable import Louppe

@MainActor
final class CompactSessionPersistenceTests: XCTestCase {
    func testProductionEncodingIsCompactSortedDeterministicAndPreservesEverySchemaField() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var session = try makeSession(fixture)
        let persistence = SessionPersistence(backupDirectory: fixture.backups)
        let saved = await persistence.save(session, for: fixture.photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        session.snapshotGeneration = 1
        let bytes = try Data(contentsOf: fixture.sidecar)
        let expected = try SessionPersistence.encodeSnapshot(session)
        XCTAssertEqual(bytes, expected)
        XCTAssertFalse(bytes.contains(0x0A), "Formatting must not add indentation or line breaks.")
        XCTAssertEqual(try SessionPersistence.encodeSnapshot(session), expected)
        let sorted = JSONEncoder()
        sorted.dateEncodingStrategy = .iso8601
        sorted.outputFormatting = [.sortedKeys]
        XCTAssertEqual(bytes, try sorted.encode(session))
        sorted.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertLessThan(bytes.count, try sorted.encode(session).count)
        let reopened = await SessionPersistence(backupDirectory: fixture.backups).read(for: fixture.photos)
        XCTAssertTrue(reopened.problems.isEmpty)
        let decoded = try XCTUnwrap(reopened.session)
        XCTAssertEqual(try SessionPersistence.encodeSnapshot(decoded), expected,
                       "All identities, metadata timestamps, origin bytes, proof and recovery history must round-trip.")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: fixture.backups, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    func testCompactEncoderPreservesLegacyPairAndAbsentSchemaMarkers() throws {
        let session = SessionFile(
            version: 1, sourcePath: "/private/tmp/LouppeLegacy", scannedAt: Date(timeIntervalSince1970: 10),
            entries: [.init(filename: "A.RAF", pairedFilename: "A.JPG", rating: Rating.yes.rawValue,
                            ratedAt: Date(timeIntervalSince1970: 20))]
        )
        let bytes = try SessionPersistence.encodeSnapshot(session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionFile.self, from: bytes)
        XCTAssertEqual(decoded.entries.first?.pairedFilename, "A.JPG")
        XCTAssertNil(decoded.fileIDEncoding)
        XCTAssertNil(decoded.snapshotGeneration)
        XCTAssertNil(decoded.recoveryEntries)
        XCTAssertEqual(try SessionPersistence.encodeSnapshot(decoded), bytes)
    }

    func testCompactSnapshotByteCeilingStillFailsBeforeWritingAndAllowsBoundarySize() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try makeSession(fixture)
        var expected = session
        expected.snapshotGeneration = 1
        let bytes = try SessionPersistence.encodeSnapshot(expected)
        let tooSmall = SessionPersistence(backupDirectory: fixture.backups,
                                          maximumSnapshotBytesForTesting: bytes.count - 1)
        let rejected = await tooSmall.save(session, for: fixture.photos, sequence: 1)
        XCTAssertEqual(rejected, .failed(.init(sidecar: .snapshotTooLarge, backup: .snapshotTooLarge)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backups.path))
        let boundary = SessionPersistence(backupDirectory: fixture.backups,
                                          maximumSnapshotBytesForTesting: bytes.count)
        let saved = await boundary.save(session, for: fixture.photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecar), bytes)
    }

    func testCompactSaveRetainsExactByteCASAgainstWhitespaceOnlyExternalEdits() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try makeSession(fixture)
        let persistence = SessionPersistence(backupDirectory: fixture.backups)
        let saved = await persistence.save(session, for: fixture.photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        let read = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(read.access)
        let decoded = try XCTUnwrap(read.session)
        let pretty = JSONEncoder()
        pretty.dateEncodingStrategy = .iso8601
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        let externallyChanged = try pretty.encode(decoded)
        try externallyChanged.write(to: fixture.sidecar, options: .atomic)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: fixture.backups, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        let backupBefore = try Data(contentsOf: backup)
        let conflict = await persistence.save(decoded, for: fixture.photos, sequence: 2, access: access)
        XCTAssertEqual(conflict, .sidecarChanged)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecar), externallyChanged)
        XCTAssertEqual(try Data(contentsOf: backup), backupBefore)
    }

    private struct Fixture {
        let root: URL
        let photos: URL
        let backups: URL
        let original: URL
        var sidecar: URL { photos.appendingPathComponent(SessionConstants.sidecarName) }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/LouppeCompactPersistence-\(UUID())")
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let original = photos.appendingPathComponent("A.JPG")
        try Data([0, 1, 2, 3]).write(to: original)
        return Fixture(root: root, photos: photos, backups: root.appendingPathComponent("Backups"),
                       original: original)
    }

    private func makeSession(_ fixture: Fixture) throws -> SessionFile {
        let entry = SessionEntry(
            filename: "A.JPG", pairedFilename: nil, rating: Rating.no.rawValue,
            ratedAt: Date(timeIntervalSince1970: 100), stars: .four,
            starsChangedAt: Date(timeIntervalSince1970: 101), colorLabel: .purple,
            colorChangedAt: Date(timeIntervalSince1970: 102),
            fileIdentity: try FileOperationJournal.captureIdentity(at: fixture.original),
            contentSHA256: String(repeating: "ab", count: 32),
            organizationOriginFolderPathBytes: Data("Original/\u{00E9}".utf8)
        )
        var empty = entry
        empty.filename = "Unrated.JPG"
        empty.rating = Rating.undecided.rawValue
        empty.ratedAt = nil
        empty.stars = nil
        empty.starsChangedAt = nil
        empty.colorLabel = nil
        empty.colorChangedAt = nil
        empty.contentSHA256 = nil
        empty.organizationOriginFolderPathBytes = Data()
        return SessionFile(
            version: SessionConstants.currentSchemaVersion, sourcePath: fixture.photos.path,
            scannedAt: Date(timeIntervalSince1970: 200), entries: [entry, empty],
            fileIDEncoding: .percentEncodedFileSystemPath,
            recoveryEntries: [
                .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, entry: entry),
                .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, entry: entry,
                      resolvedFileID: "Restored.JPG"),
            ]
        )
    }
}
