import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class MainWindowLayoutTests: XCTestCase {
    func testWelcomeMinimumIncludesIntrinsicContentAndWarnings() {
        XCTAssertEqual(
            MainWindowLayout.welcome.minimumContentSize(measuredWelcome: .zero, warningHeight: 0),
            CGSize(width: 456, height: 180)
        )
        XCTAssertEqual(
            MainWindowLayout.welcome.minimumContentSize(
                measuredWelcome: CGSize(width: 961.2, height: 731.1), warningHeight: 27.4
            ),
            CGSize(width: 962, height: 759)
        )
        XCTAssertEqual(
            MainWindowLayout.scanning.minimumContentSize(
                measuredWelcome: CGSize(width: 1257, height: 800), warningHeight: 40
            ),
            CGSize(width: 520, height: 560),
            "the previous welcome measurement must not constrain scanning"
        )
        XCTAssertEqual(
            MainWindowLayout.session.minimumContentSize(
                measuredWelcome: CGSize(width: 1257, height: 800), warningHeight: 40
            ),
            CGSize(width: 900, height: 640)
        )
    }

    func testNativeMinimumReservesTheFullSizeToolbarAboveRequiredContent() {
        let required = CGSize(width: 961, height: 650)
        let (window, controller) = makeWindow(minimum: required)
        defer { window.close() }
        controller.apply()
        let fittedHeight = fittingWelcomeHeight(required.height, in: window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertGreaterThan(window.contentMinSize.height, fittedHeight)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, required.width)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, fittedHeight)
        XCTAssertEqual(
            window.contentMinSize.height,
            fittedHeight + nativeCoveredHeight(window), accuracy: 0.5
        )
        window.setContentSize(window.contentMinSize)
        controller.apply()
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, fittedHeight)
    }

    func testAddedContentGrowsWindowAndRemovingContentOnlyLowersMinimum() {
        let (window, controller) = makeWindow()
        defer { window.close() }
        controller.minimumContentSize = CGSize(width: 961, height: 690)
        controller.apply()
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, 961)
        XCTAssertGreaterThanOrEqual(
            window.contentLayoutRect.height, fittingWelcomeHeight(690, in: window)
        )
        let grownFrame = window.frame.size
        let grownMinimum = window.contentMinSize

        controller.minimumContentSize = MainWindowLayout.welcome.minimumContentSize
        controller.apply()
        XCTAssertEqual(window.frame.size, grownFrame, "removing a drive should not make the window jump smaller")
        XCTAssertLessThan(window.contentMinSize.width, grownMinimum.width)
        XCTAssertLessThan(window.contentMinSize.height, grownMinimum.height)
    }

    func testWelcomeOpensAtItsMeasuredMinimum() {
        let required = CGSize(width: 644, height: 510)
        let (window, controller) = makeWindow(minimum: required)
        defer { window.close() }
        controller.apply()
        XCTAssertEqual(window.contentLayoutRect.width, required.width, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, required.height, accuracy: 1)
    }

    func testLateToolbarInstallationRechecksUsableSpace() {
        let (window, controller) = makeWindow(toolbar: false)
        defer { window.close() }
        window.setContentSize(window.contentMinSize)
        let before = window.contentMinSize.height
        window.toolbar = NSToolbar(identifier: "LouppeLayoutLateToolbar")
        window.toolbarStyle = .unified
        window.contentView?.layoutSubtreeIfNeeded()
        controller.apply()
        XCTAssertGreaterThan(window.contentMinSize.height, before)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, controller.minimumContentSize.height)
    }

    func testPhaseTransitionsRetainLaunchGrowthAndRestoreSessionLayout() {
        let (window, controller) = makeWindow(minimum: CGSize(width: 961, height: 660))
        defer { window.close() }
        let welcomeSize = window.frame.size
        controller.windowLayout = .scanning
        controller.minimumContentSize = MainWindowLayout.scanning.minimumContentSize
        controller.apply()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.frame.size, welcomeSize, "starting a scan should not collapse an expanded welcome window")

        controller.windowLayout = .session
        controller.minimumContentSize = MainWindowLayout.session.minimumContentSize
        controller.apply()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        guard let visible = window.screen?.visibleFrame else {
            XCTFail("window needs a screen")
            return
        }
        XCTAssertEqual(window.frame.width, visible.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, visible.height, accuracy: 1)

        controller.windowLayout = .welcome
        controller.minimumContentSize = CGSize(width: 961, height: 650)
        controller.apply()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, 961)
        let fittedHeight = fittingWelcomeHeight(650, in: window)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, fittedHeight)
        XCTAssertEqual(window.contentLayoutRect.width, 961, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, fittedHeight, accuracy: 1)
    }

    func testSessionKeepsManualResizeUntilDisplayChanges() throws {
        let (window, controller) = makeWindow()
        defer { window.close() }
        controller.windowLayout = .session
        controller.minimumContentSize = MainWindowLayout.session.minimumContentSize
        controller.apply()
        let visible = try XCTUnwrap(window.screen).visibleFrame
        window.setContentSize(CGSize(width: 950, height: 650))
        controller.apply()
        XCTAssertLessThan(window.frame.width, visible.width)

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared
        )
        XCTAssertEqual(window.frame.width, visible.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, visible.height, accuracy: 1)
    }

    func testNativeScreenChangeReportsActualDisplayAndFitsAfterReflow() async throws {
        _ = NSApplication.shared
        let orderedScreens = NSScreen.screens.sorted { $0.visibleFrame.width < $1.visibleFrame.width }
        guard let small = orderedScreens.first, let large = orderedScreens.last,
              small.visibleFrame.width < large.visibleFrame.width else {
            throw XCTSkip("Screen transition requires two different display sizes")
        }
        let wide = min(large.visibleFrame.width - 20, small.visibleFrame.width + 100)
        let (window, controller) = makeWindow(minimum: CGSize(width: wide, height: 520))
        defer { window.close() }
        window.setFrameOrigin(CGPoint(x: large.visibleFrame.minX + 5, y: large.visibleFrame.minY + 5))
        var reportedWidth: CGFloat?
        controller.onAvailableContentSizeChange = { reportedWidth = $0.width }
        window.setFrameOrigin(CGPoint(x: small.visibleFrame.minX + 5, y: small.visibleFrame.minY + 5))
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        for _ in 0..<20 where reportedWidth != small.visibleFrame.width {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reportedWidth, small.visibleFrame.width)
        XCTAssertGreaterThan(window.frame.width, small.visibleFrame.width, "old content minimum stays protected until reflow")
        controller.minimumContentSize = CGSize(width: 961, height: 620)
        controller.apply()
        XCTAssertLessThanOrEqual(window.frame.width, small.visibleFrame.width)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, 961)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, 620)
    }

    func testScreenParameterChangesRefitOnSameDisplayAndDetachStopsObservation() throws {
        let (window, controller) = makeWindow()
        defer { window.close() }
        let screen = try XCTUnwrap(window.screen)
        let oversized = CGSize(
            width: screen.visibleFrame.width + 200,
            height: window.contentMinSize.height
        )
        window.setContentSize(oversized)
        controller.apply()
        XCTAssertGreaterThan(window.frame.width, screen.visibleFrame.width)

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared
        )
        XCTAssertEqual(window.screen, screen, "this notification does not require moving to another display")
        XCTAssertLessThanOrEqual(window.frame.width, screen.visibleFrame.width)
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, controller.minimumContentSize.width)

        controller.removeFromSuperview()
        window.setContentSize(oversized)
        let detachedFrame = window.frame
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared
        )
        XCTAssertEqual(window.frame, detachedFrame, "detached bridges must stop receiving global screen notifications")
    }

    func testOverflowCapsWelcomeHeightAndIncludesWarningsInScrollDecision() {
        let available = CGSize(width: 900, height: 580)
        let content = CGSize(width: 665, height: 560)
        XCTAssertFalse(MainWindowLayout.welcome.needsVerticalScrolling(
            measuredWelcome: content, warningHeight: 20, availableContentSize: available
        ))
        XCTAssertTrue(MainWindowLayout.welcome.needsVerticalScrolling(
            measuredWelcome: content, warningHeight: 40, availableContentSize: available
        ))
        XCTAssertEqual(MainWindowLayout.welcome.minimumContentSize(
            measuredWelcome: CGSize(width: 665, height: 1_100),
            warningHeight: 40, availableContentSize: available
        ), CGSize(width: 665, height: 580))
        XCTAssertEqual(MainWindowLayout.session.minimumContentSize(
            measuredWelcome: content, warningHeight: 40, availableContentSize: available
        ), CGSize(width: 900, height: 640), "the fallback is confined to the welcome page")
    }

    func testOversizedWelcomeStaysWithinNativeDisplayHeight() throws {
        let (window, controller) = makeWindow()
        defer { window.close() }
        let visible = try XCTUnwrap(window.screen).visibleFrame
        controller.minimumContentSize = CGSize(width: 665, height: visible.height + 500)
        controller.apply()
        XCTAssertLessThanOrEqual(window.frame.height, visible.height)
        XCTAssertLessThanOrEqual(
            window.contentMinSize.height,
            window.contentRect(forFrameRect: visible).height
        )
    }

    func testToolbarChangeReportsNewUsableHeightWithoutChangingScreenWidth() async throws {
        let (window, controller) = makeWindow(toolbar: false)
        defer { window.close() }
        var reports: [CGSize] = []
        controller.onAvailableContentSizeChange = { reports.append($0) }
        controller.apply()
        try await Task.sleep(for: .milliseconds(30))
        let before = try XCTUnwrap(reports.last)
        window.toolbar = NSToolbar(identifier: "LouppeOverflowToolbar")
        window.toolbarStyle = .unified
        window.contentView?.layoutSubtreeIfNeeded()
        controller.apply()
        try await Task.sleep(for: .milliseconds(30))
        let after = try XCTUnwrap(reports.last)
        XCTAssertEqual(after.width, before.width)
        XCTAssertLessThan(after.height, before.height)
    }

    func testOverflowScrollCanReachLastOfThirteenDriveRows() async throws {
        _ = NSApplication.shared
        let fixtures = (0..<13).map { index in
            ConnectedDrive(
                id: .init(volumeUUID: "layout-\(index)", mediaUUID: "layout-media-\(index)",
                          bsdName: "fixture\(index)",
                          mountURL: URL(fileURLWithPath: "/tmp/LayoutDrive-\(index)")),
                name: "Layout drive \(index)", availableBytes: 1_000_000,
                totalBytes: 2_000_000, isRemovable: true
            )
        }
        let drives = ConnectedDrivesStore { fixtures }
        let store = SessionStore()
        store.recentFolders = (0..<5).map { URL(fileURLWithPath: "/tmp/LayoutRecent-\($0)") }
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 665, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WelcomeView(
            store: store, availableScreenWidth: 900,
            connectedDrives: drives, scrollsVertically: true
        ))
        window.contentView = host
        defer { drives.stop(); window.close() }
        window.orderFront(nil)
        for _ in 0..<40 where drives.drives.count != 13 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(drives.drives.count, 13)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScrollView).first
        }
        let scroll = try XCTUnwrap(findScrollView(host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        let bottom = CGRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1)
        document.scrollToVisible(bottom)
        XCTAssertGreaterThanOrEqual(document.visibleRect.maxY, document.bounds.maxY - 1)
    }

    private func makeWindow(
        minimum: CGSize = MainWindowLayout.welcome.minimumContentSize,
        toolbar: Bool = true
    ) -> (NSWindow, WindowContentLayout.Configurator) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 520, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if toolbar {
            window.toolbar = NSToolbar(identifier: "LouppeLayoutTests")
            window.toolbarStyle = .unified
        }
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        let controller = WindowContentLayout.Configurator(frame: content.bounds)
        controller.windowLayout = .welcome
        controller.minimumContentSize = minimum
        controller.autoresizingMask = [.width, .height]
        content.addSubview(controller)
        controller.apply()
        return (window, controller)
    }

    // Welcome preserves its intrinsic minimum until the display requires the
    // documented scroll fallback. Hosted runners can have only 608 usable points.
    private func fittingWelcomeHeight(_ required: CGFloat, in window: NSWindow) -> CGFloat {
        guard let screen = window.screen else {
            XCTFail("window needs a screen")
            return required
        }
        let available = window.contentRect(forFrameRect: screen.visibleFrame).height
            - nativeCoveredHeight(window)
        return min(required, available)
    }

    private func nativeCoveredHeight(_ window: NSWindow) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).height - window.contentLayoutRect.height
    }
}
