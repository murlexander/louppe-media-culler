import SwiftUI

/// The info panel: filename and review metadata, photo histogram, camera/lens,
/// shooting settings, then the remaining EXIF fields.
struct MetadataPanel: View {
    /// EXIF detail and histogram analysis are secondary to the visible photo.
    /// A short dwell prevents key repeat from opening every transient file.
    private static let inspectionDebounceNanoseconds: UInt64 = 80_000_000

    @ObservedObject var store: SessionStore
    let item: PhotoItem

    @State private var fields: [MetadataField] = []
    @State private var fieldsRevision: PhotoContentRevision?
    @State private var histogram: HistogramAnalysis?
    @State private var histogramLoadFailed = false
    @State private var histogramRevision: PhotoContentRevision?
    @State private var rawHistogram: HistogramAnalysis?
    @State private var rawHistogramIsPending = false
    @State private var rawHistogramRevision: PhotoContentRevision?
    @State private var audioLevels: AudioLevelAnalysis?
    @State private var audioLevelsLoadFailed = false
    @State private var audioLevelsRevision: PhotoContentRevision?
    @State private var isEditingFilename = false
    @State private var filenameDraft = ""
    @State private var filenamePlan: SourceOrganizationPlan?
    @State private var filenamePlanningError: String?
    @State private var isPlanningFilename = false
    @State private var filenameSubmissionPending = false
    @State private var filenamePlanningTask: Task<Void, Never>?
    @State private var filenamePlanningCancelFlag:
        SourceOrganizationPlanningCancelFlag?
    @FocusState private var filenameIsFocused: Bool
    @AppStorage(CameraQualityWarningPreferences.Keys.isEnabled)
    private var cameraQualityWarningsEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isHighISOEnabled)
    private var highISOWarningEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isSlowShutterEnabled)
    private var slowShutterWarningEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.isClippingEnabled)
    private var clippingWarningEnabled = true
    @AppStorage(CameraQualityWarningPreferences.Keys.highISOThreshold)
    private var highISOWarningThreshold =
        CameraQualityWarningPreferences.defaultHighISOThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.slowShutterThreshold)
    private var slowShutterWarningThreshold =
        CameraQualityWarningPreferences.defaultSlowShutterThreshold
    @AppStorage(CameraQualityWarningPreferences.Keys.clippingPercentageThreshold)
    private var clippingWarningThreshold =
        CameraQualityWarningPreferences.defaultClippingPercentageThreshold

    private struct MetadataLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isMultipleSelection: Bool
    }

    private struct HistogramLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isEligible: Bool
    }

    private struct AudioLevelsLoadID: Hashable {
        let contentRevision: PhotoContentRevision
        let isEligible: Bool
    }

    private let shootingLabels = ["Aperture", "Shutter", "ISO"]
    private let secondaryShootingLabels = ["Focal length", "Exposure comp.", "White balance"]
    private let promotedLabels = [
        "Filename", "Camera", "Lens", "Aperture", "Shutter", "ISO",
        "Focal length", "Exposure comp.", "White balance"
    ]

    private var displayedFields: [MetadataField] {
        fieldsRevision == item.contentRevision ? fields : []
    }

    private var displayedHistogram: HistogramAnalysis? {
        displayedRawHistogram
            ?? (histogramRevision == item.contentRevision ? histogram : nil)
    }

    private var displayedRawHistogram: HistogramAnalysis? {
        rawHistogramRevision == item.contentRevision ? rawHistogram : nil
    }

    private var displayedHistogramSource: HistogramAnalysisSource {
        displayedRawHistogram == nil ? .renderedPreview : .rawDecode
    }

    private var displayedRawHistogramIsPending: Bool {
        rawHistogramRevision == item.contentRevision && rawHistogramIsPending
    }

    private var displayedHistogramLoadFailed: Bool {
        displayedHistogram == nil
            && histogramRevision == item.contentRevision
            && histogramLoadFailed
            && !displayedRawHistogramIsPending
    }

    private var showsAudioLevels: Bool {
        store.selectedIndices.count <= 1
            && (item.isVideo || item.isAudio)
            && item.isPlayableMedia
    }

    private var filenameExtension: String {
        let ext = item.primaryURL.pathExtension
        return ext.isEmpty ? "" : ".\(ext)"
    }

    private var audioLevelsLoadID: AudioLevelsLoadID {
        AudioLevelsLoadID(
            contentRevision: item.contentRevision,
            isEligible: showsAudioLevels
        )
    }

    private var displayedAudioLevels: AudioLevelAnalysis? {
        audioLevelsRevision == item.contentRevision ? audioLevels : nil
    }

    private var displayedAudioLevelsLoadFailed: Bool {
        audioLevelsRevision == item.contentRevision
            && audioLevelsLoadFailed
    }

    private var cameraQualityWarningPreferences: CameraQualityWarningPreferences {
        CameraQualityWarningPreferences(
            isEnabled: cameraQualityWarningsEnabled,
            isHighISOEnabled: highISOWarningEnabled,
            isSlowShutterEnabled: slowShutterWarningEnabled,
            isClippingEnabled: clippingWarningEnabled,
            highISOThreshold: highISOWarningThreshold,
            slowShutterThreshold: slowShutterWarningThreshold,
            clippingPercentageThreshold: clippingWarningThreshold
        )
    }

    private var cameraQualityCuesRow: CameraQualityCuesRow {
        CameraQualityCuesRow(
            item: item,
            analysis: displayedHistogram,
            analysisSource: displayedHistogramSource,
            isRawAnalysisPending: displayedRawHistogramIsPending,
            preferences: cameraQualityWarningPreferences
        )
    }

    private var showsCameraQualityCues: Bool {
        cameraQualityCuesRow.isVisible
    }

    private var cameraName: String? {
        displayedFields.first { $0.label == "Camera" }?.value
    }

    private var lensName: String? {
        displayedFields.first { $0.label == "Lens" }?.value
    }

    private var primaryShootingFields: [MetadataField] {
        fields(for: shootingLabels)
    }

    private var secondaryShootingFields: [MetadataField] {
        fields(for: secondaryShootingLabels)
    }

    private var hasCameraLensInfo: Bool {
        cameraName != nil || lensName != nil
    }

    private var hasShootingInfo: Bool {
        !primaryShootingFields.isEmpty || !secondaryShootingFields.isEmpty
    }

    private var cameraLensText: String? {
        switch (cameraName, lensName) {
        case let (camera?, lens?): return "\(camera) + \(lens)"
        case let (camera?, nil): return camera
        case let (nil, lens?): return lens
        case (nil, nil): return nil
        }
    }

    private func fields(for labels: [String]) -> [MetadataField] {
        labels.compactMap { label in
            displayedFields.first { $0.label == label }
        }
    }

    private var otherFields: [MetadataField] {
        displayedFields.filter { !promotedLabels.contains($0.label) }
    }

    private var metadataLoadID: MetadataLoadID {
        MetadataLoadID(
            contentRevision: item.contentRevision,
            isMultipleSelection: store.selectedIndices.count > 1
        )
    }

    private var showsHistogram: Bool {
        store.selectedIndices.count <= 1
            && item.mediaKind == .photo
            && item.isSupported
    }

    private var histogramLoadID: HistogramLoadID {
        HistogramLoadID(
            contentRevision: item.contentRevision,
            isEligible: showsHistogram
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let multiSelectionSummary = store.multiSelectionSummary {
                    multiSelectionContent(multiSelectionSummary)
                } else {
                    singlePhotoContent
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.appBackground)
        .background(SessionRenderMarker(kind: .metadata))
        .task(id: metadataLoadID) {
            let requestedRevision = metadataLoadID.contentRevision
            fields = []
            fieldsRevision = requestedRevision
            guard !metadataLoadID.isMultipleSelection else {
                // The selection summary uses scan-cached metadata only. Avoid
                // reopening the current file for fields that are not rendered.
                return
            }
            try? await Task.sleep(
                nanoseconds: Self.inspectionDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            let current = item
            let loaded = await Task.detached(priority: .userInitiated) {
                MetadataExtractor.fields(for: current)
            }.value
            guard !Task.isCancelled,
                  fieldsRevision == requestedRevision else { return }
            fields = loaded
        }
        .task(id: histogramLoadID) {
            let requestedRevision = histogramLoadID.contentRevision
            histogram = nil
            histogramLoadFailed = false
            histogramRevision = requestedRevision
            guard histogramLoadID.isEligible else { return }
            try? await Task.sleep(
                nanoseconds: Self.inspectionDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            let requestedItem = item
            let loaded = await HistogramPipeline.shared.analysis(
                for: requestedItem
            )
            guard !Task.isCancelled,
                  histogramRevision == requestedRevision else { return }
            histogram = loaded
            histogramLoadFailed = (loaded == nil)
        }
        .task(id: histogramLoadID) {
            let requestedRevision = histogramLoadID.contentRevision
            let requestedItem = item
            rawHistogramRevision = requestedRevision
            rawHistogram = RawHistogramPipeline.shared.cachedAnalysis(
                for: requestedItem
            )
            rawHistogramIsPending = histogramLoadID.isEligible
                && RawHistogramPipeline.supportsAnalysis(for: requestedItem)
                && rawHistogram == nil
            guard rawHistogramIsPending else { return }

            let loaded = await RawHistogramPipeline.shared.analysis(
                for: requestedItem
            )
            guard !Task.isCancelled,
                  rawHistogramRevision == requestedRevision else { return }
            rawHistogram = loaded
            rawHistogramIsPending = false
        }
        .task(id: audioLevelsLoadID) {
            let requestedRevision = audioLevelsLoadID.contentRevision
            audioLevels = nil
            audioLevelsLoadFailed = false
            audioLevelsRevision = requestedRevision
            guard audioLevelsLoadID.isEligible else { return }
            try? await Task.sleep(
                nanoseconds: Self.inspectionDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            let requestedItem = item
            let loaded = await AudioLevelPipeline.shared.analysis(for: requestedItem)
            guard !Task.isCancelled,
                  audioLevelsRevision == requestedRevision else { return }
            audioLevels = loaded
            audioLevelsLoadFailed = (loaded == nil)
        }
        .onChange(of: item.contentRevision) { _, _ in
            cancelFilenameEditing()
        }
        .onChange(of: store.selectedIndices.count > 1) { _, isMultiple in
            if isMultiple { cancelFilenameEditing() }
        }
        .onChange(of: filenameDraft) { _, _ in
            if isEditingFilename { refreshFilenamePlan() }
        }
        .onDisappear {
            cancelFilenameEditing()
        }
    }

    // MARK: - Single photo

    @ViewBuilder
    private var singlePhotoContent: some View {
        HStack(alignment: .center, spacing: 10) {
            filenameControl

            Spacer(minLength: 4)

            MetadataDecisionButton(store: store, size: 27)
        }

        MetadataEditingControls(store: store, showsDecision: false)

        Divider()

        if item.isPlayableMedia {
            MediaPlaybackSpeedControl(
                playback: store.videoPlayback,
                isEnabled: store.canSetCurrentPlayableMediaPlaybackRate
            )
            Divider()
        }

        if showsAudioLevels {
            AudioLevelsSection(
                item: item,
                analysis: displayedAudioLevels,
                isLoading: displayedAudioLevels == nil
                    && !displayedAudioLevelsLoadFailed,
                loadFailed: displayedAudioLevelsLoadFailed,
                playback: store.videoPlayback
            )
            Divider()
        }

        if showsHistogram {
            HistogramSection(
                analysis: displayedHistogram,
                source: displayedHistogramSource,
                loadFailed: displayedHistogramLoadFailed,
                store: store
            )
        }

        if showsHistogram
            && (hasCameraLensInfo || hasShootingInfo || !otherFields.isEmpty) {
            Divider()
        }

        if let cameraLensText {
            metadataValue(cameraLensText, emphasized: true)
        }

        if hasCameraLensInfo && hasShootingInfo {
            Divider()
        }

        if hasShootingInfo || showsCameraQualityCues {
            VStack(spacing: 12) {
                if !primaryShootingFields.isEmpty {
                    metadataRow(primaryShootingFields, showLabels: false, emphasized: true)
                }
                if !secondaryShootingFields.isEmpty {
                    metadataRow(secondaryShootingFields)
                }
                if showsCameraQualityCues {
                    cameraQualityCuesRow
                }
            }
        }

        if (hasShootingInfo || showsCameraQualityCues) && !otherFields.isEmpty {
            Divider()
        }

        ForEach(otherFields) { field in
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.label(field.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(field.value)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }

    private var filenameControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditingFilename {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField(L10n.text("Filename"), text: $filenameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.weight(.semibold))
                        .focused($filenameIsFocused)
                        .onSubmit { submitFilenameRename() }
                        .onExitCommand { cancelFilenameEditing() }
                        .accessibilityLabel(L10n.text("Filename without extension"))
                        .accessibilityHint(
                            L10n.text("Edit the name without its extension. Matching RAW, JPEG, and XMP files are renamed together.")
                        )
                    Text(filenameExtension)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button {
                        cancelFilenameEditing()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Cancel filename editing"))
                }

                if isPlanningFilename {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Checking filename…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let filenamePlanningError {
                    Label(filenamePlanningError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let filenamePlan,
                          !filenamePlan.collisions.isEmpty {
                    Label(
                        filenamePlan.collisions[0].message,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else if store.isRenamingSource {
                HStack(spacing: 7) {
                    Text(item.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    ProgressView()
                        .controlSize(.small)
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.text("Renaming \(item.displayName)"))
            } else {
                Button {
                    beginFilenameEditing()
                } label: {
                    Text(item.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!store.canRenameSource)
                .help(L10n.text("Click to edit filename"))
                .accessibilityLabel(item.displayName)
                .accessibilityHint(L10n.text("Click to edit the filename in place."))
            }

            if let operationError = store.organizationError,
               !isEditingFilename,
               !store.isRenamingSource {
                Label(operationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginFilenameEditing() {
        guard store.canRenameSource else { return }
        filenamePlanningTask?.cancel()
        filenameDraft = (item.displayName as NSString).deletingPathExtension
        filenamePlan = nil
        filenamePlanningError = nil
        isEditingFilename = true
        DispatchQueue.main.async {
            filenameIsFocused = true
        }
        refreshFilenamePlan()
    }

    private func cancelFilenameEditing() {
        filenamePlanningCancelFlag?.cancel()
        filenamePlanningTask?.cancel()
        filenamePlanningCancelFlag = nil
        filenamePlanningTask = nil
        isPlanningFilename = false
        filenameSubmissionPending = false
        isEditingFilename = false
        filenameIsFocused = false
        filenamePlan = nil
        filenamePlanningError = nil
    }

    private func refreshFilenamePlan() {
        filenameSubmissionPending = false
        filenamePlanningCancelFlag?.cancel()
        filenamePlanningTask?.cancel()
        filenamePlanningTask = nil
        filenamePlanningCancelFlag = nil
        filenamePlan = nil
        filenamePlanningError = nil
        guard isEditingFilename else {
            isPlanningFilename = false
            return
        }
        let requestedItemID = item.id
        let configuration = FileRenamingPlanner.sourceConfiguration(
            customBaseName: filenameDraft
        )
        let cancelFlag = SourceOrganizationPlanningCancelFlag()
        filenamePlanningCancelFlag = cancelFlag
        isPlanningFilename = true
        filenamePlanningTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            guard let snapshot = store.sourceFileRenamingPlanningSnapshot(
                itemID: requestedItemID
            ) else {
                isPlanningFilename = false
                filenamePlanningError = L10n.text("This filename can no longer be edited.")
                return
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try SourceOrganizationPlanner.makePlan(
                        sourceFolder: snapshot.sourceFolder,
                        selectedItems: snapshot.selectedItems,
                        familyContextItems: snapshot.familyContextItems,
                        configuration: configuration,
                        knownOriginFolderPathBytesByFileID:
                            snapshot.knownOriginFolderPathBytesByFileID,
                        pairedFiles: snapshot.pairedFiles,
                        isCancelled: { cancelFlag.isCancelled }
                    )
                }
            }.value
            guard !Task.isCancelled, isEditingFilename else { return }
            filenamePlanningCancelFlag = nil
            isPlanningFilename = false
            switch result {
            case .success(let prepared):
                filenamePlan = prepared
            case .failure(let error):
                filenamePlanningError = error.localizedDescription
            }
            if filenameSubmissionPending {
                filenameSubmissionPending = false
                submitFilenameRename()
            }
        }
    }

    private func submitFilenameRename() {
        // Return may arrive while the debounced preflight is still running.
        // Apply that exact draft when it is ready; editing or cancelling clears
        // the request so a stale result can never rename a different draft.
        if isPlanningFilename {
            filenameSubmissionPending = true
            return
        }
        guard let filenamePlan, filenamePlan.canExecute else {
            filenameIsFocused = true
            return
        }
        filenamePlanningCancelFlag?.cancel()
        filenamePlanningTask?.cancel()
        filenameIsFocused = false
        isEditingFilename = false
        store.startSourceRename(filenamePlan, presentsSheet: false)
    }

    // MARK: - Multiple photos

    @ViewBuilder
    private func multiSelectionContent(_ summary: PhotoSelectionSummary) -> some View {
        Text(selectionTitle(for: summary))
            .font(.title3.weight(.semibold))

        MetadataEditingControls(store: store)

        Button(L10n.text("Rename Files…")) {
            store.presentMetadataFileRenaming()
        }
        .disabled(!store.canRenameSource)

        Divider()

        selectionSummaryField(L10n.text("Cameras"), value: summary.cameras.joined(separator: ", "))
        selectionSummaryField(L10n.text("Lenses"), value: summary.lenses.joined(separator: ", "))
        selectionSummaryField(L10n.text("Captured"), value: captureDateText(for: summary))
        selectionSummaryField(
            L10n.text("Total size"),
            value: ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)
        )
        selectionSummaryField(L10n.text("Types"), value: summary.fileTypes.joined(separator: ", "))
    }

    private func selectionTitle(for summary: PhotoSelectionSummary) -> String {
        let itemLabel = summary.photoCount == summary.count
            ? "photos"
            : L10n.text("media items")
        return L10n.text("\(summary.count) \(itemLabel) selected · \(summary.fileCount) files")
    }

    private func selectionSummaryField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 3)
    }

    private func captureDateText(for summary: PhotoSelectionSummary) -> String {
        var lines: [String] = []
        if let range = summary.captureDayRange {
            if range.lowerBound == range.upperBound {
                lines.append(AppDateFormat.day(range.lowerBound))
            } else {
                lines.append(AppDateFormat.dayRange(
                    from: range.lowerBound,
                    to: range.upperBound
                ))
            }
        }
        if summary.unknownDateCount > 0 {
            let itemLabel = summary.photoCount == summary.count
                ? L10n.text("photo")
                : L10n.text("media item")
            let label = summary.unknownDateCount == 1
                ? L10n.text("1 \(itemLabel) without a capture date")
                : L10n.text("\(summary.unknownDateCount) \(itemLabel)s without a capture date")
            lines.append(label)
        }
        return lines.isEmpty ? L10n.text("Unknown") : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func metadataRow(
        _ rowFields: [MetadataField],
        showLabels: Bool = true,
        emphasized: Bool = false
    ) -> some View {
        if !rowFields.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                ForEach(rowFields) { field in
                    VStack(spacing: 2) {
                        if showLabels {
                            Text(displayLabel(for: field))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if emphasized {
                            settingValue(for: field)
                        } else {
                            Text(field.value)
                                .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func settingValue(for field: MetadataField) -> some View {
        let largeFont = Font.system(size: 18, weight: .semibold)
        let smallFont = Font.system(size: 12, weight: .semibold)
        let value = field.value

        switch field.label {
        case "Aperture" where value.hasPrefix("f/"):
            return Text("f/\(Text(String(value.dropFirst(2))).font(largeFont))")
                .font(smallFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .textSelection(.enabled)
        case "Shutter" where value.hasPrefix("1/"):
            let remainder = String(value.dropFirst(2))
            let suffix = remainder.hasSuffix("s") ? "s" : ""
            let number = suffix.isEmpty ? remainder : String(remainder.dropLast())
            return Text("1/\(Text(number).font(largeFont))\(suffix)")
                .font(smallFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .textSelection(.enabled)
        case "ISO":
            return Text("ISO\(Text(value).font(largeFont))")
                .font(smallFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .textSelection(.enabled)
        default:
            return Text(value)
                .font(largeFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func displayLabel(for field: MetadataField) -> String {
        switch field.label {
        case "Exposure comp.": return L10n.text("Exp. comp.")
        case "White balance": return L10n.text("WB")
        default: return L10n.label(field.label)
        }
    }

    private func metadataValue(_ value: String, emphasized: Bool = false) -> some View {
        Text(value)
            .font(emphasized ? .subheadline : .callout)
            .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
    }

}

private struct MediaPlaybackSpeedControl: View {
    @ObservedObject var playback: VideoPlaybackController
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Playback speed"))
                .font(.subheadline.weight(.semibold))
            Picker(
                L10n.text("Media playback speed"),
                selection: Binding(
                    get: { playback.playbackRate },
                    set: { playback.setPlaybackRate($0) }
                )
            ) {
                ForEach(VideoPlaybackController.availablePlaybackRates, id: \.self) {
                    rate in
                    Text(speedLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isEnabled)
            .accessibilityHint(L10n.text("Applies to video and audio playback."))
        }
    }

    private func speedLabel(_ rate: Double) -> String {
        rate.rounded() == rate ? "\(Int(rate))×" : "\(rate)×"
    }
}
