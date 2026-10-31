import SwiftUI

struct RenameFilesView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var scope: SourceOrganizationScope = .selected
    @State private var metadataConfiguration = FileRenamingConfiguration.initial
    @State private var customBaseName: String
    @State private var partDragID = UUID().uuidString
    @State private var targetedPart: FileRenamingPartKind?
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
        .controlSize(.regular)
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
        SheetForm(title: L10n.text("Rename File"), layout: .grouped) {
            Section(L10n.text("Name")) {
                LabeledContent(L10n.text("New base name")) {
                    HStack(spacing: 6) {
                        TextField(L10n.text("New base name"), text: $customBaseName)
                            .labelsHidden()
                            .focused($customNameIsFocused)
                            .onSubmit { runSingleRename() }
                            .accessibilityLabel(L10n.text("New base name"))
                            .accessibilityHint(singleFamilyExplanation)
                        Text(extensionSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section(L10n.text("Preview")) { preview }
        } actions: {
            HStack(spacing: 12) {
                planningIndicator
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isRenamePresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text("Rename")) { runSingleRename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.louppeFilledAccent)
                    .disabled(plan?.canExecute != true || isPlanning)
            }
        }
    }

    private var metadataSetup: some View {
        SheetForm(title: L10n.text("Rename Files"), layout: .grouped) {
            Section {
                ArchiveActionScopeNote(store: store)
                Picker(L10n.text("Apply to"), selection: $scope) {
                    ForEach(SourceOrganizationScope.allCases, id: \.self) {
                        value in
                        Text("\(value == .all ? store.archiveAllScopeLabel : value.label) (\(store.organizationScopeCount(for: value)))")
                            .tag(value)
                    }
                }
            }

            Section(L10n.text("Filename parts")) {
                ForEach(metadataConfiguration.parts) { part in
                    filenamePartRow(part)
                }
            }

            Section(L10n.text("Preview")) { preview }
        } actions: {
            HStack(spacing: 12) {
                planningIndicator
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isRenamePresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text("Review Rename…")) { isReviewing = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.louppeFilledAccent)
                    .disabled(plan?.canExecute != true || isPlanning)
            }
        }
    }

    private func filenamePartRow(_ part: FileRenamingPart) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Toggle(part.kind.label, isOn: partBinding(part.kind))
                .toggleStyle(LouppeToggleStyle(.checkbox))
                .accessibilityIdentifier("rename.part.\(part.kind.rawValue)")
                .accessibilityAction(named: L10n.text("Move \(part.kind.label) earlier")) {
                    movePart(part.kind, offset: -1)
                }
                .accessibilityAction(named: L10n.text("Move \(part.kind.label) later")) {
                    movePart(part.kind, offset: 1)
                }
            Spacer()
        }
        .contentShape(Rectangle())
        .opacity(part.isEnabled ? 1 : 0.62)
        .overlay {
            if targetedPart == part.kind {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.louppeAccent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        // Scope text transfers to this sheet; unrelated text and drags from
        // another rename window cannot reorder its configuration.
        .draggable("\(partDragID):\(part.kind.rawValue)")
        .dropDestination(for: String.self) { payloads, _ in
            guard payloads.count == 1,
                  payloads[0].hasPrefix(partDragID + ":"),
                  let source = FileRenamingPartKind(rawValue:
                    String(payloads[0].dropFirst(partDragID.count + 1)))
            else { return false }
            var changed = false
            withAnimation(reduceMotion ? nil : .default) {
                changed = metadataConfiguration.movePart(source, to: part.kind)
            }
            return changed
        } isTargeted: { targeted in
            if targeted {
                targetedPart = part.kind
            } else if targetedPart == part.kind {
                targetedPart = nil
            }
        }
        .contextMenu {
            Button(L10n.text("Move \(part.kind.label) earlier")) {
                movePart(part.kind, offset: -1)
            }
            .disabled(metadataConfiguration.parts.first?.kind == part.kind)
            Button(L10n.text("Move \(part.kind.label) later")) {
                movePart(part.kind, offset: 1)
            }
            .disabled(metadataConfiguration.parts.last?.kind == part.kind)
        }
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
                            Image(systemName: layoutDirection == .rightToLeft ? "arrow.left" : "arrow.right")
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
            }
        } else {
            Text(L10n.text("Choose at least one filename part."))
                .foregroundStyle(.secondary)
        }
    }

    private func confirmationView(_ plan: SourceOrganizationPlan) -> some View {
        SheetForm(title: L10n.text("Rename \(plan.movingFileCount) files?")) {
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
        } actions: {
            HStack(spacing: 12) {
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
                .tint(Color.louppeFilledAccent)
            }
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
        SheetForm(title: outcome.title(for: .rename)) {
            Text(outcome.fileCountDescription(for: .rename))
                .foregroundStyle(.secondary)
            if let message = store.organizationError ?? outcome.message {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !outcome.wasUndo {
                Text(L10n.text("Restore previous filenames with ⌘Z before closing this session."))
                    .foregroundStyle(.secondary)
            }
            if case .scanning = store.phase {
                ProgressView(L10n.text("Refreshing the session…"))
            }
        } actions: {
            HStack(spacing: 12) {
                Spacer()
                Button(L10n.text("Done")) { store.isRenamePresented = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.louppeFilledAccent)
                    .disabled(store.isFileOperationRunning)
            }
        }
    }

    @ViewBuilder
    private var planningIndicator: some View {
        if isPlanning {
            ProgressView().controlSize(.small)
                .accessibilityLabel(L10n.text("Checking filenames and sidecars…"))
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

    private func movePart(_ kind: FileRenamingPartKind, offset: Int) {
        withAnimation(reduceMotion ? nil : .default) {
            _ = metadataConfiguration.movePart(kind, offset: offset)
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
