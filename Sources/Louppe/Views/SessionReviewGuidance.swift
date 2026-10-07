import SwiftUI

/// A single status strip below the media, with optional first-use guidance.
struct SessionReviewFooter: View {
    @ObservedObject var store: SessionStore
    @AppStorage("louppe.showQuickStart") private var showQuickStart = true

    var body: some View {
        VStack(spacing: 4) {
            if showQuickStart {
                HStack(spacing: 8) {
                    Text(L10n.text("F Yes · D No · arrows browse · ⌘Z undo. Decisions save automatically; No leaves files in place."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(L10n.text("F marks Yes; D marks No. Both advance to the next undecided item by default (Settings → Review). Arrows browse; ⌘Z undoes. Decisions save automatically; No never trashes files."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("Dismiss tips"), systemImage: "xmark") {
                        showQuickStart = false
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help(L10n.text("Hide this tip. See Help > Louppe Help for shortcuts."))
                }
            }

            HStack(spacing: 0) {
                Text(informationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(informationSummary)
                    .accessibilityLabel(informationSummary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Group {
                    if store.viewMode == .gallery,
                       let item = store.currentItem,
                       item.mediaKind == .photo && item.isSupported {
                        PhotoZoomControl(store: store)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: store.currentItem?.isRaw == true ? 300 : 240, height: 28)

                Text(store.sessionSaveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(L10n.text("Decisions, stars, and colors save automatically. Reopen this folder to continue. Export → Metadata (XMP) shares ratings with editing apps."))
                    .accessibilityLabel(L10n.text("Session: \(store.sessionSaveStatus)"))
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.appBackground)
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
            parts.append("Decision: " + (included.isEmpty ? L10n.text("none") : included.joined(separator: ", ")))
        }
        if !excludedStarStates.isEmpty { parts.append(L10n.text("Stars")) }
        if !excludedColorStates.isEmpty { parts.append(L10n.text("Color")) }
        if dateEnabled { parts.append(L10n.text("Date")) }
        if !excludedTypes.isEmpty { parts.append(L10n.text("File type")) }
        if !excludedMediaKinds.isEmpty { parts.append(L10n.text("Media type")) }
        if !excludedSubfolders.isEmpty { parts.append(L10n.text("Subfolder")) }
        if !excludedCameras.isEmpty { parts.append(L10n.text("Camera")) }
        if !excludedLenses.isEmpty { parts.append(L10n.text("Lens")) }
        if apertureEnabled || shutterEnabled || isoEnabled { parts.append(L10n.text("Exposure")) }
        if durationEnabled { parts.append(L10n.text("Duration")) }
        if videoFrameRateEnabled || !excludedVideoResolutions.isEmpty || !excludedVideoCodecs.isEmpty {
            parts.append(L10n.text("Video details"))
        }
        return "Filters: " + parts.joined(separator: " · ")
    }
}
