import AppKit
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import Louppe

/// Popover glass only composes on screen. The window sits just above the
/// desktop, behind every other app, and never activates; ScreenCaptureKit reads
/// this process's own windows without Screen Recording permission.
@available(macOS 14.4, *)
@MainActor
final class PopoverSurfaceTests: XCTestCase {
    func testArrowSharesTheBodySurface() async throws {
        try requireForegroundUI()
        let suite = "PopoverSurfaceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let surfaces: [(String, AnyView)] = [
            // Content-sized popovers round to whole points; a fractional
            // height once left the arrow outside the material.
            ("fractional height", AnyView(Text(verbatim: "Row").frame(width: 300, height: 16.25)
                .padding(14).louppePopoverSurface())),
            ("Sort", AnyView(SortView(store: store))),
            ("Filter", AnyView(FilterView(store: store))),
        ]
        for (name, surface) in surfaces {
            let (arrow, body) = try await arrowAndBody(surface)
            for (a, b) in zip(arrow, body) {
                XCTAssertEqual(a, b, accuracy: 0.05, "\(name): arrow \(arrow) differs from the popover body \(body)")
            }
        }
    }

    /// Dark appearance over mid-grey, where uncovered arrow glass is far
    /// lighter than the thick material.
    private func arrowAndBody(_ surface: AnyView) async throws -> ([CGFloat], [CGFloat]) {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let size = CGSize(width: 520, height: 720)
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2,
                                                  y: screen.visibleFrame.midY - size.height / 2,
                                                  width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.contentView = NSHostingView(rootView: ZStack(alignment: .top) {
            Color(white: 0.55)
            Button {} label: { Text(verbatim: "Anchor") }
                .padding(.top, 20)
                .popover(isPresented: .constant(true), arrowEdge: .bottom) { surface }
        })
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        window.orderFrontRegardless()
        defer {
            for presented in NSApp.windows where !existing.contains(ObjectIdentifier(presented)) {
                presented.orderOut(nil)
            }
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        var popover: NSWindow?
        for _ in 0..<40 where popover == nil {
            await pause()
            popover = NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        let presented = try XCTUnwrap(popover, "The popover did not appear")
        for _ in 0..<15 { await pause() }

        let content = try await SCShareableContent.currentProcess
        let ids: Set<CGWindowID> = [CGWindowID(window.windowNumber), CGWindowID(presented.windowNumber)]
        let filter = SCContentFilter(display: try XCTUnwrap(content.displays.first),
                                     including: content.windows.filter { ids.contains($0.windowID) })
        let frame = presented.frame
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                   width: frame.width, height: frame.height)
        config.width = Int(frame.width * 2)
        config.height = Int(frame.height * 2)
        config.showsCursor = false
        let image = NSBitmapImageRep(cgImage: try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config))
        func rgb(x: CGFloat, yFromTop: CGFloat) throws -> [CGFloat] {
            let color = try XCTUnwrap(image.colorAt(x: Int(x * 2), y: Int(yFromTop * 2))?.usingColorSpace(.deviceRGB))
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
        // The arrow points at the anchor; the body sample sits right of the title.
        return (try rgb(x: window.frame.midX - frame.minX, yFromTop: 6),
                try rgb(x: frame.width - 60, yFromTop: 24))
    }

    private func pause() async {
        pumpRunLoop()
        try? await Task.sleep(for: .milliseconds(60))
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        // Dispatch only events already queued to this process, never global input.
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}
