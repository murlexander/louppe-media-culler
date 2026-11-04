import Darwin
import Foundation
import XCTest
@testable import Louppe

/// Opt-in acceptance on a mounted disposable image, with production-style
/// journals on the local system volume. Ordinary test runs skip these checks.
/// LOUPPE_FILE_VOLUME_ROOT must be a Louppe-named mount under /Volumes;
/// LOUPPE_FILE_VOLUME_FS is its expected statfs name (apfs or exfat).
final class FileVolumeAcceptanceTests: XCTestCase {
    func testExclusiveRenameCapabilityDistinguishesUnknownFromUnsupported() {
        let flag = UInt32(VOL_CAP_INT_RENAME_EXCL)
        XCTAssertTrue(ExportDestinationValidator.exclusiveRenameIsUnsupported(capabilities: 0, valid: flag))
        XCTAssertFalse(ExportDestinationValidator.exclusiveRenameIsUnsupported(capabilities: flag, valid: flag))
        XCTAssertFalse(ExportDestinationValidator.exclusiveRenameIsUnsupported(capabilities: 0, valid: 0))
    }

    func testNoOverwriteAndDetectedStoragePolicy() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = try media("SOURCE.JPG", in: fixture.photos)
        let target = fixture.destination.appendingPathComponent("SOURCE.JPG")
        let foreign = Data("existing destination".utf8)
        try foreign.write(to: target)
        XCTAssertThrowsError(try DurableFileIO.renameWithoutOverwrite(
            from: source, to: target,
            strategy: fixture.safety.noOverwriteRenameStrategy
        ))
        XCTAssertEqual(try Data(contentsOf: source), Data("SOURCE.JPG".utf8))
        XCTAssertEqual(try Data(contentsOf: target), foreign)
        if fixture.safety.usesReducedDirectoryDurability {
            try SourceOrganizationWorker.verifyExFATMoveCompatibilityForTesting(in: fixture.photos)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.photos.path), ["SOURCE.JPG"])
        }
    }

    func testCopyPreservesExistingDestinationAndOriginal() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = try media("PHOTO.JPG", in: fixture.photos)
        let target = fixture.destination.appendingPathComponent("PHOTO.JPG")
        let foreign = Data("existing destination".utf8)
        try foreign.write(to: target)
        let item = makeItem(source)
        let result = ExportWorker.copy(
            [item], to: fixture.destination,
            journalDirectory: fixture.journals,
            progress: { _, _ in }
        )
        if fixture.safety.usesReducedDirectoryDurability {
            XCTAssertEqual(result.copiedFiles, 0)
            XCTAssertEqual(result.failedPhotos, 1)
            XCTAssertFalse(result.journalFailure)
            XCTAssertFalse(result.requiresRecovery)
            XCTAssertTrue(result.failureMessage?.contains("APFS") == true)
            XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
            XCTAssertEqual(try Data(contentsOf: target), foreign)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["PHOTO.JPG"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
            return
        }
        XCTAssertEqual(result.copiedFiles, 1, String(describing: result.failureMessage))
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
        XCTAssertEqual(try Data(contentsOf: target), foreign)
        let copied = try FileManager.default.contentsOfDirectory(
            at: fixture.destination, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != "PHOTO.JPG" }
        XCTAssertEqual(copied.count, 1)
        if let copy = copied.first {
            XCTAssertEqual(try Data(contentsOf: copy), Data("PHOTO.JPG".utf8))
        }
    }

    func testSameVolumeExportMovePreservesBytes() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = try media("PHOTO.JPG", in: fixture.photos)
        let result = ExportWorker.move(
            [makeItem(source)], to: fixture.destination,
            journalDirectory: fixture.journals,
            progress: { _, _ in }
        )
        if fixture.safety.usesReducedDirectoryDurability {
            XCTAssertEqual(result.movedFiles, 0)
            XCTAssertEqual(result.failedPhotos, 1)
            XCTAssertFalse(result.journalFailure)
            XCTAssertFalse(result.requiresRecovery)
            XCTAssertTrue(result.failureMessage?.contains("APFS") == true)
            XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
            return
        }
        XCTAssertEqual(result.movedFiles, 1, String(describing: result.failureMessage))
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent("PHOTO.JPG")), Data("PHOTO.JPG".utf8))
    }

    func testUnsupportedDestinationPreflightTouchesNoMediaOrJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        guard fixture.safety.usesReducedDirectoryDurability else {
            throw XCTSkip("this case requires the real unsupported ExFAT destination")
        }
        let source = try media("PHOTO.JPG", in: fixture.photos)
        let item = makeItem(source)
        for mode in [ExportMode.copy, .move] {
            XCTAssertThrowsError(try ExportDestinationValidator.validateBound(
                sourceFolder: fixture.photos, destination: fixture.destination,
                items: [item], mode: mode
            )) { error in
                XCTAssertEqual(error as? ExportDestinationValidator.ValidationError, .collisionSafePublicationUnavailable)
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    func testExFATSourceCanStillCopyToAPFSDestination() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        guard fixture.safety.usesReducedDirectoryDurability,
              let secondRoot = ProcessInfo.processInfo.environment["LOUPPE_FILE_VOLUME_SECOND_ROOT"] else {
            throw XCTSkip("requires the real ExFAT source and a second disposable APFS mount")
        }
        let targetFixture = try makeFixture(volumePath: secondRoot, expectedFileSystem: "apfs")
        defer { targetFixture.remove() }
        let source = try media("PHOTO.JPG", in: fixture.photos)
        let item = makeItem(source)
        let validated = try ExportDestinationValidator.validateBound(
            sourceFolder: fixture.photos, destination: targetFixture.destination,
            items: [item], mode: .copy
        )
        let result = ExportWorker.copy(
            [item], to: validated.url, destinationBinding: validated.binding,
            journalDirectory: fixture.journals, progress: { _, _ in }
        )
        XCTAssertEqual(result.copiedFiles, 1, result.failureMessage ?? "")
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
        XCTAssertEqual(try Data(contentsOf: targetFixture.destination.appendingPathComponent("PHOTO.JPG")), Data("PHOTO.JPG".utf8))
    }

    func testRenameAndOrganizationUndoPreserveFamily() throws {
        for rename in [false, true] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let raw = try media("A.NEF", in: fixture.photos)
            let jpeg = try media("A.JPG", in: fixture.photos)
            let xmp = try media("A.xmp", in: fixture.photos)
            let item = PhotoItem(
                id: "A.NEF", primaryURL: raw, pairedURL: jpeg,
                captureDate: nil, cameraModel: nil, lensModel: nil,
                fileSize: 5, pairedFileSize: 5, rating: .yes
            )
            let configuration = rename
                ? FileRenamingPlanner.sourceConfiguration(customBaseName: "Renamed-001")
                : SourceOrganizationConfiguration(
                    levels: [.init(kind: .decision, isEnabled: true)],
                    dateGranularity: .day, existingFolderDepth: .topLevel,
                    containerName: "Organized"
                )
            let plan = try SourceOrganizationPlanner.makePlan(
                sourceFolder: fixture.photos, selectedItems: [item],
                familyContextItems: [item], configuration: configuration,
                knownOriginFolderPathBytesByFileID: [:]
            )
            XCTAssertTrue(plan.canExecute, plan.collisions.map(\.message).joined(separator: " | "))
            XCTAssertEqual(plan.storageSafety, fixture.safety)
            let changed = SourceOrganizationWorker.organize(
                plan, journalDirectory: fixture.journals, progress: { _, _ in }
            )
            XCTAssertEqual(changed.movedFiles, 3, changed.failureMessage ?? "")
            XCTAssertEqual(changed.failedItems, 0)
            XCTAssertFalse(changed.requiresRecovery)
            let undo = SourceOrganizationWorker.undo(
                try XCTUnwrap(changed.undoRecord), currentItems: [],
                journalDirectory: fixture.journals, progress: { _, _ in }
            )
            XCTAssertEqual(undo.movedFiles, 3, undo.failureMessage ?? "")
            XCTAssertEqual(undo.failedItems, 0)
            for file in [raw, jpeg, xmp] {
                XCTAssertEqual(try Data(contentsOf: file), Data(file.lastPathComponent.utf8))
            }
            XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
        }
    }

    func testChangedMoveParentIsRefusedWithoutRedirectingBytes() throws {
        for replaceSource in [false, true] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let source = try media("PHOTO.JPG", in: fixture.photos)
            let item = makeItem(source)
            let plan = try ExportWorker.makePlan(for: [item], in: fixture.destination, mode: .move)
            let parent = replaceSource ? fixture.photos : fixture.destination
            let retained = fixture.root.appendingPathComponent("RetainedParent", isDirectory: true)
            let sentinel = parent.appendingPathComponent("FOREIGN.JPG")
            let foreign = Data("unrelated replacement bytes".utf8)
            let result = ExportWorker.move(
                [item], to: fixture.destination, preparedPlan: plan,
                journalDirectory: fixture.journals, journalKind: .organizeSource,
                directorySyncPolicy: fixture.safety.directorySyncPolicy,
                renameStrategy: fixture.safety.noOverwriteRenameStrategy,
                afterMoveDirectoriesOpened: {
                    do {
                        try FileManager.default.moveItem(at: parent, to: retained)
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                        try foreign.write(to: sentinel)
                    } catch { XCTFail("could not inject parent replacement: \(error)") }
                },
                progress: { _, _ in }
            )
            XCTAssertEqual(result.movedFiles, 0)
            XCTAssertEqual(result.failedPhotos, 1)
            let retainedSource = replaceSource ? retained.appendingPathComponent("PHOTO.JPG") : source
            XCTAssertEqual(try Data(contentsOf: retainedSource), Data("PHOTO.JPG".utf8))
            XCTAssertEqual(try Data(contentsOf: sentinel), foreign)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["FOREIGN.JPG"])
        }
    }

    func testInterruptedRenameRestoresIncompleteFamily() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let raw = try media("A.NEF", in: fixture.photos)
        let jpeg = try media("A.JPG", in: fixture.photos)
        let renamedRAW = fixture.destination.appendingPathComponent("Renamed.NEF")
        let renamedJPEG = fixture.destination.appendingPathComponent("Renamed.JPG")
        let writer = try FileOperationJournal.start(
            kind: .renameSource,
            seeds: [
                .init(itemID: "family:A", source: raw, destination: renamedRAW),
                .init(itemID: "family:A", source: jpeg, destination: renamedJPEG)
            ], directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.renameWithoutOverwrite(
            from: raw, to: renamedRAW, strategy: fixture.safety.noOverwriteRenameStrategy
        )
        try DurableFileIO.syncRenameDirectories(
            from: raw, to: renamedRAW, fullSync: true,
            policy: fixture.safety.directorySyncPolicy
        )
        let identity = try FileOperationJournal.captureIdentity(at: renamedRAW)
        try writer.mark(.completed, fileAt: 0, identityAt: renamedRAW, expectedIdentity: identity)
        try writer.mark(.started, fileAt: 1)
        XCTAssertTrue(FileOperationJournal.finalize(writer, operationIsConsistent: false))
        let report = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.restoredFiles, 1)
        XCTAssertEqual(try Data(contentsOf: raw), Data("A.NEF".utf8))
        XCTAssertEqual(try Data(contentsOf: jpeg), Data("A.JPG".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedRAW.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedJPEG.path))
    }

    func testRecoveryPreservesReplacementAndRemainsRetryable() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let source = try media("PHOTO.JPG", in: fixture.photos)
        let target = fixture.destination.appendingPathComponent("PHOTO.JPG")
        let writer = try FileOperationJournal.start(
            kind: .organizeSource,
            seeds: [.init(itemID: "PHOTO.JPG", source: source, destination: target)],
            directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.renameWithoutOverwrite(
            from: source, to: target, strategy: fixture.safety.noOverwriteRenameStrategy
        )
        try DurableFileIO.syncRenameDirectories(
            from: source, to: target, fullSync: true,
            policy: fixture.safety.directorySyncPolicy
        )
        let identity = try FileOperationJournal.captureIdentity(at: target)
        try writer.mark(.completed, fileAt: 0, identityAt: target, expectedIdentity: identity)
        XCTAssertTrue(FileOperationJournal.finalize(writer, operationIsConsistent: false))
        let retained = fixture.root.appendingPathComponent("RetainedDestination", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.destination, to: retained)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let foreign = Data("unrelated destination bytes".utf8)
        try foreign.write(to: target)
        let refused = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        XCTAssertGreaterThan(refused.unresolvedOperations, 0)
        XCTAssertTrue(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
        XCTAssertEqual(try Data(contentsOf: target), foreign)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("PHOTO.JPG")), Data("PHOTO.JPG".utf8))

        // Remove only our injected replacement and restore the planned inode.
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.moveItem(at: retained, to: fixture.destination)
        let recovered = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        XCTAssertEqual(recovered.unresolvedOperations, 0)
        XCTAssertEqual(recovered.preservedMoves, 1)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: target), Data("PHOTO.JPG".utf8))
    }

    func testDiskImageRemountKeepsOfflineRatingsAndOriginalBytes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let handoffPath = environment["LOUPPE_FILE_VOLUME_HANDOFF"],
              handoffPath.hasPrefix("/private/tmp/louppe-readiness/") else {
            throw XCTSkip("requires an external disposable disk-image remount coordinator")
        }
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let handoff = URL(fileURLWithPath: handoffPath, isDirectory: true)
        let source = try media("PHOTO.JPG", in: fixture.photos)
        let persistence = SessionPersistence(backupDirectory: fixture.journals)
        var session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: fixture.photos.path, scannedAt: Date(),
            entries: [.init(filename: "PHOTO.JPG", pairedFilename: nil,
                rating: Rating.yes.rawValue, ratedAt: nil,
                fileIdentity: try FileOperationJournal.captureIdentity(at: source))],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let opened = await persistence.read(for: fixture.photos)
        let access = try XCTUnwrap(opened.access)
        let initial = await persistence.save(session, for: fixture.photos, sequence: 1, access: access)
        XCTAssertTrue(initial.canDiscardInMemoryState)
        try Data().write(to: handoff.appendingPathComponent("ready"))
        try await waitForMarker("detached", in: handoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.photos.path))
        session.entries[0].rating = Rating.no.rawValue
        let offline = await persistence.save(session, for: fixture.photos, sequence: 2, access: access)
        XCTAssertEqual(offline, .savedToBackup(sidecarFailure: .volumeUnavailable))
        XCTAssertTrue(offline.canDiscardInMemoryState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.photos.path), "offline saving must not recreate the missing mount")
        try Data().write(to: handoff.appendingPathComponent("offline-saved"))
        try await waitForMarker("remounted", in: handoff)
        XCTAssertTrue(access.folderIdentity.matches(folder: fixture.photos))
        XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
        let reopened = await persistence.read(for: fixture.photos)
        XCTAssertEqual(reopened.session?.entries.first?.rating, Rating.no.rawValue)
        XCTAssertEqual(reopened.session?.snapshotGeneration, 2)
        XCTAssertNil(reopened.blockingMessage)
        let repaired = await persistence.save(session, for: fixture.photos, sequence: 3, access: access)
        XCTAssertTrue(repaired.canDiscardInMemoryState)
        let final = await persistence.read(for: fixture.photos)
        XCTAssertEqual(final.session?.entries.first?.rating, Rating.no.rawValue)
        XCTAssertEqual(final.session?.snapshotGeneration, 3)
        XCTAssertEqual(try Data(contentsOf: source), Data("PHOTO.JPG".utf8))
    }

    private func waitForMarker(_ name: String, in directory: URL) async throws {
        for _ in 0..<1_500 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FileVolumeAcceptance", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "disk-image remount coordinator timed out"])
    }

    private struct Fixture {
        let root: URL
        let photos: URL
        let destination: URL
        let journals: URL
        let safety: SourceOrganizationStorageSafety

        func remove() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: journals)
        }
    }

    private func makeFixture(
        volumePath: String? = nil,
        expectedFileSystem: String? = nil
    ) throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard let path = volumePath ?? environment["LOUPPE_FILE_VOLUME_ROOT"],
              let expectedFS = expectedFileSystem ?? environment["LOUPPE_FILE_VOLUME_FS"] else {
            throw XCTSkip("requires a disposable mounted Louppe volume and explicit filesystem")
        }
        let volume = URL(fileURLWithPath: path, isDirectory: true)
        let values = try volume.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
        guard path.hasPrefix("/Volumes/Louppe"),
              values.volume?.path == volume.path,
              ["apfs", "exfat"].contains(expectedFS) else {
            throw NSError(domain: "FileVolumeAcceptance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "expected an explicit disposable Louppe mount"])
        }
        let safety = SourceOrganizationStorageSafety.detect(at: volume)
        XCTAssertEqual(safety.fileSystemName, expectedFS, "the actual mounted filesystem must match acceptance provenance")
        print("File-volume acceptance: \(volume.path), fs=\(safety.fileSystemName ?? "unknown"), uuid=\(values.volumeUUIDString ?? "unavailable")")
        let root = volume.appendingPathComponent("Acceptance-\(UUID().uuidString)", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let journals = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe-VolumeAcceptance-Journals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return Fixture(root: root, photos: photos, destination: destination, journals: journals, safety: safety)
    }

    private func media(_ name: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try Data(name.utf8).write(to: file)
        return file
    }

    private func makeItem(_ url: URL) -> PhotoItem {
        PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
            captureDate: nil, cameraModel: nil, lensModel: nil,
            fileSize: Int64(url.lastPathComponent.utf8.count), rating: .yes)
    }
}
