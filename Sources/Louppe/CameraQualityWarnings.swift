import Foundation

/// Per-app preferences for optional camera-quality cues. These live
/// in UserDefaults, deliberately separate from the folder-bound review
/// session, so changing a threshold never writes a sidecar or affects a photo.
struct CameraQualityWarningPreferences: Equatable, Sendable {
    enum Keys {
        static let isEnabled = "cameraQualityWarnings.isEnabled"
        static let isHighISOEnabled = "cameraQualityWarnings.isHighISOEnabled"
        static let isSlowShutterEnabled = "cameraQualityWarnings.isSlowShutterEnabled"
        static let isClippingEnabled = "cameraQualityWarnings.isClippingEnabled"
        static let highISOThreshold = "cameraQualityWarnings.highISOThreshold"
        static let slowShutterThreshold = "cameraQualityWarnings.slowShutterThreshold"
        static let clippingPercentageThreshold = "cameraQualityWarnings.clippingPercentageThreshold"
    }

    static let defaultHighISOThreshold = 6_400.0
    static let defaultSlowShutterThreshold = 1.0 / 30.0
    static let defaultClippingPercentageThreshold = 10.0

    var isEnabled: Bool
    var isHighISOEnabled: Bool
    var isSlowShutterEnabled: Bool
    var isClippingEnabled: Bool
    var highISOThreshold: Double
    var slowShutterThreshold: Double
    var clippingPercentageThreshold: Double

    init(
        isEnabled: Bool = true,
        isHighISOEnabled: Bool = true,
        isSlowShutterEnabled: Bool = true,
        isClippingEnabled: Bool = true,
        highISOThreshold: Double = Self.defaultHighISOThreshold,
        slowShutterThreshold: Double = Self.defaultSlowShutterThreshold,
        clippingPercentageThreshold: Double = Self.defaultClippingPercentageThreshold
    ) {
        self.isEnabled = isEnabled
        self.isHighISOEnabled = isHighISOEnabled
        self.isSlowShutterEnabled = isSlowShutterEnabled
        self.isClippingEnabled = isClippingEnabled
        self.highISOThreshold = Self.validISOThreshold(highISOThreshold)
        self.slowShutterThreshold = Self.validSlowShutterThreshold(
            slowShutterThreshold
        )
        self.clippingPercentageThreshold = Self.validClippingThreshold(
            clippingPercentageThreshold
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            isEnabled: bool(
                for: Keys.isEnabled,
                in: defaults,
                fallback: true
            ),
            isHighISOEnabled: bool(for: Keys.isHighISOEnabled, in: defaults, fallback: true),
            isSlowShutterEnabled: bool(for: Keys.isSlowShutterEnabled, in: defaults, fallback: true),
            isClippingEnabled: bool(for: Keys.isClippingEnabled, in: defaults, fallback: true),
            highISOThreshold: double(
                for: Keys.highISOThreshold,
                in: defaults,
                fallback: defaultHighISOThreshold
            ),
            slowShutterThreshold: double(
                for: Keys.slowShutterThreshold,
                in: defaults,
                fallback: defaultSlowShutterThreshold
            ),
            clippingPercentageThreshold: double(
                for: Keys.clippingPercentageThreshold,
                in: defaults,
                fallback: defaultClippingPercentageThreshold
            )
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Keys.isEnabled)
        defaults.set(isHighISOEnabled, forKey: Keys.isHighISOEnabled)
        defaults.set(isSlowShutterEnabled, forKey: Keys.isSlowShutterEnabled)
        defaults.set(isClippingEnabled, forKey: Keys.isClippingEnabled)
        defaults.set(highISOThreshold, forKey: Keys.highISOThreshold)
        defaults.set(slowShutterThreshold, forKey: Keys.slowShutterThreshold)
        defaults.set(
            clippingPercentageThreshold,
            forKey: Keys.clippingPercentageThreshold
        )
    }

    private static func bool(
        for key: String,
        in defaults: UserDefaults,
        fallback: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    private static func double(
        for key: String,
        in defaults: UserDefaults,
        fallback: Double
    ) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    private static func validISOThreshold(_ value: Double) -> Double {
        guard let value = CameraQualityThresholdInput.highISO.validValue(value)
        else { return defaultHighISOThreshold }
        return value
    }

    private static func validSlowShutterThreshold(_ value: Double) -> Double {
        guard let value = CameraQualityThresholdInput.slowShutter.validValue(value)
        else { return defaultSlowShutterThreshold }
        return value
    }

    private static func validClippingThreshold(_ value: Double) -> Double {
        guard let value = CameraQualityThresholdInput.clipping.validValue(value)
        else { return defaultClippingPercentageThreshold }
        return value
    }
}

/// Strict, locale-aware input shared by Settings and its validation tests.
/// A draft never changes the stored threshold until an explicit commit.
enum CameraQualityThresholdInput: Sendable {
    case highISO
    case slowShutter
    case clipping

