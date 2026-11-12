import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Louppe

/// Exercise GridCell through the real collection/hosting boundaries. No
/// TileBadgeLayout or rubber-band helper supplies the click coordinates.
@MainActor
final class RenderedGridControlTests: XCTestCase {
    func testVideoPlayReceivesGlyphAndEdgeClicksInBothDirections() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AccessibilityMedia/captioned-described.mov")
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("Video.mov")
        try FileManager.default.copyItem(at: source, to: url)
        let item = PhotoItem(id: url.path, primaryURL: url, pairedURL: nil, captureDate: nil,
                             cameraModel: nil, lensModel: nil, mediaKind: .video, duration: 8,
                             videoDimensions: CGSize(width: 640, height: 360), videoIsPlayable: true,
                             fileSize: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        _ = await ImagePipeline.shared.thumbnail(for: item)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let store = readyStore(item)
            store.videoPlayback.player.isMuted = true
            let host = gridHost(store, direction: direction)
            let window = mount(host)
            defer { store.videoPlayback.stop(); window.contentView = nil; window.close() }
            try await settle(host)
            let frame = try controlFrame(label: L10n.text("Play \(L10n.label(item.mediaKind.singularLabel))"), in: host, window: window)
            XCTAssertFalse(frame.isEmpty)
            let glyph = try paintedCenter(in: host, within: host.convert(frame.insetBy(dx: 6, dy: 6), from: nil)) {
                $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9
            }
            let glyphPoint = host.convert(glyph, to: nil)
            print("Rendered Grid Play \(direction): target=\(frame), glyph=\(glyphPoint)")
            for point in outsidePoints(frame) {
                try click(point, window: window)
                XCTAssertFalse(store.videoPlayback.isPlaying, "Outside Play: \(direction), \(point), \(frame)")
            }
            // The native circular button's glyph is centered; cardinal edges
            // stay inside its drawn circle, unlike the rectangle's corners.
            for point in [glyphPoint] + edgePoints(frame) {
                try click(point, window: window)
                XCTAssertTrue(store.videoPlayback.isActive(item), "Play must act on the rendered video")
                XCTAssertTrue(store.videoPlayback.isPlaying, "Drawn Play: \(direction), \(point), \(frame)")
                try await waitUntil { store.videoPlayback.player.rate > 0 }
                store.videoPlayback.pause()
                try await settle(host)
                XCTAssertEqual(store.viewMode, .grid, "Play must not open Gallery through the tile beneath it")
            }
        }
    }

    func testPanoramaDecisionReceivesDrawnGlyphAndTargetEdgesInBothDirections() async throws {
        // Cover both a 6:1 panorama and a sliver shorter than the badge itself.
        for size in [CGSize(width: 1200, height: 200), CGSize(width: 1800, height: 100)] {
            let item = try panorama(size: size)
            _ = await ImagePipeline.shared.thumbnail(for: item)
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let store = readyStore(item)
                item.rating = .yes
                let host = gridHost(store, direction: direction)
                let window = mount(host)
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                let frame = try controlFrame(label: L10n.text("Change decision for \(item.displayName)"),
                                             in: host, window: window)
                XCTAssertEqual(frame.width, 40, accuracy: 0.5)
                XCTAssertEqual(frame.height, 40, accuracy: 0.5)
                // Locate the *painted* green Yes badge, not its intended layout.
                let glyph = try paintedCenter(in: host) {
                    $0.greenComponent > 0.4 && $0.greenComponent > $0.redComponent * 1.3
                        && $0.greenComponent > $0.blueComponent * 1.2
                }
                let point = host.convert(glyph, to: nil)
                print("Rendered panorama \(size), \(direction): target=\(frame), glyph=\(point)")
                XCTAssertTrue(frame.contains(point), "The drawn badge must lie inside its real control")
                for outside in outsidePoints(frame) {
                    try click(outside, window: window)
                    XCTAssertEqual(item.rating, .yes, "Outside decision: \(direction), \(outside), \(frame)")
                }
                for inside in [point] + edgePoints(frame) {
                    try click(inside, window: window)
                    XCTAssertEqual(item.rating, .no, "Drawn decision: \(direction), \(inside), \(frame)")
                    XCTAssertEqual(store.viewMode, .grid)
                    store.rate(.yes, at: 0)
                    try await settle(host)
                }
            }
        }
    }

    private func readyStore(_ item: PhotoItem) -> SessionStore {
        _ = NSApplication.shared
        let store = SessionStore()
        store.items = [item]
        store.phase = .ready
        store.viewMode = .grid
        store.gridThumbSize = 180
        store.rebuildDerivedDataForTesting()
        return store
    }

    private func gridHost(_ store: SessionStore, direction: LayoutDirection) -> NSView {
        NSHostingView(rootView: GridView(store: store)
            .environment(\.layoutDirection, direction)
            .environment(\.accessibilityEnabled, true)
            .preferredColorScheme(.light))
    }

    private func mount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 320, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        return window
    }

    private func controlFrame(label: String, in host: NSView, window: NSWindow) throws -> CGRect {
        let elements = accessibilityElements(host)
        let button = try XCTUnwrap(elements.first { string($0, "accessibilityLabel") == label },
                                   "Missing \(label): \(elements.compactMap { string($0, "accessibilityLabel") })")
        let screen = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let frame = window.convertFromScreen(screen)
        XCTAssertTrue(host.convert(host.bounds, to: nil).contains(frame), "Control must be in the rendered viewport")
        return frame
    }

    private func accessibilityElements(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
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
        walk(root)
        return result
    }

    private func string(_ object: NSObject, _ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func paintedCenter(in host: NSView, within region: CGRect? = nil,
                               matching matches: (NSColor) -> Bool) throws -> CGPoint {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let fromTop = (CGFloat(y) + 0.5) / CGFloat(bitmap.pixelsHigh) * host.bounds.height
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(bitmap.pixelsWide) * host.bounds.width,
                                    y: host.isFlipped ? fromTop : host.bounds.height - fromTop)
                guard region?.contains(point) ?? true,
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      matches(color) else { continue }
                xs.append(x); ys.append(y)
            }
        }
        let minX = try XCTUnwrap(xs.min(), "The real Grid must paint the control glyph")
        let maxX = try XCTUnwrap(xs.max())
        let minY = try XCTUnwrap(ys.min())
        let maxY = try XCTUnwrap(ys.max())
        let x = CGFloat(minX + maxX + 1) / 2 / CGFloat(bitmap.pixelsWide) * host.bounds.width
        let fromTop = CGFloat(minY + maxY + 1) / 2 / CGFloat(bitmap.pixelsHigh) * host.bounds.height
        return CGPoint(x: x, y: host.isFlipped ? fromTop : host.bounds.height - fromTop)
    }

    private func edgePoints(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX + 2, y: rect.midY), CGPoint(x: rect.maxX - 2, y: rect.midY),
         CGPoint(x: rect.midX, y: rect.minY + 2), CGPoint(x: rect.midX, y: rect.maxY - 2)]
    }

    private func outsidePoints(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX - 2, y: rect.midY), CGPoint(x: rect.maxX + 2, y: rect.midY),
         CGPoint(x: rect.midX, y: rect.minY - 2), CGPoint(x: rect.midX, y: rect.maxY + 2)]
    }

    private func click(_ point: CGPoint, window: NSWindow) throws {
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: time + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                        inMode: .default, dequeue: true) {
            window.sendEvent(queued)
        }
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Real video playback must start")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RenderedGrid-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func panorama(size: CGSize) throws -> PhotoItem {
        let url = try temporaryFolder().appendingPathComponent("Panorama.png")
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.gray.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return PhotoItem(id: url.path, primaryURL: url, pairedURL: nil, captureDate: nil,
                         cameraModel: nil, lensModel: nil, fileSize: 1)
    }
}
