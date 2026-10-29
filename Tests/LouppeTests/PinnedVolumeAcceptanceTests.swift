import AppKit
import Foundation
import XCTest
@testable import Louppe

/// Opt-in real Foundation bookmark/identity test on a named disposable image.
/// This is a disk-image check, not a physical external-drive or TCC claim.
@MainActor
final class PinnedVolumeAcceptanceTests: XCTestCase {
    func testDisposableAPFSImageRetainsPinAcrossDetachAndVerifiedRemount() async throws {
        guard let imagePath = ProcessInfo.processInfo.environment["LOUPPE_PIN_TEST_IMAGE"],
              let mountPath = ProcessInfo.processInfo.environment["LOUPPE_PIN_TEST_MOUNT"] else {
            throw XCTSkip("Requires the named disposable APFS image and mount")
        }
        guard imagePath.hasPrefix("/private/tmp/louppe-overnight-20261025/morning/"),
              mountPath == "/Volumes/LouppeArchiveTest" else { throw CocoaError(.fileReadInvalidFileName) }
        let deviceData = try await capture("/usr/sbin/diskutil", ["info", "-plist", mountPath])
        let device = try XCTUnwrap(PropertyListSerialization.propertyList(from: deviceData, format: nil) as? [String: Any])
        guard device["BusProtocol"] as? String == "Disk Image", device["FilesystemType"] as? String == "apfs" else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let imageData = try await capture("/usr/bin/hdiutil", ["info", "-plist"])
        let imageInfo = try XCTUnwrap(PropertyListSerialization.propertyList(from: imageData, format: nil) as? [String: Any])
        let images = try XCTUnwrap(imageInfo["images"] as? [[String: Any]])
        guard images.contains(where: { image in
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath() == URL(fileURLWithPath: imagePath).resolvingSymlinksInPath(),
                  let entities = image["system-entities"] as? [[String: Any]] else { return false }
            return entities.contains { $0["mount-point"] as? String == mountPath }
        }) else { throw CocoaError(.fileReadInvalidFileName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-PinVolume-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = URL(fileURLWithPath: mountPath, isDirectory: true).appendingPathComponent("Photos", isDirectory: true)
        let source = try SessionPersistence.SourceFolderIdentity.capture(at: folder)
        let expected = PinnedFolderIdentity(source: source)
        let first = PinnedFoldersStore(storageDirectory: root, observesSystemChanges: false)
        let pinnedID = await first.pin(url: folder, expectedIdentity: expected)
        let id = try XCTUnwrap(pinnedID)
        let file = try XCTUnwrap(FolderScanner.scan(folder) { _ in }.first?.primaryFile)
        let anchor = PinnedFolderFileAnchor(physicalFileID: file.id, identity: try XCTUnwrap(file.scannedIdentity))
        let position = PinnedFolderPosition(current: anchor, browser: .init(anchor: anchor, topOffset: -7), grid: .init(anchor: anchor, topOffset: -13))
        let saved = await first.savePosition(position, for: expected)
        XCTAssertTrue(saved)
        let detached = try await run(["detach", mountPath])
        XCTAssertEqual(detached, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let offline = PinnedFoldersStore(storageDirectory: root, observesSystemChanges: false)
        await offline.refresh()
        XCTAssertEqual(offline.folders.count, 1)
        XCTAssertEqual(offline.folders.first?.id, id)
        XCTAssertNotEqual(offline.folders.first?.availability, .available)
        let retained = await offline.position(for: expected)
        XCTAssertEqual(retained, position)
        let attached = try await run(["attach", "-nobrowse", imagePath])
        XCTAssertEqual(attached, 0)
        await offline.refresh()
        XCTAssertEqual(offline.folders.first?.availability, .available)
        let prepared = await offline.prepareOpen(id: id)
        let request = try XCTUnwrap(prepared)
        XCTAssertTrue(request.expectedIdentity.matches(try .capture(at: request.authorityURL)))
        let scanned = try FolderScanner.scan(request.authorityURL) { _ in }
        let candidates = scanned.flatMap { $0.individualFiles }.compactMap { file in
            file.scannedIdentity.map { PinnedFolderFileAnchor(physicalFileID: file.id, identity: $0) }
        }
        let restored = position.restored(for: .init(source: try .capture(at: request.authorityURL)),
                                         expectedFolder: expected, candidates: candidates)
        XCTAssertEqual(restored?.currentPhysicalFileID, file.id)
        XCTAssertEqual(restored?.browser?.topOffset, -7)
        XCTAssertEqual(restored?.grid?.topOffset, -13)
        let unpinned = await offline.unpin(id: id)
        XCTAssertTrue(unpinned)
        XCTAssertTrue(offline.folders.isEmpty)
        print("PIN_VOLUME live-foundation-bookmark detach/remount identity/position/unpin passed; physical-drive=false")
    }

    private func capture(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
            return data
        }.value
    }

    private func run(_ arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 { print(String(decoding: output, as: UTF8.self)) }
            return process.terminationStatus
        }.value
    }
}
