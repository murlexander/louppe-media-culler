import Foundation

/// Small, session-only evidence index. Histograms remain in the existing
/// bounded pipeline caches; folder indexing retains counts, never bitmaps/bins.
struct QualityCueEvidence: Equatable, Sendable {
    let revision: PhotoContentRevision
    let sampleCount: Int
    let shadowCount: Int
    let highlightCount: Int
    let width: Int
    let height: Int
    let source: HistogramAnalysisSource
    let rawFallback: Bool

    init(item: PhotoItem, analysis: HistogramAnalysis?, source: HistogramAnalysisSource,
         rawFallback: Bool = false) {
        revision = item.contentRevision
        sampleCount = analysis?.sampleCount ?? 0
        shadowCount = analysis?.shadowCount ?? 0
        highlightCount = analysis?.highlightCount ?? 0
        width = analysis?.width ?? 0
        height = analysis?.height ?? 0
        self.source = source
        self.rawFallback = rawFallback
    }

    var analysis: HistogramAnalysis? {
        guard sampleCount > 0 else { return nil }
        return HistogramAnalysis(bins: [], sampleCount: sampleCount,
                                 shadowCount: shadowCount, highlightCount: highlightCount,
                                 width: width, height: height)
    }

    var coverageDescription: String {
        guard sampleCount > 0 else { return L10n.text("Image measurement unavailable. Try Rescan Folder if the file changed.") }
        let dimensions = "\(width) × \(height)"
        let counts = "\(shadowCount)/\(sampleCount); \(highlightCount)/\(sampleCount)"
        let zones = source == .rawDecode
            ? L10n.text("Linear luminance ≤ 0.002 / ≥ 0.995; Apple Default RAW decode.")
            : L10n.text("sRGB luminance 0–5 / 250–255; rendered preview.")
        return L10n.text("Whole image, scaled to \(dimensions). Near-black / near-white samples: \(counts). \(zones)")
    }

    static func measure(_ item: PhotoItem) async -> Self {
        if RawHistogramPipeline.supportsAnalysis(for: item),
           let raw = await RawHistogramPipeline.shared.analysis(for: item, purpose: .backgroundQuality) {
            return Self(item: item, analysis: raw, source: .rawDecode)
        }
        guard !Task.isCancelled else {
            return Self(item: item, analysis: nil, source: .renderedPreview)
        }
        let preview = await HistogramPipeline.shared.analysis(for: item, purpose: .backgroundQuality)
        return Self(item: item, analysis: preview, source: .renderedPreview,
                    rawFallback: item.isRaw)
    }
}

enum QualityCueStatus: Equatable, Sendable {
    case disabled, unchecked, checking, checked, partial, unavailable

    var label: String {
        switch self {
        case .disabled: return L10n.text("Quality cues disabled")
        case .unchecked: return L10n.text("Unchecked")
        case .checking: return L10n.text("Checking…")
        case .checked: return L10n.text("Checked")
        case .partial: return L10n.text("Partial coverage")
        case .unavailable: return L10n.text("Unavailable")
        }
    }

    var symbol: String {
        switch self {
        case .disabled: return "minus.circle"
        case .unchecked: return "circle.dotted"
        case .checking: return "hourglass"
        case .checked: return "checkmark.circle"
        case .partial: return "circle.lefthalf.filled"
        case .unavailable: return "questionmark.circle"
        }
    }
}
