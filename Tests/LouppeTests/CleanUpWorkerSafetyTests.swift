import Foundation
import XCTest
@testable import Louppe

final class CleanUpWorkerSafetyTests: XCTestCase {
    func testPairMemberCleanUpMovesOnlyTargetAndRestoresIt() throws {
        let root = try makeTemporaryDirectory(named: "PairMember")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("PAIR.NEF")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        let rawData = Data("raw original".utf8)
        let jpegData = Data("jpeg shareable".utf8)
        try rawData.write(to: raw)
        try jpegData.write(to: jpeg)
        let pair = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let jpegOnly = PhotoItem(primaryFile: try XCTUnwrap(pair.individualFiles.last))

        let moved = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(
                index: 0,
                item: jpegOnly,
                validationFiles: pair.individualFiles
            )],
            journalDirectory: journals,
            fileManager: ProtectedTrashFileManager(trashDirectory: trash)
        ) { _, _ in }

        XCTAssertEqual(moved.succeeded.count, 1)
        XCTAssertEqual(moved.succeeded.first?.files.count, 1)
        XCTAssertEqual(try Data(contentsOf: raw), rawData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path))
        let restored = CleanUpWorker.restore(
            moved.succeeded,
            journalDirectory: journals
        ) { _, _ in }
        XCTAssertEqual(restored.restored.count, 1)
        XCTAssertEqual(try Data(contentsOf: raw), rawData)
        XCTAssertEqual(try Data(contentsOf: jpeg), jpegData)
    }

    func testPairMemberCleanUpRejectsStaleRetainedCounterpart() throws {
        let root = try makeTemporaryDirectory(named: "PairMemberStale")
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("PAIR.NEF")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let pair = makeItem(id: "PAIR.NEF", primaryURL: raw, pairedURL: jpeg)
        let jpegOnly = PhotoItem(primaryFile: try XCTUnwrap(pair.individualFiles.last))
        try Data("changed retained raw".utf8).write(to: raw)

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(
                index: 0,
                item: jpegOnly,
                validationFiles: pair.individualFiles
            )],
            journalDirectory: journals,
            fileManager: ProtectedTrashFileManager(trashDirectory: trash)
        ) { _, _ in }

        XCTAssertEqual(result.stalePhotos.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCleanUpDoesNotRequireOpeningProtectedTrashDirectory() throws {
        let root = try makeTemporaryDirectory(named: "ProtectedTrash")
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: true
        )
        defer {
            try? setDirectoryPermissions(0o700, at: trash)
            try? FileManager.default.removeItem(at: root)
        }

        let source = photos.appendingPathComponent("SOURCE.JPG")
        let contents = Data("original".utf8)
        try contents.write(to: source)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: source)
        let fileManager = ProtectedTrashFileManager(trashDirectory: trash)
        try setDirectoryPermissions(0o300, at: trash)
        XCTAssertThrowsError(
            try DurableFileIO.syncDirectory(trash, fullSync: true),
            "the fixture must reject the direct Trash-directory sync that caused the production failure"
        )

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: item)],
            journalDirectory: journals,
            fileManager: fileManager
        ) { _, _ in }

        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let landed = try XCTUnwrap(result.succeeded.first?.files.first?.trash)
        XCTAssertEqual(try Data(contentsOf: landed), contents)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testTrashUndoDoesNotRequireOpeningProtectedTrashDirectory() throws {
        let root = try makeTemporaryDirectory(named: "ProtectedTrashUndo")
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let trashDirectory = root.appendingPathComponent(".Trash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? setDirectoryPermissions(0o700, at: trashDirectory)
            try? FileManager.default.removeItem(at: root)
        }

        let original = photos.appendingPathComponent("SOURCE.JPG")
        let trash = trashDirectory.appendingPathComponent("SOURCE.JPG")
        let contents = Data("original".utf8)
        try contents.write(to: original)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: original)
        try ExportWorker.atomicExclusiveRename(from: original, to: trash)
        let identity = try FileOperationJournal.captureIdentity(at: trash)
        try setDirectoryPermissions(0o300, at: trashDirectory)
        XCTAssertThrowsError(
            try DurableFileIO.syncDirectory(trashDirectory, fullSync: true)
        )

        let result = CleanUpWorker.restore(
            [
                TrashedPhotoSnapshot(
                    index: 0,
                    item: item,
                    files: [
                        TrashedFile(
                            original: original,
                            trash: trash,
                            identity: identity
                        ),
                    ]
                ),
            ],
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.restored.count, 1)
        XCTAssertEqual(result.lostPhotos, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: original), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCleanUpPairRollbackDoesNotSyncProtectedTrashDirectory() throws {
        let root = try makeTemporaryDirectory(named: "ProtectedTrashRollback")
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: true
        )
        defer {
            try? setDirectoryPermissions(0o700, at: trash)
            try? FileManager.default.removeItem(at: root)
        }

        let primary = photos.appendingPathComponent("PAIR.RAW")
        let paired = photos.appendingPathComponent("PAIR.JPG")
        let primaryContents = Data("raw".utf8)
        let pairedContents = Data("jpeg".utf8)
        try primaryContents.write(to: primary)
        try pairedContents.write(to: paired)
        let item = makeItem(
            id: "PAIR.RAW",
            primaryURL: primary,
            pairedURL: paired
        )
        let fileManager = ProtectedTrashFileManager(
            trashDirectory: trash,
            failingCall: 2
        )
        try setDirectoryPermissions(0o300, at: trash)

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: item)],
            journalDirectory: journals,
            fileManager: fileManager
        ) { _, _ in }

        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: primary), primaryContents)
        XCTAssertEqual(try Data(contentsOf: paired), pairedContents)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testTrashUndoKeepsRestoredPairMemberOutOfProtectedTrash() throws {
        let root = try makeTemporaryDirectory(named: "ProtectedTrashUndoRollback")
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let trashDirectory = root.appendingPathComponent(".Trash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? setDirectoryPermissions(0o700, at: trashDirectory)
            try? FileManager.default.removeItem(at: root)
        }

        let primary = photos.appendingPathComponent("PAIR.RAW")
        let paired = photos.appendingPathComponent("PAIR.JPG")
        let primaryTrash = trashDirectory.appendingPathComponent("PAIR.RAW")
        let pairedTrash = trashDirectory.appendingPathComponent("PAIR.JPG")
        let primaryContents = Data("raw".utf8)
        let pairedContents = Data("jpeg".utf8)
        let blockerContents = Data("replacement".utf8)
        try primaryContents.write(to: primary)
        try pairedContents.write(to: paired)
        let item = makeItem(
            id: "PAIR.RAW",
            primaryURL: primary,
            pairedURL: paired
        )
        try ExportWorker.atomicExclusiveRename(from: primary, to: primaryTrash)
        try ExportWorker.atomicExclusiveRename(from: paired, to: pairedTrash)
        let primaryIdentity = try FileOperationJournal.captureIdentity(at: primaryTrash)
        let pairedIdentity = try FileOperationJournal.captureIdentity(at: pairedTrash)
        try blockerContents.write(to: paired)
        try setDirectoryPermissions(0o300, at: trashDirectory)

        let result = CleanUpWorker.restore(
            [
                TrashedPhotoSnapshot(
                    index: 0,
                    item: item,
                    files: [
                        TrashedFile(
                            original: primary,
                            trash: primaryTrash,
                            identity: primaryIdentity
                        ),
                        TrashedFile(
                            original: paired,
                            trash: pairedTrash,
                            identity: pairedIdentity
                        ),
                    ]
                ),
            ],
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertEqual(result.lostPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 1)
        XCTAssertFalse(result.journalFailure)
        XCTAssertTrue(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: primary), primaryContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryTrash.path))
        XCTAssertEqual(try Data(contentsOf: pairedTrash), pairedContents)
        XCTAssertEqual(try Data(contentsOf: paired), blockerContents)
        XCTAssertTrue(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testCleanUpRejectsSamePathReplacementCapturedAfterScan() throws {
        let root = try makeTemporaryDirectory(named: "ScanReplacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let untouched = root.appendingPathComponent("UNTOUCHED.mov")
        let trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("original".utf8).write(to: source)
        try Data("movie".utf8).write(to: untouched)
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: true
        )
        let scannedItem = makeItem(id: "SOURCE.JPG", primaryURL: source)
        let untouchedItem = makeItem(
            id: "UNTOUCHED.mov",
            primaryURL: untouched,
            mediaKind: .video
        )

        try FileManager.default.removeItem(at: source)
        let replacement = Data("replacement with a different size".utf8)
        try replacement.write(to: source, options: .withoutOverwriting)

        let result = CleanUpWorker.moveToTrash(
            [
                CleanUpPhotoSnapshot(index: 0, item: scannedItem),
                CleanUpPhotoSnapshot(index: 1, item: untouchedItem),
            ],
            journalDirectory: journals,
            fileManager: ProtectedTrashFileManager(trashDirectory: trash)
        ) { _, _ in }

        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(result.stalePhotos, [
            StaleCleanUpPhoto(itemID: "SOURCE.JPG", displayName: "SOURCE.JPG"),
        ])
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertEqual(try Data(contentsOf: untouched), Data("movie".utf8))
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(directory: journals),
            "a stale scan must stop before journal activation or moving another item"
        )
    }

    func testStaleJPEGPreflightStopsWholeBatchAndFreshSnapshotsCanMoveIt() throws {
        let root = try makeTemporaryDirectory(named: "StaleJPEGPreflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("PAIR.RAW")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        let movie = root.appendingPathComponent("MOVIE.mov")
        let trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("movie".utf8).write(to: movie)
        try FileManager.default.createDirectory(
            at: trash,
            withIntermediateDirectories: true
        )
        let pair = makeItem(id: "PAIR.RAW", primaryURL: raw, pairedURL: jpeg)
        let video = makeItem(id: "MOVIE.mov", primaryURL: movie, mediaKind: .video)
        let oldJPEGIdentity = try XCTUnwrap(pair.pairedFile?.scannedIdentity)

        // Permission metadata changes ctime without changing pixels, size,
        // mtime, inode, or volume. This simulates Finder metadata drift.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: jpeg.path
        )
        let changedJPEGIdentity = try FileOperationJournal.captureIdentity(at: jpeg)
        XCTAssertTrue(FileOperationJournal.identitiesMatch(
            expected: oldJPEGIdentity,
            actual: changedJPEGIdentity,
            includeStatusChange: false
        ))
        XCTAssertFalse(FileOperationJournal.identitiesMatch(
            expected: oldJPEGIdentity,
            actual: changedJPEGIdentity,
            includeStatusChange: true
        ))

        let stale = CleanUpWorker.moveToTrash(
            [
                CleanUpPhotoSnapshot(index: 0, item: pair),
                CleanUpPhotoSnapshot(index: 1, item: video),
            ],
            journalDirectory: journals,
            fileManager: ProtectedTrashFileManager(trashDirectory: trash)
        ) { _, _ in }

        XCTAssertEqual(stale.stalePhotos, [
            StaleCleanUpPhoto(itemID: "PAIR.RAW", displayName: "PAIR.RAW"),
        ])
        XCTAssertEqual(stale.failedPhotos, 0)
        XCTAssertFalse(stale.journalFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))

        // A normal rescan creates new snapshots; exact live checks still run
        // before each move, but the refreshed batch can now use the existing
        // protected/fake Trash path safely.
        let rescannedPair = makeItem(
            id: "PAIR.RAW", primaryURL: raw, pairedURL: jpeg
        )
        let rescannedVideo = makeItem(
            id: "MOVIE.mov", primaryURL: movie, mediaKind: .video
        )
        let moved = CleanUpWorker.moveToTrash(
            [
                CleanUpPhotoSnapshot(index: 0, item: rescannedPair),
                CleanUpPhotoSnapshot(index: 1, item: rescannedVideo),
            ],
            journalDirectory: journals,
            fileManager: ProtectedTrashFileManager(trashDirectory: trash)
        ) { _, _ in }
        XCTAssertTrue(moved.stalePhotos.isEmpty)
        XCTAssertEqual(moved.succeeded.count, 2)
        XCTAssertEqual(moved.failedPhotos, 0)
        XCTAssertFalse(moved.journalFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testMultipleStalePairMembersCountAsOneReviewItem() throws {
        let root = try makeTemporaryDirectory(named: "MultipleStalePairMembers")
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("PAIR.RAW")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let pair = makeItem(id: "PAIR.RAW", primaryURL: raw, pairedURL: jpeg)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: raw.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: jpeg.path
        )

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: pair)],
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertEqual(result.stalePhotos.count, 1)
        XCTAssertEqual(result.stalePhotos.first?.itemID, "PAIR.RAW")
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    @MainActor
    func testStaleScanMessageReportsOnlyStaleItemsAndRescanInstruction() {
        let message = SessionStore.cleanUpStaleScanMessage(for: [
            StaleCleanUpPhoto(itemID: "A", displayName: "A.RAW"),
            StaleCleanUpPhoto(itemID: "B", displayName: "B.mov"),
        ])
        XCTAssertTrue(message.contains("2 items have changed"))
        XCTAssertTrue(message.contains("A.RAW"))
        XCTAssertTrue(message.contains("B.mov"))
        XCTAssertTrue(message.contains("No files were moved."))
        XCTAssertTrue(message.contains("Rescan Folder"))
        XCTAssertTrue(message.contains("Trash No + Unmarked"))
        XCTAssertFalse(message.contains("179"))
    }

    func testRestoreCollisionLeavesBothFilesAndFinishesConsistently() throws {
        let root = try makeTemporaryDirectory(named: "RestoreCollision")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("ORIGINAL.JPG")
        let trash = root.appendingPathComponent("TRASH.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let trashedData = Data("trashed original".utf8)
        let replacementData = Data("existing replacement".utf8)
        try trashedData.write(to: trash)
        try replacementData.write(to: original)
        let identity = try FileOperationJournal.captureIdentity(at: trash)
        let item = makeItem(id: "ORIGINAL.JPG", primaryURL: original)

        let result = CleanUpWorker.restore(
            [
                TrashedPhotoSnapshot(
                    index: 0,
                    item: item,
                    files: [
                        TrashedFile(
                            original: original,
                            trash: trash,
                            identity: identity
                        ),
                    ]
                ),
            ],
            journalDirectory: journals
        ) { _, _ in }

        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertEqual(result.lostPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.journalFailure)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: original), replacementData)
        XCTAssertEqual(try Data(contentsOf: trash), trashedData)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
    }

    func testThrownTrashWithUnreportedMoveAndSourceReplacementStaysRecoverable() throws {
        let root = try makeTemporaryDirectory(named: "UnreportedTrashMove")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.JPG")
        let displaced = root.appendingPathComponent("DISPLACED.JPG")
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        let original = Data("planned original".utf8)
        let replacement = Data("same-path replacement".utf8)
        try original.write(to: source)
        let item = makeItem(id: "SOURCE.JPG", primaryURL: source)
        let fileManager = UnreportedTrashMoveFileManager(
            displaced: displaced,
            replacement: replacement
        )

        let result = CleanUpWorker.moveToTrash(
            [CleanUpPhotoSnapshot(index: 0, item: item)],
            journalDirectory: journals,
            fileManager: fileManager
        ) { _, _ in }

        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 1)
        XCTAssertFalse(result.journalFailure)
        XCTAssertTrue(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertTrue(
            FileOperationJournal.hasPendingOperations(directory: journals),
            "an unlocated planned inode must retain its recovery journal"
        )
    }

    func testRestoreRollbackPreservesRacingReplacementAndStopsBatch() throws {
        let root = try makeTemporaryDirectory(named: "RestoreRollbackRace")
        defer { try? FileManager.default.removeItem(at: root) }
        let journals = root.appendingPathComponent("Journals", isDirectory: true)

        let firstOriginal = root.appendingPathComponent("FIRST.JPG")
        let secondOriginal = root.appendingPathComponent("SECOND.JPG")
        let laterOriginal = root.appendingPathComponent("LATER.JPG")
        let firstTrash = root.appendingPathComponent("TRASH-FIRST.JPG")
        let secondTrash = root.appendingPathComponent("TRASH-SECOND.JPG")
        let laterTrash = root.appendingPathComponent("TRASH-LATER.JPG")
        let firstData = Data("first original".utf8)
        let secondData = Data("second original".utf8)
        let laterData = Data("later original".utf8)
        try firstData.write(to: firstTrash)
        try secondData.write(to: secondTrash)
        try laterData.write(to: laterTrash)

        let firstIdentity = try FileOperationJournal.captureIdentity(at: firstTrash)
        let secondIdentity = try FileOperationJournal.captureIdentity(at: secondTrash)
        let laterIdentity = try FileOperationJournal.captureIdentity(at: laterTrash)
        let pair = makeItem(
            id: "FIRST.JPG",
            primaryURL: firstOriginal,
            pairedURL: secondOriginal
        )
        let later = makeItem(id: "LATER.JPG", primaryURL: laterOriginal)
        let trashReplacement = Data("racing Trash replacement".utf8)
        let originalBlocker = Data("racing original replacement".utf8)
        let race = RestoreRollbackRace(
            trashReplacementURL: firstTrash,
            trashReplacement: trashReplacement,
            originalBlockerURL: secondOriginal,
            originalBlocker: originalBlocker
        )

        let result = CleanUpWorker.restore(
            [
                TrashedPhotoSnapshot(
                    index: 0,
                    item: pair,
                    files: [
                        TrashedFile(
                            original: firstOriginal,
                            trash: firstTrash,
                            identity: firstIdentity
                        ),
                        TrashedFile(
                            original: secondOriginal,
                            trash: secondTrash,
                            identity: secondIdentity
                        ),
                    ]
                ),
                TrashedPhotoSnapshot(
                    index: 1,
                    item: later,
                    files: [
                        TrashedFile(
                            original: laterOriginal,
                            trash: laterTrash,
                            identity: laterIdentity
                        ),
                    ]
                ),
            ],
            journalDirectory: journals
        ) { done, _ in
            race.injectAfterFirstFile(done: done)
        }
        if let failure = race.failureDescription {
            XCTFail(failure)
        }

        XCTAssertTrue(result.restored.isEmpty)
        XCTAssertEqual(result.lostPhotos, 2, "the later photo must not be attempted")
        XCTAssertEqual(result.inconsistentPhotos, 1)
        XCTAssertTrue(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: firstOriginal), firstData)
        XCTAssertEqual(try Data(contentsOf: firstTrash), trashReplacement)
        XCTAssertEqual(try Data(contentsOf: secondTrash), secondData)
        XCTAssertEqual(try Data(contentsOf: secondOriginal), originalBlocker)
        XCTAssertEqual(try Data(contentsOf: laterTrash), laterData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: laterOriginal.path))
        XCTAssertTrue(FileOperationJournal.hasPendingOperations(directory: journals))

        // Remove only the two deliberately injected blockers. Recovery can
        // then finish the exact journaled files and retire the operation.
        try FileManager.default.removeItem(at: firstTrash)
        try FileManager.default.removeItem(at: secondOriginal)
        let recovery = FileOperationJournal.recoverPendingOperations(
            directory: journals
        )
        XCTAssertEqual(recovery.unresolvedOperations, 0)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        XCTAssertEqual(try Data(contentsOf: firstOriginal), firstData)
        XCTAssertEqual(try Data(contentsOf: secondOriginal), secondData)
        XCTAssertEqual(try Data(contentsOf: laterOriginal), laterData)
    }

    func testSuccessfulRestoreRefreshesLiveScanIdentity() throws {
        let root = try makeTemporaryDirectory(named: "RestoreRefresh")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("ORIGINAL.JPG")
        let trash = root.appendingPathComponent("TRASH.JPG")
        try Data("original".utf8).write(to: original)
        let item = makeItem(id: "ORIGINAL.JPG", primaryURL: original)
        try ExportWorker.atomicExclusiveRename(from: original, to: trash)
        let trashIdentity = try FileOperationJournal.captureIdentity(at: trash)

        let result = CleanUpWorker.restore(
            [
                TrashedPhotoSnapshot(
                    index: 0,
                    item: item,
                    files: [
                        TrashedFile(
                            original: original,
                            trash: trash,
                            identity: trashIdentity
                        ),
                    ]
                ),
            ],
            journalDirectory: root.appendingPathComponent("Journals")
        ) { _, _ in }

        XCTAssertEqual(result.restored.count, 1)
        XCTAssertEqual(result.lostPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        let refreshed = try XCTUnwrap(item.individualFiles[0].scannedIdentity)
        let current = try FileOperationJournal.captureIdentity(at: original)
        XCTAssertTrue(
            FileOperationJournal.identitiesMatch(
                expected: refreshed,
                actual: current,
                includeStatusChange: true
            ),
            "undo must refresh the session's exact live identity"
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeCleanUpWorkerTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func setDirectoryPermissions(
        _ permissions: Int,
        at directory: URL
    ) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: directory.path
        )
    }

    private func makeItem(
        id: String,
        primaryURL: URL,
        pairedURL: URL? = nil,
        mediaKind: MediaKind = .photo
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: primaryURL,
            pairedURL: pairedURL,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: mediaKind,
            fileSize: 1,
            pairedFileSize: pairedURL == nil ? 0 : 1
        )
    }
}

