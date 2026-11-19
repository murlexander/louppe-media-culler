import CryptoKit
import XCTest
@testable import Louppe

/// Differential checks for the decision-path speedups: each optimized path is
/// compared with the computation it replaced or with a full recount.
@MainActor
final class DecisionPathEquivalenceTests: XCTestCase {
    // MARK: - Proof-queue order

    /// The previous comparator, verbatim apart from the history lookup source.
    private func previousProofOrder(_ ids: [String], history: Set<String>) -> [String] {
        ids.sorted {
            let left = history.contains($0)
            let right = history.contains($1)
            return left == right ? $0 < $1 : left
        }
    }

    func testProofOrderMatchesThePreviousComparatorAcrossVariedIDs() {
        let folders = ["", "A/", "a/", "A/B/", "Z/", "2026-10-01/", "2026-10-1/", "%C3%A9t%C3%A9/",
                       "e%CC%81/", "B%20C/", "\u{E9}/", "~/", "A%2FB/"]
        let stems = ["IMG_1", "IMG_10", "IMG_2", "img_1", "a", "a.", "A", "DSCF0001", "DSCF0001 ",
                     "%25", "\u{1F600}", "\u{C5}", "Z", "0", ""]
        let extensions = [".RAF", ".JPG", ".jpg", ".NEF", ".HEIC", ""]
        var random = Generator(state: 0xA1D06)
        for round in 0..<60 {
            let size = round == 0 ? 0 : random.next(round < 30 ? 40 : 900)
            // Session IDs are unique; a Set also removes canonically equal spellings.
            var unique = Set<String>()
            while unique.count < size {
                unique.insert(folders[random.next(folders.count)] + stems[random.next(stems.count)]
                    + extensions[random.next(extensions.count)] + (random.next(4) == 0 ? "\(random.next(50))" : ""))
                if unique.count < size, random.next(3) == 0 { break }
            }
            var ids = Array(unique)
            ids.shuffle(using: &random)
            // Ties within each priority class, all-history and no-history rounds.
            let historyShare = [0, 1, 2, 4][round % 4]
            let flags = ids.map { _ in historyShare == 1 || (historyShare > 1 && random.next(historyShare) == 0) }
            let history = Set(zip(ids, flags).filter(\.1).map(\.0))
            let order = SessionStore.sessionContentCheckOrder(ids: ids, hasRecoveryHistory: flags)
            XCTAssertEqual(order.map { ids[$0] }, previousProofOrder(ids, history: history), "round \(round)")
            XCTAssertEqual(Set(order).count, ids.count)
        }
    }

