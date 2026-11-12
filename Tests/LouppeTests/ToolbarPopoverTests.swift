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

    func testToolbarPopoversShareTheirScaffoldAndOwnedDropdownsStayModern() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = repository.appendingPathComponent("Sources/Louppe/Views")
        for file in ["SortView.swift", "FilterView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("CompactToolbarPopover("), "\(file) must use the toolbar scaffold")
            XCTAssertFalse(source.contains(".padding(14)"), "Popover margins belong to the scaffold")
            XCTAssertFalse(source.contains(".keyboardShortcut(.cancelAction)"), "Done belongs to the scaffold")
        }
        let deprecated = try NSRegularExpression(pattern:
            #"\.pickerStyle\s*\(\s*\.menu\s*\)|\.menuStyle\s*\(\s*\.(?:borderedButton|borderlessButton)\s*\)"#)
        for file in ["SortView.swift", "MediaTrackSelectionControls.swift", "ReviewShortcutsSettingsView.swift", "WelcomeView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(deprecated.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)),
                           0, "\(file) must not reintroduce legacy dropdown styles")
        }
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
