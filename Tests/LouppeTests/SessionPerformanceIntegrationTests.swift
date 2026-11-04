import Foundation
import XCTest
@testable import Louppe

@MainActor
final class SessionPerformanceIntegrationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "SessionPerformanceIntegration.\(UUID())"
        let value = UserDefaults(suiteName: name)!
        value.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        value.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func item(_ name: String, bytes: Int64 = 1, kind: MediaKind = .photo) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: name, url: URL(fileURLWithPath: "/private/tmp/\(name)"),
            captureDate: Date(timeIntervalSince1970: 100), cameraModel: nil, lensModel: nil,
            mediaKind: kind, fileSize: bytes, rating: .undecided))
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }

    func testSortOnlyRetainsStructuralGenerationPendingProofsAndSelection() {
        let store = SessionStore(reviewDefaults: defaults())
        store.items = [item("Z.JPG"), item("A.JPG"), item("B.JPG")]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.setSelection([0, 2])
        store.toggleRating(at: 0)
        let generation = store.structuralIndexGenerationForTesting
        let pending = store.pendingContentFileIDsForTesting
        let selected = Set(store.selectedIndices.map { store.items[$0].id })
        for key in [PhotoSort.Key.camera, .decision, .starRating, .colorLabel, .captureDate] {
            store.sort = PhotoSort(key: key, ascending: false)
            XCTAssertEqual(store.structuralIndexGenerationForTesting, generation)
            XCTAssertEqual(store.pendingContentFileIDsForTesting, pending)
            XCTAssertEqual(Set(store.selectedIndices.map { store.items[$0].id }), selected)
        }
        // Same-count replacement invalidates the canonical order and ID maps.
        store.items = [item("D.JPG"), item("C.JPG"), item("B.JPG")]
        store.sort = PhotoSort(key: .decision, ascending: true)
        XCTAssertGreaterThan(store.structuralIndexGenerationForTesting, generation)
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].id }, ["B.JPG", "C.JPG", "D.JPG"])
        store.beginTerminationPreparation()
    }

    func testCoverageCountsAreExactForSupportedUnsupportedAndEmptySessions() async throws {
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            QualityCueEvidence(item: item,
                analysis: item.id == "A.JPG" ? HistogramAnalysis(bins: [], sampleCount: 10,
                    shadowCount: 0, highlightCount: 0) : nil, source: .renderedPreview)
        })
        store.items = [item("A.JPG"), item("B.JPG"), item("C.unknown"), item("D.txt", kind: .text)]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, 3)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 0)
        var preferences = store.qualityCuePreferences
        preferences.isHighlightClippingEnabled = true
        store.updateQualityCuePreferences(preferences)
        try await wait { store.qualityCueEvidence.count == 2 }
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 1)
        store.pauseQualityCueAnalysis()
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 1)
        store.items = [PhotoItem(primaryFile: store.items[0].primaryFile, pairedFile: store.items[1].primaryFile)]
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, 1)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 0)
        store.startQualityCueAnalysis()
        try await wait { store.qualityCueCoverageCountsForTesting.measured == 1 }
        store.items = []
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, 0)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 0)
        store.beginTerminationPreparation()
    }

    func testRollbackIdentityRefreshWithoutItemReplacementCannotDoubleCountCoverage() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-coverage-rollback-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A.JPG")
        let originalBytes = Data("disposable identity fixture".utf8)
        try originalBytes.write(to: url)
        let photo = PhotoItem(primaryFile: PhotoFile(id: "A.JPG", url: url,
            captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: Int64(originalBytes.count),
            scannedIdentity: try FileOperationJournal.captureIdentity(at: url)))
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 10,
                shadowCount: 0, highlightCount: 10), source: .renderedPreview)
        })
        store.items = [photo]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        var preferences = store.qualityCuePreferences
        preferences.isHighlightClippingEnabled = true
        store.updateQualityCuePreferences(preferences)
        try await wait { store.qualityCueCoverageCountsForTesting.measured == 1 }
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(store.visibleIndices, [0])
        let revision = photo.contentRevision
        XCTAssertTrue(store.exportWillStart(mode: .move))
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 0)
        XCTAssertTrue(store.isQualityCueAnalysisPaused)
        XCTAssertTrue(store.visibleIndices.isEmpty, "invalid evidence must also leave the cue filter")
        let moved = root.appendingPathComponent("temporarily-moved.JPG")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.moveItem(at: moved, to: url)
        try photo.primaryFile.refreshScannedIdentityFromDisk()
        XCTAssertNotEqual(photo.contentRevision, revision)
        store.finishExport(mode: .move, movedIDs: [], requiresRecovery: false)
        try await wait { store.qualityCueCoverageCountsForTesting.measured == 1 }
        try await wait { store.visibleIndices == [0] }
        store.pauseQualityCueAnalysis()
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 1)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 1)
        store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 1)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        store.beginTerminationPreparation()
    }

    func testLatestSensitivityAndModeWinWhileCompletedMembershipRemains() async throws {
        let gate = MembershipGate()
        let store = SessionStore(reviewDefaults: defaults(), duplicateBurstGrouping: { _, mode, distance, interval in
            await gate.groups(mode: mode, distance: distance, interval: interval)
        })
        store.items = [item("A.JPG"), item("B.JPG"), item("C.JPG")]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.enterGroupedReview(.likelySimilarPhotos)
        try await wait { await gate.count == 1 }
        await gate.release(0, ids: ["A.JPG", "B.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        XCTAssertEqual(store.visibleIndices, [0, 1])
        store.setVisualSimilarityDistance(3)
        try await wait { await gate.count == 2 }
        XCTAssertEqual(store.visibleIndices, [0, 1], "Pending sensitivity keeps completed membership")
        store.setVisualSimilarityDistance(16)
        try await wait { await gate.count == 3 }
        await gate.release(2, ids: ["B.JPG", "C.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        await gate.release(1, ids: ["A.JPG", "C.JPG"])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(store.visualSimilarityDistance, 16)
        XCTAssertEqual(store.visibleIndices, [1, 2])
        store.enterGroupedReview(.exactDuplicates)
        try await wait { await gate.count == 4 }
        XCTAssertEqual(store.groupedReviewMode, .likelySimilarPhotos)
        XCTAssertEqual(store.visibleIndices, [1, 2])
        store.enterGroupedReview(.captureBursts)
        try await wait { await gate.count == 5 }
        await gate.release(4, ids: ["A.JPG", "C.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        await gate.release(3, ids: ["A.JPG", "B.JPG"])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(store.groupedReviewMode, .captureBursts)
        XCTAssertEqual(store.visibleIndices, [0, 2])
        store.beginTerminationPreparation()
    }

    func testCancelSimilarityRegroupingRestoresCompletedSensitivity() async throws {
        let gate = MembershipGate()
        let store = SessionStore(reviewDefaults: defaults(), duplicateBurstGrouping: { _, mode, distance, interval in
            await gate.groups(mode: mode, distance: distance, interval: interval)
        })
        store.items = [item("A.JPG"), item("B.JPG"), item("C.JPG")]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.enterGroupedReview(.likelySimilarPhotos)
        try await wait { await gate.count == 1 }
        await gate.release(0, ids: ["A.JPG", "B.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        let completedDistance = store.visualSimilarityDistance
        store.setVisualSimilarityDistance(16)
        try await wait { await gate.count == 2 }
        XCTAssertEqual(store.visibleIndices, [0, 1])
        store.cancelDuplicateBurstAnalysis()
        XCTAssertEqual(store.visualSimilarityDistance, completedDistance)
        XCTAssertEqual(store.groupedReviewMode, .likelySimilarPhotos)
        XCTAssertEqual(store.visibleIndices, [0, 1])
        await gate.release(1, ids: ["B.JPG", "C.JPG"])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(store.visibleIndices, [0, 1])
        XCTAssertFalse(store.isDuplicateBurstAnalysisRunning)
        store.beginTerminationPreparation()
    }

    func testNavigationDuringModeChangeKeepsPreviousCompletedProjection() async throws {
        let gate = MembershipGate()
        let store = SessionStore(reviewDefaults: defaults(), duplicateBurstGrouping: { _, mode, distance, interval in
            await gate.groups(mode: mode, distance: distance, interval: interval)
        })
        store.items = [item("A.JPG"), item("B.JPG"), item("C.JPG")]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.enterGroupedReview(.captureBursts)
        try await wait { await gate.count == 1 }
        await gate.release(0, ids: ["A.JPG", "B.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        store.enterGroupedReview(.exactDuplicates)
        try await wait { await gate.count == 2 }
        store.setIndex(1)
        await gate.release(1, ids: ["B.JPG", "C.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        XCTAssertEqual(store.groupedReviewMode, .captureBursts)
        XCTAssertEqual(store.visibleIndices, [0, 1])
        XCTAssertEqual(store.currentIndex, 1)
        store.beginTerminationPreparation()
    }

    func testCancelNavigationAndReplacementRejectPendingMembership() async throws {
        let gate = MembershipGate()
        let store = SessionStore(reviewDefaults: defaults(), duplicateBurstGrouping: { _, mode, distance, interval in
            await gate.groups(mode: mode, distance: distance, interval: interval)
        })
        store.items = [item("A.JPG"), item("B.JPG"), item("C.JPG")]
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.enterGroupedReview(.exactDuplicates)
        try await wait { await gate.count == 1 }
        store.setIndex(2)
        await gate.release(0, ids: ["A.JPG", "B.JPG"])
        try await wait { !store.isDuplicateBurstAnalysisRunning }
        XCTAssertEqual(store.groupedReviewMode, .off)
        XCTAssertEqual(store.currentIndex, 2)
        store.enterGroupedReview(.likelySimilarPhotos)
        try await wait { await gate.count == 2 }
        store.exitGroupedReview()
        await gate.release(1, ids: ["A.JPG", "B.JPG"])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(store.groupedReviewMode, .off)
        XCTAssertEqual(store.visibleIndices, [0, 1, 2])
        store.enterGroupedReview(.captureBursts)
        try await wait { await gate.count == 3 }
        store.items = [item("A.JPG", bytes: 2)]
        store.rebuildDerivedDataForTesting()
        await gate.release(2, ids: ["A.JPG", "B.JPG"])
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(store.groupedReviewMode, .off)
        XCTAssertEqual(store.visibleIndices, [0])
        XCTAssertFalse(store.isDuplicateBurstAnalysisRunning)
        store.beginTerminationPreparation()
    }
}

private actor MembershipGate {
    private struct Request {
        let mode: DuplicateBurstAnalysis.ReviewMode
        let continuation: CheckedContinuation<[DuplicateBurstAnalysis.Group], Never>
    }
    private var requests: [Request] = []
    var count: Int { requests.count }
    func groups(mode: DuplicateBurstAnalysis.ReviewMode, distance: Int, interval: TimeInterval) async -> [DuplicateBurstAnalysis.Group] {
        await withCheckedContinuation { requests.append(Request(mode: mode, continuation: $0)) }
    }
    func release(_ index: Int, ids: [String]) {
        let request = requests[index]
        request.continuation.resume(returning: [.init(id: "test-\(index)", mode: request.mode, itemIDs: ids)])
    }
}
