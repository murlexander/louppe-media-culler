import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// In-process layout evidence. Never uses Screen Recording or global input.
@MainActor
enum OffscreenCapture {
    enum Appearance: String, CaseIterable {
        case light, dark

        var native: NSAppearance {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)!
        }
        var scheme: ColorScheme { self == .light ? .light : .dark }
    }

    static func host<V: View>(_ view: V, defaults: UserDefaults,
                              appearance: Appearance, bridgesScene: Bool = true) -> NSViewController {
        let controller = NSHostingController(rootView: view
            .defaultAppStorage(defaults)
            .preferredColorScheme(appearance.scheme)
            .localizedInterface()
            .background(Color.appBackground)
            .tint(Color.louppeAccent)
            .toggleStyle(LouppeToggleStyle())
            .transaction { $0.animation = nil })
        // SessionView's toolbar otherwise silently disappears in plain windows.
        if bridgesScene { controller.sceneBridgingOptions = [.toolbars, .title] }
        return controller
    }

    static func capture<V: View>(_ view: V, defaults: UserDefaults, size: CGSize,
                                 title: String, appearance: Appearance, to output: URL,
                                 requiresToolbar: Bool = false) async throws {
        try await capture(host(view, defaults: defaults, appearance: appearance), size: size,
                          title: title, appearance: appearance, to: output,
                          requiresToolbar: requiresToolbar)
    }

    static func capture(_ controller: NSViewController, size: CGSize, title: String,
                        appearance: Appearance, to output: URL,
                        requiresToolbar: Bool = false,
                        prepare: (NSViewController) throws -> Void = { _ in }) async throws {
        _ = NSApplication.shared
        try requireInactive()
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance.native
        defer { NSApp.appearance = previousAppearance }

        // A pathological multi-display setup must still place this fully offscreen.
        let left = min(-20_000, (NSScreen.screens.map(\.frame.minX).min() ?? 0) - size.width - 1_000)
        let bottom = min(-20_000, (NSScreen.screens.map(\.frame.minY).min() ?? 0) - size.height - 1_000)
        let window = CaptureWindow(contentRect: NSRect(origin: CGPoint(x: left, y: bottom), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            try? assertFuse(window)
            window.contentViewController = nil
            window.close()
        }
        // NSWindow's initializer may ignore an offscreen contentRect origin.
        // Explicit placement happens before the window is ever ordered.
        window.setFrameOrigin(NSPoint(x: left, y: bottom))
        try assertFuse(window)
        window.appearance = appearance.native
        window.title = title
        window.contentViewController = controller
        window.setContentSize(size)
        try assertFuse(window)
        window.setFrameOrigin(NSPoint(x: left, y: bottom))
        try assertFuse(window)
        window.orderBack(nil)
        try assertFuse(window)

        let frame = try XCTUnwrap(window.contentView?.superview, "Missing window frame view")
        try await settle(frame, window: window)
        try prepare(controller)
        try await settle(frame, window: window)
        if requiresToolbar {
            let toolbar = try XCTUnwrap(window.toolbar, "The SwiftUI session toolbar was not bridged")
            XCTAssertFalse(toolbar.items.isEmpty, "The bridged session toolbar has no items")
        }
        try assertFuse(window)
        let bitmap = try rasterize(frame, scale: 2)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output, options: .atomic)
        print("CAPTURE \(output.lastPathComponent) \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), fuse passed")
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func requireInactive() throws {
        guard !NSApp.isActive else {
            XCTFail("CAPTURE FOCUS FUSE: the test application became active; capture stopped")
            throw CaptureError.focusFuse
        }
    }

    private static func assertFuse(_ window: NSWindow) throws {
        try requireInactive()
        guard !window.isKeyWindow,
              NSScreen.screens.allSatisfy({ !$0.frame.intersects(window.frame) }) else {
            // Close immediately even on failure; never leave an intersecting window.
            window.orderOut(nil)
            XCTFail("CAPTURE FOCUS FUSE: a capture window is key or intersects a display: \(window.frame)")
            throw CaptureError.focusFuse
        }
    }

    /// Require unchanged rendered pixels and geometry for a quiet interval.
    /// Pump actual run-loop work and yield to SwiftUI/media tasks, with a hard deadline.
    private static func settle(_ view: NSView, window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(6)
        var previous: Data?
        var unchangedSince = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            try assertFuse(window)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try rasterize(view, scale: 0.25)
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            let sample = Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            if sample != previous {
                previous = sample
                unchangedSince = Date()
            } else if Date().timeIntervalSince(unchangedSince) >= 0.3 {
                return
            }
            pumpRunLoop()
            await Task.yield()
        }
        XCTFail("Offscreen view did not settle within six seconds: \(window.title)")
        throw CaptureError.didNotSettle
    }

    private static func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private static func rasterize(_ view: NSView, scale: CGFloat) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        if scale == 2, let native = view.bitmapImageRepForCachingDisplay(in: bounds),
           native.pixelsWide == Int(ceil(bounds.width * 2)),
           native.pixelsHigh == Int(ceil(bounds.height * 2)) {
            view.cacheDisplay(in: bounds, to: native)
            return native
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: max(1, Int(ceil(bounds.width * scale))),
            pixelsHigh: max(1, Int(ceil(bounds.height * scale))), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        // Capture the theme frame, including title bar and bridged toolbar.
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private enum CaptureError: Error { case focusFuse, didNotSettle }

    /// AppKit normally rescues a titled window onto a display when its hosted
    /// controller changes the content size. These fixtures must never be rescued.
    private final class CaptureWindow: NSWindow {
        override var canBecomeKey: Bool { false }
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
}
