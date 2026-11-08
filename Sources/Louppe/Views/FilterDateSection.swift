import SwiftUI

/// The Filter popover's "Date taken" section: a folder-wide range, whole
/// years, or individual days. Each mode keeps its own choices; switching
/// only changes which of them narrows the session.
struct FilterDateSection: View {
    @ObservedObject var store: SessionStore
    @Binding var isExpanded: Bool

    var body: some View {
        FilterDisclosureSection(title: L10n.text("Date taken"), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Picker(L10n.text("Date filter"), selection: modeBinding) {
                    Text(L10n.text("Range")).tag(DateFilterMode.range)
                    Text(L10n.text("Year")).tag(DateFilterMode.specificYears)
                    Text(L10n.text("Date")).tag(DateFilterMode.specificDates)
                }
                .pickerStyle(.segmented)
                .tint(Color.louppeFilledAccent)
                .labelsHidden()
                .fillsSegmentedWidth()
                .frame(maxWidth: .infinity)

                switch store.filter.dateMode {
                case .range:
                    rangeControls
                case .specificYears:
                    checklist(
                        values: store.availableCaptureYears,
                        label: AppDateFormat.year,
                        count: { store.captureYearCounts[$0, default: 0] },
                        excluded: \.excludedYears,
                        excludesUnknown: \.excludesUnknownYear
                    )
                case .specificDates:
                    checklist(
                        values: store.availableCaptureDates,
                        label: AppDateFormat.day,
                        count: { store.captureDateCounts[$0, default: 0] },
                        excluded: \.excludedDates,
                        excludesUnknown: \.excludesUnknownDate
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var rangeControls: some View {
        if store.captureDateRange != nil {
            DatePicker(
                L10n.text("From"),
                selection: endpointBinding(\.dateFrom),
                in: fromLimits,
                displayedComponents: .date
            )
            .accessibilityLabel(L10n.text("Date taken from"))
            DatePicker(
                L10n.text("To"),
                selection: endpointBinding(\.dateTo),
                in: toLimits,
                displayedComponents: .date
            )
            .accessibilityLabel(L10n.text("Date taken to"))
        } else {
            Text(L10n.text("This folder contains no dated items."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Select all / Clear, then each value oldest first, then undated items.
    private func checklist<Value: Hashable>(
        values: [Value],
        label: @escaping (Value) -> String,
        count: @escaping (Value) -> Int,
        excluded: WritableKeyPath<PhotoFilter, Set<Value>>,
        excludesUnknown: WritableKeyPath<PhotoFilter, Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(L10n.text("Select all")) {
                    update {
                        $0[keyPath: excluded] = []
                        $0[keyPath: excludesUnknown] = false
                    }
                }
                Button(L10n.text("Clear")) {
                    update {
                        $0[keyPath: excluded] = Set(values)
                        $0[keyPath: excludesUnknown] = true
                    }
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(values, id: \.self) { value in
                    Toggle(isOn: inclusionBinding(value, excluded)) {
                        FilterCountLabel(label: label(value), count: count(value))
                    }
                }

                if store.unknownDateCount > 0 {
                    Toggle(isOn: unknownBinding(excludesUnknown)) {
                        FilterCountLabel(label: L10n.text("Unknown date"), count: store.unknownDateCount)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    /// Every date edit recomputes the effect flag for the current mode only.
    private func update(_ change: (inout PhotoFilter) -> Void) {
        var filter = store.filter
        change(&filter)
        store.normalizeDateFilter(&filter)
        store.filter = filter
    }

    private var modeBinding: Binding<DateFilterMode> {
        Binding {
            store.filter.dateMode
        } set: { mode in
            update { $0.dateMode = mode }
        }
    }

    private func endpointBinding(_ endpoint: WritableKeyPath<PhotoFilter, Date>) -> Binding<Date> {
        Binding {
            store.filter[keyPath: endpoint]
        } set: { date in
            update { $0[keyPath: endpoint] = date }
        }
    }

    private var fromLimits: ClosedRange<Date> {
        guard let available = store.captureDateRange else {
            return store.filter.dateFrom...store.filter.dateFrom
        }
        let upper = min(max(store.filter.dateTo, available.lowerBound), available.upperBound)
        return available.lowerBound...upper
    }

    private var toLimits: ClosedRange<Date> {
        guard let available = store.captureDateRange else {
            return store.filter.dateTo...store.filter.dateTo
        }
        let lower = max(min(store.filter.dateFrom, available.upperBound), available.lowerBound)
        return lower...available.upperBound
    }

    private func inclusionBinding<Value: Hashable>(
        _ value: Value,
        _ excluded: WritableKeyPath<PhotoFilter, Set<Value>>
    ) -> Binding<Bool> {
        Binding {
            !store.filter[keyPath: excluded].contains(value)
        } set: { isIncluded in
            update {
                if isIncluded {
                    $0[keyPath: excluded].remove(value)
                } else {
                    $0[keyPath: excluded].insert(value)
                }
            }
        }
    }

    private func unknownBinding(_ excludesUnknown: WritableKeyPath<PhotoFilter, Bool>) -> Binding<Bool> {
        Binding {
            !store.filter[keyPath: excludesUnknown]
        } set: { isIncluded in
            update { $0[keyPath: excludesUnknown] = !isIncluded }
        }
    }
}

private extension View {
    /// macOS 26 lets the native segmented control share the full column
    /// equally. Earlier systems keep the control's intrinsic width.
    @ViewBuilder
    func fillsSegmentedWidth() -> some View {
        if #available(macOS 26, *) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }
}
