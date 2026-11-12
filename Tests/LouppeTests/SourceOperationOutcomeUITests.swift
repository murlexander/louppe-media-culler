import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Composed UI regressions. Windows stay inactive and offscreen; input goes
/// through the installed session monitor or the rendered native controls.
@MainActor
final class SourceOperationOutcomeUITests: XCTestCase {
    func testPartialRenameAndOrganizeOfferWorkingUndo() async throws {
        for kind in [SourceFileChangeKind.rename, .organization] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIOutcome-\(UUID())")
            let media = root.appendingPathComponent("Photos")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["A.txt", "B.txt"] { try Data(name.utf8).write(to: media.appendingPathComponent(name)) }
            let suite = "UIOutcome.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
                operationJournalDirectory: root.appendingPathComponent("Journals"), reviewDefaults: defaults)
            store.openFolder(media)
            try await until { store.items.count == 2 && isReady(store) }
            let snapshot = try XCTUnwrap(store.sourceOrganizationPlanningSnapshot(scope: .all))
            let configuration = kind == .rename
                ? FileRenamingPlanner.sourceConfiguration(metadata: .initial)
                : SourceOrganizationConfiguration.initial(hasMultipleTopLevelFolders: false)
            let plan = try SourceOrganizationPlanner.makePlan(sourceFolder: media,
                selectedItems: snapshot.selectedItems, familyContextItems: snapshot.familyContextItems,
                configuration: configuration, knownOriginFolderPathBytesByFileID: [:])
            XCTAssertTrue(plan.canExecute, "\(plan.collisions)")
            if kind == .rename { store.startSourceRename(plan) } else { store.startSourceOrganization(plan) }
            try await until { store.organizationOutcome != nil && isReady(store) && !store.isFileOperationRunning }
            XCTAssertEqual(store.organizationOutcome?.movedFiles, 2, store.organizationOutcome?.message ?? "")
            XCTAssertTrue(store.canUndo, "The completed files have a real undo record")
            // The result view accepts the worker's partial-success value. Use
            // its existing presentation seam without introducing filesystem
            // failures into this UI test (worker failures have separate owners).
            let outcome = SourceOrganizationOutcome(movedFiles: 2, failedItems: 1,
                message: "Another item could not be changed.", wasUndo: false)
            store.presentSourceFileOperationForTesting(outcome: outcome)
            let host = NSHostingView(rootView: SourceFileOperationOutcomeView(store: store, outcome: outcome, kind: kind, done: {})
                .frame(width: 680, height: 400).environment(\.accessibilityEnabled, true))
            let window = mount(host, size: CGSize(width: 680, height: 400))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            let undo = try XCTUnwrap(elements(host).first { string($0, "accessibilityLabel") == "Undo" },
                                     "Partial success must offer Undo beside the result")
            let screen = try XCTUnwrap(undo.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let frame = window.convertFromScreen(screen)
            try click(CGPoint(x: frame.midX, y: frame.midY), window: window)
            try await until { store.organizationOutcome?.wasUndo == true && isReady(store) && !store.isFileOperationRunning }
            XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent("A.txt")), Data("A.txt".utf8))
            XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent("B.txt")), Data("B.txt".utf8))
        }
    }

    func testResultsWithoutCompletedWorkOrAfterUndoHideUndo() async throws {
        let store = SessionStore()
        store.items = [PhotoItem(id: "A.JPG", primaryURL: URL(fileURLWithPath: "/tmp/A.JPG"),
            pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.rate(.yes, at: 0)
        XCTAssertTrue(store.canUndo)
        for outcome in [
            SourceOrganizationOutcome(movedFiles: 0, failedItems: 1, message: "No changes", wasUndo: false),
            SourceOrganizationOutcome(movedFiles: 1, failedItems: 0, message: nil, wasUndo: true)
        ] {
            let host = NSHostingView(rootView: SourceFileOperationOutcomeView(store: store, outcome: outcome,
                kind: .rename, done: {}).frame(width: 680, height: 400).environment(\.accessibilityEnabled, true))
            let window = mount(host, size: CGSize(width: 680, height: 400))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            XCTAssertFalse(elements(host).contains { string($0, "accessibilityLabel") == "Undo" })
        }
    }

    private func isReady(_ store: SessionStore) -> Bool {
        if case .ready = store.phase { return true }; return false
    }

    private func mount(_ host: NSView, size: CGSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        return window
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "UI operation timed out")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func elements(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(walk) }
            if let view = object as? NSView { view.subviews.forEach(walk) }
        }
        walk(root)
        return result
    }

    private func click(_ point: CGPoint, window: NSWindow) throws {
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(queued) }
    }
}
