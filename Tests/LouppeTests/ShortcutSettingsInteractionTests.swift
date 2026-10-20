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
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
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
}

@MainActor
@Observable
private final class ShortcutHitState {
    var expanded = false
    var childPresses = 0
}
