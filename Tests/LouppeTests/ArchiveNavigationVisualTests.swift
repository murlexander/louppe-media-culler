import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Opt-in mounted native evidence. Every window stays hidden; no global input.
@MainActor
final class ArchiveNavigationVisualTests: XCTestCase {
    func testCaptureFolderNavigationWithoutForegroundControl() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_ARCHIVE_SNAPSHOTS"] else {
            throw XCTSkip("Set LOUPPE_ARCHIVE_SNAPSHOTS for native archive navigation captures.")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-ArchiveVisual-\(UUID())")
        let media = root.appendingPathComponent("Photo archive")
        let defaultsName = "Louppe-ArchiveVisual-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 320, height: 220))
        image.lockFocus()
        NSColor(calibratedRed: 0.22, green: 0.34, blue: 0.27, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 220)).fill()
        NSColor(calibratedRed: 0.72, green: 0.57, blue: 0.37, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 85, y: 30, width: 150, height: 150)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for folder in ["2025", "2026/Autumn", "2026/Summer", "Empty folder"] {
            let directory = media.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if folder != "Empty folder" {
                for index in 1...24 {
                    try bytes.write(to: directory.appendingPathComponent(String(format: "PHOTO_%04d.png", index)))
                }
            }
        }
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            reviewDefaults: defaults,
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("Navigation.json")))
        store.openFolder(media)
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if case .ready = store.phase { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        guard case .ready = store.phase else { return XCTFail(store.scanError ?? "opening timeout") }
        store.archiveLeadingPane = .folders
        store.setArchiveExpandedFolders(["", "2026"])
        store.selectArchiveFolder("2026")
        for scheme in [ColorScheme.light, .dark] {
            for mode in [ViewMode.gallery, .grid] {
                store.viewMode = mode
                for width in [900.0, 1512.0] {
                    try await capture(store, defaults: defaults, output: output,
                        name: "\(mode.rawValue)-\(Int(width))-\(scheme)", width: width, scheme: scheme)
                }
            }
        }
        store.showBrowser = false
        for mode in [ViewMode.gallery, .grid] {
            store.viewMode = mode
            try await capture(store, defaults: defaults, output: output,
                name: "subfolder-hidden-tree-\(mode.rawValue)", width: 900, scheme: .light)
        }
        store.showBrowser = true
        store.viewMode = .grid
        try await capture(store, defaults: defaults, output: output, name: "grid-rtl", width: 1512,
            scheme: .dark, direction: .rightToLeft)
        store.selectArchiveFolder("Empty%20folder")
        try await capture(store, defaults: defaults, output: output, name: "empty-folder", width: 900, scheme: .light)
        store.selectArchiveFolder("2026")
        store.setArchiveIncludesDescendants(false)
        try await capture(store, defaults: defaults, output: output, name: "direct-folder-empty", width: 900, scheme: .dark)
        store.setArchiveIncludesDescendants(true)
        store.viewMode = .gallery
        store.archiveLeadingPane = .browser
        try await capture(store, defaults: defaults, output: output, name: "browser", width: 900, scheme: .light)
        store.archiveLeadingPane = .folders
        store.selectArchiveFolder("")
        store.viewMode = .grid
        try await capture(store, defaults: defaults, output: output, name: "all-media", width: 900, scheme: .light)
        store.showBrowser = false
        try await capture(store, defaults: defaults, output: output,
            name: "all-media-hidden-tree", width: 900, scheme: .light)
        store.showBrowser = true
        await store.flushArchiveNavigation()
        store.archiveNavigationWarning = L10n.text("Folder navigation could not be restored. Previous positions are retained.")
        store.archiveNavigationCanReset = true
        try await capture(store, defaults: defaults, output: output, name: "navigation-recovery", width: 900, scheme: .light)
        store.archiveNavigationWarning = nil
        store.archiveNavigationCanReset = false
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
        for folder in ["2025", "2026/Autumn", "2026/Summer"] {
            for index in 1...24 {
                XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(folder)
                    .appendingPathComponent(String(format: "PHOTO_%04d.png", index))), bytes)
            }
        }
    }

    func testCaptureFlatFolderWithoutArchiveControls() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_ARCHIVE_SNAPSHOTS"] else {
            throw XCTSkip("Set LOUPPE_ARCHIVE_SNAPSHOTS for native archive navigation captures.")
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-FlatVisual-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let defaultsName = "Louppe-FlatVisual-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
        let image = NSImage(size: NSSize(width: 320, height: 220))
        image.lockFocus()
        NSColor.systemGray.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 220)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: media.appendingPathComponent("PHOTO.png"))
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            reviewDefaults: defaults,
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("Navigation.json")))
        store.openFolder(media)
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if case .ready = store.phase { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        guard case .ready = store.phase else { return XCTFail(store.scanError ?? "opening timeout") }
        XCTAssertFalse(store.hasArchiveFolders)
        store.showBrowser = true
        store.archiveLeadingPane = .folders
        for mode in [ViewMode.gallery, .grid] {
            store.viewMode = mode
            try await capture(store, defaults: defaults, output: URL(fileURLWithPath: path),
                name: "flat-\(mode.rawValue)", width: 900, scheme: .light)
        }
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
        XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent("PHOTO.png")), bytes)
    }

    private func capture(_ store: SessionStore, defaults: UserDefaults, output: URL,
                         name: String, width: Double, scheme: ColorScheme,
                         direction: LayoutDirection = .leftToRight) async throws {
        let host = NSHostingView(rootView: SessionView(store: store)
            .defaultAppStorage(defaults).preferredColorScheme(scheme)
            .environment(\.layoutDirection, direction)
            .frame(width: width, height: 700).background(Color.appBackground)
            .tint(Color.louppeAccent).toggleStyle(LouppeToggleStyle()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
}
