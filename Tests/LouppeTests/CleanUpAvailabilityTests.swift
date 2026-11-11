import AppKit
import XCTest
@testable import Louppe

@MainActor
final class CleanUpAvailabilityTests: XCTestCase {
    private let ratings: [Rating] = [.undecided, .yes, .no]

    func testEmptyAllYesAndMixedDecisions() {
        let (store, cleanup) = makeStore([])
        defer { cleanup() }
        store.phase = .welcome
        assertFresh(store)
        store.phase = .ready
        store.items = [photo("YES.JPG", .yes), photo("PAIR.NEF", .yes, paired: .no)]
        store.rebuildDerivedDataForTesting()
        assertFresh(store)
        store.cleanUpScope = .all
        XCTAssertFalse(store.hasCleanUpTargets(for: .trashNo))
        XCTAssertFalse(store.hasCleanUpTargets(for: .keepOnlyYes), "Mixed physical decisions are protected")
        store.rate(.no, at: 1)
        assertFresh(store)
        XCTAssertTrue(store.hasCleanUpTargets(for: .trashNo))
        store.undo()
        assertFresh(store)
        XCTAssertFalse(store.hasCleanUpTargets(for: .keepOnlyYes))
        store.items = []
        store.rebuildDerivedDataForTesting()
        assertFresh(store)
    }

    func testCurrentSelectionAndVisibilityBoundaries() {
        let (store, cleanup) = makeStore([photo("YES.JPG", .yes), photo("NO.JPG", .no), photo("OPEN.JPG")])
        defer { cleanup() }
        store.cleanUpScope = .selected
        store.setSelection([])
        store.currentIndex = 0
        XCTAssertFalse(store.hasCleanUpTargets(for: .trashNo))
        store.currentIndex = 1
        XCTAssertTrue(store.hasCleanUpTargets(for: .trashNo))
        assertFresh(store)
        store.setSelection([0, 2])
        XCTAssertFalse(store.hasCleanUpTargets(for: .trashNo))
        store.currentIndex = 1 // Explicit selection still owns the scope.
        assertFresh(store)
        store.filter.excludedDecisionStates = [.undecided]
        assertFresh(store)
        store.setSelection([])
        store.filter.searchText = "absent"
        store.flushPendingFilter()
        assertFresh(store)
        XCTAssertFalse(store.hasCleanUpTargets(for: .selection))
        store.filter = PhotoFilter()
        store.flushPendingFilter()
        store.setSelection([0, 1, 2])
        store.rate(.yes)
        assertFresh(store)
        store.undo()
        assertFresh(store)
        store.clearAllRatings()
        assertFresh(store)
        store.undo()
        assertFresh(store)
    }

