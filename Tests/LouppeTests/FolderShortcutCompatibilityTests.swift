import AppKit
import XCTest
@testable import Louppe

@MainActor
final class FolderShortcutCompatibilityTests: XCTestCase {
    func testEstablishedDefaultIDsAndInventoryOrderStayStable() {
        let established = "yes no previous next previousRow nextRow playPause seekBackward seekForward browser info clipping grid export clear undo actualSize phoneSize clearStars oneStar twoStars threeStars fourStars fiveStars".split(separator: " ").map(String.init)
        XCTAssertEqual(Array(ReviewShortcutAction.allCases.prefix(established.count)).map(\.rawValue), established)
        for (position, name) in established.enumerated() {
            let action = ReviewShortcutAction(rawValue: name)!
            for (offset, assignment) in ReviewShortcutPreferences.defaultAssignments(for: action).enumerated() {
                XCTAssertEqual(assignment.id.uuidString.lowercased(), "00000000-0000-0000-0000-" + String(format: "%012x", position * 16 + offset + 1))
            }
        }
        XCTAssertEqual(CommandShortcutAction.allCases.last, .enclosingFolder)
        XCTAssertEqual(CommandShortcutPreferences.defaultBindings(for: .enclosingFolder).first?.display, "⌘↑")
    }

    func testLegacyBindingsOnNewDefaultsSurviveInBothInterpretations() throws {
        for mode in ReviewShortcutInterpretation.allCases {
            let raw = """
            {"interpretation":"\(mode.rawValue)","customBindings":{
              "yes":{"character":"t","keyCode":17},
              "no":{"character":"[","keyCode":33},
              "info":{"character":"]","keyCode":30}}}
            """
            let preferences = try JSONDecoder().decode(ReviewShortcutPreferences.self, from: Data(raw.utf8))
            XCTAssertEqual(preferences.interpretation, mode)
            XCTAssertEqual(preferences.assignments(for: .yes).first?.binding.character, "t")
            XCTAssertEqual(preferences.assignments(for: .no).first?.binding.character, "[")
            XCTAssertEqual(preferences.assignments(for: .info).first?.binding.character, "]")
            for action in newActions { XCTAssertTrue(preferences.assignments(for: action).isEmpty) }
            XCTAssertEqual(ReviewShortcutPreferences.decode(preferences.encoded), preferences)
        }
    }

    func testSchemaTwoMissingDefaultsYieldOnlyInTheAffectedMode() throws {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        for action in newActions {
            XCTAssertTrue(preferences.remove(preferences.assignments(for: action)[0].id, for: action))
        }
        XCTAssertTrue(preferences.add(.init(character: "t", keyCode: 17), for: .yes))
        XCTAssertTrue(preferences.add(.init(character: "[", keyCode: 33), for: .no))
        XCTAssertTrue(preferences.add(.init(character: "]", keyCode: 30), for: .info))
        let raw = try omittingNewEntries(preferences)
        var loaded = try JSONDecoder().decode(ReviewShortcutPreferences.self, from: raw)
        for action in newActions { XCTAssertTrue(loaded.assignments(for: action).isEmpty) }
        XCTAssertEqual(loaded.assignments(for: .yes), preferences.assignments(for: .yes))
        loaded.interpretation = .physicalPosition
        for action in newActions { XCTAssertEqual(loaded.assignments(for: action), ReviewShortcutPreferences.defaultAssignments(for: action)) }
        XCTAssertEqual(ReviewShortcutPreferences.decode(loaded.encoded), loaded)
    }

    func testMigrationComparesActiveKeyMeaningAndOverlappingContexts() throws {
        for mode in ReviewShortcutInterpretation.allCases {
            var preferences = ReviewShortcutPreferences(interpretation: mode)
            let action = ReviewShortcutAction.folders
            XCTAssertTrue(preferences.remove(preferences.assignments(for: action)[0].id, for: action))
            let binding = mode == .physicalPosition
                ? ReviewShortcutBinding(character: "v", keyCode: 17)
                : ReviewShortcutBinding(character: "t", keyCode: 9)
            XCTAssertTrue(preferences.add(binding, for: .yes, scope: .galleryPhotos))
            let loaded = try JSONDecoder().decode(ReviewShortcutPreferences.self, from: omittingNewEntries(preferences))
            XCTAssertTrue(loaded.assignments(for: .folders).isEmpty)
            XCTAssertEqual(loaded.assignments(for: .yes), preferences.assignments(for: .yes))
        }
    }

    func testNewActionsConflictNormallyAfterMigration() {
        for mode in ReviewShortcutInterpretation.allCases {
            var preferences = ReviewShortcutPreferences(interpretation: mode)
            for action in newActions {
                let binding = ReviewShortcutPreferences.defaultBinding(for: action)
                XCTAssertEqual(preferences.conflict(for: binding, action: .yes)?.action, action)
                XCTAssertFalse(preferences.add(binding, for: .yes))
            }
        }
    }

