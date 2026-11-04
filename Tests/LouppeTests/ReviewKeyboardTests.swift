import XCTest
@testable import Louppe

@MainActor
final class ReviewKeyboardTests: XCTestCase {
    func testLayoutMapUsesCurrentCharactersInsteadOfRecordedLocations() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .keyboardLayout
        // Dvorak: F is produced at the QWERTY Y position, while QWERTY F produces U.
        let map = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [3: "u", 16: "f"])
        XCTAssertEqual(map.label(for: 3), "U")
        XCTAssertFalse(map.actions(for: 3, preferences: preferences).contains(.yes))
        XCTAssertEqual(map.actions(for: 16, preferences: preferences), [.yes])
    }

    func testPhysicalMapKeepsDocumentedPositionNamesAcrossInputLayouts() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .physicalPosition
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [3: "u", 16: "f"])
        XCTAssertEqual(map.label(for: 3), "F")
        XCTAssertEqual(map.actions(for: 3, preferences: preferences), [.yes])
        XCTAssertFalse(map.actions(for: 16, preferences: preferences).contains(.yes))
    }

    func testContextReusedKeysExposeEveryAssignedAction() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .keyboardLayout
        let map = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [:])
        XCTAssertEqual(Set(map.actions(for: 123, preferences: preferences)), [.previous, .seekBackward])
        XCTAssertEqual(Set(map.actions(for: 49, preferences: preferences)), [.next, .playPause])
        XCTAssertEqual(map.actions(for: 48, preferences: preferences), [.grid])
    }

    func testRemappingImmediatelyChangesMapWithoutChangingItsInput() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .keyboardLayout
        let map = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [3: "f", 16: "y"])
        XCTAssertTrue(preferences.set(.init(character: "y", keyCode: 16), for: .yes))
        XCTAssertTrue(map.actions(for: 3, preferences: preferences).isEmpty)
        XCTAssertEqual(map.actions(for: 16, preferences: preferences), [.yes])
        XCTAssertEqual(preferences.binding(for: .yes).character, "y")
    }

    func testOverviewIncludesEveryCommandLayerAndTracksAliasReplacementRemovalAndReset() {
        var commands = CommandShortcutPreferences()
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:],
            modifiedCharactersByLayer: [.command: [40: "k", 17: "t", 24: "="],
                                        .commandShift: [16: "y", 24: "+"]])
        XCTAssertEqual(map.commandActions(for: 40, preferences: commands), [.commandPalette])
        XCTAssertEqual(map.commandBindings(for: 24, preferences: commands).map(\.binding.display), ["⌘+", "⇧⌘+"])
        XCTAssertTrue(map.commandActions(for: 51, preferences: commands).contains(.trash))
        XCTAssertEqual(Set(map.commandActions(for: 123, preferences: commands)), [.slower, .seekBackward, .selectFirst])

        let original = commands.bindings(for: .commandPalette)[0]
        let replacement = CommandShortcutBinding(character: "t", keyCode: 17, modifiers: .command)
        XCTAssertTrue(commands.replace(original, with: replacement, for: .commandPalette))
        XCTAssertTrue(map.commandActions(for: 40, preferences: commands).isEmpty)
        XCTAssertEqual(map.commandActions(for: 17, preferences: commands), [.commandPalette])
        let alias = CommandShortcutBinding(character: "y", keyCode: 16, modifiers: .commandShift)
        XCTAssertTrue(commands.add(alias, for: .commandPalette))
        XCTAssertEqual(map.commandActions(for: 16, preferences: commands), [.commandPalette])
        XCTAssertTrue(commands.remove(replacement, for: .commandPalette))
        XCTAssertTrue(map.commandActions(for: 17, preferences: commands).isEmpty)
        XCTAssertTrue(commands.reset(for: .commandPalette))
        XCTAssertTrue(map.commandActions(for: 16, preferences: commands).isEmpty)
        XCTAssertEqual(map.commandActions(for: 40, preferences: commands), [.commandPalette])
    }

    func testOverviewUsesEachCommandsInputLayoutEvenWhenReviewUsesPhysicalPositions() {
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [2: "e", 14: "."],
            modifiedCharactersByLayer: [.command: [14: "e", 2: "d"], .commandShift: [24: "+"]])
        XCTAssertEqual(map.commandActions(for: 14, preferences: CommandShortcutPreferences()), [.export])
        XCTAssertTrue(map.commandActions(for: 2, preferences: CommandShortcutPreferences()).isEmpty)
        XCTAssertEqual(map.commandActions(for: 24, preferences: CommandShortcutPreferences()), [.zoomIn])
    }

    func testReviewOverviewTracksRemovalAndResetWhileOtherShortcutsKeepSharedKeysUsed() {
        var review = ReviewShortcutPreferences()
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:],
                                   modifiedCharactersByLayer: [.command: [3: "f"]])
        XCTAssertTrue(review.set(.init(character: "y", keyCode: 16), for: .oneStar))
        XCTAssertTrue(map.actions(for: 18, preferences: review).isEmpty)
        XCTAssertEqual(map.actions(for: 16, preferences: review), [.oneStar])
        XCTAssertTrue(review.remove(review.assignments(for: .oneStar)[0].id, for: .oneStar))
        XCTAssertTrue(map.actions(for: 16, preferences: review).isEmpty)
        XCTAssertTrue(review.reset(for: .oneStar))
        XCTAssertEqual(map.actions(for: 18, preferences: review), [.oneStar])

        XCTAssertTrue(review.set(.init(character: "y", keyCode: 16), for: .yes))
        XCTAssertTrue(map.actions(for: 3, preferences: review).isEmpty)
        XCTAssertEqual(map.commandActions(for: 3, preferences: CommandShortcutPreferences()), [.filterSearch],
                       "F stays lit because Command-F is still assigned")
    }

    func testUnavailableLayoutCharacterDoesNotPretendToBeQwerty() {
        let map = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [:])
        XCTAssertNil(map.character(for: 3))
        XCTAssertEqual(map.label(for: 3), "–")
        XCTAssertTrue(map.actions(for: 3, preferences: ReviewShortcutPreferences()).isEmpty)
        XCTAssertEqual(map.label(for: 123), "←")
    }

    func testVisualRowsHaveUniqueSupportedPositions() {
        let codes = ReviewKeyboardMap.rows.flatMap { $0 }
        XCTAssertEqual(codes.count, Set(codes).count)
        XCTAssertTrue(codes.allSatisfy { ReviewShortcutBinding.positionLabels[$0] != nil || $0 == 48 })
        XCTAssertEqual(Set(codes.filter { $0 != 48 }), Set(ReviewShortcutBinding.positionLabels.keys))
    }

    func testCommandMapFollowsActualCommandCharactersIndependentlyOfPhysicalReviewMode() {
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [14: ".", 2: "e"],
                                    layer: .command, modifiedCharacters: [14: "e", 2: "d"])
        XCTAssertEqual(map.label(for: 14), "E", "Dvorak Command-QWERTY uses the Command layer's translation")
        XCTAssertEqual(map.commandActions(for: 14, preferences: CommandShortcutPreferences()), [.export])
        XCTAssertTrue(map.commandActions(for: 2, preferences: CommandShortcutPreferences()).isEmpty)
        XCTAssertTrue(map.actions(for: 14, preferences: ReviewShortcutPreferences()).isEmpty)
    }

    func testModifiedMapImmediatelyReflectsCustomAliasesAndDoesNotRelyOnRecordedLocation() {
        var preferences = CommandShortcutPreferences()
        let original = preferences.bindings(for: .export)[0]
        XCTAssertTrue(preferences.replace(original, with: .init(character: "t", keyCode: 17, modifiers: .command), for: .export))
        XCTAssertTrue(preferences.add(.init(character: "y", keyCode: 16, modifiers: .commandShift), for: .export))
        let command = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [:],
                                       layer: .command, modifiedCharacters: [14: "e", 40: "t"])
        XCTAssertTrue(command.commandActions(for: 14, preferences: preferences).isEmpty)
        XCTAssertEqual(command.commandActions(for: 40, preferences: preferences), [.export])
        let combined = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:],
                                        layer: .commandShift, modifiedCharacters: [45: "y"])
        XCTAssertEqual(combined.commandActions(for: 45, preferences: preferences), [.export])
    }

    func testModifierLayersShowDirectionalAndDeleteCommandsOnlyOnCorrectLayers() {
        let prefs = CommandShortcutPreferences()
        let command = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:], layer: .command)
        let shift = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:], layer: .shift)
        let combined = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [:], layer: .commandShift)
        XCTAssertEqual(command.commandActions(for: 123, preferences: prefs), [.slower])
        XCTAssertEqual(command.commandActions(for: 51, preferences: prefs), [.trash])
        XCTAssertEqual(shift.commandActions(for: 123, preferences: prefs), [.seekBackward])
        XCTAssertEqual(combined.commandActions(for: 123, preferences: prefs), [.selectFirst])
    }

    func testShiftLayerKeepsPhysicalReviewLettersUnderDvorakAndExcludesNonLetters() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .physicalPosition
        let map = ReviewKeyboardMap(interpretation: .physicalPosition, layoutCharacters: [3: "u", 16: "f"],
                                    layer: .shift, modifiedCharacters: [3: "u", 16: "f", 18: "!"])
        XCTAssertEqual(map.label(for: 3), "U", "Shift labels reflect the active keyboard's shifted characters")
        XCTAssertEqual(map.actions(for: 3, preferences: preferences), [.yes], "Physical F position still marks Yes")
        XCTAssertFalse(map.actions(for: 16, preferences: preferences).contains(.yes))
        for key in [UInt16(18), 48, 49, 123, 124, 125, 126] {
            XCTAssertTrue(map.actions(for: key, preferences: preferences).isEmpty, "Shift excludes non-letter position \(key)")
        }
        XCTAssertTrue(preferences.set(.init(character: "f", keyCode: 41), for: .yes))
        XCTAssertTrue(map.actions(for: 41, preferences: preferences).isEmpty,
                      "Physical mode checks the position's punctuation meaning, not the stored character")
    }

    func testShiftLayerUsesShiftedLayoutLettersAndLeavesCommandShiftToCommands() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .keyboardLayout
        let shifted = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [3: "u", 16: "f"],
                                        layer: .shift, modifiedCharacters: [3: "u", 16: "F", 18: "!"])
        XCTAssertEqual(shifted.label(for: 16), "F")
        XCTAssertEqual(shifted.actions(for: 16, preferences: preferences), [.yes])
        XCTAssertFalse(shifted.actions(for: 3, preferences: preferences).contains(.yes))
        for key in [UInt16(18), 48, 49, 123, 124, 125, 126] {
            XCTAssertTrue(shifted.actions(for: key, preferences: preferences).isEmpty)
        }
        XCTAssertTrue(preferences.set(.init(character: ".", keyCode: 14), for: .yes))
        let punctuation = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [14: "."],
                                            layer: .shift, modifiedCharacters: [14: "."])
        XCTAssertTrue(punctuation.actions(for: 14, preferences: preferences).isEmpty)
        let combined = ReviewKeyboardMap(interpretation: .keyboardLayout, layoutCharacters: [:],
                                        layer: .commandShift, modifiedCharacters: [16: "f"])
        XCTAssertTrue(combined.actions(for: 16, preferences: preferences).isEmpty)
    }

    func testHoldingModifiersCombinesWithAndRestoresClickedLayer() {
        var state = ReviewKeyboardLayerState()
        state.toggleCommand()
        XCTAssertEqual(state.displayed, .command)
        state.held = .shift
        XCTAssertEqual(state.displayed, .commandShift)
        state.held = .base
        XCTAssertEqual(state.displayed, .command)
        state.toggleShift()
        XCTAssertEqual(state.displayed, .commandShift)
        state.held = .command
        XCTAssertEqual(state.displayed, .commandShift)
        state.held = .base
        XCTAssertEqual(state.displayed, .commandShift)
        state.toggleCommand()
        XCTAssertEqual(state.displayed, .shift)
        state.held = .command
        XCTAssertEqual(state.displayed, .commandShift)
        state.held = .base
        XCTAssertEqual(state.displayed, .shift)
    }
}
