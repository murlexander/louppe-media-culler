import SwiftUI
import AppKit
#if !APP_STORE
import Sparkle
#endif

@main
struct LouppeApp: App {
    @NSApplicationDelegateAdaptor(LouppeApplicationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var folderOpening = FolderOpening()
    #if APP_STORE
    @StateObject private var store = SessionStore(
        automaticallyRecoversInterruptedOperations: false
    )
    #else
    @StateObject private var store = SessionStore(
        automaticallyRecoversInterruptedOperations: true
    )
    #endif
    #if APP_STORE
    @StateObject private var tipStore = TipStore()
    #endif
    #if !APP_STORE
    private let updaterController: SPUStandardUpdaterController
    #endif

    init() {
        // Initialize the bundled XMPCore runtime once before any explicit
        // Metadata (XMP), Copy-with-XMP, or Move-with-XMP request reaches it.
        _ = XMPFieldMapping.runtimeIsAvailable
        #if !APP_STORE
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !AppBuildInfo.isReviewBuild,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    var body: some Scene {
        // Configure from the scene lifecycle, before a document-open launch
        // can suppress the default window and prevent RootView.onAppear.
        let _ = appDelegate.configure(
            store: store, folderOpening: folderOpening,
            showMainWindow: { openWindow(id: "main") }
        )
        Window(AppBuildInfo.displayName, id: "main") {
            RootView(store: store, folderOpening: folderOpening)
                .localizedInterface()
                .onAppear {
                    #if APP_STORE
                    // Initialize the listener even when the tip window stays closed.
                    _ = tipStore
                    #endif
                    NSApp.activate(ignoringOtherApps: true)
                    // Optional launch argument for testing:
                    //   open Louppe.app --args -openFolder /path/to/photos
                    // Keep test launches explicit. Dock/Finder document-open
                    // requests use the application delegate's folder path.
                    #if !APP_STORE
                    if let path = UserDefaults.standard.string(forKey: "openFolder"),
                       FileManager.default.fileExists(atPath: path) {
                        store.openFolder(URL(fileURLWithPath: path))
                    }
                    #endif
                }
        }
        // Keep the system-owned macOS window chrome. This adopts the current
        // platform appearance (including macOS 26 window geometry) instead of
        // freezing a custom or plain style in the app.
        .windowStyle(.automatic)
        .defaultSize(width: 456, height: 220)
        .commands {
            // Standard About panel reads its version from the release bundle
            // and adds credits plus a link to the complete release history.
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("About Louppe")) {
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
                }
            }
            CommandGroup(after: .appInfo) {
                #if APP_STORE
                Button(L10n.text("Support Louppe…")) {
                    openWindow(id: TipView.windowID)
                }
                #else
                Link(L10n.text("Support Louppe…"), destination: AppBuildInfo.directTipURL)
                #endif
            }
            #if !APP_STORE
            CommandGroup(after: .appInfo) {
                if !AppBuildInfo.isReviewBuild {
                    CheckForUpdatesView(
                        updater: updaterController.updater,
                        isFileOperationRunning: store.isFileOperationRunning
                    )
                }
            }
            #endif
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Open Folder…")) {
                    store.promptForSourceFolder()
                }
                .keyboardShortcut("o")
                .disabled(
                    store.isFileOperationRunning
                        || store.isSessionCommandPresentationActive
                )
            }
            FocusedLouppeSessionCommands(store: store)
            CommandGroup(replacing: .help) {
                Button(L10n.text("Louppe Help")) {
                    openWindow(id: LouppeHelpWindow.id)
                }
                Link(L10n.text("Privacy Policy"), destination: AppBuildInfo.privacyPolicyURL)
            }
        }

        Window(L10n.text("\(AppBuildInfo.displayName) Help"), id: LouppeHelpWindow.id) {
            LouppeHelpView()
                .localizedInterface()
        }
        .defaultSize(width: 630, height: 620)

        #if APP_STORE
        Window(L10n.text("Support Louppe"), id: TipView.windowID) {
            TipView(store: tipStore)
                .localizedInterface()
        }
        .windowResizability(.contentSize)
        #endif

        Settings {
            Group {
            #if !APP_STORE
            LouppeSettingsView(store: store, updater: updaterController.updater)
            #else
            LouppeSettingsView(store: store)
            #endif
            }
            .localizedInterface()
        }
        .windowResizability(.contentSize)
    }

    /// Credits block for the About panel. Links are clickable.
    private static var aboutCredits: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        var link = base
        let credits = NSMutableAttributedString()

        credits.append(NSAttributedString(
            string: L10n.text("Fast photo, video, and audio culling for creators.\n\n"), attributes: base))

        link[.link] = URL(string: "https://louppe.eu")!
        credits.append(NSAttributedString(string: "louppe.eu", attributes: link))
        credits.append(NSAttributedString(string: "\n", attributes: base))

        link[.link] = AppBuildInfo.privacyPolicyURL
        credits.append(NSAttributedString(string: L10n.text("Privacy Policy"), attributes: link))
        credits.append(NSAttributedString(string: "\n", attributes: base))

        link[.link] = URL(string: "https://github.com/murlexander/louppe-media-culler/releases")!
        credits.append(NSAttributedString(string: L10n.text("Version History"), attributes: link))
        credits.append(NSAttributedString(string: "\n\n", attributes: base))

        credits.append(NSAttributedString(
            string: L10n.text("Created by Alex Markin\n"), attributes: base))

        link[.link] = URL(string: "mailto:a@alex-markin.com")!
        credits.append(NSAttributedString(string: "a@alex-markin.com", attributes: link))
        credits.append(NSAttributedString(string: "\n", attributes: base))

        link[.link] = URL(string: "https://github.com/murlexander/louppe-media-culler")!
        credits.append(NSAttributedString(string: "GitHub", attributes: link))

        return credits
    }
}

