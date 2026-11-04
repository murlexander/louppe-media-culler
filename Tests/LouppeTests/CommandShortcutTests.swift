import AppKit
import XCTest
@testable import Louppe

@MainActor
final class CommandShortcutTests: XCTestCase {
    func testDefaultInventoryAndContextualArrows() {
        let preferences = CommandShortcutPreferences()
        XCTAssertEqual(preferences.hint(for: .export), "⌘E")
        XCTAssertEqual(preferences.hint(for: .commandPalette), "⌘K")
        XCTAssertEqual(preferences.hint(for: .rescan), "⌘R")
        XCTAssertEqual(preferences.hint(for: .zoomIn), "⌘+")
        XCTAssertEqual(preferences.match(for: event("e", code: 14), context: .galleryPhoto), .export)
        XCTAssertEqual(preferences.match(for: event("", code: 123, flags: [.command, .function, .numericPad]), context: .galleryPhoto), .slower)
        XCTAssertEqual(preferences.match(for: event("", code: 123, flags: [.shift, .function, .numericPad]), context: .galleryPlayableVideo), .seekBackward)
        XCTAssertNil(preferences.match(for: event("", code: 123, flags: [.shift, .function, .numericPad]), context: .gridPlayableVideo))
        XCTAssertNil(preferences.match(for: event("=", code: 24), context: .galleryPhoto))
        XCTAssertEqual(preferences.match(for: event("=", code: 24), context: .gridPhoto), .zoomIn)
        XCTAssertEqual(preferences.match(for: event("+", code: 24, flags: [.command, .shift]), context: .gridPhoto), .zoomIn)
    }

    func testAliasesReplaceRemoveAndResetWithoutRevivingRemovedDefaults() throws {
        var preferences = CommandShortcutPreferences()
        let original = try XCTUnwrap(preferences.bindings(for: .export).first)
        let alias = CommandShortcutBinding(character: "t", keyCode: 17, modifiers: .commandShift)
        XCTAssertTrue(preferences.add(alias, for: .export))
        XCTAssertEqual(preferences.hint(for: .export), "⌘E / ⇧⌘T")
        XCTAssertTrue(preferences.remove(original, for: .export))
        XCTAssertNil(preferences.match(for: event("e", code: 14), context: .galleryPhoto))
        XCTAssertEqual(preferences.match(for: event("T", code: 17, flags: [.command, .shift]), context: .galleryPhoto), .export)
        let replacement = CommandShortcutBinding(character: "j", keyCode: 38, modifiers: .command)
        XCTAssertTrue(preferences.replace(alias, with: replacement, for: .export))
        XCTAssertNil(preferences.match(for: event("t", code: 17, flags: [.command, .shift]), context: .galleryPhoto))
        XCTAssertEqual(CommandShortcutPreferences.decode(preferences.encoded), preferences)
        XCTAssertTrue(preferences.remove(replacement, for: .export))
        XCTAssertTrue(preferences.bindings(for: .export).isEmpty)
        XCTAssertTrue(CommandShortcutPreferences.decode(preferences.encoded).bindings(for: .export).isEmpty)
        XCTAssertTrue(preferences.reset(for: .export))
        XCTAssertEqual(preferences, CommandShortcutPreferences())
    }

    func testConflictsAreCharacterBasedAndResetCannotStealAnAlias() throws {
        var preferences = CommandShortcutPreferences()
        let export = try XCTUnwrap(preferences.bindings(for: .export).first)
        XCTAssertTrue(preferences.remove(export, for: .export))
        let eOnDvorak = CommandShortcutBinding(character: "e", keyCode: 2, modifiers: .command)
        XCTAssertTrue(preferences.add(eOnDvorak, for: .rescan))
        XCTAssertFalse(preferences.reset(for: .export))
        XCTAssertFalse(preferences.add(export, for: .commandPalette))
        XCTAssertEqual(preferences.match(for: event("e", code: 2), context: .galleryPhoto), .rescan)
        XCTAssertEqual(preferences.match(for: event("e", code: 14), context: .galleryPhoto), .rescan)
        XCTAssertNil(preferences.match(for: event("j", code: 14), context: .galleryPhoto))
        preferences.resetAll()
        XCTAssertEqual(preferences, CommandShortcutPreferences())
    }

