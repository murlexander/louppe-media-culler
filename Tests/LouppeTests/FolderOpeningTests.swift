import AppKit
import XCTest
@testable import Louppe

@MainActor
final class FolderOpeningTests: XCTestCase {
    func testOnlyOneLocalFolderIsAccepted() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.txt")
        try Data("fixture".utf8).write(to: file)
        XCTAssertNil(FolderOpening.validationError(for: [folder]))
        XCTAssertNotNil(FolderOpening.validationError(for: []))
        XCTAssertNotNil(FolderOpening.validationError(for: [folder, folder]))
        XCTAssertNotNil(FolderOpening.validationError(for: [file]))
        XCTAssertNotNil(FolderOpening.validationError(for: [URL(string: "https://example.com/photos")!]))
    }

    func testModalPresentationRefusesFolderReplacement() throws {
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
        try await waitUntilReady(store)
        store.rate(.yes)
        XCTAssertNil(opening.open([secondFolder]))
        for _ in 0..<500 where store.sourceFolder != secondFolder || store.isFileOperationRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntilReady(store)
        XCTAssertEqual(store.sourceFolder, secondFolder)
        XCTAssertNil(opening.open([firstFolder]))
        for _ in 0..<500 where store.sourceFolder != firstFolder || store.isFileOperationRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntilReady(store)
        XCTAssertEqual(store.sourceFolder, firstFolder)
        XCTAssertEqual(store.items.first?.rating, .yes)
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
