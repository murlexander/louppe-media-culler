import Foundation
import XCTest
@testable import Louppe

/// Opt-in measurements: fixtures and correctness checks remain outside timing.
/// These are in-memory CPU experiments, not removable-volume acceptance tests.
@MainActor
final class LouppeSpeedPersistenceTests: XCTestCase {
    func testSnapshotCaptureAndDetachedConstruction() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "persistence-snapshot")
        for count in SpeedBenchmark.sizes {
            let items = (0..<count).map { makeItem($0) }
            let retained = [
                SessionEntry(filename: items[0].id, pairedFilename: nil,
                             rating: Rating.no.rawValue, ratedAt: nil),
                SessionEntry(filename: "MISSING.JPG", pairedFilename: nil,
                             rating: Rating.no.rawValue, ratedAt: nil)
            ]
            var latest = capture(items, retained: retained)
            try report.measure(name: "snapshot.main-capture.unpaired", count: count) {
                latest = capture(items, retained: retained)
            }
            XCTAssertEqual(latest.files.count, count)
            let frozen = latest
            items[0].primaryFile.setRating(.no, ratedAt: Date(timeIntervalSince1970: 999))
            var built = frozen.makeSession()
            try await report.measureAsync(name: "snapshot.detached-entry-build.unpaired", count: count) {
                built = await Task.detached(priority: .utility) { frozen.makeSession() }.value
            }
            XCTAssertEqual(built.entries.count, count + 1)
            XCTAssertEqual(built.entries[0].rating, Rating.yes.rawValue,
                           "Detached construction must consume frozen metadata.")
            XCTAssertEqual(built.entries[0].fileIdentity, items[0].primaryFile.scannedIdentity)
            XCTAssertEqual(built.entries[0].organizationOriginFolderPathBytes, Data("Original".utf8))
            XCTAssertEqual(built.entries.filter { $0.filename == items[0].id }.count, 1)
            XCTAssertEqual(built.entries.last?.filename, "MISSING.JPG")
        }
        try report.finish()
    }

    func testSnapshotJSONFormattingHypothesis() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "persistence-json-format")
        for count in SpeedBenchmark.sizes {
            let entries = (0..<count).map { index in
                SessionEntry(
                    filename: "Album/FRAME_\(index).JPG", pairedFilename: nil,
                    rating: index.isMultiple(of: 2) ? Rating.yes.rawValue : Rating.no.rawValue,
                    ratedAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                    stars: .four, starsChangedAt: Date(timeIntervalSince1970: 1_001),
                    colorLabel: .purple, colorChangedAt: Date(timeIntervalSince1970: 1_002),
                    fileIdentity: identity(index),
                    contentSHA256: String(repeating: "ab", count: 32),
                    organizationOriginFolderPathBytes: Data("Original".utf8)
                )
            }
            let session = SessionFile(
                version: SessionConstants.currentSchemaVersion, sourcePath: "/private/tmp/LouppeSpeed",
                scannedAt: Date(timeIntervalSince1970: 2_000), entries: entries,
                fileIDEncoding: .percentEncodedFileSystemPath, snapshotGeneration: 8,
                recoveryEntries: [SessionRecoveryEntry(entry: entries[0])]
            )
            let canonicalEncoder = makeEncoder(format: [.sortedKeys])
            let canonical = try canonicalEncoder.encode(session)
            var byteCounts: [String: Int] = [:]
            let variants: [(String, JSONEncoder.OutputFormatting)] = [
                ("pretty-sorted", [.prettyPrinted, .sortedKeys]),
                ("compact-sorted", [.sortedKeys]),
                ("compact", [])
            ]
            for (name, formatting) in variants {
                let encoder = makeEncoder(format: formatting)
                var encoded = Data()
                try report.measure(name: "json.encode.\(name)", count: count) {
                    encoded = try encoder.encode(session)
                }
                byteCounts[name] = encoded.count
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(SessionFile.self, from: encoded)
                XCTAssertEqual(try canonicalEncoder.encode(decoded), canonical,
                               "Formatting must preserve every persisted field and its order.")
                XCTAssertEqual(decoded.entries.count, count)
                XCTAssertEqual(decoded.recoveryEntries?.first?.id, session.recoveryEntries?.first?.id)
            }
            var production = Data()
            try report.measure(name: "json.encode.production-compact-sorted", count: count) {
                production = try SessionPersistence.encodeSnapshot(session)
            }
            XCTAssertEqual(production, canonical)
            let prettyBytes = byteCounts["pretty-sorted"]!
            let compactSortedBytes = byteCounts["compact-sorted"]!
            let compactBytes = byteCounts["compact"]!
            print("SPEED_JSON_BYTES count=\(count) pretty=\(prettyBytes) compactSorted=\(compactSortedBytes) compact=\(compactBytes)")
        }
        try report.finish()
    }

    func testCompletedGroupConstructionDistributions() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "group-construction")
        for count in SpeedBenchmark.sizes {
            let ids = (0..<count).map { String(format: "%08d", $0) }
            let exactSets = stride(from: 0, to: count - 1, by: 2).map { [ids[$0], ids[$0 + 1]] }
            let exact = DuplicateBurstAnalysis.Result(
                exactDuplicateItemSets: exactSets, visualFingerprints: [], burstCandidates: [],
                analyzedExactFileCount: count, analyzedVisualPhotoCount: 0
            )
            var groups: [DuplicateBurstAnalysis.Group] = []
            try report.measure(name: "groups.exact.pairs", count: count) {
                groups = exact.groups(for: .exactDuplicates, visualDistance: 8, burstInterval: 2)
            }
            XCTAssertEqual(groups.map(\.itemIDs), exactSets)
            try report.measure(name: "groups.exact.pairs.production-cancellable", count: count) {
                groups = try exact.groupsCancellable(for: .exactDuplicates, visualDistance: 8, burstInterval: 2)
            }
            XCTAssertEqual(groups.map(\.itemIDs), exactSets)
            for distribution in ["equal", "paired-random", "random"] {
                let fingerprints = ids.enumerated().map { index, id in
                    DuplicateBurstAnalysis.VisualFingerprint(
                        itemID: id,
                        hash: distribution == "equal" ? 0 : mixedHash(UInt64(distribution == "paired-random" ? index / 2 : index))
                    )
                }
                let visual = DuplicateBurstAnalysis.Result(
                    exactDuplicateItemSets: [], visualFingerprints: fingerprints, burstCandidates: [],
                    analyzedExactFileCount: 0, analyzedVisualPhotoCount: count
                )
                try report.measure(name: "groups.similar.\(distribution)", count: count) {
                    groups = visual.groups(for: .likelySimilarPhotos, visualDistance: 8, burstInterval: 2)
                }
                let referenceGroups = groups
                try report.measure(name: "groups.similar.\(distribution).production-cancellable", count: count) {
                    groups = try visual.groupsCancellable(for: .likelySimilarPhotos, visualDistance: 8, burstInterval: 2)
                }
                XCTAssertEqual(groups, referenceGroups)
                let groupedIDs = groups.flatMap(\.itemIDs)
                XCTAssertEqual(Set(groupedIDs).count, groupedIDs.count,
                               "A displayed item must never appear in two groups.")
                XCTAssertTrue(Set(groupedIDs).isSubset(of: Set(ids)))
                XCTAssertTrue(groups.allSatisfy { $0.itemIDs.count >= 2 })
                if distribution == "equal" {
                    XCTAssertEqual(groups.count, 1)
                    XCTAssertEqual(groups[0].itemIDs, ids)
                } else if distribution == "paired-random" {
                    XCTAssertEqual(Set(groupedIDs), Set(ids.prefix(count - count % 2)),
                                   "Exact hash families must survive the bounded near-match search.")
                }
            }
        }
        try report.finish()
    }

    /// Mirrors the production snapshot map to isolate needless burst-only
    /// exact/visual arrays. This is an allocation hypothesis, not a UI timing.
    func testBurstInputConstructionHypothesis() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "burst-input-allocation")
        for count in SpeedBenchmark.sizes {
            let items = (0..<count).map { makeItem($0) }
            var full: [DuplicateBurstAnalysis.Input] = []
            var metadataOnly: [DuplicateBurstAnalysis.Input] = []
            try report.measure(name: "burst.input.full-production-shape", count: count) {
                full = items.map { item in
                    let files = item.individualFiles
                    return DuplicateBurstAnalysis.Input(
                        id: item.id, mediaKind: item.mediaKind, captureDate: item.captureDate,
                        captureDateEvidence: item.captureDateEvidence,
                        exactFiles: files.map { .init(reviewItemID: item.id, url: $0.url, fileSize: $0.fileSize,
                                                     expectedIdentity: $0.scannedIdentity) },
                        visualFiles: item.mediaKind == .photo && item.isSupported
                            ? files.map { .init(url: $0.url, expectedIdentity: $0.scannedIdentity) } : []
                    )
                }
            }
            try report.measure(name: "burst.input.metadata-only-hypothesis", count: count) {
                metadataOnly = items.map { item in
                    .init(id: item.id, mediaKind: item.mediaKind, captureDate: item.captureDate,
                          captureDateEvidence: item.captureDateEvidence, exactFiles: [], visualFiles: [])
                }
            }
            var production: [DuplicateBurstAnalysis.Input] = []
            try report.measure(name: "burst.input.metadata-only-production", count: count) {
                production = DuplicateBurstAnalysis.inputs(from: items, mode: .captureBursts)
            }
            XCTAssertTrue(production.allSatisfy { $0.exactFiles.isEmpty && $0.visualFiles.isEmpty })
            let productionResult = try DuplicateBurstAnalysis.analyze(production, mode: .captureBursts)
            let fullResult = try DuplicateBurstAnalysis.analyze(full, mode: .captureBursts)
            XCTAssertEqual(productionResult.burstCandidates, fullResult.burstCandidates)
            let lightResult = try DuplicateBurstAnalysis.analyze(metadataOnly, mode: .captureBursts)
            XCTAssertEqual(fullResult.burstCandidates, lightResult.burstCandidates)
            XCTAssertEqual(fullResult.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2),
                           lightResult.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2))
            XCTAssertEqual(lightResult.analyzedExactFileCount, 0)
            XCTAssertEqual(lightResult.analyzedVisualPhotoCount, 0)
            XCTAssertFalse(lightResult.supports(.likelySimilarPhotos))
        }
        try report.finish()
    }

    private func capture(_ items: [PhotoItem], retained: [SessionEntry]) -> SessionSnapshotCapture {
        SessionSnapshotCapture(sourcePath: "/private/tmp/LouppeSpeed", items: items,
                               retainedEntries: retained,
                               originPaths: [items[0].id: Data("Original".utf8)])
    }

    private func makeEncoder(format: JSONEncoder.OutputFormatting) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = format
        return encoder
    }

    private func makeItem(_ index: Int) -> PhotoItem {
        let id = "FRAME_\(index).JPG"
        let file = PhotoFile(
            id: id, url: URL(fileURLWithPath: "/private/tmp/LouppeSpeed/\(id)"),
            captureDate: Date(timeIntervalSince1970: 1_000 + Double(index / 2) * 4 + Double(index % 2) * 0.25),
            cameraModel: "Synthetic Camera", lensModel: "Synthetic Lens", fileSize: 4_000_000,
            scannedIdentity: identity(index), rating: .yes, ratedAt: Date(timeIntervalSince1970: 123),
            starRating: .four, colorLabel: .purple
        )
        return PhotoItem(primaryFile: file)
    }

    private func identity(_ index: Int) -> FileOperationJournal.FileIdentity {
        .init(volumeRootPath: "/", volumeUUIDString: "11111111-2222-3333-4444-555555555555",
              systemNumber: 1, fileNumber: UInt64(index + 1), logicalSize: 4_000_000,
              modificationTime: .init(seconds: 1_000, nanoseconds: 123),
              statusChangeTime: .init(seconds: 1_001, nanoseconds: 456),
              birthTime: .init(seconds: 999, nanoseconds: 789))
    }

    private func mixedHash(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
