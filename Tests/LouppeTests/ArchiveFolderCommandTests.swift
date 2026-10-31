import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ArchiveFolderCommandTests: XCTestCase {
    func testStopsUseNaturalPreorderAndSkipRootEmptyAndContainers() {
        let store = makeStore()
        let expected = ["2/child", "10", "20", "Caf%C3%A9", "Cafe%CC%81"].sorted { a, b in
            let order = store.archiveFolderIndex!.directories.map(\.id)
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
        var stops: [String] = []
        var current = ""
        while let next = store.archiveNextFolderID(after: current) {
            stops.append(next); current = next
        }
        XCTAssertEqual(stops, expected)
        XCTAssertEqual(stops.prefix(3), ["2/child", "10", "20"])
        XCTAssertEqual(store.archiveNextFolderID(after: "2"), "2/child")
        XCTAssertNil(store.archivePreviousFolderID(before: "2/child"))
        XCTAssertNil(store.archivePreviousFolderID(before: ""))
        XCTAssertNil(store.archiveNextFolderID(after: "missing"))
        XCTAssertNil(store.archivePreviousFolderID(before: "missing"))
        for position in stops.indices.dropFirst() {
            XCTAssertEqual(store.archivePreviousFolderID(before: stops[position]), stops[position - 1])
        }
    }

    func testSelectorsAndParentUseExistingScopeAuthority() {
        let store = makeStore()
        XCTAssertTrue(store.selectNextArchiveFolder())
        XCTAssertEqual(store.archiveSelectedFolderID, "2/child")
        XCTAssertEqual(store.currentItem?.primaryFile.id, "2/child/a.JPG")
        XCTAssertFalse(store.selectPreviousArchiveFolder())
        XCTAssertTrue(store.selectEnclosingArchiveFolder())
        XCTAssertEqual(store.archiveSelectedFolderID, "2")
        XCTAssertTrue(store.selectEnclosingArchiveFolder())
        XCTAssertEqual(store.archiveSelectedFolderID, "")
        XCTAssertFalse(store.selectEnclosingArchiveFolder())
        store.selectArchiveFolder("10")
        XCTAssertTrue(store.selectPreviousArchiveFolder())
        XCTAssertEqual(store.archiveSelectedFolderID, "2/child")
    }

    func testRevealUsesPrimaryPhysicalParentAndKeepsCurrentItem() throws {
        let store = makeStore()
        let target = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "20/c.JPG" })
        store.setIndex(target)
        XCTAssertTrue(store.canRevealCurrentItemArchiveFolder)
        XCTAssertTrue(store.revealCurrentItemArchiveFolder())
        XCTAssertEqual(store.archiveSelectedFolderID, "20")
        XCTAssertEqual(store.currentItem?.primaryFile.id, "20/c.JPG")
        XCTAssertFalse(store.canRevealCurrentItemArchiveFolder)
        XCTAssertFalse(store.revealCurrentItemArchiveFolder())
        store.selectArchiveFolder("")
        let rootItem = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "root.JPG" })
        store.setIndex(rootItem)
        XCTAssertEqual(store.currentItemArchiveFolderID, "")
    }

    func testCommandsRejectFileWorkPresentationsWrongPhaseAndFlatArchives() {
        let store = makeStore()
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        XCTAssertFalse(store.canSelectNextArchiveFolder)
        XCTAssertFalse(store.selectNextArchiveFolder())
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        store.isSortPresented = true
        XCTAssertFalse(store.selectNextArchiveFolder())
        XCTAssertFalse(store.canUseArchiveFolderCommands(allowingActionPalette: true))
        store.isSortPresented = false
        store.isActionPalettePresented = true
        XCTAssertFalse(store.selectNextArchiveFolder())
        XCTAssertTrue(store.canUseArchiveFolderCommands(allowingActionPalette: true))
        store.isActionPalettePresented = false
        store.phase = .welcome
        XCTAssertFalse(store.selectNextArchiveFolder())
        store.phase = .ready
        store.archiveFolderIndex = ArchiveFolderIndex(root: root, directories: [], items: [])
        XCTAssertFalse(store.canUseArchiveFolderCommands())
        XCTAssertNil(store.archiveNextFolderID(after: ""))
        XCTAssertNil(store.archivePreviousFolderID(before: ""))
    }

    func testReviewFolderKeysKeepOutlineNavigationAndShareAllOwnershipGates() {
        let store = makeStore()
        let view = SessionView(store: store)
        let preferences = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        let outline = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false,
            focusedResponderOwnsNavigation: true)
        XCTAssertTrue(SessionKeyRoutingContext.responderOwnsNavigation(NSOutlineView()))
        XCTAssertTrue(view.handleKey(event("]", 30), context: outline, shortcutPreferences: preferences))
        XCTAssertEqual(store.archiveSelectedFolderID, "2/child")
        XCTAssertFalse(view.handleKey(event("[", 33), context: outline, shortcutPreferences: preferences))
        for context in [SessionKeyRoutingContext.blocked,
                        .init(sessionOwnsEvent: true, hasModalPresentation: true),
                        .init(sessionOwnsEvent: true, hasModalPresentation: false, focusedResponderOwnsText: true)] {
            XCTAssertFalse(view.handleKey(event("]", 30), context: context, shortcutPreferences: preferences))
        }
        for flags: NSEvent.ModifierFlags in [.shift, .option, .control, .function, [.control, .option]] {
            XCTAssertFalse(view.handleKey(event("]", 30, flags), context: outline, shortcutPreferences: preferences))
        }
        let voiceOver = SessionKeyRoutingContext(sessionOwnsEvent: true, hasModalPresentation: false, isVoiceOverEnabled: true)
        XCTAssertFalse(view.handleKey(event("]", 30, .capsLock), context: voiceOver, shortcutPreferences: preferences))
        XCTAssertTrue(view.handleKey(event("]", 30, .capsLock), context: outline, shortcutPreferences: preferences))
        XCTAssertTrue(view.handleKey(event("", 126, [.command, .function, .numericPad]), context: outline))
        XCTAssertEqual(store.archiveSelectedFolderID, "")
    }

    func testSidebarSwitchingKeysAreOnePressAndSafeDuringFileOperations() {
        let store = makeStore()
        let view = SessionView(store: store)
        let prefs = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        store.viewMode = .gallery
        store.showBrowser = true
        store.archiveLeadingPane = .browser
        XCTAssertTrue(view.handleKey(event("T", 17, .shift), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertEqual(store.archiveLeadingPane, .folders)
        XCTAssertTrue(store.isLeadingPaneVisible)
        XCTAssertTrue(view.handleKey(event("q", 12), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertEqual(store.archiveLeadingPane, .browser)
        XCTAssertTrue(store.isLeadingPaneVisible)
        XCTAssertTrue(view.handleKey(event("q", 12), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertFalse(store.isLeadingPaneVisible)
        store.viewMode = .grid
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        XCTAssertTrue(view.handleKey(event("t", 17), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertEqual(store.archiveLeadingPane, .folders)
        XCTAssertEqual(store.viewMode, .grid)
        XCTAssertTrue(store.isLeadingPaneVisible)
        XCTAssertFalse(view.handleKey(event("]", 30), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertFalse(view.handleKey(event("", 126, .command), context: .focusedSession))
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        store.archiveFolderIndex = nil
        XCTAssertFalse(view.handleKey(event("t", 17), context: .focusedSession, shortcutPreferences: prefs))
    }

    func testNextUnfinishedFolderSkipsFoldersWhoseDirectItemsAreReviewed() throws {
        let store = makeStore()
        XCTAssertEqual(store.archiveNextUnfinishedFolderID(after: ""), "2/child")
        let child = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "2/child/a.JPG" })
        let ten = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "10/b.JPG" })
        store.rate(.yes, at: child)
        store.rate(.no, at: ten)
        XCTAssertEqual(store.archiveNextUnfinishedFolderID(after: ""), "20", "finished folders are skipped")
        XCTAssertTrue(store.selectNextUnfinishedArchiveFolder())
        XCTAssertEqual(store.archiveSelectedFolderID, "20")
        store.undo()
        XCTAssertEqual(store.archiveNextUnfinishedFolderID(after: ""), "10", "Undo of the last rating reopens its folder")
        let actions = ActionPaletteView(store: store).actions
        XCTAssertNotNil(actions.first { $0.id == "next-unfinished-folder" })
    }

    func testEnteringAFolderStartsAtItsFirstUndecidedItemUnlessTheCurrentItemBelongsToIt() throws {
        let store = makeStore(paths: ["A/1.JPG", "A/2.JPG", "A/3.JPG", "B/4.JPG", "2/child/a.JPG"])
        store.rate(.yes, at: 0)
        let later = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "B/4.JPG" })
        store.setIndex(later)
        store.selectArchiveFolder("A")
        XCTAssertEqual(store.currentItem?.primaryFile.id, "A/2.JPG",
                       "a fresh folder starts at its first undecided item, not the filter-snapped last one")
        store.selectArchiveFolder("")
        let child = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "2/child/a.JPG" })
        store.setIndex(child)
        store.selectArchiveFolder("2")
        XCTAssertEqual(store.currentItem?.primaryFile.id, "2/child/a.JPG", "an item inside the new scope stays current")
    }

    func testRepeatedCommandEnablementDoesNotRescanTwentyThousandFolders() {
        let store = makeStore()
        let dirs = (0..<20_000).map { ArchiveFolderIndex.Directory(id: "f\($0)", parentID: "", name: "f\($0)") }
        store.archiveFolderIndex = ArchiveFolderIndex(root: root, directories: dirs, items: store.items)
        _ = store.canSelectNextUnfinishedArchiveFolder
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<100 {
                _ = store.canSelectNextArchiveFolder
                _ = store.canSelectPreviousArchiveFolder
                _ = store.canSelectNextUnfinishedArchiveFolder
            }
        }
        XCTAssertLessThan(elapsed, .milliseconds(50), "cached targets serve repeated menu updates")
        let revision = store.archiveFolderProgressRevision
        let first = try? XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "2/child/a.JPG" })
        store.rate(.yes, at: first!)
        XCTAssertNotEqual(store.archiveFolderProgressRevision, revision)
        XCTAssertEqual(store.archiveFolderTargets?.nextUnfinished, "10", "a decision refreshes the unfinished target")
    }

    func testQHidesTheBrowserOfAFlatFolderEvenAfterFoldersWasChosen() {
        let store = makeStore()
        let view = SessionView(store: store)
        let prefs = ReviewShortcutPreferences(interpretation: .keyboardLayout)
        store.archiveFolderIndex = ArchiveFolderIndex(root: root, directories: [], items: [])
        store.viewMode = .gallery
        store.showBrowser = true
        store.archiveLeadingPane = .folders
        XCTAssertTrue(store.isArchiveBrowserVisible, "a flat folder shows the Browser")
        XCTAssertTrue(view.handleKey(event("q", 12), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertFalse(store.isLeadingPaneVisible, "the first Q press hides it")
        XCTAssertTrue(view.handleKey(event("q", 12), context: .focusedSession, shortcutPreferences: prefs))
        XCTAssertTrue(store.isArchiveBrowserVisible)
    }

    func testPaletteListsFolderPathsAndRunsAfterDismissal() throws {
        let store = makeStore()
        store.presentActionPalette()
        let actions = ActionPaletteView(store: store).actions
        for id in ["folders", "expand-all-folders", "collapse-all-folders", "next-folder", "previous-folder",
                   "enclosing-folder", "current-item-folder", "all-media", "archive-folder-2/child"] {
            XCTAssertNotNil(actions.first { $0.id == id }, id)
        }
        let next = try XCTUnwrap(actions.first { $0.id == "next-folder" })
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(try XCTUnwrap(actions.first { $0.id == "previous-folder" }).isEnabled)
        XCTAssertTrue(ActionPaletteSearch.results(for: "directory", in: actions).contains { $0.id == "next-folder" })
        store.dismissActionPalette(then: next.perform)
        XCTAssertEqual(store.archiveSelectedFolderID, "")
        store.finishActionPaletteDismissal()
        XCTAssertEqual(store.archiveSelectedFolderID, "2/child")
        let path = try XCTUnwrap(ActionPaletteView(store: store).actions.first { $0.id == "archive-folder-Caf%C3%A9" })
        XCTAssertTrue(path.title.contains("Café"))
    }

    func testPaletteBoundsPathEntriesAtTwoThousandFolders() {
        let store = makeStore()
        let dirs = (0..<2_001).map { ArchiveFolderIndex.Directory(id: "folder\($0)", parentID: "", name: "folder\($0)") }
        store.archiveFolderIndex = ArchiveFolderIndex(root: root, directories: dirs, items: [])
        XCTAssertFalse(ActionPaletteView(store: store).actions.contains { $0.id.hasPrefix("archive-folder-") })
        store.archiveFolderIndex = ArchiveFolderIndex(root: root, directories: Array(dirs.dropLast()), items: [])
        XCTAssertEqual(ActionPaletteView(store: store).actions.filter { $0.id.hasPrefix("archive-folder-") }.count, 2_000)
    }

    private let root = URL(fileURLWithPath: "/private/tmp/louppe-synthetic-archive", isDirectory: true)
    private func makeStore(paths: [String] = ["root.JPG", "2/child/a.JPG", "10/b.JPG", "20/c.JPG",
                                              "Caf%C3%A9/d.JPG", "Cafe%CC%81/e.JPG"]) -> SessionStore {
        let store = SessionStore()
        store.items = paths.map {
            PhotoItem(primaryFile: PhotoFile(id: $0, url: URL(string: root.absoluteString + $0)!,
                captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1))
        }
        store.sort = PhotoSort(key: .name, ascending: true)
        store.archiveFolderIndex = ArchiveFolderIndex(root: root, directories: [
            .init(id: "Empty", parentID: "", name: "Empty")], items: store.items)
        store.phase = .ready
        return store
    }
    private func event(_ char: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!
    }
}
