import AppKit
import SwiftUI

/// One native outline over the already prepared archive. No row owns scanning,
/// media requests, decision persistence or file-operation authority.
struct ArchiveFoldersView: NSViewRepresentable {
    let index: ArchiveFolderIndex
    let selectedFolderID: String
    let expandedFolderIDs: Set<String>
    let includesDescendants: Bool
    var progress: ArchiveFolderProgress? = nil
    var progressRevision = 0
    let onSelect: (String) -> Void
    let onExpansionChange: (Set<String>) -> Void
    let onIncludesDescendantsChange: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.update(scroll)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle(scroll)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var owner: ArchiveFoldersView
        private var items: [String: FolderItem] = [:]
        private var generation: UUID?
        private var expanded: Set<String> = []
        private var applying = false
        private var countsIncludeDescendants = true
        private var selectedFolderID: String?
        private var pendingExpansionReport = false
        private var appliedSource: Set<String>?
        private var progressRevision: Int?
        private var progressGeneration: UUID?
        private(set) var reloadCount = 0
        private weak var outline: OutlineView?

        init(owner: ArchiveFoldersView) { self.owner = owner }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.contentView = VerticalClipView()
            scroll.drawsBackground = true
            scroll.backgroundColor = NSColor(Color.appBackground)
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.horizontalScrollElasticity = .none
            scroll.borderType = .noBorder

