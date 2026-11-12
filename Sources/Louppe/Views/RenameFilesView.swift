import SwiftUI

struct RenameFilesView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    @State private var scope: SourceOrganizationScope = .selected
    @State private var metadataConfiguration = FileRenamingConfiguration.initial
    @State private var customBaseName: String
    @State private var partDrag = ReorderDragState<FileRenamingPartKind>()
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

    /// A finished rename with no error is a short confirmation, not a form.
    private var sheetHeight: CGFloat {
        if store.organizationProgress == nil, let outcome = store.organizationOutcome,
           store.organizationError == nil, outcome.message == nil {
            return 250
        }
        return isSingle ? 460 : 650
    }

    var body: some View {
        Group {
            if let progress = store.organizationProgress {
                SourceFileOperationProgressView(
                    title: isSingle ? L10n.text("Rename File") : L10n.text("Rename Files"),
                    progress: progress,
                    headline: progress.action == .restoring
                        ? L10n.text("Restoring previous filenames…")
                        : L10n.text("Renaming files…")
                )
            } else if let outcome = store.organizationOutcome {
                SourceFileOperationOutcomeView(
                    store: store, outcome: outcome, kind: .rename
                ) { store.isRenamePresented = false }
            } else if isReviewing, let plan {
                confirmationView(plan)
            } else if isSingle {
                singleSetup
            } else {
                metadataSetup
            }
        }
        .frame(width: isSingle ? 540 : 680, height: sheetHeight)
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
            SheetActions {
                planningIndicator
            } trailing: {
                SheetCancelButton { store.isRenamePresented = false }
                SheetPrimaryButton(L10n.text("Rename"), runsOnReturn: true) { runSingleRename() }
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
                        Text("\(value == .all ? store.archiveAllScopeLabel : value.label) (\(L10n.number(store.organizationScopeCount(for: value))))")
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
            SheetActions {
                planningIndicator
            } trailing: {
                SheetCancelButton { store.isRenamePresented = false }
                SheetPrimaryButton(L10n.text("Review Rename…"), runsOnReturn: true) { isReviewing = true }
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
        .reorderableRow(
            part.kind,
            in: metadataConfiguration.parts.map(\.kind),
            state: $partDrag,
            sectionEdges: .all
        ) { source, offset in
            metadataConfiguration.parts.move(
                fromOffsets: IndexSet(integer: source), toOffset: offset)
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
                        Text(L10n.plural("…and %lld more media files", changed.count - 6))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    summary(L10n.plural("%lld items", plan.movingItemCount))
                    summary(L10n.plural("%lld media files", changed.count))
                    if plan.sidecarFileCount > 0 {
                        summary(L10n.text("\(L10n.number(plan.sidecarFileCount)) XMP"))
                    }
                }
                if plan.autoNumberedFileCount > 0 {
                    summary(L10n.plural("Numbered %lld files that shared a name.", plan.autoNumberedFileCount))
                }
            }

            if !plan.collisions.isEmpty {
                Label(
                    L10n.plural("Resolve %lld filename conflicts before renaming.", plan.collisions.count),
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
        SheetForm(title: L10n.plural("Rename %lld files?", plan.movingFileCount)) {
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
            SheetActions {
                Button(L10n.text("Back")) { isReviewing = false }
            } trailing: {
                SheetCancelButton { store.isRenamePresented = false }
                SheetPrimaryButton(
                    plan.storageSafety.usesReducedDirectoryDurability
                        ? L10n.text("Rename Files Anyway")
                        : L10n.text("Rename Files"),
                    runsOnReturn: true
                ) {
                    store.startSourceRename(plan)
                }
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
