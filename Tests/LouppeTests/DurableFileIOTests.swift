import Foundation
import XCTest
@testable import Louppe

final class DurableFileIOTests: XCTestCase {
    func testRootRelativeDirectoriesPreserveExactNamesAndRefuseEscapes() throws {
        let root = try makeTemporaryDirectory(named: "RootRelativeDirectories")
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected")
        let outside = root.appendingPathComponent("Selected-sibling")
        for folder in [selected, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let directory = try DurableFileIO.BoundDirectory(.init(url: selected))
        for name in ["caf\u{00E9}", "cafe\u{301}"] {
            let bytes = Data(name.utf8)
            let expected = try XMPExactFileSystemPath(url: selected).appending(componentBytes: bytes)
            let created = try directory.openChildDirectory(component: bytes, createIfMissing: true)
            let existing = try directory.openDescendantDirectory(at: expected.url)
            XCTAssertEqual(try XMPExactFileSystemPath(url: created.binding.url).bytes, expected.bytes)
            XCTAssertEqual(existing.binding, created.binding)
        }
        XCTAssertThrowsError(try directory.openDescendantDirectory(at: outside))
        let link = selected.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try directory.openDescendantDirectory(at: link))
        XCTAssertThrowsError(try directory.openChildDirectory(component: Data("Link".utf8), createIfMissing: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testDescriptorCopyRejectsForeignSourceWhenParentIsRestoredAfterOpen() throws {
        let root = try makeTemporaryDirectory(named: "CopySourceParentSwap")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let parent = root.appendingPathComponent("Source")
        let held = root.appendingPathComponent("HeldSource")
        let foreign = root.appendingPathComponent("Foreign")
        let destination = root.appendingPathComponent("Destination")
        for folder in [parent, foreign, destination] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let source = parent.appendingPathComponent("PHOTO.JPG")
        let original = Data("original photo".utf8)
        let foreignBytes = Data("foreign bytes!".utf8)
        try original.write(to: source)
        try foreignBytes.write(to: foreign.appendingPathComponent("PHOTO.JPG"))
        let plannedIdentity = try FileOperationJournal.captureIdentity(at: source)
        let directory = try DurableFileIO.BoundDirectory(.init(url: destination))
        let temporary = destination.appendingPathComponent("partial")
        try fm.moveItem(at: parent, to: held)
        try fm.createSymbolicLink(at: parent, withDestinationURL: foreign)
        XCTAssertThrowsError(try directory.copy(
            from: source, to: temporary, expectedSourceIdentity: plannedIdentity,
            afterSourceOpened: {
                try fm.removeItem(at: parent)
                try fm.moveItem(at: held, to: parent)
            }
        ))
        XCTAssertFalse(fm.fileExists(atPath: temporary.path), "reject before creating a foreign copy")
        XCTAssertEqual(try FileOperationJournal.captureIdentity(at: source), plannedIdentity)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("PHOTO.JPG")), foreignBytes)
    }

    func testDescriptorCopyRechecksOpenedSourceAfterTransfer() throws {
        let root = try makeTemporaryDirectory(named: "CopySourceChanged")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("PHOTO.JPG")
        let original = Data("original photo".utf8)
        try original.write(to: source)
        let identity = try FileOperationJournal.captureIdentity(at: source)
        let directory = try DurableFileIO.BoundDirectory(.init(url: root))
        XCTAssertThrowsError(try directory.copy(
            from: source, to: root.appendingPathComponent("partial"),
            expectedSourceIdentity: identity,
            afterDestinationOpened: {
                let handle = try! FileHandle(forWritingTo: source)
                try! handle.write(contentsOf: Data("changed bytes!".utf8))
                try! handle.close()
            }
        ))
    }

    func testBoundMoveKeepsStagedFileInOpenedDirectoryAfterPathSwap() throws {
        let root = try makeTemporaryDirectory(named: "BoundMovePathSwap")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let unapproved = root.appendingPathComponent("Unapproved", isDirectory: true)
        for folder in [sourceFolder, destination, unapproved] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let source = sourceFolder.appendingPathComponent("PHOTO.JPG")
        let temporary = destination.appendingPathComponent(".louppe-test.partial")
        let bytes = Data("original photo".utf8)
        try bytes.write(to: source)
        let sourceDirectory = try DurableFileIO.BoundDirectory(.init(url: sourceFolder))
        let targetDirectory = try DurableFileIO.BoundDirectory(.init(url: destination))
        try sourceDirectory.move(
            source, to: temporary, in: targetDirectory,
            strategy: .exclusivePOSIX
        )
        let movedDestination = root.appendingPathComponent("OriginalDestination")
        try FileManager.default.moveItem(at: destination, to: movedDestination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: unapproved)
        try sourceDirectory.syncRename(to: targetDirectory, policy: .required)
        XCTAssertThrowsError(try targetDirectory.binding.requireCurrentPath())
        XCTAssertEqual(
            try Data(contentsOf: movedDestination.appendingPathComponent(".louppe-test.partial")),
            bytes
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: unapproved.path), [])
    }

