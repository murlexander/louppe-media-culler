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
