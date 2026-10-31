import AppKit
import XCTest
@testable import Louppe

@MainActor
final class MenuShortcutColumnsTests: XCTestCase {
    private let galleryPhoto = ReviewShortcutContext(
        viewMode: .gallery, mediaKind: .photo, isPlayable: false, canSeekVideo: false
    )

    func testUnrelatedMenuNotificationsDoNotTraverseMainMenu() async throws {
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        defer { app.mainMenu = originalMenu }
        let main = ShortcutCountingMenu(title: "Main")
        let item = NSMenuItem(title: L10n.text("Export…"), action: nil, keyEquivalent: "")
        main.addItem(item)
        app.mainMenu = main
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        let columns = MenuShortcutColumns(store: store)
        columns.refresh()
        main.itemReads = 0

        let detached = NSMenu(title: "Settings picker")
        let choice = NSMenuItem(title: L10n.text("Grid"), action: nil, keyEquivalent: "")
        detached.addItem(choice)
        choice.title = L10n.text("Gallery")
        detached.removeItem(choice)
        let names = [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification,
                     NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification,
                     NSMenu.didEndTrackingNotification]
        for name in names { NotificationCenter.default.post(name: name, object: detached) }
        XCTAssertEqual(main.itemReads, 0, "Detached menus must not trigger a decoration pass")
        XCTAssertNil(choice.attributedTitle)

        // Ignore unrelated background notifications before entering the main
        // actor, even when their sender does not carry a menu object.
        await Task.detached {
            for name in names { NotificationCenter.default.post(name: name, object: nil) }
        }.value
        XCTAssertEqual(main.itemReads, 0)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        XCTAssertGreaterThan(main.itemReads, 0, "Main-menu tracking still forces synchronous refresh")
        XCTAssertFalse(item.keyEquivalent.isEmpty)
        withExtendedLifetime(columns) {}
    }

    func testScheduledRefreshSkipsUnchangedHintsAndUpdatesPreferencesAndContext() async throws {
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        let domain = "MenuShortcutColumnsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            app.mainMenu = originalMenu
            defaults.removePersistentDomain(forName: domain)
        }
        var preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        XCTAssertTrue(preferences.add(.init(character: "b", keyCode: 11), for: .export, scope: .gallery))
        preferences.save(to: defaults)
        let main = ShortcutCountingMenu(title: "Main")
        let item = NSMenuItem(title: L10n.text("Export…"), action: nil, keyEquivalent: "")
        main.addItem(item)
        app.mainMenu = main
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        let columns = MenuShortcutColumns(store: store, defaults: defaults)
        columns.refresh()
        XCTAssertEqual(item.accessibilityHelp(), "E / B / ⌘E")
        main.itemReads = 0

        store.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(main.itemReads, 0, "Unrelated state publications must reuse unchanged hints")

        store.viewMode = .grid
        await waitForHint("E / ⌘E", on: item)
        XCTAssertGreaterThan(main.itemReads, 0)
        XCTAssertTrue(preferences.add(.init(character: "y", keyCode: 16), for: .export))
        preferences.save(to: defaults)
        // A deterministic defaults notification also covers platforms where
        // suite defaults notifications are delayed or coalesced by Foundation.
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await waitForHint("E / Y / ⌘E", on: item)

        // Equal hints cannot suppress structural refresh of a newly built row.
        let replacement = NSMenuItem(title: L10n.text("Export…"), action: nil, keyEquivalent: "")
        main.addItem(replacement)
        XCTAssertEqual(replacement.accessibilityHelp(), "E / Y / ⌘E")
        var commands = CommandShortcutPreferences()
        XCTAssertTrue(commands.replace(commands.bindings(for: .export)[0],
                                       with: .init(character: "t", keyCode: 17, modifiers: .command), for: .export))
        defaults.set(commands.encoded, forKey: CommandShortcutPreferences.preferenceKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await waitForHint("E / Y / ⌘T", on: item)
        withExtendedLifetime(columns) {}
    }

