import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Louppe

/// Frozen document envelopes/field names from v1.14.0, not current writers.
/// Only physical identities and bookmark authority come from disposable files.
@MainActor
final class ReleaseUpgradeCompatibilityTests: XCTestCase {
    func test114PinsAndNavigationLoadWithoutRewritingOrRenewingAccess() async throws {
        let fixture = try UpgradeFixture()
        defer { fixture.remove() }
        let pins = fixture.pins()
        let snapshot = await pins.refresh()
        XCTAssertNil(snapshot.message)
        XCTAssertEqual(snapshot.folders.map(\.id), [fixture.pinID])
        XCTAssertEqual(snapshot.folders.first?.availability, .available)
        let position = try await pins.position(for: fixture.identity)
        XCTAssertEqual(position, fixture.position)
        let (request, _) = try await pins.prepareOpen(id: fixture.pinID)
        XCTAssertEqual(request.authorityURL, fixture.source)
        XCTAssertEqual(request.expectedIdentity, fixture.identity)
        XCTAssertEqual(try Data(contentsOf: fixture.pinDocument), fixture.pinBytes)

        let navigation = ArchiveNavigationPersistence(fileURL: fixture.navigationDocument)
        let loaded = try await navigation.load(for: fixture.identity)
        XCTAssertEqual(loaded?.selectedFolderID, "DCIM")
        XCTAssertEqual(loaded?.expandedFolderIDs, ["", "DCIM"])
        XCTAssertEqual(loaded?.position(for: "DCIM"), fixture.position)
        let index = ArchiveFolderIndex(root: fixture.source, directories: [
            .init(id: "", parentID: nil, name: "Card", identity: fixture.rootFileIdentity),
            .init(id: "DCIM", parentID: "", name: "DCIM", identity: fixture.directoryIdentity)
        ], items: [])
        XCTAssertEqual(loaded?.reconciled(with: index), loaded)
        XCTAssertEqual(try Data(contentsOf: fixture.navigationDocument), fixture.navigationBytes)
        // Exercise a subsequent transaction as well as initial decoding.
        let next = ArchiveNavigationMemory(index: index)
        try await navigation.save(next, for: fixture.identity)
        let reopened = try await ArchiveNavigationPersistence(fileURL: fixture.navigationDocument).load(for: fixture.identity)
        XCTAssertEqual(reopened, next)
        XCTAssertEqual(try Data(contentsOf: fixture.navigationDocument.appendingPathExtension("previous")), fixture.navigationBytes)
    }

