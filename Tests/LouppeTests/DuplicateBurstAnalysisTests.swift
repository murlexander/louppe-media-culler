import Foundation
import XCTest
@testable import Louppe

final class DuplicateBurstAnalysisTests: XCTestCase {
    @MainActor
    func testGroupedReviewCacheFollowsFiltersSensitivityAndFreshAnalysis() async throws {
        let store = SessionStore(reviewDefaults: makeDefaults())
        let start = Date(timeIntervalSince1970: 1_000)
        store.items = [
            item(id: "A.JPG", captureDate: start),
            item(id: "B.JPG", captureDate: start.addingTimeInterval(1)),
            item(id: "C.PNG", captureDate: start.addingTimeInterval(5)),
        ]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.setBurstGroupingInterval(2)
        store.enterGroupedReview(.captureBursts)
        try await waitForAnalysis(store)
        XCTAssertEqual(store.visibleIndices, [0, 1])

        store.setBurstGroupingInterval(10)
        try await waitForAnalysis(store)
        XCTAssertEqual(store.visibleIndices, [0, 1, 2])
        store.filter.excludedTypes = ["PNG"]
        XCTAssertEqual(store.visibleIndices, [0, 1])
        XCTAssertEqual(store.visibleGroups.first?.title,
                       "Capture burst · 2 items · inferred dates (2 of 3 shown)")
        store.filter.excludedTypes = []
        XCTAssertEqual(store.visibleIndices, [0, 1, 2])

        // A refreshed analysis must invalidate membership even when the user
        // keeps the same review mode and sensitivity selected.
        store.items = [
            item(id: "A.JPG", captureDate: start),
            item(id: "B.JPG", captureDate: start.addingTimeInterval(20)),
            item(id: "C.PNG", captureDate: start.addingTimeInterval(21)),
        ]
        store.rebuildDerivedDataForTesting()
        store.analyzeDuplicateAndBurstGroups()
        try await waitForAnalysis(store)
        XCTAssertEqual(store.visibleIndices, [1, 2])
        store.exitGroupedReview()
        XCTAssertEqual(store.visibleIndices, [0, 1, 2])
    }

