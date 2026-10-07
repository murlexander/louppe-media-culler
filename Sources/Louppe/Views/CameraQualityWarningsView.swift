import SwiftUI

/// One quiet metadata row that reveals exact cue values only on request. It
/// never appears in Grid cells and never changes review metadata.
struct CameraQualityCuesRow: View {
    let item: PhotoItem
    let analysis: HistogramAnalysis?
    let analysisSource: HistogramAnalysisSource
    let isRawAnalysisPending: Bool
    let preferences: CameraQualityWarningPreferences
    @State private var isPopoverPresented = false

    private var warnings: [CameraQualityWarning] {
        CameraQualityWarning.warnings(
            for: item,
            analysis: analysis,
            analysisSource: analysisSource,
            preferences: preferences
        )
    }

    var isVisible: Bool {
        !warnings.isEmpty
    }

    var body: some View {
        if !warnings.isEmpty {
            Button {
                isPopoverPresented = true
            } label: {
                HStack(spacing: 4) {
                    Text((warnings.count == 1 ? L10n.text("⚠︎ \(warnings.count) quality cue") : L10n.text("⚠︎ \(warnings.count) quality cues")))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                (warnings.count == 1 ? L10n.text("\(warnings.count) quality cue") : L10n.text("\(warnings.count) quality cues"))
            )
            .accessibilityHint(L10n.text("Show exact values and sources"))
            .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
                qualityCuesPopover
            }
        }
    }

    private var qualityCuesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Quality cues"))
                .font(.subheadline.weight(.semibold))

            ForEach(warnings) { warning in
                warningRow(warning)
            }

            if let clippingSourceDescription {
                Text(clippingSourceDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preferences.isClippingEnabled && isRawAnalysisPending {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("Checking RAW data…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var clippingSourceDescription: String? {
        warnings.first { warning in
            warning.kind == .highlightClipping
                || warning.kind == .shadowClipping
        }?.source.description
    }

    private func warningRow(_ warning: CameraQualityWarning) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(warning.title)
                .font(.callout.weight(.medium))
            Text(warning.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Source: \(warning.source.label)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(warning.accessibilityLabel)
    }
}

/// Three compact, independently optional cues; values are written only when
/// their text field commits a valid edit.
struct CameraQualityWarningsSettingsView: View {
    @AppStorage(CameraQualityWarningPreferences.Keys.isEnabled)
    private var isEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isHighISOEnabled)
    private var isHighISOEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isSlowShutterEnabled)
    private var isSlowShutterEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isClippingEnabled)
    private var isClippingEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.highISOThreshold)
    private var highISOThreshold = CameraQualityWarningPreferences.defaultHighISOThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.slowShutterThreshold)
    private var slowShutterThreshold = CameraQualityWarningPreferences.defaultSlowShutterThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.clippingPercentageThreshold)
    private var clippingPercentageThreshold = CameraQualityWarningPreferences.defaultClippingPercentageThreshold
    @State private var thresholdResetGeneration = 0

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Show quality cues"), isOn: $isEnabled)
            }

            Section {
                HStack(spacing: 10) {
                    cueToggle(L10n.text("High ISO"), isOn: $isHighISOEnabled)
                    CameraQualityThresholdField(
                        kind: .highISO, value: $highISOThreshold,
                        resetGeneration: $thresholdResetGeneration
                    )
                    .disabled(!isHighISOEnabled)
                    cueDetail(L10n.text("ISO or above"))
                }
                HStack(spacing: 10) {
                    cueToggle(L10n.text("Slow shutter"), isOn: $isSlowShutterEnabled)
                    CameraQualityThresholdField(
                        kind: .slowShutter, value: $slowShutterThreshold,
                        resetGeneration: $thresholdResetGeneration
                    )
                    .disabled(!isSlowShutterEnabled)
                    cueDetail(L10n.text("s or slower"))
                }
                HStack(spacing: 10) {
                    cueToggle(L10n.text("Clipping"), isOn: $isClippingEnabled)
                        .help(CameraQualityWarning.clippingSettingsDescription)
                    CameraQualityThresholdField(
                        kind: .clipping, value: $clippingPercentageThreshold,
                        resetGeneration: $thresholdResetGeneration
                    )
                    .disabled(!isClippingEnabled)
                    cueDetail(L10n.text("% near black or white"))
                }
            }
            .disabled(!isEnabled)

            Section {
                Button(L10n.text("Restore Quality Cue Defaults")) {
                    // Retire focused drafts before changing any values. A
                    // delayed focus-loss callback cannot restore stale text.
                    thresholdResetGeneration &+= 1
                    isEnabled = true
                    isHighISOEnabled = true
                    isSlowShutterEnabled = true
                    isClippingEnabled = true
                    highISOThreshold = CameraQualityWarningPreferences.defaultHighISOThreshold
                    slowShutterThreshold = CameraQualityWarningPreferences.defaultSlowShutterThreshold
                    clippingPercentageThreshold = CameraQualityWarningPreferences.defaultClippingPercentageThreshold
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
        .tint(Color.louppeAccent)
    }

    private func cueDetail(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cueToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .frame(width: 108, alignment: .leading)
    }
}

private struct CameraQualityThresholdField: View {
    let kind: CameraQualityThresholdInput
    @Binding var value: Double
    @Binding var resetGeneration: Int
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var draft = ""
    @State private var hasEdits = false
    @State private var observedResetGeneration = 0

    var body: some View {
        TextField("", text: Binding(
            get: { draft },
            set: { draft = $0; hasEdits = true }
        ))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 76)
        .focused($isFocused)
        .accessibilityLabel(kind.accessibilityLabel)
        .help(kind.inputHelp)
        .onAppear { refreshDraft() }
        .onSubmit { commit() }
        .onExitCommand { refreshDraft() }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { commit() }
        }
        .onChange(of: resetGeneration) { _, _ in refreshDraft() }
        .onChange(of: value) { _, _ in
            if !isFocused { refreshDraft() }
        }
        .onChange(of: locale) { _, _ in
            if !isFocused { refreshDraft() }
        }
    }

    private func commit() {
        guard observedResetGeneration == resetGeneration else {
            refreshDraft()
            return
        }
        guard hasEdits else { return }
        value = kind.committedValue(for: draft, previous: value, locale: locale)
        refreshDraft()
    }

    private func refreshDraft() {
        draft = kind.format(value, locale: locale)
        hasEdits = false
        observedResetGeneration = resetGeneration
    }
}