    func test114SchemaSevenRestoresDecisionsProofOriginsAndHistoryWithoutConfirmation() async throws {
        let fixture = try UpgradeFixture()
        defer { fixture.remove() }
        let sidecar = fixture.source.appendingPathComponent(".louppe_session.json")
        let digest = SHA256.hash(data: fixture.mediaBytes).map { String(format: "%02x", $0) }.joined()
        let entry: [String: Any] = [
            "filename": "DCIM/PHOTO.JPG", "rating": "yes", "ratedAt": "2026-11-01T12:00:00Z",
            "stars": 4, "starsChangedAt": "2026-11-01T12:01:00Z", "colorLabel": "purple", "colorChangedAt": "2026-11-01T12:02:00Z",
            "fileIdentity": try UpgradeFixture.json(fixture.fileIdentity), "contentSHA256": digest,
            "organizationOriginFolderPathBytes": Data("DCIM".utf8).base64EncodedString()
        ]
        let recoveryID = UUID()
        let bytes = try UpgradeFixture.data([
            "version": 7, "sourcePath": fixture.source.path, "scannedAt": "2026-11-01T12:03:00Z",
            "fileIDEncoding": "percentEncodedFileSystemPath", "snapshotGeneration": 19,
            "entries": [entry],
            "recoveryEntries": [["id": recoveryID.uuidString, "entry": entry, "resolvedFileID": "DCIM/PHOTO.JPG"]]
        ])
        try bytes.write(to: sidecar)
        let persistence = SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("Backups"))
        let read = await persistence.read(for: fixture.source)
        XCTAssertNil(read.blockingMessage)
        XCTAssertNotNil(read.access)
        let item = PhotoItem(primaryFile: PhotoFile(id: "DCIM/PHOTO.JPG", url: fixture.media,
            captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: Int64(fixture.mediaBytes.count),
            scannedIdentity: fixture.fileIdentity))
        let restored = try SessionOpeningRestoration.prepare(scanned: [item], url: fixture.source,
            persistenceResult: read, replaceSavedSession: false)
        XCTAssertFalse(restored.requiresNewSessionConfirmation)
        XCTAssertFalse(restored.legacySessionNeedsConfirmation)
        XCTAssertFalse(restored.hasIdentityConflicts)
        XCTAssertEqual(restored.items.first?.rating, .yes)
        XCTAssertEqual(restored.items.first?.primaryFile.starRating, .four)
        XCTAssertEqual(restored.items.first?.primaryFile.colorLabel, .purple)
        XCTAssertEqual(restored.sessionContentProofs[item.id]?.sha256, digest)
        XCTAssertEqual(restored.restoredOrganizationOrigins[item.id], Data("DCIM".utf8))
        XCTAssertEqual(restored.sessionRecoveryEntries.map(\.id), [recoveryID])
        XCTAssertEqual(restored.sessionRecoveryEntries.first?.resolvedFileID, item.id)
        XCTAssertEqual(read.session?.snapshotGeneration, 19)
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
    }

    func test114PreferenceKeysKeepReviewChoicesAndIndependentPhotosConsent() throws {
        let domain = "LouppeUpgrade-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let prior: [String: Any] = [
            "review.advancesAfterDecision": false, "review.defaultSortKey": "name",
            "review.defaultSortAscending": false, "review.defaultGroupingEnabled": false,
            "review.defaultView": "grid", "photosReview.allowNetworkImages": true,
            "photosReview.allowNetworkOriginals": false
        ]
        defaults.setPersistentDomain(prior, forName: domain)
        XCTAssertEqual(ReviewPreferences.load(from: defaults), .init(advancesAfterDecision: false,
            defaultSort: .init(key: .name, ascending: false), isGroupingEnabled: false, defaultView: .grid))
        XCTAssertEqual(PhotosNetworkPreferences.load(from: defaults), .init(reviewImages: true, originals: false))
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(defaults.persistentDomain(forName: domain))).isEqual(to: prior))
    }

    func testTaggedRAWJPEGAndEditedXMPStillCopyFromOriginalAndCopiedCardLayouts() async throws {
        let fixture = try UpgradeFixture()
        defer { fixture.remove() }
        let raw = fixture.media.deletingPathExtension().appendingPathExtension("NEF")
        try Data("disposable RAW original".utf8).write(to: raw)
        let tags = try PropertyListSerialization.data(fromPropertyList: ["Photographer review"], format: .binary, options: 0)
        XCTAssertEqual(tags.withUnsafeBytes {
            setxattr(fixture.media.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packet = try Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/XMP/universal-unknown.xmp"))
        let sidecar = raw.deletingPathExtension().appendingPathExtension("xmp")
        try packet.write(to: sidecar)
        let copiedCard = fixture.root.appendingPathComponent("CopiedCard")
        try FileManager.default.copyItem(at: fixture.source, to: copiedCard)
        // This is an APFS folder-copy fixture, not a claim about another volume.
        for (index, card) in [fixture.source, copiedCard].enumerated() {
            let destination = fixture.root.appendingPathComponent("Export-\(index)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let selected = try ["JPG", "NEF"].map { ext in
                let url = card.appendingPathComponent("DCIM/PHOTO.\(ext)")
                let identity = try FileOperationJournal.captureIdentity(at: url)
                return PhotoItem(primaryFile: PhotoFile(id: "DCIM/PHOTO.\(ext)", url: url,
                    captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: identity.logicalSize ?? 0,
                    scannedIdentity: identity, rating: .yes, starRating: .four, colorLabel: .purple))
            }
            let plan = try await XMPExportPlanner.prepare(selected: selected, familyContextItems: selected,
                profile: .universal, visibleDecisionKeywords: true, allowExternalLabelReplacement: true)
            let result = await Task.detached {
                ExportWorker.copy(selected, to: destination, xmpPlan: plan,
                    journalDirectory: fixture.root.appendingPathComponent("Operations-\(index)"), progress: { _, _ in })
            }.value
            XCTAssertNil(result.failureMessage)
            XCTAssertFalse(result.cancelled)
            XCTAssertEqual(result.failedPhotos, 0)
            XCTAssertFalse(result.requiresRecovery)
            for item in selected {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(item.primaryURL.lastPathComponent)),
                    try Data(contentsOf: item.primaryURL))
            }
            XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("DCIM/PHOTO.xmp")), packet)
            try XMPFieldMapping.verify(packet: Data(contentsOf: destination.appendingPathComponent("PHOTO.xmp")),
                metadata: .init(decision: .yes, stars: .four, colorLabel: .purple, profile: .universal,
                    visibleDecisionKeywords: true, allowExternalLabelRemoval: true))
        }
    }

    func testChildHeldPinAndNavigationLocksTimeoutAndCrashReleasesStaleFiles() async throws {
        let fixture = try UpgradeFixture()
        defer { fixture.remove() }
        for isPin in [true, false] {
            let document = isPin ? fixture.pinDocument : fixture.navigationDocument
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = ["-e", "$|=1; open(my $f, '>>', $ARGV[0]) or die $!; flock($f, 2) or die $!; print qq(locked\\n); sleep 30;", document.appendingPathExtension("lock").path]
            let output = Pipe()
            child.standardOutput = output
            try child.run()
            defer {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }
            let ready = await Task.detached { output.fileHandleForReading.availableData }.value
            XCTAssertEqual(String(data: ready, encoding: .utf8), "locked\n")
            let start = ContinuousClock.now
            let heartbeat = expectation(description: "Main actor remains responsive during lock contention")
            let tick = Task { @MainActor in
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertLessThan(start.duration(to: .now), .seconds(1), "The main actor must run before the two-second timeout")
                heartbeat.fulfill()
            }
            let pins = fixture.pins()
            let navigation = ArchiveNavigationPersistence(fileURL: fixture.navigationDocument)
            let old = try Data(contentsOf: document)
            do {
                if isPin { _ = try await pins.savePosition(fixture.position, for: fixture.identity) }
                else {
                    let loaded = try await navigation.load(for: fixture.identity)
                    let memory = try XCTUnwrap(loaded)
                    try await navigation.save(memory, for: fixture.identity)
                }
                XCTFail("Another process owns this transaction")
            } catch DurableFileIO.IOError.system(let operation, _, let code) {
                XCTAssertEqual(operation, "wait for persistence lock")
                XCTAssertEqual(code, EWOULDBLOCK)
            }
            XCTAssertLessThan(start.duration(to: .now), .seconds(5))
            await fulfillment(of: [heartbeat], timeout: 1)
            try await tick.value
            XCTAssertEqual(try Data(contentsOf: document), old)
            kill(child.processIdentifier, SIGKILL)
            await Task.detached { child.waitUntilExit() }.value
            // The surviving lock *file* must not preserve a crashed owner's lock.
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.appendingPathExtension("lock").path))
            if isPin { _ = try await pins.savePosition(fixture.position, for: fixture.identity) }
            else {
                let loaded = try await navigation.load(for: fixture.identity)
                let memory = try XCTUnwrap(loaded)
                try await navigation.save(memory, for: fixture.identity)
            }
        }
    }

}