    func testKeyboardAndMenuDecisionsShareIncrementalUpdates() throws {
        let (store, cleanup) = makeStore([photo("ONE.JPG"), photo("TWO.JPG", .yes)])
        defer { cleanup() }
        store.setIndex(0)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: 2
        ))
        XCTAssertTrue(SessionView(store: store).handleKey(event))
        XCTAssertEqual(store.items[0].rating, .no)
        assertFresh(store)
        store.rate(.yes) // Same command as the menu.
        assertFresh(store)
        store.undo()
        assertFresh(store)
    }

    func testPairingAndArchiveScopeChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-Availability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = file("A/PAIR.NEF", .yes, root: root)
        let jpeg = file("B/PAIR.JPG", .no, root: root)
        let (store, cleanup) = makeStore([PhotoItem(primaryFile: raw, pairedFile: jpeg), photo("A/YES.JPG", .yes)])
        defer { cleanup() }
        store.setRawJPEGPairingMode(.together) // Before source authority, no task.
        store.rebuildDerivedDataForTesting(sourceFolder: root)
        store.replaceArchiveFolderIndex(ArchiveFolderIndex(root: root, directories: [], items: store.items))
        assertFresh(store)
        store.selectArchiveFolder("A")
        assertFresh(store)
        store.setArchiveIncludesDescendants(false)
        assertFresh(store)
        store.setRawJPEGPairingMode(.separate)
        let deadline = ContinuousClock.now + .seconds(10)
        while store.isSessionTransitioning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isSessionTransitioning)
        XCTAssertNil(store.pairingMetadataError)
        store.selectArchiveFolder("A")
        store.setArchiveIncludesDescendants(false)
        assertFresh(store)
        store.cleanUpScope = .all
        XCTAssertFalse(store.hasCleanUpTargets(for: .pairedJPEGs), "Separate JPEG is outside folder A")
        XCTAssertTrue(store.hasCleanUpTargets(for: .pairedRAWs))
        store.selectArchiveFolder("B")
        assertFresh(store)
        XCTAssertTrue(store.hasCleanUpTargets(for: .pairedJPEGs))
        XCTAssertFalse(store.hasCleanUpTargets(for: .pairedRAWs))
        store.selectArchiveFolder("")
        assertFresh(store)
        store.setRawJPEGPairingMode(.together)
        let regroupDeadline = ContinuousClock.now + .seconds(10)
        while store.isSessionTransitioning, ContinuousClock.now < regroupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isSessionTransitioning)
        XCTAssertNil(store.pairingMetadataError)
        XCTAssertTrue(store.items.contains { $0.hasMixedRatings })
        assertFresh(store)
    }

    func testAppliedCleanUpOutcomeRebuildsAvailabilityIncludingEmptySession() {
        let removed = photo("NO.JPG", .no)
        let survivor = photo("YES.JPG", .yes)
        let (store, cleanup) = makeStore([removed, survivor])
        defer { cleanup() }
        assertFresh(store)
        let result = TrashBatchResult(succeeded: [TrashedPhotoSnapshot(index: 0, item: removed, files: [])],
            stalePhotos: [], failedPhotos: 0, inconsistentPhotos: 0, journalFailure: false, requiresRecovery: false)
        store.finishCleanUpForTesting(result, mode: .trashNo, preparedSurvivors: [])
        XCTAssertEqual(store.items.map(\.id), [survivor.id])
        assertFresh(store)
        store.cleanUpScope = .all
        XCTAssertFalse(store.hasCleanUpTargets(for: .trashNo))
        XCTAssertFalse(store.hasCleanUpTargets(for: .keepOnlyYes))
        let emptied = TrashBatchResult(succeeded: [TrashedPhotoSnapshot(index: 0, item: survivor, files: [])],
            stalePhotos: [], failedPhotos: 0, inconsistentPhotos: 0, journalFailure: false, requiresRecovery: false)
        store.finishCleanUpForTesting(emptied, mode: .selection, preparedSurvivors: [])
        XCTAssertTrue(store.items.isEmpty)
        assertFresh(store)
    }

    func testWorkerSuccessResolvesChangedDecisionsAndTrashUndo() async throws {
        try await workerRoundTrip(failingNames: [])
    }

    func testWorkerPartialSuccessResolvesChangedDecisionsAndTrashUndo() async throws {
        try await workerRoundTrip(failingNames: ["C.png"])
    }

    func testWorkerFailureResolvesChangedDecisions() async throws {
        try await workerRoundTrip(failingNames: ["B.png", "C.png"])
    }

    private func workerRoundTrip(failingNames: Set<String>) async throws {
        let root = try disposableRoot()
        let media = root.appendingPathComponent("Media")
        let trash = root.appendingPathComponent("Trash")
        let journals = root.appendingPathComponent("Operations")
        try writePhotos(["A.png", "B.png", "C.png"], to: media)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let (store, cleanup) = makeDiskStore(root: root)
        defer { cleanup() }
        let fileManager = AvailabilityTrashFileManager(trash: trash, failingNames: failingNames)
        store.makeCleanUpFileManagerForTesting = { fileManager }
        store.cleanUpJournalDirectoryForTesting = journals
        store.openFolder(media)
        try await wait { self.isReady(store) }
        func index(_ name: String) throws -> Int { try XCTUnwrap(store.items.firstIndex { $0.id == name }) }
        store.rate(.no, at: try index("A.png"))
        store.rate(.yes, at: try index("B.png"))
        store.rate(.yes, at: try index("C.png"))
        store.cleanUpScope = .all
        assertFresh(store)
        store.requestCleanUp(.trashNo)
        XCTAssertEqual(store.pendingCleanUp, .trashNo)
        XCTAssertEqual(store.cleanUpCounts(for: .trashNo).photos, 1)
        // Change the exact target set while confirmation is pending. All of
        // these commands must stay independent of any menu availability cache.
        store.rate(.yes, at: try index("A.png"))
        store.rate(.no, at: try index("B.png"))
        store.rate(.no, at: try index("C.png"))
        assertFresh(store)
        XCTAssertEqual(store.cleanUpCounts(for: .trashNo).photos, 2)
        store.performCleanUp(.trashNo)
        XCTAssertTrue(store.isCleaningUp)
        try await wait { !store.isCleaningUp }
        XCTAssertEqual(Set(fileManager.attemptedNames), ["B.png", "C.png"])
        XCTAssertTrue(store.cleanUpStalePhotos.isEmpty)
        let removed = Set(["B.png", "C.png"]).subtracting(failingNames)
        XCTAssertEqual(Set(store.items.map(\.id)), Set(["A.png", "B.png", "C.png"]).subtracting(removed))
        for name in ["A.png", "B.png", "C.png"] {
            XCTAssertEqual(FileManager.default.fileExists(atPath: media.appendingPathComponent(name).path), !removed.contains(name))
            XCTAssertEqual(FileManager.default.fileExists(atPath: trash.appendingPathComponent(name).path), removed.contains(name))
        }
        XCTAssertEqual(store.cleanUpError != nil, !failingNames.isEmpty)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        assertFresh(store)
        // Exercise the live selection fallback, even after the final No was
        // removed and the surviving current photo has changed index.
        store.dismissCleanUpError()
        if !removed.isEmpty {
            store.undo()
            XCTAssertTrue(store.isCleaningUp)
            try await wait { !store.isCleaningUp }
            XCTAssertNil(store.cleanUpError)
            XCTAssertEqual(Set(store.items.map(\.id)), ["A.png", "B.png", "C.png"])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
            for name in ["A.png", "B.png", "C.png"] {
                XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(name)), tinyPNG)
            }
            assertFresh(store)
            XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        }
        _ = await store.saveSessionForTermination()
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        store.closeSession()
        try await wait { store.sourceFolder == nil && store.items.isEmpty }
        assertFresh(store)
    }

    func testSessionSwitchCloseAndReopenUseProductionInvalidation() async throws {
        let root = try disposableRoot()
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        try writePhotos(["First.png"], to: first)
        try writePhotos(["Second.png"], to: second)
        let (store, cleanup) = makeDiskStore(root: root)
        defer { cleanup() }
        store.openFolder(first)
        try await wait { self.isReady(store) }
        store.rate(.no, at: 0)
        assertFresh(store)
        store.openFolder(second)
        try await wait { self.isReady(store) && store.items.first?.id == "Second.png" }
        assertFresh(store)
        store.rate(.yes, at: 0)
        assertFresh(store)
        store.closeSession()
        try await wait { store.sourceFolder == nil && store.items.isEmpty }
        assertFresh(store)
        store.openFolder(first)
        try await wait { self.isReady(store) && store.items.first?.id == "First.png" }
        XCTAssertEqual(store.items[0].rating, .no)
        assertFresh(store)
        store.closeSession()
        try await wait { store.sourceFolder == nil && store.items.isEmpty }
        assertFresh(store)
    }

    func testLargeAllYesSessionUpdatesAfterNavigationAndSingleDecision() {
        let (store, cleanup) = makeStore((0..<17_015).map { photo("\($0).JPG", .yes) })
        defer { cleanup() }
        for index in [0, 8_500, 17_014] {
            store.currentIndex = index
            assertFresh(store)
            store.rate(.no, at: index)
            assertFresh(store)
            store.undo()
            assertFresh(store)
        }
    }

    func testRandomizedDifferentialAcrossMetadataFiltersSelectionAndReplacements() throws {
        let root = try disposableRoot()
        var random = Generator()
        let (store, cleanup) = makeStore((0..<96).map {
            photo("\($0).NEF", ratings[$0 % 3], paired: $0.isMultiple(of: 3) ? ratings[($0 + 1) % 3] : nil, root: root)
        }, sourceFolder: root)
        defer { cleanup() }
        store.cleanUpScope = .all
        XCTAssertTrue(store.hasCleanUpTargets(for: .pairedJPEGs))
        XCTAssertTrue(store.hasCleanUpTargets(for: .pairedRAWs))
        for step in 0..<360 {
            let index = random.next(96)
            switch random.next(12) {
            case 0: store.rate(ratings[random.next(3)], at: index)
            case 1: store.setSelection(Set((0..<random.next(15)).map { _ in random.next(96) }))
            case 2: store.currentIndex = index
            case 3: store.filter.excludedDecisionStates = random.next(2) == 0 ? [.yes] : []
            case 4: store.undo()
            case 5: store.clearAllRatings()
            case 6: store.setStarRating(random.next(2) == 0 ? .three : nil, at: index)
            case 7: store.filter.excludedStarStates = random.next(2) == 0 ? [.unrated] : []
            case 8: store.sort = PhotoSort(key: step.isMultiple(of: 2) ? .decision : .name, ascending: random.next(2) == 0)
            case 9: store.setColorLabel(random.next(2) == 0 ? .red : nil, at: index)
            case 10: store.toggleRating(at: index)
            default:
                store.items = store.items.reversed()
                store.rebuildDerivedDataForTesting()
            }
            assertFresh(store)
        }
    }

    /// Confirmation uses fresh targets and the existing physical-member scope
    /// predicate, independent of the menu cache. Check all scopes twice so a
    /// scope switch cannot conceal stale state.
    private func assertFresh(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) {
        assertCleanUpAvailabilityMatchesFresh(store, file: file, line: line)
    }

    private func makeStore(_ items: [PhotoItem], sourceFolder: URL? = nil) -> (SessionStore, () -> Void) {
        let name = "CleanUpAvailability.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
        let store = SessionStore(reviewDefaults: defaults)
        store.items = items
        store.rebuildDerivedDataForTesting(sourceFolder: sourceFolder)
        store.phase = .ready
        store.pauseQualityCueAnalysis()
        return (store, {
            store.beginTerminationPreparation()
            defaults.removePersistentDomain(forName: name)
        })
    }

    private func photo(_ id: String, _ rating: Rating = .undecided, paired: Rating? = nil,
                       root: URL = URL(fileURLWithPath: "/absent-louppe-availability")) -> PhotoItem {
        PhotoItem(primaryFile: file(id, rating, root: root), pairedFile: paired.map {
            file(id.replacingOccurrences(of: ".NEF", with: ".JPG"), $0, root: root)
        })
    }

    private func file(_ id: String, _ rating: Rating, root: URL = URL(fileURLWithPath: "/absent-louppe-availability")) -> PhotoFile {
        PhotoFile(id: id, url: root.appendingPathComponent(id), captureDate: nil,
            cameraModel: nil, lensModel: nil, fileSize: 1, rating: rating)
    }

    private var tinyPNG: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func disposableRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-Availability-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writePhotos(_ names: [String], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try tinyPNG.write(to: folder.appendingPathComponent(name)) }
    }

    private func makeDiskStore(root: URL) -> (SessionStore, () -> Void) {
        let name = "CleanUpAvailabilityDisk.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            saveTrailingDelay: 60, saveMaximumDelay: 60,
            operationJournalDirectory: root.appendingPathComponent("Operations"), reviewDefaults: defaults)
        return (store, {
            store.beginTerminationPreparation()
            defaults.removePersistentDomain(forName: name)
        })
    }

    private func isReady(_ store: SessionStore) -> Bool {
        if case .ready = store.phase { return !store.isSessionTransitioning && !store.isFileOperationRunning }
        return false
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else {
            XCTFail("Session lifecycle did not settle", file: file, line: line)
            throw CocoaError(.executableRuntimeMismatch)
        }
    }

    private struct Generator {
        var state: UInt64 = 0xC1
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 32) % bound
        }
    }
}

