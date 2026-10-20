import SwiftUI

/// Session details live in the toolbar popover, leaving the media full height.
struct SessionReviewStatus: View {
    @ObservedObject var store: SessionStore
    @AppStorage("louppe.showQuickStart") private var showQuickStart = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !informationSummary.isEmpty {
                Text(informationSummary)
                    .font(.callout)
            }

            if showQuickStart {
                if !informationSummary.isEmpty { Divider() }
                Text(L10n.text("Use Yes and No to decide, and navigation controls to browse. ⌘Z undoes your last action. Decisions save automatically; No leaves files in place."))
                    .font(.callout)
                Button(L10n.text("Dismiss tips")) {
                    showQuickStart = false
                }
                .help(L10n.text("Hide this tip. See Help > Louppe Help for shortcuts."))
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var informationSummary: String {
        var parts: [String] = []
        if store.filter.isActive {
            parts.append(store.filter.reviewSummary)
        }
        if store.isReviewComplete && !store.isGroupedReviewActive {
            parts.append(L10n.text("Review complete: \(store.yesCount) Yes · \(store.noCount) No"))
        }
        return parts.joined(separator: "  ·  ")
    }
}

extension PhotoFilter {
    var reviewSummary: String {
        var parts: [String] = []
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty { parts.append(L10n.text("Search: “\(search)”")) }
        if !excludedDecisionStates.isEmpty {
            let choices: [(PhotoItemRatingState, String)] = [
                (.yes, L10n.text("Yes")), (.no, L10n.text("No")), (.undecided, L10n.text("Undecided")), (.mixed, L10n.text("Mixed"))
            ]
            let included = choices.filter { !excludedDecisionStates.contains($0.0) }.map(\.1)
            let decisions = included.isEmpty ? L10n.text("none") : included.joined(separator: ", ")
            parts.append(L10n.text("Decision: \(decisions)"))
        }
        if !excludedStarStates.isEmpty { parts.append(L10n.text("Stars")) }
        if !excludedColorStates.isEmpty { parts.append(L10n.text("Color")) }
        if dateEnabled { parts.append(L10n.text("Date")) }
        if !excludedTypes.isEmpty { parts.append(L10n.text("File type")) }
        if !excludedMediaKinds.isEmpty { parts.append(L10n.text("Media type")) }
        if !excludedSubfolders.isEmpty { parts.append(L10n.text("Subfolder")) }
        if !excludedCameras.isEmpty { parts.append(L10n.text("Camera")) }
        if !excludedLenses.isEmpty { parts.append(L10n.text("Lens")) }
        if !excludedFilmSimulations.isEmpty { parts.append(L10n.text("Film simulation")) }
        if apertureEnabled || shutterEnabled || isoEnabled { parts.append(L10n.text("Exposure")) }
        if durationEnabled { parts.append(L10n.text("Duration")) }
        if videoFrameRateEnabled || !excludedVideoResolutions.isEmpty || !excludedVideoCodecs.isEmpty {
            parts.append(L10n.text("Video details"))
        }
        return L10n.text("Filters: \(parts.joined(separator: " · "))")
    }
}
