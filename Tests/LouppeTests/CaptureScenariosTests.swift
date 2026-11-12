import AppKit
import SwiftUI
import XCTest
#if !APP_STORE
import Sparkle
#endif
@testable import Louppe

/// Named, disposable, opt-in layout captures. Entry point: Scripts/capture_ui.sh.
@MainActor
final class CaptureScenariosTests: XCTestCase {
    private struct Surface {
        let view: AnyView
        let size: CGSize
        var requiresToolbar = false
        var settingsTab: Int?
    }

    private struct Scenario {
        let name: String
        let description: String
        let builder: (Fixture) throws -> Surface
    }

    // --list reads these literal name/description lines without compiling Swift.
    private static let registry: [Scenario] = [
        Scenario(name: "session-grid-ready", description: "Ready Grid session with toolbar, generated photos and fixture video.") { fixture in
            fixture.ready(mode: .grid)
            return Surface(view: AnyView(SessionView(store: fixture.store)), size: CGSize(width: 1280, height: 800), requiresToolbar: true)
        },
        Scenario(name: "session-gallery-ready", description: "Ready Gallery session with toolbar, Browser and Info.") { fixture in
            fixture.ready(mode: .gallery)
            return Surface(view: AnyView(SessionView(store: fixture.store)), size: CGSize(width: 1280, height: 800), requiresToolbar: true)
        },
        Scenario(name: "welcome-recent", description: "Welcome with recent disposable folders and no connected drives.") { try $0.welcome(recent: true, drives: false) },
        Scenario(name: "welcome-drives", description: "Welcome with synthetic connected drives and no recent folders.") { try $0.welcome(recent: false, drives: true) },
        Scenario(name: "welcome-both", description: "Welcome with recent folders and synthetic connected drives.") { try $0.welcome(recent: true, drives: true) },
        Scenario(name: "welcome-empty", description: "Welcome with no recent folders, pins or connected drives.") { try $0.welcome(recent: false, drives: false) },
        Scenario(name: "settings-general", description: "Native Settings window on its General page (scrollable content starts at top).") { fixture in
            Surface(view: fixture.settings(), size: CGSize(width: 620, height: 600), settingsTab: 0)
        },
        Scenario(name: "settings-shortcuts", description: "Native Settings window on its Keyboard shortcuts page.") { fixture in
            Surface(view: fixture.settings(), size: CGSize(width: 620, height: 600), settingsTab: 1)
        },
        Scenario(name: "popover-filter", description: "Production Filter popover content over disposable session data.") { fixture in
            fixture.ready(mode: .grid)
            return Surface(view: AnyView(FilterView(store: fixture.store)), size: CGSize(width: 340, height: 560))
        },
        Scenario(name: "popover-sort", description: "Production Sort popover content over disposable session data.") { fixture in
            fixture.ready(mode: .grid)
            return Surface(view: AnyView(SortView(store: fixture.store)), size: CGSize(width: 340, height: 480))
        },
        Scenario(name: "session-opening", description: "Deterministic read-only opening session with partially ready metadata and toolbar.") { fixture in
            let inventory = fixture.items.map { item in
                PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL,
                    captureDate: nil, cameraModel: nil, lensModel: nil,
                    mediaKind: item.mediaKind, fileSize: item.fileSize,
                    scannedIdentity: item.primaryFile.scannedIdentity, metadataIsLoaded: false))
            }
            let opening = OpeningSessionState(snapshot: .init(items: inventory), viewMode: .grid, sourceAccess: nil)
            let ready = inventory.prefix(4).map { item in
                PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL,
                    captureDate: Date(timeIntervalSince1970: 1_792_440_000),
                    cameraModel: "Synthetic camera", lensModel: "23 mm fixture lens",
                    fileSize: item.fileSize, scannedIdentity: item.primaryFile.scannedIdentity))
            }
            XCTAssertEqual(opening.applyMetadata(ready.map { OpeningMetadataUpdate(item: $0) }), 4)
            fixture.store.presentOpeningSessionForTesting(opening)
            return Surface(view: AnyView(SessionView(store: fixture.store)), size: CGSize(width: 1280, height: 800), requiresToolbar: true)
        },
        Scenario(name: "sheet-rename", description: "Rename setup with generated photos and video; native grouped form and fixed actions.") { fixture in
            fixture.ready(mode: .gallery)
            return Surface(view: AnyView(RenameFilesView(store: fixture.store)), size: CGSize(width: 680, height: 650))
        },
        Scenario(name: "sheet-organize", description: "Organize setup with generated photos and video; native grouped form and fixed actions.") { fixture in
            fixture.ready(mode: .gallery)
            return Surface(view: AnyView(OrganizeSourceView(store: fixture.store)), size: CGSize(width: 680, height: 650))
        },
        Scenario(name: "session-recovery-warning", description: "Production interrupted-operation warning with distinct remedies over a disposable Gallery session.") { fixture in
            fixture.ready(mode: .gallery)
            var report = FileOperationJournal.RecoveryReport()
            report.unresolvedOperations = 1
            report.unresolvedFiles = 1
            report.details = ["A file changed since the operation began."]
            fixture.store.presentOperationRecoveryReportForTesting(report)
            return Surface(view: AnyView(RootView(store: fixture.store)), size: CGSize(width: 1280, height: 800), requiresToolbar: true)
        }
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let output = ProcessInfo.processInfo.environment["LOUPPE_CAPTURE_OUTPUT"], !output.isEmpty else {
            throw XCTSkip("Set LOUPPE_CAPTURE_OUTPUT or use Scripts/capture_ui.sh for opt-in screenshots.")
        }
    }

    func testCaptureNamedScenarios() async throws {
        let env = ProcessInfo.processInfo.environment
        if env["LOUPPE_CAPTURE_LIST"] == "1" {
            for scenario in Self.registry { print("\(scenario.name)\t\(scenario.description)") }
            return
        }
        let output = URL(fileURLWithPath: try XCTUnwrap(env["LOUPPE_CAPTURE_OUTPUT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let appearanceName = env["LOUPPE_CAPTURE_APPEARANCE"] ?? "both"
        let appearances: [OffscreenCapture.Appearance]
        if appearanceName == "both" { appearances = [.light, .dark] }
        else { appearances = [try XCTUnwrap(OffscreenCapture.Appearance(rawValue: appearanceName), "Expected light, dark or both")] }
        let pair = env["LOUPPE_CAPTURE_PAIR"].flatMap { value in
            value.isEmpty ? nil : value.components(separatedBy: ",")
        }
        if let pair {
            guard pair.count == 2, pair.allSatisfy({ name in Self.registry.contains { $0.name == name } }) else {
                throw CaptureError.invalidSelection("Pair mode requires two exact scenario names")
            }
        }
        let patterns = (env["LOUPPE_CAPTURE_SCENARIOS"] ?? "*").components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for pattern in patterns where pair == nil {
            guard Self.registry.contains(where: { Self.matches($0.name, pattern: pattern) }) else {
                throw CaptureError.invalidSelection("No scenario matches '\(pattern)'; use --list")
            }
        }
        let selected = Self.registry.filter { scenario in
            pair?.contains(scenario.name) ?? patterns.contains { Self.matches(scenario.name, pattern: $0) }
        }
        guard !selected.isEmpty else { throw CaptureError.invalidSelection("No scenarios selected") }
        let metadata = try repositoryMetadata()
        var entries: [(file: String, name: String, description: String, appearance: String)] = []
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for appearance in appearances {
            for scenario in selected {
                let fixture = try Fixture()
                defer { fixture.cleanUp() }
                let surface = try scenario.builder(fixture)
                let controller = OffscreenCapture.host(surface.view, defaults: fixture.defaults,
                    appearance: appearance, bridgesScene: surface.settingsTab == nil)
                let file = "\(scenario.name)-\(appearance.rawValue).png"
                try await OffscreenCapture.capture(controller, size: surface.size, title: scenario.name,
                    appearance: appearance, to: output.appendingPathComponent(file), requiresToolbar: surface.requiresToolbar) { controller in
                    if let tab = surface.settingsTab {
                        guard tab != 0 else { return }
                        let root = controller.view.window?.contentView?.superview ?? controller.view
                        let views = OffscreenCapture.descendants(of: root)
                        if let tabs = views.compactMap({ $0 as? NSTabView }).first {
                            XCTAssertEqual(tabs.tabViewItems.count, 2)
                            tabs.selectTabViewItem(at: tab)
                        } else {
                            // Newer macOS hosts TabView's pages behind a native
                            // title-bar segmented control instead of NSTabView.
                            let selector = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }
                                .first { $0.segmentCount == 2 })
                            selector.selectedSegment = tab
                            XCTAssertTrue(selector.sendAction(selector.action, to: selector.target),
                                          "Settings tab selection action did not reach SwiftUI")
                        }
                    }
                }
                entries.append((file, scenario.name, scenario.description, appearance.rawValue))
            }
            if let pair {
                let file = "pair-\(pair[0])-\(pair[1])-\(appearance.rawValue).png"
                try writePair(pair, appearance: appearance, output: output, file: file)
                entries.append((file, "\(pair[0]) + \(pair[1])", "Top-aligned comparison of two production surfaces.", appearance.rawValue))
            }
        }
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Alex may change applications during a run. Log the evidence without treating
        // his own app switch as a capture failure; the per-window fuse is authoritative.
        print("CAPTURE FRONTMOST before=\(frontmostBefore ?? -1) after=\(frontmostAfter ?? -1) unchanged=\(frontmostBefore == frontmostAfter)")
        XCTAssertFalse(NSApp.isActive)
        XCTAssertTrue(NSApp.windows.filter(\.isVisible).allSatisfy { window in
            NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }
        }, "Capture left a visible test window on a display")
        print("CAPTURE TEARDOWN: no visible test windows intersect any display")
        let warning = "Offscreen captures show the inactive window appearance (grey traffic lights, muted selection). Use them for layout review only, never for Store, website or README images."
        let notes = "Generated disposable fixtures only. Settings show the top of each scrollable pane. Native Liquid Glass selected tabs can cache as black pills offscreen, obscuring the selected tab label; pane content remains visible."
        try "\(warning)\n\n\(metadata)\n\n\(notes)\n".write(to: output.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let cards = entries.map { entry in
            "<figure><a href=\"\(entry.file)\"><img loading=\"lazy\" src=\"\(entry.file)\" alt=\"\(entry.name) \(entry.appearance)\"></a><figcaption><strong>\(entry.name) · \(entry.appearance)</strong><p>\(entry.description)</p></figcaption></figure>"
        }.joined(separator: "\n")
        let html = """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Louppe offscreen layout captures</title><style>body{font:15px system-ui;margin:24px;background:#eee;color:#222}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:20px}figure{margin:0;padding:12px;background:white;border-radius:8px}img{width:100%;height:auto}figcaption{margin-top:10px}p{line-height:1.4}pre{white-space:pre-wrap}</style>
        <h1>Louppe layout captures</h1><p>\(warning)</p><pre>\(metadata)</pre><p>\(notes)</p><main>\(cards)</main></html>
        """
        try html.write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private static func matches(_ name: String, pattern: String) -> Bool {
        let regex = "^" + pattern.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        return name.range(of: regex, options: .regularExpression) != nil
    }

    private func repositoryMetadata() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func git(_ arguments: [String]) throws -> String {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments = ["-C", root.path] + arguments
            let pipe = Pipe()
            task.standardOutput = pipe
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw CaptureError.metadata }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        let sha = try git(["rev-parse", "HEAD"])
        let count = try git(["status", "--short"]).split(separator: "\n").count
        return "Commit: \(sha)\nGit status --short: \(count) entries (\(count == 0 ? "clean" : "dirty"))"
    }

    private func writePair(_ pair: [String], appearance: OffscreenCapture.Appearance, output: URL, file: String) throws {
        let images = try pair.map { name in
            try XCTUnwrap(NSImage(contentsOf: output.appendingPathComponent("\(name)-\(appearance.rawValue).png")))
        }
        let gap: CGFloat = 16
        let header: CGFloat = 32
        let size = CGSize(width: images[0].size.width + images[1].size.width + gap * 3,
                          height: max(images[0].size.height, images[1].size.height) + header + gap * 2)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // NSGraphicsContext already maps bitmap.size points to its 2× pixels.
        (appearance == .dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill()
        NSRect(origin: .zero, size: size).fill()
        var x = gap
        for (index, image) in images.enumerated() {
            let y = size.height - gap - header - image.size.height
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))
            (pair[index] as NSString).draw(at: NSPoint(x: x, y: size.height - gap - 19), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: appearance == .dark ? NSColor.white : NSColor.black
            ])
            x += image.size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(file), options: .atomic)
    }

    private enum CaptureError: Error { case invalidSelection(String), metadata }

    @MainActor
    private final class Fixture {
        let root: URL
        let media: URL
        let defaults: UserDefaults
        let store: SessionStore
        var items: [PhotoItem] = []
        var drives: ConnectedDrivesStore?
        #if !APP_STORE
        private let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #endif

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("Louppe-Capture-\(UUID())", isDirectory: true)
            media = root.appendingPathComponent("Disposable photos", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            // Registration is volatile. Captures do not edit preference bindings.
            defaults = try XCTUnwrap(UserDefaults(suiteName: "Louppe.Capture.\(UUID())"))
            defaults.register(defaults: [EarlyUserFeedback.shownKey: true,
                "louppe.showQuickStart": false, CameraQualityWarningPreferences.Keys.isEnabled: false,
                ReviewPreferences.Keys.advancesAfterDecision: false])
            store = SessionStore(
                persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
                photosDecisions: PhotosReviewDecisions(directory: root.appendingPathComponent("Decisions")),
                operationJournalDirectory: root.appendingPathComponent("Journals"), reviewDefaults: defaults,
                pinnedFolders: PinnedFoldersStore(storageDirectory: root.appendingPathComponent("Pins"), observesSystemChanges: false),
                archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("Navigation.json")))
            for index in 0..<9 {
                let name = String(format: "PHOTO_%04d.png", index + 1)
                let url = media.appendingPathComponent(name)
                let data = try Self.image(index: index)
                try data.write(to: url)
                items.append(PhotoItem(id: name, primaryURL: url, pairedURL: nil,
                    captureDate: Date(timeIntervalSince1970: 1_792_440_000 + Double(index) * 60),
                    cameraModel: "Synthetic camera", lensModel: "23 mm fixture lens", aperture: 5.6,
                    shutterSpeed: 1.0 / 250, iso: 200, fileSize: Int64(data.count),
                    rating: index % 3 == 0 ? .yes : index % 3 == 1 ? .no : .undecided,
                    starRating: index % 3 == 0 ? .four : nil, colorLabel: index == 0 ? .purple : nil))
            }
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let video = repository.appendingPathComponent("Tests/Fixtures/AccessibilityMedia/captioned-described.mov")
            let videoURL = media.appendingPathComponent("VIDEO_001.mov")
            try FileManager.default.copyItem(at: video, to: videoURL)
            items.append(PhotoItem(id: "VIDEO_001.mov", primaryURL: videoURL, pairedURL: nil,
                captureDate: Date(timeIntervalSince1970: 1_792_441_000), cameraModel: "Synthetic camera", lensModel: nil,
                mediaKind: .video, duration: 8, videoDimensions: CGSize(width: 640, height: 360),
                videoIsPlayable: true, fileSize: 1))
        }

        func ready(mode: ViewMode) {
            store.items = items
            store.phase = .ready
            store.isGroupingEnabled = false
            store.rebuildDerivedDataForTesting(sourceFolder: media)
            store.viewMode = mode
            store.showBrowser = true
            store.showMetadataPanel = true
        }

        func welcome(recent: Bool, drives showsDrives: Bool) throws -> Surface {
            if recent {
                store.recentFolders = try ["Disposable photos", "Weekend review", "Studio selects"].map { name in
                    let url = root.appendingPathComponent(name, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    return url
                }
            }
            let mounted: [ConnectedDrive] = try (showsDrives ? ["CAMERA CARD", "PHOTO ARCHIVE"] : []).enumerated().map { index, name in
                let url = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return ConnectedDrive(id: .init(volumeUUID: "capture-\(index)", mediaUUID: nil,
                    bsdName: "capture\(index)", mountURL: url), name: name,
                    availableBytes: 32_000_000_000, totalBytes: 64_000_000_000, isRemovable: index == 0)
            }
            let drives = ConnectedDrivesStore(loader: { mounted })
            self.drives = drives
            return Surface(view: AnyView(WelcomeView(store: store, availableScreenWidth: 900, connectedDrives: drives)),
                           size: CGSize(width: 760, height: 600))
        }

        func settings() -> AnyView {
            #if APP_STORE
            AnyView(LouppeSettingsView(store: store))
            #else
            AnyView(LouppeSettingsView(store: store, updater: updater.updater))
            #endif
        }

        func cleanUp() {
            drives?.stop()
            store.beginTerminationPreparation()
            try? FileManager.default.removeItem(at: root)
        }

        // Same generated mountain fixture idiom as UIConsistencyVisualTests.
        private static func image(index: Int) throws -> Data {
            let image = NSImage(size: CGSize(width: 900, height: 600))
            image.lockFocus()
            NSColor(calibratedHue: 0.5 + Double(index) * 0.018, saturation: 0.3, brightness: 0.8, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 900, height: 600).fill()
            NSColor(calibratedHue: 0.2 + Double(index) * 0.01, saturation: 0.4, brightness: 0.45, alpha: 1).setFill()
            let mountain = NSBezierPath()
            mountain.move(to: .zero)
            mountain.line(to: NSPoint(x: 300, y: 440 - index * 8))
            mountain.line(to: NSPoint(x: 580, y: 180))
            mountain.line(to: NSPoint(x: 750, y: 360))
            mountain.line(to: NSPoint(x: 900, y: 0))
            mountain.close()
            mountain.fill()
            image.unlockFocus()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
    }
}
