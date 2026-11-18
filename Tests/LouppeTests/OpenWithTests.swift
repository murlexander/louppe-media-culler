import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// Launch Services stand-in: no editor is ever opened by these tests.
final class FakeOpenWithWorkspace: OpenWithWorkspace, @unchecked Sendable {
    struct App { let identifier: String; let name: String; let version: String? }
    private let lock = NSLock()
    var byIdentifier: [String: [URL]] = [:]
    var byContentType: [UTType: [URL]] = [:]
    var apps: [URL: App] = [:]
    var defaults: [URL: URL] = [:]
    var openError: (any Error)?
    private(set) var opens: [(urls: [URL], app: URL)] = []
    private(set) var lookups = 0

    func install(_ path: String, _ identifier: String, version: String? = nil, name: String? = nil) -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        apps[url] = App(identifier: identifier,
                        name: name ?? url.deletingPathExtension().lastPathComponent, version: version)
        byIdentifier[identifier, default: []].append(url)
        return url
    }

    func applicationURLs(bundleIdentifier: String) -> [URL] {
        lock.withLock { lookups += 1 }
        return byIdentifier[bundleIdentifier] ?? []
    }
    func applicationURLs(toOpen contentType: UTType) -> [URL] { byContentType[contentType] ?? [] }
    func bundleIdentifier(ofApplicationAt url: URL) -> String? { apps[url]?.identifier }
    func displayName(ofApplicationAt url: URL) -> String { apps[url]?.name ?? url.lastPathComponent }
    func version(ofApplicationAt url: URL) -> String? { apps[url]?.version }
    func defaultApplicationURL(toOpen fileURL: URL) -> URL? { defaults[fileURL.standardizedFileURL] }
    func open(_ urls: [URL], withApplicationAt applicationURL: URL,
              completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.withLock { opens.append((urls, applicationURL)) }
        completion(openError)
    }
    var openCount: Int { lock.withLock { opens.count } }
}

@MainActor
final class OpenWithTests: XCTestCase {
    override func tearDown() async throws {
        await PhotoEditorCatalog.shared.replaceWorkspaceForTesting(LiveOpenWithWorkspace())
        OriginalFilesOpener.didFinishPlanning = nil
        try await super.tearDown()
    }

    // MARK: - Catalog

    func testOnlyInstalledEditorsAreListedInOrder() {
        let workspace = FakeOpenWithWorkspace()
        XCTAssertTrue(PhotoEditorCatalog.resolve(using: workspace).isEmpty, "Nothing installed, nothing listed")
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        _ = workspace.install("/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app",
                              "com.adobe.LightroomClassicCC7")
        // Lightroom (not Classic) also handles RAW but is not an editor here.
        let lightroom = workspace.install("/Applications/Adobe Lightroom.app", "com.adobe.lightroomCC")
        workspace.byContentType[.rawImage] = [lightroom]
        let editors = PhotoEditorCatalog.resolve(using: workspace)
        XCTAssertEqual(editors.map(\.kind), [.lightroomClassic, .preview])
        XCTAssertEqual(editors.map(\.title), ["Adobe Lightroom Classic", "Preview"])
    }

    func testEveryCaptureOneVersionAndPhotoshopCopyStaysListed() {
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/Applications/Capture One.app", "com.captureone.captureone16",
                              version: "16.9.0", name: "Capture One")
        _ = workspace.install("/Applications/Capture One 23.app", "com.captureone.captureone16",
                              version: "16.0.1", name: "Capture One")
        _ = workspace.install("/Applications/Capture One 12.app", "com.phaseone.captureone12", name: "Capture One 12")
        // A future version outside the exact list, found as a RAW handler.
        let future = URL(fileURLWithPath: "/Applications/Capture One 41.app", isDirectory: true)
        workspace.apps[future] = .init(identifier: "com.captureone.captureone41", name: "Capture One 41", version: "41.0")
        let viewer = URL(fileURLWithPath: "/Applications/Viewer.app", isDirectory: true)
        workspace.apps[viewer] = .init(identifier: "com.captureone.captureoneviewer", name: "Viewer", version: nil)
        workspace.byContentType[.rawImage] = [future, viewer]
        _ = workspace.install("/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app", "com.adobe.Photoshop")
        _ = workspace.install("/Applications/Adobe Photoshop (Beta)/Adobe Photoshop (Beta).app", "com.adobe.Photoshop")

