import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Opt-in native captures of the folder pane header, Expand/Collapse All and
/// a realistic archive shape. Windows stay hidden; no global input.
@MainActor
final class ArchiveFolderHeaderVisualTests: XCTestCase {
    static let folders = [
        "2024/2024-06-14 Wedding/Ceremony", "2024/2024-06-14 Wedding/Reception",
        "2024/2024-09 Street", "2025/01 January", "2025/02 February",
        "2025/A very long client delivery folder name with many words",
        "2026/Autumn", "2026/Summer", "Deep/Level 2/Level 3/Level 4/Level 5/Level 6/Level 7",
        "Scans", "Empty folder",
    ]

    func testCaptureFolderHeaderStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_ARCHIVE_SNAPSHOTS"] else {
            throw XCTSkip("Set LOUPPE_ARCHIVE_SNAPSHOTS for native archive navigation captures.")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-HeaderVisual-\(UUID())")
        let media = root.appendingPathComponent("Photo archive")
        let defaultsName = "Louppe-HeaderVisual-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        let bytes = try Self.photo()
        for folder in Self.folders {
            let directory = media.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard folder != "Empty folder" else { continue }
            for index in 1...3 {
                try bytes.write(to: directory.appendingPathComponent(String(format: "IMG_%04d.png", index)))
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
        XCTAssertTrue(store.hasArchiveFolders)

        // Finished folders show a quiet completion mark beside their count.
        for (index, item) in store.items.enumerated()
            where item.primaryFile.id.hasPrefix("2025/01%20January/") || item.primaryFile.id.hasPrefix("Scans/")
                || item.primaryFile.id.hasPrefix("2024/2024-06-14%20Wedding/Ceremony/") {
            store.rate(index.isMultiple(of: 2) ? .yes : .no, at: index)
        }
        store.viewMode = .gallery
        store.showLeadingPane(.folders)
        XCTAssertTrue(store.canExpandAllArchiveFolders)
        XCTAssertFalse(store.canCollapseAllArchiveFolders)
        for scheme in [ColorScheme.light, .dark] {
            try await capture(store, defaults: defaults, output: output, name: "header-collapsed-\(scheme)", scheme: scheme)
        }
        store.expandAllArchiveFolders()
        XCTAssertFalse(store.canExpandAllArchiveFolders)
        XCTAssertTrue(store.canCollapseAllArchiveFolders)
        for scheme in [ColorScheme.light, .dark] {
            try await capture(store, defaults: defaults, output: output, name: "header-expanded-\(scheme)", scheme: scheme)
        }
        store.selectArchiveFolder("2024/2024-06-14%20Wedding/Reception")
        store.collapseAllArchiveFolders()
        XCTAssertEqual(store.archiveSelectedFolderID, "2024/2024-06-14%20Wedding/Reception")
        XCTAssertFalse(store.canCollapseAllArchiveFolders)
        try await capture(store, defaults: defaults, output: output, name: "header-collapsed-keeps-path", scheme: .dark)
        store.expandAllArchiveFolders()
        store.archiveFolderPaneWidth = ArchiveFolderPaneWidth.clamped(320)
        try await capture(store, defaults: defaults, output: output, name: "header-wide-pane", scheme: .light)
        store.archiveFolderPaneWidth = ArchiveFolderPaneWidth.clamped(10_000)
        XCTAssertEqual(store.archiveFolderPaneWidth, ArchiveFolderPaneWidth.range.upperBound)
        store.archiveFolderPaneWidth = ArchiveFolderPaneWidth.standard
        store.collapseAllArchiveFolders()
        store.showLeadingPane(.browser)
        XCTAssertEqual(store.viewMode, .gallery)
        try await capture(store, defaults: defaults, output: output, name: "header-browser", scheme: .light)
        store.viewMode = .grid
        store.toggleArchiveFolders()
        XCTAssertTrue(store.isLeadingPaneVisible)
        XCTAssertEqual(store.archiveLeadingPane, .folders)
        store.expandAllArchiveFolders()
        try await capture(store, defaults: defaults, output: output, name: "header-grid-rtl", scheme: .dark,
                          direction: .rightToLeft)
        store.showLeadingPane(.browser)
        XCTAssertEqual(store.viewMode, .gallery, "Browser from Grid returns to Gallery")
        XCTAssertTrue(store.isLeadingPaneVisible)

        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
        for folder in Self.folders where folder != "Empty folder" {
            for index in 1...3 {
                XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(folder)
                    .appendingPathComponent(String(format: "IMG_%04d.png", index))), bytes)
            }
        }
    }

    private static func photo() throws -> Data {
        let image = NSImage(size: NSSize(width: 300, height: 200))
        image.lockFocus()
        NSColor(calibratedRed: 0.25, green: 0.33, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 300, height: 200)).fill()
        NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 100, y: 50, width: 100, height: 100)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func capture(_ store: SessionStore, defaults: UserDefaults, output: URL,
                         name: String, scheme: ColorScheme,
                         direction: LayoutDirection = .leftToRight) async throws {
        let host = NSHostingView(rootView: SessionView(store: store)
            .defaultAppStorage(defaults).preferredColorScheme(scheme)
            .environment(\.layoutDirection, direction)
            .frame(width: 1000, height: 560).background(Color.appBackground)
            .tint(Color.louppeAccent).toggleStyle(LouppeToggleStyle()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560),
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
