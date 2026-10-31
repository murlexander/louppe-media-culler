import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class HotkeyTests: XCTestCase {
    private static var retainedHostingWindows: [NSWindow] = []

    func testKeyboardNavigationKeepsTabAndShiftTabWhileGStillSwitchesViews() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let context = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false,
                                               isKeyboardNavigationEnabled: true)
        for modifiers: NSEvent.ModifierFlags in [[], .shift] {
            XCTAssertFalse(view.handleKey(keyEvent(code: 48, characters: "\t", modifiers: modifiers), context: context))
            XCTAssertEqual(store.viewMode, .gallery)
        }
        XCTAssertTrue(view.handleKey(keyEvent(code: 5, characters: "g"), context: context))
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertTrue(view.handleKey(keyEvent(code: 48, characters: "\t"), context: .focusedSession))
        XCTAssertEqual(store.viewMode, .gallery)
    }

    func testToolbarHintsShowOnlyAliasesThatRouteInTheCurrentContext() {
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        let gridKey = ReviewShortcutBinding(character: "b", keyCode: 11)
        let photoKey = ReviewShortcutBinding(character: "y", keyCode: 16)
        XCTAssertTrue(preferences.add(gridKey, for: .export, scope: .grid))
        XCTAssertTrue(preferences.add(photoKey, for: .info, scope: .photos))
        let store = readyStore(itemCount: 3, firstItemIsVideo: true)
        let view = SessionView(store: store)
        func hint(_ action: ReviewShortcutAction, command: CommandShortcutAction? = nil) -> String {
            view.toolbarShortcutHint(for: action, command: command,
                                     shortcutPreferences: preferences, commandShortcutPreferences: .init())
        }

        XCTAssertEqual(hint(.export, command: .export), "E / ⌘E")
        XCTAssertEqual(hint(.info), "W")
        XCTAssertNil(preferences.match(for: keyEvent(code: 11, characters: "b"), context: .galleryPlayableVideo))
        store.viewMode = .grid
        XCTAssertEqual(hint(.export, command: .export), "E / B / ⌘E")
        XCTAssertEqual(preferences.match(for: keyEvent(code: 11, characters: "b"), context: .gridPlayableVideo)?.action, .export)
        store.setIndex(1)
        XCTAssertEqual(hint(.info), "W / Y")
        XCTAssertEqual(preferences.match(for: keyEvent(code: 16, characters: "y"), context: .gridPhoto)?.action, .info)
        store.viewMode = .gallery
        XCTAssertEqual(hint(.export, command: .export), "E / ⌘E")
    }

    func testEditedCommandAliasesRespectOwnershipCapsLockAndRemoval() throws {
        var preferences = CommandShortcutPreferences()
        let original = try XCTUnwrap(preferences.bindings(for: .export).first)
        XCTAssertTrue(preferences.replace(original, with: .init(character: "t", keyCode: 17, modifiers: .commandShift), for: .export))
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let event = keyEvent(code: 17, characters: "T", modifiers: [.command, .shift])
        let text = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false,
                                            focusedResponderOwnsText: true, focusedResponderOwnsNavigation: true)
        let modal = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: true)
        for context in [text, modal, .blocked] {
            XCTAssertFalse(view.handleKey(event, context: context, commandShortcutPreferences: preferences))
        }
        XCTAssertFalse(view.handleKey(keyEvent(code: 14, characters: "e", modifiers: .command), context: .focusedSession, commandShortcutPreferences: preferences))
        XCTAssertFalse(view.handleKey(keyEvent(code: 17, characters: "t", modifiers: .command), context: .focusedSession, commandShortcutPreferences: preferences))
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(view.handleKey(keyEvent(code: 17, characters: "T", modifiers: [.command, .shift, .function]), context: .focusedSession, commandShortcutPreferences: preferences))
        let voiceOver = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false, isVoiceOverEnabled: true)
        XCTAssertFalse(view.handleKey(keyEvent(code: 17, characters: "T", modifiers: [.command, .shift, .capsLock]), context: voiceOver, commandShortcutPreferences: preferences))
        XCTAssertTrue(view.handleKey(event, context: .focusedSession, commandShortcutPreferences: preferences))
        XCTAssertTrue(store.isExportPresented)
        store.isExportPresented = false
        XCTAssertTrue(view.handleKey(keyEvent(code: 17, characters: "T", modifiers: [.command, .shift, .capsLock]), context: .focusedSession, commandShortcutPreferences: preferences))
    }

#if DEBUG
    func testInstalledMonitorUsesSavedCommandAliasesAndLeavesOldDefaultInactive() throws {
        _ = NSApplication.shared
        let domain = "HotkeyTests.Command.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var preferences = CommandShortcutPreferences()
        let original = try XCTUnwrap(preferences.bindings(for: .export).first)
        XCTAssertTrue(preferences.replace(original, with: .init(character: "t", keyCode: 17, modifiers: .commandShift), for: .export))
        preferences.save(to: defaults)
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let host = NSHostingView(rootView: SessionView(store: store).defaultAppStorage(defaults))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let baseline = SessionKeyMonitorTestProbe.activeMonitorCount
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        SessionKeyMonitorTestProbe.overrideKeyWindow(with: window)
        defer {
            store.isExportPresented = false
            window.contentView = nil
            window.orderOut(nil)
            SessionKeyMonitorTestProbe.overrideKeyWindow(with: nil)
        }
        XCTAssertTrue(waitForCondition { SessionKeyMonitorTestProbe.activeMonitorCount == baseline + 1 })
        XCTAssertTrue(window.makeFirstResponder(host))
        sendKeyEvent(code: 14, characters: "e", modifiers: .command, in: window)
        XCTAssertFalse(store.isExportPresented)
        sendKeyEvent(code: 17, characters: "T", modifiers: [.command, .shift], in: window)
        XCTAssertTrue(store.isExportPresented)
        XCTAssertTrue(waitForCondition { window.attachedSheet != nil })
    }
