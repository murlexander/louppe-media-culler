import AppKit
import Combine

/// Native shortcut columns while menus are tracking. Outside deliberate menu
/// navigation, SessionView remains the sole owner of Louppe shortcut routing.
@MainActor
final class MenuShortcutColumns {
    private weak var store: SessionStore?
    private let defaults: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private var isRefreshing = false
    private var lastEntries: [Entry]?
    private weak var lastMenu: NSMenu?
    private var trackingMenus: [ObjectIdentifier: WeakMenu] = [:]
    private let presentation = MenuShortcutPresentation()

    private struct WeakMenu { weak var menu: NSMenu? }

    init(store: SessionStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        store.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &subscriptions)
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { @Sendable [weak self] notification in
                    // SwiftUI can populate a submenu after tracking starts.
                    // A queued Task need not run in AppKit's tracking run loop;
                    // decorate attached items now, before AppKit draws them.
                    // refresh's guard prevents our own title notifications
                    // from recursively refreshing the menu tree.
                    guard Thread.isMainThread else { return }
                    let ancestors = Self.menuAncestorIDs(notification.object as? NSMenu)
                    MainActor.assumeIsolated {
                        guard Self.belongsToMainMenu(ancestors) else { return }
                        self?.refresh()
                    }
                }.store(in: &subscriptions)
        }
        // Synchronous refresh before tracking catches newly rebuilt SwiftUI
        // menus without taking over their delegates or target/action pairs.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { @Sendable [weak self] notification in
                guard Thread.isMainThread else { return }
                let ancestors = Self.menuAncestorIDs(notification.object as? NSMenu)
                let menuID = ancestors.first
                let isEnding = notification.name == NSMenu.didEndTrackingNotification
                MainActor.assumeIsolated {
                    guard let self, let menuID else { return }
                    if isEnding {
                        guard self.trackingMenus.values.contains(where: {
                            Self.menuAncestorIDs($0.menu).contains(menuID)
                        }) else { return }
                        // Ending a parent also ends its descendants, even if
                        // AppKit coalesces their individual end notifications.
                        self.trackingMenus = self.trackingMenus.filter {
                            !Self.menuAncestorIDs($0.value.menu).contains(menuID)
                        }
                    } else {
                        guard Self.belongsToMainMenu(ancestors), let mainMenu = NSApp.mainMenu,
                              let menu = Self.findMenu(menuID, in: mainMenu) else { return }
                        self.trackingMenus[menuID] = WeakMenu(menu: menu)
                    }
                    self.refresh()
                }
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { @Sendable [weak self] _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    self?.trackingMenus.removeAll()
                    self?.refresh()
                }
            }.store(in: &subscriptions)
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !isRefreshing, !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            // Store publishers announce before the new value is installed.
            await Task.yield()
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh(onlyIfChanged: true)
        }
    }

    // Called only after the notification handler's main-thread guard. Pass
    // immutable identities into assumeIsolated rather than an AppKit object
    // (NSMenu itself is not Sendable in the supported SDK).
    private nonisolated static func menuAncestorIDs(_ menu: NSMenu?) -> [ObjectIdentifier] {
        var identities: [ObjectIdentifier] = []
        var ancestor = menu
        while let menu = ancestor {
            identities.append(ObjectIdentifier(menu))
            ancestor = menu.supermenu
        }
        return identities
    }

    private static func belongsToMainMenu(_ ancestors: [ObjectIdentifier]) -> Bool {
        guard let mainMenu = NSApp.mainMenu else { return false }
        return ancestors.contains(ObjectIdentifier(mainMenu))
    }

    private static func findMenu(_ identity: ObjectIdentifier, in menu: NSMenu) -> NSMenu? {
        if ObjectIdentifier(menu) == identity { return menu }
        for item in menu.items {
            if let submenu = item.submenu, let match = findMenu(identity, in: submenu) { return match }
        }
        return nil
    }

    func refresh() { refresh(onlyIfChanged: false) }

    private func refresh(onlyIfChanged: Bool) {
        guard !isRefreshing, let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let mainMenu = NSApp.mainMenu else {
            presentation.clear()
            trackingMenus.removeAll()
            lastMenu = nil
            return
        }
        if let lastMenu, lastMenu !== mainMenu {
            presentation.clear()
            trackingMenus.removeAll()
        }
        trackingMenus = trackingMenus.filter { Self.belongsToMainMenu(Self.menuAncestorIDs($0.value.menu)) }
        let context = ReviewShortcutContext(
            viewMode: store.viewMode, mediaKind: store.currentItem?.mediaKind,
            isPlayable: store.currentItem?.isPlayableMedia == true,
            canSeekVideo: store.canSeekCurrentVideo
        )
        let entries = Self.entries(preferences: .load(from: defaults),
                                   commandPreferences: .load(from: defaults), context: context)
        // Ordinary state publications (loading, quality checks, ratings) do
        // not change these hints. Structural/tracking notifications always
        // bypass this cache so lazy menu creation is still styled immediately.
        if onlyIfChanged, lastMenu === mainMenu, lastEntries == entries { return }
        presentation.apply(entries, to: mainMenu, isTracking: !trackingMenus.isEmpty)
        lastEntries = entries
        lastMenu = mainMenu
    }

    struct Entry: Equatable {
        let title: String
        let hint: String
        let accessibilityHint: String
    }

    static func entries(
        preferences: ReviewShortcutPreferences,
        commandPreferences: CommandShortcutPreferences = .init(),
        context: ReviewShortcutContext
    ) -> [Entry] {
        func entry(_ title: L10n.Message, action: ReviewShortcutAction? = nil,
                   command: CommandShortcutAction? = nil) -> Entry {
            let assignments = action.map { action in
                preferences.assignments(for: action).filter {
                    preferences.effectiveContexts(for: action, scope: $0.scope).contains(context)
                }
            } ?? []
            // Physical mode's longer "F position" explanation belongs in Help,
            // while the menu uses the compact physical keycap label.
            var hints: [String] = []
            for assignment in assignments {
                let binding = assignment.binding
                let label: String
                if preferences.interpretation == .physicalPosition,
                   let position = ReviewShortcutBinding.positionLabels[binding.keyCode] {
                    label = position.uppercased()
                } else {
                    label = preferences.display(for: binding)
                }
                if !hints.contains(label) { hints.append(label) }
            }
            let commandHint = command.map { commandPreferences.hint(for: $0) } ?? ""
            if !commandHint.isEmpty { hints.append(commandHint) }
            let explanation = [action.map { preferences.hint(for: $0, context: context) } ?? "", commandHint]
                .filter { !$0.isEmpty }.joined(separator: " / ")
            return Entry(title: L10n.text(title), hint: hints.joined(separator: " / "), accessibilityHint: explanation)
        }
        return [
            entry("Command Palette…", command: .commandPalette),
            entry("Rescan Folder", command: .rescan),
            entry("Undo Louppe Action", action: .undo, command: .undo),
            entry("Clear All Decisions…", action: .clear),
            entry("Export…", action: .export, command: .export),
            entry("Gallery", action: .grid),
            entry("Grid", action: .grid),
            entry("Browser", action: .browser),
            entry("Folders", action: .folders),
            entry("Previous Folder", action: .previousFolder),
            entry("Next Folder", action: .nextFolder),
            entry("Enclosing Folder", command: .enclosingFolder),
            entry("Zoom In", command: .zoomIn),
            entry("Zoom Out", command: .zoomOut),
            entry("View Photo at 100%", action: .actualSize),
            entry("View Photo at Phone Size", action: .phoneSize),
        ]
    }

}

