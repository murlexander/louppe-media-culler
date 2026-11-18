import SwiftUI

/// Matching cues and their values, shared by Info and tile popovers.
struct QualityCueDetailsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var cuePublication: QualityCuePublication
    let item: PhotoItem
    var showsInspectionAction = false

    init(store: SessionStore, item: PhotoItem, showsInspectionAction: Bool = false) {
        self.store = store
        cuePublication = store.qualityCuePublication
        self.item = item
        self.showsInspectionAction = showsInspectionAction
    }

    var body: some View {
        let cues = store.qualityCues(for: item)
        if !cues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Quality cues"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(cues) { cue in
                    HStack(alignment: .firstTextBaseline) {
                        Label(cue.title, systemImage: cue.kind.symbol)
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 8)
                        Text(cue.compactValue).font(.callout.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
                if showsInspectionAction {
                    Button(L10n.text("Inspect in Info")) {
                        guard let index = store.items.firstIndex(where: { $0.contentRevision == item.contentRevision }) else { return }
                        store.setIndex(index)
                        store.showMetadataPanel = true
                    }
                    .buttonStyle(.borderless)
                }
            }
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
        }
    }
}

struct QualityCueTileIcons: View {
    @ObservedObject var store: SessionStore
    /// Measured evidence publishes here; the store publishes everything else.
    @ObservedObject private var cuePublication: QualityCuePublication
    let item: PhotoItem
    /// Browser wraps the icons to the width its badge layout offers.
    var wraps = false
    @State private var showsDetails = false

    init(store: SessionStore, item: PhotoItem, wraps: Bool = false) {
        self.store = store
        cuePublication = store.qualityCuePublication
        self.item = item
        self.wraps = wraps
    }

    var body: some View {
        let cues = store.qualityCues(for: item)
        Group {
            if !cues.isEmpty {
                Button { showsDetails = true } label: {
                    QualityCueIconRow(symbols: cues.map(\.kind.symbol), wraps: wraps)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(cues.map { "\($0.title): \($0.compactValue)" }.joined(separator: "\n"))
                .accessibilityLabel(L10n.text("Quality cues for \(item.displayName)"))
                .accessibilityValue(cues.map { "\($0.title): \($0.compactValue)" }.joined(separator: ", "))
                .popover(isPresented: $showsDetails) {
                    QualityCueDetailsView(store: store, item: item, showsInspectionAction: true)
                        .padding(14).frame(width: 300)
                        .louppePopoverSurface()
                }
            }
        }
        .onAppear { store.prioritizeQualityCues(for: item) }
    }
}

/// The cue icons and their 36-point target. `wraps` flows them onto more
/// rows within the offered width (Browser); otherwise one row (Grid).
struct QualityCueIconRow: View {
    let symbols: [String]
    var wraps = false

    var body: some View {
        Group {
            if wraps {
                CueIconFlowLayout { icons }
            } else {
                HStack(spacing: TileBadgeLayout.spacing) { icons }
            }
        }
        .font(.system(size: TileBadgeLayout.iconSize, weight: .medium))
        .frame(minWidth: 36, minHeight: TileBadgeLayout.cueTargetHeight, alignment: .bottomLeading)
        .contentShape(Rectangle())
    }

    private var icons: some View {
        ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
            Image(systemName: symbol)
                .frame(width: TileBadgeLayout.height, height: TileBadgeLayout.height)
                .mediaBadgeBackdrop(Circle(), role: .glyph)
                .accessibilityHidden(true)
        }
    }
}

/// Equal badge-sized icons in leading-aligned rows that fit the proposed width.
private struct CueIconFlowLayout: Layout {
    private func columns(_ width: CGFloat?, count: Int) -> Int {
        let step = TileBadgeLayout.height + TileBadgeLayout.spacing
        guard let width, width.isFinite else { return max(1, count) }
        return max(1, min(count, Int((width + TileBadgeLayout.spacing) / step)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let columns = columns(proposal.width, count: subviews.count)
        let rows = (subviews.count + columns - 1) / columns
        let step = TileBadgeLayout.height + TileBadgeLayout.spacing
        return CGSize(width: CGFloat(columns) * step - TileBadgeLayout.spacing,
                      height: CGFloat(rows) * step - TileBadgeLayout.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(bounds.width, count: subviews.count)
        let step = TileBadgeLayout.height + TileBadgeLayout.spacing
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * step,
                                      y: bounds.minY + CGFloat(index / columns) * step),
                          anchor: .topLeading, proposal: ProposedViewSize(width: TileBadgeLayout.height,
                                                                         height: TileBadgeLayout.height))
        }
    }
}

/// Filter's progress line for the background cue walk.
struct QualityCueCoverageText: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var cuePublication: QualityCuePublication

    init(store: SessionStore) {
        self.store = store
        cuePublication = store.qualityCuePublication
    }

    var body: some View {
        Text(store.qualityCueCoverageSummary)
    }
}

/// Info's divider beside the cue rows, which appear while Info is open.
struct QualityCueDivider: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var cuePublication: QualityCuePublication
    let item: PhotoItem

    init(store: SessionStore, item: PhotoItem) {
        self.store = store
        cuePublication = store.qualityCuePublication
        self.item = item
    }

    var body: some View {
        if !store.qualityCues(for: item).isEmpty { Divider() }
    }
}