#endif

    func testMultipleAliasesRouteSharedKeyOnlyWithinItsMediaContext() {
        var preferences = ReviewShortcutPreferences()
        let shared = ReviewShortcutBinding(character: "b", keyCode: 11)
        XCTAssertTrue(preferences.add(shared, for: .yes, scope: .photos))
        XCTAssertTrue(preferences.add(shared, for: .no, scope: .videos))
        XCTAssertFalse(preferences.add(shared, for: .info, scope: .gallery))

        let photos = readyStore(itemCount: 3, firstItemIsVideo: false)
        let photoView = SessionView(store: photos)
        XCTAssertTrue(photoView.handleKey(keyEvent(code: 11, characters: "b"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(photos.items[0].rating, .yes)
        XCTAssertTrue(photoView.handleKey(keyEvent(code: 3, characters: "f"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(photos.items[1].rating, .yes)

        let videos = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videos)
        XCTAssertTrue(videoView.handleKey(keyEvent(code: 11, characters: "b"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(videos.items[0].rating, .no)
    }

    func testRemovingNavigationAliasKeepsItsDisjointVideoMeaningAndNativeFocus() throws {
        var preferences = ReviewShortcutPreferences()
        let left = try XCTUnwrap(preferences.assignments(for: .previous).first { $0.binding.keyCode == 123 })
        XCTAssertTrue(preferences.remove(left.id, for: .previous))
        let photos = readyStore(itemCount: 3, firstItemIsVideo: false)
        photos.setIndex(1)
        let photoView = SessionView(store: photos)
        let leftEvent = keyEvent(code: 123, modifiers: [.numericPad, .function])
        XCTAssertFalse(photoView.handleKey(leftEvent, context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(photos.currentIndex, 1)

        let videos = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videos)
        XCTAssertTrue(videoView.handleKey(leftEvent, context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(videos.currentIndex, 0)

        XCTAssertTrue(preferences.add(.init(character: "←", keyCode: 123), for: .yes, scope: .photos))
        let nativeControl = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false,
                                                    focusedResponderOwnsText: false, focusedResponderOwnsNavigation: true)
        XCTAssertFalse(photoView.handleKey(leftEvent, context: nativeControl, shortcutPreferences: preferences))
        XCTAssertEqual(photos.items[1].rating, .undecided)
        XCTAssertTrue(photoView.handleKey(leftEvent, context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(photos.items[1].rating, .yes)
    }

    func testCustomAndPhysicalReviewBindingsUseExistingOwnershipGates() {
        let store = readyStore(itemCount: 4, firstItemIsVideo: false)
        let view = SessionView(store: store)
        var preferences = ReviewShortcutPreferences()
        XCTAssertTrue(preferences.set(.init(character: "b", keyCode: 11), for: .yes))
        XCTAssertFalse(view.handleKey(keyEvent(code: 3, characters: "f"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(store.items[0].rating, .undecided)
        let textContext = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false,
                                                  focusedResponderOwnsText: true, focusedResponderOwnsNavigation: false)
        XCTAssertFalse(view.handleKey(keyEvent(code: 11, characters: "b"), context: textContext, shortcutPreferences: preferences))
        XCTAssertFalse(view.handleKey(keyEvent(code: 11, characters: "b", modifiers: .option), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertTrue(view.handleKey(keyEvent(code: 11, characters: "b"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(store.items[0].rating, .yes)
        preferences.interpretation = .physicalPosition
        XCTAssertTrue(preferences.set(.init(character: "d", keyCode: 4), for: .yes))
        XCTAssertTrue(view.handleKey(keyEvent(code: 4, characters: "d"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(store.items[1].rating, .yes)
        store.isEarlyUserFeedbackPresented = true
        XCTAssertFalse(view.handleKey(keyEvent(code: 4, characters: "d"), context: .focusedSession, shortcutPreferences: preferences))
        XCTAssertEqual(store.items[2].rating, .undecided)
    }

    func testFeedbackPromptOwnsKeysUntilDismissed() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        store.isEarlyUserFeedbackPresented = true
        XCTAssertTrue(store.isSessionCommandPresentationActive)
        XCTAssertFalse(view.handleKey(keyEvent(code: 3, characters: "f")))
        XCTAssertFalse(view.handleKey(keyEvent(code: 37, characters: "l")))
        XCTAssertFalse(view.handleKey(keyEvent(code: 14, characters: "e")))
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertFalse(store.isExportPresented)
        store.isEarlyUserFeedbackPresented = false
        XCTAssertTrue(view.handleKey(keyEvent(code: 3, characters: "f")))
        XCTAssertEqual(store.items[0].rating, .yes)
    }

    func testArrowKeysNavigateGridEvenWhenCurrentItemIsVideo() {
        let store = readyStore(itemCount: 6, firstItemIsVideo: true)
        store.viewMode = .grid
        store.setGridColumnCount(3)
        let view = SessionView(store: store)

        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 124, modifiers: arrowFlags))
        ) // right
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 125, modifiers: arrowFlags))
        ) // down
        XCTAssertEqual(store.currentIndex, 4)
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 126, modifiers: arrowFlags))
        ) // up
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(
            view.handleKey(keyEvent(code: 123, modifiers: arrowFlags))
        ) // left
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testHorizontalReviewKeysKeepJLForItemsAndArrowsForVideoSeeking() {
        let photoStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        photoStore.setIndex(1)
        let photoView = SessionView(store: photoStore)

        XCTAssertTrue(photoView.handleKey(keyEvent(code: 38, characters: "j")))
        XCTAssertEqual(photoStore.currentIndex, 0)
        XCTAssertTrue(photoView.handleKey(keyEvent(code: 37, characters: "l")))
        XCTAssertEqual(photoStore.currentIndex, 1)

        let videoStore = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videoStore)

        XCTAssertTrue(videoView.handleKey(keyEvent(code: 123)))
        XCTAssertEqual(videoStore.currentIndex, 0)
        XCTAssertTrue(videoStore.videoPlayback.isActive(videoStore.items[0]))
        XCTAssertTrue(videoView.handleKey(keyEvent(code: 37, characters: "l")))
        XCTAssertEqual(videoStore.currentIndex, 1)
        XCTAssertTrue(videoView.handleKey(keyEvent(code: 38, characters: "j")))
        XCTAssertEqual(videoStore.currentIndex, 0)

        let focusedPlayer = SessionKeyRoutingContext(
            sessionOwnsEvent: true,
            hasModalPresentation: false,
            focusedResponderOwnsText: false,
            focusedResponderOwnsNavigation: true
        )
        XCTAssertTrue(
            videoView.handleKey(
                keyEvent(code: 37, characters: "l"),
                context: focusedPlayer
            ),
            "J/L must stay review-navigation keys after the native player has focus"
        )
        XCTAssertEqual(videoStore.currentIndex, 1)
        videoStore.setIndex(0)

        XCTAssertTrue(
            videoView.handleKey(keyEvent(code: 124, modifiers: [.shift]))
        )
        XCTAssertEqual(
            videoStore.currentIndex,
            0,
            "Shift-right seeks within the video instead of changing the item"
        )
    }

    func testCommandArrowsAdjustMediaSpeedAndNavigatePhotos() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: true)
        let view = SessionView(store: store)
        store.selectAllVisible()

        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 124, modifiers: [.command])
            )
        )
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.videoPlayback.playbackRate, 1.5)
        XCTAssertFalse(store.selectedIndices.isEmpty)

        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 123, modifiers: [.command])
            )
        )
        XCTAssertEqual(store.videoPlayback.playbackRate, 1)

        let photoStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        let photoView = SessionView(store: photoStore)
        XCTAssertTrue(
            photoView.handleKey(keyEvent(code: 124, modifiers: [.command]))
        )
        XCTAssertEqual(photoStore.currentIndex, 1)
    }

    func testReviewHotkeysStillRateAndAdvance() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: true)
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 3, characters: "f")))
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)

        XCTAssertTrue(view.handleKey(keyEvent(code: 2, characters: "d")))
        XCTAssertEqual(store.items[1].rating, .no)
        XCTAssertEqual(store.currentIndex, 2)
    }

    func testNumericHotkeysSetStarsWithoutChangingDecisionOrAdvancing() {
        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        store.rate(.yes, at: 0)

        XCTAssertTrue(view.handleKey(keyEvent(code: 21, characters: "4")))
        XCTAssertEqual(store.items[0].starRatingState, .stars(.four))
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 0)

        XCTAssertTrue(view.handleKey(keyEvent(code: 29, characters: "0")))
        XCTAssertEqual(store.items[0].starRatingState, .unrated)
        XCTAssertEqual(store.items[0].rating, .yes)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 23, characters: "5", modifiers: [.command])
            )
        )
        XCTAssertEqual(store.items[0].starRatingState, .unrated)
    }

    func testSpaceTogglesPlayableMediaButAdvancesFromPhoto() {
        let videoStore = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videoStore)

        XCTAssertTrue(videoView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(videoStore.currentIndex, 0)
        XCTAssertEqual(videoStore.videoPlayback.itemID, videoStore.items[0].id)
        XCTAssertTrue(videoStore.videoPlayback.isActive(videoStore.items[0]))

        let audioStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        let audioID = "ITEM_0.WAV"
        audioStore.items[0] = PhotoItem(
            id: audioID,
            primaryURL: URL(fileURLWithPath: "/tmp/\(audioID)"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            mediaKind: .audio,
            duration: 2,
            audioIsPlayable: true,
            fileSize: 1
        )
        let audioView = SessionView(store: audioStore)

        XCTAssertTrue(audioView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(audioStore.currentIndex, 0)
        XCTAssertEqual(audioStore.videoPlayback.itemID, audioStore.items[0].id)
        XCTAssertTrue(audioStore.videoPlayback.isActive(audioStore.items[0]))

        let photoStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        let photoView = SessionView(store: photoStore)

        XCTAssertTrue(photoView.handleKey(keyEvent(code: 49, characters: " ")))
        XCTAssertEqual(photoStore.currentIndex, 1)
        XCTAssertNil(photoStore.videoPlayback.itemID)
    }

    func testKTogglesPlayableMediaWithoutChangingPhotoNavigation() {
        let videoStore = readyStore(itemCount: 3, firstItemIsVideo: true)
        let videoView = SessionView(store: videoStore)

        XCTAssertTrue(videoView.handleKey(keyEvent(code: 40, characters: "k")))
        XCTAssertEqual(videoStore.currentIndex, 0)
        XCTAssertTrue(videoStore.videoPlayback.isActive(videoStore.items[0]))

        let photoStore = readyStore(itemCount: 3, firstItemIsVideo: false)
        let photoView = SessionView(store: photoStore)
        XCTAssertFalse(photoView.handleKey(keyEvent(code: 40, characters: "k")))
        XCTAssertEqual(photoStore.currentIndex, 0)
    }

    func testXTogglesClippingWarningsOnlyForSingleGalleryPhoto() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)

        XCTAssertTrue(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertTrue(store.showClippingWarnings)
        XCTAssertTrue(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)

        store.viewMode = .grid
        XCTAssertFalse(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)

        store.viewMode = .gallery
        store.selectAllVisible()
        XCTAssertFalse(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)
    }

    func testXDoesNotToggleClippingWarningsForVideo() {
        let store = readyStore(itemCount: 2, firstItemIsVideo: true)
        let view = SessionView(store: store)

        XCTAssertFalse(view.handleKey(keyEvent(code: 7, characters: "x")))
        XCTAssertFalse(store.showClippingWarnings)
    }

    func testDestructiveShortcutPassesThroughOutsideUnobstructedSessionContext() {
        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandDelete = keyEvent(
            code: 51,
            characters: "\u{7f}",
            modifiers: [.command]
        )
        let blockedContexts = [
            SessionKeyRoutingContext(
                sessionOwnsEvent: false,
                hasModalPresentation: false
            ),
            SessionKeyRoutingContext(
                sessionOwnsEvent: true,
                hasModalPresentation: true
            ),
            SessionKeyRoutingContext(
                sessionOwnsEvent: true,
                hasModalPresentation: false,
                focusedResponderOwnsText: true
            ),
        ]

        for context in blockedContexts {
            XCTAssertFalse(view.handleKey(commandDelete, context: context))
        }
        XCTAssertFalse(store.isFileOperationRunning)
        XCTAssertEqual(store.items.count, 2)
    }

    func testResponderRolesSeparateTextFromNativeControlNavigation() {
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsText(
                NSTextView()
            )
        )
        XCTAssertFalse(
            SessionKeyRoutingContext.responderOwnsText(
                NSSlider()
            )
        )
        XCTAssertFalse(
            SessionKeyRoutingContext.responderOwnsText(
                NSView()
            )
        )
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsNavigation(NSSlider())
        )
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsNavigation(NSView())
        )
        XCTAssertFalse(
            SessionKeyRoutingContext.responderOwnsNavigation(NSWindow())
        )
    }

    func testSessionEventSurvivesTransientMissingKeyWindow() {
        let sessionWindow = NSWindow()
        let otherWindow = NSWindow()

        let exactEventContext = SessionKeyRoutingContext(
            eventWindow: sessionWindow,
            eventWindowNumber: sessionWindow.windowNumber,
            sessionWindow: sessionWindow,
            keyWindow: nil,
            modalWindow: nil
        )
        XCTAssertTrue(exactEventContext.sessionOwnsEvent)

        let numberOnlyContext = SessionKeyRoutingContext(
            eventWindow: nil,
            eventWindowNumber: sessionWindow.windowNumber,
            sessionWindow: sessionWindow,
            keyWindow: nil,
            modalWindow: nil
        )
        XCTAssertTrue(numberOnlyContext.sessionOwnsEvent)

        let inactiveNumberOnlyContext = SessionKeyRoutingContext(
            eventWindow: nil,
            eventWindowNumber: sessionWindow.windowNumber,
            sessionWindow: sessionWindow,
            keyWindow: nil,
            modalWindow: nil,
            applicationIsActive: false
        )
        XCTAssertFalse(inactiveNumberOnlyContext.sessionOwnsEvent)

        let otherKeyWindowContext = SessionKeyRoutingContext(
            eventWindow: sessionWindow,
            eventWindowNumber: sessionWindow.windowNumber,
            sessionWindow: sessionWindow,
            keyWindow: otherWindow,
            modalWindow: nil
        )
        XCTAssertFalse(otherKeyWindowContext.sessionOwnsEvent)
    }

    func testHostedSwiftUIButtonFocusStillAllowsCullingHotkeys() throws {
        let hostingView = NSHostingView(
            rootView: Button("Focused control") {}
                .frame(width: 200, height: 80)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let focusedControlProxy = try XCTUnwrap(hostingView.nextKeyView)
        XCTAssertTrue(window.makeFirstResponder(focusedControlProxy))
        let context = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertTrue(context.acceptsReviewShortcuts)
        XCTAssertFalse(context.acceptsNavigationShortcuts)

        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: context
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 5, characters: "g"),
                context: context
            )
        )
        XCTAssertEqual(store.viewMode, .grid)
        let currentIndex = store.currentIndex
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 49, characters: " "),
                context: context
            ),
            "Space must stay with a keyboard-focused Button"
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 124,
                    modifiers: [.numericPad, .function]
                ),
                context: context
            ),
            "arrows must stay with a keyboard-focused control"
        )
        XCTAssertEqual(store.currentIndex, currentIndex)
        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

    func testSelectableTextRetainsEverySessionCommand() {
        let selectableText = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        selectableText.string = "Selectable metadata"
        selectableText.isEditable = false
        selectableText.isSelectable = true
        let contentView = NSView(frame: selectableText.frame)
        contentView.addSubview(selectableText)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()

        XCTAssertTrue(window.makeFirstResponder(selectableText))
        let context = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertTrue(context.focusedResponderOwnsText)
        XCTAssertFalse(context.acceptsReviewShortcuts)
        XCTAssertFalse(context.acceptsNavigationShortcuts)

        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        store.rate(.yes, at: 0)
        let originalRatings = store.items.map(\.rating)
        let view = SessionView(store: store)
        for event in [
            keyEvent(code: 3, characters: "f"),
            keyEvent(code: 0, characters: "a", modifiers: [.command]),
            keyEvent(code: 14, characters: "e", modifiers: [.command]),
            keyEvent(code: 6, characters: "z", modifiers: [.command]),
            keyEvent(
                code: 51,
                characters: "\u{7f}",
                modifiers: [.command]
            ),
        ] {
            XCTAssertFalse(view.handleKey(event, context: context))
        }
        XCTAssertEqual(store.items.map(\.rating), originalRatings)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(store.isFileOperationRunning)

        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

    func testWindowRootFocusDoesNotInheritNestedSelectableText() {
        let hostingView = NSHostingView(
            rootView: VStack {
                Text("Selectable metadata")
                    .textSelection(.enabled)
                Button("Ordinary control") {}
            }
            .frame(width: 260, height: 100)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(window.makeFirstResponder(hostingView))
        XCTAssertTrue(window.firstResponder === window.contentView)
        let context = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertFalse(context.focusedResponderOwnsText)
        XCTAssertFalse(context.focusedResponderOwnsNavigation)
        XCTAssertEqual(context.isKeyboardNavigationEnabled, NSApp.isFullKeyboardAccessEnabled)
        XCTAssertTrue(context.acceptsReviewShortcuts)
        XCTAssertTrue(context.acceptsNavigationShortcuts)

        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: context
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)

        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

#if DEBUG
    func testRootPhaseTransitionReinstallsLiveSessionMonitor() {
        _ = NSApplication.shared
        let baselineMonitorCount =
            SessionKeyMonitorTestProbe.activeMonitorCount
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let host = NSHostingView(rootView: RootView(store: store))
        host.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        SessionKeyMonitorTestProbe.overrideKeyWindow(with: window)
        defer {
            window.contentView = nil
            window.orderOut(nil)
            SessionKeyMonitorTestProbe.overrideKeyWindow(with: nil)
        }

        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount + 1
        })

        store.isOrganizePresented = true
        XCTAssertTrue(waitForCondition { window.attachedSheet != nil })
        XCTAssertEqual(
            SessionKeyMonitorTestProbe.activeMonitorCount,
            baselineMonitorCount + 1
        )
        store.phase = .scanning(found: 1)
        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount
        })
        XCTAssertTrue(store.isOrganizePresented)
        XCTAssertTrue(waitForCondition { window.attachedSheet == nil })
        store.phase = .ready
        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount + 1
        })
        XCTAssertTrue(waitForCondition { window.attachedSheet != nil })
        store.isOrganizePresented = false
        XCTAssertTrue(waitForCondition { window.attachedSheet == nil })

        sendKeyEvent(code: 3, characters: "f", in: window)
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)
    }

    func testInstalledMonitorRoutesWindowEventsAndIsRemovedWithSessionView() throws {
        _ = NSApplication.shared
        let baselineMonitorCount =
            SessionKeyMonitorTestProbe.activeMonitorCount
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let container = NSView(frame: frame)
        var sessionHost: NSHostingView<SessionView>? = NSHostingView(
            rootView: SessionView(store: store)
        )
        sessionHost?.frame = frame
        if let sessionHost {
            container.addSubview(sessionHost)
        }

        let button = NSButton(
            title: "Focused control",
            target: nil,
            action: nil
        )
        button.refusesFirstResponder = false
        button.frame = NSRect(x: 12, y: 12, width: 140, height: 28)
        container.addSubview(button)

        let selectableText = NSTextView(
            frame: NSRect(x: 170, y: 12, width: 180, height: 28)
        )
        selectableText.string = "Selectable metadata"
        selectableText.isEditable = false
        selectableText.isSelectable = true
        selectableText.drawsBackground = false
        container.addSubview(selectableText)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        // XCTest bundles cannot become the process's active app, so AppKit
        // never assigns their otherwise-real test window to NSApp.keyWindow.
        // The debug-only override supplies only that unavailable fact; event
        // monitoring, window-number matching, hosting-window discovery,
        // first responders, and teardown all remain the production path.
        SessionKeyMonitorTestProbe.overrideKeyWindow(with: window)
        defer {
            sessionHost?.removeFromSuperview()
            sessionHost = nil
            window.orderOut(nil)
            SessionKeyMonitorTestProbe.overrideKeyWindow(with: nil)
        }

        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount + 1
        })

        // Exercise the installed NSEvent monitor, its live NSWindow lookup,
        // and its non-text-control focus policy rather than calling handleKey.
        XCTAssertTrue(window.makeFirstResponder(button))
        sendKeyEvent(code: 3, characters: "f", in: window)
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)
        sendKeyEvent(code: 5, characters: "g", in: window)
        XCTAssertEqual(store.viewMode, .grid)

        // Selectable text owns every key. If the live routing misclassifies
        // this responder, D would rate item 1 and Command-A would select media.
        XCTAssertTrue(window.makeFirstResponder(selectableText))
        XCTAssertTrue(
            SessionKeyRoutingContext.responderOwnsText(
                window.firstResponder
            )
        )
        sendKeyEvent(code: 2, characters: "d", in: window)
        sendKeyEvent(
            code: 0,
            characters: "a",
            modifiers: [.command],
            in: window
        )
        XCTAssertEqual(store.items[1].rating, .undecided)
        XCTAssertTrue(store.selectedIndices.isEmpty)

        // A SessionView can leave and re-enter the persistent window while a
        // folder is closed, rescanned, or replaced. Its process-wide monitor
        // must disappear while detached and reliably return on reattachment.
        sessionHost?.removeFromSuperview()
        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount
        })
        if let sessionHost {
            container.addSubview(sessionHost)
        }
        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount + 1
        })
        XCTAssertTrue(window.makeFirstResponder(button))
        sendKeyEvent(code: 2, characters: "d", in: window)
        XCTAssertEqual(store.items[1].rating, .no)
        XCTAssertEqual(store.currentIndex, 2)

        // Final removal must unregister the monitor. Dispatching the same key
        // afterward must leave state alone.
        sessionHost?.removeFromSuperview()
        sessionHost = nil
        XCTAssertTrue(waitForCondition {
            SessionKeyMonitorTestProbe.activeMonitorCount
                == baselineMonitorCount
        })
        XCTAssertTrue(window.makeFirstResponder(button))
        sendKeyEvent(code: 2, characters: "d", in: window)
        XCTAssertEqual(store.items[2].rating, .undecided)
    }