/// AppKit owns the font, spacing, writing direction and shared trailing column.
/// Equivalent strings are installed only during explicit native menu tracking;
/// restoring them removes every alternate route around the session monitor.
@MainActor
final class MenuShortcutPresentation {
    private struct Original {
        weak var item: NSMenuItem?
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let automaticLocalization: Bool
        let automaticMirroring: Bool

        func restore() {
            item?.keyEquivalent = key
            item?.keyEquivalentModifierMask = modifiers
            item?.allowsAutomaticKeyEquivalentLocalization = automaticLocalization
            item?.allowsAutomaticKeyEquivalentMirroring = automaticMirroring
        }
    }
    private var originals: [ObjectIdentifier: Original] = [:]

    isolated deinit { clear() }

    func clear() {
        let previous = originals
        originals.removeAll()
        for original in previous.values {
            original.restore()
        }
    }

    func apply(_ entries: [MenuShortcutColumns.Entry], to menu: NSMenu, isTracking: Bool) {
        if !isTracking { clear() }
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0) })
        var visited: Set<ObjectIdentifier> = []
        decorate(byTitle, in: menu, isTracking: isTracking, visited: &visited)
        for id in Array(originals.keys) where !visited.contains(id) {
            guard let original = originals.removeValue(forKey: id) else { continue }
            original.restore()
        }
    }

    private func decorate(_ entries: [String: MenuShortcutColumns.Entry], in menu: NSMenu,
                          isTracking: Bool, visited: inout Set<ObjectIdentifier>) {
        for item in menu.items {
            if let entry = entries[item.title] {
                let id = ObjectIdentifier(item)
                visited.insert(id)
                // SwiftUI may replace a deallocated row at the same address.
                // Only restore an original that belongs to this live item.
                if originals[id]?.item !== item { originals.removeValue(forKey: id) }
                // Standard system equivalents (Open, Close, etc.) stay intact.
                if isTracking, originals[id] != nil || item.keyEquivalent.isEmpty {
                    if originals[id] == nil {
                        originals[id] = Original(item: item, key: item.keyEquivalent,
                                                 modifiers: item.keyEquivalentModifierMask,
                                                 automaticLocalization: item.allowsAutomaticKeyEquivalentLocalization,
                                                 automaticMirroring: item.allowsAutomaticKeyEquivalentMirroring)
                    }
                    if item.keyEquivalent != entry.hint { item.keyEquivalent = entry.hint }
                    if item.keyEquivalentModifierMask != [] { item.keyEquivalentModifierMask = [] }
                    item.allowsAutomaticKeyEquivalentLocalization = false
                    item.allowsAutomaticKeyEquivalentMirroring = false
                }
                item.setAccessibilityTitle(entry.title)
                item.setAccessibilityLabel(entry.title)
                item.setAccessibilityHelp(entry.accessibilityHint.isEmpty ? nil : entry.accessibilityHint)
                item.toolTip = entry.accessibilityHint.isEmpty ? nil : entry.accessibilityHint
            }
            if let submenu = item.submenu {
                decorate(entries, in: submenu, isTracking: isTracking, visited: &visited)
            }
        }
    }
}
