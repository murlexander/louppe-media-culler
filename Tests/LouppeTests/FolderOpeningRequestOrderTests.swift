import Foundation
import XCTest
@testable import Louppe

@MainActor
final class FolderOpeningRequestOrderTests: XCTestCase {
    func testNewerPinRetiresPendingExternalValidation() async throws {
        try await checkRequestOrder(externalFirst: true)
    }

    func testNewerExternalValidationRetiresPendingPin() async throws {
        try await checkRequestOrder(externalFirst: false)
    }

    func testRecoveryDeferredOpenYieldsToNewerExternalRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeOpenOrder-\(UUID())")
        let older = root.appendingPathComponent("Older")
        let newer = root.appendingPathComponent("Newer")
        for folder in [older, newer] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Disposable review document".utf8).write(to: folder.appendingPathComponent("Photo.txt"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        // A finalized, inconsistent journal makes the store recover at launch.
        let journals = root.appendingPathComponent("Journals")
        let source = root.appendingPathComponent("SOURCE.JPG")
        try Data("photo".utf8).write(to: source)
        let writer = try FileOperationJournal.start(
            kind: .exportMove,
            seeds: [.init(itemID: "SOURCE.JPG", source: source, destination: root.appendingPathComponent("EXPORTED.JPG"))],
            directory: journals)
        XCTAssertTrue(FileOperationJournal.finalize(writer, operationIsConsistent: false))
        let suite = "LouppeOpenOrder-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let newerRead = DelayedFolderRead(entered: expectation(description: "Newer validation entered"))
        defer { newerRead.release.signal() }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
                                 operationJournalDirectory: journals,
                                 automaticallyRecoversInterruptedOperations: true,
                                 reviewDefaults: defaults)
        XCTAssertTrue(store.isRecoveringInterruptedOperations)
        let opening = FolderOpening(readDirectory: { url in
            newerRead.read()
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        })
        opening.store = store
        // Recovery parks the older choice (a recent folder) in its deferred slot;
        // the newer external request is still validating when recovery ends.
        store.openFolder(older)
        XCTAssertNil(store.sourceFolder)
        newerRead.arm()
        opening.open([newer])
        await fulfillment(of: [newerRead.entered], timeout: 5)
        try await wait { !store.isRecoveringInterruptedOperations }
        XCTAssertNil(store.sourceFolder, "Recovery must not open the older deferred folder over the newer request")
        newerRead.release.signal()
        await opening.validationTask?.value
        try await wait { if case .ready = store.phase { return true }; return false }
        XCTAssertEqual(store.sourceFolder?.path, newer.path)
        XCTAssertNil(opening.error)
        store.closeSession()
        try await wait { store.sourceFolder == nil }
        let persistenceIdle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(persistenceIdle)
    }

    private func checkRequestOrder(externalFirst: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeOpenOrder-\(UUID())")
        let external = root.appendingPathComponent("External")
        let pinned = root.appendingPathComponent("Pinned")
        for folder in [external, pinned] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Disposable review document".utf8).write(to: folder.appendingPathComponent("Photo.txt"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let externalRead = DelayedFolderRead(entered: expectation(description: "External validation entered"))
        let pinRead = DelayedFolderRead(entered: expectation(description: "Pin resolution entered"))
        defer { externalRead.release.signal(); pinRead.release.signal() }
        let pinPersistence = PinnedFoldersPersistence(storageDirectory: root.appendingPathComponent("Pins"), operations: .init(
            resolve: { data in
                pinRead.read()
                return .init(url: try XCTUnwrap(URL(string: String(decoding: data, as: UTF8.self))), isStale: false)
            }, create: { Data($0.absoluteString.utf8) },
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            access: .init(start: { _ in true }, stop: { _ in })))
        let pins = PinnedFoldersStore(storageDirectory: root.appendingPathComponent("Pins"),
                                     persistence: pinPersistence, observesSystemChanges: false)
        _ = await pins.pinSelectedFolder(url: pinned)
        let pin = try XCTUnwrap(pins.folders.first)
        let suite = "LouppeOpenOrder-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
                                 operationJournalDirectory: root.appendingPathComponent("Journals"),
                                 reviewDefaults: defaults, pinnedFolders: pins)
        let opening = FolderOpening(readDirectory: { url in
            externalRead.read()
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        })
        opening.store = store
        externalRead.arm()
        pinRead.arm()
        if externalFirst {
            opening.open([external])
            await fulfillment(of: [externalRead.entered], timeout: 5)
            store.openPinnedFolder(pin)
            await fulfillment(of: [pinRead.entered], timeout: 5)
            externalRead.release.signal()
            await opening.validationTask?.value
            XCTAssertNil(store.sourceFolder, "The older external request must not retire the newer pin")
            pinRead.release.signal()
        } else {
            store.openPinnedFolder(pin)
            await fulfillment(of: [pinRead.entered], timeout: 5)
            opening.open([external])
            await fulfillment(of: [externalRead.entered], timeout: 5)
            pinRead.release.signal()
            try await wait { !pins.isWorking }
            // Allow the pin owner's continuation to consume its completed request.
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(store.sourceFolder, "The older pin must not retire the newer external request")
            externalRead.release.signal()
            await opening.validationTask?.value
        }
        try await wait { if case .ready = store.phase { return true }; return false }
        XCTAssertEqual(store.sourceFolder?.path, (externalFirst ? pinned : external).path)
        XCTAssertNil(opening.error)
        XCTAssertFalse(pins.isWorking)
        store.closeSession()
        try await wait { store.sourceFolder == nil }
        let persistenceIdle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(persistenceIdle)
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Folder request did not settle")
    }
}

private final class DelayedFolderRead: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false

    init(entered: XCTestExpectation) { self.entered = entered }
    func arm() { lock.withLock { armed = true } }
    func read() {
        let shouldWait = lock.withLock { let value = armed; armed = false; return value }
        guard shouldWait else { return }
        XCTAssertFalse(Thread.isMainThread)
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
    }
}