    var range: ClosedRange<Double> {
        switch self {
        case .highISO: return 100...1_000_000
        case .slowShutter: return (1.0 / 8_000.0)...60
        case .clipping: return 0.1...100
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .highISO: return L10n.text("High ISO threshold")
        case .slowShutter: return L10n.text("Slow shutter threshold in seconds")
        case .clipping: return L10n.text("Clipping threshold in percent")
        }
    }

    var inputHelp: String {
        switch self {
        case .highISO: return L10n.text("ISO 100–1,000,000. Press Return to apply.")
        case .slowShutter: return L10n.text("1/8000–60 seconds. Enter a fraction such as 1/30 or seconds such as 2.5. Press Return to apply.")
        case .clipping: return L10n.text("0.1–100%. Press Return to apply.")
        }
    }

    func validValue(_ value: Double) -> Double? {
        value.isFinite && range.contains(value) ? value : nil
    }

    func parse(_ text: String, locale: Locale = .current) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let value: Double
        if self == .slowShutter, parts.count == 2 {
            guard let numerator = number(String(parts[0]), locale: locale),
                  let denominator = number(String(parts[1]), locale: locale),
                  denominator > 0 else { return nil }
            value = numerator / denominator
        } else {
            guard parts.count == 1, let parsed = number(text, locale: locale)
            else { return nil }
            value = parsed
        }
        return validValue(value)
    }

    /// Invalid or incomplete edits revert to the exact prior threshold.
    func committedValue(for text: String, previous: Double, locale: Locale = .current) -> Double {
        parse(text, locale: locale) ?? previous
    }

    func format(_ value: Double, locale: Locale = .current) -> String {
        if self == .slowShutter, value > 0, value < 1 {
            let reciprocal = 1 / value
            let denominator = (reciprocal * 1_000).rounded() / 1_000
            // Use a readable fraction only when parsing it returns the exact
            // same Double; nearby custom thresholds must never be rounded.
            if denominator.isFinite, denominator >= 1, 1 / denominator == value {
                return "1/\(decimalText(denominator, locale: locale))"
            }
        }
        return decimalText(value, locale: locale)
    }

    private func decimalText(_ value: Double, locale: Locale) -> String {
        // Double's lossless decimal description avoids NumberFormatter's
        // default precision limit. All supported thresholds fit plain decimal.
        var text = String(value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    private func number(_ text: String, locale: Locale) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let decimal = locale.decimalSeparator ?? "."
        let grouping = locale.groupingSeparator ?? ","
        // Accept grouped ISO values only when every group is complete. A
        // partially typed 6,40 must not silently become a stored ISO 640.
        if self == .highISO, grouping != decimal, value.contains(grouping) {
            let pieces = value.components(separatedBy: decimal)
            let groups = pieces[0].components(separatedBy: grouping)
            if groups.count > 1, (1...3).contains(groups[0].count),
               groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isDigit) }),
               groups.dropFirst().allSatisfy({ $0.count == 3 }) {
                value = groups.joined()
                    + (pieces.count > 1 ? decimal + pieces.dropFirst().joined(separator: decimal) : "")
            } else if grouping != "." || decimal == "." || value.contains(decimal) {
                return nil
            }
        }
        if decimal != "." {
            // A period is also accepted as a decimal separator, but never
            // combine two different decimal separators in one number.
            if value.contains(decimal), value.contains(".") { return nil }
            value = value.replacingOccurrences(of: decimal, with: ".")
        }
        guard value.allSatisfy({ Self.isDigit($0) || $0 == "." }),
              value.filter({ $0 == "." }).count <= 1,
              let result = Double(value), result.isFinite else { return nil }
        return result
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}

