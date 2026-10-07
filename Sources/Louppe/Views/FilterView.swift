import SwiftUI

/// Only explicitly edited endpoints are parsed from their rounded display.
/// Untouched endpoints keep the exact filter value; opening/closing is a no-op.
enum NumericFilterRangeDraft {
    static func resolve(
        available: ClosedRange<Double>,
        currentFrom: Double, currentTo: Double, isEnabled: Bool,
        fromText: String, toText: String,
        editedFrom: Bool, editedTo: Bool,
        parse: (String) -> Double?,
        snap: (Double, Double) -> Double
    ) -> (from: Double, to: Double)? {
        guard editedFrom || editedTo else { return nil }
        let from: Double
        let to: Double
        if editedFrom {
            guard let parsed = parse(fromText) else { return nil }
            from = snap(parsed, available.lowerBound)
        } else {
            from = isEnabled ? currentFrom : available.lowerBound
        }
        if editedTo {
            guard let parsed = parse(toText) else { return nil }
            to = snap(parsed, available.upperBound)
        } else {
            to = isEnabled ? currentTo : available.upperBound
        }
        guard from.isFinite, to.isFinite, from <= to else { return nil }
        return (from, to)
    }
}


/// The toolbar filter popover. Metadata is cached during scanning, so every
/// control below only filters in-memory `PhotoItem` values.
struct FilterView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var decisionExpanded = false
    @State private var starsExpanded = false
    @State private var colorExpanded = false
    @State private var dateExpanded = false
    @State private var mediaExpanded = false
    @State private var durationExpanded = false
    @State private var videoDetailsExpanded = false
    @State private var cameraSettingsExpanded = false
    @State private var subfoldersExpanded = false
    @State private var fileTypesExpanded = false
    @State private var camerasExpanded = false
    @State private var lensesExpanded = false

    @State private var apertureFromText = ""
    @State private var apertureToText = ""
    @State private var shutterFromText = ""
    @State private var shutterToText = ""
    @State private var isoFromText = ""
    @State private var isoToText = ""
    @State private var durationFromText = ""
    @State private var durationToText = ""
    @State private var videoFrameRateFromText = ""
    @State private var videoFrameRateToText = ""
    @State private var settingCommitTask: Task<Void, Never>?
    @State private var editedSettingFields: Set<SettingField> = []
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedSettingField: SettingField?

    private enum SettingField: Hashable {
        case apertureFrom, apertureTo
        case shutterFrom, shutterTo
        case isoFrom, isoTo
        case durationFrom, durationTo
        case videoFrameRateFrom, videoFrameRateTo

        var accessibilityLabel: String {
            switch self {
            case .apertureFrom: return L10n.text("Minimum aperture")
            case .apertureTo: return L10n.text("Maximum aperture")
            case .shutterFrom: return L10n.text("Minimum shutter speed")
            case .shutterTo: return L10n.text("Maximum shutter speed")
            case .isoFrom: return L10n.text("Minimum ISO")
            case .isoTo: return L10n.text("Maximum ISO")
            case .durationFrom: return L10n.text("Minimum media duration")
            case .durationTo: return L10n.text("Maximum media duration")
            case .videoFrameRateFrom: return L10n.text("Minimum video frame rate")
            case .videoFrameRateTo: return L10n.text("Maximum video frame rate")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Filter"))
                .font(.headline)
            searchField
            quickDecisionFilter
            if store.rawJPEGPairCount > 0 {
                rawJPEGPairingToggle
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    dateSection
                    Divider()
                    decisionSection
                    Divider()
                    starsSection
                    Divider()
                    colorSection

                    if store.availableMediaKinds.count > 1 {
                        Divider()
                        mediaSection
                    }

                    if store.durationRange != nil {
                        Divider()
                        durationSection
                    }

                    if !store.availableVideoResolutions.isEmpty
                        || !store.availableVideoCodecs.isEmpty
                        || store.videoFrameRateRange != nil {
                        Divider()
                        videoDetailsSection
                    }

                    Divider()
                    fileTypesSection

                    if store.availableSubfolders.count > 1 {
                        Divider()
                        subfoldersSection
                    }

                    if store.availableCameras.count > 1 {
                        Divider()
                        camerasSection
                    }

                    if store.availableLenses.count > 1 {
                        Divider()
                        lensesSection
                    }

                    if store.apertureRange != nil || store.shutterRange != nil || store.isoRange != nil {
                        Divider()
                        cameraSettingsSection
                    }
                }
                .padding(.trailing, 5)
            }

            Divider()
            footer
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 340, height: 560)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
        .onAppear {
            syncAllSettingDrafts()
            if store.takeFilterSearchFocusRequest() {
                isSearchFocused = true
            }
        }
        .onDisappear {
            settingCommitTask?.cancel()
            settingCommitTask = nil
            commitAllSettingDrafts()
        }
        .onChange(of: focusedSettingField) { previous, current in
            if let previous, previous != current {
                restoreInvalidDraft(for: previous)
            }
        }
    }

    // MARK: - Review metadata

    /// These four shortcuts change only the Decision facet. A narrower date,
    /// search, or other choice stays in place until the full filter is reset.
    private var quickDecisionFilter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Decision"))
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 5) {
                quickDecisionButton(L10n.text("All"), included: nil)
                quickDecisionButton(L10n.text("Undecided"), included: .undecided)
                quickDecisionButton(L10n.text("Yes"), included: .yes)
                quickDecisionButton(L10n.text("No"), included: .no)
            }
            Text(L10n.text("All shows every decision; other filters still apply."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func quickDecisionButton(
        _ title: String,
        included: PhotoItemRatingState?
    ) -> some View {
        let states: Set<PhotoItemRatingState> = [.yes, .no, .undecided, .mixed]
        let exclusions: Set<PhotoItemRatingState>
        if included == .undecided {
            // Mixed RAW/JPEG decisions still need review and belong in the
            // same quick bucket as undecided photos.
            exclusions = [.yes, .no]
        } else {
            exclusions = included.map { states.subtracting([$0]) } ?? []
        }
        return Button(title) {
            var filter = store.filter
            filter.excludedDecisionStates = exclusions
            store.filter = filter
        }
        .buttonStyle(.bordered)
        .tint(store.filter.excludedDecisionStates == exclusions
            ? Color.louppeAccent : Color.primary)
        .controlSize(.small)
        .accessibilityLabel(included == nil ? L10n.text("All decisions") : "\(title) decisions")
        .accessibilityAddTraits(store.filter.excludedDecisionStates == exclusions ? .isSelected : [])
    }

    private var decisionSection: some View {
        FilterDisclosureSection(title: L10n.text("Decision details"), isExpanded: $decisionExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                metadataToggle(
                    L10n.text("Yes"),
                    count: store.yesCount,
                    value: PhotoItemRatingState.yes,
                    set: \.excludedDecisionStates
                )
                metadataToggle(
                    L10n.text("No"),
                    count: store.noCount,
                    value: PhotoItemRatingState.no,
                    set: \.excludedDecisionStates
                )
                metadataToggle(
                    L10n.text("Undecided"),
                    count: store.plainUndecidedCount,
                    value: PhotoItemRatingState.undecided,
                    set: \.excludedDecisionStates
                )
                metadataToggle(
                    L10n.text("Mixed"),
                    count: store.mixedCount,
                    value: PhotoItemRatingState.mixed,
                    set: \.excludedDecisionStates
                )
            }
        }
    }

    private var starsSection: some View {
        FilterDisclosureSection(title: L10n.text("Star rating"), isExpanded: $starsExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                metadataToggle(
                    L10n.text("Unrated"),
                    count: store.unratedStarCount,
                    value: PhotoItemStarRatingState.unrated,
                    set: \.excludedStarStates
                )
                ForEach(StarRating.allCases, id: \.self) { rating in
                    metadataToggle(
                        rating == .one ? L10n.text("1 star") : "\(rating.count) stars",
                        count: store.starCount(rating),
                        value: PhotoItemStarRatingState.stars(rating),
                        set: \.excludedStarStates
                    )
                }
                metadataToggle(
                    L10n.text("Mixed"),
                    count: store.mixedStarCount,
                    value: PhotoItemStarRatingState.mixed,
                    set: \.excludedStarStates
                )
            }
        }
    }

    private var colorSection: some View {
        FilterDisclosureSection(title: L10n.text("Color label"), isExpanded: $colorExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                metadataToggle(
                    L10n.text("None"),
                    count: store.noColorCount,
                    value: PhotoItemColorLabelState.none,
                    set: \.excludedColorStates
                )
                ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                    Toggle(
                        isOn: metadataExclusionBinding(
                            PhotoItemColorLabelState.label(label),
                            \.excludedColorStates
                        )
                    ) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(label.swatchColor)
                                .frame(width: 10, height: 10)
                            labeledCount(label.localizedDisplayName, store.colorCount(label))
                        }
                    }
                }
                metadataToggle(
                    L10n.text("Mixed"),
                    count: store.mixedColorCount,
                    value: PhotoItemColorLabelState.mixed,
                    set: \.excludedColorStates
                )
            }
        }
    }

    private func metadataToggle<Value: Hashable>(
        _ label: String,
        count: Int,
        value: Value,
        set: WritableKeyPath<PhotoFilter, Set<Value>>
    ) -> some View {
        Toggle(isOn: metadataExclusionBinding(value, set)) {
            labeledCount(label, count)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.text("Search name, type, camera, lens…"), text: $store.filter.searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityLabel(L10n.text("Search media"))
            if !store.filter.searchText.isEmpty {
                Button {
                    store.filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Clear Search"))
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(contrast == .increased ? Color.primary : Color.clear, lineWidth: 1)
        }
    }

    // MARK: - Date

    private var dateSection: some View {
        FilterDisclosureSection(title: L10n.text("Date taken"), isExpanded: $dateExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Picker(L10n.text("Date filter"), selection: dateModeBinding) {
                    Text(L10n.text("Range")).tag(DateFilterMode.range)
                    Text(L10n.text("Specific dates")).tag(DateFilterMode.specificDates)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if store.filter.dateMode == .range {
                    if store.captureDateRange != nil {
                        DatePicker(
                            L10n.text("From"),
                            selection: dateFromBinding,
                            in: dateFromLimits,
                            displayedComponents: .date
                        )
                        .accessibilityLabel(L10n.text("Date taken from"))
                        DatePicker(
                            L10n.text("To"),
                            selection: dateToBinding,
                            in: dateToLimits,
                            displayedComponents: .date
                        )
                        .accessibilityLabel(L10n.text("Date taken to"))
                    } else {
                        Text(L10n.text("This folder contains no dated items."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Button(L10n.text("Select all"), action: selectAllDates)
                            Button(L10n.text("Clear"), action: clearAllDates)
                            Spacer()
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)

                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(store.availableCaptureDates, id: \.self) { date in
                                Toggle(isOn: dateBinding(date)) {
                                    labeledCount(
                                        AppDateFormat.day(date),
                                        store.captureDateCounts[date, default: 0]
                                    )
                                }
                            }

                            if store.unknownDateCount > 0 {
                                Toggle(isOn: unknownDateBinding) {
                                    labeledCount(L10n.text("Unknown date"), store.unknownDateCount)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Media

    private var mediaSection: some View {
        FilterDisclosureSection(title: L10n.text("Media"), isExpanded: $mediaExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableMediaKinds, id: \.self) { kind in
                    Toggle(isOn: mediaKindBinding(kind)) {
                        labeledCount(kind.localizedLabel, store.mediaKindCounts[kind, default: 0])
                    }
                }
            }
        }
    }

    private var durationSection: some View {
        FilterDisclosureSection(title: L10n.text("Media duration"), isExpanded: $durationExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(L10n.text("From"))
                    validatedTextField(
                        $durationFromText,
                        field: .durationFrom,
                        width: 76,
                        invalid: !durationDraftIsValid
                    )
                    Text("to").foregroundStyle(.secondary)
                    validatedTextField(
                        $durationToText,
                        field: .durationTo,
                        width: 76,
                        invalid: !durationDraftIsValid
                    )
                }
                .padding(.leading, 20)
                Text(L10n.text("Use m:ss or h:mm:ss"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                if !durationDraftIsValid { invalidRangeMessage }
            }
            .onChange(of: durationFromText) { scheduleSettingCommit() }
            .onChange(of: durationToText) { scheduleSettingCommit() }
        }
    }

    private var videoDetailsSection: some View {
        FilterDisclosureSection(title: L10n.text("Video details"), isExpanded: $videoDetailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !store.availableVideoResolutions.isEmpty {
                    videoFacet(
                        title: L10n.text("Resolution"),
                        values: store.availableVideoResolutions,
                        counts: store.videoResolutionCounts,
                        set: \.excludedVideoResolutions
                    )
                }
                if !store.availableVideoCodecs.isEmpty {
                    videoFacet(
                        title: L10n.text("Codec"),
                        values: store.availableVideoCodecs,
                        counts: store.videoCodecCounts,
                        set: \.excludedVideoCodecs
                    )
                }
                if store.videoFrameRateRange != nil {
                    videoFrameRateSetting
                }
            }
        }
    }

    private func videoFacet(
        title: String,
        values: [String],
        counts: [String: Int],
        set: WritableKeyPath<PhotoFilter, Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
            ForEach(values, id: \.self) { value in
                Toggle(isOn: exclusionBinding(value, set)) {
                    labeledCount(value == "Unknown resolution" || value == "Unknown video codec" ? L10n.label(value) : value, counts[value, default: 0])
                }
            }
        }
    }

    private var videoFrameRateSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Frame rate"))
                .font(.callout)
            HStack(spacing: 5) {
                Text(L10n.text("From"))
                validatedTextField(
                    $videoFrameRateFromText,
                    field: .videoFrameRateFrom,
                    width: 62,
                    invalid: !videoFrameRateDraftIsValid
                )
                Text("to").foregroundStyle(.secondary)
                validatedTextField(
                    $videoFrameRateToText,
                    field: .videoFrameRateTo,
                    width: 62,
                    invalid: !videoFrameRateDraftIsValid
                )
                Text("fps").foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
            if !videoFrameRateDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: videoFrameRateFromText) { scheduleSettingCommit() }
        .onChange(of: videoFrameRateToText) { scheduleSettingCommit() }
    }

    private var cameraSettingsSection: some View {
        FilterDisclosureSection(title: L10n.text("Camera settings"), isExpanded: $cameraSettingsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if store.apertureRange != nil { apertureSetting }
                if store.shutterRange != nil { shutterSetting }
                if store.isoRange != nil { isoSetting }
            }
        }
    }

    private var apertureSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Aperture"))
            HStack(spacing: 5) {
                Text(L10n.text("From"))
                Text("f/").foregroundStyle(.secondary)
                validatedTextField($apertureFromText, field: .apertureFrom, width: 52, invalid: !apertureDraftIsValid)
                Text("to").foregroundStyle(.secondary)
                Text("f/").foregroundStyle(.secondary)
                validatedTextField($apertureToText, field: .apertureTo, width: 52, invalid: !apertureDraftIsValid)
            }
            .padding(.leading, 20)
            if !apertureDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: apertureFromText) { scheduleSettingCommit() }
        .onChange(of: apertureToText) { scheduleSettingCommit() }
    }

    private var shutterSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Shutter speed"))
            HStack(spacing: 5) {
                Text(L10n.text("From"))
                validatedTextField($shutterFromText, field: .shutterFrom, width: 72, invalid: !shutterDraftIsValid)
                Text("to").foregroundStyle(.secondary)
                validatedTextField($shutterToText, field: .shutterTo, width: 72, invalid: !shutterDraftIsValid)
            }
            .padding(.leading, 20)
            if !shutterDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: shutterFromText) { scheduleSettingCommit() }
        .onChange(of: shutterToText) { scheduleSettingCommit() }
    }

    private var isoSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ISO")
            HStack(spacing: 5) {
                Text(L10n.text("From"))
                validatedTextField($isoFromText, field: .isoFrom, width: 68, invalid: !isoDraftIsValid)
                Text("to").foregroundStyle(.secondary)
                validatedTextField($isoToText, field: .isoTo, width: 68, invalid: !isoDraftIsValid)
            }
            .padding(.leading, 20)
            if !isoDraftIsValid { invalidRangeMessage }
        }
        .onChange(of: isoFromText) { scheduleSettingCommit() }
        .onChange(of: isoToText) { scheduleSettingCommit() }
    }

    private var invalidRangeMessage: some View {
        Label(L10n.text("Enter a valid range"), systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.leading, 20)
    }

    private func validatedTextField(
        _ text: Binding<String>,
        field: SettingField,
        width: CGFloat,
        invalid: Bool
    ) -> some View {
        TextField("", text: Binding {
            text.wrappedValue
        } set: { value in
            editedSettingFields.insert(field)
            text.wrappedValue = value
        })
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focusedSettingField, equals: field)
            .accessibilityLabel(field.accessibilityLabel)
            .accessibilityHint(invalid ? L10n.text("Invalid range") : "")
            .frame(width: width)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(invalid ? Color.red : Color.clear, lineWidth: 1)
            }
    }

    // MARK: - Facet sections

    private var subfoldersSection: some View {
        FilterDisclosureSection(title: L10n.text("Subfolders"), isExpanded: $subfoldersExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableSubfolders, id: \.self) { subfolder in
                    Toggle(isOn: exclusionBinding(subfolder, \.excludedSubfolders)) {
                        labeledCount(subfolder == "None" ? L10n.text("None") : subfolder, store.subfolderCounts[subfolder, default: 0])
                    }
                }
            }
        }
    }

    private var fileTypesSection: some View {
        FilterDisclosureSection(title: L10n.text("File types"), isExpanded: $fileTypesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableTypes, id: \.self) { type in
                    Toggle(isOn: exclusionBinding(type, \.excludedTypes)) {
                        labeledCount(type, store.typeCounts[type, default: 0])
                    }
                }
            }
        }
    }

    private var rawJPEGPairingToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: rawJPEGPairingBinding) {
                HStack {
                    Text(RawJPEGPairingMode.togetherControlTitle)
                    Spacer()
                    if store.isChangingRawJPEGPairingMode {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.text("Preparing JPEG metadata"))
                    }
                }
            }
            .disabled(
                store.isChangingRawJPEGPairingMode
                    || store.isFileOperationRunning
                    || store.isXMPPublicationRunning
            )
            .accessibilityLabel(L10n.text("Treat matching RAW and JPEG as one photo"))
            .accessibilityHint(rawJPEGPairingStatus)
            .help(
                L10n.text("Ratings and item actions apply to both files, except RAW-only and JPEG-only Trash.")
            )

            Text(rawJPEGPairingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rawJPEGPairingStatus: String {
        if store.isChangingRawJPEGPairingMode {
            return L10n.text("Updating RAW + JPEG review…")
        }
        if store.isFileOperationRunning {
            return L10n.text("Available when file work finishes.")
        }
        if store.isXMPPublicationRunning {
            return L10n.text("Available when XMP work finishes.")
        }
        let count = store.rawJPEGPairCount
        if store.rawJPEGPairingMode == .together {
            return count == 1 ? L10n.text("1 matching pair reviewed together.") : L10n.text("\(count) matching pairs reviewed together.")
        }
        return count == 1 ? L10n.text("1 matching pair reviewed separately.") : L10n.text("\(count) matching pairs reviewed separately.")
    }

    private var rawJPEGPairingBinding: Binding<Bool> {
        Binding(
            get: { store.rawJPEGPairingMode == .together },
            set: { store.setRawJPEGPairingMode($0 ? .together : .separate) }
        )
    }

    private var camerasSection: some View {
        FilterDisclosureSection(title: L10n.text("Camera"), isExpanded: $camerasExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableCameras, id: \.self) { camera in
                    Toggle(isOn: exclusionBinding(camera, \.excludedCameras)) {
                        labeledCount(camera == "Unknown" ? L10n.text("Unknown") : camera, store.cameraCounts[camera, default: 0])
                    }
                }
            }
        }
    }

    private var lensesSection: some View {
        FilterDisclosureSection(title: L10n.text("Lens"), isExpanded: $lensesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.availableLenses, id: \.self) { lens in
                    Toggle(isOn: exclusionBinding(lens, \.excludedLenses)) {
                        labeledCount(lens == "Unknown" ? L10n.text("Unknown") : lens, store.lensCounts[lens, default: 0])
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.text("Showing \(store.visibleIndices.count) of \(store.items.count)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(L10n.text("Reset")) {
                focusedSettingField = nil
                store.resetFilter()
                syncAllSettingDrafts()
            }
            .disabled(!store.filterCanReset)
            Button(L10n.text("Done")) { store.isFilterPresented = false }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Filter bindings

    private var dateModeBinding: Binding<DateFilterMode> {
        Binding {
            store.filter.dateMode
        } set: { mode in
            var filter = store.filter
            filter.dateMode = mode
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var dateFromBinding: Binding<Date> {
        Binding {
            store.filter.dateFrom
        } set: { date in
            var filter = store.filter
            filter.dateFrom = date
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var dateToBinding: Binding<Date> {
        Binding {
            store.filter.dateTo
        } set: { date in
            var filter = store.filter
            filter.dateTo = date
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var dateFromLimits: ClosedRange<Date> {
        guard let available = store.captureDateRange else {
            return store.filter.dateFrom...store.filter.dateFrom
        }
        let upper = min(max(store.filter.dateTo, available.lowerBound), available.upperBound)
        return available.lowerBound...upper
    }

    private var dateToLimits: ClosedRange<Date> {
        guard let available = store.captureDateRange else {
            return store.filter.dateTo...store.filter.dateTo
        }
        let lower = max(min(store.filter.dateFrom, available.upperBound), available.lowerBound)
        return lower...available.upperBound
    }

    private func dateBinding(_ date: Date) -> Binding<Bool> {
        Binding {
            !store.filter.excludedDates.contains(date)
        } set: { isIncluded in
            var filter = store.filter
            if isIncluded {
                filter.excludedDates.remove(date)
            } else {
                filter.excludedDates.insert(date)
            }
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private var unknownDateBinding: Binding<Bool> {
        Binding {
            !store.filter.excludesUnknownDate
        } set: { isIncluded in
            var filter = store.filter
            filter.excludesUnknownDate = !isIncluded
            updateDateActivation(&filter)
            store.filter = filter
        }
    }

    private func selectAllDates() {
        var filter = store.filter
        filter.excludedDates = []
        filter.excludesUnknownDate = false
        updateDateActivation(&filter)
        store.filter = filter
    }

    private func clearAllDates() {
        var filter = store.filter
        filter.excludedDates = Set(store.availableCaptureDates)
        filter.excludesUnknownDate = true
        updateDateActivation(&filter)
        store.filter = filter
    }

    private func updateDateActivation(_ filter: inout PhotoFilter) {
        switch filter.dateMode {
        case .range:
            guard let available = store.captureDateRange else {
                filter.dateEnabled = false
                return
            }
            filter.dateEnabled = filter.dateFrom != available.lowerBound
                || filter.dateTo != available.upperBound
        case .specificDates:
            filter.dateEnabled = !filter.excludedDates.isEmpty
                || (store.unknownDateCount > 0 && filter.excludesUnknownDate)
        }
    }

    private func exclusionBinding(
        _ label: String,
        _ set: WritableKeyPath<PhotoFilter, Set<String>>
    ) -> Binding<Bool> {
        Binding {
            !store.filter[keyPath: set].contains(label)
        } set: { on in
            if on {
                store.filter[keyPath: set].remove(label)
            } else {
                store.filter[keyPath: set].insert(label)
            }
        }
    }

    private func metadataExclusionBinding<Value: Hashable>(
        _ value: Value,
        _ set: WritableKeyPath<PhotoFilter, Set<Value>>
    ) -> Binding<Bool> {
        Binding {
            !store.filter[keyPath: set].contains(value)
        } set: { isIncluded in
            var filter = store.filter
            if isIncluded {
                filter[keyPath: set].remove(value)
            } else {
                filter[keyPath: set].insert(value)
            }
            store.filter = filter
        }
    }

    private func mediaKindBinding(_ kind: MediaKind) -> Binding<Bool> {
        Binding {
            !store.filter.excludedMediaKinds.contains(kind)
        } set: { on in
            var filter = store.filter
            if on {
                filter.excludedMediaKinds.remove(kind)
            } else {
                filter.excludedMediaKinds.insert(kind)
            }
            store.filter = filter
        }
    }

    // MARK: - Range drafts

    private var apertureDraftIsValid: Bool {
        draftIsValid(
            available: store.apertureRange,
            currentFrom: store.filter.apertureFrom, currentTo: store.filter.apertureTo,
            isEnabled: store.filter.apertureEnabled,
            fromText: apertureFromText, toText: apertureToText,
            fromField: .apertureFrom, toField: .apertureTo,
            parse: Self.parseAperture,
            snap: { Self.snapAperture($0, toDisplayedBound: $1) }
        )
    }

    private var shutterDraftIsValid: Bool {
        draftIsValid(
            available: store.shutterRange,
            currentFrom: store.filter.shutterFrom, currentTo: store.filter.shutterTo,
            isEnabled: store.filter.shutterEnabled,
            fromText: shutterFromText, toText: shutterToText,
            fromField: .shutterFrom, toField: .shutterTo,
            parse: Self.parseShutter,
            snap: { Self.snapShutter($0, toDisplayedBound: $1) }
        )
    }

    private var isoDraftIsValid: Bool {
        draftIsValid(
            available: store.isoRange,
            currentFrom: store.filter.isoFrom, currentTo: store.filter.isoTo,
            isEnabled: store.filter.isoEnabled,
            fromText: isoFromText, toText: isoToText,
            fromField: .isoFrom, toField: .isoTo,
            parse: Self.parseISO,
            snap: { Self.snapISO($0, toDisplayedBound: $1) }
        )
    }

    private var durationDraftIsValid: Bool {
        draftIsValid(
            available: store.durationRange,
            currentFrom: store.filter.durationFrom, currentTo: store.filter.durationTo,
            isEnabled: store.filter.durationEnabled,
            fromText: durationFromText, toText: durationToText,
            fromField: .durationFrom, toField: .durationTo,
            parse: Self.parseDuration,
            snap: { Self.snapDuration($0, toDisplayedBound: $1) }
        )
    }

    private var videoFrameRateDraftIsValid: Bool {
        draftIsValid(
            available: store.videoFrameRateRange,
            currentFrom: store.filter.videoFrameRateFrom, currentTo: store.filter.videoFrameRateTo,
            isEnabled: store.filter.videoFrameRateEnabled,
            fromText: videoFrameRateFromText, toText: videoFrameRateToText,
            fromField: .videoFrameRateFrom, toField: .videoFrameRateTo,
            parse: Self.parseVideoFrameRate,
            snap: { Self.snapVideoFrameRate($0, toDisplayedBound: $1) }
        )
    }

    private func draftIsValid(
        available: ClosedRange<Double>?, currentFrom: Double, currentTo: Double,
        isEnabled: Bool, fromText: String, toText: String,
        fromField: SettingField, toField: SettingField,
        parse: (String) -> Double?, snap: (Double, Double) -> Double
    ) -> Bool {
        let editedFrom = editedSettingFields.contains(fromField)
        let editedTo = editedSettingFields.contains(toField)
        guard editedFrom || editedTo else { return true }
        guard let available else { return false }
        return NumericFilterRangeDraft.resolve(
            available: available, currentFrom: currentFrom, currentTo: currentTo,
            isEnabled: isEnabled, fromText: fromText, toText: toText,
            editedFrom: editedFrom, editedTo: editedTo, parse: parse, snap: snap
        ) != nil
    }

    private func commitApertureDrafts(to filter: inout PhotoFilter) {
        guard let available = store.apertureRange,
              let resolved = NumericFilterRangeDraft.resolve(
                available: available,
                currentFrom: filter.apertureFrom, currentTo: filter.apertureTo,
                isEnabled: filter.apertureEnabled,
                fromText: apertureFromText, toText: apertureToText,
                editedFrom: editedSettingFields.contains(.apertureFrom),
                editedTo: editedSettingFields.contains(.apertureTo),
                parse: Self.parseAperture,
                snap: { Self.snapAperture($0, toDisplayedBound: $1) }
              ) else { return }
        filter.apertureFrom = resolved.from
        filter.apertureTo = resolved.to
        filter.apertureEnabled = resolved.from != available.lowerBound
            || resolved.to != available.upperBound
        editedSettingFields.subtract([.apertureFrom, .apertureTo])
    }

    private func commitShutterDrafts(to filter: inout PhotoFilter) {
        guard let available = store.shutterRange,
              let resolved = NumericFilterRangeDraft.resolve(
                available: available,
                currentFrom: filter.shutterFrom, currentTo: filter.shutterTo,
                isEnabled: filter.shutterEnabled,
                fromText: shutterFromText, toText: shutterToText,
                editedFrom: editedSettingFields.contains(.shutterFrom),
                editedTo: editedSettingFields.contains(.shutterTo),
                parse: Self.parseShutter,
                snap: { Self.snapShutter($0, toDisplayedBound: $1) }
              ) else { return }
        filter.shutterFrom = resolved.from
        filter.shutterTo = resolved.to
        filter.shutterEnabled = resolved.from != available.lowerBound
            || resolved.to != available.upperBound
        editedSettingFields.subtract([.shutterFrom, .shutterTo])
    }

    private func commitISODrafts(to filter: inout PhotoFilter) {
        guard let available = store.isoRange,
              let resolved = NumericFilterRangeDraft.resolve(
                available: available,
                currentFrom: filter.isoFrom, currentTo: filter.isoTo,
                isEnabled: filter.isoEnabled,
                fromText: isoFromText, toText: isoToText,
                editedFrom: editedSettingFields.contains(.isoFrom),
                editedTo: editedSettingFields.contains(.isoTo),
                parse: Self.parseISO,
                snap: { Self.snapISO($0, toDisplayedBound: $1) }
              ) else { return }
        filter.isoFrom = resolved.from
        filter.isoTo = resolved.to
        filter.isoEnabled = resolved.from != available.lowerBound
            || resolved.to != available.upperBound
        editedSettingFields.subtract([.isoFrom, .isoTo])
    }

    private func commitDurationDrafts(to filter: inout PhotoFilter) {
        guard let available = store.durationRange,
              let resolved = NumericFilterRangeDraft.resolve(
                available: available,
                currentFrom: filter.durationFrom, currentTo: filter.durationTo,
                isEnabled: filter.durationEnabled,
                fromText: durationFromText, toText: durationToText,
                editedFrom: editedSettingFields.contains(.durationFrom),
                editedTo: editedSettingFields.contains(.durationTo),
                parse: Self.parseDuration,
                snap: { Self.snapDuration($0, toDisplayedBound: $1) }
              ) else { return }
        filter.durationFrom = resolved.from
        filter.durationTo = resolved.to
        filter.durationEnabled = resolved.from != available.lowerBound
            || resolved.to != available.upperBound
        editedSettingFields.subtract([.durationFrom, .durationTo])
    }

    private func commitVideoFrameRateDrafts(to filter: inout PhotoFilter) {
        guard let available = store.videoFrameRateRange,
              let resolved = NumericFilterRangeDraft.resolve(
                available: available,
                currentFrom: filter.videoFrameRateFrom, currentTo: filter.videoFrameRateTo,
                isEnabled: filter.videoFrameRateEnabled,
                fromText: videoFrameRateFromText, toText: videoFrameRateToText,
                editedFrom: editedSettingFields.contains(.videoFrameRateFrom),
                editedTo: editedSettingFields.contains(.videoFrameRateTo),
                parse: Self.parseVideoFrameRate,
                snap: { Self.snapVideoFrameRate($0, toDisplayedBound: $1) }
              ) else { return }
        filter.videoFrameRateFrom = resolved.from
        filter.videoFrameRateTo = resolved.to
        filter.videoFrameRateEnabled = resolved.from != available.lowerBound
            || resolved.to != available.upperBound
        editedSettingFields.subtract([.videoFrameRateFrom, .videoFrameRateTo])
    }

    private func syncAllSettingDrafts() {
        editedSettingFields.removeAll()
        if let range = store.apertureRange {
            let from = store.filter.apertureFrom > 0 ? store.filter.apertureFrom : range.lowerBound
            let to = store.filter.apertureTo > 0 ? store.filter.apertureTo : range.upperBound
            apertureFromText = Self.formatDecimal(from)
            apertureToText = Self.formatDecimal(to)
        }
        if let range = store.shutterRange {
            let from = store.filter.shutterFrom > 0 ? store.filter.shutterFrom : range.lowerBound
            let to = store.filter.shutterTo > 0 ? store.filter.shutterTo : range.upperBound
            shutterFromText = Self.formatShutter(from)
            shutterToText = Self.formatShutter(to)
        }
        if let range = store.isoRange {
            let from = store.filter.isoFrom > 0 ? store.filter.isoFrom : range.lowerBound
            let to = store.filter.isoTo > 0 ? store.filter.isoTo : range.upperBound
            isoFromText = Self.formatISO(from)
            isoToText = Self.formatISO(to)
        }
        if let range = store.durationRange {
            let from = store.filter.durationEnabled ? store.filter.durationFrom : range.lowerBound
            let to = store.filter.durationEnabled ? store.filter.durationTo : range.upperBound
            durationFromText = Self.formatDuration(from)
            durationToText = Self.formatDuration(to)
        }
        if let range = store.videoFrameRateRange {
            let from = store.filter.videoFrameRateEnabled
                ? store.filter.videoFrameRateFrom : range.lowerBound
            let to = store.filter.videoFrameRateEnabled
                ? store.filter.videoFrameRateTo : range.upperBound
            videoFrameRateFromText = Self.formatVideoFrameRate(from)
            videoFrameRateToText = Self.formatVideoFrameRate(to)
        }
    }

    /// Numeric text can be valid on every keystroke ("3", "32", "320"),
    /// but each assignment walks the full photo list. Coalesce continuous
    /// typing just like metadata search while preserving responsive results.
    private func scheduleSettingCommit() {
        guard !editedSettingFields.isEmpty else { return }
        settingCommitTask?.cancel()
        settingCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            commitAllSettingDrafts()
            settingCommitTask = nil
        }
    }

    private func commitAllSettingDrafts() {
        var updated = store.filter
        commitApertureDrafts(to: &updated)
        commitShutterDrafts(to: &updated)
        commitISODrafts(to: &updated)
        commitDurationDrafts(to: &updated)
        commitVideoFrameRateDrafts(to: &updated)
        if updated != store.filter {
            // One assignment means one pass across the photo list even if
            // several camera-setting fields changed before the debounce fired.
            store.filter = updated
        }
    }

    private func restoreInvalidDraft(for field: SettingField) {
        switch field {
        case .apertureFrom where !apertureDraftIsValid:
            apertureFromText = Self.formatDecimal(store.filter.apertureFrom)
        case .apertureTo where !apertureDraftIsValid:
            apertureToText = Self.formatDecimal(store.filter.apertureTo)
        case .shutterFrom where !shutterDraftIsValid:
            shutterFromText = Self.formatShutter(store.filter.shutterFrom)
        case .shutterTo where !shutterDraftIsValid:
            shutterToText = Self.formatShutter(store.filter.shutterTo)
        case .isoFrom where !isoDraftIsValid:
            isoFromText = Self.formatISO(store.filter.isoFrom)
        case .isoTo where !isoDraftIsValid:
            isoToText = Self.formatISO(store.filter.isoTo)
        case .durationFrom where !durationDraftIsValid:
            durationFromText = Self.formatDuration(store.filter.durationFrom)
        case .durationTo where !durationDraftIsValid:
            durationToText = Self.formatDuration(store.filter.durationTo)
        case .videoFrameRateFrom where !videoFrameRateDraftIsValid:
            videoFrameRateFromText = Self.formatVideoFrameRate(
                store.filter.videoFrameRateFrom
            )
        case .videoFrameRateTo where !videoFrameRateDraftIsValid:
            videoFrameRateToText = Self.formatVideoFrameRate(
                store.filter.videoFrameRateTo
            )
        default:
            return
        }
        editedSettingFields.remove(field)
    }

    // MARK: - Formatting

    private static func parseAperture(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasPrefix("f/") { value.removeFirst(2) }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return number
    }

    private static func parseShutter(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasSuffix("s") { value.removeLast() }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        let seconds: Double?
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            seconds = numerator / denominator
        } else if components.count == 1 {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static func parseISO(_ text: String) -> Double? {
        guard let number = Double(normalizedNumberText(text)),
              number.isFinite,
              number > 0,
              number.rounded() == number else { return nil }
        return number
    }

    private static func parseDuration(_ text: String) -> Double? {
        var value = normalizedNumberText(text).lowercased()
        if value.hasSuffix("s") { value.removeLast() }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        let seconds: Double?
        switch fields.count {
        case 1:
            seconds = Double(fields[0])
        case 2:
            if let minutes = Double(fields[0]), minutes >= 0,
               let remainder = Double(fields[1]), remainder >= 0, remainder < 60 {
                seconds = minutes * 60 + remainder
            } else {
                seconds = nil
            }
        case 3:
            if let hours = Double(fields[0]), hours >= 0,
               let minutes = Double(fields[1]), minutes >= 0, minutes < 60,
               let remainder = Double(fields[2]), remainder >= 0, remainder < 60 {
                seconds = hours * 3600 + minutes * 60 + remainder
            } else {
                seconds = nil
            }
        default:
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func parseVideoFrameRate(_ text: String) -> Double? {
        guard let value = Double(normalizedNumberText(text)),
              MediaNumeric.frameRate(value) != nil
        else { return nil }
        return value
    }

    private static func normalizedNumberText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
    }

    private static func formatDecimal(_ value: Double) -> String {
        MetadataFormat.decimal(value)
    }

    private static func formatShutter(_ seconds: Double) -> String {
        MetadataFormat.shutter(seconds)
    }

    private static func formatISO(_ value: Double) -> String {
        MetadataFormat.iso(value)
    }

    private static func formatDuration(_ value: Double) -> String {
        MediaDurationFormat.display(value)
    }

    private static func formatVideoFrameRate(_ value: Double) -> String {
        VideoMetadataFormat.frameRate(value)
            .replacingOccurrences(of: " fps", with: "")
    }

    /// Display formatting rounds some legal EXIF values. If the user-entered
    /// value equals what a folder bound displays, retain the exact bound so a
    /// neutral full range cannot accidentally exclude its edge photo.
    private static func snapAperture(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseAperture(formatDecimal(bound)) == value ? bound : value
    }

    private static func snapShutter(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseShutter(formatShutter(bound)) == value ? bound : value
    }

    private static func snapISO(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseISO(formatISO(bound)) == value ? bound : value
    }

    private static func snapDuration(_ value: Double, toDisplayedBound bound: Double) -> Double {
        parseDuration(formatDuration(bound)) == value ? bound : value
    }

    private static func snapVideoFrameRate(
        _ value: Double,
        toDisplayedBound bound: Double
    ) -> Double {
        parseVideoFrameRate(formatVideoFrameRate(bound)) == value ? bound : value
    }

    private func labeledCount(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// A native-looking disclosure row whose whole width, including its title, is
/// clickable. SwiftUI's standard DisclosureGroup gives the chevron a much more
/// obvious hit target than the label on macOS, which made the title feel inert.
private struct FilterDisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
                        .frame(width: 12)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? L10n.text("Expanded") : L10n.text("Collapsed"))

            if isExpanded {
                content
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
