import SwiftUI

/// Position-following loudness meters for the media currently playing. The
/// bounded PCM analysis supplies short RMS slices; playback time chooses the
/// slice, so this section behaves as a live meter instead of a whole-file
/// waveform.
struct AudioLevelsSection: View {
    let item: PhotoItem
    let analysis: AudioLevelAnalysis?
    let isLoading: Bool
    let loadFailed: Bool
    @ObservedObject var playback: VideoPlaybackController

    private var isMetering: Bool {
        playback.isPlaying && playback.represents(item)
    }

    private var normalizedPosition: Double {
        playback.normalizedPlaybackPosition(for: item.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Audio levels"))
                .font(.subheadline.weight(.semibold))

            if let analysis {
                Text(isMetering ? L10n.text("Live playback loudness") : L10n.text("Play media to monitor loudness"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(analysis.channels.enumerated()), id: \.offset) {
                    index, channel in
                    AudioLoudnessChannelRow(
                        decibels: isMetering
                            ? channel.loudnessDecibels(at: normalizedPosition)
                            : nil,
                        isMetering: isMetering,
                        label: channelLabel(
                            for: index,
                            total: analysis.channels.count
                        )
                    )
                }
            } else if isLoading {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("Preparing audio meter…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if loadFailed {
                Text(L10n.text("No readable audio track"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func channelLabel(for index: Int, total: Int) -> String {
        if total == 1 { return L10n.text("Mono") }
        return L10n.text("Channel \(index + 1)")
    }
}

private struct AudioLoudnessChannelRow: View {
    let decibels: Double?
    let isMetering: Bool
    let label: String

    private var levelLabel: String {
        guard isMetering else { return L10n.text("Paused") }
        guard let decibels else { return "−∞ dBFS" }
        let value = String(format: "%.1f", decibels)
        return L10n.text("\(value) dBFS")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(levelLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            AudioLoudnessMeter(decibels: decibels)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("\(label) live audio level"))
                .accessibilityValue(levelLabel)
                .accessibilityHint(
                    L10n.text("Green is below minus 12 dBFS, orange is minus 12 to minus 3 dBFS, and red is above minus 3 dBFS.")
                )
        }
    }
}

/// A conventional -60...0 dBFS meter. The quiet, caution, and clipping-risk
/// regions stay visible while paused; the brighter fill follows playback.
private struct AudioLoudnessMeter: View {
    let decibels: Double?

    private let minimumDecibels = -60.0
    private let orangeThreshold = -12.0
    private let redThreshold = -3.0

    private var levelFraction: CGFloat {
        guard let decibels, decibels.isFinite else { return 0 }
        return CGFloat(min(max(
            (decibels - minimumDecibels) / -minimumDecibels,
            0
        ), 1))
    }

    var body: some View {
        Canvas { context, size in
            let orangeStart = fraction(for: orangeThreshold)
            let redStart = fraction(for: redThreshold)
            let zones: [(ClosedRange<CGFloat>, Color)] = [
                (0...orangeStart, .green),
                (orangeStart...redStart, .orange),
                (redStart...1, .red),
            ]

            for (range, color) in zones {
                fill(
                    range: range,
                    color: color.opacity(0.18),
                    size: size,
                    context: &context
                )
                let illuminatedEnd = min(range.upperBound, levelFraction)
                if illuminatedEnd > range.lowerBound {
                    fill(
                        range: range.lowerBound...illuminatedEnd,
                        color: color.opacity(0.9),
                        size: size,
                        context: &context
                    )
                }
            }

            for boundary in [orangeStart, redStart] {
                var line = Path()
                let x = boundary * size.width
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    line,
                    with: .color(Color.appBackground.opacity(0.9)),
                    lineWidth: 2
                )
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func fraction(for decibels: Double) -> CGFloat {
        CGFloat(min(max(
            (decibels - minimumDecibels) / -minimumDecibels,
            0
        ), 1))
    }

    private func fill(
        range: ClosedRange<CGFloat>,
        color: Color,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        var path = Path()
        path.addRect(CGRect(
            x: range.lowerBound * size.width,
            y: 0,
            width: max(0, range.upperBound - range.lowerBound) * size.width,
            height: size.height
        ))
        context.fill(path, with: .color(color))
    }
}

/// Whole-file waveform used in the main audio review surface. Channels remain
/// separate and the playhead follows the shared AVPlayer position.
struct AudioWaveformView: View {
    let analysis: AudioLevelAnalysis
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let channels = analysis.channels
            guard !channels.isEmpty else { return }
            let channelHeight = size.height / CGFloat(channels.count)

            for (channelIndex, channel) in channels.enumerated() {
                let centerY = (CGFloat(channelIndex) + 0.5) * channelHeight
                let amplitude = max(1, channelHeight / 2 - 7)
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: centerY))
                baseline.addLine(to: CGPoint(x: size.width, y: centerY))
                context.stroke(
                    baseline,
                    with: .color(Color.secondary.opacity(0.28)),
                    lineWidth: 1
                )

                let bins = channel.envelope
                guard !bins.isEmpty else { continue }
                let columns = min(
                    bins.count,
                    max(1, Int(size.width.rounded(.down)))
                )
                let columnWidth = size.width / CGFloat(columns)
                var waveform = Path()
                for column in 0..<columns {
                    let start = column * bins.count / columns
                    let end = max(start + 1, (column + 1) * bins.count / columns)
                    var minimum = Float.zero
                    var maximum = Float.zero
                    for bin in bins[start..<min(end, bins.count)] {
                        minimum = min(minimum, bin.minimum)
                        maximum = max(maximum, bin.maximum)
                    }
                    let x = (CGFloat(column) + 0.5) * columnWidth
                    waveform.move(to: CGPoint(
                        x: x,
                        y: centerY - CGFloat(maximum) * amplitude
                    ))
                    waveform.addLine(to: CGPoint(
                        x: x,
                        y: centerY - CGFloat(minimum) * amplitude
                    ))
                }
                context.stroke(
                    waveform,
                    with: .color(Color.louppeAccent.opacity(0.88)),
                    lineWidth: max(1, columnWidth * 0.76)
                )
            }

            var playhead = Path()
            let boundedProgress = min(max(progress, 0), 1)
            let x = CGFloat(boundedProgress) * size.width
            playhead.move(to: CGPoint(x: x, y: 0))
            playhead.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                playhead,
                with: .color(Color.primary.opacity(0.8)),
                lineWidth: 1
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Audio waveform"))
        .accessibilityValue(L10n.text("Playback position \(Int(min(max(progress, 0), 1) * 100)) percent"))
    }
}
