import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class SelectionInteractionFixture {
    let root: URL
    let defaults: UserDefaults
    private let suite = "SelectionInteraction.\(UUID())"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SelectionInteraction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func store() -> SessionStore {
        SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
            photosDecisions: PhotosReviewDecisions(directory: root.appendingPathComponent("photos")),
            operationJournalDirectory: root.appendingPathComponent("operations"), reviewDefaults: defaults,
            pinnedFolders: PinnedFoldersStore(storageDirectory: root.appendingPathComponent("pins"), observesSystemChanges: false),
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("navigation.json")))
    }

    func readyStore(count: Int) throws -> SessionStore {
        let store = store()
        store.items = try (0..<count).map { index in
            let name = String(format: "PHOTO_%03d.JPG", index)
            let image = NSImage(size: CGSize(width: 480, height: 320), flipped: false) { rect in
                NSColor(calibratedHue: CGFloat(index % 12) / 12, saturation: 0.3, brightness: 0.65, alpha: 1).setFill()
                rect.fill()
                ("Disposable \(index)" as NSString).draw(at: CGPoint(x: 30, y: 130),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.white])
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: root.appendingPathComponent(name))
            return PhotoItem(id: name, primaryURL: root.appendingPathComponent(name), pairedURL: nil,
                captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.viewMode = .grid
        store.sort = PhotoSort(key: .name, ascending: true)
        store.isGroupingEnabled = false
        store.rebuildDerivedDataForTesting()
        return store
    }

    static func mount(_ host: NSView, size: CGSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        return window
    }

    static func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    static func elements(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { children.forEach(walk) }
            if let view = object as? NSView { view.subviews.forEach(walk) }
        }
        walk(root)
        return result
    }

    static func label(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityLabel")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    static func clickControl(_ label: String, in host: NSView, window: NSWindow) throws {
        let button = try XCTUnwrap(elements(host).first { Self.label($0) == label }, "Missing mounted control: \(label)")
        let frame = window.convertFromScreen(try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue)
        XCTAssertTrue(host.convert(host.bounds, to: nil).contains(frame))
        try click(CGPoint(x: frame.midX, y: frame.midY), window: window)
    }

    static func click(_ point: CGPoint, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: modifiers, timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: modifiers, timestamp: time + 0.01, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(queued) }
    }

    static func assertCurrentVisible(_ store: SessionStore, in scroll: NSScrollView,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try XCTUnwrap(store.currentItem)
        guard let tile = elements(scroll).first(where: { label($0) == item.displayName }) else {
            XCTFail("Current tile must be mounted in the native viewport: \(item.displayName)", file: file, line: line)
            return
        }
        let frame = scroll.window!.convertFromScreen(try XCTUnwrap(tile.value(forKey: "accessibilityFrame") as? NSValue).rectValue)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        XCTAssertTrue(frame.intersects(viewport), "Actual current tile \(frame) must intersect native viewport \(viewport)", file: file, line: line)
    }

    func capture(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_SELECTION_CAPTURE_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
