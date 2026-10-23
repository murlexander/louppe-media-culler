import SwiftUI

struct SessionRecoveryBanner: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.pendingSessionRecoveryEntries.isEmpty
                  ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.louppeAccent)
            Text(store.sessionRecoveryNotice)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .checking(let done, let total) = store.sessionContentCheck {
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .frame(width: 70)
                    .accessibilityLabel(L10n.text("Checking file contents: \(done) of \(total)"))
            }
            Button(L10n.text("Check and Restore…")) { store.isSessionRecoveryPresented = true }
                .disabled(store.isFileOperationRunning)
            Button {
                store.dismissSessionRecoveryNotice()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Dismiss notification"))
            .accessibilityLabel(L10n.text("Dismiss notification"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        Divider()
    }
}

struct SessionRecoveryView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()
    @State private var confirmsSamePhotos = false

    var body: some View {
        SheetForm(title: L10n.text("Check Saved Decisions")) {
            Text(L10n.text("Identical copies restore automatically. Older sessions need your confirmation. Current decisions are kept, and previous decisions remain in recovery history."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            checkProgress
            Divider()
            HStack {
                Text(L10n.text("Previous decisions"))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.text("Select All")) {
                    selected = Set(store.pendingSessionRecoveryEntries.map(\.id))
                    confirmsSamePhotos = false
                }
                .disabled(store.pendingSessionRecoveryEntries.isEmpty)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.pendingSessionRecoveryEntries) { record in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { selected.contains(record.id) },
                            set: { value in
                                if value { selected.insert(record.id) }
                                else { selected.remove(record.id) }
                                confirmsSamePhotos = false
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName(record)).lineLimit(2).textSelection(.enabled)
                                Text(previousMetadata(record.entry))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 12)
                        Text(store.sessionRecoveryStatus(record))
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 200, alignment: .trailing)
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
                if store.pendingSessionRecoveryEntries.isEmpty {
                    Text(L10n.text("No saved decisions need attention."))
                        .foregroundStyle(.secondary).padding(.vertical, 24)
                }
                let history = store.sessionRecoveryEntries.filter { $0.resolvedFileID != nil }
                if !history.isEmpty {
                    DisclosureGroup(L10n.text("Recovery History")) {
                        ForEach(history) { record in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(displayName(record))
                                    Text(previousMetadata(record.entry)).font(.caption)
                                }
                                Spacer()
                                Text(L10n.text("Restored or kept in history")).font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.top, 10)
                }
            }
        } actions: {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.text("I confirm the selected files are the same photos or videos."),
                       isOn: $confirmsSamePhotos)
                    .toggleStyle(.checkbox)
                    .disabled(selected.isEmpty)
                Text(L10n.text("Restoring applies the selected previous decisions only to files you have not reviewed. It does not change media files."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(L10n.text("Keep Current Decisions")) {
                        store.keepCurrentSessionDecisions(selected)
                        selected = []
                        confirmsSamePhotos = false
                    }
                    .disabled(selected.isEmpty || store.isFileOperationRunning)
                    Spacer()
                    Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("Restore Selected Decisions")) {
                        store.restoreSessionRecoveryEntries(selected)
                        selected = []
                        confirmsSamePhotos = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasRestorableSelection || !confirmsSamePhotos || store.isFileOperationRunning)
                }
            }
        }
        .frame(width: 660, height: 620)
    }

    private var hasRestorableSelection: Bool {
        let records = store.pendingSessionRecoveryEntries.filter {
            selected.contains($0.id) && store.canRestoreSessionRecoveryEntry($0)
        }
        return !records.isEmpty && Set(records.compactMap { store.recoveryFile(for: $0)?.id }).count == records.count
    }

    @ViewBuilder private var checkProgress: some View {
        HStack(spacing: 12) {
            switch store.sessionContentCheck {
            case .checking(let done, let total):
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .frame(width: 100)
                    .accessibilityLabel(L10n.text("Checking file contents: \(done) of \(total)"))
                Text(L10n.text("Checking file contents: \(done) of \(total)"))
                Spacer()
                Button(L10n.text("Pause")) { store.toggleSessionContentChecks() }
            case .paused:
                Text(L10n.text("Content checks paused"))
                Spacer()
                Button(L10n.text("Resume Checks")) { store.toggleSessionContentChecks() }
                    .disabled(store.isFileOperationRunning)
            case .finished, .idle:
                Text(L10n.text("Previous decisions are preserved."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func displayName(_ record: SessionRecoveryEntry) -> String {
        record.entry.filename.removingPercentEncoding ?? record.entry.filename
    }

    private func previousMetadata(_ entry: SessionEntry) -> String {
        var labels = [String]()
        switch Rating(rawValue: entry.rating) ?? .undecided {
        case .yes: labels.append(L10n.text("Yes"))
        case .no: labels.append(L10n.text("No"))
        case .undecided: labels.append(L10n.text("Undecided"))
        }
        if let stars = entry.stars { labels.append(String(repeating: "★", count: stars.count)) }
        if let color = entry.colorLabel { labels.append(color.localizedDisplayName) }
        return labels.joined(separator: " · ")
    }
}
