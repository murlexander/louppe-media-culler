import Foundation
import XCTest
@testable import Louppe

/// Exercise the session's observable filtering contract. Expected membership
/// comes from deliberately distinct fixture conditions, not the cue cache.
@MainActor
final class QualityCueFilterProjectionTests: XCTestCase {
    func testPreparedIndexTreatsNoSelectedCueAsNeutralEvenWhenMatchesAreSupplied() {
        let items = [photo("Z.JPG", order: 0, rating: .yes),
                     photo("A.JPG", order: 1, rating: .yes), photo("M.JPG", order: 2, rating: .no)]
        let sort = PhotoSort(key: .name, ascending: false)
        var index = PreparedSessionIndex()
        index.rebuildItems(items, sort: sort)
        var filter = PhotoFilter()
        filter.excludedDecisionStates = [.no]
        let supplied: [QualityCueMatch] = [.highISO, [], .shadowClipping]
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: false,
                          qualityCueMatches: supplied)
        XCTAssertEqual(index.visibleIndices.map { items[$0].id }, ["Z.JPG", "A.JPG"],
                       "Supplied cue matches cannot restrict an inactive cue filter.")
        filter.selectedQualityCues = [.highISO]
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: false,
                          qualityCueMatches: supplied)
        XCTAssertEqual(index.visibleIndices.map { items[$0].id }, ["Z.JPG"])
        filter.selectedQualityCues = []
        index.applyFilter(filter, to: items, sort: sort, isGroupingEnabled: false,
                          qualityCueMatches: supplied)
        XCTAssertEqual(index.visibleIndices.map { items[$0].id }, ["Z.JPG", "A.JPG"])
    }

    func testEveryCueSubsetUsesORAcrossMixedMediaAndPrimaryOnlyPairs() async throws {
        let fixture = mixedFixture()
        let probe = CueProjectionProbe(statistics: [
            "H.JPG": [1: .init(highlights: 20)],
            "D.JPG": [1: .init(shadows: 20)],
            "BOTH.JPG": [1: .init(shadows: 20, highlights: 20)],
            "MISSING.JPG": [1: .unavailable]
        ])
        let store = makeStore(items: fixture, probe: probe)
        let before = fixture.flatMap(\.individualFiles).map(\.metadataSnapshot)
        try await measureAllSupportedPhotos(store)
        let conditions: [CameraQualityWarning.Kind: Set<String>] = [
            .highISO: ["I.JPG", "BOTH.JPG", "RAW.NEF", "UNSUPPORTED.unknown"],
            .slowShutter: ["S.JPG", "BOTH.JPG"],
            .highlightClipping: ["H.JPG", "BOTH.JPG"],
            .shadowClipping: ["D.JPG", "BOTH.JPG"]
        ]
        let kinds: [CameraQualityWarning.Kind] = [.highISO, .slowShutter, .highlightClipping, .shadowClipping]
        // Return through earlier combinations as well as visiting each once:
        // switching a warm projection must be as correct as its first use.
        for combination in Array(0..<16) + Array((0..<16).reversed()) {
            let selected = Set(kinds.enumerated().compactMap { index, kind in
                combination & (1 << index) != 0 ? kind : nil
            })
            store.filter.selectedQualityCues = selected
            let expected = selected.isEmpty ? Set(fixture.map(\.id))
                : selected.reduce(into: Set<String>()) { $0.formUnion(conditions[$1]!) }
            XCTAssertEqual(visibleIDs(store), fixture.map(\.id).filter(expected.contains),
                           "Wrong OR membership for \(selected)")
        }
        XCTAssertNil(store.qualityEvidence(for: fixture.first { $0.id == "UNSUPPORTED.unknown" }!))
        XCTAssertEqual(fixture.first { $0.id == "PAIR.NEF" }?.ratingState, .mixed)
        XCTAssertEqual(fixture.first { $0.id == "RAW.NEF" }?.ratingState, .mixed)
        XCTAssertEqual(fixture.flatMap(\.individualFiles).map(\.metadataSnapshot), before,
                       "Switching review cues must preserve every physical decision.")
    }

    func testWarmProjectionReclassifiesThresholdsAndEnabledFlagsWithoutRemeasuring() async throws {
        let items = [
            photo("A.JPG", order: 0, iso: 6_400, shutter: 1.0 / 30),
            photo("B.JPG", order: 1, iso: 12_800, shutter: 1.0 / 15),
            photo("C.JPG", order: 2),
            photo("MISSING.JPG", order: 3, iso: nil, shutter: nil)
        ]
        let probe = CueProjectionProbe(statistics: [
            "A.JPG": [1: .init(shadows: 10, highlights: 10)],
            "B.JPG": [1: .init(shadows: 20, highlights: 20)],
            "MISSING.JPG": [1: .unavailable]
        ])
        let store = makeStore(items: items, probe: probe)
        try await measureAllSupportedPhotos(store)
        let initialCalls = await probe.totalCalls
        var preferences = store.qualityCuePreferences

        for kind in [CameraQualityWarning.Kind.highISO, .slowShutter, .highlightClipping, .shadowClipping] {
            store.filter.selectedQualityCues = [kind]
            XCTAssertEqual(visibleIDs(store), ["A.JPG", "B.JPG"], "Cutoff equality is inclusive.")
        }
        store.filter.selectedQualityCues = [.highISO]
        preferences.highISOThreshold = 12_800
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(visibleIDs(store), ["B.JPG"])
        preferences.highISOThreshold = 12_801
        store.updateQualityCuePreferences(preferences)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        preferences.highISOThreshold = 6_400

        store.filter.selectedQualityCues = [.slowShutter]
        preferences.slowShutterThreshold = 1.0 / 15
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(visibleIDs(store), ["B.JPG"])
        preferences.slowShutterThreshold = 1.0 / 15 + 0.0001
        store.updateQualityCuePreferences(preferences)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        preferences.slowShutterThreshold = 1.0 / 30

        for kind in [CameraQualityWarning.Kind.highlightClipping, .shadowClipping] {
            store.filter.selectedQualityCues = [kind]
            if kind == .highlightClipping { preferences.highlightPercentageThreshold = 20 }
            else { preferences.shadowPercentageThreshold = 20 }
            store.updateQualityCuePreferences(preferences)
            XCTAssertEqual(visibleIDs(store), ["B.JPG"])
            if kind == .highlightClipping { preferences.highlightPercentageThreshold = 20.0001 }
            else { preferences.shadowPercentageThreshold = 20.0001 }
            store.updateQualityCuePreferences(preferences)
            XCTAssertTrue(store.visibleIndices.isEmpty)
            if kind == .highlightClipping { preferences.highlightPercentageThreshold = 10 }
            else { preferences.shadowPercentageThreshold = 10 }
            store.updateQualityCuePreferences(preferences)
            XCTAssertEqual(visibleIDs(store), ["A.JPG", "B.JPG"])
        }

        preferences.isHighISOEnabled = false
        preferences.isSlowShutterEnabled = false
        preferences.isHighlightClippingEnabled = false
        preferences.isShadowClippingEnabled = false
        store.updateQualityCuePreferences(preferences)
        store.filter.selectedQualityCues = Set(CameraQualityWarning.Kind.allCases)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        preferences.isHighlightClippingEnabled = true
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(visibleIDs(store), ["A.JPG", "B.JPG"])
        store.filter.selectedQualityCues = [.highISO, .slowShutter, .shadowClipping]
        XCTAssertTrue(store.visibleIndices.isEmpty, "Disabled selected rules cannot contribute matches.")
        preferences.isEnabled = false
        store.updateQualityCuePreferences(preferences)
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.filter.selectedQualityCues = []
        XCTAssertEqual(visibleIDs(store), items.map(\.id), "No selected cue is a neutral filter even when rules are off.")
        preferences.isEnabled = true
        store.updateQualityCuePreferences(preferences)
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["A.JPG", "B.JPG"])
        for _ in 0..<12 { await Task.yield() }
        let finalCalls = await probe.totalCalls
        XCTAssertEqual(finalCalls, initialCalls, "Rule changes must reuse completed source evidence.")
    }

    func testArrivingEvidenceUpdatesWarmORProjectionWithoutRetargetingSelection() async throws {
        let items = [photo("A.JPG", order: 0, iso: 6_400),
                     photo("B.JPG", order: 1), photo("C.JPG", order: 2)]
        let probe = CueProjectionProbe(statistics: [
            "B.JPG": [1: .init(highlights: 20)], "C.JPG": [1: .init(shadows: 20)]
        ], deferred: true)
        let store = makeStore(items: items, probe: probe)
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["A.JPG"])
        store.setSelection([0])
        store.startQualityCueAnalysis()
        try await waitUntil { await probe.totalCalls == 2 }
        await probe.release(["A.JPG", "B.JPG"])
        try await waitUntil { visibleIDs(store) == ["A.JPG", "B.JPG"] }
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.selectedIndices, [0])
        store.filter.selectedQualityCues = [.shadowClipping]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        await probe.release(["C.JPG"])
        try await waitUntil { visibleIDs(store) == ["C.JPG"] }
        XCTAssertEqual(store.currentIndex, 0, "Asynchronous completion must not choose a different current photo.")
        XCTAssertNil(store.currentItem)
        XCTAssertTrue(store.effectiveSelection.isEmpty)
        store.rate(.yes)
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .undecided])
        store.filter.selectedQualityCues = [.highISO, .shadowClipping]
        XCTAssertEqual(visibleIDs(store), ["A.JPG", "C.JPG"])
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["B.JPG"])
    }

    func testSameIDReplacementAndReorderingDiscardWarmProjectionUntilFreshEvidence() async throws {
        let original = [photo("A.JPG", order: 0, iso: 6_400), photo("B.JPG", order: 1)]
        let probe = CueProjectionProbe(statistics: [
            "A.JPG": [1: .init(highlights: 20), 2: .init(highlights: 30)],
            "B.JPG": [1: .init(), 2: .init()]
        ])
        let store = makeStore(items: original, probe: probe)
        try await measureAllSupportedPhotos(store)
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["A.JPG"])
        store.filter.selectedQualityCues = [.highISO]
        XCTAssertEqual(visibleIDs(store), ["A.JPG"])
        store.pauseQualityCueAnalysis(userInitiated: true)
        store.items = [photo("B.JPG", order: 0, iso: 12_800, bytes: 2),
                       photo("A.JPG", order: 1, bytes: 2)]
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(visibleIDs(store), ["B.JPG"], "Immutable camera metadata must follow the replacement, not its old ID/index.")
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertTrue(store.visibleIndices.isEmpty, "The replacement cannot inherit an old file's image evidence.")
        XCTAssertNil(store.qualityEvidence(for: original[0]))
        XCTAssertNil(store.qualityEvidence(for: store.items[0]))
        store.resumeQualityCueAnalysis()
        try await waitUntil { store.qualityCueEvidence.count == 2 && visibleIDs(store) == ["A.JPG"] }
        XCTAssertNil(store.qualityEvidence(for: original[0]))
        XCTAssertNotNil(store.qualityEvidence(for: store.items[1]))
        store.filter.selectedQualityCues = [.highISO]
        XCTAssertEqual(visibleIDs(store), ["B.JPG"])
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["B.JPG", "A.JPG"])
        let total = await probe.totalCalls
        XCTAssertEqual(total, 4)
    }

    func testOtherFiltersSortAndSelectionIntersectWarmCueMembership() async throws {
        let items = [
            photo("Z.JPG", order: 0, iso: 6_400, camera: "Camera A", rating: .yes, stars: .five, color: .red),
            photo("A.JPG", order: 1, camera: "Camera B", rating: .yes, stars: .four, color: .purple),
            photo("M.JPG", order: 2, iso: 6_400, camera: "Camera B", rating: .no, stars: .four, color: .purple),
            photo("P.JPG", order: 3, camera: "Camera B", rating: .yes, stars: .four, color: .purple)
        ]
        let probe = CueProjectionProbe(statistics: [
            "A.JPG": [1: .init(highlights: 20)], "P.JPG": [1: .init(highlights: 20)]
        ])
        let store = makeStore(items: items, probe: probe)
        try await measureAllSupportedPhotos(store)
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        store.sort = PhotoSort(key: .name, ascending: true)
        XCTAssertEqual(visibleIDs(store), ["A.JPG", "M.JPG", "P.JPG", "Z.JPG"])
        store.currentIndex = 3
        store.setSelection([1, 3])
        store.sort = PhotoSort(key: .name, ascending: false)
        XCTAssertEqual(visibleIDs(store), ["Z.JPG", "P.JPG", "M.JPG", "A.JPG"])
        XCTAssertEqual(store.selectedIndices, [1, 3])
        XCTAssertEqual(store.currentItem?.id, "P.JPG")
        store.filter.excludedDecisionStates = [.no]
        XCTAssertEqual(visibleIDs(store), ["Z.JPG", "P.JPG", "A.JPG"])
        store.filter.excludedColorStates = [.label(.red)]
        XCTAssertEqual(visibleIDs(store), ["P.JPG", "A.JPG"])
        store.filter.excludedColorStates = []
        store.filter.excludedStarStates = [.stars(.five)]
        XCTAssertEqual(visibleIDs(store), ["P.JPG", "A.JPG"])
        store.filter.excludedStarStates = []
        store.filter.excludedCameras = ["Camera A"]
        XCTAssertEqual(visibleIDs(store), ["P.JPG", "A.JPG"])
        store.filter.searchText = "A.JPG"
        try await waitUntil { visibleIDs(store) == ["A.JPG"] }
        XCTAssertEqual(store.selectedIndices, [1])
        XCTAssertEqual(store.currentItem?.id, "A.JPG", "Surviving explicit selection owns the current photo after filtering.")
        store.filter.selectedQualityCues = [.highISO]
        XCTAssertTrue(store.visibleIndices.isEmpty, "Cue switching must preserve every other active criterion.")
        XCTAssertTrue(store.selectedIndices.isEmpty)
        var reset = PhotoFilter()
        reset.selectedQualityCues = [.highlightClipping]
        store.filter = reset
        store.sort = PhotoSort(key: .captureDate, ascending: false)
        XCTAssertEqual(visibleIDs(store), ["P.JPG", "A.JPG"])
        store.filter.excludedMediaKinds = [.photo]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.filter.excludedMediaKinds = []
        XCTAssertEqual(visibleIDs(store), ["P.JPG", "A.JPG"])
    }

    func testBurstAndNormalGroupsPreservePartialMembershipAcrossCueSwitches() async throws {
        let items = [photo("A.JPG", order: 0, iso: 6_400, date: 100),
                     photo("B.JPG", order: 1, date: 101),
                     photo("C.JPG", order: 2, date: 110),
                     photo("D.JPG", order: 3, iso: 6_400, date: 111)]
        let probe = CueProjectionProbe(statistics: [
            "B.JPG": [1: .init(highlights: 20)], "C.JPG": [1: .init(shadows: 20)],
            "D.JPG": [1: .init(highlights: 20)]
        ])
        let store = makeStore(items: items, probe: probe)
        try await measureAllSupportedPhotos(store)
        store.isGroupingEnabled = true
        store.setBurstGroupingInterval(2)
        store.enterGroupedReview(.captureBursts)
        try await waitUntil { store.groupedReviewMode == .captureBursts && !store.isDuplicateBurstAnalysisRunning }
        XCTAssertEqual(groupIDs(store), [["A.JPG", "B.JPG"], ["C.JPG", "D.JPG"]])
        store.filter.selectedQualityCues = [.highISO]
        XCTAssertEqual(visibleIDs(store), ["A.JPG", "D.JPG"])
        XCTAssertEqual(groupIDs(store), [["A.JPG"], ["D.JPG"]], "A cue filter retains even a group's single visible survivor.")
        store.currentIndex = 3
        store.setSelection([0, 3])
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        XCTAssertEqual(groupIDs(store), [["A.JPG", "B.JPG"], ["D.JPG"]])
        XCTAssertEqual(store.selectedIndices, [0, 3])
        XCTAssertEqual(store.currentItem?.id, "D.JPG")
        store.filter.selectedQualityCues = [.shadowClipping]
        XCTAssertEqual(groupIDs(store), [["C.JPG"]])
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(store.currentItem?.id, "C.JPG")
        store.filter.selectedQualityCues = []
        store.sort = PhotoSort(key: .captureDate, ascending: false)
        XCTAssertEqual(groupIDs(store), [["D.JPG", "C.JPG"], ["B.JPG", "A.JPG"]])
        XCTAssertEqual(store.currentItem?.id, "C.JPG")
        store.exitGroupedReview()
        XCTAssertEqual(visibleIDs(store), ["D.JPG", "C.JPG", "B.JPG", "A.JPG"])
        XCTAssertEqual(store.visibleGroups.flatMap(\.indices), store.visibleIndices)
        store.isGroupingEnabled = false
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["D.JPG", "B.JPG"])
        XCTAssertEqual(store.visibleGroups.flatMap(\.indices), store.visibleIndices)
    }

    func testWarmCueSwitchingAndAcceptedPairsAvoidFullReclassification() async throws {
        let items = [photo("A.JPG", order: 0, iso: 6_400),
                     photo("B.JPG", order: 1), photo("C.JPG", order: 2), photo("D.JPG", order: 3)]
        let probe = CueProjectionProbe(statistics: [
            "B.JPG": [1: .init(highlights: 20)],
            "C.JPG": [1: .init(shadows: 20)], "D.JPG": [1: .init(highlights: 30)]
        ], deferred: true)
        let store = makeStore(items: items, probe: probe)
        let initialBuilds = store.qualityCueMatchBuildsForTesting
        let initialUpdates = store.qualityCueMatchUpdatesForTesting
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        XCTAssertEqual(visibleIDs(store), ["A.JPG"])
        let warmedBuilds = store.qualityCueMatchBuildsForTesting
        XCTAssertEqual(warmedBuilds, initialBuilds + 1)
        let combinations: [Set<CameraQualityWarning.Kind>] = [
            [.highlightClipping], [.highISO], [.shadowClipping, .slowShutter], [],
            [.highISO, .highlightClipping]
        ]
        for _ in 0..<4 {
            for selected in combinations { store.filter.selectedQualityCues = selected }
        }
        XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds,
                       "Warm filter toggles must not classify the whole session again.")

        store.startQualityCueAnalysis()
        try await waitUntil { await probe.totalCalls == 2 }
        await probe.release(["A.JPG", "B.JPG"])
        // The following pair stays inside the measurement gate. Reaching it
        // proves the accepted pair has finished its entire projection turn.
        try await waitUntil { await probe.totalCalls == 4 }
        XCTAssertEqual(visibleIDs(store), ["A.JPG", "B.JPG"])
        XCTAssertEqual(store.qualityCueMatchUpdatesForTesting, initialUpdates + 2,
                       "A completed pair should reclassify its two entries only.")
        XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds)
        for selected in combinations { store.filter.selectedQualityCues = selected }
        XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds)

        var preferences = store.qualityCuePreferences
        preferences.highlightPercentageThreshold = 21
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(visibleIDs(store), ["A.JPG"])
        XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds + 1,
                       "Changed rules require one fresh classification.")
        store.items = [photo("E.JPG", order: 0, iso: 6_400),
                       photo("F.JPG", order: 1), photo("G.JPG", order: 2), photo("H.JPG", order: 3)]
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(visibleIDs(store), ["E.JPG"])
        XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds + 2,
                       "Equal array counts do not make replaced item structure reusable.")
        let updatesBeforeRetiredResults = store.qualityCueMatchUpdatesForTesting
        store.startQualityCueAnalysis()
        await probe.release(["C.JPG", "D.JPG"])
        // E/F are new, unreleased gate IDs. Their admission proves the retired
        // C/D generation drained, without accepting any fresh result yet.
        try await waitUntil { await probe.totalCalls == 6 }
        XCTAssertTrue(store.qualityCueEvidence.isEmpty)
        XCTAssertEqual(store.qualityCueMatchUpdatesForTesting, updatesBeforeRetiredResults,
                       "Retired results must not update classification slots.")
        XCTAssertEqual(store.qualityCueMatchBuildsForTesting, warmedBuilds + 2)
        XCTAssertEqual(visibleIDs(store), ["E.JPG"])
    }

    private func makeStore(items: [PhotoItem], probe: CueProjectionProbe) -> SessionStore {
        let suite = "QualityCueFilterProjectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        CameraQualityWarningPreferences().save(to: defaults)
        let store = SessionStore(reviewDefaults: defaults,
            qualityCueMeasurement: { await probe.measure($0) },
            qualityCueRest: { _ in await Task.yield() })
        store.showMetadataPanel = false
        store.isGroupingEnabled = false
        store.items = items
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        addTeardownBlock {
            await MainActor.run { store.beginTerminationPreparation() }
            await probe.releaseAll()
            await MainActor.run { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
        return store
    }

    private func measureAllSupportedPhotos(_ store: SessionStore) async throws {
        let count = store.items.filter { $0.mediaKind == .photo && $0.isSupported }.count
        store.startQualityCueAnalysis()
        try await waitUntil { store.qualityCueEvidence.count == count && store.qualityCueCheckingIDs.isEmpty }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard await predicate() else {
            XCTFail("Cue projection did not reach the requested observable state.")
            throw CueProjectionTimeout.expired
        }
    }

    private func visibleIDs(_ store: SessionStore) -> [String] {
        store.visibleIndices.map { store.items[$0].id }
    }

    private func groupIDs(_ store: SessionStore) -> [[String]] {
        store.visibleGroups.map { group in group.indices.map { store.items[$0].id } }
    }

    private func photo(_ id: String, order: Int, iso: Double? = 100, shutter: Double? = 0.001,
                       camera: String? = nil, rating: Rating = .undecided, stars: StarRating? = nil,
                       color: PhotoColorLabel? = nil, bytes: Int64 = 1, date: TimeInterval? = nil,
                       kind: MediaKind = .photo) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-cue-projection-synthetic/\(id)"),
            captureDate: Date(timeIntervalSince1970: date ?? 1_000 + Double(order)),
            cameraModel: camera, lensModel: nil, shutterSpeed: shutter, iso: iso,
            mediaKind: kind, fileSize: bytes, rating: rating, starRating: stars, colorLabel: color))
    }

    private func mixedFixture() -> [PhotoItem] {
        var items = [photo("I.JPG", order: 0, iso: 6_400),
                     photo("S.JPG", order: 1, shutter: 1.0 / 30),
                     photo("H.JPG", order: 2), photo("D.JPG", order: 3),
                     photo("BOTH.JPG", order: 4, iso: 12_800, shutter: 1.0 / 15),
                     photo("CLEAR.JPG", order: 5)]
        let rawNoCue = photo("PAIR.NEF", order: 6, rating: .yes).primaryFile
        let jpegCue = photo("PAIR.JPG", order: 6, iso: 12_800, shutter: 1, rating: .no).primaryFile
        items.append(PhotoItem(primaryFile: rawNoCue, pairedFile: jpegCue))
        let rawCue = photo("RAW.NEF", order: 7, iso: 6_400, rating: .no).primaryFile
        let jpegNoCue = photo("RAW.JPG", order: 7, rating: .yes).primaryFile
        items.append(PhotoItem(primaryFile: rawCue, pairedFile: jpegNoCue))
        items.append(contentsOf: [photo("UNSUPPORTED.unknown", order: 8, iso: 6_400),
                                 photo("MOVIE.MOV", order: 9, iso: 12_800, shutter: 1, kind: .video),
                                 photo("SOUND.WAV", order: 10, iso: 12_800, shutter: 1, kind: .audio),
                                 photo("NOTE.txt", order: 11, iso: 12_800, shutter: 1, kind: .text),
                                 photo("MISSING.JPG", order: 12, iso: nil, shutter: nil)])
        return items
    }
}

