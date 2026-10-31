import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ArchiveFoldersOutlineTests: XCTestCase {
    func testNativeHierarchyIncludesEmptyFoldersAndSelectionPublishesOnlyUserChanges() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertFalse(fixture.window.isKeyWindow)
        XCTAssertEqual(fixture.outline.numberOfRows, 4)
        let all = try XCTUnwrap(fixture.item(""))
        XCTAssertTrue(fixture.outline.isItemExpanded(all))
        let empty = try XCTUnwrap(fixture.item("Empty"))
        XCTAssertFalse(fixture.outline.isExpandable(empty))
        let cell = try XCTUnwrap(fixture.coordinator.outlineView(fixture.outline,
            viewFor: fixture.outline.outlineTableColumn, item: empty) as? ArchiveFoldersView.FolderCell)
        XCTAssertEqual(cell.nameField.stringValue, "Empty")
        XCTAssertEqual(cell.countField.stringValue, "0")
        XCTAssertEqual(cell.nameField.accessibilityLabel(), "Empty, " + L10n.text("\(0) items"))

        let a = try XCTUnwrap(fixture.item("A"))
        fixture.outline.selectRowIndexes(IndexSet(integer: fixture.outline.row(forItem: a)), byExtendingSelection: false)
        XCTAssertEqual(fixture.state.selections, ["A"])
        fixture.update()
        fixture.update()
        XCTAssertEqual(fixture.state.selections, ["A"], "representable updates do not feed selection back")
        XCTAssertEqual(fixture.coordinator.reloadCount, 1, "rating publications keep native rows and expansion")
    }

    func testNativeDisclosureAndExternalExpansionRetainPreparedIdentity() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let a = try XCTUnwrap(fixture.item("A"))
        fixture.outline.expandItem(a)
        XCTAssertTrue(fixture.state.expanded.contains("A"))
        XCTAssertEqual(fixture.outline.numberOfRows, 5)
        let nested = try XCTUnwrap(fixture.item("A/Nested"))
        fixture.state.selected = "A/Nested"
        fixture.update()
        XCTAssertTrue(fixture.outline.item(atRow: fixture.outline.selectedRow) as AnyObject === nested)
        fixture.outline.collapseItem(a)
        XCTAssertFalse(fixture.state.expanded.contains("A"))
        fixture.state.selected = "A"
        fixture.update()
        XCTAssertFalse(fixture.outline.isItemExpanded(a))
        XCTAssertEqual(fixture.coordinator.reloadCount, 1)
    }

    func testRestoredExpansionRealizesAncestorsBeforeChildrenAndCollapseSelectsVisibleAncestor() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.state.selected = "A/Nested"
        fixture.state.expanded = ["", "A"]
        fixture.state.index = fixture.state.index.reproject(items: [])
        fixture.update()
        let a = try XCTUnwrap(fixture.item("A"))
        XCTAssertTrue(fixture.outline.isItemExpanded(a))
        XCTAssertNotNil(fixture.item("A/Nested"))
        fixture.outline.collapseItem(a)
        XCTAssertEqual(fixture.state.selected, "A")
        fixture.update()
        XCTAssertFalse(fixture.outline.isItemExpanded(a))
    }

    func testContextMenuOffersDirectFolderScopeAndRejectsRetiredGeneration() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let a = try XCTUnwrap(fixture.item("A"))
        let row = fixture.outline.row(forItem: a)
        let menu = try XCTUnwrap(fixture.coordinator.menu(forRow: row))
        let toggle = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(toggle.title, L10n.text("Include Subfolders"))
        XCTAssertEqual(toggle.state, .on)
        fixture.coordinator.toggleDescendants(toggle)
        XCTAssertEqual(fixture.state.selections, ["A"])
        XCTAssertEqual(fixture.state.scopes, [false])
        fixture.update()
        let cell = try XCTUnwrap(fixture.coordinator.outlineView(fixture.outline,
            viewFor: fixture.outline.outlineTableColumn, item: a) as? ArchiveFoldersView.FolderCell)
        XCTAssertEqual(cell.countField.stringValue, "1", "direct-folder count excludes the nested item")

        let staleMenu = try XCTUnwrap(fixture.coordinator.menu(forRow: row))
        let staleToggle = try XCTUnwrap(staleMenu.items.first)
        let staleItem = a
        fixture.state.index = fixture.state.index.reproject(items: [])
        fixture.update()
        fixture.coordinator.toggleDescendants(staleToggle)
        XCTAssertEqual(fixture.state.scopes, [false], "a menu from a replaced archive cannot change scope")
        XCTAssertNil(fixture.coordinator.outlineView(fixture.outline,
            viewFor: fixture.outline.outlineTableColumn, item: staleItem))
        XCTAssertEqual(fixture.coordinator.reloadCount, 2)
    }

    func testReusedCellUpdatesAccessibleNameCountAndLongNameWithoutDuplicateSpokenCount() {
        let cell = ArchiveFoldersView.FolderCell()
        cell.configure(id: "first", name: "First", count: 12)
        let longName = String(repeating: "Archive ", count: 30)
        cell.configure(id: "second", name: longName, count: 0)
        XCTAssertEqual(cell.accessibilityIdentifier(), "archive.folder.second")
        XCTAssertEqual(cell.toolTip, longName)
        XCTAssertEqual(cell.nameField.stringValue, longName)
        XCTAssertEqual(cell.nameField.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cell.nameField.accessibilityLabel(), longName + ", " + L10n.text("\(0) items"))
        XCTAssertFalse(cell.countField.isAccessibilityElement())
        XCTAssertFalse(cell.imageView?.isAccessibilityElement() ?? true)
    }

    func testNativeWheelAndDirectBoundsChangesStayVerticalAndDismantleDetachesCallbacks() throws {
        let fixture = Fixture(folderCount: 200)
        defer { fixture.close() }
        XCTAssertTrue(fixture.scroll.contentView is ArchiveFoldersView.VerticalClipView)
        fixture.scroll.contentView.setBoundsOrigin(NSPoint(x: 30, y: 100))
        XCTAssertEqual(fixture.scroll.contentView.bounds.minX, 0)
        XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 100)
        try VerticalScrollRegression.assertWheelInputStaysVertical(fixture.scroll)
        XCTAssertFalse(fixture.scroll.hasHorizontalScroller)
        let oldDelegate = fixture.outline.delegate
        XCTAssertNotNil(oldDelegate)
        fixture.coordinator.dismantle(fixture.scroll)
        XCTAssertNil(fixture.outline.delegate)
        XCTAssertNil(fixture.outline.dataSource)
        XCTAssertNil(fixture.outline.contextMenu)
        XCTAssertNil(fixture.coordinator.menu(forRow: 0))
        XCTAssertFalse(fixture.window.isVisible)
    }

    func testExpandAllAndCollapseAllUseBulkNativeCallsAndKeepSelectedPath() throws {
        let fixture = Fixture(nestedParents: 40)
        defer { fixture.close() }
        let expandable = fixture.state.index.expandableFolderIDs
        XCTAssertEqual(expandable.first, "", "pre-order starts at All Media")
        XCTAssertGreaterThan(expandable.count, 32, "fixture exercises the bulk path")
        fixture.state.expanded = Set(expandable)
        fixture.update()
        XCTAssertEqual(fixture.outline.numberOfRows, fixture.state.index.nodes.count, "every folder row is realized")
        for id in expandable { XCTAssertTrue(fixture.outline.isItemExpanded(try XCTUnwrap(fixture.item(id))), id) }
        XCTAssertEqual(fixture.state.expansionReports, 0, "applying the store's set never reports back")

        fixture.state.selected = "P7/Child"
        fixture.state.expanded = [""]
        fixture.update()
        XCTAssertTrue(fixture.outline.isItemExpanded(try XCTUnwrap(fixture.item("P7"))), "the current folder stays visible")
        XCTAssertFalse(fixture.outline.isItemExpanded(try XCTUnwrap(fixture.item("P8"))))
        XCTAssertFalse(fixture.outline.isItemExpanded(try XCTUnwrap(fixture.item("A"))))
        XCTAssertTrue(fixture.outline.item(atRow: fixture.outline.selectedRow) as AnyObject
                      === fixture.item("P7/Child"), "collapse never changes the selected folder")
        XCTAssertEqual(fixture.state.selections, [], "a bulk collapse does not change the review scope")
        XCTAssertEqual(fixture.coordinator.reloadCount, 1)
    }

    func testNativeRecursiveExpansionReportsOnceAfterAppKitFinishes() throws {
        let fixture = Fixture(nestedParents: 40)
        defer { fixture.close() }
        let root = try XCTUnwrap(fixture.item(""))
        fixture.outline.collapseItem(root)
        XCTAssertEqual(fixture.state.expansionReports, 1)
        fixture.outline.expandItem(root, expandChildren: true)
        XCTAssertEqual(fixture.state.expansionReports, 2, "Option-click reports one final set, not one per folder")
        XCTAssertEqual(fixture.state.expanded, Set(fixture.state.index.expandableFolderIDs))
        fixture.update()
        XCTAssertEqual(fixture.outline.numberOfRows, fixture.state.index.nodes.count, "the update keeps the native result")
        let a = try XCTUnwrap(fixture.item("A"))
        fixture.outline.collapseItem(a)
        XCTAssertEqual(fixture.state.expansionReports, 3, "an ordinary click still reports synchronously")
        XCTAssertFalse(fixture.state.expanded.contains("A"))
    }

    func testRecursiveCollapseChangesScopeOnceAndFirstMountRevealsSelection() throws {
        let fixture = Fixture(folderCount: 200)
        defer { fixture.close() }
        fixture.state.selected = "A/Nested"
        fixture.update()
        fixture.state.selections = []
        let root = try XCTUnwrap(fixture.item(""))
        fixture.outline.collapseItem(root, collapseChildren: true)
        XCTAssertEqual(fixture.state.selections, [""], "one scope change, to the visible All Media row")
        XCTAssertFalse(fixture.outline.allowsTypeSelect, "letters never jump between folders")

        // A fresh outline (pane switch or relaunch) shows a remembered late folder.
        let late = State(folderCount: 200)
        late.selected = "Folder199"
        let coordinator = ArchiveFoldersView.Coordinator(owner: late.view)
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { coordinator.dismantle(scroll); window.close() }
        let outline = try XCTUnwrap(scroll.documentView as? ArchiveFoldersView.OutlineView)
        coordinator.update(scroll)
        XCTAssertGreaterThan(outline.selectedRow, 100)
        XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)))
    }

    func testDeeplyNestedRowsKeepValidLayout() throws {
        var directories: [ArchiveFolderIndex.Directory] = [.init(id: "", parentID: nil, name: "Root")]
        var path = ""
        for level in 0..<24 {
            let parent = path
            path = path.isEmpty ? "L\(level)" : path + "/L\(level)"
            directories.append(.init(id: path, parentID: parent, name: "Level \(level) with a long name"))
        }
        let state = State(folderCount: nil)
        state.index = ArchiveFolderIndex(root: URL(fileURLWithPath: "/deep"), directories: directories, items: [])
        state.expanded = Set(state.index.expandableFolderIDs)
        state.selected = path
        let coordinator = ArchiveFoldersView.Coordinator(owner: state.view)
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { coordinator.dismantle(scroll); window.close() }
        let outline = try XCTUnwrap(scroll.documentView as? ArchiveFoldersView.OutlineView)
        coordinator.update(scroll)
        XCTAssertEqual(outline.numberOfRows, 25)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 24, makeIfNecessary: true) as? ArchiveFoldersView.FolderCell)
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(cell.hasAmbiguousLayout)
        XCTAssertGreaterThanOrEqual(cell.nameField.frame.width, 0)
    }

    func testRowClickReturnsKeysToTheSessionUnlessTheTreeWasAlreadyFocused() throws {
        // Hidden windows ignore synthetic row clicks, so this covers the
        // post-click focus contract that the mouseDown override applies.
        let fixture = Fixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.outline))
        fixture.outline.finishClick(wasFocused: false)
        XCTAssertFalse(fixture.window.firstResponder === fixture.outline, "a click hands review keys back")
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.outline))
        fixture.outline.finishClick(wasFocused: true)
        XCTAssertTrue(fixture.window.firstResponder === fixture.outline, "a Tab-focused tree keeps native arrows")
        XCTAssertFalse(fixture.window.isVisible)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(ArchiveFoldersView.OutlineView.isPointerEvent(click), "pointer clicks do not take keyboard focus")
        XCTAssertFalse(ArchiveFoldersView.OutlineView.isPointerEvent(key), "Tab can still focus the tree")
        XCTAssertFalse(ArchiveFoldersView.OutlineView.isPointerEvent(nil), "VoiceOver/programmatic focus is allowed")
    }

    func testExpandAndCollapseAllStayFastOnTenThousandFolders() throws {
        let fixture = Fixture(nestedParents: 5_000)
        defer { fixture.close() }
        let clock = ContinuousClock()
        let expand = clock.measure {
            fixture.state.expanded = Set(fixture.state.index.expandableFolderIDs)
            fixture.update()
        }
        XCTAssertEqual(fixture.outline.numberOfRows, fixture.state.index.nodes.count)
        let ratingUpdate = clock.measure { fixture.update() }
        let collapse = clock.measure {
            fixture.state.expanded = [""]
            fixture.update()
        }
        XCTAssertEqual(fixture.outline.numberOfRows, 1 + 3 + 5_000, "All Media plus top-level folders")
        print("10k-folder expand \(expand), unchanged update \(ratingUpdate), collapse \(collapse)")
        XCTAssertLessThan(expand, .seconds(2))
        XCTAssertLessThan(collapse, .seconds(2))
        XCTAssertLessThan(ratingUpdate, .milliseconds(50), "an unchanged update skips expansion work")
    }

    func testPaneSplitterDragsInBothDirectionsResetsAndIsAnAccessibleSplitter() throws {
        _ = NSApplication.shared
        var width: CGFloat = 220
        var commits = 0
        let view = ArchivePaneSplitter.SplitterView()
        view.width = { width }
        view.setWidth = { width = ArchiveFolderPaneWidth.clamped($0.rounded()) }
        view.commit = { commits += 1 }
        func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, x: 220))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 300))
        view.mouseUp(with: mouse(.leftMouseUp, x: 300))
        XCTAssertEqual(width, 300)
        XCTAssertEqual(commits, 1, "the width is remembered once, at the end of the drag")
        view.mouseDown(with: mouse(.leftMouseDown, x: 300))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 900))
        XCTAssertEqual(width, ArchiveFolderPaneWidth.range.upperBound)
        view.mouseUp(with: mouse(.leftMouseUp, x: 900))
        view.isRightToLeft = true
        view.mouseDown(with: mouse(.leftMouseDown, x: 500))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 600))
        view.mouseUp(with: mouse(.leftMouseUp, x: 600))
        XCTAssertEqual(width, 320, "in right-to-left layouts dragging right narrows the pane")
        view.mouseDown(with: mouse(.leftMouseDown, x: 600, clicks: 2))
        XCTAssertEqual(width, ArchiveFolderPaneWidth.standard)
        XCTAssertEqual(view.accessibilityRole(), .splitter)
        XCTAssertEqual(view.accessibilityLabel(), L10n.text("Folders width"))
        XCTAssertTrue(view.accessibilityPerformIncrement())
        XCTAssertEqual(width, 240)
        XCTAssertTrue(view.accessibilityPerformDecrement())
        XCTAssertTrue(view.accessibilityPerformDecrement())
        XCTAssertTrue(view.accessibilityPerformDecrement())
        XCTAssertEqual(width, ArchiveFolderPaneWidth.range.lowerBound)
    }

    func testExpansionSummaryIgnoresHiddenExpansionsAndTheSelectedPath() {
        let index = State(folderCount: nil, nestedParents: 2).index
        func summary(_ expanded: Set<String>, selected: String = "") -> ArchiveExpansionSummary {
            ArchiveExpansionSummary(index: index, expanded: expanded, selectedFolderID: selected)
        }
        XCTAssertEqual(summary([""]), .init(canExpandForTesting: true, canCollapse: false))
        XCTAssertEqual(summary(Set(index.expandableFolderIDs)), .init(canExpandForTesting: false, canCollapse: true))
        XCTAssertFalse(summary(["", "A"], selected: "A/Nested").canCollapse, "the selected path is not collapsible")
        XCTAssertTrue(summary(["", "A", "P0"], selected: "A/Nested").canCollapse)
        XCTAssertFalse(summary(["P0"]).canCollapse, "an expansion below collapsed All Media is not visible")
        let flat = ArchiveFolderIndex(root: URL(fileURLWithPath: "/flat"), directories: [], items: [])
        XCTAssertEqual(ArchiveExpansionSummary(index: flat, expanded: [""], selectedFolderID: ""),
                       .init(canExpandForTesting: false, canCollapse: false))
    }

    @MainActor
    private final class State {
        var index: ArchiveFolderIndex
        var selected = ""
        var expanded: Set<String> = [""]
        var includesDescendants = true
        var selections: [String] = []
        var scopes: [Bool] = []
        var expansionReports = 0
        init(folderCount: Int?, nestedParents: Int = 0) {
            let root = URL(fileURLWithPath: "/disposable-archive-outline")
            var directories: [ArchiveFolderIndex.Directory] = [
                .init(id: "", parentID: nil, name: "Fixture", identity: nil),
                .init(id: "A", parentID: "", name: "A", identity: nil),
                .init(id: "A/Nested", parentID: "A", name: "Nested", identity: nil),
                .init(id: "Empty", parentID: "", name: "Empty", identity: nil),
                .init(id: "Z", parentID: "", name: "Z", identity: nil)
            ]
            if let folderCount {
                directories += (0..<folderCount).map {
                    .init(id: "Folder\($0)", parentID: "", name: "Folder\($0)", identity: nil)
                }
            }
            for parent in 0..<nestedParents {
                directories += [.init(id: "P\(parent)", parentID: "", name: "P\(parent)", identity: nil),
                                .init(id: "P\(parent)/Child", parentID: "P\(parent)", name: "Child", identity: nil)]
            }
            let items = ["A/one.jpg", "A/Nested/two.jpg"].map { path in
                PhotoItem(primaryFile: PhotoFile(id: path, url: root.appendingPathComponent(path),
                    captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1))
            }
            index = ArchiveFolderIndex(root: root, directories: directories, items: items)
        }
        var view: ArchiveFoldersView {
            ArchiveFoldersView(index: index, selectedFolderID: selected, expandedFolderIDs: expanded,
                includesDescendants: includesDescendants,
                onSelect: { self.selected = $0; self.selections.append($0) },
                onExpansionChange: { self.expanded = $0; self.expansionReports += 1 },
                onIncludesDescendantsChange: { self.includesDescendants = $0; self.scopes.append($0) })
        }
    }

    @MainActor
    private final class Fixture {
        let state: State
        let coordinator: ArchiveFoldersView.Coordinator
        let scroll: NSScrollView
        let outline: ArchiveFoldersView.OutlineView
        let window: NSWindow
        init(folderCount: Int? = nil, nestedParents: Int = 0) {
            _ = NSApplication.shared
            state = State(folderCount: folderCount, nestedParents: nestedParents)
            coordinator = ArchiveFoldersView.Coordinator(owner: state.view)
            scroll = coordinator.makeScrollView()
            scroll.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
            outline = scroll.documentView as! ArchiveFoldersView.OutlineView
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.contentView?.layoutSubtreeIfNeeded()
            outline.layoutSubtreeIfNeeded()
        }
        func update() { coordinator.owner = state.view; coordinator.update(scroll) }
        func item(_ id: String) -> ArchiveFoldersView.FolderItem? {
            for row in 0..<outline.numberOfRows {
                if let item = outline.item(atRow: row) as? ArchiveFoldersView.FolderItem,
                   item.node.id == id { return item }
            }
            return nil
        }
        func close() { coordinator.dismantle(scroll); window.close() }
    }
}