/// Four compact, independently optional cues; values are written only when
/// their text field commits a valid edit.
struct CameraQualityWarningsSettingsView: View {
    @AppStorage(CameraQualityWarningPreferences.Keys.isEnabled)
    private var isEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isHighISOEnabled)
    private var isHighISOEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isSlowShutterEnabled)
    private var isSlowShutterEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
    private var isHighlightClippingEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
    private var isShadowClippingEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.highISOThreshold)
    private var highISOThreshold = CameraQualityWarningPreferences.defaultHighISOThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.slowShutterThreshold)
    private var slowShutterThreshold = CameraQualityWarningPreferences.defaultSlowShutterThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.highlightPercentageThreshold)
    private var highlightPercentageThreshold = CameraQualityWarningPreferences.defaultClippingPercentageThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.shadowPercentageThreshold)
    private var shadowPercentageThreshold = CameraQualityWarningPreferences.defaultClippingPercentageThreshold
    @State private var highISOResetGeneration = 0
    @State private var slowShutterResetGeneration = 0
    @State private var highlightResetGeneration = 0
    @State private var shadowResetGeneration = 0

    var body: some View {
        Group {
            Section {
                Toggle(L10n.text("Show quality cues"), isOn: $isEnabled)
            } header: {
                Text(L10n.text("Quality Cues"))
            }

            Section {
                HStack(spacing: 10) {
                    cueToggle(L10n.text("High ISO"), isOn: $isHighISOEnabled)
                    CameraQualityThresholdField(
                        kind: .highISO, value: $highISOThreshold,
                        resetGeneration: $highISOResetGeneration
                    )
                    .disabled(!isHighISOEnabled)
                    cueDetail(L10n.text("ISO or above"))
                    resetButton(L10n.text("High ISO")) {
                        highISOResetGeneration &+= 1
                        highISOThreshold = CameraQualityWarningPreferences.defaultHighISOThreshold
                        isHighISOEnabled = true
                    }
                }
                HStack(spacing: 10) {
                    cueToggle(L10n.text("Slow shutter"), isOn: $isSlowShutterEnabled)
                    CameraQualityThresholdField(
                        kind: .slowShutter, value: $slowShutterThreshold,
                        resetGeneration: $slowShutterResetGeneration
                    )
                    .disabled(!isSlowShutterEnabled)
                    cueDetail(L10n.text("s or slower"))
                    resetButton(L10n.text("Slow shutter")) {
                        slowShutterResetGeneration &+= 1
                        slowShutterThreshold = CameraQualityWarningPreferences.defaultSlowShutterThreshold
                        isSlowShutterEnabled = true
                    }
                }
                HStack(spacing: 10) {
                    cueToggle(L10n.text("Near-white area"), isOn: $isHighlightClippingEnabled)
                    CameraQualityThresholdField(
                        kind: .clipping, value: $highlightPercentageThreshold,
                        resetGeneration: $highlightResetGeneration,
                        accessibilityName: L10n.text("Near-white area threshold in percent")
                    )
                    .disabled(!isHighlightClippingEnabled)
                    cueDetail(L10n.text("% or above"))
                    resetButton(L10n.text("Near-white area")) {
                        highlightResetGeneration &+= 1
                        highlightPercentageThreshold = CameraQualityWarningPreferences.defaultClippingPercentageThreshold
                        isHighlightClippingEnabled = true
                    }
                }
                HStack(spacing: 10) {
                    cueToggle(L10n.text("Near-black area"), isOn: $isShadowClippingEnabled)
                    CameraQualityThresholdField(
                        kind: .clipping, value: $shadowPercentageThreshold,
                        resetGeneration: $shadowResetGeneration,
                        accessibilityName: L10n.text("Near-black area threshold in percent")
                    )
                    .disabled(!isShadowClippingEnabled)
                    cueDetail(L10n.text("% or above"))
                    resetButton(L10n.text("Near-black area")) {
                        shadowResetGeneration &+= 1
                        shadowPercentageThreshold = CameraQualityWarningPreferences.defaultClippingPercentageThreshold
                        isShadowClippingEnabled = true
                    }
                }
            }
            .disabled(!isEnabled)

        }
        .tint(Color.louppeAccent)
    }

    private func resetButton(_ title: String, action: @escaping () -> Void) -> some View {
        ShortcutAccessoryButton(
            symbol: "arrow.counterclockwise",
            title: L10n.text("Restore defaults for \(title)"),
            action: action
        )
        .help(L10n.text("Restore defaults for \(title)"))
    }

    private func cueDetail(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cueToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(LouppeToggleStyle(.checkbox))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 148, alignment: .leading)
    }
}

struct CameraQualityThresholdField: View {
    let kind: CameraQualityThresholdInput
    @Binding var value: Double
    @Binding var resetGeneration: Int
    var accessibilityName: String? = nil
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
        .accessibilityLabel(accessibilityName ?? kind.accessibilityLabel)
        .help(kind.inputHelp)
        .onAppear { refreshDraft() }
        .onSubmit { commit() }
        .onDisappear { commit() }
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
