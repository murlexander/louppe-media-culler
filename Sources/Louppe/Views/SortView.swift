import SwiftUI

/// Sort and grouping settings with separate grouped-review commands, in the
/// same compact popover layout as Filter. It only reorders what's shown and
/// never touches ratings.
struct SortView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        CompactToolbarPopover(title: L10n.text("Sort"), done: { store.isSortPresented = false }) {
            VStack(alignment: .leading, spacing: 8) {
                pickerRow(L10n.text("Sort by"), value: store.sort.key.popoverLabel,
                          selection: $store.sort.key, identifier: "louppe.sortKey") {
                    sortOption(.captureDate)
                    sortOption(.name)
                    sortOption(.decision)
                    sortOption(.starRating)
                    sortOption(.colorLabel)
                    sortOption(.subfolder, disabled: store.availableSubfolders.count <= 1)
                    sortOption(.folderHierarchy)
                        .help(L10n.text("Review folders before their subfolders; files stay chronological."))
                    sortOption(.fileType)
                    sortOption(.mediaKind, disabled: store.availableMediaKinds.count <= 1)
                    sortOption(.camera)
                    sortOption(.lens)
                    sortOption(.aperture, disabled: store.apertureRange == nil)
                    sortOption(.shutterSpeed, disabled: store.shutterRange == nil)
                    sortOption(.iso, disabled: store.isoRange == nil)
                    sortOption(.duration, disabled: store.durationRange == nil)
                    sortOption(.videoResolution,
                               disabled: store.availableVideoResolutions.count <= 1)
                    sortOption(.videoFrameRate,
                               disabled: store.videoFrameRateRange == nil)
                    sortOption(.videoCodec,
                               disabled: store.availableVideoCodecs.count <= 1)
                }

                pickerRow(L10n.text("Order"),
                          value: store.sort.ascending ? store.sort.key.ascendingLabel : store.sort.key.descendingLabel,
                          selection: $store.sort.ascending, identifier: "louppe.sortOrder") {
                    Text(store.sort.key.ascendingLabel).tag(true)
                    Text(store.sort.key.descendingLabel).tag(false)
                }

                Toggle(L10n.text("Divide into groups"), isOn: $store.isGroupingEnabled)
                    // Name sorting never divides: every file name is unique.
                    .disabled(store.sort.key == .name)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Review groups"))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                // Entering a group may first run asynchronous analysis, so
                // these are explicit commands rather than an optimistic selection.
                reviewModeButton(.exactDuplicates)
                reviewModeButton(.likelySimilarPhotos)

                if store.isGroupedReviewActive {
                    Button(L10n.text("Return to Normal Review")) {
                        store.exitGroupedReview()
                    }
                    .buttonStyle(.borderless)
                }
                if store.groupedReviewMode == .likelySimilarPhotos {
                    similarityControl
                }
                caption(L10n.text("Grouping never changes ratings, originals, Clean Up, or Export."))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if store.isDuplicateBurstAnalysisRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("Analyzing locally…"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("Cancel")) {
                            store.cancelDuplicateBurstAnalysis()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button(
                        store.duplicateBurstAnalysisState == .ready
                            ? L10n.text("Refresh Local Analysis")
                            : L10n.text("Analyze Folder Locally")
                    ) {
                        store.analyzeDuplicateAndBurstGroups()
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.items.isEmpty || store.isFileOperationRunning || store.photosBatch?.mediaSession != nil)
                }
                caption(store.duplicateBurstAnalysisSummary)
            }

            Divider()
        }
    }

    /// A compact leading label with a trailing menu, as in Filter's rows.
    private func pickerRow<Selection: Hashable, Options: View>(
        _ title: String, value: String, selection: Binding<Selection>, identifier: String,
        @ViewBuilder options: @escaping () -> Options
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: 8)
            // One width keeps both menus aligned; long names truncate natively.
            ValueMenu(title, value: value, selection: selection, options: options)
            .accessibilityIdentifier(identifier)
            .frame(width: 180, alignment: .trailing)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sortOption(_ key: PhotoSort.Key, disabled: Bool = false) -> some View {
        Text(verbatim: key.popoverLabel).tag(key).disabled(disabled)
    }

    private func reviewModeButton(_ mode: DuplicateBurstAnalysis.ReviewMode) -> some View {
        Button {
            store.enterGroupedReview(mode)
        } label: {
            HStack(spacing: 6) {
                Text(mode.displayName)
                if store.groupedReviewMode == mode {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(store.items.isEmpty || store.isFileOperationRunning || store.photosBatch?.mediaSession != nil)
        .help(mode.shortDescription)
        .accessibilityAddTraits(store.groupedReviewMode == mode ? .isSelected : [])
    }

    private var similarityControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text("Similarity"))
                Spacer()
                Text(similarityLabel)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(store.visualSimilarityDistance) },
                    set: { store.setVisualSimilarityDistance(Int($0.rounded())) }
                ),
                in: 3...16,
                step: 1
            )
            .accessibilityLabel(L10n.text("Likely-similar photo sensitivity"))
            .accessibilityValue(similarityLabel)
            Text(L10n.text("Lower is stricter. Local preview similarity is an estimate."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var similarityLabel: String {
        switch store.visualSimilarityDistance {
        case ...5: return L10n.text("Strict")
        case 6...10: return L10n.text("Balanced")
        default: return L10n.text("Broad")
        }
    }
}

private extension PhotoSort.Key {
    var popoverLabel: String {
        switch self {
        case .captureDate: return L10n.text("Date taken")
        case .name: return L10n.text("Name")
        case .decision: return L10n.text("Decision")
        case .starRating: return L10n.text("Star rating")
        case .colorLabel: return L10n.text("Color label")
        case .subfolder: return L10n.text("Subfolder")
        case .folderHierarchy: return L10n.text("Folder hierarchy")
        case .fileType: return L10n.text("File type")
        case .mediaKind: return L10n.text("Media type")
        case .camera: return L10n.text("Camera")
        case .lens: return L10n.text("Lens")
        case .aperture: return L10n.text("Aperture")
        case .shutterSpeed: return L10n.text("Shutter speed")
        case .iso: return "ISO"
        case .duration: return L10n.text("Media duration")
        case .videoResolution: return L10n.text("Video resolution")
        case .videoFrameRate: return L10n.text("Video frame rate")
        case .videoCodec: return L10n.text("Video codec")
        }
    }
}
