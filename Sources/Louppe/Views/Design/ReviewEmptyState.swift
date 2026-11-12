import SwiftUI

/// Which empty presentation a review pane shows, in priority order. Gallery and
/// Grid resolve through this one rule so their states and remedies match.
enum ReviewEmptyState: Equatable {
    /// No media left in the session (Clean Up, Move export, failed restore).
    case session
    /// Grouped review (bursts or similar groups) has nothing to show.
    case groupedReview
    /// The selected folder is empty; clearing filters would not help.
    case emptyFolder
    /// Filters hide every item.
    case filterEmpty

    static func resolve(
        hasItems: Bool, hasVisibleItems: Bool, isGroupedReviewActive: Bool,
        isInArchiveFolder: Bool, isFilterActive: Bool, archiveScopeCount: Int
    ) -> Self? {
        if !hasItems { return .session }
        guard !hasVisibleItems else { return nil }
        if isGroupedReviewActive { return .groupedReview }
        // An empty folder stays empty without filters; don't suggest clearing them.
        if isInArchiveFolder && (!isFilterActive || archiveScopeCount == 0) { return .emptyFolder }
        if isFilterActive { return .filterEmpty }
        return nil
    }

    @MainActor
    init?(store: SessionStore) {
        guard let state = Self.resolve(
            hasItems: !store.items.isEmpty,
            hasVisibleItems: !store.visibleIndices.isEmpty,
            isGroupedReviewActive: store.isGroupedReviewActive,
            isInArchiveFolder: !store.archiveSelectedFolderID.isEmpty,
            isFilterActive: store.filter.isActive,
            archiveScopeCount: store.archiveScopeCount
        ) else { return nil }
        self = state
    }
}

/// The view for a resolved `ReviewEmptyState`. Grid passes a top inset to
/// place system messages near the top; the folder-empty view keeps its own.
struct ReviewEmptyStateView: View {
    @ObservedObject var store: SessionStore
    let state: ReviewEmptyState
    var topPadding: CGFloat = 0

    var body: some View {
        switch state {
        case .session:
            SessionEmptyView(reason: store.emptySessionReason, canUndo: store.canUndo)
                .padding(.top, topPadding)
        case .groupedReview:
            ContentUnavailableView(
                store.groupedReviewEmptyTitle,
                systemImage: "rectangle.3.group",
                description: Text(store.groupedReviewEmptyDescription)
            )
            .padding(.top, topPadding)
        case .emptyFolder:
            ArchiveFolderEmptyView(store: store)
        case .filterEmpty:
            ContentUnavailableView {
                Label(L10n.text("No items match the filter"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(L10n.text("Change or clear filters to show media."))
            } actions: {
                Button(L10n.text("Clear Filters")) { store.resetFilter() }
            }
            .padding(.top, topPadding)
        }
    }
}
