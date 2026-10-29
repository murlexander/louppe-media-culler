import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Opt-in evidence capture, not a pixel-baseline test. Windows are never ordered,
/// activated, or made key. No input is sent and no real Photos library is used.
/// Recovery and completed file-tool states use only generated disposable media.
/// Parent runner: LOUPPE_UI_SNAPSHOTS=/private/tmp/louppe-ui-review
/// swift test --disable-keychain --build-system native --filter UIConsistencyVisualTests
@MainActor
final class UIConsistencyVisualTests: XCTestCase {
    func testCaptureRepresentativeSurfacesWithoutForegroundControl() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["LOUPPE_UI_SNAPSHOTS"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set LOUPPE_UI_SNAPSHOTS to opt into offscreen review captures.")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe-UIConsistency-\(UUID())", isDirectory: true)
        let media = root.appendingPathComponent("Disposable media", isDirectory: true)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "Louppe.UIConsistencyVisualTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: EarlyUserFeedback.shownKey)
        defaults.set(false, forKey: "louppe.showQuickStart")
        ReviewPreferences(advancesAfterDecision: false).save(to: defaults)
        let client = VisualPhotosLibrary()
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            photosDecisions: PhotosReviewDecisions(directory: root.appendingPathComponent("Decisions")),
            photosLibrary: client,
            operationJournalDirectory: root.appendingPathComponent("Journals"),
            reviewDefaults: defaults
        )
        let sourceImage = try makeImage()
        let transportBackdrop = try XCTUnwrap(NSImage(data: sourceImage))
        var items: [PhotoItem] = []
        for index in 0..<48 {
            let name = index == 0
                ? "A long camera filename for checking Info and preview truncation 0001.png"
                : String(format: "PHOTO_%04d.png", index + 1)
            let url = media.appendingPathComponent(name)
            try sourceImage.write(to: url)
            items.append(PhotoItem(
                id: name, primaryURL: url, pairedURL: nil,
                captureDate: Date(timeIntervalSince1970: 1_792_440_000 + Double(index / 4) * 86_400),
                cameraModel: "FUJIFILM X-T5", lensModel: "XF 23mm F2 R WR",
                aperture: 5.6, shutterSpeed: 1.0 / 30.0, iso: index == 0 ? 6400 : 200,
                fileSize: Int64(sourceImage.count),
                rating: index % 3 == 0 ? .yes : index % 3 == 1 ? .no : .undecided,
                starRating: index % 3 == 0 ? .four : nil,
                colorLabel: index % 3 == 0 ? .purple : nil
            ))
        }
        store.recentFolders = [media]
        let drives = ConnectedDrivesStore(loader: { [] })

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            store.phase = .welcome
            try await capture(WelcomeView(store: store, connectedDrives: drives),
                              name: "welcome-\(suffix)", size: CGSize(width: 680, height: 470),
                              scheme: scheme, defaults: defaults, output: output)
            store.items = items
            store.phase = .ready
            store.rebuildDerivedDataForTesting(sourceFolder: media)
            store.showBrowser = true
            store.showMetadataPanel = true
            store.viewMode = .gallery
            try await capture(SessionView(store: store), name: "gallery-info-\(suffix)",
                              size: CGSize(width: 1200, height: 760), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(MetadataEditingControls(store: store).padding(12),
                              name: "accessibility-rating-targets-\(suffix)",
                              size: CGSize(width: 280, height: 180), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(MetadataBadgeStrip(starRatingState: .stars(.four),
                                                colorLabelState: .label(.purple), showsColorNames: true).padding(12),
                              name: "accessibility-differentiate-color-\(suffix)",
                              size: CGSize(width: 260, height: 140), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(HStack {
                Button(L10n.text("Fit")) {}.buttonStyle(.borderless)
                Slider(value: .constant(0.5), in: 0...1).frame(width: 120)
            }.padding(12).modifier(FloatingControlSurface(shape: Capsule(), reduceTransparency: true, contrast: .increased)),
                              name: "accessibility-opaque-zoom-\(suffix)",
                              size: CGSize(width: 340, height: 100), scheme: scheme,
                              defaults: defaults, output: output)
            defaults.set(TextPreviewSize.largest.rawValue, forKey: TextPreviewSize.preferenceKey)
            try await capture(NativeTextPreview(text: AttributedString("Document text at 200%.\nLong lines wrap inside the native text view."),
                                                filename: "Disposable document.txt"),
                              name: "accessibility-text-200-percent-\(suffix)",
                              size: CGSize(width: 500, height: 300), scheme: scheme,
                              defaults: defaults, output: output)
            defaults.removeObject(forKey: TextPreviewSize.preferenceKey)
            store.viewMode = .grid
            store.isGroupingEnabled = false
            try await capture(SessionView(store: store), name: "grid-info-wide-\(suffix)",
                              size: CGSize(width: 1512, height: 850), scheme: scheme,
                              defaults: defaults, output: output)
            store.isGroupingEnabled = true
            try await capture(FilterView(store: store), name: "filter-\(suffix)",
                              size: CGSize(width: 340, height: 560), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(SortView(store: store), name: "sort-\(suffix)",
                              size: CGSize(width: 380, height: 560), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(ExportView(store: store), name: "export-summary-\(suffix)",
                              size: CGSize(width: 640, height: 620), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(RenameFilesView(store: store), name: "rename-setup-\(suffix)",
                              size: CGSize(width: 680, height: 650), scheme: scheme,
                              defaults: defaults, output: output)
            store.presentSingleFileRenaming(itemID: items[0].id)
            store.isRenamePresented = false
            try await capture(RenameFilesView(store: store), name: "rename-single-\(suffix)",
                              size: CGSize(width: 540, height: 460), scheme: scheme,
                              defaults: defaults, output: output)
            store.presentMetadataFileRenaming()
            store.isRenamePresented = false
            try await capture(OrganizeSourceView(store: store), name: "organize-setup-\(suffix)",
                              size: CGSize(width: 680, height: 650), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(SessionRecoveryView(store: store), name: "saved-decisions-empty-\(suffix)",
                              size: CGSize(width: 660, height: 620), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(LouppeHelpView(), name: "help-\(suffix)",
                              size: CGSize(width: 640, height: 600), scheme: scheme,
                              defaults: defaults, output: output)
            try await capture(LouppeHelpView(), name: "help-search-\(suffix)",
                              size: CGSize(width: 640, height: 600), scheme: scheme,
                              defaults: defaults, output: output, revealSearch: true)
            try await capture(LouppeSettingsForm { ReviewShortcutsSettingsView() },
                              name: "shortcut-editor-\(suffix)", size: CGSize(width: 620, height: 700),
                              scheme: scheme, defaults: defaults, output: output, revealSearch: true)
            let transport = VideoPlaybackController()
            // Render the production transport over a generated still. This
            // fixture does not play media or claim live glass compositing.
            let transportItem = PhotoItem(
                id: "Disposable video.mov", primaryURL: media.appendingPathComponent("Disposable video.mov"),
                pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil,
                mediaKind: .video, duration: 90, videoDimensions: CGSize(width: 900, height: 600),
                videoIsPlayable: true, fileSize: 1
            )
            for width in [700.0, 380.0] {
                    try await capture(ZStack(alignment: .bottom) {
                        Image(nsImage: transportBackdrop)
                            .resizable().scaledToFill()
                            .frame(width: width, height: 260).clipped()
                        GalleryMediaTransportView(
                            item: transportItem, playback: transport,
                            isScrubbing: .constant(false), scrubPosition: .constant(0),
                            volume: .constant(1), isMuted: .constant(false), compact: false
                        )
                        .padding(18)
                    }
                    .clipped(),
                        name: "video-transport-\(Int(width))-glass-\(suffix)",
                        size: CGSize(width: width, height: 260), scheme: scheme,
                        defaults: defaults, output: output)
            }
            // This view reads standard ReviewPreferences for its initial display;
            // capturing never invokes its preference-writing bindings.
            try await capture(LouppeSettingsForm { ReviewPreferencesSettingsView() },
                              name: "settings-review-\(suffix)", size: CGSize(width: 620, height: 600),
                              scheme: scheme, defaults: defaults, output: output)
            try await capture(LouppeSettingsForm {
                CameraQualityWarningsSettingsView()
                LouppeGetStartedSettingsView { _ in }
            }, name: "settings-cues-help-\(suffix)", size: CGSize(width: 620, height: 600),
                              scheme: scheme, defaults: defaults, output: output)
            try await capture(ActionPaletteView(store: store), name: "palette-\(suffix)",
                              size: CGSize(width: 560, height: 480), scheme: scheme,
                              defaults: defaults, output: output)

            await store.photosBrowser.load()
            try await capture(PhotosLibraryView(store: store, browser: store.photosBrowser),
                              name: "photos-chooser-\(suffix)", size: CGSize(width: 540, height: 560),
                              scheme: scheme, defaults: defaults, output: output)
            store.photosBrowser.query.startDate = Date(timeIntervalSince1970: 1_791_676_800)
            store.photosBrowser.query.endDate = Date(timeIntervalSince1970: 1_792_540_800)
            await store.photosBrowser.load()
            try await capture(PhotosLibraryView(store: store, browser: store.photosBrowser),
                              name: "photos-dates-\(suffix)", size: CGSize(width: 540, height: 560),
                              scheme: scheme, defaults: defaults, output: output)
            store.photosBrowser.isOpening = true // Suppress the chooser's automatic load for staged states.
            store.photosBrowser.progress = PhotosBatchProgress(completed: 12, total: 100, downloadFraction: 0.4)
            try await capture(PhotosLibraryView(store: store, browser: store.photosBrowser),
                              name: "photos-preparing-\(suffix)", size: CGSize(width: 540, height: 560),
                              scheme: scheme, defaults: defaults, output: output)
            store.photosBrowser.progress = nil
            store.photosBrowser.isOpening = false
            let organization = PhotosOrganizationReviewModel(hierarchy: [
                .init(id: "folder", title: "Archive", parentIdentifier: nil,
                      kind: .folder, canAddAssets: false, canCreateAlbum: true),
                .init(id: "album", title: "Disposable review album", parentIdentifier: "folder",
                      kind: .album, canAddAssets: true, canCreateAlbum: false)],
                scopeCounts: [.all: 8_013, .filtered: 100, .selected: 1], phase: .choosing)
            organization.choices = try PhotosOrganizationChoices.prepare(organization.hierarchy)
            try await capture(PhotosOrganizationView(model: organization, onConfirm: { _ in },
                              onCancelWork: {}, onDismiss: {}, onReload: {}),
                              name: "photos-album-organization-\(suffix)", size: CGSize(width: 560, height: 510),
                              scheme: scheme, defaults: defaults, output: output)
            await client.setAuthorizationDenied(true)
            await store.photosBrowser.load()
            try await capture(PhotosLibraryView(store: store, browser: store.photosBrowser),
                              name: "photos-permission-denied-\(suffix)", size: CGSize(width: 540, height: 560),
                              scheme: scheme, defaults: defaults, output: output)
            await client.setAuthorizationDenied(false)
            store.filter.searchText = "no matching disposable filename"
            store.rebuildDerivedDataForTesting()
            try await capture(GridView(store: store), name: "grid-filter-empty-\(suffix)",
                              size: CGSize(width: 900, height: 640), scheme: scheme,
                              defaults: defaults, output: output)
            store.resetFilter()
        }

        // Direction and contrast coverage; locale changes require a fresh process
        // because L10n chooses its catalog at launch.
        try await capture(FilterView(store: store), name: "filter-rtl-high-contrast-appearance",
                          size: CGSize(width: 340, height: 560), scheme: .dark,
                          defaults: defaults, output: output, direction: .rightToLeft, highContrastAppearance: true)
        store.zoomToFit()
        if let revision = store.currentItem?.contentRevision {
            store.reportFittedPhotoZoomScale(0.45, revision: revision, mode: .fit)
            store.reportPhotoRepresentation(.loadingPreview, revision: revision)
        }
        try await capture(PhotoZoomControl(store: store), name: "zoom-loading-rtl-high-contrast-appearance",
                          size: CGSize(width: 276, height: 60), scheme: .dark,
                          defaults: defaults, output: output, direction: .rightToLeft,
                          highContrastAppearance: true)
        try await captureRecoveryAndResults(root: root, image: sourceImage, defaults: defaults, output: output)
    }

    private func captureRecoveryAndResults(root: URL, image: Data, defaults: UserDefaults, output: URL) async throws {
        let folder = root.appendingPathComponent("Result fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Previous decision for a long camera filename 0001.png"
        let original = folder.appendingPathComponent(name)
        try image.write(to: original)
        let identity = try FileOperationJournal.captureIdentity(at: original)
        // A replacement at the same name keeps the old decision pending for
        // manual review, using the same validated records as a real session.
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("Previous original.png"))
        try image.write(to: original)
        let persistence = SessionPersistence(backupDirectory: root.appendingPathComponent("Result backups"))
        let previous = SessionEntry(filename: try XCTUnwrap(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)),
                                    pairedFilename: nil, rating: Rating.yes.rawValue,
                                    ratedAt: Date(), stars: .four, colorLabel: .purple, fileIdentity: identity)
        let saved = await persistence.save(SessionFile(
            version: 7, sourcePath: folder.path, scannedAt: Date(), entries: [],
            fileIDEncoding: .percentEncodedFileSystemPath,
            recoveryEntries: [SessionRecoveryEntry(entry: previous)]
        ), for: folder, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        let state = SessionStore(persistence: persistence,
                                 operationJournalDirectory: root.appendingPathComponent("Result journals"),
                                 reviewDefaults: defaults)
        state.openFolder(folder)
        try await waitUntil { if case .ready = state.phase { return true }; return false }
        XCTAssertFalse(state.pendingSessionRecoveryEntries.isEmpty)
        for scheme in [ColorScheme.light, .dark] {
            try await capture(SessionRecoveryView(store: state),
                              name: "saved-decisions-populated-\(scheme)", size: CGSize(width: 660, height: 620),
                              scheme: scheme, defaults: defaults, output: output)
        }
        state.presentSingleFileRenaming(itemID: try XCTUnwrap(state.currentItem?.id))
        let rename = try XCTUnwrap(state.sourceFileRenamingPlanningSnapshot(scope: .selected))
        let renamePlan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: rename.sourceFolder, selectedItems: rename.selectedItems,
            familyContextItems: rename.familyContextItems,
            configuration: FileRenamingPlanner.sourceConfiguration(customBaseName: "Reviewed"),
            knownOriginFolderPathBytesByFileID: rename.knownOriginFolderPathBytesByFileID)
        XCTAssertTrue(renamePlan.canExecute)
        state.startSourceRename(renamePlan)
        try await waitUntil { state.organizationOutcome != nil && !state.isFileOperationRunning }
        XCTAssertTrue(state.organizationOutcome?.succeeded == true)
        for scheme in [ColorScheme.light, .dark] {
            try await capture(RenameFilesView(store: state), name: "rename-result-\(scheme)",
                              size: CGSize(width: 540, height: 460), scheme: scheme, defaults: defaults, output: output)
        }
        state.isRenamePresented = false
        state.presentSourceOrganization()
        let organize = try XCTUnwrap(state.sourceOrganizationPlanningSnapshot(scope: .all))
        let organizePlan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: organize.sourceFolder, selectedItems: organize.selectedItems,
            familyContextItems: organize.familyContextItems,
            configuration: SourceOrganizationConfiguration(
                levels: [.init(kind: .decision, isEnabled: true)], dateGranularity: .day,
                existingFolderDepth: .topLevel, containerName: "Organized"),
            knownOriginFolderPathBytesByFileID: organize.knownOriginFolderPathBytesByFileID)
        XCTAssertTrue(organizePlan.canExecute)
        state.startSourceOrganization(organizePlan)
        try await waitUntil { state.organizationOutcome != nil && !state.isFileOperationRunning }
        XCTAssertTrue(state.organizationOutcome?.succeeded == true)
        for scheme in [ColorScheme.light, .dark] {
            try await capture(OrganizeSourceView(store: state), name: "organize-result-\(scheme)",
                              size: CGSize(width: 680, height: 650), scheme: scheme, defaults: defaults, output: output)
        }
        _ = await state.saveSessionForTermination()
        _ = await state.waitForPersistenceIdleForTesting()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Disposable fixture did not finish its operation.")
    }

    private func capture<V: View>(
        _ view: V, name: String, size: CGSize, scheme: ColorScheme,
        defaults: UserDefaults, output: URL, direction: LayoutDirection? = nil,
        highContrastAppearance: Bool = false, revealSearch: Bool = false
    ) async throws {
        let host = NSHostingView(rootView: view
            .defaultAppStorage(defaults)
            .preferredColorScheme(scheme)
            .localizedInterface()
            .environment(\.layoutDirection, direction ?? (L10n.isRightToLeft ? .rightToLeft : .leftToRight))
            .frame(width: size.width, height: size.height)
            .background(Color.appBackground)
            .tint(Color.louppeAccent)
            .toggleStyle(LouppeToggleStyle()))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let appearance: NSAppearance.Name = highContrastAppearance
            ? (scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
            : (scheme == .light ? .aqua : .darkAqua)
        window.appearance = NSAppearance(named: appearance)
        defer { window.contentView = nil; window.close() }
        // Yield to native representables and disposable-file preview work without
        // starting NSApplication.run(), ordering a window, or synthesizing events.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        if revealSearch, let field = descendants(host).first(where: { $0 is NSSearchField }) {
            field.scrollToVisible(field.bounds.insetBy(dx: 0, dy: -80))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertFalse(window.isVisible, "Visual fixtures must remain offscreen.")
        XCTAssertFalse(window.isKeyWindow, "Visual fixtures must not take keyboard focus.")
        let isSetup = name.hasPrefix("export-summary") || name.hasPrefix("rename-setup")
            || name.hasPrefix("rename-single") || name.hasPrefix("organize-setup")
            || (name.hasPrefix("photos-") && !name.hasPrefix("photos-preparing")
                && !name.hasPrefix("photos-batch-bar"))
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        if isSetup {
            XCTAssertEqual(scrolls.count, 1, "Configuration screens must have one native scrolling owner: \(name)")
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
        if isSetup, let scroll = scrolls.first, let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            document.scroll(NSPoint(x: 0, y: document.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let lower = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: lower)
            try XCTUnwrap(lower.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(name)-bottom.png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func makeImage() throws -> Data {
        let image = NSImage(size: CGSize(width: 900, height: 600))
        image.lockFocus()
        NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.72, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 900, height: 600).fill()
        NSColor(calibratedRed: 0.3, green: 0.4, blue: 0.25, alpha: 1).setFill()
        let mountain = NSBezierPath()
        mountain.move(to: .zero)
        mountain.line(to: CGPoint(x: 300, y: 440))
        mountain.line(to: CGPoint(x: 580, y: 180))
        mountain.line(to: CGPoint(x: 750, y: 360))
        mountain.line(to: CGPoint(x: 900, y: 0))
        mountain.close()
        mountain.fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private actor VisualPhotosLibrary: PhotosLibraryClient {
    private var authorizationDenied = false
    func setAuthorizationDenied(_ denied: Bool) { authorizationDenied = denied }
    func authorize() async throws {
        if authorizationDenied { throw PhotosLibraryError.permissionDenied }
    }
    func albums() async throws -> [PhotosLibraryAlbum] {
        [PhotosLibraryAlbum(id: "fixture", title: "Disposable review album with a long title")]
    }
    func select(_ query: PhotosLibraryQuery) async throws -> PhotosLibrarySnapshot {
        PhotosLibrarySnapshot(id: UUID(), count: 8_013, title: "Fixture library", query: query)
    }
    func prepare(snapshot: PhotosLibrarySnapshot, page: Int, size: Int, allowNetwork: Bool,
                 recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        throw PhotosLibraryError.empty // Capturing never requests or transfers originals.
    }
    func remove(_ batch: PhotosReviewBatch) async {}
}
