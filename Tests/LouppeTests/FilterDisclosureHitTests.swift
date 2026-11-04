import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class FilterDisclosureHitTests: XCTestCase {
    func testCollapsedHeaderClicksReachTheFullPaddedRowInBothDirections() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let state = DisclosureHitState()
            let root = VStack(spacing: 0) {
                Divider()
                FilterDisclosureSection(title: "Quality cues", isExpanded: Binding(
                    get: { state.expanded }, set: { state.expanded = $0 })) {
                    Text("Expanded controls")
                }
                Divider()
            }.frame(width: 300).environment(\.layoutDirection, direction)
            let host = NSHostingView(rootView: root)
            let window = mount(host)
            defer { window.close() }
            XCTAssertGreaterThanOrEqual(host.bounds.height, 40,
                "The visible row includes 12 points of padding above and below its label")
            for corner in [(2.0, 2.0), (298.0, 2.0), (2.0, host.bounds.height - 2), (298.0, host.bounds.height - 2)] {
                state.expanded = false
                settle(host)
                try click(host, window: window, x: corner.0, fromTop: corner.1)
                XCTAssertTrue(state.expanded, "Padding must activate the header: \(direction), \(corner)")
            }
        }
    }

    func testDividerAdjacentClicksOnlyToggleTheirOwnSection() throws {
        let state = DisclosureHitState()
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Divider()
            FilterDisclosureSection(title: "Quality cues", isExpanded: Binding(
                get: { state.expanded }, set: { state.expanded = $0 })) { Text("Cue controls") }
            Divider()
            FilterDisclosureSection(title: "Capture bursts", isExpanded: Binding(
                get: { state.secondExpanded }, set: { state.secondExpanded = $0 })) { Text("Burst controls") }
            Divider()
        }.frame(width: 300))
        let window = mount(host)
        defer { window.close() }
        let split = host.bounds.height / 2
        try click(host, window: window, x: 290, fromTop: split - 2)
        XCTAssertTrue(state.expanded)
        XCTAssertFalse(state.secondExpanded)
        state.expanded = false
        settle(host)
        try click(host, window: window, x: 290, fromTop: split + 2)
        XCTAssertFalse(state.expanded)
        XCTAssertTrue(state.secondExpanded)
    }

    func testExpandedControlsRemainSeparateFromHeaderHitArea() throws {
        let state = DisclosureHitState()
        state.expanded = true
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Divider()
            FilterDisclosureSection(title: "Quality cues", isExpanded: Binding(
                get: { state.expanded }, set: { state.expanded = $0 })) {
                Button { state.childPresses += 1 } label: {
                    Text("Cue control").frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
        }.frame(width: 300))
        let window = mount(host)
        defer { window.close() }
        // Content ends 12 points above the bottom divider; click its center.
        try click(host, window: window, x: 150, fromTop: host.bounds.height - 25)
        XCTAssertEqual(state.childPresses, 1)
        XCTAssertTrue(state.expanded, "A child control cannot collapse its section")
        try click(host, window: window, x: 290, fromTop: 2)
        XCTAssertFalse(state.expanded)
        XCTAssertLessThan(host.fittingSize.height, 60, "Collapsing removes the expanded controls from layout")
    }

    func testRealFilterExpandsQualityFromTopPaddingWithoutChangingPredicates() throws {
        let store = SessionStore()
        let expected = store.filter
        let host = NSHostingView(rootView: FilterView(store: store).preferredColorScheme(.dark))
        let window = mount(host)
        defer { window.close() }
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let collapsedHeight = document.bounds.height
        try snapshot(host, name: "filter-collapsed")
        let point = scroll.convert(NSPoint(x: scroll.bounds.width - 10, y: scroll.isFlipped ? 2 : scroll.bounds.height - 2), to: host)
        try click(host, window: window, x: point.x,
                  fromTop: host.isFlipped ? point.y : host.bounds.height - point.y)
        XCTAssertGreaterThan(document.bounds.height, collapsedHeight + 40,
                             "Clicking the top padding opens the first disclosure in the real scroll view")
        XCTAssertEqual(store.filter, expected, "Expanding a section cannot alter filter predicates")
        try snapshot(host, name: "filter-quality-expanded")
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

    private func mount<V: View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host)
        return window
    }

    private func click(_ host: NSView, window: NSWindow, x: Double, fromTop: Double) throws {
        let y = host.isFlipped ? fromTop : host.bounds.height - fromTop
        let point = host.convert(NSPoint(x: x, y: y), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: time + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Native buttons may track synchronously; make mouse-up available to
        // that loop. SwiftUI buttons that do not track consume it below.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                        inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
        settle(host)
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
    }
}

@MainActor
@Observable
private final class DisclosureHitState {
    var expanded = false
    var secondExpanded = false
    var childPresses = 0
}
