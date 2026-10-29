import AppKit
import SwiftUI
import XCTest
#if !APP_STORE
import Sparkle
#endif
@testable import Louppe

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testPackagedNativeAccentMatchesTheSettingsTint() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent(
            "AppIcon/Appearance.xcassets/LouppeAccent.colorset/Contents.json"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(catalog["colors"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 4)
        for entry in colors {
            let appearances = entry["appearances"] as? [[String: String]] ?? []
            let dark = appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" }
            let highContrast = appearances.contains { $0["appearance"] == "contrast" && $0["value"] == "high" }
            let appearance: NSAppearance.Name = highContrast
                ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : (dark ? .darkAqua : .aqua)
            let color = try XCTUnwrap(entry["color"] as? [String: Any])
            let components = try XCTUnwrap(color["components"] as? [String: String])
            let tint = try XCTUnwrap(NSColor.louppeAccentColor(for: appearance).usingColorSpace(.sRGB))
            for (name, actual) in [("red", tint.redComponent), ("green", tint.greenComponent), ("blue", tint.blueComponent)] {
                let hex = try XCTUnwrap(components[name]?.dropFirst(2))
                let byte = try XCTUnwrap(UInt8(hex, radix: 16))
                XCTAssertEqual(CGFloat(byte) / 255, actual, accuracy: 0.0001, "\(appearance.rawValue): \(name)")
            }
        }
    }

    func testRecordingAReviewShortcutPersistsAndRefreshesTheKeyboardInPlace() throws {
        let suite = "SettingsLayoutTests.Keyboard.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ReviewShortcutPreferences().encoded, forKey: ReviewShortcutPreferences.preferenceKey)
        let host = NSHostingView(rootView: LouppeSettingsForm {
            ReviewShortcutsSettingsView()
        }.defaultAppStorage(defaults).preferredColorScheme(.dark))
        let window = mountedWindow(host, width: 620, height: 600)
        defer { window.close() }
        settle(host)
        let search = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSearchField.SearchField }.first)
        search.stringValue = ReviewShortcutAction.oneStar.title
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        settle(host)
        try snapshot(host, name: "keyboard-before-remap")

        let recorder = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewShortcutRecorderButton }
            .first { $0.actionTitle == ReviewShortcutAction.oneStar.title })
        recorder.startRecording()
        recorder.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "t",
            charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)))
        settle(host)
        let saved = ReviewShortcutPreferences.decode(defaults.string(forKey: ReviewShortcutPreferences.preferenceKey) ?? "")
        XCTAssertEqual(saved.binding(for: .oneStar).keyCode, 17)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.shortcutTitle, saved.display(for: saved.binding(for: .oneStar)))
        try snapshot(host, name: "keyboard-after-remap")
    }

    func testSettingsUsesTwoNativePagesAndKeepsShortcutsOnTheirOwnPage() throws {
        let store = SessionStore()
        #if APP_STORE
        let settings = LouppeSettingsView(store: store)
        #else
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let settings = LouppeSettingsView(store: store, updater: controller.updater)
        #endif
        let host = NSHostingController(rootView: settings.preferredColorScheme(.dark))
        let window = NSWindow(contentViewController: host)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        window.makeKey()
        defer { window.close() }
        settle(host.view)

        let tabs = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTabView }.first)
        try snapshot(try XCTUnwrap(window.contentView?.superview), name: "pages-general")
        XCTAssertEqual(tabs.tabViewItems.map(\.label), [L10n.text("General"), L10n.text("Keyboard shortcuts")])
        XCTAssertFalse(descendants(host.view).contains { $0 is NativeSearchField.SearchField },
                       "General must not include the shortcut editor")
        XCTAssertEqual(descendants(host.view).filter { $0 is NSScrollView }.count, 1)

        tabs.selectTabViewItem(at: 1)
        settle(host.view)
        let search = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NativeSearchField.SearchField }.first)
        XCTAssertNil(search.currentEditor(), "Opening the shortcuts page must not activate search")
        XCTAssertFalse(descendants(host.view).contains { $0 is ReviewShortcutRecorderButton },
                       "Shortcut subsections must start collapsed")
        XCTAssertEqual(descendants(host.view).filter { $0 is NSScrollView }.count, 1,
                       "Each page must own its scrolling form")
        try snapshot(try XCTUnwrap(window.contentView?.superview), name: "pages-shortcuts")

        search.setAccessibilityFocused(true)
        XCTAssertNotNil(search.currentEditor(), "Explicit accessibility focus must still edit search")
        tabs.selectTabViewItem(at: 0)
        settle(host.view)
        XCTAssertFalse(descendants(host.view).contains { $0 is NativeSearchField.SearchField })

        tabs.selectTabViewItem(at: 1)
        settle(host.view)
        let returnedSearch = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NativeSearchField.SearchField }.first)
        XCTAssertNil(returnedSearch.currentEditor(), "Returning to shortcuts must not restore text-editing focus")
    }

    func testGeneralSettingsShareOneScrollableForm() throws {
        let store = SessionStore()
        #if APP_STORE
        let settings = LouppeSettingsView(store: store)
        #else
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let settings = LouppeSettingsView(store: store, updater: controller.updater)
        #endif
        let host = NSHostingView(rootView: settings.preferredColorScheme(.dark))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 620, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        defer { window.close() }
        settle(host)

        let scrollViews = descendants(host).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(scrollViews.count, 1, "Settings must not nest independent scrolling panels")
        let scroll = try XCTUnwrap(scrollViews.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        XCTAssertEqual(host.bounds.width, 620, accuracy: 1)
        XCTAssertEqual(host.bounds.height, 600, accuracy: 1)
        try snapshot(host, name: "top")

        document.scroll(NSPoint(x: 0, y: 520))
        settle(host)
        try snapshot(host, name: "middle")

        document.scroll(NSPoint(x: 0, y: document.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The lower settings must be reachable")
        try snapshot(host, name: "bottom")
    }

    func testGetStartedButtonOpensHelpAndTipsTogglePersists() throws {
        let suite = "SettingsLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "louppe.showQuickStart")
        var openedWindows: [String] = []
        let content = LouppeSettingsForm {
            LouppeGetStartedSettingsView { openedWindows.append($0) }
        }
        .defaultAppStorage(defaults)
        .environment(\.layoutDirection, .leftToRight)
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let window = mountedWindow(host, width: 520, height: 240)
        defer { window.close() }
        settle(host)
        try snapshot(host, name: "get-started")

        // Prefer actual AppKit control geometry. SwiftUI can render controls
        // without publishing native control children or an in-process AX tree;
        // fallback centers were verified in the 520 × 240 mounted snapshot
        // (1040 × 480 bitmap at 2×), with regular controls and left-to-right layout.
        let nativeHelp = descendants(host).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.text("Get started") }
        let helpPoint = nativeHelp.map { controlCenter($0, in: host) } ?? (x: 80, fromTop: 80)
        try click(host, window: window, x: helpPoint.x, fromTop: helpPoint.fromTop)
        XCTAssertEqual(openedWindows, [LouppeHelpWindow.id],
                       "clicking the rendered button must invoke the production section's Help route once")

        let nativeTips = descendants(host).compactMap { $0 as? NSSwitch }.first
        let tipsPoint = nativeTips.map { controlCenter($0, in: host) }
            ?? (x: Double(host.bounds.width) - 73, fromTop: 117.5)
        try click(host, window: window, x: tipsPoint.x, fromTop: tipsPoint.fromTop)
        XCTAssertTrue(defaults.bool(forKey: "louppe.showQuickStart"),
                      "clicking the rendered toggle must persist the existing review/footer preference")
        try snapshot(host, name: "get-started-tips-enabled")
        try click(host, window: window, x: tipsPoint.x, fromTop: tipsPoint.fromTop)
        XCTAssertFalse(defaults.bool(forKey: "louppe.showQuickStart"),
                       "a second native click must persist the disabled preference")
        XCTAssertEqual(openedWindows, [LouppeHelpWindow.id],
                       "changing the preference must not activate the neighboring Help button")
    }

    func testGetStartedAccessibilityHasOneHelpRouteAndNoInlineGuide() throws {
        let suite = "SettingsLayoutTests.Accessibility.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: LouppeSettingsForm {
            LouppeGetStartedSettingsView { _ in }
        }.defaultAppStorage(defaults).preferredColorScheme(.dark))
        let window = mountedWindow(host, width: 520, height: 240)
        defer { window.close() }
        settle(host)
        try snapshot(host, name: "get-started-structure")
        guard !(host.accessibilityChildren() ?? []).isEmpty else {
            throw XCTSkip("SwiftUI's XCTest host has no in-process accessibility children; native route/preference interaction is tested separately.")
        }
        let elements = accessibilityElements(in: host)
        XCTAssertEqual(elements.filter { $0.accessibilityIdentifier() == "louppe.settings.getStarted" }.count, 1)
        XCTAssertEqual(elements.filter { $0.accessibilityIdentifier() == "louppe.settings.quickStartTips" }.count, 1)
        XCTAssertEqual(elements.filter { $0.accessibilityRole() == .button }.count, 1,
                       "the section must have one Help route, without a second shortcuts button")
        XCTAssertFalse(elements.contains { $0.accessibilityRole() == .disclosureTriangle },
                       "Settings must not expand an inline guide")
        XCTAssertFalse(elements.contains { $0.accessibilityIdentifier() == "louppe.quickStartGuide" })
    }

    func testHelpKeepsTheGuideWithoutDuplicatingItsReviewPreference() throws {
        let suite = "SettingsLayoutTests.Help.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "louppe.showQuickStart")
        let host = NSHostingView(rootView: LouppeHelpView()
            .defaultAppStorage(defaults)
            .preferredColorScheme(.dark))
        let window = mountedWindow(host, width: 640, height: 600)
        defer { window.close() }
        settle(host)
        try snapshot(host, name: "help-get-started")

        guard !(host.accessibilityChildren() ?? []).isEmpty else {
            throw XCTSkip("SwiftUI's XCTest host has no in-process accessibility children; the mounted Help snapshot still records the guide.")
        }
        let elements = accessibilityElements(in: host)
        XCTAssertTrue(elements.contains { $0.accessibilityIdentifier() == "louppe.quickStartGuide" })
        XCTAssertFalse(elements.contains { $0.accessibilityRole() == .checkBox },
                       "Help contains reference material; the tips preference belongs in Settings")
        XCTAssertFalse(defaults.bool(forKey: "louppe.showQuickStart"))
    }

    private func mountedWindow(_ host: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // App-local key status supports native routing without activating the app.
        window.orderBack(nil)
        window.makeKey()
        return window
    }

    private func controlCenter(_ control: NSView, in host: NSView) -> (x: Double, fromTop: Double) {
        let rect = host.convert(control.bounds, from: control)
        return (Double(rect.midX), Double(host.isFlipped ? rect.midY : host.bounds.height - rect.midY))
    }

    private func click(_ host: NSView, window: NSWindow, x: Double, fromTop: Double) throws {
        let y = host.isFlipped ? fromTop : Double(host.bounds.height) - fromTop
        let point = host.convert(NSPoint(x: x, y: y), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: time + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Queue the release before sending down: native controls may enter a
        // synchronous tracking loop. Nontracking SwiftUI controls consume it below.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                        inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
        settle(host)
    }

    private func accessibilityElements(in root: NSView) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ value: Any) {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let accessible = object as? any NSAccessibilityProtocol {
                result.append(accessible)
                for child in accessible.accessibilityChildren() ?? [] { walk(child) }
            } else if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                      let children = object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] {
                for child in children { walk(child) }
            }
            if let view = object as? NSView { for child in view.subviews { walk(child) } }
        }
        walk(root)
        return result
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_SETTINGS_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
