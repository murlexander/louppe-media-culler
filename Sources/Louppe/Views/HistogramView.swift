import SwiftUI

/// Compact photo-only luminance inspection for the Info panel.
struct HistogramSection: View {
    let analysis: HistogramAnalysis?
    let source: HistogramAnalysisSource
    let loadFailed: Bool
    @ObservedObject var store: SessionStore

    private static let chartHeight: CGFloat = 88

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

                if analysis != nil {
                    Text(source.shortLabel)
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

            if !loadFailed {
                percentageRow
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
                    accessibilityDescription(for: analysis)
                )
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

    private var percentageRow: some View {
        HStack(spacing: 8) {
            percentage(
                L10n.text("Shadows"),
                value: analysis?.shadowPercentage
            )
            percentage(
                L10n.text("Highlights"),
                value: analysis?.highlightPercentage
            )
        }
    }

    private func percentage(_ label: String, value: Double?) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map(Self.formatPercentage) ?? "—")
                .font(.callout.weight(.medium))
                .foregroundStyle(percentageColor(value))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
                .frame(width: 24, height: 24)
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
        .help(L10n.text("Show or hide the red preview clipping overlay (X)"))
    }

    private func percentageColor(_ value: Double?) -> Color {
        value == nil ? .secondary : .primary
    }

    private static func formatPercentage(_ value: Double) -> String {
        if value == 0 { return "0%" }
        if value < 0.1 { return "<0.1%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    private func accessibilityDescription(
        for analysis: HistogramAnalysis
    ) -> String {
        L10n.text("\(source.detailLabel) luminance histogram. Shadows \(Self.formatPercentage(analysis.shadowPercentage)). Highlights \(Self.formatPercentage(analysis.highlightPercentage)).")
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