/// One non-blocking cue in the Info panel. The cue describes a review
/// condition; it never changes review metadata or makes a quality verdict.
struct CameraQualityWarning: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case highISO
        case slowShutter
        case highlightClipping
        case shadowClipping
    }

    static let renderedClippingSourceDescription =
        L10n.text("Rendered image estimate — measured from the displayed preview.")
    static let rawClippingSourceDescription =
        L10n.text("RAW decode — scaled Core Image decode of sensor data, not a camera-maker per-photosite histogram.")
    static let clippingSettingsDescription =
        L10n.text("Clipping cues use a scaled Core Image RAW decode when supported, otherwise a rendered-image estimate. RAW results are not camera-maker per-photosite histograms.")

    let kind: Kind
    let measuredValue: Double
    let threshold: Double
    let source: Source

    enum Source: Equatable, Sendable {
        case cameraMetadata
        case histogram(HistogramAnalysisSource)

        var label: String {
            switch self {
            case .cameraMetadata: return L10n.text("Camera metadata")
            case .histogram(let source): return source.detailLabel
            }
        }

        var description: String {
            switch self {
            case .cameraMetadata:
                return L10n.text("Camera metadata")
            case .histogram(.renderedPreview):
                return CameraQualityWarning.renderedClippingSourceDescription
            case .histogram(.rawDecode):
                return CameraQualityWarning.rawClippingSourceDescription
            }
        }
    }

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .highISO: return L10n.text("High ISO")
        case .slowShutter: return L10n.text("Slow shutter")
        case .highlightClipping: return L10n.text("Highlight clipping")
        case .shadowClipping: return L10n.text("Shadow clipping")
        }
    }

    var detail: String {
        switch kind {
        case .highISO:
            return L10n.text("ISO \(Self.iso(measuredValue)) (warning at ISO \(CameraQualityThresholdInput.highISO.format(threshold)) or above)")
        case .slowShutter:
            return L10n.text("\(Self.shutter(measuredValue)) (warning at \(CameraQualityThresholdInput.slowShutter.format(threshold))s or slower)")
        case .highlightClipping:
            return L10n.text("\(Self.percentage(measuredValue)) near white (warning at \(CameraQualityThresholdInput.clipping.format(threshold))% or more)")
        case .shadowClipping:
            return L10n.text("\(Self.percentage(measuredValue)) near black (warning at \(CameraQualityThresholdInput.clipping.format(threshold))% or more)")
        }
    }

    var accessibilityLabel: String {
        L10n.text("\(title). \(detail). Source: \(source.description). Review cue only.")
    }

    static func warnings(
        for item: PhotoItem,
        analysis: HistogramAnalysis?,
        analysisSource: HistogramAnalysisSource = .renderedPreview,
        preferences: CameraQualityWarningPreferences
    ) -> [Self] {
        guard preferences.isEnabled, item.mediaKind == .photo else { return [] }
        var warnings: [Self] = []

        // A paired projection has one displayed primary file (the RAW when an
        // unambiguous RAW+JPEG match is grouped). Its metadata and its
        // content-keyed luminance analysis are the only correct source here.
        if preferences.isHighISOEnabled,
           let iso = MediaNumeric.iso(item.iso), iso >= preferences.highISOThreshold {
            warnings.append(
                Self(
                    kind: .highISO,
                    measuredValue: iso,
                    threshold: preferences.highISOThreshold,
                    source: .cameraMetadata
                )
            )
        }
        if preferences.isSlowShutterEnabled,
           let shutter = MediaNumeric.shutterSpeed(item.shutterSpeed),
           shutter >= preferences.slowShutterThreshold {
            warnings.append(
                Self(
                    kind: .slowShutter,
                    measuredValue: shutter,
                    threshold: preferences.slowShutterThreshold,
                    source: .cameraMetadata
                )
            )
        }
        if preferences.isClippingEnabled, let analysis {
            if analysis.highlightPercentage >= preferences.clippingPercentageThreshold {
                warnings.append(
                    Self(
                        kind: .highlightClipping,
                        measuredValue: analysis.highlightPercentage,
                        threshold: preferences.clippingPercentageThreshold,
                        source: .histogram(analysisSource)
                    )
                )
            }
            if analysis.shadowPercentage >= preferences.clippingPercentageThreshold {
                warnings.append(
                    Self(
                        kind: .shadowClipping,
                        measuredValue: analysis.shadowPercentage,
                        threshold: preferences.clippingPercentageThreshold,
                        source: .histogram(analysisSource)
                    )
                )
            }
        }
        return warnings
    }

    private static func iso(_ value: Double) -> String {
        MetadataFormat.iso(value)
    }

    private static func shutter(_ value: Double) -> String {
        let formatted = MetadataFormat.shutter(value)
        return formatted.hasSuffix("s") ? formatted : "\(formatted)s"
    }

    private static func percentage(_ value: Double) -> String {
        if value == 0 { return "0%" }
        if value < 0.1 { return "<0.1%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }
}
