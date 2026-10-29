import AppKit
import Foundation
import XCTest
@testable import Louppe

@MainActor
final class ArchiveSessionIntegrationTests: XCTestCase {
    func testPinnedCurrentAndIndependentViewportSurviveNewStoreAndChangedCurrentFallsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-ArchiveSession-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<80 {
            try Data("Disposable text \(index)".utf8).write(to: folder.appendingPathComponent(String(format: "%03d.txt", index)))
        }
        let defaultsName = "Louppe-ArchiveSession-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pinsRoot = root.appendingPathComponent("pins")
        let firstPins = makePins(pinsRoot)
        let first = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: firstPins)
        first.openFolder(folder)
        try await ready(first)
        first.toggleCurrentFolderPin()
        try await until { first.currentPinnedFolderID != nil }
        let currentID = first.items[50].primaryFile.id
        let viewportID = first.items[20].primaryFile.id
        first.setIndex(50)
        first.recordPinnedViewport(physicalFileID: viewportID, topOffset: -13.25, surface: .grid)
        first.beginTerminationPreparation()
        _ = await first.saveSessionForTermination()
        let idle = await first.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        let secondPins = makePins(pinsRoot)
        await secondPins.refresh()
        XCTAssertEqual(secondPins.folders.count, 1)
        let second = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                  reviewDefaults: defaults, pinnedFolders: secondPins)
        second.openPinnedFolder(try XCTUnwrap(secondPins.folders.first))
        try await ready(second)
        XCTAssertEqual(second.currentItem?.primaryFile.id, currentID)
        XCTAssertEqual(second.pendingOpeningViewportReceipt(for: .grid)?.physicalFileID, viewportID)
        XCTAssertEqual(second.pendingOpeningViewportReceipt(for: .grid)?.topOffset, -13.25)
        second.beginTerminationPreparation()
        _ = await second.saveSessionForTermination()
        // Atomic replacement has a different physical identity, even at the same path.
        let currentURL = try XCTUnwrap(second.items.first { $0.primaryFile.id == currentID }?.primaryURL)
        try Data("Replacement must not inherit current position".utf8).write(to: currentURL, options: .atomic)
        let thirdPins = makePins(pinsRoot)
        await thirdPins.refresh()
        let third = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: thirdPins)
        third.openPinnedFolder(try XCTUnwrap(thirdPins.folders.first))
        try await ready(third)
        XCTAssertEqual(third.currentItem?.primaryFile.id, viewportID)
        third.beginTerminationPreparation()
        _ = await third.saveSessionForTermination()
    }

    func testExpectedPinRefusesSamePathReplacementBeforeSidecarCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-ArchiveIdentity-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = PinnedFolderIdentity(source: try .capture(at: folder))
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: folder.appendingPathComponent("test.txt"))
        let defaultsName = "Louppe-ArchiveIdentity-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: makePins(root.appendingPathComponent("pins")))
        store.openFolder(folder, expectedPinnedIdentity: expected)
        try await until { store.scanError != nil }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionPersistence.sidecarURL(for: folder).path))
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionPersistence.sidecarURL(for: folder).path))
    }

    func testAutosaveHardDeadlineBypassesSustainedForegroundDemand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-ArchiveDeadline-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("disposable".utf8).write(to: folder.appendingPathComponent("test.txt"))
        let defaultsName = "Louppe-ArchiveDeadline-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 saveTrailingDelay: 0.005, saveMaximumDelay: 0.04,
                                 reviewDefaults: defaults, pinnedFolders: makePins(root.appendingPathComponent("pins")))
        store.openFolder(folder)
        try await ready(store)
        _ = await store.waitForPersistenceIdleForTesting()
        let demand = ForegroundWorkCoordinator.shared.beginForegroundDemand()
        defer { demand.finish() }
        store.rate(.yes, at: 0)
        let start = ContinuousClock.now
        try await until(timeout: .milliseconds(500)) { store.sessionSaveStatus == L10n.text("Saved") }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(SessionFile.self, from: Data(contentsOf: SessionPersistence.sidecarURL(for: folder)))
        XCTAssertEqual(saved.entries.first?.rating, Rating.yes.rawValue)
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
    }

    func testPinLegacyConfirmationRetainsExpectedIdentityAcrossPathReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-PinConfirm-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: folder.appendingPathComponent("A.txt"))
        let legacy = SessionFile(version: 2, sourcePath: root.appendingPathComponent("previous").path,
                                 scannedAt: Date(timeIntervalSince1970: 1),
                                 entries: [.init(filename: "A.txt", pairedFilename: nil, rating: Rating.yes.rawValue, ratedAt: nil)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(legacy)
        try bytes.write(to: SessionPersistence.sidecarURL(for: folder))
        let pins = makePins(root.appendingPathComponent("pins"))
        let expected = PinnedFolderIdentity(source: try .capture(at: folder))
        let pinID = await pins.pin(url: folder, expectedIdentity: expected)
        XCTAssertNotNil(pinID)
        let defaultsName = "Louppe-PinConfirm-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: pins)
        store.openPinnedFolder(try XCTUnwrap(pins.folders.first))
        try await until { store.canOpenMismatchedSessionAnyway }
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: folder.appendingPathComponent("A.txt"))
        try bytes.write(to: SessionPersistence.sidecarURL(for: folder))
        store.openMismatchedSessionAnyway()
        try await until { store.scanError != nil }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: SessionPersistence.sidecarURL(for: folder)), bytes)
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
        XCTAssertEqual(try Data(contentsOf: SessionPersistence.sidecarURL(for: folder)), bytes)
    }

    func testOpeningViewportIntentAndDormantPositionsRemainIndependentFromCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-PinIntent-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<80 { try Data("text \(i)".utf8).write(to: folder.appendingPathComponent(String(format: "%03d.txt", i))) }
        let defaultsName = "Louppe-PinIntent-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pinsRoot = root.appendingPathComponent("pins")
        let firstPins = makePins(pinsRoot)
        let first = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: firstPins)
        first.openFolder(folder); try await ready(first)
        first.toggleCurrentFolderPin(); try await until { first.currentPinnedFolderID != nil }
        first.setIndex(50)
        first.recordPinnedViewport(physicalFileID: "020.txt", topOffset: -13, surface: .grid)
        first.recordPinnedViewport(physicalFileID: "030.txt", topOffset: -7, surface: .browser)
        first.beginTerminationPreparation(); _ = await first.saveSessionForTermination()
        let secondPins = makePins(pinsRoot); await secondPins.refresh()
        let second = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                  reviewDefaults: defaults, pinnedFolders: secondPins)
        let gate = DispatchSemaphore(value: 0)
        second.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
            if stage == .metadata { _ = gate.wait(timeout: .now() + 5) }
        })
        second.openPinnedFolder(try XCTUnwrap(secondPins.folders.first))
        try await until { second.openingSession != nil }
        second.openingSession?.recordViewport(.init(surface: .grid, physicalFileID: "040.txt", topOffset: -9))
        gate.signal(); try await ready(second)
        XCTAssertEqual(second.currentItem?.primaryFile.id, "050.txt", "viewport-only input must not choose current")
        XCTAssertEqual(second.pendingOpeningViewportReceipt(for: .grid)?.physicalFileID, "040.txt")
        XCTAssertEqual(second.pendingOpeningViewportReceipt(for: .browser)?.physicalFileID, "030.txt")
        second.setIndex(60) // Expires UI receipts without erasing durable dormant anchors.
        XCTAssertNil(second.pendingOpeningViewportReceipt(for: .grid))
        second.beginTerminationPreparation(); _ = await second.saveSessionForTermination()
        let thirdPins = makePins(pinsRoot); await thirdPins.refresh()
        let third = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: thirdPins)
        third.openPinnedFolder(try XCTUnwrap(thirdPins.folders.first)); try await ready(third)
        XCTAssertEqual(third.currentItem?.primaryFile.id, "060.txt")
        XCTAssertEqual(third.pendingOpeningViewportReceipt(for: .grid)?.physicalFileID, "040.txt")
        XCTAssertEqual(third.pendingOpeningViewportReceipt(for: .browser)?.physicalFileID, "030.txt")
        third.beginTerminationPreparation(); _ = await third.saveSessionForTermination()
    }

    func testNewPhotosIntentRetiresPendingPinOpenAndSamePathRefreshUsesExactGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-PinRace-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("text".utf8).write(to: folder.appendingPathComponent("A.txt"))
        let events = ArchiveSourceEvents()
        let operations = SecurityScopedFolderBookmarks.Operations(resolve: { data in
            events.blockResolutionIfRequested()
            return .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
        }, create: { Data($0.path.utf8) }, exists: { FileManager.default.fileExists(atPath: $0.path) },
        access: .init(start: { _ in true }, stop: { _ in }))
        let pinsRoot = root.appendingPathComponent("pins")
        let pins = PinnedFoldersStore(storageDirectory: pinsRoot,
            persistence: PinnedFoldersPersistence(storageDirectory: pinsRoot, operations: operations), observesSystemChanges: false)
        let pinID = await pins.pin(url: folder, expectedIdentity: .init(source: try .capture(at: folder)))
        XCTAssertNotNil(pinID)
        let defaultsName = "Louppe-PinRace-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: pins,
                                 sourceResourceAccess: .init(start: { events.started($0); return true }, stop: { _ in }))
        events.requestBlockedResolution()
        store.openPinnedFolder(try XCTUnwrap(pins.folders.first))
        try await until { events.isResolutionBlocked }
        store.presentPhotosLibrary()
        events.release.signal()
        try await until { !pins.isWorking }
        XCTAssertNil(store.sourceFolder, "older pin intent must not replace the Photos chooser")
        store.isPhotosLibraryPresented = false
        store.openFolder(folder); try await ready(store)
        let renewed = folder.appendingPathComponent("..").appendingPathComponent("media")
        XCTAssertEqual(renewed.standardizedFileURL, folder.standardizedFileURL)
        store.openFolder(renewed)
        try await until { !store.isSessionTransitioning && events.startedURLs.contains(renewed.absoluteString) }
        try await ready(store)
        XCTAssertTrue(events.startedURLs.contains(renewed.absoluteString), "same identity path must still start the supplied exact grant")
        store.beginTerminationPreparation(); _ = await store.saveSessionForTermination()
    }

    func testFailedPositionForOneFolderSurvivesAnotherFoldersCaptureAndRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-PinRetry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = [root.appendingPathComponent("A"), root.appendingPathComponent("B")]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<4 { try Data("text \(i)".utf8).write(to: folder.appendingPathComponent("\(i).txt")) }
        }
        let events = ArchiveSourceEvents()
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            create: { Data($0.path.utf8) }, exists: { FileManager.default.fileExists(atPath: $0.path) },
            access: .init(start: { _ in true }, stop: { _ in }))
        let pinsRoot = root.appendingPathComponent("pins")
        let pins = PinnedFoldersStore(storageDirectory: pinsRoot,
            persistence: PinnedFoldersPersistence(storageDirectory: pinsRoot, operations: operations, write: { data, url in
                if events.writeFails { throw CocoaError(.fileWriteNoPermission) }
                try DurableFileIO.atomicWrite(data, to: url, fullSync: true)
            }), observesSystemChanges: false)
        let identities = try folders.map { PinnedFolderIdentity(source: try .capture(at: $0)) }
        for (folder, identity) in zip(folders, identities) { _ = await pins.pin(url: folder, expectedIdentity: identity) }
        let defaultsName = "Louppe-PinRetry-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: pins)
        store.openFolder(folders[0]); try await ready(store)
        store.setIndex(3)
        events.setWriteFailure(true)
        store.openFolder(folders[1])
        try await until { store.sourceFolder?.standardizedFileURL.path == folders[1].standardizedFileURL.path && !store.isSessionTransitioning }
        try await ready(store)
        XCTAssertNotNil(pins.statusMessage)
        store.setIndex(2)
        events.setWriteFailure(false)
        store.beginTerminationPreparation(); _ = await store.saveSessionForTermination()
        let firstPosition = await pins.position(for: identities[0])
        let secondPosition = await pins.position(for: identities[1])
        XCTAssertEqual(firstPosition?.current?.physicalFileID, "3.txt")
        XCTAssertEqual(secondPosition?.current?.physicalFileID, "2.txt")
    }

    func testTerminationAttemptsLatestPositionAfterJoiningAnOlderBlockedFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-PinFinal-\(UUID())")
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<4 { try Data("text \(i)".utf8).write(to: folder.appendingPathComponent("\(i).txt")) }
        let events = ArchiveSourceEvents()
        defer { events.release.signal() }
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { .init(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            create: { Data($0.path.utf8) }, exists: { FileManager.default.fileExists(atPath: $0.path) },
            access: .init(start: { _ in true }, stop: { _ in }))
        let pinsRoot = root.appendingPathComponent("pins")
        let pins = PinnedFoldersStore(storageDirectory: pinsRoot,
            persistence: PinnedFoldersPersistence(storageDirectory: pinsRoot, operations: operations, write: { data, url in
                events.blockWriteIfRequested()
                try DurableFileIO.atomicWrite(data, to: url, fullSync: true)
            }), observesSystemChanges: false)
        let identity = PinnedFolderIdentity(source: try .capture(at: folder))
        _ = await pins.pin(url: folder, expectedIdentity: identity)
        let defaultsName = "Louppe-PinFinal-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults, pinnedFolders: pins)
        store.openFolder(folder); try await ready(store)
        events.requestBlockedWrite()
        store.setIndex(1)
        try await until { events.isWriteBlocked }
        store.setIndex(2)
        store.recordPinnedViewport(physicalFileID: "3.txt", topOffset: -11, surface: .grid)
        store.beginTerminationPreparation()
        let quit = Task { await store.saveSessionForTermination() }
        await Task.yield()
        events.release.signal()
        _ = await quit.value
        // A fresh actor immediately after Quit must already see the final state.
        let fresh = PinnedFoldersPersistence(storageDirectory: pinsRoot, operations: operations)
        let position = try await fresh.position(for: identity)
        XCTAssertEqual(position?.current?.physicalFileID, "2.txt")
        XCTAssertEqual(position?.grid?.anchor.physicalFileID, "3.txt")
        XCTAssertEqual(position?.grid?.topOffset, -11)
    }

    private func makePins(_ directory: URL) -> PinnedFoldersStore {
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: { data in .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false) },
            create: { Data($0.path.utf8) }, exists: { FileManager.default.fileExists(atPath: $0.path) },
            access: .init(start: { _ in true }, stop: { _ in }))
        return PinnedFoldersStore(storageDirectory: directory,
            persistence: PinnedFoldersPersistence(storageDirectory: directory, operations: operations), observesSystemChanges: false)
    }

    private func ready(_ store: SessionStore) async throws {
        try await until {
            if let error = store.scanError { throw NSError(domain: "ArchiveSession", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if case .ready = store.phase { return true }; return false
        }
    }

    private func until(timeout: Duration = .seconds(8), _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

}

private final class ArchiveSourceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    private var block = false
    private var blocked = false
    private var failWrites = false
    private var blockNextWrite = false
    private var writeBlocked = false
    let release = DispatchSemaphore(value: 0)
    var startedURLs: [String] { lock.withLock { urls } }
    var isResolutionBlocked: Bool { lock.withLock { blocked } }
    var isWriteBlocked: Bool { lock.withLock { writeBlocked } }
    func requestBlockedWrite() { lock.withLock { blockNextWrite = true } }
    func blockWriteIfRequested() {
        let shouldBlock = lock.withLock {
            if blockNextWrite { blockNextWrite = false; writeBlocked = true; return true }; return false
        }
        if shouldBlock { _ = release.wait(timeout: .now() + 5) }
    }
    var writeFails: Bool { lock.withLock { failWrites } }
    func started(_ url: URL) { lock.withLock { urls.append(url.absoluteString) } }
    func setWriteFailure(_ value: Bool) { lock.withLock { failWrites = value } }
    func requestBlockedResolution() { lock.withLock { block = true } }
    func blockResolutionIfRequested() {
        let shouldBlock = lock.withLock { if block { block = false; blocked = true; return true }; return false }
        if shouldBlock { _ = release.wait(timeout: .now() + 5) }
    }
}