    func testBracketsFollowLayoutOrPositionAndDoNotRequireNavigationFocus() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertEqual(preferences.match(for: event("]", 9), context: .gridEmpty), .init(action: .nextFolder, requiresNavigationFocus: false))
        XCTAssertNil(preferences.match(for: event("v", 30), context: .gridPhoto))
        preferences.interpretation = .physicalPosition
        XCTAssertEqual(preferences.match(for: event("v", 30), context: .galleryEmpty)?.action, .nextFolder)
        XCTAssertEqual(preferences.match(for: event("v", 33), context: .gridPhoto)?.action, .previousFolder)
        XCTAssertNil(preferences.match(for: event("]", 9), context: .galleryPhoto))
    }

    func testCommandArrowCanBeRecordedEditedAndRemovedWithoutFallback() throws {
        var preferences = CommandShortcutPreferences()
        let original = try XCTUnwrap(preferences.bindings(for: .enclosingFolder).first)
        XCTAssertTrue(original.isValid)
        let event = event("", 126, [.command, .function, .numericPad])
        XCTAssertEqual(CommandShortcutBinding.capture(event), original)
        XCTAssertEqual(preferences.match(for: event, context: .gridEmpty), .enclosingFolder)
        XCTAssertNotNil(preferences.conflict(for: original, action: .export))
        XCTAssertTrue(preferences.remove(original, for: .enclosingFolder))
        XCTAssertNil(preferences.match(for: event, context: .galleryPhoto))
        XCTAssertTrue(preferences.add(.init(character: "t", keyCode: 17, modifiers: .command), for: .enclosingFolder))
        XCTAssertEqual(CommandShortcutPreferences.decode(preferences.encoded), preferences)
        XCTAssertTrue(preferences.reset(for: .enclosingFolder))
        XCTAssertEqual(preferences, CommandShortcutPreferences())
        let recorder = CommandShortcutRecorderButton()
        var captured: CommandShortcutBinding?
        recorder.onCapture = { captured = $0; return true }
        recorder.startRecording()
        XCTAssertTrue(recorder.performKeyEquivalent(with: event))
        XCTAssertEqual(captured, original)
    }

    func testMissingCommandDefaultYieldsToSavedArrowAndRoundTrips() throws {
        let raw = #"{"schemaVersion":1,"customBindings":{"export":[{"character":"↑","keyCode":126,"modifiers":"command"}]}}"#
        let preferences = try JSONDecoder().decode(CommandShortcutPreferences.self, from: Data(raw.utf8))
        XCTAssertTrue(preferences.bindings(for: .enclosingFolder).isEmpty)
        XCTAssertEqual(preferences.hint(for: .export), "⌘↑")
        XCTAssertEqual(CommandShortcutPreferences.decode(preferences.encoded), preferences)
        var changed = preferences
        XCTAssertFalse(changed.reset(for: .enclosingFolder))
        let legacy = #"{"schemaVersion":1,"customBindings":{"rescan":[{"character":"t","keyCode":17,"modifiers":"command"}]}}"#
        let loaded = try JSONDecoder().decode(CommandShortcutPreferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(loaded.hint(for: .rescan), "⌘T")
        XCTAssertEqual(loaded.hint(for: .enclosingFolder), "⌘↑")
    }

    func testMenuColumnsAndSettingsKeyboardExposeFolderActions() throws {
        let review = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        let commands = CommandShortcutPreferences()
        let entries = MenuShortcutColumns.entries(preferences: review, commandPreferences: commands, context: .galleryPhoto)
        for (title, hint) in [(L10n.text("Folders"), "T"), (L10n.text("Browser"), "Q"), (L10n.text("Previous Folder"), "["),
                              (L10n.text("Next Folder"), "]"), (L10n.text("Enclosing Folder"), "⌘↑")] {
            XCTAssertEqual(entries.first { $0.title == title }?.hint, hint)
        }
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:], layer: .command)
        XCTAssertEqual(map.commandActions(for: 126, preferences: commands), [.enclosingFolder])
        let menu = NSMenu(title: "View")
        let item = NSMenuItem(title: L10n.text("Enclosing Folder"), action: nil, keyEquivalent: "")
        menu.addItem(item)
        let presentation = MenuShortcutPresentation()
        presentation.apply(entries, to: menu, isTracking: true)
        XCTAssertEqual(item.keyEquivalent, "⌘↑")
        presentation.apply(entries, to: menu, isTracking: false)
        XCTAssertTrue(item.keyEquivalent.isEmpty, "Only the session monitor routes commands outside menu tracking")
    }

    private let newActions: [ReviewShortcutAction] = [.folders, .previousFolder, .nextFolder]
    private func omittingNewEntries(_ preferences: ReviewShortcutPreferences) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preferences.encoded.utf8)) as? [String: Any])
        for key in ["layoutBindings", "physicalBindings"] {
            var map = object[key] as! [String: Any]
            for action in newActions { map.removeValue(forKey: action.rawValue) }
            object[key] = map
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func event(_ char: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!
    }
}