#endif

    func testTextEditorBlocksUntilEditingFocusEnds() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextField(
            frame: NSRect(x: 20, y: 20, width: 200, height: 24)
        )
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(editor)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        XCTAssertTrue(window.makeFirstResponder(editor))
        let editingContext = SessionKeyRoutingContext(
            eventWindow: window,
            eventWindowNumber: window.windowNumber,
            sessionWindow: window,
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertFalse(editingContext.acceptsReviewShortcuts)

        XCTAssertTrue(window.makeFirstResponder(nil))

        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: SessionKeyRoutingContext(
                    eventWindow: window,
                    eventWindowNumber: window.windowNumber,
                    sessionWindow: window,
                    keyWindow: window,
                    modalWindow: nil
                )
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        window.orderOut(nil)
        Self.retainedHostingWindows.append(window)
    }

    func testEmptySessionCannotPresentExportFromToolbarOrHotkeys() {
        let store = readyStore(itemCount: 1, firstItemIsVideo: false)
        let movedIDs = store.items.map(\.id)
        XCTAssertTrue(store.exportWillStart(mode: .move))
        store.finishExport(
            mode: .move,
            movedIDs: movedIDs,
            requiresRecovery: false
        )
        let view = SessionView(store: store)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertFalse(store.canExport)
        XCTAssertFalse(store.canCleanUp)
        store.presentExport()
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 14, characters: "e"),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 51,
                    characters: "\u{7f}",
                    modifiers: [.command]
                ),
                context: .focusedSession
            ),
            "an unavailable destructive action must not swallow Command-Delete"
        )
        XCTAssertFalse(store.isExportPresented)
        XCTAssertFalse(store.isFileOperationRunning)
    }

    func testPresentedSessionUIPassesThroughBeforeCommandShortcuts() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandA = keyEvent(
            code: 0,
            characters: "a",
            modifiers: [.command]
        )

        store.isExportPresented = true
        XCTAssertFalse(view.handleKey(commandA, context: .focusedSession))
        XCTAssertTrue(store.selectedIndices.isEmpty)

        store.isExportPresented = false
        store.isFilterPresented = true
        XCTAssertFalse(view.handleKey(commandA, context: .focusedSession))
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testLegacyMigrationConfirmationBlocksSessionHotkeys() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        store.presentLegacySessionMigrationConfirmationForTesting()

        XCTAssertTrue(store.isSessionCommandPresentationActive)
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 3, characters: "f"),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.items[0].rating, .undecided)
        XCTAssertFalse(store.isExportPresented)
    }

    func testMenuEquivalentKeysUseTheSameFocusedSessionGate() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandE = keyEvent(
            code: 14,
            characters: "e",
            modifiers: [.command]
        )

        XCTAssertFalse(view.handleKey(commandE, context: .blocked))
        XCTAssertFalse(store.isExportPresented)

        XCTAssertTrue(view.handleKey(commandE, context: .focusedSession))
        XCTAssertTrue(store.isExportPresented)

        store.isExportPresented = false
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(store.isExportPresented)
    }

    func testCommandFFocusesFilterSearchThroughFocusedSessionGate() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandF = keyEvent(
            code: 3,
            characters: "f",
            modifiers: [.command]
        )

        XCTAssertFalse(view.handleKey(commandF, context: .blocked))
        XCTAssertFalse(store.isFilterPresented)

        XCTAssertTrue(view.handleKey(commandF, context: .focusedSession))
        XCTAssertTrue(store.isFilterPresented)
        XCTAssertTrue(store.takeFilterSearchFocusRequest())
        XCTAssertFalse(store.takeFilterSearchFocusRequest())
    }

    func testCommandPaletteUsesFocusedSessionGateAndRunsAfterDismissal() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let commandK = keyEvent(
            code: 40,
            characters: "k",
            modifiers: [.command]
        )

        XCTAssertFalse(view.handleKey(commandK, context: .blocked))
        XCTAssertFalse(store.isActionPalettePresented)

        XCTAssertTrue(view.handleKey(commandK, context: .focusedSession))
        XCTAssertTrue(store.isActionPalettePresented)
        XCTAssertTrue(store.isSessionCommandPresentationActive)

        var didRunFollowUp = false
        store.dismissActionPalette {
            didRunFollowUp = true
        }
        XCTAssertFalse(didRunFollowUp)
        store.finishActionPaletteDismissal()
        XCTAssertTrue(didRunFollowUp)

        store.isExportPresented = true
        XCTAssertFalse(view.handleKey(commandK, context: .focusedSession))
        store.isExportPresented = false

        store.isRenamePresented = true
        XCTAssertTrue(store.isSessionCommandPresentationActive)
        XCTAssertFalse(view.handleKey(commandK, context: .focusedSession))
        store.isRenamePresented = false

        let textEditing = SessionKeyRoutingContext(
            sessionOwnsEvent: true,
            hasModalPresentation: false,
            focusedResponderOwnsText: true,
            focusedResponderOwnsNavigation: true
        )
        XCTAssertFalse(view.handleKey(commandK, context: textEditing))
        XCTAssertFalse(store.isActionPalettePresented)
    }

    func testCommandPaletteIncludesWorkingMediaAndAdjacentItemActions() throws {
        let store = readyStore(itemCount: 3, firstItemIsVideo: true)
        store.rebuildDerivedDataForTesting()
        let palette = ActionPaletteView(store: store)
        let actions = palette.actions

        let ids = Set(actions.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "select-previous-item",
            "select-next-item",
            "decrease-playback-rate",
            "increase-playback-rate",
            "seek-video-backward",
            "seek-video-forward",
            "seek-video-backward-large",
            "seek-video-forward-large",
            "toggle-current-media",
            "set-playback-rate-1x",
            "set-playback-rate-1-5x",
            "set-playback-rate-2x",
            "set-playback-rate-2-5x",
            "show-videos-only",
            "sort-by-video-resolution",
            "sort-by-video-frame-rate",
            "sort-by-video-codec",
        ]))

        let seekForward = try XCTUnwrap(
            actions.first(where: { $0.id == "seek-video-forward" })
        )
        XCTAssertTrue(seekForward.isEnabled)
        seekForward.perform()
        XCTAssertTrue(store.videoPlayback.isActive(store.items[0]))

        let fasterPlayback = try XCTUnwrap(
            actions.first(where: { $0.id == "set-playback-rate-2x" })
        )
        XCTAssertTrue(fasterPlayback.isEnabled)
        fasterPlayback.perform()
        XCTAssertEqual(store.videoPlayback.playbackRate, 2)

        let increasePlayback = try XCTUnwrap(
            actions.first(where: { $0.id == "increase-playback-rate" })
        )
        XCTAssertEqual(increasePlayback.shortcut, "⌘→")
        increasePlayback.perform()
        XCTAssertEqual(store.videoPlayback.playbackRate, 2.5)

        let selectNext = try XCTUnwrap(
            actions.first(where: { $0.id == "select-next-item" })
        )
        XCTAssertTrue(try XCTUnwrap(selectNext.shortcut).contains("L"))
        XCTAssertTrue(selectNext.isEnabled)
        selectNext.perform()
        XCTAssertEqual(store.currentIndex, 1)

        let videosOnly = try XCTUnwrap(
            actions.first(where: { $0.id == "show-videos-only" })
        )
        XCTAssertTrue(videosOnly.isEnabled)
        videosOnly.perform()
        XCTAssertEqual(store.visibleIndices, [0])

        let audioStore = readyStore(
            itemCount: 1,
            firstItemIsVideo: false,
            firstItemIsAudio: true
        )
        audioStore.rebuildDerivedDataForTesting()
        let audioPlayback = try XCTUnwrap(
            ActionPaletteView(store: audioStore).actions.first(where: {
                $0.id == "set-playback-rate-2-5x"
            })
        )
        XCTAssertTrue(audioPlayback.isEnabled)
        audioPlayback.perform()
        XCTAssertEqual(audioStore.videoPlayback.playbackRate, 2.5)

        let photoPalette = ActionPaletteView(
            store: readyStore(itemCount: 2, firstItemIsVideo: false)
        )
        XCTAssertFalse(
            try XCTUnwrap(
                photoPalette.actions.first(where: {
                    $0.id == "seek-video-forward"
                })
            ).isEnabled
        )
    }

    func testCommandPaletteKeepsBatchRenameButNotSingleFileRename() throws {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let actions = ActionPaletteView(store: store).actions
        XCTAssertNil(actions.first { $0.id == "rename-current-file" })
        let metadata = try XCTUnwrap(actions.first {
            $0.id == "rename-files-from-metadata"
        })

        XCTAssertTrue(metadata.isEnabled)
        XCTAssertTrue(metadata.searchText.contains("camera"))
        XCTAssertTrue(metadata.searchText.contains("sequence"))

        metadata.perform()
        XCTAssertTrue(store.isRenamePresented)
        XCTAssertEqual(store.fileRenamingPresentationMode, .metadata)

        store.isRenamePresented = false
        store.selectAllVisible()
        let selectedActions = ActionPaletteView(store: store).actions
        XCTAssertTrue(try XCTUnwrap(selectedActions.first {
            $0.id == "rename-files-from-metadata"
        }).isEnabled)
    }

    func testCommandPaletteIncludesPairedComponentCleanUpActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-Palette-Pair-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("PAIR.NEF")
        let jpeg = root.appendingPathComponent("PAIR.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)

        let store = SessionStore()
        store.items = [PhotoItem(
            id: "PAIR.NEF",
            primaryURL: raw,
            pairedURL: jpeg,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 3,
            pairedFileSize: 4
        )]
        store.phase = .ready
        store.cleanUpScope = .all
        store.rebuildDerivedDataForTesting(sourceFolder: root)

        let actions = ActionPaletteView(store: store).actions
        let jpegAction = try XCTUnwrap(actions.first {
            $0.id == "trash-paired-jpegs"
        })
        let rawAction = try XCTUnwrap(actions.first {
            $0.id == "trash-paired-raws"
        })
        XCTAssertEqual(jpegAction.title, "Trash Paired JPEGs…")
        XCTAssertEqual(rawAction.title, "Trash Paired RAWs…")
        XCTAssertTrue(jpegAction.isEnabled)
        XCTAssertTrue(rawAction.isEnabled)
        jpegAction.perform()
        XCTAssertEqual(store.pendingCleanUp, .pairedJPEGs)
        store.pendingCleanUp = nil
        rawAction.perform()
        XCTAssertEqual(store.pendingCleanUp, .pairedRAWs)

        let ordinary = readyStore(itemCount: 2, firstItemIsVideo: false)
        let ordinaryActions = ActionPaletteView(store: ordinary).actions
        XCTAssertFalse(try XCTUnwrap(ordinaryActions.first {
            $0.id == "trash-paired-jpegs"
        }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(ordinaryActions.first {
            $0.id == "trash-paired-raws"
        }).isEnabled)
    }

    func testCommandPaletteUsesFilterWordingForRAWJPEGPairing() throws {
        let store = readyStore(itemCount: 2, firstItemIsVideo: false)
        let pairingAction = try XCTUnwrap(
            ActionPaletteView(store: store).actions.first {
                $0.id == "toggle-raw-jpeg-pairing"
            }
        )

        XCTAssertEqual(
            pairingAction.title,
            RawJPEGPairingMode.togetherControlTitle
        )
        XCTAssertTrue(pairingAction.searchText.contains("review"))
    }

    func testCommandPaletteRanksSpecificActionsAndNormalizesSearch() throws {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let actions = ActionPaletteView(store: store).actions

        XCTAssertEqual(
            ActionPaletteSearch.results(for: "keep photo", in: actions).first?.id,
            "mark-yes"
        )
        XCTAssertEqual(
            ActionPaletteSearch.results(for: "2 stars", in: actions).first?.id,
            "stars-2"
        )
        XCTAssertEqual(
            ActionPaletteSearch.results(for: "RAW+JPEG separately", in: actions).first?.id,
            "toggle-raw-jpeg-pairing"
        )
        XCTAssertEqual(
            ActionPaletteSearch.results(for: "larger thumbnails", in: actions).first?.id,
            "grid-zoom-in"
        )
        XCTAssertEqual(
            ActionPaletteSearch.results(for: "1.5x speed", in: actions).first?.id,
            "set-playback-rate-1-5x"
        )
        XCTAssertEqual(
            ActionPaletteSearch.results(for: "trash paired jpegs", in: actions).first?.id,
            "trash-paired-jpegs"
        )
    }

    func testCommandPaletteShowsHotkeysAndNewActions() throws {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let actions = ActionPaletteView(store: store).actions
        func action(_ id: String) throws -> ActionPaletteAction {
            try XCTUnwrap(actions.first { $0.id == id })
        }

        XCTAssertEqual(try action("export").shortcut, "E position / ⌘E")
        XCTAssertEqual(try action("gallery").shortcut, "Tab / G position")
        XCTAssertEqual(try action("undo").shortcut, "Z position / ⌘Z")
        XCTAssertEqual(try action("filter-search").shortcut, "⌘F")
        XCTAssertEqual(try action("grid-zoom-in").shortcut, "⌘+")
        XCTAssertEqual(try action("actual-size").shortcut, "S position")
        XCTAssertEqual(try action("phone-size").shortcut, "A position")
        XCTAssertEqual(try action("select-to-first").shortcut, "⇧⌘←")
        XCTAssertEqual(try action("select-to-last").shortcut, "⇧⌘→")
        XCTAssertEqual(try action("grid-item-above").shortcut, "")
        XCTAssertEqual(try action("grid-item-below").shortcut, "")
        store.viewMode = .grid
        let gridActions = ActionPaletteView(store: store).actions
        XCTAssertEqual(gridActions.first { $0.id == "grid-item-above" }?.shortcut, "↑")
        XCTAssertEqual(gridActions.first { $0.id == "grid-item-below" }?.shortcut, "↓")
        store.viewMode = .gallery
        XCTAssertTrue(try action("trash-selection").detail.contains("skips confirmation"))
        XCTAssertTrue(try action("mark-yes").detail.contains("advance"))
        XCTAssertTrue(try action("close-session").isEnabled)
    }

    func testAppCommandsRemainAvailableFromNonTextControlFocus() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let focusedButton = SessionKeyRoutingContext(
            sessionOwnsEvent: true,
            hasModalPresentation: false,
            focusedResponderOwnsText: false,
            focusedResponderOwnsNavigation: true
        )

        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: focusedButton
            )
        )
        XCTAssertTrue(store.isExportPresented)
    }

    func testTextEditingRetainsStandardCommandShortcuts() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        let textEditing = SessionKeyRoutingContext(
            sessionOwnsEvent: true,
            hasModalPresentation: false,
            focusedResponderOwnsText: true,
            focusedResponderOwnsNavigation: true
        )

        for event in [
            keyEvent(code: 14, characters: "e", modifiers: [.command]),
            keyEvent(code: 6, characters: "z", modifiers: [.command]),
            keyEvent(code: 0, characters: "a", modifiers: [.command]),
        ] {
            XCTAssertFalse(view.handleKey(event, context: textEditing))
        }
        XCTAssertFalse(store.isExportPresented)
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testOnlyExactDocumentedModifiersReachSessionCommands() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 0,
                    characters: "a",
                    modifiers: [.command, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertTrue(store.selectedIndices.isEmpty)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.control, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.function]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.help]
                ),
                context: .focusedSession
            )
        )
        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.capsLock]
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.items[0].rating, .yes)
        XCTAssertEqual(store.currentIndex, 1)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.capsLock]
                ),
                context: SessionKeyRoutingContext(
                    sessionOwnsEvent: true,
                    hasModalPresentation: false,
                    isVoiceOverEnabled: true
                )
            ),
            "Caps Lock must remain VoiceOver's modifier while it is running"
        )

        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 2,
                    characters: "D",
                    modifiers: [.shift],
                    charactersIgnoringModifiers: "d"
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.items[1].rating, .no)

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 48,
                    characters: "\t",
                    modifiers: [.shift]
                ),
                context: .focusedSession
            ),
            "Shift-Tab must remain native reverse focus navigation"
        )

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 51,
                    characters: "\u{7f}",
                    modifiers: [.command, .shift]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(store.isFileOperationRunning)

        XCTAssertTrue(
            view.handleKey(
                keyEvent(
                    code: 0,
                    characters: "a",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertEqual(store.selectedIndices.count, 3)
    }

    func testFileOperationPassesThroughModifiersSheetsAndUnknownKeys() {
        let store = readyStore(itemCount: 3, firstItemIsVideo: false)
        let view = SessionView(store: store)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        defer {
            store.finishExport(
                mode: .copy,
                movedIDs: [],
                requiresRecovery: false
            )
        }

        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 3,
                    characters: "f",
                    modifiers: [.control, .option]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(
                    code: 14,
                    characters: "e",
                    modifiers: [.command]
                ),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 11, characters: "b"),
                context: .focusedSession
            )
        )
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 48, characters: "\t", modifiers: [.shift]),
                context: .focusedSession
            )
        )

        let initialMode = store.viewMode
        XCTAssertFalse(
            view.handleKey(
                keyEvent(code: 5, characters: "g"),
                context: SessionKeyRoutingContext(
                    sessionOwnsEvent: true,
                    hasModalPresentation: true
                )
            )
        )
        XCTAssertEqual(store.viewMode, initialMode)

        XCTAssertTrue(
            view.handleKey(
                keyEvent(code: 5, characters: "g"),
                context: .focusedSession
            )
        )
        XCTAssertNotEqual(store.viewMode, initialMode)
    }

    private func readyStore(
        itemCount: Int,
        firstItemIsVideo: Bool,
        firstItemIsAudio: Bool = false
    ) -> SessionStore {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = (0..<itemCount).map { index in
            let isVideo = firstItemIsVideo && index == 0
            let isAudio = firstItemIsAudio && index == 0
            let ext = isVideo ? "MOV" : (isAudio ? "WAV" : "JPG")
            let id = "ITEM_\(index).\(ext)"
            return PhotoItem(
                id: id,
                primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                mediaKind: isVideo ? .video : (isAudio ? .audio : .photo),
                duration: (isVideo || isAudio) ? 2 : nil,
                videoIsPlayable: isVideo,
                audioIsPlayable: isAudio,
                fileSize: 1
            )
        }
        // A sort change rebuilds the same visibility structures populated by
        // a real folder scan, while keeping the test independent of disk I/O.
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready
        return store
    }

    private func keyEvent(
        code: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        charactersIgnoringModifiers: String? = nil
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers:
                charactersIgnoringModifiers ?? characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private func sendKeyEvent(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
        NSApp.sendEvent(event)
    }

    private func waitForCondition(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        return condition()
    }
}
