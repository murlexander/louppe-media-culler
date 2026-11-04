import Foundation
import XCTest
@testable import Louppe

/// AUD-06/AUD-17 equivalence and safety contracts: cached metadata-sort ranks,
/// coalesced recovery projection, cheaper batch bookkeeping and byte-budgeted Undo.
@MainActor
final class ReviewProjectionRetentionTests: XCTestCase {
    // MARK: - Metadata-rank grouping

    func testMetadataRankGroupsMatchLiveComparatorForMixedPairsFiltersAndDirections() {
        var generator = SplitMix(seed: 0xA0D6)
        let items = pairedFixture(count: 160, generator: &generator)
        var filters: [PhotoFilter] = [PhotoFilter()]
        var hidesNo = PhotoFilter(); hidesNo.excludedDecisionStates = [.no]
        var hidesUnrated = PhotoFilter(); hidesUnrated.excludedStarStates = [.unrated]
        var hidesCamera = PhotoFilter(); hidesCamera.excludedCameras = ["Camera 1"]
        filters += [hidesNo, hidesUnrated, hidesCamera]
        for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
            for ascending in [true, false] {
                let sort = PhotoSort(key: key, ascending: ascending)
                var index = PreparedSessionIndex()
                index.rebuildItems(items, sort: sort)
                for round in 0..<40 {
                    mutate(items, generator: &generator, count: round.isMultiple(of: 7) ? items.count : 3)
                    index.rebuildPreparedSort(items, sort: sort)
                    let filter = filters[round % filters.count]
                    for grouped in [true, false] {
                        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: grouped)
                        assertMatchesReference(index, items: items, sort: sort, filter: filter, grouped: grouped)
                    }
                }
                // Another sort discards the ranks; the live comparator still groups.
                let camera = PhotoSort(key: .camera)
                index.rebuildPreparedSort(items, sort: camera)
                index.applyFilter(PhotoFilter(), to: items, sort: camera, isGroupingEnabled: true)
                assertMatchesReference(index, items: items, sort: camera, filter: PhotoFilter(), grouped: true)
            }
        }
    }

    func testIdenticalOrderWithChangedValuesStillRefreshesRankedGroups() {
        for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
            let items = (0..<6).map { photo("\($0).JPG", date: Double($0)) }
            let sort = PhotoSort(key: key)
            var index = PreparedSessionIndex()
            index.rebuildItems(items, sort: sort)
            index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
            for item in items {
                item.setRating(.no, ratedAt: nil)
                item.setStars(.two, changedAt: nil)
                item.setColor(.blue, changedAt: nil)
            }
            index.rebuildPreparedSort(items, sort: sort)
            index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
            assertMatchesReference(index, items: items, sort: sort, filter: PhotoFilter(), grouped: true)
            XCTAssertEqual(index.visibleGroups.count, 1)
            XCTAssertEqual(index.visibleGroups.first?.id, key.groupID(for: items[0]))
        }
    }

    // MARK: - Batch edits and Undo

    func testBatchEditsAndUndoRestoreIndependentPhysicalMetadataAndExactTallies() {
        var generator = SplitMix(seed: 0x17)
        let (store, cleanup) = makeStore(items: pairedFixture(count: 120, generator: &generator))
        defer { cleanup() }
        store.sort = PhotoSort(key: .decision)
        let original = store.items.flatMap(\.metadataSnapshots)
        var history: [[PhotoFileMetadataSnapshot]] = []
        func step(_ body: () -> Void) {
            history.append(store.items.flatMap(\.metadataSnapshots))
            body()
            assertTallies(store)
            assertStoreProjection(store)
        }
        store.selectAllVisible()
        step { store.rate(.yes) }
        store.selectAllVisible()
        step { store.setStarRating(.three) }
        step { store.setColorLabel(.green, at: 5) }
        store.selectAllVisible()
        step { store.setColorLabel(.red) }
        step { store.rate(.no, at: 7) }
        step { store.clearAllRatings() }
        XCTAssertEqual(store.undoStepCountForTesting, history.count)
        while let expected = history.popLast() {
            store.undo()
            XCTAssertEqual(store.items.flatMap(\.metadataSnapshots), expected)
            assertTallies(store)
            assertStoreProjection(store)
        }
        XCTAssertEqual(store.items.flatMap(\.metadataSnapshots), original)
        XCTAssertGreaterThan(store.mixedCount, 0, "The fixture must keep Mixed pairs through Undo.")
    }

    func testUndoByteBudgetEvictsOldestMetadataStepsAndKeepsFileOperationSteps() {
        var generator = SplitMix(seed: 0x5EED)
        let (store, cleanup) = makeStore(items: pairedFixture(count: 50, generator: &generator))
        defer { cleanup() }
        let stride = SessionStore.undoMetadataChangeStrideForTesting
        let filesPerBatch = store.items.reduce(0) { $0 + $1.individualFiles.count }
        store.pushCleanUpUndoForTesting()
        var states: [[PhotoFileMetadataSnapshot]] = []
        states.append(store.items.flatMap(\.metadataSnapshots))
        store.selectAllVisible()
        store.rate(.yes)
        // Budget charges reserved storage, which covers every retained change.
        let batchBytes = store.undoRetainedMetadataBytesForTesting
        XCTAssertGreaterThanOrEqual(batchBytes, filesPerBatch * stride)
        store.undoMetadataByteBudget = batchBytes * 2 + stride
        for rating in [Rating.no, .yes, .no, .yes] {
            states.append(store.items.flatMap(\.metadataSnapshots))
            store.selectAllVisible()
            store.rate(rating)
        }
        // Two whole batches fit; the oldest three were evicted, the file
        // operation step at the bottom survives metadata pressure.
        XCTAssertEqual(store.undoStepCountForTesting, 3)
        XCTAssertEqual(store.undoRetainedMetadataChangesForTesting, filesPerBatch * 2)
        XCTAssertLessThanOrEqual(store.undoRetainedMetadataBytesForTesting, store.undoMetadataByteBudget)
        store.undo()
        XCTAssertEqual(store.items.flatMap(\.metadataSnapshots), states[4])
        store.undo()
        XCTAssertEqual(store.items.flatMap(\.metadataSnapshots), states[3])
        XCTAssertEqual(store.undoStepCountForTesting, 1, "Only the Clean Up restore remains.")
        assertTallies(store)

        // A step larger than the whole budget is still kept as the newest one.
        store.undoMetadataByteBudget = stride
        store.selectAllVisible()
        store.setStarRating(.one)
        XCTAssertEqual(store.undoStepCountForTesting, 2)
        XCTAssertEqual(store.undoRetainedMetadataChangesForTesting, filesPerBatch)
        store.selectAllVisible()
        store.setStarRating(.two)
        XCTAssertEqual(store.undoStepCountForTesting, 2)
        XCTAssertEqual(store.undoRetainedMetadataChangesForTesting, filesPerBatch)

        // Single-photo steps still follow the 500-step limit, not the budget.
        store.undoMetadataByteBudget = SessionStore.undoMetadataByteBudgetDefault
        store.clearSelection()
        for offset in 0..<(SessionStore.undoStepLimit + 5) {
            store.setColorLabel(offset.isMultiple(of: 2) ? .red : .blue, at: offset % store.items.count)
        }
        XCTAssertEqual(store.undoStepCountForTesting, SessionStore.undoStepLimit)
    }

    func testUndoChargesReservedStorageForUnpairedAndPairedBatches() {
        let stride = SessionStore.undoMetadataChangeStrideForTesting
        for paired in [false, true] {
            let count = 64
            let items = (0..<count).map { i -> PhotoItem in
                func file(_ ext: String) -> PhotoFile {
                    PhotoFile(id: "IMG_\(i).\(ext)",
                              url: URL(fileURLWithPath: "/private/tmp/louppe-review-projection/IMG_\(i).\(ext)"),
                              captureDate: Date(timeIntervalSince1970: Double(i)), cameraModel: nil,
                              lensModel: nil, fileSize: 1)
                }
                return PhotoItem(primaryFile: file("RAF"), pairedFile: paired ? file("JPG") : nil)
            }
            let (store, cleanup) = makeStore(items: items)
            let files = paired ? count * 2 : count
            store.selectAllVisible()
            store.rate(.yes)
            let bytes = store.undoRetainedMetadataBytesForTesting
            XCTAssertEqual(store.undoRetainedMetadataChangesForTesting, files)
            XCTAssertGreaterThanOrEqual(bytes, files * stride, "Charges cover every retained change.")
            // Unpaired batches no longer reserve two slots per photo.
            XCTAssertLessThan(bytes, files * stride * 3 / 2, "paired: \(paired)")
            // Budget checks use the same charge: a budget of exactly one
            // batch keeps one batch and evicts the older one.
            store.undoMetadataByteBudget = bytes
            store.selectAllVisible()
            store.rate(.no)
            XCTAssertEqual(store.undoStepCountForTesting, 1)
            XCTAssertEqual(store.undoRetainedMetadataBytesForTesting, bytes)
            cleanup()
        }
    }

    // MARK: - Batched recovery

    func testBatchRecoveryKeepsCommandsSelectionNavigationAndExportScopeConsistent() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-RecoveryProjection-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let png = try LouppeSpeedReviewRetentionTests.tinyPNG()
        let count = 40
        let digest = String(repeating: "cd", count: 32)
        var entries: [SessionEntry] = []
        for i in 0..<count {
            let name = String(format: "IMG_%03d.png", i)
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
            let current = try FileOperationJournal.captureIdentity(at: url)
            let old = FileOperationJournal.FileIdentity(
                volumeRootPath: current.volumeRootPath, volumeUUIDString: current.volumeUUIDString,
                systemNumber: current.systemNumber, fileNumber: current.fileNumber &+ 1_000_000_000,
                logicalSize: current.logicalSize, modificationTime: current.modificationTime,
                statusChangeTime: current.statusChangeTime, birthTime: current.birthTime)
            entries.append(SessionEntry(
                filename: name, pairedFilename: nil, rating: (i.isMultiple(of: 3) ? Rating.no : .yes).rawValue,
                ratedAt: Date(timeIntervalSince1970: 50), stars: i.isMultiple(of: 2) ? .five : nil,
                colorLabel: nil, fileIdentity: old, contentSHA256: digest))
        }
        let backups = root.appendingPathComponent("Backups")
        let saved = await SessionPersistence(backupDirectory: backups).save(
            SessionFile(version: 7, sourcePath: photos.path, scannedAt: Date(), entries: entries,
                        fileIDEncoding: .percentEncodedFileSystemPath), for: photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)

        let defaultsName = "ReviewProjectionRetention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
        defaults.set("decision", forKey: ReviewPreferences.Keys.defaultSortKey)
        let gate = Gate(openUntil: 1)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: backups),
            reviewDefaults: defaults,
            sessionContentVerification: { file, _ in
                await gate.admit()
                return SessionContentProof(identity: file.scannedIdentity!, sha256: digest)
            })
        store.recoveryBatchMinimumInterval = .seconds(30)
        store.openFolder(photos)
        try await wait { if case .ready = store.phase { return true }; return false }
        // The first result applies at once; later ones wait for the interval.
        try await wait { store.automaticallyRestoredSessionFiles == 1 }
        store.filter.excludedDecisionStates = [.no]
        await gate.allow(5)
        try await waitAsync { await gate.calls >= 7 }
        try await wait { store.pendingRecoveryResultCountForTesting == 5 }
        XCTAssertEqual(store.automaticallyRestoredSessionFiles, 1)
        let batchesBeforeCommands = store.recoveryBatchesAppliedForTesting

        // Pending results are not restored yet: metadata, counts and the
        // projection agree, so every command resolves the same visible order.
        assertStoreProjection(store)
        assertTallies(store)
        store.selectAllVisible()
        XCTAssertEqual(store.selectedIndices, Set(store.visibleIndices))
        XCTAssertEqual(store.visibleIndices, referenceProjection(
            items: store.items, sort: store.sort, filter: store.filter, grouped: store.isGroupingEnabled
        ).flatMap(\.indices))
        store.clearSelection()
        let order = store.visibleIndices
        XCTAssertGreaterThan(order.count, 2)
        store.setIndex(order[0])
        store.goNext()
        XCTAssertEqual(store.currentIndex, order[1])
        store.selectRange(to: order[2])
        // The range runs from the current photo through the target in visible order.
        XCTAssertEqual(store.selectedIndices, Set(order[1...2]))
        store.clearSelection()
        let keepers = ExportSelectionConfiguration.preset(.keepers).snapshot(
            items: store.items, filtered: store.visibleIndices, selected: store.selectedIndices)
        XCTAssertEqual(Set(keepers.itemIndices),
                       Set(store.visibleIndices.filter { store.items[$0].rating == .yes }))
        XCTAssertEqual(store.recoveryBatchesAppliedForTesting, batchesBeforeCommands,
                       "Commands neither apply nor need pending results.")

        // Completion applies the remaining results as batches, not per file,
        // and advances the revision an open Export summary refreshes on.
        let revision = store.reviewStateRevision
        await gate.open()
        try await wait { store.sessionContentCheck == .finished }
        XCTAssertEqual(store.automaticallyRestoredSessionFiles, count)
        XCTAssertEqual(store.pendingRecoveryResultCountForTesting, 0)
        XCTAssertLessThan(store.recoveryBatchesAppliedForTesting, batchesBeforeCommands + 5,
                          "Recovery must not project the session once per restored file.")
        XCTAssertGreaterThan(store.reviewStateRevision, revision)
        assertStoreProjection(store)
        assertTallies(store)
        XCTAssertEqual(store.noCount, (0..<count).filter { $0.isMultiple(of: 3) }.count)
        XCTAssertFalse(store.visibleIndices.contains { store.items[$0].rating == .no })
        let refreshed = ExportSelectionConfiguration.preset(.keepers).snapshot(
            items: store.items, filtered: store.visibleIndices, selected: store.selectedIndices)
        XCTAssertEqual(refreshed.itemCount, (0..<count).filter { !$0.isMultiple(of: 3) }.count,
                       "Every restored keeper is in the refreshed Export scope.")
        _ = await store.saveSessionForTermination()
        _ = await store.waitForPersistenceIdleForTesting()
        store.beginTerminationPreparation()
    }

    func testPausingDiscardsUnappliedRecoveryResultsAndAResumeRestoresThem() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-RecoveryPause-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let png = try LouppeSpeedReviewRetentionTests.tinyPNG()
        let digest = String(repeating: "ef", count: 32)
        var entries: [SessionEntry] = []
        for i in 0..<6 {
            let name = "IMG_\(i).png"
            let url = photos.appendingPathComponent(name)
            try png.write(to: url)
            let current = try FileOperationJournal.captureIdentity(at: url)
            let old = FileOperationJournal.FileIdentity(
                volumeRootPath: current.volumeRootPath, volumeUUIDString: current.volumeUUIDString,
                systemNumber: current.systemNumber, fileNumber: current.fileNumber &+ 1_000_000_000,
                logicalSize: current.logicalSize, modificationTime: current.modificationTime,
                statusChangeTime: current.statusChangeTime, birthTime: current.birthTime)
            entries.append(SessionEntry(filename: name, pairedFilename: nil, rating: Rating.yes.rawValue,
                                        ratedAt: Date(timeIntervalSince1970: 50),
                                        fileIdentity: old, contentSHA256: digest))
        }
        let backups = root.appendingPathComponent("Backups")
        _ = await SessionPersistence(backupDirectory: backups).save(
            SessionFile(version: 7, sourcePath: photos.path, scannedAt: Date(), entries: entries,
                        fileIDEncoding: .percentEncodedFileSystemPath), for: photos, sequence: 1)
        let gate = Gate(openUntil: 3)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: backups),
            reviewDefaults: UserDefaults(suiteName: "ReviewProjectionRetention.\(UUID().uuidString)")!,
            sessionContentVerification: { file, _ in
                await gate.admit()
                return SessionContentProof(identity: file.scannedIdentity!, sha256: digest)
            })
        store.recoveryBatchMinimumInterval = .seconds(30)
        store.openFolder(photos)
        try await wait { if case .ready = store.phase { return true }; return false }
        try await waitAsync { await gate.calls >= 4 }
        try await wait { store.pendingRecoveryResultCountForTesting == 2 }
        XCTAssertEqual(store.automaticallyRestoredSessionFiles, 1)
        store.toggleSessionContentChecks()
        XCTAssertEqual(store.pendingRecoveryResultCountForTesting, 0)
        XCTAssertEqual(store.automaticallyRestoredSessionFiles, 1, "Paused results are not applied later.")
        await gate.open()
        store.toggleSessionContentChecks()
        try await wait { store.automaticallyRestoredSessionFiles == 6 }
        try await wait { store.sessionContentCheck == .finished }
        XCTAssertEqual(store.yesCount, 6)
        assertStoreProjection(store)
        _ = await store.saveSessionForTermination()
        _ = await store.waitForPersistenceIdleForTesting()
        store.beginTerminationPreparation()
    }

    // MARK: - Helpers

    private actor Gate {
        private var remaining: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        init(openUntil: Int) { remaining = openUntil }
        func admit() async {
            calls += 1
            if remaining > 0 { remaining -= 1; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func allow(_ count: Int) {
            remaining += count
            while remaining > 0, !waiters.isEmpty {
                remaining -= 1
                waiters.removeFirst().resume()
            }
        }
        func open() {
            remaining = .max
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }

    private func pairedFixture(count: Int, generator: inout SplitMix) -> [PhotoItem] {
        (0..<count).map { i in
            let date = i.isMultiple(of: 9) ? nil : Date(timeIntervalSince1970: Double(i / 3))
            func file(_ ext: String) -> PhotoFile {
                PhotoFile(id: "Day\(i % 4)/IMG_\(i).\(ext)",
                          url: URL(fileURLWithPath: "/private/tmp/louppe-review-projection/Day\(i % 4)/IMG_\(i).\(ext)"),
                          captureDate: date, cameraModel: "Camera \(i % 3)", lensModel: nil, fileSize: 1)
            }
            let item = PhotoItem(primaryFile: file("RAF"), pairedFile: i.isMultiple(of: 4) ? nil : file("JPG"))
            for physical in item.individualFiles { randomize(physical, generator: &generator) }
            return item
        }
    }

    private func mutate(_ items: [PhotoItem], generator: inout SplitMix, count: Int) {
        for _ in 0..<count {
            let item = items[generator.next(items.count)]
            let files = item.individualFiles
            randomize(files[generator.next(files.count)], generator: &generator)
        }
    }

    private func randomize(_ file: PhotoFile, generator: inout SplitMix) {
        file.setRating([Rating.yes, .no, .undecided][generator.next(3)], ratedAt: nil)
        let stars = generator.next(StarRating.allCases.count + 1)
        file.setStars(stars == 0 ? nil : StarRating.allCases[stars - 1], changedAt: nil)
        let color = generator.next(PhotoColorLabel.allCases.count + 1)
        file.setColor(color == 0 ? nil : PhotoColorLabel.allCases[color - 1], changedAt: nil)
    }

    private func makeStore(items: [PhotoItem]) -> (SessionStore, () -> Void) {
        let defaultsName = "ReviewProjectionRetention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
        let store = SessionStore(reviewDefaults: defaults)
        store.items = items
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.pauseQualityCueAnalysis()
        return (store, {
            store.beginTerminationPreparation()
            defaults.removePersistentDomain(forName: defaultsName)
        })
    }

    private func assertTallies(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) {
        let states = store.items.map(\.metadataState)
        XCTAssertEqual(store.yesCount, states.filter { $0.decision == .yes }.count, file: file, line: line)
        XCTAssertEqual(store.noCount, states.filter { $0.decision == .no }.count, file: file, line: line)
        XCTAssertEqual(store.mixedCount, states.filter { $0.decision == .mixed }.count, file: file, line: line)
        XCTAssertEqual(store.undecidedCount,
                       states.filter { $0.decision == .undecided || $0.decision == .mixed }.count,
                       file: file, line: line)
        for rating in StarRating.allCases {
            XCTAssertEqual(store.starCount(rating), states.filter { $0.stars == .stars(rating) }.count,
                           file: file, line: line)
        }
        XCTAssertEqual(store.unratedStarCount, states.filter { $0.stars == .unrated }.count, file: file, line: line)
        XCTAssertEqual(store.mixedStarCount, states.filter { $0.stars == .mixed }.count, file: file, line: line)
        for label in PhotoColorLabel.allCases {
            XCTAssertEqual(store.colorCount(label), states.filter { $0.color == .label(label) }.count,
                           file: file, line: line)
        }
        XCTAssertEqual(store.noColorCount, states.filter { $0.color == PhotoItemColorLabelState.none }.count,
                       file: file, line: line)
        XCTAssertEqual(store.mixedColorCount, states.filter { $0.color == .mixed }.count, file: file, line: line)
    }

    private func assertStoreProjection(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) {
        let reference = referenceProjection(items: store.items, sort: store.sort, filter: store.filter,
                                            grouped: store.isGroupingEnabled)
        XCTAssertEqual(store.visibleIndices, reference.flatMap(\.indices), file: file, line: line)
        XCTAssertEqual(store.visibleGroups, reference, file: file, line: line)
    }

    private func assertMatchesReference(_ index: PreparedSessionIndex, items: [PhotoItem], sort: PhotoSort,
                                        filter: PhotoFilter, grouped: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let groups = referenceProjection(items: items, sort: sort, filter: filter, grouped: grouped)
        let expected = groups.flatMap(\.indices)
        XCTAssertEqual(index.visibleIndices, expected, file: file, line: line)
        XCTAssertEqual(index.visibleGroups, groups, file: file, line: line)
        XCTAssertEqual(index.visibleGridGroups.map(\.id), groups.map(\.id), file: file, line: line)
        XCTAssertEqual(index.visibleEntries.map(\.index), expected, file: file, line: line)
        var position = 0
        for (groupIndex, group) in groups.enumerated() {
            for (positionInGroup, itemIndex) in group.indices.enumerated() {
                XCTAssertEqual(index.location(forItemIndex: itemIndex),
                               .init(position: position, groupIndex: groupIndex, positionInGroup: positionInGroup),
                               file: file, line: line)
                position += 1
            }
        }
        XCTAssertEqual(index.visibleLocations.count, expected.count, file: file, line: line)
    }

    /// Independent of `PreparedSessionIndex`: comparator sort, live values.
    private func referenceProjection(items: [PhotoItem], sort: PhotoSort, filter: PhotoFilter,
                                     grouped: Bool) -> [PhotoGroup] {
        let prepared = PreparedPhotoFilter(filter)
        let expected = items.indices.sorted { sort.areInOrder(items[$0], items[$1]) }
            .filter { prepared.matches(items[$0]) }
        guard !expected.isEmpty else { return [] }
        guard grouped, sort.key != .name else {
            return [PhotoGroup(id: .ungrouped, title: nil, indices: expected)]
        }
        var runs: [[Int]] = []
        for itemIndex in expected {
            if let last = runs.last?.last, sort.key.sameGroup(items[last], items[itemIndex]) {
                runs[runs.count - 1].append(itemIndex)
            } else {
                runs.append([itemIndex])
            }
        }
        return runs.map {
            PhotoGroup(id: sort.key.groupID(for: items[$0[0]]), title: sort.key.groupTitle(for: items[$0[0]]),
                       indices: $0)
        }
    }

    private func photo(_ id: String, date: TimeInterval) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-review-projection/\(id)"),
            captureDate: Date(timeIntervalSince1970: date), cameraModel: nil, lensModel: nil, fileSize: 1))
    }

    private func waitAsync(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, file: file, line: line)
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