    /// End to end: a replaced copy with saved history is proven before the
    /// rated files, which follow exact ID order across folders and pairs.
    func testStoreVerifiesRecoveryFirstThenExactIDOrderAcrossFolders() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-ProofOrder-\(UUID())")
        let photos = root.appendingPathComponent("Photos")
        let backups = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("sub"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "Packaging/AppIcon/AppIcon.iconset/icon_32x32.png"))
        let names = ["Z.png", "A.png", "M.png", "sub/B.png", "sub/a.png", "PAIR.NEF", "PAIR.JPG"]
        for name in names { try bytes.write(to: photos.appendingPathComponent(name)) }
        func entry(_ name: String, rating: Rating, fingerprint: Bool = false) throws -> SessionEntry {
            let url = photos.appendingPathComponent(name)
            return SessionEntry(
                filename: name, pairedFilename: nil, rating: rating.rawValue,
                ratedAt: Date(timeIntervalSince1970: 123),
                fileIdentity: try FileOperationJournal.captureIdentity(at: url),
                contentSHA256: fingerprint
                    ? SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() : nil)
        }
        let entries = try names.map { try entry($0, rating: $0 == "M.png" ? .no : .yes, fingerprint: $0 == "Z.png") }
        let saved = await SessionPersistence(backupDirectory: backups).save(
            SessionFile(version: 7, sourcePath: photos.path, scannedAt: Date(), entries: entries,
                        fileIDEncoding: .percentEncodedFileSystemPath),
            for: photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        // Z.png becomes an identical copy: its saved decision is history.
        let z = photos.appendingPathComponent("Z.png")
        try FileManager.default.moveItem(at: z, to: root.appendingPathComponent("Original.png"))
        try bytes.write(to: z)

        let verified = VerifiedOrder()
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: backups),
            sessionContentVerification: { file, proof in
                await verified.append(file.id)
                return try SessionContentVerifier.verify(file, knownProof: proof)
            })
        store.setRawJPEGPairingMode(.together)
        store.openFolder(photos)
        try await wait { if case .ready = store.phase { return true }; return false }
        try await wait { store.sessionContentCheck == .finished }
        let order = await verified.ids
        XCTAssertEqual(order.first, "Z.png", "recovery history is proven first")
        XCTAssertEqual(Array(order.dropFirst()), order.dropFirst().sorted(), "the rest follow exact ID order")
        XCTAssertEqual(Set(order), Set(names))
        XCTAssertEqual(store.automaticallyRestoredSessionFiles, 1)
        _ = await store.saveSessionForTermination()
        _ = await store.waitForPersistenceIdleForTesting()
        store.beginTerminationPreparation()
    }

    // MARK: - Counts from the known decision

    /// Marks, toggle-offs, tile/badge batches, Undo and re-marks over pairs,
    /// cross-folder pairs, HEIF companions, Mixed pairs and scoped selections:
    /// every incremental counter equals a full recount after each step, and
    /// each mark stamps one time on every target file.
    func testBatchDecisionCountersMatchAFullRecountTogetherAndSeparate() throws {
        for separate in [false, true] {
            let root = try disposableRoot()
            let (store, cleanup) = makeStore(countersFixture(root: root, separate: separate), root: root)
            defer { cleanup() }
            store.replaceArchiveFolderIndex(ArchiveFolderIndex(root: root, directories: [], items: store.items))
            _ = store.archiveFolderProgress // Built on first use; then maintained per decision.
            XCTAssertEqual(store.decisionCounterMismatchesForTesting, [])
            var random = Generator(state: separate ? 0x5E9A : 0x70CE)
            let ratings: [Rating] = [.yes, .no, .undecided]
            let count = store.items.count
            for step in 0..<500 {
                let before = store.items.map(\.metadataSnapshots)
                let start = Date()
                var stampsTargets: [Int] = []
                switch random.next(14) {
                case 0, 1, 2:
                    store.setSelection(Set((0..<random.next(count)).map { _ in random.next(count) }))
                    stampsTargets = store.effectiveSelection.sorted()
                    store.rate(ratings[random.next(3)])
                case 3:
                    store.selectAllVisible()
                    stampsTargets = store.effectiveSelection.sorted()
                    store.rate(random.next(2) == 0 ? .yes : .no) // Repeats toggle off.
                case 4:
                    let index = random.next(count)
                    store.setSelection(Set((0..<6).map { _ in random.next(count) }).union([index]))
                    stampsTargets = store.selectedIndices.count > 1 && store.selectedIndices.contains(index)
                        ? store.selectedIndices.sorted() : [index]
                    store.rate(ratings[random.next(2)], at: index)
                case 5:
                    let index = random.next(count)
                    store.setSelection(Set((0..<6).map { _ in random.next(count) }).union([index]))
                    stampsTargets = store.selectedIndices.count > 1 && store.selectedIndices.contains(index)
                        ? store.selectedIndices.sorted() : [index]
                    store.toggleRating(at: index)
                case 6, 7:
                    store.undo()
                case 8:
                    store.selectArchiveFolder(["", "A", "B", "A/C"][random.next(4)])
                case 9:
                    store.setArchiveIncludesDescendants(random.next(2) == 0)
                case 10:
                    store.filter.excludedDecisionStates = [[], [.yes], [.undecided], [.mixed]][random.next(4)]
                    store.flushPendingFilter()
                case 11:
                    store.setSelection([])
                    store.currentIndex = store.visibleIndices.isEmpty ? 0 : store.visibleIndices[random.next(store.visibleIndices.count)]
                    stampsTargets = store.effectiveSelection.sorted()
                    store.rate(ratings[random.next(2)])
                case 12:
                    store.setStarRating(random.next(2) == 0 ? .two : nil)
                default:
                    store.clearAllRatings()
                }
                XCTAssertEqual(store.decisionCounterMismatchesForTesting, [], "step \(step), separate \(separate)")
                // Any target whose files changed got exactly one new stamp, shared by both files.
                for index in stampsTargets where store.items.indices.contains(index)
                    && store.items[index].metadataSnapshots != before[index] {
                    let stamps = Set(store.items[index].metadataSnapshots.map(\.ratedAt))
                    XCTAssertEqual(stamps.count, 1, "step \(step)")
                    XCTAssertTrue(stamps.allSatisfy { $0.map { $0 >= start } ?? false }, "step \(step)")
                }
            }
            // Undo walks every retained step back to the opening state exactly.
            while store.canUndo { store.undo() }
            XCTAssertEqual(store.decisionCounterMismatchesForTesting, [])
        }
    }

    // MARK: - Decision-filter membership

    /// A store that keeps an unchanged projection runs in lockstep with one
    /// that re-projects after every decision (the previous behavior): visible
    /// order, date groups and titles, selection, current item, decisions and
    /// Clean Up availability must match after each step. Covers single and
    /// batch marks, toggle-off, tile and badge batches, Undo, partial and full
    /// selections, pending search, grouping on and off, archive scopes, and
    /// advancing from the old order.
    func testKeptDecisionProjectionMatchesAFullReprojection() throws {
        for advances in [false, true] {
            let root = try disposableRoot()
            let (fast, cleanFast) = makeStore(membershipFixture(root: root), root: root, advances: advances)
            let (reference, cleanReference) = makeStore(membershipFixture(root: root), root: root, advances: advances)
            defer { cleanFast(); cleanReference() }
            reference.reprojectsEveryDecisionForTesting = true
            for store in [fast, reference] {
                store.replaceArchiveFolderIndex(ArchiveFolderIndex(root: root, directories: [], items: store.items))
                store.filter.excludedDecisionStates = [.no]
                store.flushPendingFilter()
            }
            var random = Generator(state: advances ? 0xAD7 : 0x57A7)
            let filters: [Set<PhotoItemRatingState>] = [[.no], [.yes], [.undecided], [.mixed], [.no, .mixed],
                                                        [.yes, .no, .mixed]]
            let ratings: [Rating] = [.yes, .no, .undecided]
            for step in 0..<600 {
                let visible = fast.visibleIndices
                let pick = visible.isEmpty ? 0 : visible[random.next(visible.count)]
                let subset = Set((0..<random.next(12)).compactMap { _ in visible.isEmpty ? nil : visible[random.next(visible.count)] })
                let operation = random.next(16)
                let rating = ratings[random.next(operation < 6 ? 2 : 3)]
                let filter = filters[random.next(filters.count)]
                let flag = random.next(2) == 0
                let folder = ["", "A", "B"][random.next(3)]
                for store in [fast, reference] {
                    switch operation {
                    case 0, 1, 2: store.rate(rating) // Current item or explicit selection.
                    case 3, 4:
                        store.setSelection(subset)
                        store.rate(rating)
                    case 5:
                        store.selectAllVisible()
                        store.rate(rating)
                    case 6: store.rate(rating, at: pick)
                    case 7: store.toggleRating(at: pick)
                    case 8: store.undo()
                    case 9:
                        store.filter.excludedDecisionStates = filter
                        store.flushPendingFilter()
                    case 10: store.filter.searchText = flag ? "" : "R2" // Pending until the next decision.
                    case 11: store.isGroupingEnabled = flag
                    case 12: store.setIndex(pick)
                    case 13: store.setSelection(subset)
                    case 14: store.selectArchiveFolder(folder)
                    default: store.setSelection([])
                    }
                }
                assertSameReview(fast, reference, "step \(step), advances \(advances), operation \(operation)")
            }
            XCTAssertGreaterThan(fast.keptDecisionProjectionsForTesting, 50, "the kept projection must be exercised")
            XCTAssertEqual(reference.keptDecisionProjectionsForTesting, 0)
        }
    }

    /// Unmarked filter + F changes membership: the photo must leave at once.
    func testUnmarkedFilterDecisionStillReprojects() throws {
        let root = try disposableRoot()
        let (store, cleanup) = makeStore(membershipFixture(root: root), root: root, advances: false)
        defer { cleanup() }
        store.filter.excludedDecisionStates = [.yes, .no, .mixed]
        store.flushPendingFilter()
        let unmarked = try XCTUnwrap(store.visibleIndices.first)
        store.setIndex(unmarked)
        let visibleCount = store.visibleIndices.count
        store.rate(.yes)
        XCTAssertEqual(store.keptDecisionProjectionsForTesting, 0)
        XCTAssertNil(store.visiblePosition(ofItem: unmarked))
        XCTAssertEqual(store.visibleIndices.count, visibleCount - 1)
        XCTAssertNotNil(store.visiblePosition(ofItem: store.currentIndex))
        XCTAssertEqual(store.decisionCounterMismatchesForTesting, [])
        // A No → Yes edit under the same filter keeps membership (both hidden).
        store.undo()
        XCTAssertEqual(store.visibleIndices.count, visibleCount)
    }

    /// Paced cue evidence and pending search are projected, not skipped.
    /// A date range resolves whole days in the current calendar. After a
    /// time zone change, a decision must re-project, not keep stale bounds.
    func testTimeZoneChangeUnderADateRangeReprojects() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        let root = try disposableRoot()
        let base = 1_790_000_000.0 // Hourly items across two UTC days.
        let items = (0..<48).map { hour in
            PhotoItem(primaryFile: PhotoFile(
                id: "H\(hour).JPG", url: root.appendingPathComponent("H\(hour).JPG"),
                captureDate: Date(timeIntervalSince1970: base + Double(hour * 3_600)),
                cameraModel: nil, lensModel: nil, fileSize: 1))
        }
        let (store, cleanup) = makeStore(items, root: root)
        defer { cleanup() }
        store.filter.excludedDecisionStates = [.no]
        store.filter.dateEnabled = true
        store.filter.dateMode = .range
        store.filter.dateFrom = Date(timeIntervalSince1970: base + 12 * 3_600)
        store.filter.dateTo = store.filter.dateFrom
        store.applyFilter()
        let utcVisible = store.visibleIndices
        XCTAssertFalse(utcVisible.isEmpty)
        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")! // UTC+14
        var fresh = PreparedSessionIndex()
        fresh.rebuildItems(store.items, sort: store.sort)
        fresh.applyFilter(store.filter, to: store.items, sort: store.sort, isGroupingEnabled: store.isGroupingEnabled)
        XCTAssertNotEqual(fresh.visibleIndices, utcVisible, "the fixture must straddle the shifted day")
        store.setIndex(try XCTUnwrap(utcVisible.first))
        store.rate(.yes) // Undecided → Yes keeps decision-filter membership.
        XCTAssertEqual(store.keptDecisionProjectionsForTesting, 0)
        fresh.applyFilter(store.filter, to: store.items, sort: store.sort, isGroupingEnabled: store.isGroupingEnabled)
        XCTAssertEqual(store.visibleIndices, fresh.visibleIndices)
        // With the calendar unchanged since that projection, the shortcut applies again.
        store.setIndex(try XCTUnwrap(store.visibleIndices.first { store.items[$0].ratingState == .undecided }))
        store.rate(.yes)
        XCTAssertEqual(store.keptDecisionProjectionsForTesting, 1)
    }

    func testPendingCueProjectionAndSearchAreNotSkipped() throws {
        let root = try disposableRoot()
        let (store, cleanup) = makeStore(membershipFixture(root: root), root: root, advances: false)
        defer { cleanup() }
        store.filter.excludedDecisionStates = [.no]
        store.flushPendingFilter()
        store.setIndex(try XCTUnwrap(store.visibleIndices.first { store.items[$0].ratingState == .undecided }))
        store.markQualityCueFilterStaleForTesting()
        store.rate(.yes)
        XCTAssertEqual(store.keptDecisionProjectionsForTesting, 0, "a stale cue projection takes the full path")
        // Search typed just before the decision is applied first, then kept.
        let unsearched = store.visibleIndices.count
        store.filter.searchText = "R2"
        let target = try XCTUnwrap(store.visibleIndices.first { store.items[$0].ratingState == .undecided })
        store.rate(.yes, at: target)
        XCTAssertEqual(store.keptDecisionProjectionsForTesting, 1)
        XCTAssertLessThan(store.visibleIndices.count, unsearched, "the search applied before the decision")
        var fresh = PreparedSessionIndex()
        fresh.rebuildItems(store.items, sort: store.sort)
        fresh.applyFilter(store.filter, to: store.items, sort: store.sort, isGroupingEnabled: store.isGroupingEnabled)
        XCTAssertEqual(store.visibleIndices, fresh.visibleIndices)
    }

    private func assertSameReview(_ fast: SessionStore, _ reference: SessionStore, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fast.visibleIndices, reference.visibleIndices, message, file: file, line: line)
        XCTAssertEqual(fast.visibleGroups.map(\.id), reference.visibleGroups.map(\.id), message, file: file, line: line)
        XCTAssertEqual(fast.visibleGroups.map(\.indices), reference.visibleGroups.map(\.indices), message,
                       file: file, line: line)
        XCTAssertEqual(fast.visibleGroupTitles, reference.visibleGroupTitles, message, file: file, line: line)
        XCTAssertEqual(fast.gridGroups, reference.gridGroups, message, file: file, line: line)
        XCTAssertEqual(fast.selectedIndices, reference.selectedIndices, message, file: file, line: line)
        XCTAssertEqual(fast.currentIndex, reference.currentIndex, message, file: file, line: line)
        XCTAssertEqual(fast.items.map(\.ratingState), reference.items.map(\.ratingState), message, file: file, line: line)
        XCTAssertEqual(fast.decisionCounterMismatchesForTesting, [], message, file: file, line: line)
        for scope in [CleanUpScope.all, .filtered, .selected] {
            fast.cleanUpScope = scope
            reference.cleanUpScope = scope
            for mode in [CleanUpMode.selection, .trashNo, .keepOnlyYes, .pairedJPEGs, .pairedRAWs] {
                XCTAssertEqual(fast.hasCleanUpTargets(for: mode), reference.hasCleanUpTargets(for: mode),
                               "\(message), \(scope), \(mode)", file: file, line: line)
            }
        }
    }

    /// Four capture days, pairs, singles and Mixed pairs in two folders.
    private func membershipFixture(root: URL) -> [PhotoItem] {
        let ratings: [Rating] = [.yes, .no, .undecided]
        func file(_ id: String, _ rating: Rating, day: Int, offset: Int) -> PhotoFile {
            PhotoFile(id: id, url: root.appendingPathComponent(id),
                      captureDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(day * 86_400 + offset * 60)),
                      cameraModel: nil, lensModel: nil, fileSize: 1, rating: rating)
        }
        return (0..<48).map { i in
            let folder = i.isMultiple(of: 2) ? "A" : "B"
            let name = i.isMultiple(of: 3) ? "R\(i)" : "P\(i)"
            let rating = ratings[i % 3]
            let primary = file("\(folder)/\(name).NEF", rating, day: i % 4, offset: i)
            guard !i.isMultiple(of: 5) else { return PhotoItem(primaryFile: primary) }
            return PhotoItem(primaryFile: primary, pairedFile: file("\(folder)/\(name).JPG",
                                                                 i.isMultiple(of: 7) ? ratings[(i + 1) % 3] : rating,
                                                                 day: i % 4, offset: i))
        }
    }

    /// Ten physical families per subfolder pattern; ratings start varied.
    private func countersFixture(root: URL, separate: Bool) -> [PhotoItem] {
        let ratings: [Rating] = [.yes, .no, .undecided]
        func file(_ id: String, _ rating: Rating) -> PhotoFile {
            PhotoFile(id: id, url: root.appendingPathComponent(id), captureDate: nil,
                      cameraModel: nil, lensModel: nil, fileSize: 1, rating: rating,
                      ratedAt: rating == .undecided ? nil : Date(timeIntervalSince1970: 1_000))
        }
        var items: [PhotoItem] = []
        for i in 0..<12 {
            let rating = ratings[i % 3]
            let other = ratings[(i + i / 3) % 3] // Some pairs start Mixed.
            let families: [(String, String?)] = [
                ("A/X\(i).NEF", "B/X\(i).JPG"),       // Cross-folder pair.
                ("A/C/Y\(i).NEF", "A/C/Y\(i).JPG"),   // Same-folder pair.
                ("A/H\(i).NEF", "A/H\(i).HEIC"),      // Paired for review, never a JPEG target.
                ("B/S\(i).JPG", nil),
                ("R\(i).JPG", nil),
            ]
            for (primary, paired) in families {
                if let paired {
                    if separate {
                        items.append(PhotoItem(primaryFile: file(primary, rating)))
                        items.append(PhotoItem(primaryFile: file(paired, other)))
                    } else {
                        items.append(PhotoItem(primaryFile: file(primary, rating), pairedFile: file(paired, other)))
                    }
                } else {
                    items.append(PhotoItem(primaryFile: file(primary, rating)))
                }
            }
        }
        return items
    }

    private func makeStore(_ items: [PhotoItem], root: URL, advances: Bool = false) -> (SessionStore, () -> Void) {
        let name = "DecisionPathEquivalence.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(advances, forKey: ReviewPreferences.Keys.advancesAfterDecision)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            saveTrailingDelay: 60, saveMaximumDelay: 60, reviewDefaults: defaults)
        store.items = items
        store.rebuildDerivedDataForTesting(sourceFolder: root)
        store.phase = .ready
        store.pauseQualityCueAnalysis()
        return (store, {
            store.beginTerminationPreparation()
            defaults.removePersistentDomain(forName: name)
        })
    }

    private func disposableRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-DecisionPath-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: - Helpers

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func next(_ bound: Int) -> Int { Int(next() >> 33) % bound }
    }
}

private actor VerifiedOrder {
    private(set) var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
}
