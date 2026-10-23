import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class NativeSearchFieldTests: XCTestCase {
    func testRegularNativeControlPublishesTypingImmediatelyAndNativeCancelClearsBinding() throws {
        let fixture = Fixture(text: "camera")
        defer { fixture.dismantle() }
        let field = fixture.field
        XCTAssertEqual(field.controlSize, .regular)
        XCTAssertTrue(field.sendsSearchStringImmediately)
        XCTAssertFalse(field.sendsWholeSearchString)
        XCTAssertEqual(field.maximumRecents, 0)
        XCTAssertEqual(field.accessibilityIdentifier(), "test.search")
        XCTAssertEqual(field.accessibilityLabel(), "Search media")

        let editor = try fixture.beginEditing()
        editor.selectAll(nil)
        editor.insertText("lens", replacementRange: editor.selectedRange())
        XCTAssertEqual(fixture.state.text, "lens")

        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        let cancel = try XCTUnwrap(cell.cancelButtonCell)
        cancel.performClick(field)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(fixture.state.text, "")
    }

    func testUpdatesPreserveNativeCaretAndSelectionAndClampForExternalReplacement() throws {
        let fixture = Fixture(text: "camera lens")
        defer { fixture.dismantle() }
        let editor = try fixture.beginEditing()
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        fixture.coordinator.update(fixture.field)
        fixture.coordinator.update(fixture.field)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 4))

        fixture.state.text = "RAW"
        fixture.coordinator.update(fixture.field)
        XCTAssertEqual(editor.string, "RAW")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testMarkedTextSurvivesExternalUpdatesAndOwnsPaletteCommandsUntilCommitted() throws {
        let fixture = Fixture(text: "")
        defer { fixture.dismantle() }
        let editor = try fixture.beginEditing()
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let composedText = editor.string
        let markedRange = editor.markedRange()
        let selection = editor.selectedRange()
        fixture.state.text = "external update"
        fixture.coordinator.update(fixture.field)
        XCTAssertEqual(editor.string, composedText)
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.selectedRange(), selection)

        for (selector, code, characters) in paletteCommands {
            XCTAssertFalse(fixture.coordinator.route(selector, editor: editor,
                                                      event: event(code, characters)))
        }
        XCTAssertTrue(fixture.state.commands.isEmpty)
        editor.unmarkText()
        editor.insertText("日本", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertEqual(fixture.state.text, "日本")
        XCTAssertTrue(fixture.coordinator.route(#selector(NSResponder.moveDown(_:)), editor: editor,
                                                event: event(125, "\u{F701}", [.numericPad, .function])))
        XCTAssertEqual(fixture.state.commands, ["move 1"])
    }

    func testPaletteOwnsOnlyUnmodifiedNavigationSubmitAndEscape() throws {
        let fixture = Fixture(text: "search")
        defer { fixture.dismantle() }
        let editor = try fixture.beginEditing()
        let nativeModifiers: [NSEvent.ModifierFlags] = [.shift, .command, .option, .control, .help]
        for (selector, code, characters) in paletteCommands {
            XCTAssertTrue(fixture.coordinator.route(selector, editor: editor,
                                                     event: event(code, characters)))
            for modifiers in nativeModifiers {
                XCTAssertFalse(fixture.coordinator.route(selector, editor: editor,
                                                         event: event(code, characters, modifiers)))
            }
        }
        XCTAssertEqual(fixture.state.commands, ["move -1", "move 1", "submit", "cancel"])
        for selector in [#selector(NSResponder.moveLeft(_:)),
                         #selector(NSResponder.moveRight(_:)),
                         #selector(NSResponder.moveLeftAndModifySelection(_:)),
                         #selector(NSResponder.selectAll(_:)),
                         #selector(NSResponder.deleteBackward(_:))] {
            XCTAssertFalse(fixture.coordinator.route(selector, editor: editor, event: nil))
        }
        fixture.coordinator.owner.onMove = nil
        fixture.coordinator.owner.onSubmit = nil
        fixture.coordinator.owner.onCancel = nil
        for (selector, code, characters) in paletteCommands {
            XCTAssertFalse(fixture.coordinator.route(selector, editor: editor,
                                                      event: event(code, characters)))
        }
    }

    func testNativeFieldEditorDispatchesPaletteCommandsAndRetainsSelectionEditing() throws {
        let fixture = Fixture(text: "search")
        defer { fixture.dismantle() }
        let editor = try fixture.beginEditing()
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(fixture.state.commands, ["move 1", "move -1"])
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.doCommand(by: #selector(NSResponder.moveLeftAndModifySelection(_:)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 1))
    }

    func testFocusRequestWaitsForAttachedKeyWindowAndDoesNotRepeatOnUpdates() {
        let fixture = Fixture(text: "", focusRequested: true)
        defer { fixture.dismantle() }
        drainMainQueue()
        XCTAssertNil(fixture.field.currentEditor())
        XCTAssertTrue(fixture.state.focusRequested)

        fixture.window.simulatesKeyWindow = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        drainMainQueue()
        XCTAssertNotNil(fixture.field.currentEditor())
        XCTAssertFalse(fixture.state.focusRequested)

        fixture.coordinator.update(fixture.field)
        fixture.window.makeFirstResponder(nil)
        fixture.coordinator.update(fixture.field)
        drainMainQueue()
        XCTAssertNil(fixture.field.currentEditor())

        fixture.state.focusRequested = true
        fixture.coordinator.update(fixture.field)
        drainMainQueue()
        XCTAssertNotNil(fixture.field.currentEditor())
    }

    func testQueuedFocusCannotFollowDetachedFieldIntoAnotherWindow() {
        let fixture = Fixture(text: "", focusRequested: true)
        defer { fixture.dismantle() }
        fixture.window.simulatesKeyWindow = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        fixture.field.removeFromSuperview()
        let replacement = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        replacement.simulatesKeyWindow = true
        replacement.contentView?.addSubview(fixture.field)
        drainMainQueue()
        XCTAssertNil(fixture.field.currentEditor())
        XCTAssertFalse(fixture.state.focusRequested)
        replacement.contentView = nil
    }

    func testResigningWindowAndDismantleCancelPendingFocusAndReleaseEditor() throws {
        let fixture = Fixture(text: "", focusRequested: true)
        fixture.window.simulatesKeyWindow = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        fixture.window.simulatesKeyWindow = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        drainMainQueue()
        XCTAssertNil(fixture.field.currentEditor())
        XCTAssertFalse(fixture.state.focusRequested)

        _ = try fixture.beginEditing()
        fixture.state.focusRequested = true
        fixture.coordinator.update(fixture.field)
        fixture.dismantle()
        drainMainQueue()
        XCTAssertNil(fixture.field.currentEditor())
        XCTAssertNil(fixture.field.delegate)
        XCTAssertNil(fixture.field.target)
        XCTAssertFalse(fixture.state.focusRequested)
    }

    private var paletteCommands: [(Selector, UInt16, String)] {
        [(#selector(NSResponder.moveUp(_:)), 126, "\u{F700}"),
         (#selector(NSResponder.moveDown(_:)), 125, "\u{F701}"),
         (#selector(NSResponder.insertNewline(_:)), 36, "\r"),
         (#selector(NSResponder.cancelOperation(_:)), 53, "\u{1b}")]
    }

    private func event(_ code: UInt16, _ characters: String,
                       _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    @MainActor
    private final class State {
        var text: String
        var focusRequested: Bool
        var commands: [String] = []
        init(text: String, focusRequested: Bool) {
            self.text = text
            self.focusRequested = focusRequested
        }
    }

    /// Offscreen windows exercise AppKit field editors without raising an app
    /// or taking keyboard focus from the person running the suite.
    @MainActor
    private final class TestWindow: NSWindow {
        var simulatesKeyWindow = false
        override var isKeyWindow: Bool { simulatesKeyWindow }
    }

    @MainActor
    private final class Fixture {
        let state: State
        let coordinator: NativeSearchField.Coordinator
        let field: NativeSearchField.SearchField
        let window: TestWindow

        init(text: String, focusRequested: Bool = false) {
            _ = NSApplication.shared
            let state = State(text: text, focusRequested: focusRequested)
            self.state = state
            let view = NativeSearchField(
                text: Binding(get: { state.text }, set: { state.text = $0 }),
                placeholder: "Find media", accessibilityLabel: "Search media",
                accessibilityIdentifier: "test.search",
                focusRequested: Binding(get: { state.focusRequested }, set: { state.focusRequested = $0 }),
                onMove: { state.commands.append("move \($0)") },
                onSubmit: { state.commands.append("submit") },
                onCancel: { state.commands.append("cancel") }
            )
            coordinator = view.makeCoordinator()
            field = coordinator.makeField()
            window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
            field.frame = NSRect(x: 12, y: 24, width: 360, height: 28)
            window.contentView?.addSubview(field)
        }

        func beginEditing() throws -> NSTextView {
            XCTAssertTrue(window.makeFirstResponder(field))
            return try XCTUnwrap(field.currentEditor() as? NSTextView)
        }

        func dismantle() {
            coordinator.dismantle(field)
            field.removeFromSuperview()
            window.contentView = nil
        }
    }
}
