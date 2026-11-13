import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class DesignPresentationTests: XCTestCase {
    func testSheetActionsKeepLocalizedTitlesAtNarrowWidthsInBothDirections() async throws {
        for language in ["en", "pt", "ar"] {
            let titles = ["Keep Current Decisions", "Done", "Restore Selected Decisions"].map {
                L10n.render(.init(stringLiteral: $0), language: language)
            }
            for width in [320.0, 592.0, 900.0] {
                let host = NSHostingView(rootView: SheetActions {
                    Button(titles[0]) {}.background(Probe(id: 0))
                } trailing: {
                    SheetCancelButton(titles[1]) {}.background(Probe(id: 1))
                    SheetPrimaryButton(titles[2], runsOnReturn: false) {}.background(Probe(id: 2))
                }.frame(width: width).localizedInterface(language: language))
                let window = mount(host)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                let probes = OffscreenCapture.descendants(of: host).compactMap { $0 as? Probe.View }
                XCTAssertEqual(probes.count, 3)
                for probe in probes {
                    let natural = NSHostingView(rootView: Button(titles[probe.id]) {}.fixedSize()).fittingSize.width
                    let frame = probe.convert(probe.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(frame.width, natural - 1, "\(language): \(titles[probe.id]) must not truncate")
                    XCTAssertGreaterThanOrEqual(frame.minX, -1)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                }
            }
        }
    }

    func testExportConflictActionsFitTheirRealSheetContentWidth() async throws {
        let titles = ["Back", "Resolve RAW + JPEG Conflicts…", "Write Sidecars"].map {
            L10n.render(.init(stringLiteral: $0), language: "pt")
        }
        let host = NSHostingView(rootView: SheetActions {
            Button(titles[0]) {}.background(Probe(id: 0))
        } trailing: {
            Button(titles[1]) {}.background(Probe(id: 1))
            SheetPrimaryButton(titles[2], runsOnReturn: true) {}.background(Probe(id: 2))
        }.frame(width: 592)) // Export's 640-point sheet minus two 24-point margins.
        let window = mount(host)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let probes = OffscreenCapture.descendants(of: host).compactMap { $0 as? Probe.View }
        XCTAssertEqual(probes.count, 3)
        let frames = probes.map { $0.convert($0.bounds, to: host) }
        for (probe, frame) in zip(probes, frames) {
            let natural = NSHostingView(rootView: Button(titles[probe.id]) {}.fixedSize()).fittingSize.width
            XCTAssertGreaterThanOrEqual(frame.width, natural - 1)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
            XCTAssertLessThanOrEqual(frame.maxX, 593)
        }
        for first in frames.indices {
            for second in frames.indices where second > first {
                XCTAssertFalse(frames[first].intersects(frames[second]))
            }
        }
    }

    func testBannerKeepsLongRemediesInsideItsBounds() async throws {
        for language in ["en", "pt", "ar"] {
            let titles = ["Keep Files As They Are", "Retry Recovery"].map {
                L10n.render(.init(stringLiteral: $0), language: language)
            }
            let host = NSHostingView(rootView: StatusBanner(systemImage: "exclamationmark.triangle.fill") {
                Text("Some interrupted files are still untouched. Review can continue while you choose how to recover.")
            } actions: {
                Button(titles[0]) {}.background(Probe(id: 0))
                Button(titles[1]) {}.background(Probe(id: 1))
            }.frame(width: 400).localizedInterface(language: language))
            let window = mount(host)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let probes = OffscreenCapture.descendants(of: host).compactMap { $0 as? Probe.View }
            XCTAssertEqual(probes.count, 2)
            for probe in probes {
                let natural = NSHostingView(rootView: Button(titles[probe.id]) {}.fixedSize()).fittingSize.width
                let frame = probe.convert(probe.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.width, natural - 1, "\(language): the remedy must not truncate")
                XCTAssertGreaterThanOrEqual(frame.minX, 13)
                XCTAssertLessThanOrEqual(frame.maxX, 387)
            }
        }
    }

    func testSelectionOutlinesReservePurpleForActiveWindows() throws {
        for scheme in [ColorScheme.light, .dark] {
            for increasedContrast in [false, true] {
                for current in [false, true] {
                    for active in [false, true] {
                        let pixels = try outline(active: active, current: current, scheme: scheme, increasedContrast: increasedContrast)
                        let color = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: 1)?.usingColorSpace(.deviceRGB))
                        XCTAssertGreaterThan(color.redComponent, 0.1, "The selected outline must remain visible")
                        if active {
                            XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.05, "Active selection keeps Louppe purple")
                        } else {
                            XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.02, "Inactive selection uses neutral ink")
                            XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.02)
                        }
                    }
                }
            }
        }
    }

    func testPopoverTitleIsAnAccessibilityHeading() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("AXHeading is exposed on macOS 26 and later") }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: CompactToolbarPopover(title: "Review options", done: {}) {
            Text("Options")
        }.environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 340, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let title = try XCTUnwrap(accessibilityElements(host).first {
            string($0, "accessibilityLabel") == "Review options"
        })
        XCTAssertEqual(string(title, "accessibilityRole"), "AXHeading")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
    }

    func testInactiveSelectionRemainsVisibleOverWhiteMedia() throws {
        for scheme in [ColorScheme.light, .dark] {
            let pixels = try outline(active: false, current: false, scheme: scheme, background: .white)
            let color = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: 1)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(color.redComponent, 0.95)
        }
    }

    func testButtonOnlyFooterStaysTrailingInBothDirections() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = NSHostingView(rootView: SheetActions {
                SheetPrimaryButton("Done", runsOnReturn: true) {}.background(Probe(id: 0))
            }.frame(width: 900).environment(\.layoutDirection, direction))
            let window = mount(host)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let probe = try XCTUnwrap(OffscreenCapture.descendants(of: host).compactMap { $0 as? Probe.View }.first)
            let frame = probe.convert(probe.bounds, to: host)
            XCTAssertEqual(direction == .leftToRight ? frame.maxX : frame.minX,
                           direction == .leftToRight ? 900 : 0, accuracy: 1)
        }
    }

    func testResizingKeepsMountedActionsAndTheirKeyboardGates() async throws {
        var appearances = 0
        var confirmed = 0
        var cancelled = 0
        func footer(width: CGFloat, enabled: Bool) -> some SwiftUI.View {
            SheetActions {
                Button("Keep Current Decisions") {}.onAppear { appearances += 1 }
            } trailing: {
                SheetCancelButton { cancelled += 1 }
                SheetPrimaryButton("Restore Selected Decisions", runsOnReturn: true) { confirmed += 1 }
                    .disabled(!enabled)
            }.frame(width: width)
        }
        let host = NSHostingView(rootView: footer(width: 900, enabled: true))
        let window = mount(host)
        defer { window.close() }
        for (width, enabled) in [(900.0, true), (320.0, false), (900.0, true)] {
            host.rootView = footer(width: width, enabled: enabled)
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let previous = confirmed
            _ = host.performKeyEquivalent(with: try key("\r", code: 36, window: window))
            XCTAssertEqual(confirmed, previous + (enabled ? 1 : 0))
            XCTAssertTrue(host.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: window)))
        }
        XCTAssertEqual(cancelled, 3)
        XCTAssertEqual(appearances, 1, "Resize must not replace the action subtree")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
    }

    private func outline(active: Bool, current: Bool, scheme: ColorScheme = .light,
                         increasedContrast: Bool = false, background: Color = .black) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: background
            .reviewTileSelectionOutline(isCurrent: current, isSelected: true)
            .environment(\.appearsActive, active)
            .environment(\.colorScheme, scheme)
            .frame(width: 60, height: 60))
        let appearance: NSAppearance.Name = increasedContrast
            ? (scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
            : (scheme == .light ? .aqua : .darkAqua)
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = CGSize(width: 60, height: 60)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func mount<V: SwiftUI.View>(_ host: NSHostingView<V>) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func key(_ text: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private struct Probe: NSViewRepresentable {
        let id: Int
        final class View: NSView { var id = 0 }
        func makeNSView(context: Context) -> View { let view = View(); view.id = id; return view }
        func updateNSView(_ view: View, context: Context) {}
    }

    private func accessibilityElements(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector),
               let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                children.forEach(walk)
            }
        }
        walk(root)
        return result
    }
}
