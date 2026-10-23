import SwiftUI

/// Native sort and grouping settings with separate grouped-review commands.
/// It only reorders what's shown and never touches ratings.
struct SortView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("Sort"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 14)

            LouppeSettingsForm {
                Section {
                    Picker(L10n.text("Sort by"), selection: $store.sort.key) {
                        sortOption(L10n.text("Date taken"), .captureDate)
                        sortOption(L10n.text("Name"), .name)
                        sortOption(L10n.text("Decision"), .decision)
                        sortOption(L10n.text("Star rating"), .starRating)
                        sortOption(L10n.text("Color label"), .colorLabel)
                        sortOption(L10n.text("Subfolder"), .subfolder, disabled: store.availableSubfolders.count <= 1)
                        sortOption(L10n.text("Folder hierarchy"), .folderHierarchy)
                            .help(L10n.text("Review folders before their subfolders; files stay chronological."))
                        sortOption(L10n.text("File type"), .fileType)
                        sortOption(L10n.text("Media type"), .mediaKind, disabled: store.availableMediaKinds.count <= 1)
                        sortOption(L10n.text("Camera"), .camera)
                        sortOption(L10n.text("Lens"), .lens)
                        sortOption(L10n.text("Aperture"), .aperture, disabled: store.apertureRange == nil)
                        sortOption(L10n.text("Shutter speed"), .shutterSpeed, disabled: store.shutterRange == nil)
                        sortOption("ISO", .iso, disabled: store.isoRange == nil)
                        sortOption(L10n.text("Media duration"), .duration, disabled: store.durationRange == nil)
                        sortOption(L10n.text("Video resolution"), .videoResolution,
                                   disabled: store.availableVideoResolutions.count <= 1)
                        sortOption(L10n.text("Video frame rate"), .videoFrameRate,
                                   disabled: store.videoFrameRateRange == nil)
                        sortOption(L10n.text("Video codec"), .videoCodec,
                                   disabled: store.availableVideoCodecs.count <= 1)
                    }
                    .accessibilityIdentifier("louppe.sortKey")

                    Picker(L10n.text("Order"), selection: $store.sort.ascending) {
                        Text(store.sort.key.ascendingLabel).tag(true)
                        Text(store.sort.key.descendingLabel).tag(false)
                    }
                    .accessibilityIdentifier("louppe.sortOrder")

                    Toggle(L10n.text("Divide into groups"), isOn: $store.isGroupingEnabled)
                        // Name sorting never divides: every file name is unique.
                        .disabled(store.sort.key == .name)
                }

                Section {
                    // Entering a group may first run asynchronous analysis, so
                    // these are explicit commands rather than an optimistic selection.
                    reviewModeButton(.exactDuplicates)
                    reviewModeButton(.likelySimilarPhotos)

                    if store.isGroupedReviewActive {
                        Button(L10n.text("Return to Normal Review")) {
                            store.exitGroupedReview()
                        }
                    }
                    if store.groupedReviewMode == .likelySimilarPhotos {
                        similarityControl
                    }
                } header: {
                    Text(L10n.text("Review groups"))
                } footer: {
                    Text(L10n.text("Grouping never changes ratings, originals, Clean Up, or Export."))
                }

                Section {
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
                        }
                    } else {
                        Button(
                            store.duplicateBurstAnalysisState == .ready
                                ? L10n.text("Refresh Local Analysis")
                                : L10n.text("Analyze Folder Locally")
                        ) {
                            store.analyzeDuplicateAndBurstGroups()
                        }
                        .disabled(store.items.isEmpty || store.isFileOperationRunning || store.photosBatch?.mediaSession != nil)
                    }
                } footer: {
                    Text(store.duplicateBurstAnalysisSummary)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.text("Done")) { store.isSortPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 380, height: 560)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
    }

    private func sortOption(_ label: String, _ key: PhotoSort.Key, disabled: Bool = false) -> some View {
        Text(label).tag(key).disabled(disabled)
    }

    private func reviewModeButton(_ mode: DuplicateBurstAnalysis.ReviewMode) -> some View {
        Button(mode.displayName) {
            store.enterGroupedReview(mode)
        }
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
