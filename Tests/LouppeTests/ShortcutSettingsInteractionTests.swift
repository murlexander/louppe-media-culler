import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ShortcutSettingsInteractionTests: XCTestCase {
    func testReviewIncludesTheFormerActionsWithoutChangingActionIdentity() {
        XCTAssertEqual(ReviewShortcutAction.allCases.filter { $0.group == .review },
                       [.yes, .no, .export, .clear, .undo])
        XCTAssertEqual(ReviewShortcutGroup.allCases.map(\.rawValue),
                       ["review", "navigation", "playback", "view", "stars"])
    }

    func testSearchDoesNotAcceptAutomaticFocusAndEditsAfterClick() throws {
        var query = ""
        let host = NSHostingView(rootView: NativeSearchField(text: Binding(
            get: { query }, set: { query = $0 }
        ), placeholder: L10n.text("Find a shortcut"),
           accessibilityLabel: L10n.text("Find a shortcut"),
           accessibilityIdentifier: "louppe.shortcutSearch", requiresExplicitFocus: true).frame(width: 400, height: 26))
        let window = mount(host)
        defer { window.close() }
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSearchField.SearchField }.first)

        XCTAssertNil(field.currentEditor(), "Mounting the field must not start editing")
        XCTAssertFalse(field.acceptsFirstResponder, "Automatic focus must leave search inactive")
        XCTAssertNil(field.currentEditor())

        try click(host, window: window, x: 100, fromTop: 13)
        let editor = try XCTUnwrap(field.currentEditor(), "Clicking must activate the native text editor")
        editor.insertText("Export")
        settle(host)
        XCTAssertEqual(query, "Export", "Native edits must reach the production search binding")

        window.makeFirstResponder(nil)
        XCTAssertFalse(field.acceptsFirstResponder, "Ending an edit must restore the automatic-focus guard")
        field.setAccessibilityFocused(true)
        XCTAssertNotNil(field.currentEditor(), "VoiceOver must still be able to explicitly activate search")
    }

    func testShortcutGroupsStartCollapsedAndSearchRevealsMatches() throws {
        let host = NSHostingView(rootView: LouppeSettingsForm {
            ReviewShortcutsSettingsView()
        }.frame(width: 620, height: 600))
        let window = mount(host)
        defer { window.close() }
        XCTAssertFalse(descendants(host).contains { $0 is ReviewShortcutRecorderButton },
                       "Every shortcut group must start collapsed")
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSearchField.SearchField }.first)
        field.stringValue = L10n.text("Export")
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        settle(host)
        XCTAssertTrue(descendants(host).contains { $0 is ReviewShortcutRecorderButton },
                      "Searching must reveal matching shortcut editors without manually opening a group")
        field.stringValue = ""
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        settle(host)
        XCTAssertFalse(descendants(host).contains { $0 is ReviewShortcutRecorderButton },
                       "Clearing search must return to the collapsed groups")
    }

    func testEntireDisclosureHeaderTogglesInBothDirectionsAndKeepsChildrenSeparate() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let state = ShortcutHitState()
            let host = NSHostingView(rootView: DisclosureGroup(isExpanded: Binding(
                get: { state.expanded }, set: { state.expanded = $0 })) {
                Button { state.childPresses += 1 } label: {
                    Text("Child control").frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            } label: { Text("Review") }
                .disclosureGroupStyle(ShortcutDisclosureStyle())
                .frame(width: 400)
                .environment(\.layoutDirection, direction))
            let window = mount(host)
            defer { window.close() }
            XCTAssertGreaterThanOrEqual(host.bounds.height, 32)
            for corner in [(2.0, 2.0), (398.0, 2.0), (2.0, 30.0), (398.0, 30.0)] {
                try click(host, window: window, x: corner.0, fromTop: corner.1)
                XCTAssertTrue(state.expanded, "Whole header must open: \(direction), \(corner)")
                try click(host, window: window, x: corner.0, fromTop: corner.1)
                XCTAssertFalse(state.expanded, "Same header point must close")
            }
            try click(host, window: window, x: 398, fromTop: 16)
            try click(host, window: window, x: 200, fromTop: 48)
            XCTAssertEqual(state.childPresses, 1)
            XCTAssertTrue(state.expanded, "Editor controls must not collapse the section")
        }
    }

    func testAccessorySymbolsHaveEqualNativeBoundsAndRemainClickable() throws {
        var expected: CGSize?
        for symbol in ["plus", "arrow.counterclockwise", "minus", "xmark"] {
            let state = ShortcutHitState()
            let host = NSHostingView(rootView: ShortcutAccessoryButton(symbol: symbol, title: symbol) {
                state.childPresses += 1
            })
            let window = mount(host)
            defer { window.close() }
            let size = host.fittingSize
            XCTAssertGreaterThanOrEqual(size.width, 24)
            XCTAssertGreaterThanOrEqual(size.height, 24)
            if let expected {
                XCTAssertEqual(size.width, expected.width, accuracy: 0.1)
                XCTAssertEqual(size.height, expected.height, accuracy: 0.1)
            } else { expected = size }
            try click(host, window: window, x: size.width / 2, fromTop: size.height / 2)
            XCTAssertEqual(state.childPresses, 1)
        }
    }

    func testCommandRecorderCapturesModifiedAliasesAndKeepsFailedCaptureActive() throws {
        let recorder = CommandShortcutRecorderButton()
        var accepted: [CommandShortcutBinding] = []
        var invalid = 0
        recorder.onInvalid = { invalid += 1 }
        recorder.onCapture = { accepted.append($0); return accepted.count > 1 }
        recorder.startRecording()
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key("b", code: 11, flags: [.command, .shift])))
        XCTAssertTrue(recorder.isRecording, "A conflict keeps the recorder open for another choice")
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key("t", code: 17, flags: .command)))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(accepted.map(\.modifiers), [.commandShift, .command])
        XCTAssertEqual(accepted.map(\.character), ["b", "t"])
        XCTAssertEqual(invalid, 0)
    }

    func testCommandRecorderPreservesNativeChordsAndEscapeCancelsWithoutBinding() throws {
        let recorder = CommandShortcutRecorderButton()
        var captures = 0
        var cancellations = 0
        recorder.onCapture = { _ in captures += 1; return true }
        recorder.onCancel = { cancellations += 1 }
        recorder.startRecording()
        XCTAssertFalse(recorder.performKeyEquivalent(with: try key("f", code: 3, flags: [.control, .option])))
        XCTAssertFalse(recorder.isRecording)
        recorder.startRecording()
        XCTAssertFalse(recorder.performKeyEquivalent(with: try key("\t", code: 48, flags: [])))
        XCTAssertFalse(recorder.isRecording, "Tab retains native focus navigation")
        recorder.startRecording()
        XCTAssertTrue(recorder.performKeyEquivalent(with: try key("\u{1b}", code: 53, flags: [])))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(captures, 0)
    }

    func testCommandRecorderUnmodifiedLetterIsInvalidAndRepeatDoesNotCapture() throws {
        let recorder = CommandShortcutRecorderButton()
        var invalid = 0
        var captures = 0
        recorder.onInvalid = { invalid += 1 }
        recorder.onCapture = { _ in captures += 1; return true }
        recorder.startRecording()
        recorder.keyDown(with: try key("b", code: 11, flags: []))
        recorder.keyDown(with: try key("b", code: 11, flags: .command, repeating: true))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(invalid, 1)
        XCTAssertEqual(captures, 0)
    }

    func testModifierObserverBelongsOnlyToAttachedSettingsWindow() {
        _ = NSApplication.shared
        let observer = ShortcutModifierObserver.MonitorView()
        XCTAssertFalse(observer.isInstalled)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = observer
        XCTAssertTrue(observer.isInstalled)
        observer.installIfNeeded()
        XCTAssertTrue(observer.isInstalled)
        window.contentView = nil
        XCTAssertFalse(observer.isInstalled)
        window.contentView = observer
        XCTAssertTrue(observer.isInstalled)
        observer.removeMonitor()
        XCTAssertFalse(observer.isInstalled)
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code))
    }

    private func mount<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Keep the test window behind the user's apps, offscreen. App-local key
        // status enables native event routing without activating this process.
        window.orderBack(nil)
        window.makeKey()
        settle(host)
        return window
    }

    private func click(_ host: NSView, window: NSWindow, x: Double, fromTop: Double) throws {
        let y = host.isFlipped ? fromTop : host.bounds.height - fromTop
        let point = host.convert(NSPoint(x: x, y: y), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: time + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Native buttons may track synchronously; make mouse-up available to
        // that loop. SwiftUI buttons that do not track consume it below.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                        inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
        settle(host)
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
@Observable
private final class ShortcutHitState {
    var expanded = false
    var childPresses = 0
}