/// Differential oracle shared by worker-backed lifecycle suites. This calls
/// fresh confirmation target resolution, never the availability facts/counters.
@MainActor
func assertCleanUpAvailabilityMatchesFresh(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) {
    let previous = store.cleanUpScope
    defer { store.cleanUpScope = previous }
    for scope in [CleanUpScope.all, .filtered, .selected, .all] {
        store.cleanUpScope = scope
        for mode in [CleanUpMode.selection, .trashNo, .keepOnlyYes, .pairedJPEGs, .pairedRAWs] {
            XCTAssertEqual(store.hasCleanUpTargets(for: mode), store.cleanUpCounts(for: mode).photos > 0,
                "scope=\(scope), mode=\(mode)", file: file, line: line)
        }
    }
}

/// The real worker and journal run normally. Only macOS Trash is redirected
/// to this test's folder, with deterministic per-file move failures.
private final class AvailabilityTrashFileManager: FileManager, @unchecked Sendable {
    private let trash: URL
    private let failingNames: Set<String>
    private let lock = NSLock()
    private var attempted: [String] = []
    var attemptedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return attempted
    }

    init(trash: URL, failingNames: Set<String>) {
        self.trash = trash
        self.failingNames = failingNames
        super.init()
    }

    override func trashItem(at url: URL,
        resultingItemURL result: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        lock.lock()
        attempted.append(url.lastPathComponent)
        lock.unlock()
        if failingNames.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        let destination = trash.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        result?.pointee = destination as NSURL
    }
}