private enum CueProjectionTimeout: Error { case expired }

private struct CueProjectionStatistics: Sendable {
    var shadows = 0
    var highlights = 0
    var available = true
    static let unavailable = Self(available: false)
}

private actor CueProjectionProbe {
    private let statistics: [String: [Int64: CueProjectionStatistics]]
    private let deferred: Bool
    private var released = Set<String>()
    private var allowFuture = false
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var totalCalls = 0

    init(statistics: [String: [Int64: CueProjectionStatistics]] = [:], deferred: Bool = false) {
        self.statistics = statistics
        self.deferred = deferred
    }

    func measure(_ item: PhotoItem) async -> QualityCueEvidence {
        totalCalls += 1
        if deferred && !allowFuture && !released.contains(item.id) {
            await withCheckedContinuation { waiters[item.id, default: []].append($0) }
        }
        let value = statistics[item.id]?[item.fileSize] ?? .init()
        return QualityCueEvidence(item: item,
            analysis: value.available ? HistogramAnalysis(bins: [], sampleCount: 100,
                shadowCount: value.shadows, highlightCount: value.highlights, width: 10, height: 10) : nil,
            source: item.isRaw ? .rawDecode : .renderedPreview)
    }

    func release(_ ids: Set<String>) {
        released.formUnion(ids)
        for id in ids {
            let continuations = waiters.removeValue(forKey: id) ?? []
            for continuation in continuations { continuation.resume() }
        }
    }

    func releaseAll() {
        allowFuture = true
        let pending = waiters
        waiters.removeAll()
        for continuations in pending.values {
            for continuation in continuations { continuation.resume() }
        }
    }
}
