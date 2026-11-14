import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ToolbarPopoverTests: XCTestCase {
    func testPopoversKeepTheirSizingAndScrollingInBothDirectionsWithoutEditingState() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let suite = "ToolbarPopoverTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SessionStore(reviewDefaults: defaults)
            store.filter.searchText = "keep this query"
            store.sort.key = .name
            store.sort.ascending = false
            let filter = store.filter
            let sort = store.sort

            let filterHost = NSHostingView(rootView: FilterView(store: store)
                .environment(\.layoutDirection, direction))
            let filterWindow = mount(filterHost)
            defer { filterWindow.close() }
            XCTAssertEqual(filterHost.fittingSize.width, 340, accuracy: 0.1)
            XCTAssertEqual(filterHost.fittingSize.height, 560, accuracy: 0.1)
            XCTAssertEqual(descendants(filterHost).filter { $0 is NSScrollView }.count, 1)

            let sortHost = NSHostingView(rootView: SortView(store: store)
                .environment(\.layoutDirection, direction))
            let sortWindow = mount(sortHost)
            defer { sortWindow.close() }
            XCTAssertEqual(sortHost.fittingSize.width, 340, accuracy: 0.1)
            XCTAssertLessThan(sortHost.fittingSize.height, 560, "Sort must fit its compact content")
            XCTAssertFalse(descendants(sortHost).contains { $0 is NSScrollView })
            XCTAssertEqual(store.filter, filter)
            XCTAssertEqual(store.sort, sort)
        }
    }

    func testValueMenuKeepsItsTargetAndAccessibleValueInBothDirections() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = NSHostingView(rootView: ValueMenu("Order", value: "Newest", selection: .constant(true)) {
                Text("Newest").tag(true)
                Text("Oldest").tag(false).disabled(true)
            }
            .accessibilityIdentifier("louppe.testOrder")
            .frame(width: 180)
            .environment(\.layoutDirection, direction)
            .environment(\.accessibilityEnabled, true))
            let window = mount(host)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(host.fittingSize.height, 22)
            let elements = accessibilityElements(in: host)
            let menu = try XCTUnwrap(elements.first { accessibilityString($0, "accessibilityIdentifier") == "louppe.testOrder" },
                "\(elements.map { [String(describing: type(of: $0)), accessibilityString($0, "accessibilityIdentifier") ?? "-", accessibilityString($0, "accessibilityLabel") ?? "-", accessibilityString($0, "accessibilityValue") ?? "-"] })")
            XCTAssertEqual(accessibilityString(menu, "accessibilityLabel"), "Order")
            XCTAssertEqual(accessibilityString(menu, "accessibilityValue"), "Newest")
            let frame = try XCTUnwrap(menu.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertGreaterThanOrEqual(frame.height, 22, "The accessible target must include the label's full minimum height")
        }
    }

    func testSortMenusListTitledChoicesUnderThePopoverCheckboxStyle() throws {
        let suite = "ToolbarPopoverTests.Menus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        // RootView's app-wide toggle style, as the real popover inherits it.
        let host = NSHostingView(rootView: SortView(store: store).toggleStyle(LouppeToggleStyle()))
        let window = mount(host)
        defer { window.close() }
        let buttons = descendants(host).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(buttons.count, 2, "Sort by and Order")
        var titles: [[String]] = []
        for button in buttons {
            let menu = try XCTUnwrap(button.menu)
            // SwiftUI fills the menu just before it opens; ask its coordinator
            // directly so no menu appears on screen.
            let coordinator = try XCTUnwrap(menu.delegate as? NSObject)
            let willShow = NSSelectorFromString("popUpButtonCell:willShowMenu:")
            XCTAssertTrue(coordinator.responds(to: willShow), "SwiftUI changed how it fills menus; update this probe")
            coordinator.perform(willShow, with: button.cell, with: menu)
            let choices = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertFalse(choices.isEmpty)
            for item in choices {
                XCTAssertFalse(item.title.isEmpty, "A choice lost its title")
                XCTAssertNil(item.image, "\(item.title) must not show a checkbox image")
            }
            titles.append(choices.map(\.title))
        }
        XCTAssertTrue(titles.contains { $0.contains(L10n.text("Date taken")) })
        XCTAssertTrue(titles.contains { $0.contains(store.sort.key.ascendingLabel) })
    }

    func testEscapeDismissesEachPopoverWithoutResettingItsState() throws {
        let suite = "ToolbarPopoverTests.Escape.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        store.filter.searchText = "keep this query"
        store.sort.key = .name
        let filter = store.filter
        let sort = store.sort
        for isFilter in [false, true] {
            store.isFilterPresented = isFilter
            store.isSortPresented = !isFilter
            let host = NSHostingView(rootView: isFilter
                ? AnyView(FilterView(store: store)) : AnyView(SortView(store: store)))
            let window = mount(host)
            defer { window.close() }
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertTrue(host.performKeyEquivalent(with: escape))
            settle(host)
            XCTAssertFalse(store.isFilterPresented)
            XCTAssertFalse(store.isSortPresented)
            XCTAssertEqual(store.filter, filter)
            XCTAssertEqual(store.sort, sort)
        }
    }

    func testPopoversHaveNoDoneButtonAndResetSitsBesideTheTitle() async throws {
        let suite = "ToolbarPopoverTests.Reset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        for (isFilter, title) in [(true, L10n.text("Filter")), (false, L10n.text("Sort"))] {
            let host = NSHostingView(rootView: (isFilter
                ? AnyView(FilterView(store: store)) : AnyView(SortView(store: store)))
                .environment(\.accessibilityEnabled, true))
            let window = mount(host)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let elements = accessibilityElements(in: host)
            let labels = elements.compactMap { accessibilityString($0, "accessibilityLabel") }
            XCTAssertFalse(labels.contains(L10n.text("Done")), "\(title) applies choices at once; no Done button")
            let reset = try XCTUnwrap(elements.first { accessibilityString($0, "accessibilityLabel") == L10n.text("Reset") })
            let heading = try XCTUnwrap(elements.first { accessibilityString($0, "accessibilityLabel") == title })
            let resetFrame = try XCTUnwrap(reset.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let headingFrame = try XCTUnwrap(heading.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertLessThan(abs(resetFrame.midY - headingFrame.midY), 6, "Reset shares the title's row")
            XCTAssertGreaterThan(resetFrame.minX, headingFrame.maxX)
        }
    }

    func testSortResetRestoresTheSettingsOrderAndGrouping() throws {
        let suite = "ToolbarPopoverTests.SortReset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        XCTAssertFalse(store.isSortActive)
        store.sort.key = .name
        store.sort.ascending = false
        store.isGroupingEnabled.toggle()
        XCTAssertTrue(store.isSortActive)
        store.resetSort()
        XCTAssertEqual(store.sort, ReviewPreferences.load(from: defaults).defaultSort)
        XCTAssertFalse(store.isSortActive)
    }

    func testToolbarPopoversShareTheirScaffoldAndOwnedDropdownsStayModern() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = repository.appendingPathComponent("Sources/Louppe/Views")
        for file in ["SortView.swift", "FilterView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains(".padding(14)"), "Popover margins belong to the scaffold")
            XCTAssertFalse(source.contains(".keyboardShortcut(.cancelAction)"), "Esc belongs to the scaffold")
        }
        let deprecated = try NSRegularExpression(pattern:
            #"\.pickerStyle\s*\(\s*\.menu\s*\)|\.menuStyle\s*\(\s*\.(?:borderedButton|borderlessButton)\s*\)"#)
        for file in ["SortView.swift", "MediaTrackSelectionControls.swift", "ReviewShortcutsSettingsView.swift", "WelcomeView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(deprecated.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)),
                           0, "\(file) must not reintroduce legacy dropdown styles")
        }
    }

    private func accessibilityString(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func accessibilityElements(in root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector),
               let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                children.forEach(walk)
            }
            if let view = object as? NSView {
                for child in NSAccessibility.unignoredChildren(from: [view]) {
                    if let child = child as? NSObject { walk(child) }
                }
                view.subviews.forEach(walk)
            }
        }
        for child in NSAccessibility.unignoredChildren(from: [root]) {
            if let child = child as? NSObject { walk(child) }
        }
        walk(root)
        return result
    }

    private func mount<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        settle(host)
        return window
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