    func testAtomicWriteReplacesFullyAndLeavesNoTemporaryFile() throws {
        let root = try makeTemporaryDirectory(named: "Replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json")

        try DurableFileIO.atomicWrite(
            Data("first".utf8),
            to: destination,
            fullSync: true
        )
        let replacement = Data("second complete snapshot".utf8)
        try DurableFileIO.atomicWrite(
            replacement,
            to: destination,
            fullSync: true
        )

        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent), ["session.json"])
        let permissions = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testFailedReplacePreservesTargetAndCleansTemporaryFile() throws {
        let root = try makeTemporaryDirectory(named: "FailureCleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(
            "existing-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try DurableFileIO.atomicWrite(
                Data("must not replace a directory".utf8),
                to: destination,
                fullSync: true
            )
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".louppe-write-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testLateValidationFailurePreservesExternallyChangedTarget() throws {
        let root = try makeTemporaryDirectory(named: "LateValidation")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json")
        let external = Data("external edit".utf8)
        try Data("original".utf8).write(to: destination)

        XCTAssertThrowsError(
            try DurableFileIO.atomicWrite(
                Data("queued Louppe snapshot".utf8),
                to: destination,
                fullSync: true
            ) {
                try external.write(to: destination)
                throw CocoaError(.userCancelled)
            }
        )

        XCTAssertEqual(try Data(contentsOf: destination), external)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".louppe-write-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testBoundedReadRejectsOversizedFilesAndLeafSymlinks() throws {
        let root = try makeTemporaryDirectory(named: "BoundedRead")
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("record.json")
        let symlink = root.appendingPathComponent("redirected.json")
        let contents = Data("12345".utf8)
        try contents.write(to: regular)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: regular
        )

        XCTAssertEqual(
            try DurableFileIO.readRegularFile(
                at: regular,
                maximumBytes: contents.count
            ),
            contents
        )
        XCTAssertThrowsError(
            try DurableFileIO.readRegularFile(
                at: regular,
                maximumBytes: contents.count - 1
            )
        )
        XCTAssertThrowsError(
            try DurableFileIO.readRegularFile(
                at: symlink,
                maximumBytes: 1024
            )
        )
        XCTAssertEqual(try Data(contentsOf: regular), contents)
    }

    func testDirectorySyncRejectsLeafSymlink() throws {
        let root = try makeTemporaryDirectory(named: "DirectorySymlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("real", isDirectory: true)
        let symlink = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: directory
        )

        XCTAssertNoThrow(try DurableFileIO.syncDirectory(directory))
        XCTAssertThrowsError(try DurableFileIO.syncDirectory(symlink))
    }

    func testReducedDirectorySyncPolicyIgnoresOnlyUnsupportedErrors() {
        XCTAssertTrue(DurableFileIO.shouldIgnoreUnsupportedDirectorySync(
            POSIXError(.ENOTSUP),
            policy: .allowUnsupported
        ))
        XCTAssertTrue(DurableFileIO.shouldIgnoreUnsupportedDirectorySync(
            POSIXError(.EINVAL),
            policy: .allowUnsupported
        ))
        XCTAssertFalse(DurableFileIO.shouldIgnoreUnsupportedDirectorySync(
            POSIXError(.ENOTSUP),
            policy: .required
        ))
        XCTAssertFalse(DurableFileIO.shouldIgnoreUnsupportedDirectorySync(
            POSIXError(.EIO),
            policy: .allowUnsupported
        ))
        XCTAssertFalse(DurableFileIO.shouldIgnoreUnsupportedDirectorySync(
            CocoaError(.fileWriteUnknown),
            policy: .allowUnsupported
        ))
    }

    func testFoundationRenameRefusesCollisionAndPreservesIdentity() throws {
        let root = try makeTemporaryDirectory(named: "FoundationRename")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        let destination = root.appendingPathComponent("destination.jpg")
        let sourceContents = Data("source".utf8)
        let destinationContents = Data("destination".utf8)
        try sourceContents.write(to: source)
        try destinationContents.write(to: destination)
        let sourceIdentity = try FileOperationJournal.captureIdentity(
            at: source
        )

        XCTAssertThrowsError(
            try DurableFileIO.renameWithoutOverwrite(
                from: source,
                to: destination,
                strategy: .foundation
            )
        )
        XCTAssertEqual(try Data(contentsOf: source), sourceContents)
        XCTAssertEqual(try Data(contentsOf: destination), destinationContents)

        try FileManager.default.removeItem(at: destination)
        try DurableFileIO.renameWithoutOverwrite(
            from: source,
            to: destination,
            strategy: .foundation
        )
        let destinationIdentity = try FileOperationJournal.captureIdentity(
            at: destination
        )
        XCTAssertTrue(FileOperationJournal.identitiesMatch(
            expected: sourceIdentity,
            actual: destinationIdentity,
            includeStatusChange: false
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), sourceContents)
    }

    func testRegularFileUnlinkNeverRecursesOrFollowsSymlink() throws {
        let root = try makeTemporaryDirectory(named: "NonrecursiveUnlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("owned.partial")
        let directory = root.appendingPathComponent("replacement", isDirectory: true)
        let nested = directory.appendingPathComponent("irreplaceable.jpg")
        let symlink = root.appendingPathComponent("redirected.partial")
        try Data("owned copy".utf8).write(to: regular)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let nestedContents = Data("do not remove".utf8)
        try nestedContents.write(to: nested)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: nested
        )

        try DurableFileIO.unlinkRegularFile(at: regular)
        XCTAssertFalse(FileManager.default.fileExists(atPath: regular.path))
        XCTAssertThrowsError(try DurableFileIO.unlinkRegularFile(at: directory))
        XCTAssertThrowsError(try DurableFileIO.unlinkRegularFile(at: symlink))
        XCTAssertEqual(try Data(contentsOf: nested), nestedContents)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LouppeDurableFileIOTests-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
