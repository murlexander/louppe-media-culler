import SwiftUI

/// The confirmed result of Rename or Organize, including its error or the
/// ⌘Z reminder and an Undo button gated like the menu command.
struct SourceFileOperationOutcomeView: View {
    @ObservedObject var store: SessionStore
    let outcome: SourceOrganizationOutcome
    let kind: SourceFileChangeKind
    let done: () -> Void

    var body: some View {
        SheetForm(title: outcome.title(for: kind)) {
            Text(outcome.fileCountDescription(for: kind))
                .font(.headline)
            if let message = store.organizationError ?? outcome.message {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !outcome.wasUndo {
                Text(kind == .rename
                    ? L10n.text("Restore previous filenames with ⌘Z before closing this session.")
                    : L10n.text("Restore the previous layout with ⌘Z before closing this session."))
                    .foregroundStyle(.secondary)
            }
            if case .scanning = store.phase {
                ProgressView(L10n.text("Refreshing the session…"))
                    .padding(.top, kind == .rename ? 0 : 8)
            }
        } actions: {
            SheetActions {
                // The same step as ⌘Z, offered where the result is shown.
                if outcome.succeeded, !outcome.wasUndo, store.canUndo {
                    Button(L10n.text("Undo")) { store.undo() }
                        .disabled(store.isFileOperationRunning)
                }
            } trailing: {
                SheetPrimaryButton(L10n.text("Done"), runsOnReturn: true, action: done)
                    .disabled(store.isFileOperationRunning)
            }
        }
    }
}
