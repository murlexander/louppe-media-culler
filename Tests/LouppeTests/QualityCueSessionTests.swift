import XCTest
import AppKit
import ImageIO
@testable import Louppe

@MainActor
final class QualityCueSessionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "QualityCueSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func photo(_ name: String, iso: Double? = 100, shutter: Double? = 0.001,
                       rating: Rating = .undecided, bytes: Int64 = 1) -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(
            id: name, url: URL(fileURLWithPath: "/private/tmp/\(name)"),
            captureDate: Date(timeIntervalSince1970: 100), cameraModel: "Camera",
            lensModel: nil, shutterSpeed: shutter, iso: iso, fileSize: bytes, rating: rating
        ))
    }

    private func evidence(_ item: PhotoItem, shadows: Int = 0, highlights: Int = 0) -> QualityCueEvidence {
        QualityCueEvidence(item: item, analysis: HistogramAnalysis(
            bins: [], sampleCount: 100, shadowCount: shadows, highlightCount: highlights,
            width: 10, height: 10), source: .renderedPreview)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate())
    }

    func testLegacySplitPreservesDisabledFlagsAndExactCutoffOnce() {
        let defaults = defaults()
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isClippingEnabled)
        defaults.set(7.123456789, forKey: CameraQualityWarningPreferences.Keys.clippingPercentageThreshold)
        var migrated = CameraQualityWarningPreferences.load(from: defaults)
        XCTAssertFalse(migrated.isHighlightClippingEnabled)
        XCTAssertFalse(migrated.isShadowClippingEnabled)
        XCTAssertEqual(migrated.highlightPercentageThreshold, 7.123456789)
        XCTAssertEqual(migrated.shadowPercentageThreshold, 7.123456789)
        migrated.isHighlightClippingEnabled = true
        migrated.highlightPercentageThreshold = 12.5
        migrated.save(to: defaults)
        XCTAssertEqual(CameraQualityWarningPreferences.load(from: defaults), migrated)
        XCTAssertEqual(CameraQualityWarningPreferences.load(from: defaults).shadowPercentageThreshold, 7.123456789)
    }

    func testIndependentInclusiveRulesKeepDisabledCutoffs() {
        let item = photo("A.JPG")
        let analysis = evidence(item, shadows: 10, highlights: 20).analysis
        var preferences = CameraQualityWarningPreferences(
            highlightPercentageThreshold: 20, shadowPercentageThreshold: 10)
        XCTAssertEqual(CameraQualityWarning.warnings(for: item, analysis: analysis,
                       preferences: preferences).map(\.kind), [.highlightClipping, .shadowClipping])
        preferences.isShadowClippingEnabled = false
        XCTAssertEqual(CameraQualityWarning.warnings(for: item, analysis: analysis,
                       preferences: preferences).map(\.kind), [.highlightClipping])
        XCTAssertEqual(preferences.shadowPercentageThreshold, 10)
        preferences.highlightPercentageThreshold = 20.000001
        XCTAssertTrue(CameraQualityWarning.warnings(for: item, analysis: analysis,
                      preferences: preferences).isEmpty)
    }

    func testAnyCueIntersectsDecisionAndPartialBurstMembership() async throws {
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 100,
                shadowCount: 0, highlightCount: item.id == "B.JPG" ? 20 : 0), source: .renderedPreview)
        })
        store.items = [photo("A.JPG", iso: 6400, rating: .yes), photo("B.JPG", rating: .yes),
                       photo("C.JPG", rating: .no)]
        store.phase = .ready
        store.showMetadataPanel = false
        store.rebuildDerivedDataForTesting()
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueEvidence.count == 3 }
        store.filter.selectedQualityCues = [.highISO, .highlightClipping]
        XCTAssertEqual(store.visibleIndices, [0, 1])
        store.filter.excludedDecisionStates = [.yes]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.filter.excludedDecisionStates = []
        store.filter.searchText = "B.JPG"
        // Search is deliberately debounced.
        await waitUntil { store.visibleIndices == [1] }
        store.enterGroupedReview(.captureBursts)
        await waitUntil { store.groupedReviewMode == .captureBursts }
        XCTAssertEqual(store.visibleIndices, [1])
        XCTAssertTrue(store.visibleGroups.first?.title?.contains("1 of 3 shown") == true)
        XCTAssertEqual(store.items.map(\.rating), [.yes, .yes, .no])
    }

    func testThresholdEditsReuseEvidenceWithoutReadsOrSelectionChanges() async {
        let calls = MeasurementCalls()
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            await calls.record()
            return QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 100,
                shadowCount: 10, highlightCount: 20), source: .renderedPreview)
        })
        store.items = [photo("A.JPG"), photo("B.JPG")]
        store.phase = .ready
        store.showMetadataPanel = false
        store.rebuildDerivedDataForTesting()
        store.setIndex(1)
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueEvidence.count == 2 }
        var preferences = store.qualityCuePreferences
        preferences.highlightPercentageThreshold = 21
        preferences.isShadowClippingEnabled = false
        store.updateQualityCuePreferences(preferences)
        XCTAssertTrue(store.qualityCues(for: store.items[1]).isEmpty)
        preferences.highlightPercentageThreshold = 20
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(store.qualityCues(for: store.items[1]).map(\.kind), [.highlightClipping])
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(store.selectedIndices.isEmpty)
    }

    func testUncheckedCheckingCanceledReplacementAndHonestCoverage() async {
        let gate = MeasurementGate()
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            await gate.measure(item)
        })
        store.items = [photo("A.JPG")]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(store.qualityCueStatus(for: store.items[0]), .unchecked)
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueStatus(for: store.items[0]) == .checking }
        let previous = store.items[0]
        store.items = [photo("A.JPG", bytes: 2)]
        store.rebuildDerivedDataForTesting()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.qualityEvidence(for: store.items[0]))
        XCTAssertNil(store.qualityEvidence(for: previous))
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 0)
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.total, 1)
        XCTAssertEqual(store.qualityCueStatus(for: store.items[0]), .unchecked)
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueStatus(for: store.items[0]) == .checked }
        store.pauseQualityCueAnalysis()
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, 1)
        XCTAssertEqual(store.qualityCueStatus(for: store.items[0]), .checked)
    }

    func testQuitPreparationRetiresInFlightCuesAndCancellationRestartsThem() async {
        let gate = MeasurementGate()
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            await gate.measure(item)
        })
        store.items = [photo("A.JPG")]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueStatus(for: store.items[0]) == .checking }
        store.beginTerminationPreparation()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.qualityEvidence(for: store.items[0]))
        store.cancelTerminationPreparation()
        await waitUntil { store.qualityEvidence(for: store.items[0]) != nil }
    }

    func testBackgroundMatchesNeverRateTheHiddenCurrentPhoto() async {
        let gate = MeasurementGate()
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            _ = await gate.measure(item)
            return QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 100,
                shadowCount: 0, highlightCount: item.id == "B.JPG" ? 50 : 0), source: .renderedPreview)
        })
        store.items = [photo("A.JPG"), photo("B.JPG")]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        store.startQualityCueAnalysis()
        await gate.release()
        await waitUntil { store.visibleIndices == [1] }
        XCTAssertEqual(store.currentIndex, 0, "completion must not select a different photo")
        XCTAssertNil(store.currentItem, "a hidden current index must not appear in Gallery or Info")
        XCTAssertTrue(store.effectiveSelection.isEmpty)
        store.rate(.yes)
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided])
        store.setIndex(1)
        XCTAssertEqual(store.currentItem?.id, "B.JPG")
    }

    func testMixedPairFiltersUsePrimaryEvidenceAndPreservePhysicalDecisions() {
        let raw = PhotoFile(id: "A.NEF", url: URL(fileURLWithPath: "/private/tmp/A.NEF"),
            captureDate: nil, cameraModel: nil, lensModel: nil, iso: 12800, fileSize: 1, rating: .yes)
        let jpeg = PhotoFile(id: "A.JPG", url: URL(fileURLWithPath: "/private/tmp/A.JPG"),
            captureDate: nil, cameraModel: nil, lensModel: nil, iso: 100, fileSize: 1, rating: .no)
        let store = SessionStore(reviewDefaults: defaults())
        store.items = [PhotoItem(primaryFile: raw, pairedFile: jpeg)]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.filter.selectedQualityCues = [.highISO]
        XCTAssertEqual(store.visibleIndices, [0])
        XCTAssertEqual(store.items[0].ratingState, .mixed)
        XCTAssertEqual(store.qualityCues(for: store.items[0]).first?.source, .cameraMetadata)
        store.filter.excludedDecisionStates = [.mixed]
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertEqual(raw.rating, .yes)
        XCTAssertEqual(jpeg.rating, .no)
    }

    func testMissingMetadataFailedImageAndUnsupportedRemainDistinct() async {
        let store = SessionStore(reviewDefaults: defaults(), qualityCueMeasurement: { item in
            QualityCueEvidence(item: item, analysis: nil, source: .renderedPreview)
        })
        store.items = [photo("A.JPG", iso: nil, shutter: nil), photo("B.JPG")]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueEvidence.count == 2 }
        XCTAssertEqual(store.qualityCueStatus(for: store.items[0]), .unavailable)
        XCTAssertEqual(store.qualityCueStatus(for: store.items[1]), .partial)
        XCTAssertTrue(store.qualityCues(for: store.items[0]).isEmpty)
        var preferences = store.qualityCuePreferences
        preferences.isEnabled = false
        store.updateQualityCuePreferences(preferences)
        XCTAssertEqual(store.qualityCueStatus(for: store.items[0]), .disabled)
    }

    func testPreferencesNotificationsFromWorkersReachMainActor() async {
        let defaults = defaults()
        let store = SessionStore(reviewDefaults: defaults)
        defaults.set(21.125, forKey: CameraQualityWarningPreferences.Keys.highlightPercentageThreshold)
        await Task.detached {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }.value
        await waitUntil { store.qualityCuePreferences.highlightPercentageThreshold == 21.125 }
        XCTAssertEqual(store.qualityCuePreferences.shadowPercentageThreshold, 10)
    }

    func testRealRAWProvidesBoundedSourceEvidenceWithInfoClosed() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_RAW_TEST_FILE"] else {
            throw XCTSkip("Set LOUPPE_RAW_TEST_FILE for real camera cue evidence")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let scanned = try FolderScanner.scan(url.deletingLastPathComponent(), progress: { _ in })
        let item = try XCTUnwrap(scanned.first { $0.primaryURL.standardizedFileURL == url })
        let store = SessionStore(reviewDefaults: defaults())
        store.items = [item]
        store.phase = .ready
        store.showMetadataPanel = false
        store.rebuildDerivedDataForTesting()
        store.startQualityCueAnalysis()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while store.qualityEvidence(for: item) == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let result = try XCTUnwrap(store.qualityEvidence(for: item))
        XCTAssertEqual(result.source, .rawDecode)
        XCTAssertFalse(result.rawFallback)
        XCTAssertGreaterThan(result.sampleCount, 0)
        XCTAssertGreaterThan(result.width, 0)
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertLessThanOrEqual(max(result.width, result.height), 1025)
        XCTAssertEqual(item.rating, .undecided)
        XCTAssertFalse(store.showMetadataPanel)
    }

    func testRealFolderHistogramWithInfoClosedLeavesOriginalsAndRatingsIntact() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeQuality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var originals: [URL: Data] = [:]
        for (name, component) in [("White.png", UInt8(255)), ("Black.png", UInt8(0)), ("Gray.png", UInt8(128))] {
            let url = folder.appendingPathComponent(name)
            let bytes = Data(repeating: component, count: 32 * 32 * 3)
            let image = try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8,
                bitsPerPixel: 24, bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: bytes as CFData)!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(output))
            originals[url] = try Data(contentsOf: url)
        }
        let scanned = try FolderScanner.scan(folder, progress: { _ in })
        let store = SessionStore(reviewDefaults: defaults())
        store.items = scanned
        store.phase = .ready
        store.showMetadataPanel = false
        store.rebuildDerivedDataForTesting()
        store.startQualityCueAnalysis()
        await waitUntil { store.qualityCueEvidence.count == 3 }
        store.filter.selectedQualityCues = [.highlightClipping]
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].displayName }, ["White.png"])
        store.filter.selectedQualityCues = [.shadowClipping]
        XCTAssertEqual(store.visibleIndices.map { store.items[$0].displayName }, ["Black.png"])
        XCTAssertEqual(store.items.map(\.rating), [.undecided, .undecided, .undecided])
        for (url, data) in originals { XCTAssertEqual(try Data(contentsOf: url), data) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".louppe_session.json").path))
    }
}

private actor MeasurementCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor MeasurementGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func measure(_ item: PhotoItem) async -> QualityCueEvidence {
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return QualityCueEvidence(item: item, analysis: HistogramAnalysis(bins: [], sampleCount: 100,
            shadowCount: 0, highlightCount: 0), source: .renderedPreview)
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