    func testFixedSystemAndTextChordsCannotBeReassigned() {
        var preferences = CommandShortcutPreferences()
        for character in ["a", "b", "c", "f", "g", "h", "i", "m", "n", "o", "p", "q", "s", "u", "v", "w", "x", "z"] {
            for modifiers in [CommandShortcutModifiers.command, .commandShift] {
                let binding = CommandShortcutBinding(character: character, keyCode: 17, modifiers: modifiers)
                XCTAssertNotNil(preferences.conflict(for: binding, action: .export), character)
                XCTAssertFalse(preferences.add(binding, for: .export), character)
            }
        }
        for action in CommandShortcutAction.allCases where !action.isEditable {
            let fixed = preferences.bindings(for: action)[0]
            XCTAssertFalse(preferences.remove(fixed, for: action))
            XCTAssertFalse(preferences.replace(fixed, with: .init(character: "t", keyCode: 17, modifiers: .command), for: action))
            XCTAssertFalse(preferences.reset(for: action))
        }
    }

    func testUnsupportedModifiersAndUnsafeRecordingAreRejected() {
        for flags: NSEvent.ModifierFlags in [[.command, .option], [.command, .control], [.command, .function], [.command, .help], [.command, .numericPad], [.control, .option], []] {
            XCTAssertNil(CommandShortcutBinding.capture(event("t", code: 17, flags: flags)))
        }
        XCTAssertEqual(CommandShortcutBinding.capture(event("T", code: 17, flags: [.command, .capsLock]))?.character, "t")
        XCTAssertNil(CommandShortcutBinding.capture(event("", code: 122)))
        XCTAssertFalse(CommandShortcutBinding(character: "T", keyCode: 17, modifiers: .command).isValid)
        var preferences = CommandShortcutPreferences()
        XCTAssertFalse(preferences.add(.init(character: "t", keyCode: 17, modifiers: .shift), for: .export))
        XCTAssertFalse(preferences.add(.init(character: "=", keyCode: 24, modifiers: .command), for: .export))
        XCTAssertFalse(preferences.add(.init(character: "⌫", keyCode: 51, modifiers: .command), for: .export))
    }

    func testMalformedSavedMapsCannotActivateReservedOrAmbiguousCommands() throws {
        let defaults = CommandShortcutPreferences()
        let invalid = [
            "", "broken", String(repeating: "x", count: 100_001),
            #"{"schemaVersion":2,"customBindings":{}}"#,
            #"{"schemaVersion":1,"customBindings":{"quit":[]}}"#,
            #"{"schemaVersion":1,"customBindings":{"export":[{"character":"q","keyCode":12,"modifiers":"command"}]}}"#,
            #"{"schemaVersion":1,"customBindings":{"export":[{"character":"t","keyCode":17,"modifiers":"command"},{"character":"t","keyCode":3,"modifiers":"command"}]}}"#,
            #"{"schemaVersion":1,"customBindings":{"export":[{"character":"t","keyCode":17,"modifiers":"command"}],"rescan":[{"character":"t","keyCode":3,"modifiers":"command"}]}}"#,
        ]
        for raw in invalid { XCTAssertEqual(CommandShortcutPreferences.decode(raw), defaults) }
        XCTAssertThrowsError(try JSONDecoder().decode(CommandShortcutPreferences.self, from: Data(invalid[4].utf8)))
    }

    func testIndependentPreferenceDomainLeavesReviewMapsUntouched() {
        let name = "CommandShortcutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let review = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        review.save(to: defaults)
        var commands = CommandShortcutPreferences()
        XCTAssertTrue(commands.add(.init(character: "t", keyCode: 17, modifiers: .commandShift), for: .export))
        commands.save(to: defaults)
        XCTAssertEqual(CommandShortcutPreferences.load(from: defaults), commands)
        XCTAssertEqual(ReviewShortcutPreferences.load(from: defaults), review)
    }

    private func event(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, characters: character,
                        charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
}
