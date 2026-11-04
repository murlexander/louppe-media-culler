import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ReviewShortcutTests: XCTestCase {
    func testDefaultsUsePhysicalPositionAndLayoutModeRemainsAvailable() {
        var preferences = ReviewShortcutPreferences()
        let dvorakFPosition = event(code: 3, character: "u")
        XCTAssertEqual(preferences.interpretation, .physicalPosition)
        XCTAssertEqual(preferences.action(for: dvorakFPosition), .yes)
        XCTAssertNil(preferences.action(for: event(code: 32, character: "f")))
        XCTAssertEqual(preferences.hint(for: .yes), "F position")
        preferences.interpretation = .keyboardLayout
        XCTAssertNil(preferences.action(for: dvorakFPosition))
        XCTAssertEqual(preferences.action(for: event(code: 32, character: "f")), .yes)
        XCTAssertEqual(preferences.hint(for: .yes), "F")
    }

    func testAbsentEmptyAndMalformedPreferencesStartWithPhysicalPositions() {
        let domain = "ReviewShortcutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(ReviewShortcutPreferences.load(from: defaults).interpretation, .physicalPosition)
        defaults.set("", forKey: ReviewShortcutPreferences.preferenceKey)
        XCTAssertEqual(ReviewShortcutPreferences.load(from: defaults).interpretation, .physicalPosition)
        defaults.set("broken", forKey: ReviewShortcutPreferences.preferenceKey)
        XCTAssertEqual(ReviewShortcutPreferences.load(from: defaults), ReviewShortcutPreferences())
    }

    func testSavedLayoutChoiceAndBothAliasMapsSurviveNewPhysicalDefault() {
        let domain = "ReviewShortcutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertTrue(preferences.add(.init(character: "b", keyCode: 11), for: .yes, scope: .gallery))
        let layoutAliases = preferences.assignments(for: .yes)
        preferences.interpretation = .physicalPosition
        XCTAssertTrue(preferences.add(.init(character: "v", keyCode: 9), for: .no, scope: .grid))
        let physicalAliases = preferences.assignments(for: .no)
        preferences.interpretation = .keyboardLayout
        preferences.save(to: defaults)

        var loaded = ReviewShortcutPreferences.load(from: defaults)
        XCTAssertEqual(loaded, preferences)
        XCTAssertEqual(loaded.interpretation, .keyboardLayout)
        XCTAssertEqual(loaded.assignments(for: .yes), layoutAliases)
        loaded.interpretation = .physicalPosition
        XCTAssertEqual(loaded.assignments(for: .no), physicalAliases)
    }

    func testLayoutCustomBindingDoesNotChangePhysicalMapping() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertTrue(preferences.set(.init(character: "b", keyCode: 11), for: .yes))
        XCTAssertNil(preferences.action(for: event(code: 3, character: "f")))
        XCTAssertEqual(preferences.action(for: event(code: 11, character: "b")), .yes)
        preferences.interpretation = .physicalPosition
        XCTAssertEqual(preferences.action(for: event(code: 3, character: "u")), .yes)
        XCTAssertNil(preferences.action(for: event(code: 11, character: "y")))
        XCTAssertEqual(preferences.binding(for: .yes), .init(character: "b", keyCode: 3))
    }

    func testDvorakPhysicalEditsIgnoreTheInactiveLayoutCharacter() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .physicalPosition
        let dvorakHPosition = ReviewShortcutBinding(character: "d", keyCode: 4)
        XCTAssertNil(preferences.conflictingAction(for: dvorakHPosition, excluding: .yes))
        XCTAssertTrue(preferences.set(dvorakHPosition, for: .yes))
        XCTAssertEqual(preferences.action(for: event(code: 4, character: "d")), .yes)
        XCTAssertEqual(preferences.binding(for: .yes), .init(character: "f", keyCode: 4))
        // Re-recording the existing No position is valid even though Dvorak
        // emits E, which is Export's independent keyboard-layout binding.
        XCTAssertTrue(preferences.set(.init(character: "e", keyCode: 2), for: .no))
        XCTAssertEqual(preferences.action(for: event(code: 2, character: "e")), .no)
        XCTAssertEqual(ReviewShortcutPreferences.decode(preferences.encoded), preferences)
        preferences.interpretation = .keyboardLayout
        XCTAssertEqual(preferences.action(for: event(code: 4, character: "d")), .no)
        XCTAssertEqual(preferences.action(for: event(code: 16, character: "f")), .yes)
    }

    func testTrueConflictsAreRejectedInTheModeBeingEdited() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertEqual(preferences.conflictingAction(for: .init(character: "d", keyCode: 11), excluding: .yes), .no)
        XCTAssertFalse(preferences.set(.init(character: "d", keyCode: 11), for: .yes))
        XCTAssertEqual(preferences, ReviewShortcutPreferences(interpretation: .keyboardLayout))
        // The physical code is irrelevant when assigning a layout character.
        XCTAssertNil(preferences.conflictingAction(for: .init(character: "b", keyCode: 2), excluding: .yes))
        XCTAssertTrue(preferences.set(.init(character: "b", keyCode: 2), for: .yes))
        XCTAssertEqual(preferences.binding(for: .yes).keyCode, 3)
        preferences.interpretation = .physicalPosition
        XCTAssertEqual(preferences.conflictingAction(for: .init(character: "b", keyCode: 2), excluding: .yes), .no)
        XCTAssertFalse(preferences.set(.init(character: "b", keyCode: 2), for: .yes))
        XCTAssertEqual(preferences.binding(for: .yes), .init(character: "b", keyCode: 3))
    }

    func testPreferencesRoundTripAndInvalidSavedDataFallsBackSafely() {
        let domain = "ReviewShortcutTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var preferences = ReviewShortcutPreferences()
        XCTAssertTrue(preferences.set(.init(character: "b", keyCode: 11), for: .yes))
        preferences.interpretation = .physicalPosition
        preferences.save(to: defaults)
        XCTAssertEqual(ReviewShortcutPreferences.load(from: defaults), preferences)
        XCTAssertEqual(ReviewShortcutPreferences.decode("broken"), ReviewShortcutPreferences())
        let invalid = #"{"interpretation":"physicalPosition","customBindings":{"yes":{"character":"d","keyCode":17}}}"#
        XCTAssertEqual(ReviewShortcutPreferences.decode(invalid), ReviewShortcutPreferences())
        let reserved = #"{"interpretation":"physicalPosition","customBindings":{"yes":{"character":"b","keyCode":49}}}"#
        XCTAssertEqual(ReviewShortcutPreferences.decode(reserved), ReviewShortcutPreferences())
    }

    func testDecodedValueCacheTracksEditsInvalidValuesAndIndependentCopies() {
        var original = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertTrue(original.add(.init(character: "b", keyCode: 11), for: .yes))
        let first = original.encoded
        var updated = original
        updated.interpretation = .physicalPosition
        XCTAssertTrue(updated.add(.init(character: "v", keyCode: 9), for: .yes))
        let second = updated.encoded
        for raw in [first, first, second, second, "invalid", "invalid", first, "", second] {
            let expected = raw == first ? original : (raw == second ? updated : ReviewShortcutPreferences())
            XCTAssertEqual(ReviewShortcutPreferences.decode(raw), expected)
        }
        var copy = ReviewShortcutPreferences.decode(first)
        copy.resetCurrentMode()
        XCTAssertEqual(ReviewShortcutPreferences.decode(first), original, "A caller cannot mutate the cached value")
    }

    func testConcurrentDecodingKeepsRawValueAndValidatedValueTogether() {
        var preferences = ReviewShortcutPreferences()
        XCTAssertTrue(preferences.add(.init(character: "b", keyCode: 11), for: .yes))
        let custom = preferences
        let raw = preferences.encoded
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let useCustom = index.isMultiple(of: 2)
            XCTAssertEqual(ReviewShortcutPreferences.decode(useCustom ? raw : "invalid"), useCustom ? custom : ReviewShortcutPreferences())
        }
    }

    func testLettersAllowShiftButStarsAndPunctuationDoNot() {
        let preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertEqual(preferences.action(for: event(code: 3, character: "F", modifiers: .shift)), .yes)
        XCTAssertNil(preferences.action(for: event(code: 18, character: "1", modifiers: .shift)))
        XCTAssertEqual(preferences.action(for: event(code: 18, character: "1")), .oneStar)
        var physical = preferences
        physical.interpretation = .physicalPosition
        XCTAssertNil(physical.action(for: event(code: 18, character: "!", modifiers: .shift)))
        XCTAssertEqual(physical.action(for: event(code: 3, character: "U", modifiers: .shift)), .yes)
    }

    func testRecorderAcceptsNavigationButRejectsReservedKeysAndModifiers() {
        XCTAssertEqual(ReviewShortcutBinding.capture(event(code: 11, character: "b")), .init(character: "b", keyCode: 11))
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift, .function, .help, .numericPad] {
            XCTAssertNil(ReviewShortcutBinding.capture(event(code: 11, character: "b", modifiers: modifier)))
        }
        for code: UInt16 in [36, 51, 53, 76, 117] {
            XCTAssertNil(ReviewShortcutBinding.capture(event(code: code, character: "b")))
        }
    }

    func testMultipleAliasesHaveStableIdentityAndCanBeRemovedIndividually() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        let first = preferences.assignments(for: .yes)[0]
        XCTAssertEqual(first.id, preferences.assignments(for: .yes)[0].id)
        XCTAssertTrue(preferences.add(.init(character: "b", keyCode: 11), for: .yes))
        let added = preferences.assignments(for: .yes)[1]
        XCTAssertEqual(preferences.hint(for: .yes), "F / B")
        XCTAssertEqual(preferences.match(for: event(code: 11, character: "b"), context: .gridPhoto)?.action, .yes)
        XCTAssertTrue(preferences.remove(first.id, for: .yes))
        XCTAssertNil(preferences.match(for: event(code: 3, character: "f"), context: .galleryPhoto))
        XCTAssertEqual(preferences.assignments(for: .yes)[0].id, added.id)
        XCTAssertTrue(preferences.replace(added.id, with: .init(character: "v", keyCode: 9), for: .yes, scope: .all))
        XCTAssertEqual(preferences.hint(for: .yes), "V")
        XCTAssertTrue(preferences.reset(for: .yes))
        XCTAssertEqual(preferences.hint(for: .yes), "F")
        XCTAssertEqual(preferences.assignments(for: .yes)[0].id, first.id)
    }

    func testGlobalConflictsRejectButDisjointViewsAndMediaMayReuseAKey() {
        var preferences = ReviewShortcutPreferences()
        let t = ReviewShortcutBinding(character: "b", keyCode: 11)
        XCTAssertTrue(preferences.add(t, for: .yes, scope: .photos))
        XCTAssertEqual(preferences.conflict(for: t, action: .no, scope: .all)?.action, .yes)
        XCTAssertFalse(preferences.add(t, for: .no))
        XCTAssertTrue(preferences.add(t, for: .no, scope: .videos))
        XCTAssertEqual(preferences.match(for: event(code: 11, character: "b"), context: .galleryPhoto)?.action, .yes)
        XCTAssertEqual(preferences.match(for: event(code: 11, character: "b"), context: .galleryPlayableVideo)?.action, .no)
        XCTAssertTrue(preferences.add(.init(character: "v", keyCode: 9), for: .previous, scope: .gallery))
        XCTAssertTrue(preferences.add(.init(character: "v", keyCode: 9), for: .next, scope: .grid))
        XCTAssertFalse(preferences.add(.init(character: "v", keyCode: 9), for: .previous, scope: .gallery), "Duplicate aliases in one context are rejected even for the same action")
        XCTAssertFalse(preferences.add(.init(character: "b", keyCode: 11), for: .previousRow, scope: .gallery), "An impossible action scope must not be saved")
        XCTAssertEqual(ReviewShortcutPreferences.decode(preferences.encoded), preferences)
    }

    func testAllDefaultNavigationAliasesMatchEveryRuntimeContext() {
        let preferences = ReviewShortcutPreferences()
        for context in ReviewShortcutContext.allCases {
            let left: ReviewShortcutAction = context.canSeekVideo ? .seekBackward : .previous
            let right: ReviewShortcutAction = context.canSeekVideo ? .seekForward : .next
            let expected: [(UInt16, ReviewShortcutAction)] = [
                (123, left), (124, right),
                (126, context.isGallery ? .previous : .previousRow),
                (125, context.isGallery ? .next : .nextRow),
                (49, context.isPlayable ? .playPause : .next), (48, .grid),
            ]
            for (code, action) in expected {
                let match = preferences.match(for: event(code: code, character: "", modifiers: code >= 123 ? [.numericPad, .function] : []), context: context)
                XCTAssertEqual(match?.action, action, "\(context), code \(code)")
                XCTAssertEqual(match?.requiresNavigationFocus, true)
                XCTAssertNil(preferences.match(for: event(code: code, character: "", modifiers: .shift), context: context))
            }
            XCTAssertEqual(preferences.match(for: event(code: 40, character: "k"), context: context)?.action, context.isPlayable ? .playPause : nil)
            XCTAssertEqual(preferences.match(for: event(code: 38, character: "j"), context: context)?.requiresNavigationFocus, false)
        }
        XCTAssertEqual(ReviewShortcutContext(viewMode: .grid, mediaKind: .video, isPlayable: true, canSeekVideo: false), .gridPlayableVideo)
        XCTAssertEqual(ReviewShortcutContext(viewMode: .gallery, mediaKind: .video, isPlayable: false, canSeekVideo: false), .galleryOtherVideo)
    }

    func testNavigationKeysAreCapturedCanonicallyAndCannotBeClaimedGlobally() {
        var preferences = ReviewShortcutPreferences()
        for (code, label) in ReviewShortcutBinding.specialLabels {
            let captured = ReviewShortcutBinding.capture(event(code: code, character: "", modifiers: code >= 123 ? [.numericPad, .function] : []))
            XCTAssertEqual(captured, .init(character: label, keyCode: code))
            XCTAssertFalse(preferences.add(captured!, for: .yes))
        }
        preferences.interpretation = .physicalPosition
        XCTAssertFalse(preferences.add(.init(character: "←", keyCode: 123), for: .yes))
    }

    func testResetDoesNotSilentlyStealAnotherActionsKey() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        let first = preferences.assignments(for: .yes)[0]
        XCTAssertTrue(preferences.remove(first.id, for: .yes))
        XCTAssertTrue(preferences.add(.init(character: "f", keyCode: 3), for: .no))
        XCTAssertEqual(preferences.resetConflict(for: .yes)?.action, .no)
        XCTAssertFalse(preferences.reset(for: .yes))
        XCTAssertEqual(preferences.hint(for: .yes), "")
        preferences.resetCurrentMode()
        XCTAssertEqual(preferences.hint(for: .yes), "F")
        XCTAssertEqual(preferences.hint(for: .no), "D")
    }

    func testMatchingModesHaveIndependentAliasesAndConflicts() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertTrue(preferences.add(.init(character: "b", keyCode: 3), for: .yes))
        preferences.interpretation = .physicalPosition
        XCTAssertEqual(preferences.assignments(for: .yes).count, 1)
        XCTAssertTrue(preferences.add(.init(character: "d", keyCode: 4), for: .yes))
        XCTAssertEqual(preferences.match(for: event(code: 4, character: "d"), context: .galleryPhoto)?.action, .yes)
        XCTAssertFalse(preferences.add(.init(character: "b", keyCode: 2), for: .yes), "Physical No position remains reserved")
        preferences.resetCurrentMode()
        XCTAssertEqual(preferences.assignments(for: .yes).count, 1)
        preferences.interpretation = .keyboardLayout
        XCTAssertEqual(preferences.assignments(for: .yes).count, 2)
        XCTAssertEqual(preferences.match(for: event(code: 11, character: "b"), context: .galleryPhoto)?.action, .yes)
        XCTAssertEqual(ReviewShortcutPreferences.decode(preferences.encoded), preferences)
    }

    func testLegacyMigrationKeepsCustomKeyAndInheritedNavigation() {
        let legacy = #"{"interpretation":"keyboardLayout","customBindings":{"next":{"character":"t","keyCode":17},"grid":{"character":"v","keyCode":9}}}"#
        var preferences = ReviewShortcutPreferences.decode(legacy)
        XCTAssertEqual(preferences.interpretation, .keyboardLayout)
        XCTAssertEqual(preferences.hint(for: .next), "T / → / ↓ / Space")
        XCTAssertEqual(preferences.hint(for: .grid), "Tab / V")
        XCTAssertEqual(preferences.match(for: event(code: 49, character: " "), context: .galleryPlayableAudio)?.action, .playPause)
        preferences.interpretation = .physicalPosition
        XCTAssertEqual(preferences.match(for: event(code: 17, character: "y"), context: .gridPhoto)?.action, .next)
        XCTAssertEqual(ReviewShortcutPreferences.decode(preferences.encoded), preferences)
    }

    func testAmbiguousOrInvalidNewSavedMapsFallBackSafely() throws {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertTrue(preferences.add(.init(character: "b", keyCode: 11), for: .yes))
        let data = try XCTUnwrap(preferences.encoded.data(using: .utf8))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var map = try XCTUnwrap(root["layoutBindings"] as? [String: Any])
        let yes = try XCTUnwrap(map["yes"] as? [[String: Any]])
        var duplicate = yes[1]
        duplicate["id"] = UUID().uuidString
        map["no"] = [duplicate]
        root["layoutBindings"] = map
        let ambiguous = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        XCTAssertEqual(ReviewShortcutPreferences.decode(ambiguous), ReviewShortcutPreferences())
        root["schemaVersion"] = 999
        XCTAssertEqual(ReviewShortcutPreferences.decode(String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)), ReviewShortcutPreferences())
    }

    func testFocusedRecorderCapturesConflictsAndCancelsSafely() {
        var captures: [ReviewShortcutBinding] = []
        var invalidCount = 0
        let recorder = ReviewShortcutRecorderButton()
        recorder.shortcutTitle = "F"
        recorder.actionTitle = "Mark Yes"
        recorder.onCapture = { captures.append($0); return $0.character == "b" }
        recorder.onInvalid = { invalidCount += 1 }
        recorder.startRecording()
        recorder.keyDown(with: event(code: 2, character: "d"))
        XCTAssertTrue(recorder.isRecording, "A conflict keeps recording active for another key")
        recorder.keyDown(with: event(code: 11, character: "T", modifiers: .shift))
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(invalidCount, 1)
        XCTAssertEqual(captures.count, 1, "An unsupported modified key must never become a binding")
        recorder.keyDown(with: event(code: 11, character: "b"))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(captures.last, .init(character: "b", keyCode: 11))
        recorder.startRecording()
        recorder.keyDown(with: event(code: 53, character: "\u{1b}"))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(captures.count, 2)
    }

    func testFocusedRecorderAcceptsArrowFlagsTabAndSpaceAndNotifiesEscape() {
        let recorder = ReviewShortcutRecorderButton()
        var captures: [ReviewShortcutBinding] = []
        var cancellations = 0
        recorder.onCapture = { captures.append($0); return true }
        recorder.onCancel = { cancellations += 1 }
        for code: UInt16 in [123, 124, 125, 126, 48, 49] {
            recorder.startRecording()
            recorder.keyDown(with: event(code: code, character: "", modifiers: code >= 123 ? [.numericPad, .function] : []))
            XCTAssertFalse(recorder.isRecording)
            XCTAssertEqual(captures.last?.keyCode, code)
        }
        recorder.startRecording()
        recorder.keyDown(with: event(code: 53, character: "\u{1b}"))
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(captures.count, 6)
        XCTAssertFalse(recorder.isRecording)
    }

    func testRecorderAutomaticallyStartsOnlyOnceWhenMounted() {
        let recorder = ReviewShortcutRecorderButton()
        recorder.automaticallyRecord = true
        recorder.startAutomaticallyIfNeeded()
        XCTAssertFalse(recorder.isRecording)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(recorder)
        XCTAssertTrue(recorder.isRecording)
        recorder.keyDown(with: event(code: 53, character: "\u{1b}"))
        recorder.startAutomaticallyIfNeeded()
        XCTAssertFalse(recorder.isRecording, "SwiftUI updates must not restart an already cancelled recorder")
    }

    func testRecorderCancelsAndPassesThroughNativeSystemAndAccessibilityChords() {
        let recorder = ReviewShortcutRecorderButton()
        var captureCount = 0
        var invalidCount = 0
        recorder.onCapture = { _ in captureCount += 1; return true }
        recorder.onInvalid = { invalidCount += 1 }
        let nativeChords: [NSEvent.ModifierFlags] = [.command, .control, .option, [.control, .option], .function, .help]
        for modifiers in nativeChords {
            recorder.startRecording()
            XCTAssertFalse(recorder.performKeyEquivalent(with: event(code: 14, character: "e", modifiers: modifiers)))
            XCTAssertFalse(recorder.isRecording, "Native chords must end recording without consuming the event")
        }
        recorder.startRecording()
        recorder.keyDown(with: event(code: 14, character: "e", modifiers: [.control, .option]))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(captureCount, 0)
        XCTAssertEqual(invalidCount, 0)
    }

    private func event(code: UInt16, character: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: character,
                         charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
}
