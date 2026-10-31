import AppKit
import SwiftUI

/// The existing thumbnail strip and the folder tree share one leading pane.
/// Switching its content never opens another folder/session.
struct ArchiveLeadingPaneView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            if store.hasArchiveFolders {
                ArchiveNavigationHeader {
                    HStack(spacing: 6) {
                        ArchivePaneSwitcher(store: store)
                        Spacer(minLength: 0)
                        if store.archiveLeadingPane == .folders {
                            ArchiveExpandAllButton(store: store)
                        }
                    }
                }
                Divider()
            }
            if store.hasArchiveFolders, store.archiveLeadingPane == .folders, let index = store.archiveFolderIndex {
                ArchiveFoldersView(index: index,
                    selectedFolderID: store.archiveSelectedFolderID,
                    expandedFolderIDs: store.archiveExpandedFolderIDs,
                    includesDescendants: store.archiveIncludesDescendants,
                    progress: store.archiveFolderProgress,
                    progressRevision: store.archiveFolderProgressRevision,
                    onSelect: { store.selectArchiveFolder($0) },
                    onExpansionChange: { store.setArchiveExpandedFolders($0) },
                    onIncludesDescendantsChange: { store.setArchiveIncludesDescendants($0) })
                .disabled(store.isFileOperationRunning || store.isSessionTransitioning || store.isPreparingForTermination || store.isSessionCommandPresentationActive)
            } else {
                BrowserView(store: store,
                    initialViewportReceipt: store.pendingOpeningViewportReceipt(for: .browser).map {
                        ReviewCollectionViewportReceipt(physicalFileID: $0.physicalFileID, topOffset: CGFloat($0.topOffset))
                    },
                    onViewportRestored: { _ in store.consumeOpeningViewportReceipt(for: .browser) })
                    .id(store.archiveViewportGeneration)
            }
        }
        .frame(width: showsFolders ? store.archiveFolderPaneWidth : BrowserView.width)
        .background(Color.appBackground)
    }

    private var showsFolders: Bool { store.archiveLeadingPane == .folders && store.hasArchiveFolders }
}

/// Lays the folder splitter over the pane's trailing edge. It sits above the
/// whole row, so neither the outline nor the media view below takes its clicks.
struct ArchivePaneResizeOverlay: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, store.archiveFolderPaneWidth - 3))
                .allowsHitTesting(false)
            ArchivePaneSplitter(store: store)
                .frame(width: 7)
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
    }
}

/// Drag to fit long or deeply nested folder names, like a Finder sidebar;
/// double-click restores the standard width. VoiceOver adjusts it as a splitter.
struct ArchivePaneSplitter: NSViewRepresentable {
    @ObservedObject var store: SessionStore
    @Environment(\.layoutDirection) private var layoutDirection

    func makeNSView(context: Context) -> SplitterView {
        let view = SplitterView()
        update(view)
        return view
    }

    func updateNSView(_ view: SplitterView, context: Context) { update(view) }

    private func update(_ view: SplitterView) {
        view.isRightToLeft = layoutDirection == .rightToLeft
        view.width = { [weak store] in store?.archiveFolderPaneWidth ?? ArchiveFolderPaneWidth.standard }
        view.setWidth = { [weak store] in store?.archiveFolderPaneWidth = ArchiveFolderPaneWidth.clamped($0.rounded()) }
        view.commit = { [weak store] in store?.commitArchiveFolderPaneWidth() }
    }

    @MainActor
    final class SplitterView: NSView {
        var isRightToLeft = false
        var width: () -> CGFloat = { ArchiveFolderPaneWidth.standard }
        var setWidth: (CGFloat) -> Void = { _ in }
        var commit: () -> Void = {}
        private var dragStart: (x: CGFloat, width: CGFloat)?

        override func resetCursorRects() {
            if #available(macOS 15.0, *) {
                addCursorRect(bounds, cursor: .columnResize)
            } else {
                addCursorRect(bounds, cursor: .resizeLeftRight)
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                dragStart = nil
                setWidth(ArchiveFolderPaneWidth.standard)
                commit()
                return
            }
            dragStart = (event.locationInWindow.x, width())
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let delta = (event.locationInWindow.x - start.x) * (isRightToLeft ? -1 : 1)
            setWidth(ArchiveFolderPaneWidth.clamped(start.width + delta))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            commit()
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { L10n.text("Folders width") }
        override func accessibilityValue() -> Any? { NSNumber(value: Double(width())) }
        override func accessibilityPerformIncrement() -> Bool { step(by: 20) }
        override func accessibilityPerformDecrement() -> Bool { step(by: -20) }

        private func step(by amount: CGFloat) -> Bool {
            setWidth(ArchiveFolderPaneWidth.clamped(width() + amount))
            commit()
            return true
        }
    }
}

