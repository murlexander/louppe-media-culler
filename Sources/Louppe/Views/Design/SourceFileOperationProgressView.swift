import SwiftUI

/// Rename and Organize while their worker moves files. Shown as soon as the
/// operation starts; the result sheet appears only after the worker reports.
struct SourceFileOperationProgressView: View {
    let title: String
    var subtitle: String? = nil
    let progress: SourceOrganizationProgress
    let headline: String

    var body: some View {
        SheetForm(title: title, subtitle: subtitle) {
            Text(headline)
                .font(.headline)
            ProgressView(
                value: Double(progress.done),
                total: Double(max(progress.total, 1))
            )
            .accessibilityLabel(headline)
            .accessibilityValue(L10n.text("\(progress.done) of \(progress.total) files"))
            Text(L10n.text("\(progress.done) of \(progress.total) files"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(L10n.text("Keep Louppe open until file work finishes."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            SheetActions {}
            }
    }
}
