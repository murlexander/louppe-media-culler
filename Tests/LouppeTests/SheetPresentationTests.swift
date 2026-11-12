import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Shared sheet contracts, exercised in mounted inactive windows with local
/// events only. These tests never activate the app or use the owner's files.
@MainActor
final class SheetPresentationTests: XCTestCase {
    func testReturnAndEscapeKeepTheirActionsAndDisabledGate() throws {
        for enabled in [false, true] {
            var cancelled = 0
            var confirmed = 0
            let host = NSHostingView(rootView: SheetForm(title: "Confirmation") {
                Text("Preview")
            } actions: {
                SheetActions {
                    SheetCancelButton(role: .cancel) { cancelled += 1 }
                    SheetPrimaryButton("Confirm", isDefault: true) { confirmed += 1 }
                        .disabled(!enabled)
                }
            }.frame(width: 540, height: 300))
            let window = mount(host, size: CGSize(width: 540, height: 300))
            defer { window.close() }
            _ = host.performKeyEquivalent(with: try key("\r", code: 36, window: window))
            XCTAssertEqual(confirmed, enabled ? 1 : 0)
            XCTAssertEqual(cancelled, 0)
            XCTAssertTrue(host.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: window)))
            XCTAssertEqual(cancelled, 1)
        }
    }

    func testRecoveryStyleConfirmationNeverRunsOnReturn() throws {
        var done = 0
        var restored = 0
        let host = NSHostingView(rootView: SheetActions {
            SheetCancelButton("Done") { done += 1 }
            SheetPrimaryButton("Restore", isDefault: false) { restored += 1 }
        }.padding(24).frame(width: 540, height: 100))
        let window = mount(host, size: CGSize(width: 540, height: 100))
        defer { window.close() }
        _ = host.performKeyEquivalent(with: try key("\r", code: 36, window: window))
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(done, 0)
        XCTAssertTrue(host.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: window)))
        XCTAssertEqual(done, 1)
    }

    func testSheetFooterStaysOutsideScrollingBodyInBothDirections() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = NSHostingView(rootView: SheetForm(title: "Long preview") {
                ForEach(0..<100) { Text("Exact planned path \($0)") }
            } actions: {
                SheetActions {
                    Text("Fixed actions").background(GeometryProbe())
                    SheetPrimaryButton("Done", isDefault: true) {}
                }
            }.frame(width: 540, height: 300).environment(\.layoutDirection, direction))
            let window = mount(host, size: CGSize(width: 540, height: 300))
            defer { window.close() }
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            let probe = try XCTUnwrap(descendants(host).compactMap { $0 as? GeometryProbe.Probe }.first)
            XCTAssertFalse(descendants(scroll).contains { $0 === probe })
            let before = probe.convert(probe.bounds, to: host)
            let document = try XCTUnwrap(scroll.documentView)
            document.scroll(NSPoint(x: 0, y: document.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            XCTAssertEqual(probe.convert(probe.bounds, to: host), before)
        }
    }

    func testBannerWrapsLongWarningsWithoutLosingTheRemedyInEitherDirection() {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            func banner(width: CGFloat) -> NSHostingView<some View> {
                NSHostingView(rootView: StatusBanner(
                    systemImage: "exclamationmark.triangle.fill", emphasis: .warning,
                    accessibilityAnnouncement: "Session save warning"
                ) {
                    Text(String(repeating: "The session could not be saved safely. ", count: 8))
                } actions: {
                    Button("Retry Saving") {}.background(GeometryProbe())
                }.frame(width: width).environment(\.layoutDirection, direction))
            }
            let narrow = banner(width: 540)
            let wide = banner(width: 1080)
            let window = mount(narrow, size: CGSize(width: 540, height: narrow.fittingSize.height))
            defer { window.close() }
            XCTAssertGreaterThan(narrow.fittingSize.height, wide.fittingSize.height)
            let probe = descendants(narrow).compactMap { $0 as? GeometryProbe.Probe }.first
            XCTAssertNotNil(probe)
            if let probe {
                let frame = probe.convert(probe.bounds, to: narrow)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, 14)
                XCTAssertLessThanOrEqual(frame.maxX, narrow.bounds.width - 14)
            }
        }
    }

    func testSharedPresentationsKeepOwnedCallSitesAndSafetyGates() throws {
        for name in ["ExportView", "RenameFilesView", "OrganizeSourceView", "PhotosLibraryView",
                     "PhotosOrganizationView", "SessionRecoveryView", "XMPConflictResolverView", "EarlyUserFeedbackView"] {
            XCTAssertTrue(try source(name).contains("SheetActions {"), name)
        }
        let recovery = try source("SessionRecoveryView")
        XCTAssertTrue(recovery.contains("SheetPrimaryButton(L10n.text(\"Restore Selected Decisions\"), isDefault: false)"))
        XCTAssertTrue(recovery.contains("!hasRestorableSelection || !confirmsSamePhotos || store.isFileOperationRunning"))
        for name in ["RenameFilesView", "OrganizeSourceView"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("SourceFileOperationProgressView("))
            XCTAssertTrue(text.contains("else if let outcome = store.organizationOutcome"))
            XCTAssertTrue(text.contains("SourceFileOperationOutcomeView("))
            XCTAssertTrue(text.contains(".interactiveDismissDisabled(store.isFileOperationRunning)"))
        }
        let outcome = try source("Design/SourceFileOperationOutcomeView")
        XCTAssertTrue(outcome.contains("outcome.succeeded, !outcome.wasUndo, store.canUndo"))
        XCTAssertTrue(outcome.contains("store.organizationError ?? outcome.message"))
        XCTAssertEqual(outcome.components(separatedBy: ".disabled(store.isFileOperationRunning)").count - 1, 2)
        let banner = try source("Design/StatusBanner")
        XCTAssertTrue(banner.contains(".padding(.horizontal, 14)"))
        XCTAssertTrue(banner.contains(".padding(.vertical, 8)"))
        XCTAssertTrue(banner.contains(".background(Color.appBackground)"))
        XCTAssertTrue(banner.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(banner.contains(".accessibilityFocused($isMessageFocused)"))
        let surface = try source("FloatingControlSurface")
        XCTAssertTrue(surface.contains("if reduceTransparency"))
        XCTAssertTrue(surface.contains("role == .controls, #available(macOS 26.0, *)"))
        XCTAssertTrue(surface.contains("contrast == .increased"))
        let root = try source("RootView")
        XCTAssertEqual(root.components(separatedBy: "role: .panel").count - 1, 2)
        XCTAssertFalse(root.contains(".background(.regularMaterial"))
        XCTAssertTrue(try source("SessionView").contains("StatusBanner(systemImage: groupedReviewSymbol)"))
    }

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Louppe/Views/\(name).swift"), encoding: .utf8)
    }

    private func key(_ text: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private func mount<V: View>(_ host: NSHostingView<V>, size: CGSize) -> NSWindow {
        _ = NSApplication.shared
        let window = TestWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        settle(host)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        return window
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Hosting a native control can resize and rescue a window onto a display.
    /// Keep every frame change offscreen, while allowing local key equivalents.
    private final class TestWindow: NSWindow {
        override var canBecomeMain: Bool { false }

        private func offscreen(_ frame: NSRect) -> NSRect {
            var frame = frame
            frame.origin.x = min(-20_000, (NSScreen.screens.map(\.frame.minX).min() ?? 0) - frame.width - 1_000)
            frame.origin.y = min(-20_000, (NSScreen.screens.map(\.frame.minY).min() ?? 0) - frame.height - 1_000)
            return frame
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(offscreen(frameRect), display: flag)
        }

        override func setFrameOrigin(_ point: NSPoint) {
            super.setFrameOrigin(offscreen(frame).origin)
        }

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            offscreen(frameRect)
        }
    }

    private struct GeometryProbe: NSViewRepresentable {
        final class Probe: NSView {}
        func makeNSView(context: Context) -> Probe { Probe() }
        func updateNSView(_ view: Probe, context: Context) {}
    }
}