/// Session commands are available only while Louppe's photo window is the
/// focused scene. `SessionView` owns their key equivalents because it can prove
/// the live window and responder context; keeping duplicate equivalents out of
/// the menu prevents them from bypassing text selection or AppKit's Undo.
private struct FocusedLouppeSessionCommands: Commands {
    @ObservedObject var store: SessionStore
    @FocusedValue(\.louppeSessionStore) private var sceneStore

    private var focusedStore: SessionStore? {
        guard sceneStore === store else { return nil }
        return sceneStore
    }

    private var actionableStore: SessionStore? {
        guard let focusedStore,
              !focusedStore.isSessionCommandPresentationActive else {
            return nil
        }
        return focusedStore
    }

    private var canChangeGalleryImageSize: Bool {
        guard let actionableStore,
              actionableStore.viewMode == .gallery,
              let item = actionableStore.currentItem else { return false }
        return item.mediaKind == .photo && item.isSupported
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button {
                actionableStore?.presentActionPalette()
            } label: {
                Text(L10n.text("Command Palette…"))
            }
            .disabled(
                actionableStore?.isFileOperationRunning != false
            )

            Divider()

            Button {
                actionableStore?.rescan()
            } label: {
                Text(L10n.text("Rescan Folder"))
            }
            .disabled(
                actionableStore?.sourceFolder == nil
                    || actionableStore?.isFileOperationRunning != false
            )

            Button(L10n.text("Close Session")) {
                actionableStore?.closeSession()
            }
            .disabled(
                actionableStore?.sourceFolder == nil
                    || actionableStore?.isFileOperationRunning != false
            )
        }

        CommandGroup(after: .undoRedo) {
            Button {
                actionableStore?.undo()
            } label: {
                Text(L10n.text("Undo Louppe Action"))
            }
            .disabled(
                actionableStore?.isFileOperationRunning != false
                    || actionableStore?.canUndo != true
            )

            Button {
                actionableStore?.requestClearAllRatings()
            } label: {
                Text(L10n.text("Clear All Decisions"))
            }
            .disabled(
                actionableStore?.ratedCount == 0
                    || actionableStore?.isFileOperationRunning != false
            )
        }

        CommandGroup(after: .saveItem) {
            Button(L10n.text("Check Saved Decisions…")) {
                actionableStore?.isSessionRecoveryPresented = true
            }
            .disabled(actionableStore?.sessionRecoveryEntries.isEmpty != false)

            Divider()
            Button(L10n.text("Organize Source Folder…")) {
                actionableStore?.presentSourceOrganization()
            }
            .disabled(
                actionableStore?.canOrganizeSource != true
            )

            Button {
                actionableStore?.presentExport()
            } label: {
                Text(L10n.text("Export…"))
            }
            .disabled(
                actionableStore?.canExport != true
            )

            Divider()

            // Clean Up asks for confirmation in the session window
            // (SessionView presents the dialog when pendingCleanUp is set).
            Menu(L10n.text("Clean Up")) {
                CleanUpMenuItems(store: store)
            }
            .disabled(
                actionableStore?.canCleanUp != true
            )
        }