private struct UpgradeFixture {
    let root: URL
    let source: URL
    let media: URL
    let rootFileIdentity: FileOperationJournal.FileIdentity
    let directoryIdentity: FileOperationJournal.FileIdentity
    let fileIdentity: FileOperationJournal.FileIdentity
    let identity: PinnedFolderIdentity
    let position: PinnedFolderPosition
    let pinID = UUID()
    let pinDocument: URL
    let navigationDocument: URL
    let pinBytes: Data
    let navigationBytes: Data
    let mediaBytes = Data("disposable camera original".utf8)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/LouppeUpgrade-\(UUID())", isDirectory: true)
        source = root.appendingPathComponent("Card")
        let directory = source.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        media = directory.appendingPathComponent("PHOTO.JPG")
        try mediaBytes.write(to: media)
        rootFileIdentity = try FileOperationJournal.captureIdentity(at: source)
        directoryIdentity = try FileOperationJournal.captureIdentity(at: directory)
        fileIdentity = try FileOperationJournal.captureIdentity(at: media)
        identity = PinnedFolderIdentity(source: try .capture(at: source))
        let anchor = PinnedFolderFileAnchor(physicalFileID: "DCIM/PHOTO.JPG", identity: fileIdentity)
        position = .init(current: anchor, browser: .init(anchor: anchor, topOffset: 12), grid: .init(anchor: anchor, topOffset: 35))
        let storage = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        pinDocument = storage.appendingPathComponent("PinnedFolders.json")
        navigationDocument = storage.appendingPathComponent("ArchiveNavigation.json")
        pinBytes = try Self.data(["version": 1, "records": [[
            "id": pinID.uuidString, "identity": try Self.json(identity), "name": "Card", "path": source.path,
            "bookmark": Data("existing-114-bookmark".utf8).base64EncodedString(), "isPinned": true,
            "position": try Self.json(position), "updated": 100.0
        ]]])
        navigationBytes = try Self.data(["version": 1, "records": [[
            "root": try Self.json(identity), "memory": [
                "selectedFolderID": "DCIM", "includesDescendants": true, "expandedFolderIDs": ["", "DCIM"],
                "entries": [["folderID": "DCIM", "directoryIdentity": try Self.json(directoryIdentity), "position": try Self.json(position)]],
                "directoryEvidence": [["folderID": "", "identity": try Self.json(rootFileIdentity)],
                                      ["folderID": "DCIM", "identity": try Self.json(directoryIdentity)]]
            ]
        ]]])
        try pinBytes.write(to: pinDocument)
        try navigationBytes.write(to: navigationDocument)
    }

    func pins() -> PinnedFoldersPersistence {
        PinnedFoldersPersistence(storageDirectory: pinDocument.deletingLastPathComponent(), operations: .init(
            resolve: { _ in .init(url: source, isStale: false) },
            create: { _ in XCTFail("A working 1.14 bookmark must not need renewal"); throw POSIXError(.EIO) },
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            access: .init(start: { _ in true }, stop: { _ in })))
    }

    static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    static func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
