import SwiftUI

struct RenameFilesView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scope: SourceOrganizationScope = .selected
    @State private var metadataConfiguration = FileRenamingConfiguration.initial
    @State private var customBaseName: String
    @State private var plan: SourceOrganizationPlan?
    @State private var planningError: String?
    @State private var isPlanning = false
    @State private var isReviewing = false
    @State private var planningTask: Task<Void, Never>?
    @State private var planningCancelFlag:
        SourceOrganizationPlanningCancelFlag?
    @FocusState private var customNameIsFocused: Bool

    private var mode: FileRenamingPresentationMode {
        store.fileRenamingPresentationMode
    }

    private var isSingle: Bool {
        if case .single = mode { return true }
        return false
    }

    init(store: SessionStore) {
        self.store = store
        let initialName: String
        if case .single(let itemID) = store.fileRenamingPresentationMode,
           let item = store.items.first(where: { $0.id == itemID }) {
            initialName = (item.displayName as NSString).deletingPathExtension
        } else {
            initialName = ""
        }
        _customBaseName = State(initialValue: initialName)
    }

    var body: some View {
        Group {
            if let progress = store.organizationProgress {
                progressView(progress)
            } else if let outcome = store.organizationOutcome {
                outcomeView(outcome)
            } else if isReviewing, let plan {
                confirmationView(plan)
            } else if isSingle {
                singleSetup
            } else {
                metadataSetup
            }
        }
        .frame(width: isSingle ? 540 : 680, height: isSingle ? 460 : 650)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
        .interactiveDismissDisabled(store.isFileOperationRunning)
        .onAppear {
            refreshPlan()
            if isSingle {
                DispatchQueue.main.async { customNameIsFocused = true }
            }
        }
        .onDisappear {
            planningCancelFlag?.cancel()
            planningTask?.cancel()
        }
        .onChange(of: scope) { refreshPlan() }
        .onChange(of: metadataConfiguration) { refreshPlan() }
        .onChange(of: customBaseName) { refreshPlan() }
    }

    private var singleSetup: some View {
        VStack(spacing: 0) {
            header(
                L10n.text("Rename File"),
                subtitle: L10n.text("Change the name while keeping every file extension.")
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Name"))
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            TextField(L10n.text("New base name"), text: $customBaseName)
                                .textFieldStyle(.roundedBorder)
                                .focused($customNameIsFocused)
                                .onSubmit { runSingleRename() }
                                .accessibilityLabel(L10n.text("New base name"))
                                .accessibilityHint(singleFamilyExplanation)
                            Text(extensionSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(singleFamilyExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                    preview
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            Divider()
            HStack {
                planningIndicator
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isRenamePresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text("Rename")) { runSingleRename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.louppeAccent)
                    .disabled(plan?.canExecute != true || isPlanning)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private var metadataSetup: some View {
        VStack(spacing: 0) {
            header(
                L10n.text("Rename Files"),
                subtitle: L10n.text("Build sortable filenames from capture metadata.")
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(L10n.text("Apply to")) {
                        Picker(L10n.text("Apply to"), selection: $scope) {
                            ForEach(SourceOrganizationScope.allCases, id: \.self) {
                                value in
                                Text("\(value.label) (\(store.organizationScopeCount(for: value)))")
                                    .tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Divider()
                    section(L10n.text("Filename parts")) {
                        Text(L10n.text("Enabled parts form names in this order, separated by underscores. Extensions stay unchanged."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            ForEach(metadataConfiguration.parts) { part in
                                filenamePartRow(part)
                                if part.id != metadataConfiguration.parts.last?.id {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    Color(nsColor: .separatorColor),
                                    lineWidth: 1
                                )
                        }
                        Text(L10n.text("Sequence follows capture time, then original path. Keep it when shots share a second."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                    section(L10n.text("Preview")) { preview }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                planningIndicator
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isRenamePresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text("Review Rename…")) { isReviewing = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.louppeAccent)
                    .disabled(plan?.canExecute != true || isPlanning)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private func filenamePartRow(_ part: FileRenamingPart) -> some View {
        HStack(spacing: 10) {
            Toggle(part.kind.label, isOn: partBinding(part.kind))
                .toggleStyle(.checkbox)
            Spacer()
            if part.isEnabled {
                Button {
                    movePart(part.kind, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(enabledIndex(of: part.kind) == 0)
                .accessibilityLabel(L10n.text("Move \(part.kind.label) earlier"))

                Button {
                    movePart(part.kind, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(
                    enabledIndex(of: part.kind)
                        == metadataConfiguration.enabledParts.count - 1
                )
                .accessibilityLabel(L10n.text("Move \(part.kind.label) later"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 42)
        .opacity(part.isEnabled ? 1 : 0.62)
    }

    @ViewBuilder
    private var preview: some View {
        if let operationError = store.organizationError {
            VStack(alignment: .leading, spacing: 8) {
                Label(operationError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Retry Saving")) {
                    store.organizationError = nil
                    store.retryPersistence()
                }
                .disabled(!store.canRetryPersistence)
            }
            .accessibilityElement(children: .combine)
        } else if let planningError {
            Label(planningError, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let plan {
            let changed = changedMediaMappings(in: plan)
            if changed.isEmpty {
                Label(L10n.text("The filenames are already unchanged."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(changed.prefix(6).enumerated()), id: \.offset) {
                        _, mapping in
                        HStack(spacing: 8) {
                            Text(mapping.source.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(mapping.destination.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.body.monospaced())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            L10n.text("\(mapping.source.lastPathComponent), becomes \(mapping.destination.lastPathComponent)")
                        )
                    }
                    if changed.count > 6 {
                        Text(L10n.text("…and \(changed.count - 6) more media files"))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    summary(L10n.text("\(plan.movingItemCount) items"))
                    summary(L10n.text("\(changed.count) media files"))
                    if plan.sidecarFileCount > 0 {
                        summary(L10n.text("\(plan.sidecarFileCount) XMP"))
                    }
                }
            }

            if !plan.collisions.isEmpty {
                Label(
                    (plan.collisions.count == 1 ? L10n.text("Resolve \(plan.collisions.count) filename conflict before renaming.") : L10n.text("Resolve \(plan.collisions.count) filename conflicts before renaming.")),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                ForEach(plan.collisions.prefix(3)) { conflict in
                    Text(conflict.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if plan.excludedACRCompanionCount > 0 {
                Text(L10n.text("Lightroom .acr companions stay untouched."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !changed.isEmpty {
                Text(L10n.text("Nothing is overwritten. RAW + JPEG partners and recognized XMP sidecars keep matching names."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(L10n.text("Choose at least one filename part."))
                .foregroundStyle(.secondary)
        }
    }

    private func confirmationView(_ plan: SourceOrganizationPlan) -> some View {
        VStack(spacing: 0) {
            header(
                L10n.text("Rename \(plan.movingFileCount) files?"),
                subtitle: L10n.text("Review the exact source-folder change before Louppe renames anything.")
            )
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    Divider()
                    Text(L10n.text("Folders, contents, and extensions stay unchanged. Nothing is overwritten. Restore all previous names with ⌘Z before closing this session."))
                        .fixedSize(horizontal: false, vertical: true)
                    if plan.storageSafety.usesReducedDirectoryDurability {
                        Label(
                            L10n.text("This ExFAT card has reduced crash protection. Do not eject it or close the Mac until renaming finishes."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button(L10n.text("Back")) { isReviewing = false }
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isRenamePresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    plan.storageSafety.usesReducedDirectoryDurability
                        ? L10n.text("Rename Files Anyway")
                        : L10n.text("Rename Files")
                ) {
                    store.startSourceRename(plan)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.louppeAccent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private func progressView(_ progress: SourceOrganizationProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView(
                value: Double(progress.done),
                total: Double(max(progress.total, 1))
            )
            .accessibilityLabel(progress.title)
            .accessibilityValue(L10n.text("\(progress.done) of \(progress.total) files"))
            .frame(width: 360)
            Text(progress.action == .restoring
                ? L10n.text("Restoring previous filenames…")
                : L10n.text("Renaming files…"))
                .font(.headline)
            Text(L10n.text("\(progress.done) of \(progress.total) files"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(L10n.text("Keep Louppe open until file work finishes."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(30)
    }

    private func outcomeView(_ outcome: SourceOrganizationOutcome) -> some View {
        VStack(spacing: 16) {
            Image(systemName: outcome.succeeded
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(outcome.succeeded
                    ? Color.louppeAccent
                    : Color.secondary)
            Text(outcome.title(for: .rename))
                .font(.title2.weight(.semibold))
            Text(outcome.fileCountDescription(for: .rename))
                .foregroundStyle(.secondary)
            if let message = store.organizationError ?? outcome.message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else if !outcome.wasUndo {
                Text(L10n.text("Restore previous filenames with ⌘Z before closing this session."))
                    .foregroundStyle(.secondary)
            }
            if case .scanning = store.phase {
                ProgressView(L10n.text("Refreshing the session…"))
            }
            Button(L10n.text("Done")) { store.isRenamePresented = false }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(store.isFileOperationRunning)
        }
        .padding(30)
    }

    private func header(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    @ViewBuilder
    private var planningIndicator: some View {
        if isPlanning {
            ProgressView().controlSize(.small)
            Text(L10n.text("Checking filenames and sidecars…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var extensionSummary: String {
        guard let plan else { return "" }
        let suffixes = plan.mappings.filter(\.isMedia).map {
            let ext = $0.source.pathExtension
            return ext.isEmpty ? "" : ".\(ext)"
        }
        return Array(Set(suffixes)).sorted().joined(separator: " + ")
    }

    private var singleFamilyExplanation: String {
        let mediaCount = plan?.mappings.filter(\.isMedia).count ?? 1
        return mediaCount > 1
            ? L10n.text("Renames matching RAW + JPEG and recognized XMP together. Lightroom .acr companions stay unchanged.")
            : L10n.text("The extension stays unchanged. Recognized XMP sidecars follow; Lightroom .acr companions are never changed.")
    }

    private func changedMediaMappings(
        in plan: SourceOrganizationPlan
    ) -> [SourceOrganizationFileMapping] {
        plan.mappings.filter {
            $0.isMedia
                && FileOperationJournal.exactPathBytes(for: $0.source)
                    != FileOperationJournal.exactPathBytes(for: $0.destination)
        }
    }

    private func partBinding(_ kind: FileRenamingPartKind) -> Binding<Bool> {
        Binding(
            get: {
                metadataConfiguration.parts.first(where: { $0.kind == kind })?
                    .isEnabled ?? false
            },
            set: { value in
                guard let index = metadataConfiguration.parts.firstIndex(
                    where: { $0.kind == kind }
                ) else { return }
                metadataConfiguration.parts[index].isEnabled = value
            }
        )
    }

    private func enabledIndex(of kind: FileRenamingPartKind) -> Int? {
        metadataConfiguration.enabledParts.firstIndex(where: {
            $0.kind == kind
        })
    }

    private func movePart(_ kind: FileRenamingPartKind, offset: Int) {
        let enabled = metadataConfiguration.enabledParts
        guard let enabledIndex = enabled.firstIndex(where: {
            $0.kind == kind
        }) else { return }
        let destination = enabledIndex + offset
        guard enabled.indices.contains(destination),
              let from = metadataConfiguration.parts.firstIndex(where: {
                $0.kind == kind
              }),
              let to = metadataConfiguration.parts.firstIndex(where: {
                $0.kind == enabled[destination].kind
              }) else { return }
        withAnimation(reduceMotion ? nil : .default) {
            metadataConfiguration.parts.swapAt(from, to)
        }
    }

    private func runSingleRename() {
        guard let plan, plan.canExecute, !isPlanning else {
            customNameIsFocused = true
            return
        }
        customNameIsFocused = false
        store.startSourceRename(plan)
    }

    private func refreshPlan() {
        planningCancelFlag?.cancel()
        planningTask?.cancel()
        isReviewing = false
        planningError = nil
        guard let snapshot = store.sourceFileRenamingPlanningSnapshot(
            scope: scope
        ) else {
            plan = nil
            isPlanning = false
            return
        }
        let sourceConfiguration: SourceOrganizationConfiguration
        switch mode {
        case .single:
            sourceConfiguration = FileRenamingPlanner.sourceConfiguration(
                customBaseName: customBaseName
            )
        case .metadata:
            guard !metadataConfiguration.enabledParts.isEmpty else {
                plan = nil
                isPlanning = false
                return
            }
            sourceConfiguration = FileRenamingPlanner.sourceConfiguration(
                metadata: metadataConfiguration
            )
        }
        let cancelFlag = SourceOrganizationPlanningCancelFlag()
        planningCancelFlag = cancelFlag
        isPlanning = true
        planningTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try SourceOrganizationPlanner.makePlan(
                        sourceFolder: snapshot.sourceFolder,
                        selectedItems: snapshot.selectedItems,
                        familyContextItems: snapshot.familyContextItems,
                        configuration: sourceConfiguration,
                        knownOriginFolderPathBytesByFileID:
                            snapshot.knownOriginFolderPathBytesByFileID,
                        pairedFiles: snapshot.pairedFiles,
                        isCancelled: { cancelFlag.isCancelled }
                    )
                }
            }.value
            guard !Task.isCancelled, !cancelFlag.isCancelled else { return }
            planningCancelFlag = nil
            isPlanning = false
            switch result {
            case .success(let prepared):
                plan = prepared
                planningError = nil
            case .failure(let error):
                plan = nil
                planningError = error.localizedDescription
            }
        }
    }
}
