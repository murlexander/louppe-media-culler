import SwiftUI

enum HistogramAccessibility {
    static func value(analysis: HistogramAnalysis, source: HistogramAnalysisSource) -> String {
        let shadows = (analysis.shadowPercentage / 100).formatted(.percent.precision(.fractionLength(1)))
        let highlights = (analysis.highlightPercentage / 100).formatted(.percent.precision(.fractionLength(1)))
        return L10n.text("\(source.detailLabel). Near-black area: \(shadows). Near-white area: \(highlights).")
    }
}

/// Compact photo-only luminance inspection for the Info panel.
struct HistogramSection: View {
    @AppStorage(ReviewShortcutPreferences.preferenceKey) private var shortcutSettings = ""
    let item: PhotoItem
    let analysis: HistogramAnalysis?
    let source: HistogramAnalysisSource
    let loadFailed: Bool
    @ObservedObject var store: SessionStore

    private static let chartHeight: CGFloat = 88

    // Only RAW photos have two distinct histogram sources to identify.
    var sourceLabel: String? {
        item.isRaw && analysis != nil ? source.shortLabel : nil
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                chart
                    .frame(height: Self.chartHeight)

                if !loadFailed, store.viewMode == .gallery {
                    clippingButton
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }

                if let sourceLabel {
                    Text(sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .padding(.leading, 3)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chart: some View {
        if let analysis {
            LuminanceHistogramView(
                analysis: analysis,
                source: source
            )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    L10n.text("Luminance histogram")
                )
                .accessibilityValue(HistogramAccessibility.value(analysis: analysis, source: source))
        } else if loadFailed {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(L10n.text("Histogram unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.text("Calculating histogram"))
        }
    }

    private var clippingButton: some View {
        Button {
            store.toggleClippingWarnings()
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    store.showClippingWarnings
                        ? Color.louppeAccent
                        : Color.secondary
                )
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            store.showClippingWarnings
                ? L10n.text("Hide Preview Clipping Overlay")
                : L10n.text("Show Preview Clipping Overlay")
        )
        .accessibilityValue(
            store.showClippingWarnings ? L10n.text("On") : L10n.text("Off")
        )
        .help(clippingHelp)
    }

    private var clippingHelp: String {
        let context = ReviewShortcutContext(viewMode: store.viewMode, mediaKind: store.currentItem?.mediaKind,
                                            isPlayable: store.currentItem?.isPlayableMedia == true,
                                            canSeekVideo: store.canSeekCurrentVideo)
        let hint = ReviewShortcutPreferences.decode(shortcutSettings).hint(for: .clipping, context: context)
        return hint.isEmpty ? L10n.text("Show or hide the red preview clipping overlay")
            : L10n.text("Show or hide the red preview clipping overlay (\(hint))")
    }

}

private struct LuminanceHistogramView: View {
    let analysis: HistogramAnalysis
    let source: HistogramAnalysisSource

    var body: some View {
        Canvas { context, size in
            guard let maximum = analysis.bins.max(), maximum > 0 else {
                return
            }
            let binWidth = size.width / CGFloat(analysis.bins.count)
            var normalPath = Path()
            var warningPath = Path()
            for (index, count) in analysis.bins.enumerated() where count > 0 {
                let height = max(
                    CGFloat(count) / CGFloat(maximum) * size.height,
                    1
                )
                let rect = CGRect(
                    x: CGFloat(index) * binWidth,
                    y: size.height - height,
                    width: max(binWidth + 0.35, 0.5),
                    height: height
                )
                if index <= source.shadowBinUpperBound
                    || index >= source.highlightBinLowerBound {
                    warningPath.addRect(rect)
                } else {
                    normalPath.addRect(rect)
                }
            }
            context.fill(
                normalPath,
                with: .color(Color.secondary.opacity(0.55))
            )
            context.fill(
                warningPath,
                with: .color(Color.secondary.opacity(0.82))
            )
            context.stroke(
                Path(CGRect(
                    x: 0,
                    y: size.height - 0.5,
                    width: size.width,
                    height: 0.5
                )),
                with: .color(Color.secondary.opacity(0.35)),
                lineWidth: 0.5
            )
        }
    }
}
