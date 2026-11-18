import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Real key events to the presented Open With confirmation, a window-modal
/// alert sheet. The host window stays offscreen and the app need not be
/// active (another app is usually frontmost during a handover): the events
/// carry the sheet's window number, as AppKit routes them to the sheet. Run
/// only with `Scripts/test.sh --foreground` during a desktop handover.
@MainActor
final class OpenWithConfirmationAlertTests: XCTestCase {
    func testReturnOpensOnceAndEscapeOpensNothing() async throws {
        try requireForegroundUI()
        _ = NSApplication.shared
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 51)
        store.setIndex(0)
        store.selectAllVisible()
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let host = NSHostingView(rootView: SessionView(store: store))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        defer {
            store.pendingOpenWith = nil
            window.contentView = nil
            window.orderOut(nil)
        }

        // Return: the default Open button.
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        let sheet = try await presentedAlert(in: window, store: store)
        send(code: 36, characters: "\r", to: sheet)
        try await waitUntil { workspace.openCount == 1 && window.attachedSheet == nil }
        XCTAssertNil(store.pendingOpenWith)
        XCTAssertEqual(workspace.opens[0].urls.count, 51)

        // Escape: the cancel button.
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        let second = try await presentedAlert(in: window, store: store)
        send(code: 53, characters: "\u{1b}", to: second)
        try await waitUntil { window.attachedSheet == nil && store.pendingOpenWith == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(workspace.openCount, 1, "Escape opens nothing")
        XCTAssertFalse(store.isSessionCommandPresentationActive)
    }

    private func presentedAlert(in window: NSWindow, store: SessionStore) async throws -> NSWindow {
        try await waitUntil { store.pendingOpenWith != nil && window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.isSheet, "a window-modal alert, not a separate panel")
        return sheet
    }

    private func send(code: UInt16, characters: String, to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