    @MainActor
    func testClearingPendingBurstsCannotRestoreTheFilter() async throws {
        let store = SessionStore(reviewDefaults: makeDefaults())
        store.items = [item(id: "A.JPG", captureDate: Date()), item(id: "B.JPG", captureDate: Date())]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.enterGroupedReview(.captureBursts)
        store.exitGroupedReview()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.groupedReviewMode, .off)
        XCTAssertFalse(store.isDuplicateBurstAnalysisRunning)
        XCTAssertEqual(store.visibleIndices, [0, 1])
    }

    @MainActor
    func testNavigationDuringBurstRequestDoesNotStealCurrentPhoto() async throws {
        let store = SessionStore(reviewDefaults: makeDefaults())
        let date = Date(timeIntervalSince1970: 100)
        store.items = [item(id: "A.JPG", captureDate: date), item(id: "B.JPG", captureDate: date),
                       item(id: "C.JPG", captureDate: date.addingTimeInterval(100))]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.enterGroupedReview(.captureBursts)
        store.setIndex(2)
        try await waitForAnalysis(store)
        XCTAssertEqual(store.currentIndex, 2)
        XCTAssertEqual(store.groupedReviewMode, .off)
        XCTAssertEqual(store.visibleIndices, [0, 1, 2])
        // A later explicit request reuses the ready metadata.
        store.enterGroupedReview(.captureBursts)
        XCTAssertEqual(store.groupedReviewMode, .captureBursts)
        XCTAssertEqual(store.visibleIndices, [0, 1])
    }

    func testNewestFirstOrdersBurstsAndTheirMembers() throws {
        let date = Date(timeIntervalSince1970: 100)
        let items = [item(id: "A.JPG", captureDate: date),
                     item(id: "B.JPG", captureDate: date.addingTimeInterval(1)),
                     item(id: "C.JPG", captureDate: date.addingTimeInterval(10)),
                     item(id: "D.JPG", captureDate: date.addingTimeInterval(11))]
        let sort = PhotoSort(key: .captureDate, ascending: false)
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: sort)
        index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true)
        index.applyGroupedReview([
            .init(id: "first", mode: .captureBursts, itemIDs: ["A.JPG", "B.JPG"]),
            .init(id: "second", mode: .captureBursts, itemIDs: ["C.JPG", "D.JPG"])
        ], to: items)
        XCTAssertEqual(index.visibleIndices, [3, 2, 1, 0])
        XCTAssertEqual(index.visibleGroups.map(\.indices), [[3, 2], [1, 0]])
    }

    @MainActor
    func testLatestBurstIntervalWinsAndCancelKeepsCompletedMembership() async throws {
        let store = SessionStore(reviewDefaults: makeDefaults())
        let start = Date(timeIntervalSince1970: 100)
        store.items = (0..<1000).map { i in
            item(id: String(format: "%04d.JPG", i),
                 captureDate: start.addingTimeInterval(Double(i/2)*4 + Double(i%2)*0.25))
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.enterGroupedReview(.captureBursts)
        try await waitForAnalysis(store)
        XCTAssertEqual(store.visibleGroups.count, 500)
        store.setBurstGroupingInterval(10)
        store.setBurstGroupingInterval(0.5)
        try await waitForAnalysis(store)
        XCTAssertEqual(store.burstGroupingInterval, 0.5)
        XCTAssertEqual(store.visibleGroups.count, 500)
        store.setBurstGroupingInterval(10)
        store.cancelDuplicateBurstAnalysis()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.burstGroupingInterval, 0.5)
        XCTAssertEqual(store.visibleGroups.count, 500)
        XCTAssertEqual(store.duplicateBurstAnalysisState, .ready)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "Louppe-BurstTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testBurstIntervalPersistsWithFractionalValuesAndRejectsNonfiniteInput() {
        let defaults = makeDefaults()
        let store = SessionStore(reviewDefaults: defaults)
        XCTAssertEqual(store.burstGroupingInterval, 2)
        store.setBurstGroupingInterval(1.25)
        XCTAssertEqual(SessionStore(reviewDefaults: defaults).burstGroupingInterval, 1.25)
        store.setBurstGroupingInterval(.nan)
        store.setBurstGroupingInterval(.infinity)
        XCTAssertEqual(store.burstGroupingInterval, 1.25)
        store.setBurstGroupingInterval(0)
        XCTAssertEqual(store.burstGroupingInterval, 0.5)
        store.setBurstGroupingInterval(100)
        XCTAssertEqual(SessionStore(reviewDefaults: defaults).burstGroupingInterval, 10)
    }

    func testBurstIntervalDraftHandlesDecimalsLocalesAndInvalidInput() {
        XCTAssertEqual(CaptureBurstIntervalInput.parse("1.25", locale: Locale(identifier: "en_US")), 1.25)
        XCTAssertEqual(CaptureBurstIntervalInput.parse("1,25", locale: Locale(identifier: "es_ES")), 1.25)
        for text in ["", "0", "0.25", "11", "NaN", "inf", "1.2.5", "1,000", "1s"] {
            XCTAssertNil(CaptureBurstIntervalInput.parse(text, locale: Locale(identifier: "en_US")), text)
        }
        let value = 1.234567891
        let locale = Locale(identifier: "es_ES")
        XCTAssertEqual(CaptureBurstIntervalInput.parse(CaptureBurstIntervalInput.format(value, locale: locale), locale: locale), value)
    }

    @MainActor
    private func waitForAnalysis(_ store: SessionStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isDuplicateBurstAnalysisRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.duplicateBurstAnalysisState, .ready)
    }

    func testLargeNearMatchingFamiliesStayOneGroup() {
        let fingerprints = (0..<4_000).map { index in
            DuplicateBurstAnalysis.VisualFingerprint(
                itemID: String(format: "%05d", index),
                hash: index < 2_000 ? 0 : 1
            )
        }
        let result = DuplicateBurstAnalysis.Result(
            exactDuplicateItemSets: [], visualFingerprints: fingerprints,
            burstCandidates: [], analyzedExactFileCount: 0,
            analyzedVisualPhotoCount: fingerprints.count
        )
        let start = Date()
        let groups = result.groups(for: .likelySimilarPhotos, visualDistance: 1, burstInterval: 2)
        print("Large similar families: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.itemIDs, fingerprints.map(\.itemID))
    }

    func testFilteredGroupTitleCountsOnlyVisibleMembers() {
        let items = [item(id: "A.JPG"), item(id: "B.JPG"), item(id: "C.PNG")]
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: PhotoSort())
        var filter = PhotoFilter()
        filter.excludedTypes = ["PNG"]
        index.applyFilter(filter, to: items, sort: PhotoSort(), isGroupingEnabled: true)
        index.applyGroupedReview([
            .init(id: "group", mode: .exactDuplicates, itemIDs: items.map(\.id))
        ], to: items)
        XCTAssertEqual(index.visibleGroups.first?.indices, [0, 1])
        XCTAssertEqual(index.visibleGroups.first?.title,
                       "Exact duplicates · 2 items · matching file fingerprints")
    }

    func testExactDuplicateFilesMergeRAWJPEGProjectionIntoOneReviewGroup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeDuplicateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawA = directory.appendingPathComponent("A.RAW")
        let rawB = directory.appendingPathComponent("B.RAW")
        let jpegA = directory.appendingPathComponent("A.JPG")
        let jpegB = directory.appendingPathComponent("B.JPG")
        try Data("same raw bytes".utf8).write(to: rawA)
        try Data("same raw bytes".utf8).write(to: rawB)
        try Data("same jpeg bytes".utf8).write(to: jpegA)
        try Data("same jpeg bytes".utf8).write(to: jpegB)

        let result = try DuplicateBurstAnalysis.analyze([
            input(
                id: "A.RAW",
                exactFiles: [rawA, jpegA].map {
                    DuplicateBurstAnalysis.ExactFile(
                        reviewItemID: "A.RAW",
                        url: $0,
                        fileSize: Int64((try? Data(contentsOf: $0).count) ?? 0)
                    )
                }
            ),
            input(
                id: "B.RAW",
                exactFiles: [rawB, jpegB].map {
                    DuplicateBurstAnalysis.ExactFile(
                        reviewItemID: "B.RAW",
                        url: $0,
                        fileSize: Int64((try? Data(contentsOf: $0).count) ?? 0)
                    )
                }
            ),
        ])

        let groups = result.groups(
            for: .exactDuplicates,
            visualDistance: 8,
            burstInterval: 2
        )
        XCTAssertEqual(groups.map(\.itemIDs), [["A.RAW", "B.RAW"]])
        XCTAssertEqual(
            groups.first?.title,
            "Exact duplicates · 2 items · matching file fingerprints"
        )
    }

    func testVisualSensitivityOnlyGroupsNearbyPerceptualHashes() {
        let result = DuplicateBurstAnalysis.Result(
            exactDuplicateItemSets: [],
            visualFingerprints: [
                .init(itemID: "A", hash: 0x1111_0000_0000_0000),
                .init(itemID: "B", hash: 0x1111_0000_0000_0003),
                .init(itemID: "C", hash: 0x2222_0000_0000_0000),
            ],
            burstCandidates: [],
            analyzedExactFileCount: 0,
            analyzedVisualPhotoCount: 3
        )

        XCTAssertTrue(result.groups(
            for: .likelySimilarPhotos,
            visualDistance: 1,
            burstInterval: 2
        ).isEmpty)
        XCTAssertEqual(
            result.groups(
                for: .likelySimilarPhotos,
                visualDistance: 2,
                burstInterval: 2
            ).map(\.itemIDs),
            [["A", "B"]]
        )
    }

    func testBurstGroupsUseConsecutiveCaptureTimeGap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let result = DuplicateBurstAnalysis.Result(
            exactDuplicateItemSets: [],
            visualFingerprints: [],
            burstCandidates: [
                .init(itemID: "A", captureDate: start),
                .init(itemID: "B", captureDate: start.addingTimeInterval(1.8)),
                .init(itemID: "C", captureDate: start.addingTimeInterval(5)),
                .init(itemID: "D", captureDate: start.addingTimeInterval(6.9)),
            ],
            analyzedExactFileCount: 0,
            analyzedVisualPhotoCount: 0
        )

        XCTAssertEqual(
            result.groups(
                for: .captureBursts,
                visualDistance: 8,
                burstInterval: 2
            ).map(\.itemIDs),
            [["A", "B"], ["C", "D"]]
        )
        XCTAssertTrue(result.groups(
            for: .captureBursts,
            visualDistance: 8,
            burstInterval: 1
        ).isEmpty)
    }

    func testPreparedIndexKeepsOnlyFilteredGroupMembersAndRestoresNoDuplicates() {
        let items = [
            item(id: "A.JPG"),
            item(id: "B.JPG"),
            item(id: "C.PNG"),
        ]
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: PhotoSort())
        var filter = PhotoFilter()
        filter.excludedTypes = ["PNG"]
        index.applyFilter(filter, to: items, sort: PhotoSort(), isGroupingEnabled: true)
        index.applyGroupedReview([
            .init(
                id: "exact-A",
                mode: .exactDuplicates,
                itemIDs: ["A.JPG", "C.PNG"]
            ),
            .init(
                id: "exact-overlap",
                mode: .exactDuplicates,
                itemIDs: ["A.JPG", "B.JPG"]
            ),
        ], to: items)

        XCTAssertEqual(index.visibleIndices, [0, 1])
        XCTAssertEqual(index.visibleGroups.count, 1)
        XCTAssertEqual(index.visibleGroups.first?.title, "Exact duplicates · 2 items · matching file fingerprints")
    }

    func testMetadataOnlyBurstRequestNeverHashesOrDecodesAndCannotSatisfyOtherModes() throws {
        let probe = BurstFileAccessProbe()
        let start = Date(timeIntervalSince1970: 1_000)
        // Equal sizes force the full-analysis hash path. Invalid paths would
        // otherwise hide accidental reads behind ordinary failure fallbacks.
        let inputs = ["A", "B"].enumerated().map { index, id in
            let url = URL(fileURLWithPath: "/nonexistent/burst-sentinel/\(id).JPG")
            return DuplicateBurstAnalysis.Input(
                id: id, mediaKind: .photo,
                captureDate: start.addingTimeInterval(Double(index)),
                exactFiles: [.init(reviewItemID: id, url: url, fileSize: 1)],
                visualFiles: [.init(url: url)]
            )
        }
        let access = DuplicateBurstAnalysis.FileAccess(
            exactDigest: { _ in probe.recordHash(); return "sentinel" },
            visualHash: { _ in probe.recordDecode(); return 0 }
        )
        let result = try DuplicateBurstAnalysis.analyze(
            inputs, mode: .captureBursts, fileAccess: access
        )
        XCTAssertEqual(probe.hashCount, 0)
        XCTAssertEqual(probe.decodeCount, 0)
        XCTAssertEqual(result.analyzedExactFileCount, 0)
        XCTAssertEqual(result.analyzedVisualPhotoCount, 0)
        XCTAssertTrue(result.supports(.captureBursts))
        XCTAssertFalse(result.supports(.exactDuplicates))
        XCTAssertFalse(result.supports(.likelySimilarPhotos))
        XCTAssertEqual(result.groups(
            for: .captureBursts, visualDistance: 8, burstInterval: 2
        ).map(\.itemIDs), [["A", "B"]])
        _ = try DuplicateBurstAnalysis.analyze(inputs, fileAccess: access)
        XCTAssertEqual(probe.hashCount, 2, "the sentinel must detect the real hash path")
        XCTAssertEqual(probe.decodeCount, 2, "the sentinel must detect the real preview path")
    }

    func testCaptureOrderKeepsSubsecondsAndUsesStableIdentityOnlyForTrueTies() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let result = try DuplicateBurstAnalysis.analyze([
            burstInput(id: "A", date: start.addingTimeInterval(0.7)),
            burstInput(id: "Z", date: start.addingTimeInterval(0.1)),
            burstInput(id: "B", date: start.addingTimeInterval(0.7)),
        ], mode: .captureBursts)
        XCTAssertEqual(result.groups(
            for: .captureBursts, visualDistance: 8, burstInterval: 2
        ).map(\.itemIDs), [["Z", "A", "B"]])
    }

    func testAdjacentGapIsInclusiveAndDoesNotIdentifySeparateShutterPresses() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let result = try DuplicateBurstAnalysis.analyze([
            burstInput(id: "first-press-1", date: start),
            burstInput(id: "first-press-2", date: start.addingTimeInterval(1)),
            burstInput(id: "second-press", date: start.addingTimeInterval(3)),
            burstInput(id: "third-press-1", date: start.addingTimeInterval(5.01)),
            burstInput(id: "third-press-2", date: start.addingTimeInterval(6)),
        ], mode: .captureBursts)
        XCTAssertEqual(result.groups(
            for: .captureBursts, visualDistance: 8, burstInterval: 2
        ).map(\.itemIDs), [
            ["first-press-1", "first-press-2", "second-press"],
            ["third-press-1", "third-press-2"],
        ])
    }

    func testMissingDatesAndNonPhotosAreExcludedAndImportedDatesStayInferred() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let inputs = [
            burstInput(id: "camera-a", date: start, source: .exifOriginal),
            burstInput(id: "camera-b", date: start.addingTimeInterval(0.25), source: .exifOriginal),
            burstInput(id: "import-date", date: start.addingTimeInterval(0.5), source: .fileCreation),
            burstInput(id: "missing", date: nil),
            burstInput(id: "movie", date: start, mediaKind: .video),
        ]
        let result = try DuplicateBurstAnalysis.analyze(inputs, mode: .captureBursts)
        let groups = result.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2)
        XCTAssertEqual(result.burstCandidates.count, 3)
        XCTAssertEqual(groups.map(\.itemIDs), [["camera-a", "camera-b", "import-date"]],
                       "metadata gaps do not partition cameras or identify shutter presses")
        XCTAssertEqual(groups.first?.captureDateNote, "inferred dates")
    }

    func testCaptureBurstGroupingMeasurement() throws {
        for count in [1_000, 10_000, 100_000] {
            let start = Date(timeIntervalSince1970: 1_000)
            let inputs = (0..<count).reversed().map { index in
                burstInput(id: String(format: "%06d", index),
                           date: start.addingTimeInterval(Double(index / 2) * 4 + Double(index % 2) * 0.25),
                           source: .exifOriginal)
            }
            let analysisStart = Date()
            let result = try DuplicateBurstAnalysis.analyze(inputs, mode: .captureBursts)
            let analysisTime = Date().timeIntervalSince(analysisStart)
            let groupStart = Date()
            let groups = result.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2)
            let groupTime = Date().timeIntervalSince(groupStart)
            let sensitivityStart = Date()
            let updated = result.groups(for: .captureBursts, visualDistance: 8, burstInterval: 0.5)
            let sensitivityTime = Date().timeIntervalSince(sensitivityStart)
            print("Capture groups \(count): metadata \(analysisTime)s; initial \(groupTime)s; sensitivity \(sensitivityTime)s")
            XCTAssertEqual(groups.count, count / 2)
            XCTAssertEqual(updated.count, count / 2)
        }
    }

    private func burstInput(
        id: String,
        date: Date?,
        source: CaptureDateEvidence.Source = .unspecified,
        mediaKind: MediaKind = .photo
    ) -> DuplicateBurstAnalysis.Input {
        .init(id: id, mediaKind: mediaKind, captureDate: date,
              captureDateEvidence: date.map { CaptureDateEvidence(date: $0, source: source) },
              exactFiles: [], visualFiles: [])
    }

    private func input(
        id: String,
        exactFiles: [DuplicateBurstAnalysis.ExactFile]
    ) -> DuplicateBurstAnalysis.Input {
        DuplicateBurstAnalysis.Input(
            id: id,
            mediaKind: .photo,
            captureDate: nil,
            exactFiles: exactFiles,
            visualFiles: []
        )
    }

    private func item(id: String, captureDate: Date? = nil) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: URL(fileURLWithPath: "/tmp/\(id)"),
            pairedURL: nil,
            captureDate: captureDate,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
    }
}

private final class BurstFileAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes = 0
    private var decodes = 0
    var hashCount: Int { lock.withLock { hashes } }
    var decodeCount: Int { lock.withLock { decodes } }
    func recordHash() { lock.withLock { hashes += 1 } }
    func recordDecode() { lock.withLock { decodes += 1 } }
}
