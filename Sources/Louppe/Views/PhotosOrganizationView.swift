import SwiftUI

struct PhotosOrganizationView: View {
    @ObservedObject var model: PhotosOrganizationReviewModel
    let onConfirm: (PhotosOrganizationDraft) -> Void
    let onCancelWork: () -> Void
    let onDismiss: () -> Void
    let onReload: () -> Void

    private enum DestinationMode: Hashable { case existingAlbum, newAlbum }

    private struct Review: Equatable {
        let draft: PhotosOrganizationDraft
        let scopeLabel: String
        let count: Int
        let destinationPath: String
    }

    @State private var scope: SourceOrganizationScope = .selected
    @State private var destinationMode: DestinationMode = .existingAlbum
    @State private var albumIdentifier: String?
    @State private var parentFolderIdentifier: String?
    @State private var albumTitle = ""
    @State private var review: Review?
    @State private var cancellationRequested = false
    @State private var submitted = false

    var body: some View {
        SheetForm(title: title, layout: isSetup ? .grouped : .scrolling) {
            switch model.phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("Reading Photos albums and folders…"))
                }
            case .choosing:
                if let review {
                    confirmation(review)
                } else {
                    setup
                }
            case .working(let message, let completed, let total):
                progress(message: message, completed: completed, total: total)
            case .finished(let report):
                result(report)
            }
        } actions: {
            actions
        }
        .frame(width: 560, height: 510)
        .interactiveDismissDisabled(isWorking || submitted)
        .onChange(of: model.phase) { _, phase in
            if case .working = phase { return }
            cancellationRequested = false
            submitted = false
        }
    }

    private var isWorking: Bool {
        if case .working = model.phase { return true }
        return false
    }

    private var isSetup: Bool {
        if case .choosing = model.phase { return review == nil }
        return false
    }

    private var title: String {
        switch model.phase {
        case .loading: return L10n.text("Add to Album")
        case .choosing:
            return review == nil ? L10n.text("Add to Album") : L10n.text("Review Album Addition")
        case .working: return L10n.text("Adding to Album")
        case .finished(let report): return resultTitle(report)
        }
    }

    private var setup: some View {
        Group {
            Section {
                Picker(L10n.text("Scope"), selection: $scope) {
                    ForEach([SourceOrganizationScope.selected, .filtered, .all], id: \.self) { value in
                        Text(L10n.text("\(scopeLabel(value)): \(count(for: value).formatted())"))
                            .tag(value)
                    }
                }
            }
            Section {
                Picker(L10n.text("Destination"), selection: $destinationMode) {
                    Text(L10n.text("Existing album")).tag(DestinationMode.existingAlbum)
                    Text(L10n.text("New album")).tag(DestinationMode.newAlbum)
                }
                if destinationMode == .existingAlbum {
                    Picker(L10n.text("Album"), selection: $albumIdentifier) {
                        Text(L10n.text("Choose an album…")).tag(String?.none)
                        ForEach(albumOptions) { option in
                            Text(verbatim: option.label).tag(Optional(option.id))
                        }
                    }
                    if albumOptions.isEmpty, model.hierarchyError == nil {
                        Text(L10n.text("No writable albums. Create a new album instead."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    TextField(L10n.text("Album name"), text: $albumTitle)
                    Picker(L10n.text("Parent folder"), selection: $parentFolderIdentifier) {
                        if model.canCreateTopLevelAlbum {
                            Text(L10n.text("Photos Library")).tag(String?.none)
                        } else {
                            Text(L10n.text("Choose a folder…")).tag(String?.none)
                        }
                        ForEach(folderOptions) { option in
                            Text(verbatim: option.label).tag(Optional(option.id))
                        }
                    }
                }
            } footer: {
                Text(L10n.text("Photos folders contain albums. Additions keep existing album memberships and leave originals in your library."))
            }
            Section {
                if let error = model.hierarchyError {
                    Text(verbatim: error)
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(L10n.text("Reload albums and folders")) { onReload() }
                if count(for: scope) == 0 {
                    Text(L10n.text("No items in this scope."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(submitted)
    }

    private func confirmation(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent(L10n.text("Scope"), value: review.scopeLabel)
            LabeledContent(L10n.text("Items"), value: review.count.formatted())
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Destination")).font(.headline)
                Text(verbatim: review.destinationPath)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if case .newAlbum = review.draft.destination {
                Text(L10n.text("A new album will be created at this location."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("Add these items to this album? Existing album memberships and originals stay unchanged."))
                .fixedSize(horizontal: false, vertical: true)
            if currentReview != review {
                Text(L10n.text("The scope or destination changed. Go back and review again."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progress(message: String, completed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if total > 0 {
                ProgressView(value: Double(max(0, min(completed, total))), total: Double(total))
                    .accessibilityLabel(L10n.text("Album update progress"))
                Text(L10n.text("\(max(0, completed).formatted()) of \(total.formatted()) items processed"))
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
            if cancellationRequested {
                Text(L10n.text("Finishing and checking the current update…"))
                    .font(.callout)
            }
            Text(L10n.text("Cancel finishes and checks the current update. Completed additions remain in Photos."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func result(_ report: PhotosOrganizationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = report.destinationPath {
                Text(L10n.text("Requested destination: \(path)"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            LabeledContent(L10n.text("Requested"), value: report.requested.formatted())
            LabeledContent(L10n.text("Verified in album"), value: report.verified.formatted())
            LabeledContent(L10n.text("Already in album (included above)"), value: report.alreadyPresent.formatted())
            LabeledContent(L10n.text("Unavailable items"), value: report.missing.formatted())
            LabeledContent(L10n.text("Uncertain memberships"), value: report.uncertain.formatted())
            LabeledContent(L10n.text("Not processed"), value: report.unprocessed.formatted())
            if let message = report.message {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if report.uncertain > 0 {
                Text(L10n.text("Some additions could not be verified. Check the album in Photos before trying again."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("Verified memberships include items already in the album. Completed additions remain in Photos."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .loading:
                Spacer()
                dismissButton
            case .choosing:
                if review != nil {
                    Button(L10n.text("Back")) { review = nil }
                        .disabled(submitted)
                }
                Spacer()
                dismissButton.disabled(submitted)
                if let review {
                    Button(L10n.text("Add to Album")) {
                        guard !submitted, currentReview == review else { return }
                        submitted = true
                        onConfirm(review.draft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.louppeFilledAccent)
                    .disabled(submitted || currentReview != review)
                } else {
                    Button(L10n.text("Review")) { review = currentReview }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.louppeFilledAccent)
                        .disabled(currentReview == nil || submitted)
                }
            case .working:
                Spacer()
                Button(cancellationRequested ? L10n.text("Cancelling…") : L10n.text("Cancel"), role: .cancel) {
                    guard !cancellationRequested else { return }
                    cancellationRequested = true
                    onCancelWork()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancellationRequested)
            case .finished:
                Spacer()
                Button(L10n.text("Done")) { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var dismissButton: some View {
        Button(L10n.text("Cancel"), role: .cancel) { onDismiss() }
            .keyboardShortcut(.cancelAction)
    }

    private func count(for scope: SourceOrganizationScope) -> Int {
        max(0, model.scopeCounts[scope] ?? 0)
    }

    private func scopeLabel(_ scope: SourceOrganizationScope) -> String {
        scope == .selected ? model.selectionLabel : scope.label
    }

    private var currentReview: Review? {
        guard model.hierarchyError == nil, count(for: scope) > 0 else { return nil }
        let destination: PhotosOrganizationDraftDestination
        let path: String
        switch destinationMode {
        case .existingAlbum:
            guard let option = albumIdentifier.flatMap({ model.choices.albumsByID[$0] }) else { return nil }
            destination = .existingAlbum(id: option.id)
            path = option.label
        case .newAlbum:
            let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let parentPath: String
            if let parentFolderIdentifier {
                guard let option = model.choices.foldersByID[parentFolderIdentifier] else { return nil }
                parentPath = option.label
            } else {
                guard model.canCreateTopLevelAlbum else { return nil }
                parentPath = L10n.text("Photos Library")
            }
            destination = .newAlbum(title: title, parentFolderIdentifier: parentFolderIdentifier)
            path = parentPath + " › " + title
        }
        return Review(draft: PhotosOrganizationDraft(scope: scope, destination: destination),
                      scopeLabel: scopeLabel(scope), count: count(for: scope), destinationPath: path)
    }

    private var albumOptions: [PhotosOrganizationCollectionOption] { model.choices.albums }
    private var folderOptions: [PhotosOrganizationCollectionOption] { model.choices.folders }

    private func resultTitle(_ report: PhotosOrganizationReport) -> String {
        switch report.disposition {
        case .completed:
            guard report.requested > 0, report.verified == report.requested,
                  report.missing == 0, report.uncertain == 0, report.unprocessed == 0 else {
                return L10n.text("Album Addition Incomplete")
            }
            return L10n.text("Album Addition Complete")
        case .partial: return L10n.text("Album Addition Incomplete")
        case .cancelled: return L10n.text("Album Addition Cancelled")
        case .failed: return L10n.text("Album Addition Failed")
        }
    }
}