    private func waitForHint(_ expected: String, on item: NSMenuItem) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while item.accessibilityHelp() != expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(item.accessibilityHelp(), expected)
    }

    func testLazyMenuCreationAndAttachmentRefreshWithoutRunLoopYield() {
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        let domain = "MenuShortcutColumnsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            app.mainMenu = originalMenu
            defaults.removePersistentDomain(forName: domain)
        }
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .keyboardLayout
        preferences.save(to: defaults)
        let main = NSMenu(title: "Main")
        app.mainMenu = main
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        let columns = MenuShortcutColumns(store: store, defaults: defaults)

        // Simulate SwiftUI adding Edit's contents after tracking has begun.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        main.addItem(editItem)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        let undo = NSMenuItem(title: L10n.text("Undo Louppe Action"), action: nil, keyEquivalent: "")
        edit.addItem(undo)
        XCTAssertEqual(undo.accessibilityHelp(), "Z / ⌘Z")
        XCTAssertEqual(undo.keyEquivalent, "Z / ⌘Z")
        XCTAssertEqual(undo.title, L10n.text("Undo Louppe Action"))

        // Build View while detached, then attach the finished submenu.
        let view = NSMenu(title: "View")
        let grid = NSMenuItem(title: L10n.text("Grid"), action: nil, keyEquivalent: "")
        view.addItem(grid)
        XCTAssertNil(grid.attributedTitle, "Unattached menus are not styled")
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        main.addItem(viewItem)
        viewItem.submenu = view
        XCTAssertEqual(grid.accessibilityHelp(), "Tab / G")
        XCTAssertEqual(grid.keyEquivalent, "Tab / G")

        // A lazily supplied title must be styled immediately as well.
        let gallery = NSMenuItem(title: "Placeholder", action: nil, keyEquivalent: "")
        view.addItem(gallery)
        gallery.title = L10n.text("Gallery")
        XCTAssertEqual(gallery.accessibilityHelp(), "Tab / G")
        XCTAssertEqual(gallery.title, L10n.text("Gallery"))

        let picker = NSMenu(title: "Settings Picker")
        let pickerGrid = NSMenuItem(title: L10n.text("Grid"), action: nil, keyEquivalent: "")
        picker.addItem(pickerGrid)
        XCTAssertNil(pickerGrid.attributedTitle)
        XCTAssertNil(pickerGrid.accessibilityHelp())
        withExtendedLifetime(columns) {}
    }

    func testDisplayColumnKeepsPlainActionAndNativeBehavior() {
        let menu = NSMenu(title: "File")
        let presentation = MenuShortcutPresentation()
        menu.autoenablesItems = false
        let target = MenuActionTarget()
        let item = NSMenuItem(title: "Export…", action: #selector(MenuActionTarget.performMenuAction(_:)), keyEquivalent: "")
        item.target = target
        item.state = .on
        menu.addItem(item)
        let entry = MenuShortcutColumns.Entry(title: item.title, hint: "E / ⌘E", accessibilityHint: "E / ⌘E")
        presentation.apply([entry], to: menu, isTracking: true)

        XCTAssertEqual(item.title, "Export…")
        XCTAssertNil(item.attributedTitle)
        XCTAssertEqual(item.accessibilityTitle(), "Export…")
        XCTAssertEqual(item.accessibilityLabel(), "Export…")
        XCTAssertEqual(item.accessibilityHelp(), "E / ⌘E")
        XCTAssertEqual(item.keyEquivalent, "E / ⌘E")
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.action, #selector(MenuActionTarget.performMenuAction(_:)))
        XCTAssertEqual(item.state, .on)
        XCTAssertNil(item.view, "Native menu rows retain keyboard and accessibility navigation")
        XCTAssertFalse(menu.performKeyEquivalent(with: event("e", code: 14)))
        XCTAssertFalse(menu.performKeyEquivalent(with: event("e", code: 14, modifiers: .command)))
        XCTAssertEqual(target.count, 0, "Display-only hints cannot bypass SessionView")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(target.count, 1)
    }

    func testNativeSystemEquivalentAndDisabledStateRemainUntouched() {
        let menu = NSMenu(title: "File")
        let presentation = MenuShortcutPresentation()
        menu.autoenablesItems = false
        let target = MenuActionTarget()
        let item = NSMenuItem(title: "Export…", action: #selector(MenuActionTarget.performMenuAction(_:)), keyEquivalent: "n")
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = false
        menu.addItem(item)
        presentation.apply([.init(title: item.title, hint: "T", accessibilityHint: "T")], to: menu, isTracking: true)
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        item.isEnabled = true
        XCTAssertTrue(menu.performKeyEquivalent(with: event("n", code: 45, modifiers: .command)))
        XCTAssertEqual(target.count, 1)
    }

    func testPreferenceEditsAndContextsReplaceHintsWithoutStaleAliases() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .keyboardLayout
        XCTAssertTrue(preferences.set(.init(character: "b", keyCode: 11), for: .export))
        XCTAssertTrue(preferences.add(.init(character: "y", keyCode: 16), for: .export, scope: .gallery))
        func exportHint(_ context: ReviewShortcutContext) -> String? {
            MenuShortcutColumns.entries(preferences: preferences, context: context).first { $0.title == L10n.text("Export…") }?.hint
        }
        XCTAssertEqual(exportHint(galleryPhoto), "B / Y / ⌘E")
        let gridPhoto = ReviewShortcutContext(viewMode: .grid, mediaKind: .photo, isPlayable: false, canSeekVideo: false)
        XCTAssertEqual(exportHint(gridPhoto), "B / ⌘E")

        let menu = NSMenu(title: "File")
        let presentation = MenuShortcutPresentation()
        let item = NSMenuItem(title: L10n.text("Export…"), action: nil, keyEquivalent: "")
        menu.addItem(item)
        presentation.apply(MenuShortcutColumns.entries(preferences: preferences, context: galleryPhoto), to: menu, isTracking: true)
        XCTAssertEqual(item.keyEquivalent, "B / Y / ⌘E")
        presentation.apply(MenuShortcutColumns.entries(preferences: preferences, context: gridPhoto), to: menu, isTracking: true)
        XCTAssertEqual(item.keyEquivalent, "B / ⌘E")
        XCTAssertFalse(item.keyEquivalent.contains("Y"))
        XCTAssertEqual(item.title, L10n.text("Export…"))
    }

    func testCommandPreferenceAliasesReplaceDefaultsAndCanBeRemoved() {
        let review = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        var commands = CommandShortcutPreferences()
        let oldExport = commands.bindings(for: .export)[0]
        let replacement = CommandShortcutBinding(character: "t", keyCode: 17, modifiers: .command)
        XCTAssertTrue(commands.replace(oldExport, with: replacement, for: .export))
        XCTAssertTrue(commands.add(.init(character: "y", keyCode: 16, modifiers: .commandShift), for: .export))
        func hint(_ title: L10n.Message) -> String? {
            MenuShortcutColumns.entries(preferences: review, commandPreferences: commands, context: galleryPhoto)
                .first { $0.title == L10n.text(title) }?.hint
        }
        XCTAssertEqual(hint("Export…"), "E / ⌘T / ⇧⌘Y")
        XCTAssertEqual(hint("Command Palette…"), commands.hint(for: .commandPalette))
        XCTAssertEqual(hint("Rescan Folder"), commands.hint(for: .rescan))
        for binding in commands.bindings(for: .export) {
            XCTAssertTrue(commands.remove(binding, for: .export))
        }
        XCTAssertEqual(hint("Export…"), "E", "Removed Command aliases must not leave the default behind")
        for binding in commands.bindings(for: .commandPalette) {
            XCTAssertTrue(commands.remove(binding, for: .commandPalette))
        }
        XCTAssertEqual(hint("Command Palette…"), "")
    }

    func testPhysicalColumnIsCompactAndHelpExplainsPositions() {
        var preferences = ReviewShortcutPreferences()
        preferences.interpretation = .physicalPosition
        XCTAssertTrue(preferences.set(.init(character: "y", keyCode: 11), for: .export))
        let entry = MenuShortcutColumns.entries(preferences: preferences, context: galleryPhoto).first { $0.title == L10n.text("Export…") }!
        XCTAssertEqual(entry.hint, "B / ⌘E")
        let position = "B"
        XCTAssertEqual(entry.accessibilityHint, L10n.text("\(position) position") + " / ⌘E")
    }

    func testColumnUsesActualMenuWidthsAndClearsUnavailableHint() {
        let menu = NSMenu(title: "View")
        let presentation = MenuShortcutPresentation()
        let longTitle = "A much longer translated action title"
        let wide = NSMenuItem(title: longTitle, action: nil, keyEquivalent: "")
        let short = NSMenuItem(title: "Grid", action: nil, keyEquivalent: "")
        menu.addItem(wide)
        menu.addItem(short)
        presentation.apply([
            .init(title: longTitle, hint: "⌘K", accessibilityHint: "⌘K"),
            .init(title: "Grid", hint: "Tab / G / T", accessibilityHint: "Tab / G / T"),
        ], to: menu, isTracking: true)
        XCTAssertNil(wide.attributedTitle, "AppKit owns the native column; no title padding or custom drawing")
        XCTAssertNil(short.attributedTitle)
        XCTAssertEqual(wide.keyEquivalent, "⌘K")
        XCTAssertEqual(short.keyEquivalent, "Tab / G / T")
        XCTAssertEqual(wide.title, longTitle)
        presentation.apply([.init(title: "Grid", hint: "", accessibilityHint: "")], to: menu, isTracking: true)
        XCTAssertEqual(short.title, "Grid")
        XCTAssertNil(short.attributedTitle)
        XCTAssertNil(short.accessibilityHelp())
        XCTAssertEqual(short.keyEquivalent, "")
    }

    func testNativeHintsExistOnlyDuringTrackingAndNestedTrackingKeepsThemVisible() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let main = NSMenu(title: "Main")
        let file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)
        let nested = NSMenu(title: "Nested")
        let nestedItem = NSMenuItem(title: "Nested", action: nil, keyEquivalent: "")
        nestedItem.submenu = nested
        file.addItem(nestedItem)
        let target = MenuActionTarget()
        let clear = NSMenuItem(title: L10n.text("Clear All Decisions…"),
                               action: #selector(MenuActionTarget.performMenuAction(_:)), keyEquivalent: "")
        clear.target = target
        file.autoenablesItems = false
        file.addItem(clear)
        app.mainMenu = main
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        let columns = MenuShortcutColumns(store: store)
        columns.refresh()
        XCTAssertEqual(clear.keyEquivalent, "")
        for char in ["r", "R"] {
            XCTAssertFalse(file.performKeyEquivalent(with: event(char, code: 15)))
            XCTAssertFalse(file.performKeyEquivalent(with: event(char, code: 15, modifiers: .command)))
        }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: file)
        XCTAssertEqual(clear.keyEquivalent, "R")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nested)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nested)
        XCTAssertEqual(clear.keyEquivalent, "R", "Closing a submenu must not clear a still-open parent")
        let late = NSMenuItem(title: L10n.text("Rescan Folder"), action: nil, keyEquivalent: "")
        file.addItem(late)
        XCTAssertEqual(late.keyEquivalent, "⌘R")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: file)
        XCTAssertEqual(clear.keyEquivalent, "")
        XCTAssertEqual(late.keyEquivalent, "")
        XCTAssertTrue(clear.allowsAutomaticKeyEquivalentLocalization)
        XCTAssertTrue(clear.allowsAutomaticKeyEquivalentMirroring)
        for char in ["r", "R"] {
            XCTAssertFalse(file.performKeyEquivalent(with: event(char, code: 15)))
            XCTAssertFalse(file.performKeyEquivalent(with: event(char, code: 15, modifiers: .command)))
        }
        XCTAssertEqual(target.count, 0)
        withExtendedLifetime(columns) {}
    }

    func testAppResignationMenuReplacementAndDeinitClearNativeHints() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let main = NSMenu(title: "Main")
        let item = NSMenuItem(title: L10n.text("Export…"), action: nil, keyEquivalent: "")
        main.addItem(item)
        app.mainMenu = main
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        var columns: MenuShortcutColumns? = MenuShortcutColumns(store: store)
        columns?.refresh()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        XCTAssertFalse(item.keyEquivalent.isEmpty)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        XCTAssertEqual(item.keyEquivalent, "")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        XCTAssertFalse(item.keyEquivalent.isEmpty)
        app.mainMenu = NSMenu(title: "Replacement")
        columns?.refresh()
        XCTAssertEqual(item.keyEquivalent, "")
        app.mainMenu = main
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
        XCTAssertFalse(item.keyEquivalent.isEmpty)
        columns = nil
        XCTAssertEqual(item.keyEquivalent, "")
    }

    private func event(_ character: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code
        )!
    }
}

@MainActor
private final class MenuActionTarget: NSObject {
    var count = 0
    @objc func performMenuAction(_ sender: NSMenuItem) { count += 1 }
}

// NSMenu's items override is nonisolated in the SDK. The fixture is used only
// by main-actor tests; keeping the subclass nonisolated avoids an invalid actor
// override while the background-delivery test verifies it is never touched there.
private final class ShortcutCountingMenu: NSMenu {
    var itemReads = 0
    override var items: [NSMenuItem] {
        get { itemReads += 1; return super.items }
        set { super.items = newValue }
    }
}
