import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import Louppe

@MainActor
final class FolderOpeningTests: XCTestCase {
    func testOnlyOneLocalFolderIsAccepted() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.txt")
        try Data("fixture".utf8).write(to: file)
        let opening = FolderOpening()
        let store = SessionStore()
        opening.store = store
        XCTAssertNil(opening.open([folder]))
        await opening.validationTask?.value
        XCTAssertNil(opening.error)
        store.cancelScan()
        XCTAssertNotNil(FolderOpening.requestError(for: []))
        XCTAssertNotNil(FolderOpening.requestError(for: [folder, folder]))
        XCTAssertNotNil(FolderOpening.requestError(for: [URL(string: "https://example.com/photos")!]))
        XCTAssertNil(opening.open([file]))
        await opening.validationTask?.value
        XCTAssertEqual(opening.error, L10n.text("Drop a folder containing photos, videos, audio, or text files, not an individual file."))
        XCTAssertNil(opening.open([folder.appendingPathComponent("missing")]))
        await opening.validationTask?.value
        XCTAssertEqual(opening.error, L10n.text("Louppe couldn't read the dropped folder. Please try again."))
    }

    func testModalPresentationRefusesFolderReplacement() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore()
        let opening = FolderOpening()
        opening.store = store
        store.isFilterPresented = true
        XCTAssertNotNil(opening.open([folder]))
        XCTAssertNil(store.sourceFolder)
        XCTAssertNotNil(opening.error)
        store.isFilterPresented = false
        XCTAssertNil(opening.open([folder]))
        await opening.validationTask?.value
        XCTAssertEqual(store.sourceFolder, folder)
        XCTAssertNil(opening.error)
        store.cancelScan()
    }

    func testActiveTransitionRefusesFolderReplacement() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore()
        let opening = FolderOpening()
        opening.store = store
        store.beginTerminationPreparation()
        defer { store.cancelTerminationPreparation() }
        XCTAssertNotNil(opening.open([folder]))
        XCTAssertNil(store.sourceFolder)
    }

    func testFolderReplacementPersistsDecisionsBeforeOpeningNewFolder() async throws {
        let firstFolder = try makeFolder()
        let secondFolder = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder)
            try? FileManager.default.removeItem(at: secondFolder)
        }
        try Data("First disposable document".utf8)
            .write(to: firstFolder.appendingPathComponent("first.txt"))
        try Data("Second disposable document".utf8)
            .write(to: secondFolder.appendingPathComponent("second.txt"))
        let store = SessionStore()
        let opening = FolderOpening()
        opening.store = store
        XCTAssertNil(opening.open([firstFolder]))
        await opening.validationTask?.value
        try await waitUntilReady(store)
        store.rate(.yes)
        XCTAssertNil(opening.open([secondFolder]))
        await opening.validationTask?.value
        for _ in 0..<500 where store.sourceFolder != secondFolder || store.isFileOperationRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntilReady(store)
        XCTAssertEqual(store.sourceFolder, secondFolder)
        XCTAssertNil(opening.open([firstFolder]))
        await opening.validationTask?.value
        for _ in 0..<500 where store.sourceFolder != firstFolder || store.isFileOperationRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntilReady(store)
        XCTAssertEqual(store.sourceFolder, firstFolder)
        XCTAssertEqual(store.items.first?.rating, .yes)
    }

    func testSlowValidationRunsOffMainAndRetainsAccessUntilWorkerExit() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entered = expectation(description: "Directory read entered")
        let stopped = expectation(description: "Scope released")
        let release = DispatchSemaphore(value: 0)
        let scope = DispatchSemaphore(value: 0)
        let store = SessionStore()
        let opening = FolderOpening(readDirectory: { url in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(scope.wait(timeout: .now()), .success)
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }, resourceAccess: .init(start: { _ in
            XCTAssertFalse(Thread.isMainThread)
            scope.signal()
            return true
        }, stop: { _ in stopped.fulfill() }))
        opening.store = store
        XCTAssertNil(opening.open([folder]))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertNil(store.sourceFolder)
        XCTAssertNil(opening.error)
        // The main actor remains available while the worker is blocked.
        let staleTask = opening.validationTask
        XCTAssertNotNil(opening.open([]))
        release.signal()
        await staleTask?.value
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertNil(store.sourceFolder)
        XCTAssertEqual(opening.error, L10n.text("Open one folder at a time."))
    }

    func testNewerRequestRetiresSlowValidation() async throws {
        let first = try makeFolder()
        let second = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let entered = expectation(description: "First validation entered")
        let release = DispatchSemaphore(value: 0)
        let opening = FolderOpening(readDirectory: { url in
            if url == first {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        })
        let store = SessionStore()
        opening.store = store
        opening.open([first])
        let staleTask = opening.validationTask
        await fulfillment(of: [entered], timeout: 5)
        let provider = NSItemProvider(item: second as NSURL, typeIdentifier: UTType.fileURL.identifier)
        XCTAssertTrue(opening.openDroppedFolder([provider]))
        for _ in 0..<500 where store.sourceFolder != second {
            try await Task.sleep(for: .milliseconds(10))
        }
        await opening.validationTask?.value
        XCTAssertEqual(store.sourceFolder, second)
        release.signal()
        await staleTask?.value
        XCTAssertEqual(store.sourceFolder, second)
        XCTAssertNil(opening.error)
        store.cancelScan()
    }

    func testNewerMenuOpenRetiresSlowExternalValidation() async throws {
        let first = try makeFolder()
        let second = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let entered = expectation(description: "External validation entered")
        let release = DispatchSemaphore(value: 0)
        let opening = FolderOpening(readDirectory: { url in
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        })
        let store = SessionStore()
        opening.store = store
        opening.open([first])
        await fulfillment(of: [entered], timeout: 5)
        store.openFolder(second)
        release.signal()
        await opening.validationTask?.value
        XCTAssertEqual(store.sourceFolder, second)
        XCTAssertNil(opening.error)
        store.cancelScan()
    }

    func testGatesAreRecheckedAfterValidation() async throws {
        for operation in [false, true] {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let entered = expectation(description: "Validation entered")
            let release = DispatchSemaphore(value: 0)
            let opening = FolderOpening(readDirectory: { url in
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            })
            let store = SessionStore()
            opening.store = store
            opening.open([folder])
            await fulfillment(of: [entered], timeout: 5)
            if operation { store.beginTerminationPreparation() }
            else { store.isFilterPresented = true }
            release.signal()
            await opening.validationTask?.value
            XCTAssertNil(store.sourceFolder)
            XCTAssertEqual(opening.error, operation
                ? L10n.text("Wait for Louppe to finish its current operation, then try again.")
                : L10n.text("Close the current dialog or popover, then open the folder."))
            store.cancelTerminationPreparation()
            store.isFilterPresented = false
        }
    }

    private func waitUntilReady(_ store: SessionStore) async throws {
        for _ in 0..<500 {
            if case .ready = store.phase { return }
            if let error = store.scanError { XCTFail(error); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Disposable folder scan did not finish")
    }

    func testDockOpenBeforeSceneMountIsBufferedUntilLaunchCompletes() async throws {
        try requireForegroundUI()
        _ = NSApplication.shared
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let delegate = LouppeApplicationDelegate()
        delegate.application(NSApp, open: [folder])
        let store = SessionStore()
        let opening = FolderOpening()
        var windowWasRequested = false
        delegate.configure(store: store, folderOpening: opening) {
            windowWasRequested = true
        }
        XCTAssertNil(store.sourceFolder)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await Task.sleep(for: .milliseconds(30))
        await opening.validationTask?.value
        XCTAssertTrue(windowWasRequested)
        XCTAssertEqual(store.sourceFolder, folder)
        XCTAssertNil(opening.error)
        store.cancelScan()
        // Restore the singleton service provider after this isolated delegate test.
        NSApp.servicesProvider = nil
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeFolderOpening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