private final class ProtectedTrashFileManager: FileManager, @unchecked Sendable {
    private let trashDirectory: URL
    private let failingCall: Int?
    private var callCount = 0

    init(trashDirectory: URL, failingCall: Int? = nil) {
        self.trashDirectory = trashDirectory
        self.failingCall = failingCall
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        callCount += 1
        if callCount == failingCall {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = trashDirectory.appendingPathComponent(
            url.lastPathComponent
        )
        try FileManager.default.moveItem(at: url, to: destination)
        outResultingURL?.pointee = destination as NSURL
    }
}

private final class UnreportedTrashMoveFileManager: FileManager, @unchecked Sendable {
    private let displaced: URL
    private let replacement: Data

    init(displaced: URL, replacement: Data) {
        self.displaced = displaced
        self.replacement = replacement
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try FileManager.default.moveItem(at: url, to: displaced)
        try replacement.write(to: url, options: .withoutOverwriting)
        outResultingURL?.pointee = nil
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class RestoreRollbackRace: @unchecked Sendable {
    private let lock = NSLock()
    private let trashReplacementURL: URL
    private let trashReplacement: Data
    private let originalBlockerURL: URL
    private let originalBlocker: Data
    private var injected = false
    private var storedFailureDescription: String?

    init(
        trashReplacementURL: URL,
        trashReplacement: Data,
        originalBlockerURL: URL,
        originalBlocker: Data
    ) {
        self.trashReplacementURL = trashReplacementURL
        self.trashReplacement = trashReplacement
        self.originalBlockerURL = originalBlockerURL
        self.originalBlocker = originalBlocker
    }

    func injectAfterFirstFile(done: Int) {
        guard done == 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !injected else { return }
        injected = true
        do {
            try trashReplacement.write(
                to: trashReplacementURL,
                options: .withoutOverwriting
            )
            try originalBlocker.write(
                to: originalBlockerURL,
                options: .withoutOverwriting
            )
        } catch {
            storedFailureDescription =
                "could not inject restore rollback race: "
                + error.localizedDescription
        }
    }

    var failureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailureDescription
    }
}
