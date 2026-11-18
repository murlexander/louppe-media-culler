import AppKit
import XCTest
@testable import Louppe

@MainActor
final class ArchiveNavigationSessionTests: XCTestCase {
    func testFolderScopesReuseOneSessionAndKeepFileActionsInsideTheFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let generation = try XCTUnwrap(store.archiveFolderIndex?.generation)
        store.viewMode = .grid
        XCTAssertFalse(store.isLeadingPaneVisible)
        store.toggleLeadingPane()
        XCTAssertTrue(store.isLeadingPaneVisible, "the first Grid toggle shows the previously absent folder pane")
        store.toggleLeadingPane()
        XCTAssertFalse(store.isLeadingPaneVisible)
        store.viewMode = .gallery
        store.showBrowser = true
        store.selectAllVisible()
        store.selectArchiveFolder("A")
        XCTAssertEqual(store.items.count, 4)
        XCTAssertEqual(store.archiveScopeCount, 2)
        XCTAssertTrue(store.selectedIndices.allSatisfy { store.visibleIndices.contains($0) })
        XCTAssertEqual(store.sourceFolder, fixture.media)
        XCTAssertEqual(store.archiveFolderIndex?.generation, generation, "folder navigation does not rescan")
        XCTAssertEqual(Set(store.visibleIndices.map { store.items[$0].primaryFile.id }), ["A/one.txt", "A/Nested/two.txt"])
        XCTAssertEqual(store.cleanUpScopeCount(for: .all), 2)
        XCTAssertEqual(store.organizationScopeCount(for: .all), 2)
        XCTAssertEqual(store.sourceOrganizationPlanningSnapshot(scope: .all)?.selectedItems.count, 2)
        XCTAssertEqual(store.sourceFileRenamingPlanningSnapshot(scope: .all)?.selectedItems.count, 2)
        let selection = ExportSelectionConfiguration(scope: .all,
            predicate: .init(decisions: [.yes, .no, .undecided]))
        XCTAssertEqual(selection.snapshot(items: store.items, filtered: store.visibleIndices,
            selected: store.selectedIndices, all: store.archiveActionIndices).itemCount, 2)
        store.setArchiveIncludesDescendants(false)
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].primaryFile.id }, ["A/one.txt"])
        store.selectArchiveFolder("Empty")
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertNil(store.currentItem)
        XCTAssertTrue(store.effectiveSelection.isEmpty)
        XCTAssertEqual(store.cleanUpScopeCount(for: .all), 0)
        store.selectArchiveFolder("")
        XCTAssertTrue(store.archiveIncludesDescendants)
        XCTAssertEqual(store.visibleIndices.count, 4)
        await finish(store)
        for folder in ["A", "A/Nested", "B", "Empty"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.media.appendingPathComponent(folder)
                .appendingPathComponent(SessionConstants.sidecarName).path))
        }
    }

    func testClearDecisionsUsesCurrentFolderAndUndoPreservesOtherFolders() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let a = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/one.txt" })
        let b = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "B/three.txt" })
        store.rate(.yes, at: a)
        store.rate(.no, at: b)
        store.selectArchiveFolder("A")
        store.clearAllRatings()
        XCTAssertEqual(store.items[a].rating, .undecided)
        XCTAssertEqual(store.items[b].rating, .no)
        XCTAssertEqual(store.ratedCount, 1)
        store.undo()
        XCTAssertEqual(store.items[a].rating, .yes)
        XCTAssertEqual(store.items[b].rating, .no)
        XCTAssertEqual(store.ratedCount, 2)
        await finish(store)
    }

    func testDirectFolderProgressFollowsRatingsUndoAndClear() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let index = try XCTUnwrap(store.archiveFolderIndex)
        let progress = try XCTUnwrap(store.archiveFolderProgress)
        func direct(_ id: String) -> Int { progress.directReviewedCount(for: id, index: index) }
        let one = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/one.txt" })
        let two = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/Nested/two.txt" })
        let revision = store.archiveFolderProgressRevision
        store.rate(.yes, at: one)
        XCTAssertGreaterThan(store.archiveFolderProgressRevision, revision)
        XCTAssertEqual(direct("A"), 1)
        store.rate(.no, at: two)
        XCTAssertEqual(direct("A/Nested"), 1)
        XCTAssertEqual(direct("A"), 1, "subfolder items are not direct items")
        store.undo()
        XCTAssertEqual(direct("A/Nested"), 0)
        store.rate(.no, at: two)
        store.rate(.no, at: two)
        XCTAssertEqual(direct("A/Nested"), 0, "a second No toggles back to Unmarked")
        store.rate(.no, at: two)
        store.selectArchiveFolder("A")
        store.clearAllRatings()
        XCTAssertEqual(direct("A"), 0, "Clear All Decisions reopens the folder")
        XCTAssertEqual(direct("A/Nested"), 0)
        XCTAssertTrue(store.archiveFolderProgress === progress, "folder navigation keeps the prepared progress")
        await finish(store)
    }

    func testClearStarsAndLabelsUsesCurrentFolderIncludingHiddenItemsWithOneUndo() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        func index(_ id: String) throws -> Int { try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == id }) }
        let a = try index("A/one.txt"), nested = try index("A/Nested/two.txt"), b = try index("B/three.txt")
        store.setStarRating(.three, at: a)
        store.setColorLabel(.green, at: nested)
        store.rate(.yes, at: nested)
        store.setColorLabel(.blue, at: b)
        let starsAt = store.items[a].primaryFile.starsChangedAt
        let colorAt = store.items[nested].primaryFile.colorChangedAt
        let ratedAt = store.items[nested].primaryFile.ratedAt
        store.selectArchiveFolder("A")
        XCTAssertTrue(store.canClearArchiveStarsAndLabels)
        let action = try XCTUnwrap(ActionPaletteView(store: store).actions.first { $0.id == "clear-stars-labels" })
        XCTAssertTrue(action.isEnabled)
        store.filter.searchText = "one"
        store.flushPendingFilter()
        XCTAssertEqual(store.visibleIndices, [a], "the nested item is hidden by Filter but in the folder scope")
        let depth = store.undoStepCountForTesting
        store.requestClearStarsAndLabels()
        XCTAssertEqual(store.undoStepCountForTesting, depth + 1)
        XCTAssertNil(store.items[a].primaryFile.starRating)
        XCTAssertNil(store.items[nested].primaryFile.colorLabel)
        XCTAssertEqual(store.items[nested].rating, .yes)
        XCTAssertEqual(store.items[nested].primaryFile.ratedAt, ratedAt)
        XCTAssertEqual(store.items[b].primaryFile.colorLabel, .blue, "another folder keeps its label")
        XCTAssertFalse(store.canClearArchiveStarsAndLabels)
        XCTAssertFalse(try XCTUnwrap(ActionPaletteView(store: store).actions.first { $0.id == "clear-stars-labels" }).isEnabled)
        store.undo()
        XCTAssertEqual(store.items[a].primaryFile.starRating, .three)
        XCTAssertEqual(store.items[a].primaryFile.starsChangedAt, starsAt)
        XCTAssertEqual(store.items[nested].primaryFile.colorLabel, .green)
        XCTAssertEqual(store.items[nested].primaryFile.colorChangedAt, colorAt)
        XCTAssertTrue(store.canClearArchiveStarsAndLabels)
        store.filter.searchText = ""
        store.flushPendingFilter()
        store.selectArchiveFolder("Empty")
        XCTAssertFalse(store.canClearArchiveStarsAndLabels)
        store.selectArchiveFolder("B")
        XCTAssertTrue(store.canClearArchiveStarsAndLabels)
        store.setColorLabel(nil, at: try XCTUnwrap(store.visibleIndices.first))
        XCTAssertFalse(store.canClearArchiveStarsAndLabels, "scoped enablement follows ordinary edits")
        await finish(store)
    }

    func testToolbarTotalsShowYesAlwaysAndNoOnlyWhenNonzero() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let view = SessionView(store: store)
        let position = L10n.text("Item \(L10n.number(store.currentVisiblePosition.map { $0 + 1 } ?? 0)) of \(L10n.number(4))")
        XCTAssertEqual(view.subtitle, position + L10n.text("  ·  \(L10n.number(0)) Yes"))
        let three = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "B/three.txt" })
        store.rate(.no, at: three)
        XCTAssertTrue(view.subtitle.hasSuffix(L10n.text("  ·  \(L10n.number(0)) Yes") + L10n.text("  ·  \(L10n.number(1)) No")))
        XCTAssertFalse(view.subtitle.contains("reviewed"))
        store.selectArchiveFolder("A")
        XCTAssertFalse(view.subtitle.contains(L10n.text("  ·  \(L10n.number(1)) No")), "No is scoped and hidden at zero")
        let one = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/one.txt" })
        store.rate(.yes, at: one)
        store.filter.searchText = "one"
        store.flushPendingFilter()
        XCTAssertEqual(view.subtitle, L10n.text("Item \(L10n.number(1)) of \(L10n.number(1))")
            + L10n.text(" (of \(L10n.number(2)) total)") + L10n.text("  ·  \(L10n.number(1)) Yes"))
        await finish(store)
    }

    func testFlatFoldersKeepTheOriginalBrowserAndGridWithoutFolderControls() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let flat = fixture.root.appendingPathComponent("flat")
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: false)
        try Data("flat original".utf8).write(to: flat.appendingPathComponent("photo.txt"))
        let store = fixture.store()
        store.archiveLeadingPane = .folders // A remembered preference from an archive.
        store.openFolder(flat)
        try await ready(store)
        XCTAssertNotNil(store.archiveFolderIndex, "keep the prepared index for memory and scope identity")
        XCTAssertFalse(store.hasArchiveFolders)
        store.showBrowser = true
        store.viewMode = .gallery
        XCTAssertTrue(store.isLeadingPaneVisible)
        store.viewMode = .grid
        XCTAssertFalse(store.isLeadingPaneVisible)
        XCTAssertEqual(store.archiveAllScopeLabel, L10n.text("All Media"))
        await finish(store)
    }

    func testScopeTotalsAndClearEnablementFollowRatingsUndoAndFiltering() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let a = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/one.txt" })
        let nested = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/Nested/two.txt" })
        let b = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "B/three.txt" })
        store.rate(.no, at: b)
        store.selectArchiveFolder("A")
        XCTAssertEqual(store.archiveRatedCount, 0, "another folder cannot enable Clear here")
        XCTAssertFalse(try XCTUnwrap(ActionPaletteView(store: store).actions.first { $0.id == "clear-decisions" }).isEnabled)
        XCTAssertEqual(store.archiveYesCount + store.archiveNoCount, 0)
        store.rate(.yes, at: a)
        XCTAssertEqual(store.archiveYesCount, 1)
        XCTAssertTrue(try XCTUnwrap(ActionPaletteView(store: store).actions.first { $0.id == "clear-decisions" }).isEnabled)
        store.rate(.no, at: nested)
        XCTAssertEqual(store.archiveNoCount, 1)
        store.undo()
        XCTAssertEqual(store.archiveNoCount, 0)
        XCTAssertEqual(store.archiveYesCount, 1)
        store.filter.searchText = "missing"
        store.flushPendingFilter()
        XCTAssertEqual(store.archiveYesCount, 1, "filtering does not change the folder totals")
        XCTAssertEqual(store.archiveScopeCount, 2)
        store.setArchiveIncludesDescendants(false)
        XCTAssertEqual(store.archiveScopeCount, 1)
        XCTAssertEqual(store.archiveYesCount, 1)
        store.clearAllRatings()
        XCTAssertEqual(store.archiveRatedCount, 0)
        XCTAssertEqual(store.ratedCount, 1, "unrelated folder decisions remain")
        store.selectArchiveFolder("")
        XCTAssertEqual(store.archiveNoCount, 1)
        XCTAssertEqual(store.archiveYesCount, 0)
        XCTAssertEqual(store.archiveScopeCount, 4)
        await finish(store)
    }

    func testScopeCountsDeduplicatePairComponentsAndKeepMixedPendingThroughUndo() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let a = try XCTUnwrap(store.items.first { $0.primaryFile.id == "A/one.txt" }?.primaryFile)
        let b = try XCTUnwrap(store.items.first { $0.primaryFile.id == "B/three.txt" }?.primaryFile)
        a.setRating(.yes, ratedAt: Date())
        b.setRating(.no, ratedAt: Date())
        let others = store.items.filter { $0.primaryFile.id != a.id && $0.primaryFile.id != b.id }
        store.items = [PhotoItem(primaryFile: a, pairedFile: b)] + others
        store.rebuildDerivedDataForTesting(sourceFolder: fixture.media)
        store.selectArchiveFolder("B")
        XCTAssertEqual(store.archiveScopeCount, 1)
        XCTAssertEqual(store.archiveMixedCount, 1)
        XCTAssertEqual(store.archiveRatedCount, 1)
        XCTAssertEqual(store.archiveYesCount + store.archiveNoCount, 0)
        let pair = try XCTUnwrap(store.visibleIndices.first)
        store.rate(.yes, at: pair)
        XCTAssertEqual(store.archiveYesCount, 1, "two changed physical IDs update one review item; Mixed is marked, not cleared")
        XCTAssertEqual(store.archiveMixedCount, 0)
        store.undo()
        XCTAssertEqual(store.archiveMixedCount, 1)
        XCTAssertEqual(store.archiveYesCount, 0)
        store.clearAllRatings()
        XCTAssertEqual(store.archiveRatedCount, 0)
        XCTAssertEqual(a.rating, .undecided)
        XCTAssertEqual(b.rating, .undecided)
        await finish(store)
    }

    func testCorruptNavigationOffersRecoveryWithoutTouchingDecisions() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let state = fixture.root.appendingPathComponent("navigation.json")
        let evidence = Data("damaged UI positions".utf8)
        try evidence.write(to: state)
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        XCTAssertNotNil(store.archiveNavigationWarning)
        XCTAssertTrue(store.archiveNavigationCanReset)
        let a = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/one.txt" })
        store.rate(.yes, at: a)
        await store.resetArchiveNavigationStorage()
        XCTAssertNil(store.archiveNavigationWarning)
        XCTAssertFalse(store.archiveNavigationCanReset)
        XCTAssertEqual(store.items[a].rating, .yes)
        store.selectArchiveFolder("A")
        await finish(store)
        let reopened = fixture.store()
        reopened.openFolder(fixture.media)
        try await ready(reopened)
        XCTAssertEqual(reopened.archiveSelectedFolderID, "A")
        XCTAssertEqual(reopened.items.first { $0.primaryFile.id == "A/one.txt" }?.rating, .yes)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.root,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("ArchiveNavigation.recovered-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first).appendingPathComponent("navigation.json")), evidence)
        await finish(reopened)
    }

    func testFolderPositionsRestoreIndependentlyAndRejectOldViewportCallbacks() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        store.selectArchiveFolder("A")
        let a = try XCTUnwrap(store.items.firstIndex { $0.primaryFile.id == "A/Nested/two.txt" })
        store.setIndex(a)
        let previousGeneration = store.archiveViewportGeneration
        store.recordPinnedViewport(physicalFileID: "A/one.txt", topOffset: -12.5, surface: .grid,
            archiveGeneration: previousGeneration)
        store.selectArchiveFolder("B")
        store.recordPinnedViewport(physicalFileID: "B/three.txt", topOffset: -99, surface: .grid,
            archiveGeneration: previousGeneration)
        XCTAssertNil(store.archiveNavigationMemory?.position(for: "B")?.grid)
        store.selectArchiveFolder("A")
        XCTAssertEqual(store.currentItem?.primaryFile.id, "A/Nested/two.txt")
        XCTAssertEqual(store.pendingOpeningViewportReceipt(for: .grid)?.physicalFileID, "A/one.txt")
        XCTAssertEqual(store.pendingOpeningViewportReceipt(for: .grid)?.topOffset, -12.5)
        await finish(store)
        let reopened = fixture.store()
        reopened.openFolder(fixture.media)
        try await ready(reopened)
        XCTAssertEqual(reopened.archiveSelectedFolderID, "A")
        XCTAssertEqual(reopened.currentItem?.primaryFile.id, "A/Nested/two.txt")
        XCTAssertEqual(reopened.pendingOpeningViewportReceipt(for: .grid)?.topOffset, -12.5)
        await finish(reopened)
    }

    func testReplacedDirectoryCannotRestoreItsPositionAndFilterDoesNotBroadenScope() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        store.selectArchiveFolder("A/Nested")
        await finish(store)
        let old = fixture.root.appendingPathComponent("previous-nested")
        try FileManager.default.moveItem(at: fixture.media.appendingPathComponent("A/Nested"), to: old)
        try FileManager.default.createDirectory(at: fixture.media.appendingPathComponent("A/Nested"), withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: fixture.media.appendingPathComponent("A/Nested/replacement.txt"))
        let reopened = fixture.store()
        reopened.openFolder(fixture.media)
        try await ready(reopened)
        XCTAssertEqual(reopened.archiveSelectedFolderID, "A", "fall back to the verified surviving ancestor")
        reopened.filter.searchText = "three"
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(reopened.visibleIndices.isEmpty)
        XCTAssertNil(reopened.currentItem)
        XCTAssertEqual(reopened.cleanUpScopeCount(for: .all), 2)
        reopened.resetFilter()
        reopened.flushPendingFilter()
        XCTAssertEqual(reopened.visibleIndices.count, 2)
        await finish(reopened)
    }

    func testRescanRetainsScopedExplicitSelectionInsteadOfApplyingRememberedCurrent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        store.selectArchiveFolder("A")
        store.selectAllVisible()
        let ids = Set(store.selectedIndices.map { store.items[$0].id })
        let current = store.currentItem?.id
        let generation = store.archiveFolderIndex?.generation
        store.rescan()
        try await until { store.archiveFolderIndex?.generation != generation && !store.isFileOperationRunning }
        try await ready(store)
        XCTAssertEqual(store.archiveSelectedFolderID, "A")
        XCTAssertEqual(Set(store.selectedIndices.map { store.items[$0].id }), ids)
        XCTAssertEqual(store.currentItem?.id, current)
        await finish(store)
    }

    func testOrganizeRefreshesNewDirectoryIdentityAndRestoresItAfterRelaunch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        let previousGeneration = store.archiveFolderIndex?.generation
        let snapshot = try XCTUnwrap(store.sourceOrganizationPlanningSnapshot(scope: .all))
        let plan = try SourceOrganizationPlanner.makePlan(sourceFolder: snapshot.sourceFolder,
            selectedItems: snapshot.selectedItems, familyContextItems: snapshot.familyContextItems,
            configuration: SourceOrganizationConfiguration(
                levels: [.init(kind: .existingFolder, isEnabled: true)],
                dateGranularity: .day, existingFolderDepth: .topLevel, containerName: "Organized"),
            knownOriginFolderPathBytesByFileID: snapshot.knownOriginFolderPathBytesByFileID,
            pairedFiles: snapshot.pairedFiles)
        XCTAssertTrue(plan.canExecute)
        store.startSourceOrganization(plan)
        try await until { store.archiveFolderIndex?.generation != previousGeneration && !store.isFileOperationRunning }
        try await ready(store)
        store.isOrganizePresented = false
        XCTAssertNotNil(store.archiveFolderIndex?.node(for: "Organized/A")?.identity)
        store.selectArchiveFolder("Organized/A")
        XCTAssertEqual(store.visibleIndices.count, 2)
        await finish(store)
        let reopened = fixture.store()
        reopened.openFolder(fixture.media)
        try await ready(reopened)
        XCTAssertEqual(reopened.archiveSelectedFolderID, "Organized/A")
        XCTAssertEqual(reopened.visibleIndices.count, 2)
        XCTAssertEqual(try String(contentsOf: fixture.media.appendingPathComponent("Organized/A/one.txt"), encoding: .utf8), "A/one.txt")
        await finish(reopened)
    }

    func testRenameAndUndoRefreshFolderProjectionWithoutLosingScope() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.media)
        try await ready(store)
        store.selectArchiveFolder("A")
        store.setArchiveIncludesDescendants(false)
        store.rate(.no, at: try XCTUnwrap(store.visibleIndices.first))
        assertCleanUpAvailabilityMatchesFresh(store)
        let snapshot = try XCTUnwrap(store.sourceFileRenamingPlanningSnapshot(scope: .all))
        let plan = try SourceOrganizationPlanner.makePlan(sourceFolder: snapshot.sourceFolder,
            selectedItems: snapshot.selectedItems, familyContextItems: snapshot.familyContextItems,
            configuration: FileRenamingPlanner.sourceConfiguration(customBaseName: "Renamed"),
            knownOriginFolderPathBytesByFileID: snapshot.knownOriginFolderPathBytesByFileID,
            pairedFiles: snapshot.pairedFiles)
        let generation = store.archiveFolderIndex?.generation
        store.startSourceRename(plan, presentsSheet: false)
        try await until { store.archiveFolderIndex?.generation != generation && !store.isFileOperationRunning }
        try await ready(store)
        XCTAssertEqual(store.archiveSelectedFolderID, "A")
        XCTAssertEqual(store.currentItem?.primaryFile.id, "A/Renamed.txt")
        XCTAssertEqual(try String(contentsOf: fixture.media.appendingPathComponent("A/Renamed.txt"), encoding: .utf8), "A/one.txt")
        assertCleanUpAvailabilityMatchesFresh(store)
        store.filter.searchText = "one"
        store.flushPendingFilter()
        XCTAssertTrue(store.visibleIndices.isEmpty)
        assertCleanUpAvailabilityMatchesFresh(store)
        store.filter.searchText = ""
        store.flushPendingFilter()
        let renamedGeneration = store.archiveFolderIndex?.generation
        store.undo()
        try await until { store.archiveFolderIndex?.generation != renamedGeneration && !store.isFileOperationRunning }
        try await ready(store)
        XCTAssertEqual(store.archiveSelectedFolderID, "A")
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].primaryFile.id }, ["A/one.txt"])
        XCTAssertEqual(try String(contentsOf: fixture.media.appendingPathComponent("B/three.txt"), encoding: .utf8), "B/three.txt")
        assertCleanUpAvailabilityMatchesFresh(store)
        store.isRenamePresented = false
        await finish(store)
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("file-operation projection did not settle")
        throw TestError.opening
    }

    private func ready(_ store: SessionStore) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if case .ready = store.phase { return }
            if let error = store.scanError { XCTFail(error); throw TestError.opening }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("archive did not become ready")
        throw TestError.opening
    }
    private func finish(_ store: SessionStore) async {
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
    }
    private enum TestError: Error { case opening }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-FolderNavigation-\(UUID())")
        let defaultsName = "Louppe-FolderNavigation-\(UUID())"
        let defaults: UserDefaults
        var media: URL { root.appendingPathComponent("media") }
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            for dir in ["A/Nested", "B", "Empty"] {
                try FileManager.default.createDirectory(at: media.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            for file in ["root.txt", "A/one.txt", "A/Nested/two.txt", "B/three.txt"] {
                try Data(file.utf8).write(to: media.appendingPathComponent(file))
            }
        }
        func store() -> SessionStore {
            SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                reviewDefaults: defaults,
                archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("navigation.json")))
        }
        func remove() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