/// One click switches the pane's content. Grid has no Browser, so choosing it
/// there returns to Gallery with the Browser showing.
struct ArchivePaneSwitcher: View {
    @ObservedObject var store: SessionStore
    @AppStorage(ReviewShortcutPreferences.preferenceKey) private var shortcutSettings = ""

    var body: some View {
        let shortcuts = ReviewShortcutPreferences.decode(shortcutSettings)
        Picker(L10n.text("Navigation"), selection: Binding(
            get: { store.archiveLeadingPane },
            set: { store.showLeadingPane($0) }
        )) {
            Label(L10n.text("Browser"), systemImage: "photo.on.rectangle")
                .labelStyle(.iconOnly)
                .help(Self.help(L10n.text("Browser"), shortcuts.hint(for: .browser)))
                .tag(ArchiveLeadingPane.browser)
            Label(L10n.text("Folders"), systemImage: "folder")
                .labelStyle(.iconOnly)
                .help(Self.help(L10n.text("Folders"), shortcuts.hint(for: .folders)))
                .tag(ArchiveLeadingPane.folders)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private static func help(_ title: String, _ hint: String) -> String {
        hint.isEmpty ? title : "\(title) (\(hint))"
    }
}

/// Obsidian-style single toggle: Collapse All while any folder is open,
/// otherwise Expand All. The current folder's path always stays visible.
struct ArchiveExpandAllButton: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let summary = store.archiveExpansionSummary
        let collapses = summary.canCollapse
        Button {
            if collapses { store.collapseAllArchiveFolders() } else { store.expandAllArchiveFolders() }
        } label: {
            Group {
                if collapses { CollapseAllGlyph() } else { Image(systemName: "chevron.up.chevron.down") }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!summary.canCollapse && !summary.canExpand)
        .help(collapses ? L10n.text("Collapse All") : L10n.text("Expand All"))
        .accessibilityLabel(collapses ? L10n.text("Collapse All") : L10n.text("Expand All"))
    }
}

/// SF Symbols has no inward pair for chevron.up.chevron.down; two native
/// chevrons sized to that symbol's frame keep the same weight and tint.
struct CollapseAllGlyph: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .hidden()
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.down")
                    Image(systemName: "chevron.up")
                }
                .font(.system(size: 10, weight: .medium))
            }
            .accessibilityHidden(true)
    }
}

/// Both pane headers share native control space so their divider is continuous.
/// The minimum leaves room for regular controls without forcing an older bezel size.
struct ArchiveNavigationHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(Color.appBackground)
    }
}

struct ArchiveBreadcrumbView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        ArchiveNavigationHeader {
            HStack(spacing: 6) {
                if store.archiveSelectedFolderID.isEmpty {
                    Text(L10n.text("All Media")).font(.callout)
                } else {
                    Button { store.selectArchiveFolder("") } label: {
                        Text(L10n.text("All Media")).font(.callout)
                    }
                        .buttonStyle(.plain)
                    Image(systemName: "chevron.forward").foregroundStyle(.secondary)
                    Menu {
                        ForEach(store.archiveBreadcrumbs) { node in
                            Button(node.id.isEmpty ? L10n.text("All Media") : node.name) {
                                store.selectArchiveFolder(node.id)
                            }
                        }
                        Divider()
                        Toggle(L10n.text("Include Subfolders"), isOn: Binding(
                            get: { store.archiveIncludesDescendants },
                            set: { store.setArchiveIncludesDescendants($0) }))
                    } label: {
                        Text(verbatim: store.archiveFolderIndex?.node(for: store.archiveSelectedFolderID)?.name ?? "")
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .help(store.archiveScopeDescription ?? "")
            .disabled(store.isFileOperationRunning || store.isSessionTransitioning || store.isSessionCommandPresentationActive)
        }
    }
}

struct ArchiveNavigationWarningView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        if let warning = store.archiveNavigationWarning {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: warning)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.text("Retry")) { Task { await store.flushArchiveNavigation() } }
                    if store.archiveNavigationCanReset {
                        Button(L10n.text("Reset Folder Navigation")) {
                            Task { await store.resetArchiveNavigationStorage() }
                        }
                    }
                }
                .fixedSize()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appBackground)
        }
    }
}

struct ArchiveFolderEmptyView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        ContentUnavailableView {
            Label(L10n.text("No media in this folder"), systemImage: "folder")
        } description: {
            Text(L10n.text("Choose another folder or include subfolders."))
        } actions: {
            if !store.archiveIncludesDescendants {
                Button(L10n.text("Include Subfolders")) { store.setArchiveIncludesDescendants(true) }
            }
            Button(L10n.text("All Media")) { store.selectArchiveFolder("") }
        }
    }
}

struct ArchiveActionScopeNote: View {
    @ObservedObject var store: SessionStore
    var body: some View {
        if let context = store.archiveScopeDescription {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: context)
                if store.rawJPEGPairingMode == .together {
                    Text(L10n.text("RAW + JPEG pairs stay together, even across folders."))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
