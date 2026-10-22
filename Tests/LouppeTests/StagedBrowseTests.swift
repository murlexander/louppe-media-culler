import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class StagedBrowseTests: XCTestCase {
    func testManualViewportIsHandedOffWithoutChoosingTheCurrentPhoto() {
        let item = PhotoItem(id: "A.JPG", primaryURL: URL(fileURLWithPath: "/tmp/A.JPG"),
                             pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        let opening = OpeningSessionState(snapshot: .init(items: [item]), viewMode: .grid, sourceAccess: nil)
        let receipt = OpeningViewportReceipt(surface: .grid, physicalFileID: item.primaryFile.id, topOffset: -17)
        opening.recordViewport(receipt, userInitiated: false)
        XCTAssertTrue(opening.handoff().viewportReceipts.isEmpty)
        opening.recordViewport(receipt)
        XCTAssertEqual(opening.handoff().viewportReceipts[.grid], receipt)
        XCTAssertNil(opening.handoff().currentPhysicalFileID)
    }

    func testUninteractedPreviewUsesFinalDefaultSortForInitialCurrent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "LouppeUninteractedPreview.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        ReviewPreferences(defaultSort: PhotoSort(key: .name, ascending: false),
                          isGroupingEnabled: false, defaultView: .grid).save(to: defaults)
        let gate = StagedBrowseGate()
        defer { gate.release.signal() }
        let store = SessionStore(persistence: StagedBrowsePersistence(), reviewDefaults: defaults)
        store.openingWorkerHooksForTesting = .init(metadataReader: { _ in gate.enter(); return .init() })
        store.openFolder(root)
        try await eventually { store.openingSession != nil && gate.entered }
        XCTAssertNil(store.openingSession?.handoff().currentPhysicalFileID,
                     "Creating a preview does not choose the authoritative current photo")
        let opening = try XCTUnwrap(store.openingSession)
        opening.recordViewport(.init(surface: .grid, physicalFileID: opening.items[0].primaryFile.id, topOffset: 12),
                               userInitiated: false)
        XCTAssertTrue(opening.handoff().viewportReceipts.isEmpty,
                      "Automatic preview positioning must not override the final default photo")
        gate.release.signal()
        try await eventually { if case .ready = store.phase { return true }; return false }
        XCTAssertEqual(store.currentItem?.id, "C.JPG")
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testEarlyBrowseHasNoSessionMutationOrSaveAuthorityAndHandsOffLatestSelection() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StagedBrowsePersistence()
        let gate = StagedBrowseGate()
        defer { gate.release.signal() }
        let store = SessionStore(persistence: persistence)
        store.openingWorkerHooksForTesting = .init(metadataReader: { _ in
            gate.enter()
            return MetadataExtractor.ScanInfo()
        })
        store.openFolder(root)
        try await eventually { store.openingSession != nil && gate.entered }
        let opening = try XCTUnwrap(store.openingSession)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertFalse(store.canRate)
        let original = opening.items.map(\.metadataSnapshots)
        store.rate(.yes)
        store.rate(.no, at: 0)
        store.saveSession()
        XCTAssertEqual(opening.items.map(\.metadataSnapshots), original)
        let earlySaves = await persistence.saveCount
        XCTAssertEqual(earlySaves, 0)
        let selected = try XCTUnwrap(opening.items.last)
        opening.select(selected.id)
        opening.viewMode = .grid
        opening.recordViewport(.init(surface: .grid, physicalFileID: opening.items[0].primaryFile.id, topOffset: -17))
        gate.release.signal()
        try await eventually { if case .ready = store.phase { return true }; return false }
        XCTAssertNil(store.openingSession)
        XCTAssertEqual(store.currentItem?.id, selected.id)
        XCTAssertEqual(Set(store.selectedIndices.map { store.items[$0].id }), [selected.id])
        XCTAssertEqual(store.viewMode, .grid)
        let receipt = try XCTUnwrap(store.pendingOpeningViewportReceipt(for: .grid))
        XCTAssertNotEqual(receipt.physicalFileID, store.currentItem?.id)
        XCTAssertEqual(receipt.topOffset, -17)
        store.consumeOpeningViewportReceipt(for: .grid)
        XCTAssertNil(store.pendingOpeningViewportReceipt(for: .grid))
    }

    func testCancelledAndSupersededSameURLSnapshotCannotPublishOrBecomeReady() async throws {
        for close in [false, true] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let gate = StagedBrowseGate()
            defer { gate.release.signal() }
            let store = SessionStore(persistence: StagedBrowsePersistence())
            store.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
                if stage == .previewIdentityValidation { gate.enter() }
            })
            store.openFolder(root)
            try await eventually { gate.entered }
            if close { store.closeSession() } else { store.cancelScan() }
            XCTAssertNil(store.openingSession)
            if !close {
                store.openingWorkerHooksForTesting = .init()
                store.openFolder(root)
                try await eventually { if case .ready = store.phase { return true }; return false }
            }
            gate.release.signal()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertNil(store.openingSession)
            if close { XCTAssertTrue(store.items.isEmpty) }
            else { XCTAssertEqual(store.items.count, 3) }
        }
    }

    func testNewFolderSupersedesUnpublishedSnapshot() async throws {
        let root = try fixture()
        let next = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: next) }
        try Data("next only".utf8).write(to: next.appendingPathComponent("D.JPG"))
        let gate = StagedBrowseGate()
        defer { gate.release.signal() }
        let store = SessionStore(persistence: StagedBrowsePersistence())
        store.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
            if stage == .previewPublication { gate.enter() }
        })
        store.openFolder(root)
        try await eventually { gate.entered }
        store.openingWorkerHooksForTesting = .init()
        store.openFolder(next)
        try await eventually { if case .ready = store.phase { return true }; return false }
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(store.sourceFolder, next.standardizedFileURL)
        XCTAssertEqual(store.items.count, 4)
        XCTAssertNil(store.openingSession)
    }

    func testPreviewBoundaryRejectsReplacementBeforeAnyEarlyPixels() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(persistence: StagedBrowsePersistence())
        store.openingWorkerHooksForTesting = .init(willBeginStage: { stage in
            if stage == .previewIdentityValidation {
                try Data("replacement".utf8).write(to: root.appendingPathComponent("A.JPG"), options: .atomic)
            }
        })
        store.openFolder(root)
        try await eventually { store.scanError != nil }
        XCTAssertNil(store.openingSession)
        XCTAssertTrue(store.items.isEmpty)
    }

    #if DEBUG
    func testMountedEarlyGalleryAndGridKeepPendingCapabilitiesAndSessionAuthoritySeparate() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = StagedBrowseGate()
        defer { gate.release.signal() }
        let store = SessionStore(persistence: StagedBrowsePersistence())
        store.openingWorkerHooksForTesting = .init(metadataReader: { _ in gate.enter(); return .init() })
        store.openFolder(root)
        try await eventually { store.openingSession != nil && gate.entered }
        let opening = try XCTUnwrap(store.openingSession)
        let host = NSHostingView(rootView: OpeningSessionView(state: opening, cancel: store.cancelScan))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); store.cancelScan() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(markers(in: host).isEmpty)
        opening.viewMode = .grid
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(markers(in: host).isEmpty)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.canRate)
    }

    private func markers(in view: NSView) -> [ThumbnailRenderMarker.MarkerView] {
        (view as? ThumbnailRenderMarker.MarkerView).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    #endif

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-Staged-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A.JPG", "B.JPG", "C.JPG"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        return root
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("staged opening did not reach the expected state")
        throw CocoaError(.coderInvalidValue)
    }
}

private final class StagedBrowseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasEntered = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return hasEntered }
    func enter() {
        lock.lock()
        let first = !hasEntered
        hasEntered = true
        lock.unlock()
        if first { _ = release.wait(timeout: .now() + 10) }
    }
}

private actor StagedBrowsePersistence: SessionPersistenceClient {
    private(set) var saveCount = 0
    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?) async -> SessionPersistence.ReadResult {
        .init(session: nil, origin: nil, problems: [], access: .init(id: UUID(), folderIdentity: folderIdentity, sidecarRevision: .absent))
    }
    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        saveCount += 1
        return .savedToSidecar
    }
}
