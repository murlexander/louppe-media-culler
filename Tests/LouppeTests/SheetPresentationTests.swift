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
                    SheetCancelButton { cancelled += 1 }
                    SheetPrimaryButton("Confirm", runsOnReturn: true) { confirmed += 1 }
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

    func testEscapeCancelsOrganizeConfirmationButGoesBackFromExportReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "SheetPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = SessionStore(reviewDefaults: defaults)
        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: root, selectedItems: [], familyContextItems: [],
            configuration: .initial(hasMultipleTopLevelFolders: false),
            knownOriginFolderPathBytesByFileID: [:])
        store.isOrganizePresented = true
        let organize = NSHostingView(rootView: OrganizeSourceView(store: store).confirmationView(plan)
            .frame(width: 680, height: 330))
        let organizeWindow = mount(organize, size: CGSize(width: 680, height: 330))
        defer { organizeWindow.close() }
        XCTAssertTrue(organize.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: organizeWindow)))
        XCTAssertFalse(store.isOrganizePresented, "Cancel closes confirmation even when Back is also present")
        XCTAssertFalse(store.isFileOperationRunning)

        let exportPlan = MultiDestinationExportPlan(routes: [], unmatchedNames: [],
            workerPlan: .init(items: []), xmpPlan: nil)
        let exporter = ExportManager()
        exporter.state = .awaitingMultiDestinationConfirmation(exportPlan)
        store.isExportPresented = true
        let export = NSHostingView(rootView: ExportView(store: store, exporter: exporter))
        let exportWindow = mount(export, size: CGSize(width: 640, height: 620))
        defer { exportWindow.close() }
        XCTAssertEqual(exporter.state, .awaitingMultiDestinationConfirmation(exportPlan))
        XCTAssertTrue(export.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: exportWindow)))
        settle(export)
        XCTAssertEqual(exporter.state, .summary, "Back returns to setup")
        XCTAssertTrue(store.isExportPresented, "Back keeps Export open")
        XCTAssertFalse(store.isFileOperationRunning)
    }

    func testRecoveryStyleConfirmationNeverRunsOnReturn() throws {
        var done = 0
        var restored = 0
        let host = NSHostingView(rootView: SheetActions {
            SheetCancelButton("Done") { done += 1 }
            SheetPrimaryButton("Restore", runsOnReturn: false) { restored += 1 }
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
                    SheetPrimaryButton("Done", runsOnReturn: true) {}
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
                    voiceOverLabel: "Session save warning", focusOnAppear: true
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

    func testRootDoesNotRecreateBannerMaterials() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Louppe/Views/RootView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".background(.regularMaterial"))
    }

    func testSourceOperationSheetsKeepSizeAndIgnoreEscapeDuringProgress() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for rename in [false, true] {
                let store = SessionStore()
                store.isRenamePresented = rename
                store.isOrganizePresented = !rename
                let content = rename ? AnyView(RenameFilesView(store: store)) : AnyView(OrganizeSourceView(store: store))
                let host = NSHostingView(rootView: content.environment(\.layoutDirection, direction))
                let window = mount(host, size: CGSize(width: 680, height: 650))
                defer { window.close() }
                let setupSize = host.fittingSize
                store.presentSourceFileOperationForTesting(progress: .init(action: .organizing, done: 4, total: 10))
                settle(host)
                XCTAssertEqual(host.fittingSize, setupSize)
                XCTAssertNotNil(descendants(host).compactMap { $0 as? NSScrollView }.first,
                                "Progress must retain the shared sheet's scrolling body")
                _ = host.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: window))
                XCTAssertEqual(store.isRenamePresented, rename)
                XCTAssertEqual(store.isOrganizePresented, !rename)
                store.presentSourceFileOperationForTesting(outcome: .init(
                    movedFiles: 10, failedItems: 0, message: nil, wasUndo: false))
                settle(host)
                XCTAssertEqual(host.fittingSize, setupSize, "A clean result must not shrink the sheet")
            }
        }
    }

    func testExportProgressKeepsSizeAndExistingEscapeCancellationPaths() throws {
        let store = SessionStore()
        store.isExportPresented = true
        let exporter = ExportManager()
        let host = NSHostingView(rootView: ExportView(store: store, exporter: exporter))
        let window = mount(host, size: CGSize(width: 640, height: 620))
        defer { window.close() }
        let setupSize = host.fittingSize
        for state in [ExportManager.State.preparingXMP(.copy), .preparingMultiDestination,
                      .working(mode: .copy, completedBytes: 4, totalBytes: 10),
                      .working(mode: .move, completedBytes: 4, totalBytes: 10)] {
            exporter.state = state
            settle(host)
            XCTAssertEqual(host.fittingSize, setupSize)
            XCTAssertNotNil(descendants(host).compactMap { $0 as? NSScrollView }.first)
            _ = host.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: window))
            XCTAssertEqual(exporter.state, state == .preparingMultiDestination ? .summary : state,
                           "Escape must preserve the existing preparation and worker cancellation paths")
            XCTAssertTrue(store.isExportPresented)
        }
        exporter.state = .validatingDestination(.copy)
        settle(host)
        XCTAssertEqual(host.fittingSize, setupSize)
        XCTAssertTrue(host.performKeyEquivalent(with: try key("\u{1b}", code: 53, window: window)))
        XCTAssertEqual(exporter.state, .summary)
        XCTAssertTrue(store.isExportPresented)
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
