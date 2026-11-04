import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class NativeSelectionControlsTests: XCTestCase {
    func testNativeAddMenuDefersBothActionsAndFocusesTheirRecorderAfterTracking() throws {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("NSHostingMenu requires macOS 14.4; the production SwiftUI Menu supports macOS 14.")
        }
        _ = NSApplication.shared
        for (index, choice) in ShortcutAddMenuItems.Choice.allCases.enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let review = ReviewShortcutRecorderButton()
            let command = CommandShortcutRecorderButton()
            var selected: [ShortcutAddMenuItems.Choice] = []
            var captures = 0
            review.automaticallyRecord = true
            review.onCapture = { _ in captures += 1; return true }
            command.automaticallyRecord = true
            command.onCapture = { _ in captures += 1; return true }
            let menu = NSHostingMenu(rootView: ShortcutAddMenuItems { selection in
                selected.append(selection)
                window.contentView?.addSubview(selection == .singleKey ? review : command)
            })
            menu.update()
            XCTAssertEqual(menu.items.map(\.title), ShortcutAddMenuItems.Choice.allCases.map(\.title))
            menu.performActionForItem(at: index)
            XCTAssertTrue(selected.isEmpty, "Menu actions must not mount a recorder synchronously")
            _ = RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
            XCTAssertTrue(selected.isEmpty, "Menu tracking must retain focus until it ends")
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(selected, [choice])
            XCTAssertFalse(window.isVisible, "This interaction test must not take over the desktop")

            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: choice == .command ? .command : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "b",
                charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
            switch choice {
            case .singleKey:
                XCTAssertTrue(window.firstResponder === review)
                XCTAssertTrue(review.isRecording)
                review.keyDown(with: event)
                XCTAssertFalse(review.isRecording)
            case .command:
                XCTAssertTrue(window.firstResponder === command)
                XCTAssertTrue(command.isRecording)
                XCTAssertTrue(command.performKeyEquivalent(with: event))
                XCTAssertFalse(command.isRecording)
            }
            XCTAssertEqual(captures, 1, "The first key after menu dismissal belongs to the new recorder")
        }
    }

    func testSortPickerMemberBindingsReorderWithoutChangingFilesDecisionsOrCurrentPhoto() throws {
        let suite = "NativeSelectionControlsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        store.items = ["C.JPG", "A.JPG", "B.JPG"].enumerated().map { index, name in
            PhotoItem(primaryFile: PhotoFile(id: name, url: URL(fileURLWithPath: "/tmp/\(name)"),
                captureDate: Date(timeIntervalSince1970: Double(index)), cameraModel: nil,
                lensModel: nil, fileSize: 1, rating: index == 1 ? .yes : .undecided))
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.setIndex(1)
        let originals = store.items.map(\.primaryFile.url)
        let decisions = store.items.map(\.rating)
        let currentID = store.items[store.currentIndex].id
        let view = SortView(store: store)

        // These are the direct ObservedObject member bindings used by the
        // native Pickers, including writeback through PhotoSort's value type.
        view.$store.sort.key.wrappedValue = .name
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["A.JPG", "B.JPG", "C.JPG"])
        view.$store.sort.ascending.wrappedValue = false
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["C.JPG", "B.JPG", "A.JPG"])
        view.$store.isGroupingEnabled.wrappedValue = false
        XCTAssertFalse(store.isGroupingEnabled)
        XCTAssertEqual(store.items.map(\.primaryFile.url), originals)
        XCTAssertEqual(store.items.map(\.rating), decisions)
        XCTAssertEqual(store.items[store.currentIndex].id, currentID)
    }
}