        let editors = PhotoEditorCatalog.resolve(using: workspace)
        XCTAssertEqual(editors.map(\.kind), [.captureOne, .captureOne, .captureOne, .captureOne, .photoshop, .photoshop])
        XCTAssertEqual(editors.map(\.title), [
            "Capture One (16.9.0)", "Capture One (16.0.1)", "Capture One 12", "Capture One 41",
            "Adobe Photoshop 2026", "Adobe Photoshop (Beta)",
        ], "Same-named copies show their version; nothing is hidden by version")
        XCTAssertEqual(Set(editors.map(\.id)).count, editors.count)
        XCTAssertFalse(PhotoEditorKind.captureOne.matches(bundleIdentifier: "com.captureone.captureoneviewer"))
        XCTAssertTrue(PhotoEditorKind.captureOne.matches(bundleIdentifier: "com.captureone.captureone"))
    }

    // MARK: - Plans

    func testDefaultAppGroupsByHandlerAndReportsUnhandledAndMissing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = try file(root, "A.CR3"), jpeg = try file(root, "A.JPG"), other = try file(root, "B.JPG")
        let text = try file(root, "C.xyz")
        let missing = root.appendingPathComponent("Gone.JPG")
        let workspace = FakeOpenWithWorkspace()
        let rawApp = workspace.install("/Applications/RAW.app", "com.example.raw")
        let jpegApp = workspace.install("/Applications/JPEG.app", "com.example.jpeg")
        workspace.defaults = [raw: rawApp, jpeg: jpegApp, other: jpegApp, missing: jpegApp]
        let targets = OriginalFileTargets(files: [raw, jpeg, text, other, missing].enumerated().map {
            OriginalFileTarget(fileID: $0.element.lastPathComponent, url: $0.element, itemIndex: $0.offset)
        }, leaderFileIndex: 0)

        let plan = OpenWithPlan.make(targets: targets, choice: .defaultApplication, workspace: workspace)
        XCTAssertEqual(plan.requests, [
            .init(applicationURL: rawApp, urls: [raw]),
            .init(applicationURL: jpegApp, urls: [jpeg, other]),
        ], "Same default: one request; RAW and JPEG may go to different apps")
        XCTAssertEqual(plan.unhandled, [text])
        XCTAssertEqual(plan.missing, [missing], "Missing originals are reported, never sent")
        XCTAssertEqual(workspace.openCount, 0, "Planning opens nothing")

        let preview = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = PhotoEditorApplication(kind: .preview, url: preview, bundleIdentifier: "com.apple.Preview", title: "Preview")
        let named = OpenWithPlan.make(targets: targets, choice: .editor(editor), workspace: workspace)
        XCTAssertEqual(named.requests, [.init(applicationURL: preview, urls: [raw, jpeg, text, other])],
                       "A named editor receives the whole batch in one request")
        workspace.apps[preview] = nil // Removed after the menu was built.
        XCTAssertTrue(OpenWithPlan.make(targets: targets, choice: .editor(editor), workspace: workspace).editorUnavailable)
    }

    // MARK: - Dispatcher

    func testOpenWithSendsTheSameOriginalsAsDragOut() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 5)
        let jpeg = store.items[2].primaryURL
        let raw = jpeg.deletingPathExtension().appendingPathExtension("CR3")
        try Data("raw".utf8).write(to: raw)
        store.items[2] = PhotoItem(id: raw.lastPathComponent, primaryURL: raw, pairedURL: jpeg,
                                   captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 3)
        store.rebuildDerivedDataForTesting()
        store.setIndex(0)
        store.setSelection([0, 2])
        let workspace = FakeOpenWithWorkspace()
        let preview = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let rawApp = workspace.install("/Applications/RAW.app", "com.example.raw")
        workspace.defaults = [store.items[0].primaryURL.standardizedFileURL: preview,
                              raw.standardizedFileURL: rawApp, jpeg.standardizedFileURL: preview]
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)
        let dragged = try XCTUnwrap(store.originalFileTargets(for: .item(index: 2, revision: store.items[2].contentRevision)))

        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { workspace.openCount == 1 }
        XCTAssertEqual(workspace.opens[0].urls, dragged.urls, "Open With and drag-out share one resolver")
        XCTAssertEqual(workspace.opens[0].app, preview)

        OriginalFilesOpener.open(.selection, with: .defaultApplication, store: store, workspace: workspace)
        try await waitUntil { workspace.openCount == 3 }
        XCTAssertEqual(workspace.opens[1].app, preview)
        XCTAssertEqual(workspace.opens[1].urls, [store.items[0].primaryURL, jpeg])
        XCTAssertEqual(workspace.opens[2].app, rawApp)
        XCTAssertEqual(workspace.opens[2].urls, [raw])
        XCTAssertNil(store.originalHandoffAlert)
    }

    func testMissingUnhandledAndFailedOpensAreReported() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 3)
        store.setIndex(0)
        store.setSelection([0, 1])
        try FileManager.default.removeItem(at: store.items[1].primaryURL)
        let workspace = FakeOpenWithWorkspace()
        let preview = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)

        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.opens.map(\.urls), [[store.items[0].primaryURL]], "Only existing originals are sent")
        XCTAssertTrue(try XCTUnwrap(store.originalHandoffAlert).message.contains("1"))
        XCTAssertTrue(store.isSessionCommandPresentationActive, "The alert owns input like other session alerts")
        store.originalHandoffAlert = nil

        try FileManager.default.removeItem(at: store.items[0].primaryURL)
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.openCount, 1, "No original exists: nothing is sent")
        store.originalHandoffAlert = nil

        let third = try XCTUnwrap(store.originalFileTargets(for: .item(index: 2, revision: store.items[2].contentRevision)))
        workspace.openError = CocoaError(.fileReadNoPermission)
        OriginalFilesOpener.open(.item(index: 2, revision: store.items[2].contentRevision),
                                 with: .defaultApplication, store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.openCount, 1, "No default handler: reported, not opened")
        XCTAssertEqual(third.urls.count, 1)
        store.originalHandoffAlert = nil

        workspace.defaults[store.items[2].primaryURL.standardizedFileURL] = preview
        OriginalFilesOpener.open(.item(index: 2, revision: store.items[2].contentRevision),
                                 with: .defaultApplication, store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.openCount, 2)
        XCTAssertEqual(store.originalHandoffAlert?.message, CocoaError(.fileReadNoPermission).localizedDescription,
                       "A Launch Services failure is published on the main actor")
    }

    func testStaleMenuTargetReportsInsteadOfFailingSilently() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 3)
        store.setIndex(0)
        let workspace = FakeOpenWithWorkspace()
        let stale = store.items[0].contentRevision
        OriginalFilesOpener.open(.item(index: 2, revision: stale), with: .defaultApplication,
                                 store: store, workspace: workspace)
        XCTAssertEqual(store.originalHandoffAlert?.message,
                       L10n.text("The originals are missing or changed since Louppe scanned them. Rescan the folder or reconnect its drive, then try again."))
        XCTAssertEqual(workspace.openCount, 0)
    }

    func testActivationOnlyMarksTheEditorListStale() async throws {
        // A private center: the app-wide activation notice has other observers.
        let center = NotificationCenter()
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let catalog = PhotoEditorCatalog(workspace: workspace, notificationCenter: center)
        catalog.refreshIfStale()
        await catalog.waitForRefreshForTesting()
        XCTAssertEqual(catalog.editors.count, 1)
        _ = workspace.install("/Applications/Capture One.app", "com.captureone.captureone16", name: "Capture One")
        catalog.refreshIfStale()
        await catalog.waitForRefreshForTesting()
        XCTAssertEqual(catalog.editors.count, 1, "Fresh within the interval: no lookup")
        let lookups = workspace.lookups
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(workspace.lookups, lookups, "Activation alone sweeps no Launch Services lookups")
        XCTAssertEqual(catalog.editors.count, 1)
        catalog.refreshIfStale() // What building an Open With menu or the palette does.
        await catalog.waitForRefreshForTesting()
        XCTAssertGreaterThan(workspace.lookups, lookups)
        XCTAssertEqual(catalog.editors.map(\.title), ["Capture One", "Preview"])
    }

    func testOpeningAStaleMenuShowsAnEditorInstalledAfterLaunch() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 2)
        store.setIndex(0)
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        await PhotoEditorCatalog.shared.replaceWorkspaceForTesting(workspace)
        _ = workspace.install("/Applications/Capture One.app", "com.captureone.captureone16", name: "Capture One")
        PhotoEditorCatalog.shared.markStale() // As on becoming active.

        let host = NSHostingView(rootView: OpenWithMenu(store: store, origin: .selection)
            .menuStyle(.button).buttonStyle(.borderless))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 240, height: 60))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let button = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? NSPopUpButton }.first)
        let menu = try XCTUnwrap(button.menu)
        let coordinator = try XCTUnwrap(menu.delegate as? NSObject)
        let willShow = NSSelectorFromString("popUpButtonCell:willShowMenu:")
        func rows() -> [String] {
            menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.title.isEmpty && $0.title != L10n.text("Open With") }
                .map(\.title)
        }
        // Opening the menu starts the off-main refresh.
        coordinator.perform(willShow, with: button.cell, with: menu)
        await PhotoEditorCatalog.shared.waitForRefreshForTesting()
        try await SelectionInteractionFixture.settle(host)
        // The next opening lists the newly installed editor.
        coordinator.perform(willShow, with: button.cell, with: menu)
        XCTAssertEqual(rows(), ["Capture One", "Preview", L10n.text("Default App")])
        XCTAssertEqual(workspace.openCount, 0)
    }

    func testSameNameReplacementIsNotOpened() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 4)
        store.items = try store.items.map { item in
            PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL, captureDate: nil,
                cameraModel: nil, lensModel: nil, fileSize: item.fileSize,
                scannedIdentity: try FileOperationJournal.captureIdentity(at: item.primaryURL)))
        }
        store.rebuildDerivedDataForTesting()
        store.setIndex(0)
        store.setSelection([0, 1])
        // Opened in an editor before: attributes and permissions changed only.
        try touchMetadataLikeLaunchServices(store.items[0].primaryURL)
        // Re-exported in place by another app: same name, different file.
        let replaced = store.items[1].primaryURL
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.copyItem(at: store.items[3].primaryURL, to: replaced)
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)

        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.opens.map(\.urls), [[store.items[0].primaryURL]],
                       "Only the untouched original is opened; the replacement is reported as missing")
        store.originalHandoffAlert = nil

        store.setSelection([1])
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.openCount, 1, "Nothing left: no request, the existing alert")
        XCTAssertEqual(store.originalHandoffAlert?.message,
                       L10n.text("The originals are missing or changed since Louppe scanned them. Rescan the folder or reconnect its drive, then try again."))
    }

    // MARK: - Menus and palette

    func testMenuListsInstalledEditorsAndOpensNothingWhileBuilt() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 3)
        store.setIndex(1)
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        _ = workspace.install("/Applications/Capture One.app", "com.captureone.captureone16", name: "Capture One")
        await PhotoEditorCatalog.shared.replaceWorkspaceForTesting(workspace)

        // Standalone presentation per the app's menu convention; in menus
        // (File, tile, Gallery) the same view becomes a native submenu.
        let host = NSHostingView(rootView: OpenWithMenu(store: store, origin: .selection)
            .menuStyle(.button).buttonStyle(.borderless))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 240, height: 60))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let button = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertTrue(button.isEnabled)
        let menu = try XCTUnwrap(button.menu)
        let coordinator = try XCTUnwrap(menu.delegate as? NSObject)
        let willShow = NSSelectorFromString("popUpButtonCell:willShowMenu:")
        XCTAssertTrue(coordinator.responds(to: willShow), "SwiftUI changed how it fills menus; update this probe")
        coordinator.perform(willShow, with: button.cell, with: menu)
        let rows = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.title.isEmpty && $0.title != L10n.text("Open With") }
        XCTAssertEqual(rows.map(\.title), ["Capture One", "Preview", L10n.text("Default App")])
        XCTAssertTrue(rows.allSatisfy(\.isEnabled))
        XCTAssertNotNil(rows[0].image, "Editors show their app icon")
        XCTAssertEqual(workspace.openCount, 0, "Building and showing the menu opens no editor")

        store.phase = .scanning(found: 0)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertFalse(button.isEnabled, "Unavailable before Ready (and for Photos sources)")
    }

    func testGridTileContextMenuHasOpenWithBetweenSelectionAndDecisions() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 6)
        store.setIndex(0)
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        await PhotoEditorCatalog.shared.replaceWorkspaceForTesting(workspace)
        let host = NSHostingView(rootView: GridView(store: store).environment(\.accessibilityEnabled, true))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 700, height: 560))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let surface = try XCTUnwrap(SelectionInteractionFixture.descendants(host)
            .compactMap { $0 as? GridImmediateClickSurface.ClickView }.first { $0.bounds.height > 100 })
        let point = surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        // Ask the responder chain for the native menu without tracking it.
        var view: NSView? = surface
        var menu: NSMenu?
        while let current = view, menu == nil { menu = current.menu(for: event); view = current.superview }
        let contextMenu = try XCTUnwrap(menu, "The tile's native context menu")
        contextMenu.delegate?.menuNeedsUpdate?(contextMenu)
        let titles = contextMenu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        let openWith = try XCTUnwrap(titles.firstIndex(of: L10n.text("Open With")), "Titles: \(titles)")
        let addToSelection = try XCTUnwrap(titles.firstIndex(of: L10n.text("Add to Selection")))
        let decideYes = try XCTUnwrap(titles.firstIndex(of: L10n.label("Mark Yes")))
        XCTAssertLessThan(addToSelection, openWith)
        XCTAssertLessThan(openWith, decideYes)
        let submenu = try XCTUnwrap(contextMenu.items[openWith].submenu)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        XCTAssertEqual(submenu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Preview", L10n.text("Default App")])
        XCTAssertEqual(workspace.openCount, 0, "Building the menu opens nothing")
    }

    func testPaletteOffersFlatRowsThatOpenAfterDismissal() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 3)
        store.setIndex(2)
        let workspace = FakeOpenWithWorkspace()
        let preview = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        workspace.defaults[store.items[2].primaryURL.standardizedFileURL] = preview
        await PhotoEditorCatalog.shared.replaceWorkspaceForTesting(workspace)

        let actions = ActionPaletteView(store: store).actions
        let rows = actions.filter { $0.id.hasPrefix("open-with-") }
        XCTAssertEqual(rows.map(\.title), [L10n.text("Open with \("Preview")"), L10n.text("Open with Default App")])
        XCTAssertTrue(rows.allSatisfy(\.isEnabled))
        XCTAssertEqual(rows.first?.category, L10n.text("Files & folders"))
        XCTAssertEqual(ActionPaletteSearch.results(for: "open with", in: actions).prefix(2).map(\.id), rows.map(\.id))
        XCTAssertEqual(workspace.openCount, 0)
        try XCTUnwrap(rows.first).perform()
        try await waitUntil { workspace.openCount == 1 }
        XCTAssertEqual(workspace.opens[0].urls, [store.items[2].primaryURL])
    }

    // MARK: - Confirmation above 50 originals

    func testFiftyOriginalsOpenAtOnceAndFiftyOneAskFirst() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 51)
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)

        store.setIndex(0)
        store.setSelection(Set(0..<50))
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { workspace.openCount == 1 }
        XCTAssertEqual(workspace.opens[0].urls.count, 50, "Exactly 50 opens without asking")
        XCTAssertNil(store.pendingOpenWith)

        store.selectAllVisible()
        var planned = 0
        OriginalFilesOpener.didFinishPlanning = { _ in planned += 1 }
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.pendingOpenWith != nil }
        let pending = try XCTUnwrap(store.pendingOpenWith)
        XCTAssertEqual(planned, 1)
        XCTAssertEqual(workspace.openCount, 1, "Nothing opens before the answer")
        XCTAssertEqual(pending.title, "Open 51 files in Preview?")
        XCTAssertEqual(pending.message, "Preview will open each file. The originals stay where they are.")
        XCTAssertTrue(store.isSessionCommandPresentationActive, "The confirmation owns input like other session alerts")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        _ = SessionView(store: store).handleKey(key, context: .focusedSession,
                                                shortcutPreferences: ReviewShortcutPreferences(interpretation: .keyboardLayout))
        XCTAssertEqual(store.items[0].rating, .undecided, "Review shortcuts wait behind the confirmation")

        // The alert's Cancel button (role .cancel, also Esc) and its
        // dismissal binding, exactly as SessionView wires them.
        let view = SessionView(store: store)
        XCTAssertTrue(view.isOpenWithConfirmationPresented.wrappedValue)
        view.isOpenWithConfirmationPresented.wrappedValue = false
        XCTAssertNil(store.pendingOpenWith)
        XCTAssertFalse(view.isOpenWithConfirmationPresented.wrappedValue)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(workspace.openCount, 1, "Cancel opens nothing")
        XCTAssertFalse(store.isSessionCommandPresentationActive)
        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.pendingOpenWith != nil }
        OriginalFilesOpener.cancelPending(store: store)
        XCTAssertNil(store.pendingOpenWith)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(workspace.openCount, 1, "The Cancel button opens nothing")

        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.pendingOpenWith != nil }
        let again = try XCTUnwrap(store.pendingOpenWith)
        OriginalFilesOpener.confirm(again, store: store)
        OriginalFilesOpener.confirm(again, store: store)
        XCTAssertNil(store.pendingOpenWith)
        try await waitUntil { workspace.openCount == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(workspace.openCount, 2, "Open sends one request, once")
        XCTAssertEqual(workspace.opens[1].urls, store.items.map(\.primaryURL))
        XCTAssertNil(store.originalHandoffAlert)
    }

    func testPairsCountAsTwoFilesAndDefaultAppCountsResolvedFiles() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 26)
        let workspace = FakeOpenWithWorkspace()
        let preview = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let rawApp = workspace.install("/Applications/RAW.app", "com.example.raw")
        for index in 0..<25 {
            let jpeg = store.items[index].primaryURL
            let raw = jpeg.deletingPathExtension().appendingPathExtension("CR3")
            try Data("raw".utf8).write(to: raw)
            store.items[index] = PhotoItem(id: raw.lastPathComponent, primaryURL: raw, pairedURL: jpeg,
                                           captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 3)
            workspace.defaults[raw.standardizedFileURL] = rawApp
            workspace.defaults[jpeg.standardizedFileURL] = preview
        }
        store.rebuildDerivedDataForTesting()
        let single = store.items[25].primaryURL.standardizedFileURL
        store.setIndex(0)

        // 25 pairs are 50 files: no confirmation.
        store.setSelection(Set(0..<25))
        OriginalFilesOpener.open(.selection, with: .defaultApplication, store: store, workspace: workspace)
        try await waitUntil { workspace.openCount == 2 }
        XCTAssertEqual(workspace.opens.map(\.urls.count).reduce(0, +), 50)
        XCTAssertNil(store.pendingOpenWith)

        // One more photo without a default app still sends only 50.
        store.selectAllVisible()
        OriginalFilesOpener.open(.selection, with: .defaultApplication, store: store, workspace: workspace)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertNil(store.pendingOpenWith, "Unhandled files are not counted")
        XCTAssertEqual(workspace.openCount, 4)
        store.originalHandoffAlert = nil

        // With a handler it is 51 files: ask, in the Default App wording.
        workspace.defaults[single] = preview
        OriginalFilesOpener.open(.selection, with: .defaultApplication, store: store, workspace: workspace)
        try await waitUntil { store.pendingOpenWith != nil }
        let pending = try XCTUnwrap(store.pendingOpenWith)
        XCTAssertEqual(pending.title, "Open 51 files in their default apps?")
        XCTAssertEqual(pending.message, "Each file will open in its default app. The originals stay where they are.")
        XCTAssertEqual(workspace.openCount, 4)
        OriginalFilesOpener.confirm(pending, store: store)
        try await waitUntil { workspace.openCount == 6 }
        XCTAssertEqual(workspace.opens.suffix(2).map(\.urls.count).reduce(0, +), 51)
    }

    func testOpenChecksTheFilesAgainAndLeavesOutAReplacement() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 52)
        store.items = try store.items.map { item in
            PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL, captureDate: nil,
                cameraModel: nil, lensModel: nil, fileSize: item.fileSize,
                scannedIdentity: try FileOperationJournal.captureIdentity(at: item.primaryURL)))
        }
        store.rebuildDerivedDataForTesting()
        store.setIndex(0)
        store.setSelection(Set(0..<51))
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)

        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.pendingOpenWith != nil }
        let pending = try XCTUnwrap(store.pendingOpenWith)
        // Re-exported in place while the question is open: same name, different file.
        let replaced = store.items[3].primaryURL
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.copyItem(at: store.items[51].primaryURL, to: replaced)

        OriginalFilesOpener.confirm(pending, store: store)
        try await waitUntil { store.originalHandoffAlert != nil }
        XCTAssertEqual(workspace.openCount, 1, "Open does not ask again although only 50 remain")
        XCTAssertEqual(workspace.opens[0].urls.count, 50)
        XCTAssertFalse(workspace.opens[0].urls.contains(replaced), "The replacement is not opened")
        XCTAssertEqual(store.originalHandoffAlert?.message,
                       L10n.plural("%lld originals are missing or changed since Louppe scanned them, so they weren't opened. Rescan the folder or reconnect its drive.", 1))
        XCTAssertNil(store.pendingOpenWith)
    }

    func testRequestIsDroppedWhenAnotherPresentationAppearsWhilePlanning() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 51)
        store.setIndex(0)
        store.selectAllVisible()
        let workspace = FakeOpenWithWorkspace()
        _ = workspace.install("/System/Applications/Preview.app", "com.apple.Preview")
        let editor = try XCTUnwrap(PhotoEditorCatalog.resolve(using: workspace).first)
        var planned = 0
        OriginalFilesOpener.didFinishPlanning = { _ in planned += 1 }

        for present in [{ store.isExportPresented = true }, { store.presentActionPalette() }] {
            planned = 0
            OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
            present() // Opens while planning runs off-main.
            try await waitUntil { planned == 1 }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(store.pendingOpenWith, "No alert hides behind the other presentation")
            XCTAssertEqual(workspace.openCount, 0, "The dropped request opens nothing")
            store.isExportPresented = false
            store.dismissActionPalette()
            XCTAssertFalse(store.isSessionCommandPresentationActive, "Review keys are not blocked")
        }

        OriginalFilesOpener.open(.selection, with: .editor(editor), store: store, workspace: workspace)
        try await waitUntil { store.pendingOpenWith != nil }
    }

    func testConfirmationTitlesUseEachLanguagesPlurals() {
        // Arabic formatting wraps inserted values in direction isolates.
        func isolatesRemoved(_ value: String) -> String {
            value.replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
        }
        XCTAssertEqual(L10n.renderPlural("Open %lld files in %@?", counts: [51], arguments: ["Photoshop"], language: "en"),
                       "Open 51 files in Photoshop?")
        XCTAssertEqual(L10n.renderPlural("Open %lld files in their default apps?", counts: [312], language: "en"),
                       "Open 312 files in their default apps?")
        XCTAssertEqual(L10n.renderPlural("Open %lld files in %@?", counts: [51], arguments: ["Photoshop"], language: "es"),
                       "¿Abrir 51 archivos en Photoshop?")
        XCTAssertEqual(L10n.renderPlural("Open %lld files in %@?", counts: [312], arguments: ["Photoshop"], language: "zh-Hans"),
                       "要在“Photoshop”中打开 312 个文件吗？")
        XCTAssertEqual(isolatesRemoved(L10n.renderPlural("Open %lld files in %@?", counts: [2], arguments: ["Photoshop"], language: "ar")),
                       "فتح ملفين في Photoshop؟")
        XCTAssertEqual(isolatesRemoved(L10n.renderPlural("Open %lld files in %@?", counts: [51], arguments: ["Photoshop"], language: "ar")),
                       "فتح \(51.formatted(.number.locale(Locale(identifier: "ar")))) ملفًا في Photoshop؟")
        XCTAssertEqual(L10n.renderPlural("Open %lld files in their default apps?", counts: [312], language: "hi"),
                       "312 फ़ाइलें उनके डिफ़ॉल्ट ऐप में खोलें?")
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenWith-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url.standardizedFileURL
    }
}
