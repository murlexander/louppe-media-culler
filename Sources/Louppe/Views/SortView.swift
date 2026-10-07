import SwiftUI

/// The toolbar sort popover, styled after FilterView: pick a sort key and a
/// direction, and choose whether the visible list divides into groups.
/// It only reorders what's shown and never touches ratings.
struct SortView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Sort"))
                .font(.headline)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(L10n.text("Sort by"), spacing: 2) {
                        keyRow(L10n.text("Date taken"), .captureDate)
                        keyRow(L10n.text("Name"), .name)
                        keyRow(L10n.text("Decision"), .decision)
                        keyRow(L10n.text("Star rating"), .starRating)
                        keyRow(L10n.text("Color label"), .colorLabel)
                        keyRow(L10n.text("Subfolder"), .subfolder, disabled: store.availableSubfolders.count <= 1)
                        keyRow(L10n.text("Folder hierarchy"), .folderHierarchy)
                            .help(L10n.text("Review folders before their subfolders; files stay chronological."))
                        keyRow(L10n.text("File type"), .fileType)
                        keyRow(L10n.text("Media type"), .mediaKind, disabled: store.availableMediaKinds.count <= 1)
                        keyRow(L10n.text("Camera"), .camera)
                        keyRow(L10n.text("Lens"), .lens)
                        keyRow(L10n.text("Aperture"), .aperture, disabled: store.apertureRange == nil)
                        keyRow(L10n.text("Shutter speed"), .shutterSpeed, disabled: store.shutterRange == nil)
                        keyRow("ISO", .iso, disabled: store.isoRange == nil)
                        keyRow(L10n.text("Media duration"), .duration, disabled: store.durationRange == nil)
                        keyRow(
                            L10n.text("Video resolution"),
                            .videoResolution,
                            disabled: store.availableVideoResolutions.count <= 1
                        )
                        keyRow(
                            L10n.text("Video frame rate"),
                            .videoFrameRate,
                            disabled: store.videoFrameRateRange == nil
                        )
                        keyRow(
                            L10n.text("Video codec"),
                            .videoCodec,
                            disabled: store.availableVideoCodecs.count <= 1
                        )
                    }

                    Divider()

                    section(L10n.text("Order")) {
                        orderRow(store.sort.key.ascendingLabel, ascending: true)
                        orderRow(store.sort.key.descendingLabel, ascending: false)
                    }

                    Divider()

                    section(L10n.text("Groups")) {
                        Toggle(L10n.text("Divide into groups"), isOn: $store.isGroupingEnabled)
                            .toggleStyle(.checkbox)
                            // Name sorting never divides: every file name is unique.
                            .disabled(store.sort.key == .name)
                    }

                    Divider()

                    section(L10n.text("Review groups")) {
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
                            .disabled(store.items.isEmpty || store.isFileOperationRunning)
                        }

                        reviewModeRow(.exactDuplicates)
                        reviewModeRow(.likelySimilarPhotos)
                        reviewModeRow(.captureBursts)

                        if store.isGroupedReviewActive {
                            Button(L10n.text("Return to Normal Review")) {
                                store.exitGroupedReview()
                            }
                            .buttonStyle(.borderless)
                        }

                        if store.groupedReviewMode == .likelySimilarPhotos {
                            similarityControl
                        }
                        if store.groupedReviewMode == .captureBursts {
                            burstControl
                        }

                        Text(store.duplicateBurstAnalysisSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("Grouping never changes ratings, originals, Clean Up, or Export."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 5)
            }
            Divider()
            HStack {
                Spacer()
                Button(L10n.text("Done")) { store.isSortPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 340, height: 560)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
    }

    private func section(_ title: String, spacing: CGFloat = 8, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func keyRow(_ label: String, _ key: PhotoSort.Key, disabled: Bool = false) -> some View {
        checkRow(label, isSelected: store.sort.key == key, disabled: disabled) {
            store.sort.key = key
        }
    }

    private func orderRow(_ label: String, ascending: Bool) -> some View {
        checkRow(label, isSelected: store.sort.ascending == ascending, disabled: false) {
            store.sort.ascending = ascending
        }
    }

    private func reviewModeRow(_ mode: DuplicateBurstAnalysis.ReviewMode) -> some View {
        checkRow(
            mode.displayName,
            isSelected: store.groupedReviewMode == mode,
            disabled: store.items.isEmpty || store.isFileOperationRunning
        ) {
            store.enterGroupedReview(mode)
        }
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

    private var burstControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text("Burst interval"))
                Spacer()
                Text(L10n.text("\(String(format: "%.1f", store.burstGroupingInterval)) s"))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { store.burstGroupingInterval },
                    set: { store.setBurstGroupingInterval($0) }
                ),
                in: 0.5...10,
                step: 0.5
            )
            .accessibilityLabel(L10n.text("Capture burst interval"))
            .accessibilityValue(L10n.text("\(String(format: "%.1f", store.burstGroupingInterval)) seconds"))
            Text(L10n.text("Group consecutive shots within this interval."))
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

    /// A menu-like row: reserved checkmark column so labels stay aligned,
    /// whole width clickable.
    private func checkRow(
        _ label: String,
        isSelected: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14, alignment: .leading)
                    .opacity(isSelected ? 1 : 0)
                Text(label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityValue(isSelected ? L10n.text("Selected") : L10n.text("Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