        CommandGroup(after: .toolbar) {
            Picker(L10n.text("View"), selection: Binding(
                get: { focusedStore?.viewMode ?? .gallery },
                set: { actionableStore?.viewMode = $0 }
            )) {
                Text(L10n.text("Gallery")).tag(ViewMode.gallery)
                Text(L10n.text("Grid")).tag(ViewMode.grid)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(actionableStore == nil)

            Divider()

            Button {
                actionableStore?.zoomGrid(larger: true)
            } label: {
                Text(L10n.text("Zoom In"))
            }
            .disabled(actionableStore?.viewMode != .grid)

            Button {
                actionableStore?.zoomGrid(larger: false)
            } label: {
                Text(L10n.text("Zoom Out"))
            }
            .disabled(actionableStore?.viewMode != .grid)

            Divider()

            Button(L10n.text("Fit Photo in Gallery")) {
                actionableStore?.zoomToFit()
            }
            .disabled(!canChangeGalleryImageSize)

            Button {
                if actionableStore?.isAtActualSize != true {
                    actionableStore?.toggleZoom(.actual)
                }
            } label: {
                Text(L10n.text("View Photo at 100%"))
            }
            .disabled(!canChangeGalleryImageSize)

            Button {
                if actionableStore?.zoomMode != .small {
                    actionableStore?.toggleZoom(.small)
                }
            } label: {
                Text(L10n.text("View Photo at Phone Size"))
            }
            .disabled(!canChangeGalleryImageSize)

            Divider()

            Menu(L10n.text("Review Groups")) {
                Button(L10n.text("Analyze Folder Locally")) {
                    actionableStore?.analyzeDuplicateAndBurstGroups()
                }
                .disabled(
                    actionableStore?.items.isEmpty != false
                        || actionableStore?.isFileOperationRunning != false
                        || actionableStore?.isXMPPublicationRunning == true
                )

                Divider()

                Group {
                    Button(L10n.text("Exact Duplicates")) {
                        actionableStore?.enterGroupedReview(.exactDuplicates)
                    }
                    Button(L10n.text("Likely Similar Photos")) {
                        actionableStore?.enterGroupedReview(.likelySimilarPhotos)
                    }
                    Button(L10n.text("Capture Bursts")) {
                        actionableStore?.enterGroupedReview(.captureBursts)
                    }
                }
                .disabled(
                    actionableStore?.items.isEmpty != false
                        || actionableStore?.isFileOperationRunning != false
                        || actionableStore?.isXMPPublicationRunning == true
                )

                Divider()

                Button(L10n.text("Return to Normal Review")) {
                    actionableStore?.exitGroupedReview()
                }
                .disabled(actionableStore?.isGroupedReviewActive != true)

                Button(L10n.text("Review Group Settings…")) {
                    actionableStore?.isSortPresented = true
                }
                .disabled(actionableStore?.isFileOperationRunning != false)
            }
        }
    }
}

private struct LouppeSessionStoreFocusedValueKey: FocusedValueKey {
    typealias Value = SessionStore
}

extension FocusedValues {
    var louppeSessionStore: SessionStore? {
        get { self[LouppeSessionStoreFocusedValueKey.self] }
        set { self[LouppeSessionStoreFocusedValueKey.self] = newValue }
    }
}

