import XCTest
import AppKit
@testable import Louppe

final class CameraQualityWarningTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CameraQualityWarningTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testNoiseCueSymbolAndCompactValues() {
        XCTAssertNotNil(NSImage(systemSymbolName: QualityCueKind.highISO.symbol, accessibilityDescription: nil))
        XCTAssertNotEqual(QualityCueKind.highISO.symbol, "camera.aperture")
        XCTAssertEqual(CameraQualityWarning(kind: .highISO, measuredValue: 6400, threshold: 3200,
                                          source: .cameraMetadata).compactValue, "ISO 6400")
        XCTAssertEqual(CameraQualityWarning(kind: .shadowClipping, measuredValue: 25, threshold: 10,
                                          source: .histogram(.renderedPreview)).compactValue, "25%")
    }

    func testDefaultPreferencesAreSensibleAndEnabled() {
        let preferences = CameraQualityWarningPreferences.load(from: defaults)

        XCTAssertTrue(preferences.isEnabled)
        XCTAssertTrue(preferences.isHighISOEnabled)
        XCTAssertTrue(preferences.isSlowShutterEnabled)
        XCTAssertTrue(preferences.isClippingEnabled)
        XCTAssertEqual(
            preferences.highISOThreshold,
            CameraQualityWarningPreferences.defaultHighISOThreshold
        )
        XCTAssertEqual(
            preferences.slowShutterThreshold,
            1.0 / 30.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            preferences.clippingPercentageThreshold,
            10
        )
    }

    func testCustomPreferencesPersistIndependently() {
        let saved = CameraQualityWarningPreferences(
            isEnabled: false,
            highISOThreshold: 3_200,
            slowShutterThreshold: 1.0 / 60.0,
            clippingPercentageThreshold: 5
        )

        saved.save(to: defaults)

        XCTAssertEqual(CameraQualityWarningPreferences.load(from: defaults), saved)
    }

    func testInvalidStoredThresholdsSafelyUseDefaults() {
        defaults.set(-1, forKey: CameraQualityWarningPreferences.Keys.highISOThreshold)
        defaults.set(0, forKey: CameraQualityWarningPreferences.Keys.slowShutterThreshold)
        defaults.set(101, forKey: CameraQualityWarningPreferences.Keys.clippingPercentageThreshold)

        let preferences = CameraQualityWarningPreferences.load(from: defaults)

        XCTAssertEqual(
            preferences.highISOThreshold,
            CameraQualityWarningPreferences.defaultHighISOThreshold
        )
        XCTAssertEqual(
            preferences.slowShutterThreshold,
            CameraQualityWarningPreferences.defaultSlowShutterThreshold,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            preferences.clippingPercentageThreshold,
            CameraQualityWarningPreferences.defaultClippingPercentageThreshold
        )
    }

    func testThresholdBoundariesProduceClearWarnings() {
        let item = photo(iso: 6_400, shutter: 1.0 / 30.0)
        let warnings = CameraQualityWarning.warnings(
            for: item,
            analysis: analysis(shadows: 10, highlights: 10),
            preferences: CameraQualityWarningPreferences()
        )

        XCTAssertEqual(
            warnings.map(\.kind),
            [.highISO, .slowShutter, .highlightClipping, .shadowClipping]
        )
        XCTAssertEqual(
            warnings[0].detail,
            "ISO 6400 (warning at ISO 6400 or above)"
        )
        XCTAssertEqual(
            warnings[1].detail,
            "1/30s (warning at 1/30s or slower)"
        )
        XCTAssertEqual(
            warnings[2].detail,
            "10% near white (warning at 10% or more)"
        )
        XCTAssertTrue(
            warnings[2].accessibilityLabel.contains("Rendered image estimate")
        )
        XCTAssertEqual(
            warnings[2].source,
            .histogram(.renderedPreview)
        )
    }

    func testCustomThresholdsAndMissingOrInvalidMetadataAreHandledSafely() {
        let preferences = CameraQualityWarningPreferences(
            highISOThreshold: 3_200,
            slowShutterThreshold: 1.0 / 60.0,
            clippingPercentageThreshold: 5
        )
        let belowThreshold = photo(iso: 3_199, shutter: 1.0 / 125.0)
        XCTAssertEqual(
            CameraQualityWarning.warnings(
                for: belowThreshold,
                analysis: analysis(shadows: 4, highlights: 5),
                preferences: preferences
            ).map(\.kind),
            [.highlightClipping]
        )

        let invalid = photo(iso: .nan, shutter: 0)
        XCTAssertTrue(
            CameraQualityWarning.warnings(
                for: invalid,
                analysis: nil,
                preferences: preferences
            ).isEmpty
        )
    }

    func testGroupedRawJPEGUsesDisplayedPrimaryPhoto() {
        let paired = PhotoItem(
            id: "capture.NEF",
            primaryURL: URL(fileURLWithPath: "/tmp/capture.NEF"),
            pairedURL: URL(fileURLWithPath: "/tmp/capture.JPG"),
            captureDate: nil,
            cameraModel: "Camera",
            lensModel: nil,
            shutterSpeed: 1.0 / 125.0,
            iso: 12_800,
            fileSize: 1,
            pairedFileSize: 1
        )

        let warnings = CameraQualityWarning.warnings(
            for: paired,
            analysis: analysis(shadows: 0, highlights: 0),
            preferences: CameraQualityWarningPreferences()
        )

        XCTAssertEqual(paired.fileTypeLabel, "RAW + JPEG")
        XCTAssertEqual(warnings.map(\.kind), [.highISO])
        XCTAssertEqual(warnings.first?.measuredValue, 12_800)
    }

    func testRawClippingUsesRawSourceWithoutDuplicateRenderedWarnings() {
        let warnings = CameraQualityWarning.warnings(
            for: photo(iso: nil, shutter: nil),
            analysis: analysis(shadows: 12, highlights: 15),
            analysisSource: .rawDecode,
            preferences: CameraQualityWarningPreferences()
        )

        XCTAssertEqual(
            warnings.map(\.kind),
            [.highlightClipping, .shadowClipping]
        )
        XCTAssertEqual(
            warnings.map(\.source),
            [.histogram(.rawDecode), .histogram(.rawDecode)]
        )
        XCTAssertTrue(
            warnings[0].accessibilityLabel.contains("scaled Core Image decode")
        )
    }

    func testVideoAndDisabledCuesStayNonBlocking() {
        let video = PhotoItem(
            id: "clip.MOV",
            primaryURL: URL(fileURLWithPath: "/tmp/clip.MOV"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            shutterSpeed: 1,
            iso: 25_600,
            mediaKind: .video,
            duration: 1,
            videoIsPlayable: true,
            fileSize: 1
        )

        XCTAssertTrue(
            CameraQualityWarning.warnings(
                for: video,
                analysis: analysis(shadows: 100, highlights: 100),
                preferences: CameraQualityWarningPreferences()
            ).isEmpty
        )
        XCTAssertTrue(
            CameraQualityWarning.warnings(
                for: photo(iso: 25_600, shutter: 1),
                analysis: analysis(shadows: 100, highlights: 100),
                preferences: CameraQualityWarningPreferences(isEnabled: false)
            ).isEmpty
        )
    }

    func testArbitraryCustomThresholdsAndIndependentEnabledFlagsPersist() {
        let saved = CameraQualityWarningPreferences(
            isHighISOEnabled: false,
            isSlowShutterEnabled: true,
            isClippingEnabled: false,
            highISOThreshold: 7_250,
            slowShutterThreshold: 1.0 / 83.5,
            clippingPercentageThreshold: 12.75
        )
        saved.save(to: defaults)
        XCTAssertEqual(CameraQualityWarningPreferences.load(from: defaults), saved)
        XCTAssertEqual(defaults.double(forKey: CameraQualityWarningPreferences.Keys.highISOThreshold), 7_250)
        XCTAssertEqual(defaults.double(forKey: CameraQualityWarningPreferences.Keys.clippingPercentageThreshold), 12.75)
    }

    func testLegacyThresholdsKeepAllIndividualCuesEnabled() {
        defaults.set(7_250, forKey: CameraQualityWarningPreferences.Keys.highISOThreshold)
        defaults.set(2.5, forKey: CameraQualityWarningPreferences.Keys.slowShutterThreshold)
        defaults.set(12.75, forKey: CameraQualityWarningPreferences.Keys.clippingPercentageThreshold)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isEnabled)
        let loaded = CameraQualityWarningPreferences.load(from: defaults)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertTrue(loaded.isHighISOEnabled)
        XCTAssertTrue(loaded.isSlowShutterEnabled)
        XCTAssertTrue(loaded.isClippingEnabled)
        XCTAssertEqual(loaded.highISOThreshold, 7_250)
        XCTAssertEqual(loaded.slowShutterThreshold, 2.5)
        XCTAssertEqual(loaded.clippingPercentageThreshold, 12.75)
    }

    func testDisablingEachCueLeavesOtherWarningsAndThresholdsIntact() {
        let item = photo(iso: 25_600, shutter: 3)
        let histogram = analysis(shadows: 20, highlights: 25)
        let enabled = CameraQualityWarningPreferences(
            highISOThreshold: 7_250,
            slowShutterThreshold: 2.5,
            clippingPercentageThreshold: 12.75
        )
        for cue in [CameraQualityThresholdInput.highISO, .slowShutter, .clipping] {
            var preferences = enabled
            let expected: [CameraQualityWarning.Kind]
            switch cue {
            case .highISO:
                preferences.isHighISOEnabled = false
                expected = [.slowShutter, .highlightClipping, .shadowClipping]
            case .slowShutter:
                preferences.isSlowShutterEnabled = false
                expected = [.highISO, .highlightClipping, .shadowClipping]
            case .clipping:
                preferences.isClippingEnabled = false
                expected = [.highISO, .slowShutter]
            }
            preferences.save(to: defaults)
            let loaded = CameraQualityWarningPreferences.load(from: defaults)
            XCTAssertEqual(loaded.highISOThreshold, enabled.highISOThreshold)
            XCTAssertEqual(loaded.slowShutterThreshold, enabled.slowShutterThreshold)
            XCTAssertEqual(loaded.clippingPercentageThreshold, enabled.clippingPercentageThreshold)
            XCTAssertEqual(CameraQualityWarning.warnings(
                for: item, analysis: histogram, preferences: loaded
            ).map(\.kind), expected)
        }
    }

    func testAllIndividualCuesCanBeDisabledAndRestored() {
        let item = photo(iso: 25_600, shutter: 3)
        let histogram = analysis(shadows: 20, highlights: 25)
        let disabled = CameraQualityWarningPreferences(
            isHighISOEnabled: false, isSlowShutterEnabled: false, isClippingEnabled: false
        )
        XCTAssertTrue(CameraQualityWarning.warnings(
            for: item, analysis: histogram, preferences: disabled
        ).isEmpty)
        CameraQualityWarningPreferences().save(to: defaults)
        XCTAssertEqual(CameraQualityWarning.warnings(
            for: item, analysis: histogram,
            preferences: CameraQualityWarningPreferences.load(from: defaults)
        ).count, 4)
    }

    func testShutterInputAcceptsFractionsAndSecondsWithoutRounding() throws {
        let input = CameraQualityThresholdInput.slowShutter
        let english = Locale(identifier: "en_US")
        for (text, expected) in [
            ("1/80", 1.0 / 80), ("1 / 83.5", 1.0 / 83.5),
            ("0.3", 0.3), ("2.5", 2.5), ("60", 60), ("1/8000", 1.0 / 8_000),
        ] {
            XCTAssertEqual(try XCTUnwrap(input.parse(text, locale: english)), expected)
            XCTAssertEqual(
                try XCTUnwrap(input.parse(input.format(expected, locale: english), locale: english)),
                expected,
                "formatting must preserve the exact stored threshold"
            )
        }
        XCTAssertEqual(input.format(1.0 / 80, locale: english), "1/80")
        XCTAssertEqual(input.format(1.0 / 83.5, locale: english), "1/83.5")
        XCTAssertEqual(input.format(0.3, locale: english), "0.3")
        XCTAssertEqual(input.format(2.5, locale: english), "2.5")
    }

    func testLocaleDecimalInputAndGroupedISOAreStrict() throws {
        let danish = Locale(identifier: "da_DK")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(try XCTUnwrap(CameraQualityThresholdInput.highISO.parse("7,250", locale: english)), 7_250)
        XCTAssertEqual(try XCTUnwrap(CameraQualityThresholdInput.highISO.parse("7.250", locale: danish)), 7_250)
        XCTAssertEqual(try XCTUnwrap(CameraQualityThresholdInput.slowShutter.parse("2,5", locale: danish)), 2.5)
        XCTAssertEqual(try XCTUnwrap(CameraQualityThresholdInput.slowShutter.parse("0.3", locale: danish)), 0.3)
        XCTAssertEqual(try XCTUnwrap(CameraQualityThresholdInput.slowShutter.parse("1/83,5", locale: danish)), 1.0 / 83.5)
        XCTAssertEqual(try XCTUnwrap(CameraQualityThresholdInput.clipping.parse("12,75", locale: danish)), 12.75)
        XCTAssertEqual(CameraQualityThresholdInput.clipping.format(12.75, locale: danish), "12,75")
        XCTAssertNil(CameraQualityThresholdInput.highISO.parse("7,25", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.clipping.parse("12,75", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.clipping.parse("12,7.5", locale: danish))
    }

    func testThresholdInputRejectsPartialInvalidAndNonfiniteValues() {
        let english = Locale(identifier: "en_US")
        let commonInvalid = ["", " ", ".", "nan", "NaN", "inf", "Infinity", "0", "-1", "10abc", "1.2.3", "1/", "/30", "1/0", "1/2/3"]
        for input in [CameraQualityThresholdInput.highISO, .slowShutter, .clipping] {
            for text in commonInvalid {
                XCTAssertNil(input.parse(text, locale: english), "\(input) accepted \(text)")
            }
            XCTAssertNil(input.validValue(.nan))
            XCTAssertNil(input.validValue(.infinity))
            XCTAssertNil(input.validValue(-.infinity))
        }
        XCTAssertNil(CameraQualityThresholdInput.highISO.parse("99", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.highISO.parse("1000001", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.slowShutter.parse("1/8001", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.slowShutter.parse("60.1", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.clipping.parse("0.09", locale: english))
        XCTAssertNil(CameraQualityThresholdInput.clipping.parse("100.1", locale: english))
    }

    func testInfoDetailsPreserveCustomThresholdPrecisionInCurrentLocale() {
        let warnings = CameraQualityWarning.warnings(
            for: photo(iso: 20_000, shutter: 1),
            analysis: analysis(shadows: 20, highlights: 25),
            preferences: CameraQualityWarningPreferences(
                highISOThreshold: 12_500.5,
                slowShutterThreshold: 0.3,
                clippingPercentageThreshold: 12.75
            )
        )
        let decimal = Locale.current.decimalSeparator ?? "."
        XCTAssertEqual(warnings.map(\.detail), [
            "ISO 20000 (warning at ISO 12500\(decimal)5 or above)",
            "1s (warning at 0\(decimal)3s or slower)",
            "25% near white (warning at 12\(decimal)75% or more)",
            "20% near black (warning at 12\(decimal)75% or more)",
        ])
        let fractional = CameraQualityWarning(
            kind: .slowShutter, measuredValue: 1.0 / 30,
            threshold: 1.0 / 83.5, source: .cameraMetadata
        )
        XCTAssertEqual(fractional.detail,
            "1/30s (warning at 1/83\(decimal)5s or slower)")
    }

    func testInvalidCommitRetainsExactPreviousCustomThreshold() {
        let previous = 1.0 / 83.5
        let input = CameraQualityThresholdInput.slowShutter
        let english = Locale(identifier: "en_US")
        for draft in ["", "1/", "1/0", "nan", "-2", "2 seconds"] {
            XCTAssertEqual(input.committedValue(for: draft, previous: previous, locale: english), previous)
        }
        XCTAssertEqual(input.committedValue(for: "2.5", previous: previous, locale: english), 2.5)
    }

    private func photo(iso: Double?, shutter: Double?) -> PhotoItem {
        PhotoItem(
            id: "photo.JPG",
            primaryURL: URL(fileURLWithPath: "/tmp/photo.JPG"),
            pairedURL: nil,
            captureDate: nil,
            cameraModel: "Camera",
            lensModel: nil,
            shutterSpeed: shutter,
            iso: iso,
            fileSize: 1
        )
    }

    private func analysis(shadows: Int, highlights: Int) -> HistogramAnalysis {
        HistogramAnalysis(
            bins: Array(repeating: 0, count: 256),
            sampleCount: 100,
            shadowCount: shadows,
            highlightCount: highlights
        )
    }
}