            let outline = OutlineView()
            outline.headerView = nil
            outline.style = .sourceList
            outline.backgroundColor = NSColor(Color.appBackground)
            outline.rowSizeStyle = .default
            outline.intercellSpacing = NSSize(width: 0, height: 0)
            outline.allowsMultipleSelection = false
            outline.allowsEmptySelection = false
            // Unassigned letters must not jump to a folder and change scope;
            // review letters already belong to the session.
            outline.allowsTypeSelect = false
            outline.autoresizingMask = [.width]
            outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            outline.setAccessibilityLabel(L10n.text("Folders"))
            outline.setAccessibilityIdentifier("archive.folders")
            outline.dataSource = self
            outline.delegate = self
            outline.contextMenu = { [weak self] row in self?.menu(forRow: row) }
            outline.onExpansionBatchEnd = { [weak self] in self?.reportExpansion() }
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("archive.folder"))
            column.resizingMask = .autoresizingMask
            column.minWidth = 60
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            scroll.documentView = outline
            self.outline = outline
            update(scroll)
            return scroll
        }

        func update(_ scroll: NSScrollView) {
            guard let outline = scroll.documentView as? OutlineView else { return }
            applying = true
            defer { applying = false }
            let direction: NSUserInterfaceLayoutDirection = owner.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
            let changedDirection = outline.userInterfaceLayoutDirection != direction
            scroll.userInterfaceLayoutDirection = direction
            outline.userInterfaceLayoutDirection = direction
            let previousOrigin = scroll.contentView.bounds.origin
            let changedIndex = generation != owner.index.generation
            let firstMount = generation == nil
            let changedCounts = countsIncludeDescendants != owner.includesDescendants
            let changedSelection = selectedFolderID != owner.selectedFolderID
            // A native expansion not yet reported to the store is newer than
            // the store's copy; applying the stale copy would undo the click.
            let source = pendingExpansionReport ? expanded : owner.expandedFolderIDs
            if changedIndex {
                items = owner.index.nodes.mapValues { FolderItem(node: $0, generation: owner.index.generation) }
                generation = owner.index.generation
                outline.reloadData()
                reloadCount += 1
                expanded = []
            }
            countsIncludeDescendants = owner.includesDescendants
            // SwiftUI updates this view for every store change, including
            // ratings. Unchanged sets share storage, so this check is cheap.
            var bulkChange = false
            if changedIndex || changedSelection || appliedSource != source {
                bulkChange = applyExpansion(source, to: outline)
                appliedSource = source
            }
            if let selected = items[owner.selectedFolderID] {
                let row = outline.row(forItem: selected)
                if row >= 0, outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            }
            selectedFolderID = owner.selectedFolderID
            if (changedCounts || changedDirection) && !changedIndex && outline.numberOfRows > 0 {
                outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                                   columnIndexes: IndexSet(integer: 0))
            } else if !changedIndex, progressRevision != owner.progressRevision
                        || progressGeneration != owner.progress?.generation {
                // A decision changed: refresh only the rows on screen.
                let visible = outline.rows(in: outline.visibleRect)
                if visible.length > 0 {
                    outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
                                       columnIndexes: IndexSet(integer: 0))
                }
            }
            progressRevision = owner.progressRevision
            progressGeneration = owner.progress?.generation
            if firstMount, outline.selectedRow >= 0 {
                // A remembered folder late in the tree starts on screen.
                outline.scrollRowToVisible(outline.selectedRow)
            } else if changedIndex {
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(
                    NSRect(origin: previousOrigin, size: scroll.contentView.bounds.size)).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            } else if (changedSelection || bulkChange), outline.selectedRow >= 0 {
                outline.scrollRowToVisible(outline.selectedRow)
            }
        }

        /// Applies the store's expansion set. Returns true for bulk changes
        /// (Expand/Collapse All), which use one recursive native call instead
        /// of thousands of individual row insertions.
        private func applyExpansion(_ source: Set<String>, to outline: OutlineView) -> Bool {
            var desired = source.filter { items[$0] != nil }
            // A restored selection remains reachable, without expanding its
            // descendants or creating views for unrelated directories.
            let ancestors = owner.index.breadcrumbs(to: owner.selectedFolderID).dropLast().map(\.id)
            desired.formUnion(ancestors)
            let collapsing = expanded.subtracting(desired)
            var expanding = desired.subtracting(expanded)
            guard !collapsing.isEmpty || !expanding.isEmpty else { return false }
            var bulk = false
            if collapsing.count > Self.bulkThreshold {
                outline.collapseItem(nil, collapseChildren: true)
                expanded = []
                expanding = desired
                bulk = true
            } else {
                // Children first, so a later parent expansion cannot natively
                // restore a child the store has collapsed.
                for id in collapsing.sorted(by: { Self.depth($0) > Self.depth($1) }) {
                    if let item = items[id] { outline.collapseItem(item) }
                }
            }
            if expanding.count > Self.bulkThreshold,
               owner.index.expandableFolderIDs.allSatisfy(desired.contains) {
                outline.expandItem(nil, expandChildren: true)
                bulk = true
            } else {
                for id in expanding.sorted(by: {
                    let left = Self.depth($0), right = Self.depth($1)
                    return left == right ? $0 < $1 : left < right
                }) {
                    if let item = items[id] { outline.expandItem(item) }
                }
            }
            expanded = desired
            return bulk || collapsing.count + expanding.count > 1
        }

        private static let bulkThreshold = 32
        private static func depth(_ id: String) -> Int {
            id.isEmpty ? 0 : id.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
        }

        func dismantle(_ scroll: NSScrollView) {
            applying = true
            outline?.contextMenu = nil
            outline?.onExpansionBatchEnd = nil
            outline?.delegate = nil
            outline?.dataSource = nil
            outline = nil
            items = [:]
            generation = nil
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item else { return items[owner.index.rootID] == nil ? 0 : 1 }
            guard let folder = current(item) else { return 0 }
            return folder.node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil, let root = items[owner.index.rootID] { return root }
            guard let item, let folder = current(item),
                  folder.node.children.indices.contains(index),
                  let child = items[folder.node.children[index]] else { return NSObject() }
            return child
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            current(item)?.node.children.isEmpty == false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let folder = current(item) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("archive.folder.cell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? FolderCell) ?? FolderCell()
            cell.identifier = identifier
            let node = folder.node
            let name = node.id == owner.index.rootID ? L10n.text("All Media") : node.name
            let count = node.id.isEmpty || owner.includesDescendants ? node.subtreeCount : node.directCount
            let complete = owner.progress?.isComplete(node.id, includesDescendants: owner.includesDescendants,
                                                      index: owner.index) ?? false
            cell.configure(id: node.id, name: name, count: count, isComplete: complete,
                           direction: outlineView.userInterfaceLayoutDirection)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            owner.isEnabled && current(item) != nil
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            // A recursive collapse moves the native selection level by level;
            // reportExpansion settles the scope once when AppKit finishes.
            guard !applying, owner.isEnabled, let outline, outline.expansionBatchDepth == 0,
                  let item = outline.item(atRow: outline.selectedRow), let folder = current(item),
                  folder.node.id != owner.selectedFolderID else { return }
            owner.onSelect(folder.node.id)
        }

        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, isExpanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, isExpanded: false) }

        private func expansionChanged(_ notification: Notification, isExpanded: Bool) {
            guard !applying, let item = notification.userInfo?["NSObject"],
                  let folder = current(item) else { return }
            if isExpanded { expanded.insert(folder.node.id) }
            else { expanded.remove(folder.node.id) }
            // Option-click expands a whole subtree with one notification per
            // folder. Report the final set once, when that native call returns.
            pendingExpansionReport = true
            if outline?.expansionBatchDepth ?? 0 == 0 { reportExpansion() }
        }

        /// Reports the final expansion set. When a user collapse hid the
        /// current folder, selection moves once to the nearest visible
        /// ancestor (the native outline rule), never through each level.
        private func reportExpansion() {
            guard pendingExpansionReport else { return }
            pendingExpansionReport = false
            guard outline != nil else { return }
            owner.onExpansionChange(expanded)
            let path = owner.index.breadcrumbs(to: owner.selectedFolderID).dropLast()
            if let hidden = path.first(where: { !expanded.contains($0.id) }) {
                owner.onSelect(hidden.id)
            }
        }

        private func current(_ item: Any) -> FolderItem? {
            guard let folder = item as? FolderItem,
                  folder.generation == generation,
                  items[folder.node.id] === folder else { return nil }
            return folder
        }

        func menu(forRow row: Int) -> NSMenu? {
            guard owner.isEnabled, let outline, row >= 0,
                  let item = outline.item(atRow: row), let folder = current(item) else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            // All Media always includes every subfolder.
            if !folder.node.id.isEmpty {
                let include = NSMenuItem(title: L10n.text("Include Subfolders"),
                                         action: #selector(toggleDescendants(_:)), keyEquivalent: "")
                include.target = self
                include.state = owner.includesDescendants ? .on : .off
                include.representedObject = MenuRequest(folder: folder, includesDescendants: !owner.includesDescendants)
                menu.addItem(include)
                menu.addItem(.separator())
            }
            // Read-only: Finder shows the folder; nothing in it changes.
            let reveal = NSMenuItem(title: L10n.text("Show in Finder"),
                                    action: #selector(showInFinder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = folder
            menu.addItem(reveal)
            return menu
        }

        @objc func showInFinder(_ sender: NSMenuItem) {
            guard let folder = sender.representedObject as? FolderItem, current(folder) != nil,
                  let url = owner.index.url(for: folder.node.id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc func toggleDescendants(_ sender: NSMenuItem) {
            guard owner.isEnabled, let request = sender.representedObject as? MenuRequest,
                  let folder = current(request.folder) else { return }
            if owner.selectedFolderID != folder.node.id { owner.onSelect(folder.node.id) }
            owner.onIncludesDescendantsChange(request.includesDescendants)
        }
    }

    @MainActor
    final class FolderItem: NSObject {
        let node: ArchiveFolderIndex.Node
        let generation: UUID
        init(node: ArchiveFolderIndex.Node, generation: UUID) { self.node = node; self.generation = generation }
    }

    @MainActor
    private final class MenuRequest: NSObject {
        let folder: FolderItem
        let includesDescendants: Bool
        init(folder: FolderItem, includesDescendants: Bool) {
            self.folder = folder; self.includesDescendants = includesDescendants
        }
    }

    @MainActor
    final class OutlineView: NSOutlineView {
        var contextMenu: ((Int) -> NSMenu?)?
        var onExpansionBatchEnd: (() -> Void)?
        private(set) var expansionBatchDepth = 0

        override func expandItem(_ item: Any?, expandChildren: Bool) {
            expansionBatchDepth += 1
            super.expandItem(item, expandChildren: expandChildren)
            expansionBatchDepth -= 1
            if expansionBatchDepth == 0 { onExpansionBatchEnd?() }
        }

        /// A click chooses a folder but leaves review keys with the media, as
        /// after a thumbnail click (like a Finder sidebar). Tab, Full Keyboard
        /// Access and VoiceOver can still focus the tree for native arrows.
        override var acceptsFirstResponder: Bool {
            guard super.acceptsFirstResponder else { return false }
            return window?.firstResponder === self || !Self.isPointerEvent(NSApp.currentEvent)
        }

        override func mouseDown(with event: NSEvent) {
            let wasFocused = window?.firstResponder === self
            super.mouseDown(with: event)
            finishClick(wasFocused: wasFocused)
        }

        /// Fallback for AppKit paths that assign focus before asking.
        func finishClick(wasFocused: Bool) {
            if !wasFocused, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }

        static func isPointerEvent(_ event: NSEvent?) -> Bool {
            guard let type = event?.type else { return false }
            return [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp].contains(type)
        }

        override func collapseItem(_ item: Any?, collapseChildren: Bool) {
            expansionBatchDepth += 1
            super.collapseItem(item, collapseChildren: collapseChildren)
            expansionBatchDepth -= 1
            if expansionBatchDepth == 0 { onExpansionBatchEnd?() }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
        }
    }

    @MainActor
    final class VerticalClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var result = super.constrainBoundsRect(proposedBounds)
            result.origin.x = 0
            return result
        }
        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
        }
    }

    @MainActor
    final class FolderCell: NSTableCellView {
        let nameField = NSTextField(labelWithString: "")
        let countField = NSTextField(labelWithString: "")
        /// Quiet completion mark: every item in this folder has Yes or No.
        let completeView = NSImageView()
        private var completeWidth: NSLayoutConstraint!

        init() {
            super.init(frame: .zero)
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            icon.contentTintColor = .louppeAccentColor
            icon.setAccessibilityElement(false)
            imageView = icon
            textField = nameField
            nameField.lineBreakMode = .byTruncatingMiddle
            nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            countField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            countField.textColor = .secondaryLabelColor
            countField.alignment = .right
            countField.setContentCompressionResistancePriority(.required, for: .horizontal)
            countField.setAccessibilityElement(false)
            completeView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .semibold))
            completeView.contentTintColor = .secondaryLabelColor
            completeView.setAccessibilityElement(false)
            completeView.isHidden = true
            for view in [icon, nameField, completeView, countField] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            completeWidth = completeView.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
                completeWidth,
                completeView.trailingAnchor.constraint(equalTo: countField.leadingAnchor, constant: -3),
                completeView.centerYAnchor.constraint(equalTo: centerYAnchor),
                countField.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            // Extreme nesting can leave less room than the fixed parts need.
            // Yield the trailing pin instead of breaking layout; widening the
            // pane restores the count.
            let trailing = countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
            trailing.priority = .defaultHigh
            trailing.isActive = true
            let nameFits = nameField.trailingAnchor.constraint(lessThanOrEqualTo: completeView.leadingAnchor, constant: -6)
            nameFits.priority = .defaultHigh
            nameFits.isActive = true
        }

        required init?(coder: NSCoder) { nil }

        func configure(id: String, name: String, count: Int, isComplete: Bool = false,
                       direction: NSUserInterfaceLayoutDirection = .leftToRight) {
            userInterfaceLayoutDirection = direction
            for view in subviews { view.userInterfaceLayoutDirection = direction }
            nameField.alignment = direction == .rightToLeft ? .right : .left
            countField.alignment = direction == .rightToLeft ? .left : .right
            nameField.stringValue = name
            // Empty folders stay listed but recede, so media-bearing rows lead.
            nameField.textColor = count == 0 ? .secondaryLabelColor : .labelColor
            countField.stringValue = count.formatted()
            completeView.isHidden = !isComplete
            completeWidth.constant = isComplete ? 12 : 0
            toolTip = isComplete ? name + "\n" + L10n.text("All reviewed") : name
            setAccessibilityIdentifier("archive.folder.\(id)")
            var label = name + ", " + L10n.text("\(count) items")
            if isComplete { label += ", " + L10n.text("All reviewed") }
            nameField.setAccessibilityLabel(label)
        }
    }
}
