import SwiftUI
import UniformTypeIdentifiers

/// The start screen: pick a folder (or a recent one) to begin a session.
struct WelcomeView: View {
    @ObservedObject var store: SessionStore
    private let availableScreenWidth: CGFloat
    private let scrollsVertically: Bool
    // Preserve the minimum height and keep scrolling rows clear of Help.
    private let helpFooterHeight: CGFloat = 16 + 28 + 24
    @StateObject private var connectedDrives: ConnectedDrivesStore
    @Environment(\.openWindow) private var openWindow
    @State private var isFolderDropTarget = false
    @State private var folderDropError: String?
    @State private var isNewSessionConfirmationPresented = false

    init(
        store: SessionStore,
        availableScreenWidth: CGFloat = NSScreen.main?.visibleFrame.width ?? 1280,
        connectedDrives: ConnectedDrivesStore = ConnectedDrivesStore(),
        scrollsVertically: Bool = false
    ) {
        self.store = store
        self.availableScreenWidth = availableScreenWidth
        self.scrollsVertically = scrollsVertically
        _connectedDrives = StateObject(wrappedValue: connectedDrives)
    }

    // Keep the common case to two quiet columns. Additional drive columns
    // use the display's available width instead of hiding drives in an overflow.
    private var driveColumnCount: Int {
        let recentWidth: CGFloat = store.recentFolders.isEmpty ? 0 : 300
        let available = availableScreenWidth - 64 - recentWidth
        let fittingColumns = max(1, Int((available + 16) / 296))
        return min(fittingColumns, max(1, (connectedDrives.drives.count + 5) / 6))
    }

    private var sourcesWidth: CGFloat {
        let drivesWidth = CGFloat(driveColumnCount) * 280 + CGFloat(driveColumnCount - 1) * 16
        return hasConnectedDrives && !store.recentFolders.isEmpty ? 300 + drivesWidth : max(392, drivesWidth)
    }

    private var hasConnectedDrives: Bool {
        !connectedDrives.drives.isEmpty || connectedDrives.statusMessage != nil
    }

    private var measuredContent: some View {
        welcomeContent
            .frame(width: sourcesWidth)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, helpFooterHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: WelcomeContentSizeKey.self, value: geometry.size)
                }
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if scrollsVertically {
                ScrollView(.vertical) {
                    measuredContent
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom, helpFooterHeight)
            } else {
                measuredContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {
            Button {
                openWindow(id: LouppeHelpWindow.id)
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.louppeAccent)
            .accessibilityLabel(L10n.text("Quick Start and supported formats"))
            .help(L10n.text("Quick Start and supported formats"))
            .padding(24)
        }
        .onAppear { connectedDrives.start() }
        .onDisappear { connectedDrives.stop() }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isFolderDropTarget,
            perform: openDroppedFolder
        )
        .alert(
            L10n.text("Open as a New Session?"),
            isPresented: $isNewSessionConfirmationPresented
        ) {
            Button(L10n.text("Open as New Session"), role: .destructive) {
                store.openIdentityConflictAsNewSession()
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.text("This replaces this folder’s saved decisions and opens its files unrated. Photos and videos stay unchanged.")
            )
        }
        .toolbar { LaunchToolbarTitle() }
        .navigationTitle("")
    }

    private var welcomeContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Button {
                    store.promptForSourceFolder()
                } label: {
                    Label(L10n.text("Choose Media Folder…"), systemImage: "folder")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
                .controlSize(.large)
                .keyboardShortcut("o")

                Label(
                    isFolderDropTarget
                        ? L10n.text("Release to open this folder")
                        : L10n.text("or drag a media folder in this window"),
                    systemImage: isFolderDropTarget
                        ? "folder.badge.plus"
                        : "arrow.down.doc"
                )
                .font(.callout)
                .foregroundStyle(
                    isFolderDropTarget ? Color.louppeAccent : .secondary
                )
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("Open a media folder"))
            .accessibilityHint(L10n.text("Choose a folder or drop one anywhere in this window"))

            if let folderDropError {
                Text(folderDropError)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if let error = store.scanError {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(
                            store.canOpenMismatchedSessionAnyway
                                ? Color.secondary
                                : Color.orange
                        )
                        .multilineTextAlignment(.center)

                    if store.canOpenMismatchedSessionAnyway {
                        Button(L10n.text("Open Anyway")) {
                            store.openMismatchedSessionAnyway()
                        }
                        .accessibilityHint(
                            L10n.text("Loads saved ratings after checking they match the files in this folder")
                        )
                    } else if store.canOpenIdentityConflictAsNewSession {
                        Button(L10n.text("Open as New Session")) {
                            isNewSessionConfirmationPresented = true
                        }
                        .accessibilityHint(
                            L10n.text("Forgets saved decisions for this folder and opens the current files unrated")
                        )
                    }
                }
            }

            if !store.recentFolders.isEmpty || hasConnectedDrives {
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    if !store.recentFolders.isEmpty {
                        recentFolders
                            .frame(width: hasConnectedDrives ? 280 : 392)
                    }
                    if hasConnectedDrives {
                        ConnectedDrivesView(drives: connectedDrives, columnCount: driveColumnCount) { directory in
                            store.promptForSourceFolder(initialDirectory: directory)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

        }
    }

    private var recentFolders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Recent folders"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(store.recentFolders.prefix(5), id: \.path) { url in
                    Button {
                        store.openFolder(url)
                    } label: {
                        WelcomeSourceRow(
                            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                            detail: abbreviatedParentPath(url),
                            symbol: "clock"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Open \(url.path)"))
                    .help(url.path)
                }
            }
        }
    }

    private func abbreviatedParentPath(_ url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func openDroppedFolder(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { item, _ in
            let url: URL?
            if let urlItem = item as? URL {
                url = urlItem
            } else if let urlItem = item as? NSURL {
                url = urlItem as URL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }

            Task { @MainActor in
                guard let url else {
                    folderDropError = L10n.text("Louppe couldn't read the dropped folder. Please try again.")
                    return
                }

                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    folderDropError = L10n.text("Drop a folder containing photos, videos, audio, or text files, not an individual file.")
                    return
                }

                folderDropError = nil
                store.openFolder(url)
            }
        }
        return true
    }
}

