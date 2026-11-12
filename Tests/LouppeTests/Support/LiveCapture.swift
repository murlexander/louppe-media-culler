import AppKit
import ScreenCaptureKit
import XCTest

/// Window-server evidence of this process only. Requires an explicit desktop handover.
@available(macOS 14.4, *)
@MainActor
enum LiveCapture {
    enum Presentation { case window, popover, sheet }

    static func capture(_ controller: NSViewController, size: CGSize, title: String,
                        appearance: OffscreenCapture.Appearance, to output: URL,
                        requiresToolbar: Bool, presentation: Presentation,
                        prepare: (NSViewController) throws -> Void) async throws {
        try requireForegroundUI()
        _ = NSApplication.shared
        // XCTest waits in its own run-loop mode. ScreenCaptureKit's callbacks
        // need the default mode serviced while its async requests are suspended.
        let pump = Task { @MainActor in
            while !Task.isCancelled { await pause() }
        }
        defer { pump.cancel() }
        let previousApp = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        let previousPolicy = NSApp.activationPolicy()
        let previousAppearance = NSApp.appearance
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var failure: Error?
        do {
            NSApp.setActivationPolicy(.regular)
            if !NSRunningApplication.current.isFinishedLaunching { NSApp.finishLaunching() }
            NSApp.appearance = appearance.native
            try await captureWindow(controller, size: size, title: title, appearance: appearance,
                                    to: output, requiresToolbar: requiresToolbar,
                                    presentation: presentation, prepare: prepare)
        } catch {
            print("CAPTURE LIVE FAILURE type=\(type(of: error)) error=\(error)")
            failure = error
        }
        // Includes native popovers and sheets, even if presentation/capture failed.
        for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) {
            if let parent = window.sheetParent { parent.endSheet(window) }
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        NSApp.appearance = previousAppearance
        NSApp.setActivationPolicy(previousPolicy)
        previousApp.activate(options: [])
        let deadline = Date().addingTimeInterval(3)
        while (NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp.processIdentifier || NSApp.isActive),
              Date() < deadline {
            await pause()
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousApp.processIdentifier,
                       "Live capture must restore the previously frontmost app, including on failure")
        XCTAssertTrue(NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }.allSatisfy { !$0.isVisible },
                      "Live capture left a test window visible")
        print("CAPTURE LIVE RESTORED frontmost=\(previousApp.processIdentifier) confirmed=\(previousApp.isActive)")
        pump.cancel()
        await pump.value
        if let failure { throw failure }
    }

    private static func captureWindow(_ controller: NSViewController, size: CGSize, title: String,
                                      appearance: OffscreenCapture.Appearance, to output: URL,
                                      requiresToolbar: Bool, presentation: Presentation,
                                      prepare: (NSViewController) throws -> Void) async throws {
        try requireForegroundUI()
        let screen = try XCTUnwrap(NSScreen.screens.first, "Live capture needs the main display")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        window.appearance = appearance.native
        window.title = title
        window.contentViewController = controller
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                      y: screen.visibleFrame.midY - window.frame.height / 2))
        guard screen.visibleFrame.contains(window.frame) else {
            throw CaptureError.invalidState("Scenario does not fit the main display at its requested size")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil("active session window") { NSApp.isActive && window.isKeyWindow }
        await pause()
        // Let the real toolbar bridge mount before changing a presentation binding.
        _ = try await settledImage(window: window, screen: screen)
        if requiresToolbar {
            let toolbar = try XCTUnwrap(window.toolbar, "The SwiftUI session toolbar was not bridged")
            XCTAssertFalse(toolbar.items.isEmpty, "The bridged session toolbar has no items")
        }
        try prepare(controller)
        try await waitUntil("native \(presentation) presentation") {
            switch presentation {
            case .window: return true
            case .sheet: return window.attachedSheet?.isVisible == true
            case .popover: return NSApp.windows.contains { $0.isVisible && isPopover($0) }
            }
        }
        let image = try await settledImage(window: window, screen: screen)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Preserve point dimensions when composing --pair at 2×.
        bitmap.size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output, options: .atomic)
        print("CAPTURE LIVE \(output.lastPathComponent) \(image.width)×\(image.height), active=\(NSApp.isActive), windows=\(captureWindows(window).map { String(describing: type(of: $0)) })")
    }

    private static func isPopover(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("Popover")
    }

    private static func captureWindows(_ main: NSWindow) -> [NSWindow] {
        // Popovers are not always in childWindows. Limit the filter to visible
        // NSWindows from this test process; no other application's pixels enter it.
        NSApp.windows.filter { $0.isVisible && ($0 === main || $0.sheetParent === main
            || main.childWindows?.contains($0) == true || isPopover($0)) }
    }

    private static func screenshot(window: NSWindow, screen: NSScreen) async throws -> CGImage {
        guard NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            throw CaptureError.invalidState("Test process lost foreground ownership")
        }
        let native = captureWindows(window)
        let bounds = native.reduce(window.frame) { $0.union($1.frame) }.integral
        guard screen.frame.contains(bounds) else {
            throw CaptureError.invalidState("A presented surface extends beyond the main display")
        }
        let content = try await SCShareableContent.currentProcess
        let displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
        let display = try XCTUnwrap(content.displays.first { $0.displayID == displayID })
        let ids = Set(native.map { CGWindowID($0.windowNumber) })
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard Set(windows.map(\.windowID)) == ids else {
            throw CaptureError.invalidState("Window server has not published every presented window")
        }
        let filter = SCContentFilter(display: display, including: windows)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: bounds.minX - screen.frame.minX,
                                   y: screen.frame.maxY - bounds.maxY,
                                   width: bounds.width, height: bounds.height)
        config.width = Int(bounds.width * 2)
        config.height = Int(bounds.height * 2)
        config.showsCursor = false
        defer { withExtendedLifetime((content, filter, config)) {} }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Same quiet-interval approach as offscreen capture, sampling the actual
    /// compositor output. Ignore tiny changes (caret/spinner and glass dithering).
    private static func settledImage(window: NSWindow, screen: NSScreen) async throws -> CGImage {
        let deadline = Date().addingTimeInterval(8)
        var previous: [UInt8]?
        var previousSize = CGSize.zero
        var unchangedSince = Date()
        while Date() < deadline {
            try Task.checkCancellation()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let image = try await screenshot(window: window, screen: screen)
            let sample = try pixels(image)
            let size = CGSize(width: image.width, height: image.height)
            if let previous, size == previousSize, stable(previous, sample) {
                if Date().timeIntervalSince(unchangedSince) >= 0.3 { return image }
            } else {
                unchangedSince = Date()
            }
            previous = sample
            previousSize = size
            await pause()
        }
        throw CaptureError.invalidState("Live pixels did not settle within eight seconds: \(window.title)")
    }

    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = max(1, image.width / 8), height = max(1, image.height / 8)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    private static func stable(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > 3 }.count
        return Double(changed) / Double(a.count) < 0.005
    }

    private static func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { await pause() }
        guard condition() else { throw CaptureError.invalidState("Timed out waiting for \(description)") }
    }

    private static func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        // A command-line XCTest host has no NSApplication.run() event pump.
        // Dispatch only events already queued to this process, never global input.
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private static func pause() async {
        pumpRunLoop()
        try? await Task.sleep(for: .milliseconds(60))
    }

    private enum CaptureError: Error { case invalidState(String) }
}