/// Keep the process alive until file operations are safe and the newest rating
/// snapshot reaches stable storage. AppKit's terminate-later handshake avoids
/// freezing the main thread during the final save.
@MainActor
final class LouppeApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: SessionStore?
    var showMainWindow: (() -> Void)?
    private var folderOpening: FolderOpening?
    private var menuShortcuts: MenuShortcutColumns?
    private var pendingFolderURLs: [URL]?
    private var hasFinishedLaunching = false
    private var isPreparingToTerminate = false

    func configure(
        store: SessionStore,
        folderOpening: FolderOpening,
        showMainWindow: @escaping () -> Void
    ) {
        self.store = store
        self.folderOpening = folderOpening
        folderOpening.store = store
        if menuShortcuts == nil {
            menuShortcuts = MenuShortcutColumns(store: store)
        }
        self.showMainWindow = showMainWindow
        openPendingFolderIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        hasFinishedLaunching = true
        menuShortcuts?.refresh()
        openPendingFolderIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFolderURLs = urls
        openPendingFolderIfNeeded()
    }

    @objc(openMediaFolder:userData:error:)
    func openMediaFolder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if let message = FolderOpening.validationError(for: urls) {
            error.pointee = message as NSString
            return
        }
        if hasFinishedLaunching, let folderOpening {
            if let message = folderOpening.open(urls) {
                error.pointee = message as NSString
            }
            presentMainWindow()
        } else {
            pendingFolderURLs = urls
            openPendingFolderIfNeeded()
        }
    }

    func openPendingFolderIfNeeded() {
        guard hasFinishedLaunching, folderOpening != nil,
              pendingFolderURLs != nil else { return }
        // Opening a SwiftUI window is valid once the scene has mounted. The
        // main-queue hop also handles Finder events delivered during startup.
        DispatchQueue.main.async { [weak self] in
            guard let self, let urls = self.pendingFolderURLs,
                  let folderOpening = self.folderOpening else { return }
            self.pendingFolderURLs = nil
            self.presentMainWindow()
            folderOpening.open(urls)
        }
    }

    private func presentMainWindow() {
        showMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.isRecoveringInterruptedOperations == true {
            let alert = NSAlert()
            alert.messageText = L10n.text("File recovery is still running")
            alert.informativeText = L10n.text("Wait for recovery to finish, then quit.")
            alert.alertStyle = .warning
            alert.runModal()
            return .terminateCancel
        }
        if let operation = store?.activeFileOperation {
            let alert = NSAlert()
            switch operation {
            case .exportCopy:
                alert.messageText = L10n.text("Export is still copying files")
                alert.informativeText = L10n.text("Stop Copy or wait for it to finish, then quit.")
            case .exportMove:
                alert.messageText = L10n.text("Export is still moving files")
                alert.informativeText = L10n.text("Wait for Move to finish, then quit.")
            case .organizeSource:
                alert.messageText = L10n.text("The source folder is still being organized")
                alert.informativeText = L10n.text("Wait for moving or restoring to finish, then quit.")
            case .renameSource:
                alert.messageText = L10n.text("Files are still being renamed")
                alert.informativeText = L10n.text("Wait for renaming or restoring to finish, then quit.")
            case .cleanUp:
                alert.messageText = L10n.text("Clean Up is still running")
                alert.informativeText = L10n.text("Wait for Trash or restore to finish, then quit.")
            }
            alert.alertStyle = .warning
            alert.runModal()
            return .terminateCancel
        }
        guard let store else { return .terminateNow }
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        // `.terminateLater` leaves AppKit interactive while persistence runs.
        // Freeze rating/navigation commands before taking the final snapshot
        // so a last key press cannot land after the data that authorizes Quit.
        store.beginTerminationPreparation()
        attemptFinalSave(store: store, application: sender)
        return .terminateLater
    }

    private func attemptFinalSave(
        store: SessionStore,
        application: NSApplication
    ) {
        Task { @MainActor [weak self, weak store] in
            guard let self, let store else {
                application.reply(toApplicationShouldTerminate: true)
                return
            }
            // Metadata publication is independently cancellable. Wait for a
            // safe between-file/atomic-replacement boundary before saving or
            // allowing AppKit to terminate the process.
            await store.cancelAndAwaitXMPPublication()
            let result = await store.saveSessionForTermination()
            // AppKit remains interactive during `.terminateLater`. No file
            // reconciliation may begin after the initial Quit check and then
            // be cut off by the final persistence reply.
            if store.isRecoveringInterruptedOperations
                || store.activeFileOperation != nil
                || store.isXMPPublicationRunning {
                self.isPreparingToTerminate = false
                store.cancelTerminationPreparation()
                application.reply(toApplicationShouldTerminate: false)
                return
            }
            if result?.canDiscardInMemoryState != false {
                self.isPreparingToTerminate = false
                application.reply(toApplicationShouldTerminate: true)
                return
            }
            if result == .rejectedInvalidSnapshot {
                self.presentInvalidSnapshotFailure(
                    store: store,
                    application: application
                )
                return
            }
            self.presentSaveFailure(store: store, application: application)
        }
    }

    private func presentInvalidSnapshotFailure(
        store: SessionStore,
        application: NSApplication
    ) {
        let alert = NSAlert()
        alert.messageText = L10n.text("Session data failed a safety check")
        alert.informativeText = L10n.text("Louppe kept your saved ratings: the new snapshot failed a safety check. Cancel Quit to keep this session open. Quit without saving discards your latest changes.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.text("Cancel Quit"))
        alert.addButton(withTitle: L10n.text("Quit Without Saving"))

        if alert.runModal() == .alertSecondButtonReturn {
            isPreparingToTerminate = false
            application.reply(toApplicationShouldTerminate: true)
        } else {
            isPreparingToTerminate = false
            store.cancelTerminationPreparation()
            application.reply(toApplicationShouldTerminate: false)
        }
    }

    private func presentSaveFailure(
        store: SessionStore,
        application: NSApplication
    ) {
        let alert = NSAlert()
        alert.messageText = L10n.text("Your latest ratings aren't saved")
        alert.informativeText = store.persistenceWarning
            ?? L10n.text("Couldn’t save to the media folder or backup. Retry.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.text("Retry Saving"))
        alert.addButton(withTitle: L10n.text("Cancel Quit"))
        alert.addButton(withTitle: L10n.text("Quit Without Saving"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            attemptFinalSave(store: store, application: application)
        case .alertThirdButtonReturn:
            isPreparingToTerminate = false
            application.reply(toApplicationShouldTerminate: true)
        default:
            isPreparingToTerminate = false
            store.cancelTerminationPreparation()
            application.reply(toApplicationShouldTerminate: false)
        }
    }
}