/// A compact source shortcut, shown only while physical drives are connected.
/// The native chooser gives the photographer control of the folder to review.
struct ConnectedDrivesView: View {
    @ObservedObject var drives: ConnectedDrivesStore
    var columnCount: Int = 1
    let chooseFolder: (URL) -> Void

    private var rowsPerColumn: Int {
        max(1, (drives.drives.count + columnCount - 1) / columnCount)
    }

    var body: some View {
        if !drives.drives.isEmpty || drives.statusMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Connected drives"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        VStack(spacing: 4) {
                            ForEach(Array(drives.drives.dropFirst(column * rowsPerColumn).prefix(rowsPerColumn))) { drive in
                                driveButton(drive)
                            }
                        }
                        .frame(width: 280)
                    }
                }
                if let message = drives.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func driveButton(_ drive: ConnectedDrive) -> some View {
        Button {
            Task { @MainActor in
                if let directory = await drives.directoryForOpening(drive) {
                    chooseFolder(directory)
                }
            }
        } label: {
            WelcomeSourceRow(
                name: drive.name,
                detail: drive.capacityDescription,
                symbol: "externaldrive",
                isOpening: drives.openingDriveID == drive.id
            )
        }
        .buttonStyle(.plain)
        .disabled(drives.openingDriveID != nil)
        .accessibilityLabel(L10n.text("Choose a media folder on \(drive.name)"))
        .accessibilityValue(drive.capacityDescription)
        .help(L10n.text("Choose a folder on \(drive.name)…\n\(drive.capacityDescription)"))
    }
}

/// Folder and drive shortcuts share one compact, keyboard-accessible row.
private struct WelcomeSourceRow: View {
    let name: String
    let detail: String
    let symbol: String
    var isOpening = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isOpening {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .foregroundStyle(Color.louppeAccent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Shown while a folder scan is in progress.
struct ScanningView: View {
    @ObservedObject var store: SessionStore
    let found: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(L10n.text("Scanning media"))
                .accessibilityValue(progressText)

            Text(L10n.text("Scanning “\(folderName)”…"))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folderPath)
                .accessibilityLabel(L10n.text("Scanning \(folderPath)"))

            Text(progressText)
                .foregroundStyle(.secondary)

        }
        .padding(.horizontal, 40)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    store.cancelScan()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .accessibilityHidden(true)
                        Text(L10n.text("Cancel Scan"))
                    }
                }
                .keyboardShortcut(.cancelAction)
                .help(L10n.text("Cancel scanning and return to the start screen (Esc)"))
            }
            LaunchToolbarTitle()
        }
        .navigationTitle("")
        .onExitCommand {
            store.cancelScan()
        }
    }

    private var folderName: String {
        guard let folder = store.sourceFolder else { return L10n.text("Folder") }
        return folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
    }

    private var folderPath: String {
        store.sourceFolder?.path ?? ""
    }

    private var progressText: String {
        guard found > 0 else { return L10n.text("Looking for media…") }
        return found == 1 ? L10n.text("1 item found") : L10n.text("\(found.formatted()) items found")
    }
}

/// Welcome and Scanning deliberately use a real unified toolbar rather than a
/// custom rounded window. On macOS 26 this gives the launch window Apple's
/// larger native toolbar-window corners while preserving the centered title.
private struct LaunchToolbarTitle: ToolbarContent {
    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                Text("Louppe")
                    .font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                Text("Louppe")
                    .font(.headline)
            }
        }
    }
}
