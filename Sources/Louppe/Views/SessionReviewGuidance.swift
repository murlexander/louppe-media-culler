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
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var informationSummary: String {
        guard store.isReviewComplete && !store.isGroupedReviewActive else { return "" }
        return L10n.text("Review complete: \(L10n.number(store.archiveYesCount)) Yes · \(L10n.number(store.archiveNoCount)) No")
    }
}
