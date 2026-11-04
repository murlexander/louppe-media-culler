import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Opt-in design-review captures of the main culling surfaces with real photographs.
/// Windows stay offscreen and unfocused; no input is sent. Photos are copied to a
/// disposable folder first, so the source folder is only read.
/// LOUPPE_UI_SNAPSHOTS=/private/tmp/louppe-ui-review \
/// LOUPPE_UI_SAMPLE_PHOTOS=<folder of JPEGs> \
/// swift test --disable-keychain --build-system native --filter CullingShowcaseVisualTests
@MainActor
final class CullingShowcaseVisualTests: XCTestCase {
    func testCaptureCullingSurfacesWithRealPhotos() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["LOUPPE_UI_SNAPSHOTS"], !outputPath.isEmpty,
              let samplesPath = env["LOUPPE_UI_SAMPLE_PHOTOS"], !samplesPath.isEmpty else {
            throw XCTSkip("Set LOUPPE_UI_SNAPSHOTS and LOUPPE_UI_SAMPLE_PHOTOS for showcase captures.")
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let samples = try fm.contentsOfDirectory(at: URL(fileURLWithPath: samplesPath), includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(samples.isEmpty, "No JPEG samples in \(samplesPath)")
        let root = fm.temporaryDirectory.appendingPathComponent("Louppe-Showcase-\(UUID())", isDirectory: true)
        let media = root.appendingPathComponent("2026.10 Canada", isDirectory: true)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "Louppe.CullingShowcaseVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        defaults.set(true, forKey: EarlyUserFeedback.shownKey)
        defaults.set(false, forKey: "louppe.showQuickStart")
        ReviewPreferences(advancesAfterDecision: false).save(to: defaults)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            photosDecisions: PhotosReviewDecisions(directory: root.appendingPathComponent("Decisions")),
            operationJournalDirectory: root.appendingPathComponent("Journals"),
            reviewDefaults: defaults
        )

        // A realistic mix: picks with stars/labels, rejects, undecided, a few quality cues.
        let lenses = ["XF 23mm F2 R WR", "XF 56mm F1.2 R", "XF 16-80mm F4 R OIS WR"]
        var items: [PhotoItem] = []
        for (index, sample) in samples.enumerated() {
            let name = String(format: "DSCF%04d.JPG", 3710 + index * 7)
            let url = media.appendingPathComponent(name)
            try fm.copyItem(at: sample, to: url)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let rating: Rating = [0, 3, 5, 8, 11].contains(index) ? .yes
                : [2, 6, 9, 13].contains(index) ? .no : .undecided
            let stars: StarRating? = index == 0 ? .five : index == 3 ? .four : index == 8 ? .three : nil
            let label: PhotoColorLabel? = index == 0 ? .purple : index == 5 ? .green : nil
            items.append(PhotoItem(
                id: name, primaryURL: url, pairedURL: nil,
                captureDate: Date(timeIntervalSince1970: 1_792_660_000 + Double(index) * 1_731 + Double(index / 6) * 86_400),
                cameraModel: "FUJIFILM X-T5", lensModel: lenses[index % lenses.count],
                aperture: [2.0, 5.6, 8.0, 1.2][index % 4], shutterSpeed: index == 6 ? 1.0 / 15.0 : 1.0 / 250.0,
                iso: index == 4 ? 6400 : 200, fileSize: size,
                rating: rating, starRating: stars, colorLabel: label
            ))
        }
        store.recentFolders = [media]
        let drives = ConnectedDrivesStore(loader: { [] })

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .light ? "light" : "dark"
            store.phase = .welcome
            try await capture(WelcomeView(store: store, connectedDrives: drives), name: "welcome-\(suffix)",
                              size: CGSize(width: 680, height: 470), scheme: scheme, defaults: defaults, output: output)
            store.items = items
            store.phase = .ready
            store.rebuildDerivedDataForTesting(sourceFolder: media)
            store.showBrowser = true
            store.showMetadataPanel = true
            store.isGroupingEnabled = true
            store.viewMode = .gallery
            try await capture(SessionView(store: store), name: "gallery-info-\(suffix)",
                              size: CGSize(width: 1440, height: 900), scheme: scheme, defaults: defaults, output: output)
            store.showMetadataPanel = false
            try await capture(SessionView(store: store), name: "gallery-browser-\(suffix)",
                              size: CGSize(width: 1440, height: 900), scheme: scheme, defaults: defaults, output: output)
            store.showMetadataPanel = true
            store.viewMode = .grid
            try await capture(SessionView(store: store), name: "grid-info-\(suffix)",
                              size: CGSize(width: 1512, height: 900), scheme: scheme, defaults: defaults, output: output)
            store.showMetadataPanel = false
            store.isGroupingEnabled = false
            try await capture(SessionView(store: store), name: "grid-\(suffix)",
                              size: CGSize(width: 1440, height: 900), scheme: scheme, defaults: defaults, output: output)
            store.isGroupingEnabled = true
            store.showMetadataPanel = true
            try await capture(FilterView(store: store), name: "filter-\(suffix)",
                              size: CGSize(width: 340, height: 560), scheme: scheme, defaults: defaults, output: output)
            try await capture(ActionPaletteView(store: store), name: "palette-\(suffix)",
                              size: CGSize(width: 560, height: 480), scheme: scheme, defaults: defaults, output: output)
            store.items = []
            store.viewMode = .gallery
        }
    }

    private func capture<V: View>(
        _ view: V, name: String, size: CGSize, scheme: ColorScheme, defaults: UserDefaults, output: URL
    ) async throws {
        let host = NSHostingView(rootView: view
            .defaultAppStorage(defaults)
            .preferredColorScheme(scheme)
            .localizedInterface()
            .environment(\.layoutDirection, L10n.isRightToLeft ? .rightToLeft : .leftToRight)
            .frame(width: size.width, height: size.height)
            .background(Color.appBackground)
            .tint(Color.louppeAccent)
            .toggleStyle(LouppeToggleStyle()))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        // Hosted collection cells resolve colors from the app appearance.
        NSApp.appearance = window.appearance
        defer { window.contentView = nil; window.close() }
        // Real JPEG thumbnails and previews decode asynchronously; give them time.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTAssertFalse(window.isVisible, "Visual fixtures must remain offscreen.")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("real-\(name).png"))
    }
}
