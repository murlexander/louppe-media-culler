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

    private func makeStore(_ items: [PhotoItem], root: URL) -> (SessionStore, () -> Void) {
        let name = "DecisionPathEquivalence.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
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
