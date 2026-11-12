import SwiftUI

struct OrganizeSourceView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scope: SourceOrganizationScope = .all
    @State private var configuration: SourceOrganizationConfiguration
    @State private var plan: SourceOrganizationPlan?
    @State private var planningError: String?
    @State private var isPlanning = false
    @State private var isReviewingMove = false
    @State private var planningTask: Task<Void, Never>?
    @State private var planningCancelFlag:
        SourceOrganizationPlanningCancelFlag?
    @State private var levelDrag = ReorderDragState<SourceOrganizationLevelKind>()

    init(store: SessionStore) {
        self.store = store
        _configuration = State(initialValue:
            store.sourceOrganizationLaunchConfiguration
                ?? .initial(
                    hasMultipleTopLevelFolders:
                        store.hasMultipleOrganizationTopLevelFolders
                )
        )
    }

    var body: some View {
        Group {
            if let progress = store.organizationProgress {
                SourceFileOperationProgressView(
                    title: L10n.text("Organize Source Folder"),
                    subtitle: L10n.text("Move media into folders built from review and capture metadata."),
                    progress: progress, headline: progress.title
                )
            } else if let outcome = store.organizationOutcome {
                SourceFileOperationOutcomeView(
                    store: store, outcome: outcome, kind: .organization
                ) { store.isOrganizePresented = false }
            } else if isReviewingMove, let plan {
                confirmationView(plan)
            } else {
                setupView
            }
        }
        .frame(width: 680, height: confirmationSheetHeight)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
        .controlSize(.regular)
        .interactiveDismissDisabled(store.isFileOperationRunning)
        .onAppear { refreshPlan() }
        .onDisappear {
            planningCancelFlag?.cancel()
            planningCancelFlag = nil
            planningTask?.cancel()
            planningTask = nil
        }
        .onChange(of: scope) { refreshPlan() }
        .onChange(of: configuration) { refreshPlan() }
    }

    private var setupView: some View {
        SheetForm(
            title: L10n.text("Organize Source Folder"),
            subtitle: L10n.text("Move media into folders built from review and capture metadata."),
            layout: .grouped
        ) {
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

            Section(L10n.text("Folder order")) {
                Text(L10n.text("Choose folder levels and drag enabled rows into order. The top row comes first."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(configuration.levels) { level in
                    levelRow(level)
                }

                additionalMetadataMenu

                if !levelBinding(.existingFolder).wrappedValue {
                    Label(
                        L10n.text("Existing folder is off: files use only the new levels. Previous folders remain, even when empty."),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.text("Place inside source folder")) {
                TextField(L10n.text("Folder name"), text: $configuration.containerName)
                Text(L10n.text("Previous folders and unrelated files stay untouched."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            previewSection
        } actions: {
            SheetActions {
                if isPlanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("Checking paths and sidecars…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                SheetCancelButton { store.isOrganizePresented = false }
                SheetPrimaryButton(reviewButtonTitle, runsOnReturn: true) {
                    isReviewingMove = true
                }
                .disabled(!canReviewMove)
            }
        }
    }

    private func levelRow(
        _ level: SourceOrganizationLevel
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(level.isEnabled ? .secondary : .tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)

            Toggle(
                level.kind.label,
                isOn: levelBinding(level.kind)
            )
            .toggleStyle(LouppeToggleStyle(.checkbox))

            Spacer(minLength: 8)

            if level.isEnabled, level.kind == .existingFolder {
                Picker(
                    L10n.text("Existing folder depth"),
                    selection: $configuration.existingFolderDepth
                ) {
                    ForEach(
                        SourceOrganizationExistingFolderDepth.allCases,
                        id: \.self
                    ) { value in
                        Text(value.label).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            if level.isEnabled, level.kind == .dateTaken {
                Picker(
                    L10n.text("Date grouping"),
                    selection: $configuration.dateGranularity
                ) {
                    ForEach(
                        SourceOrganizationDateGranularity.allCases,
                        id: \.self
                    ) { value in
                        Text(dateGranularityLabel(value)).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }

            if level.kind.isAdditionalMetadata {
                Button {
                    configuration.levels.removeAll { $0.kind == level.kind }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("Remove \(level.kind.label)"))
                .accessibilityLabel(L10n.text("Remove \(level.kind.label)"))
            }
        }
        .contentShape(Rectangle())
        .reorderableRow(
            level.kind,
            in: configuration.levels.map(\.kind),
            state: $levelDrag,
            isDraggable: level.isEnabled
        ) { source, offset in
            configuration.levels.move(
                fromOffsets: IndexSet(integer: source), toOffset: offset)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(
            level.isEnabled
                ? L10n.text("Drag to change folder priority")
                : L10n.text("Enable this level before reordering it")
        )
        .accessibilityAction(named: L10n.text("Move \(level.kind.label) earlier")) {
            moveLevel(level.kind, offset: -1)
        }
        .accessibilityAction(named: L10n.text("Move \(level.kind.label) later")) {
            moveLevel(level.kind, offset: 1)
        }
    }

    private func moveLevel(_ kind: SourceOrganizationLevelKind, offset: Int) {
        guard let from = configuration.levels.firstIndex(where: { $0.kind == kind }),
              configuration.levels[from].isEnabled else { return }
        let enabledIndices = configuration.levels.indices.filter {
            configuration.levels[$0].isEnabled
        }
        guard let position = enabledIndices.firstIndex(of: from),
              enabledIndices.indices.contains(position + offset) else { return }
        let to = enabledIndices[position + offset]
        withAnimation(reduceMotion ? nil : .default) {
            configuration.levels.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    private var additionalMetadataMenu: some View {
        Menu(L10n.text("Add metadata field…")) {
            ForEach(
                SourceOrganizationLevelKind.allCases.filter {
                    $0.isAdditionalMetadata
                        && !configuration.levels.map(\.kind).contains($0)
                }
            ) { kind in
                Button(kind.label) {
                    configuration.levels.append(SourceOrganizationLevel(
                        kind: kind,
                        isEnabled: true
                    ))
                }
            }
        }
        .disabled(
            SourceOrganizationLevelKind.allCases
                .filter(\.isAdditionalMetadata)
                .allSatisfy { configuration.levels.map(\.kind).contains($0) }
        )
    }

    @ViewBuilder
    private var previewSection: some View {
        Section(L10n.text("Preview")) {
            if let planningError {
                Label(planningError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if let plan {
                if let example = plan.previewGroups.first {
                    Text(example.path)
                        .font(.body.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(example.path)
                }
                HStack(spacing: 10) {
                    summaryValue(L10n.plural("%lld folders", plan.previewGroups.count))
                    summaryValue(L10n.plural("%lld items", plan.itemCount))
                    summaryValue(L10n.plural("%lld media files", plan.mediaFileCount))
                    if plan.sidecarFileCount > 0 {
                        summaryValue(L10n.text("\(L10n.number(plan.sidecarFileCount)) XMP"))
                    }
                }

                if plan.previewGroups.count > 1 {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(plan.previewGroups.prefix(6)) { group in
                            HStack {
                                Text(group.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(L10n.number(group.itemCount))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        if plan.previewGroups.count > 6 {
                            Text(L10n.plural("…and %lld more", plan.previewGroups.count - 6))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !plan.collisions.isEmpty {
                    Label(
                        L10n.plural("%lld filename or sidecar conflicts must be resolved before moving.", plan.collisions.count),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    ForEach(plan.collisions.prefix(2)) { conflict in
                        Text(conflict.destination.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .help(conflict.message)
                    }
                    Text(L10n.text("Keep Existing folder, add a level, narrow the scope, or rename the conflicting file outside Louppe."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if plan.itemCount == 0 {
                    Label(L10n.text("No items are included in this scope."), systemImage: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                } else if plan.alreadyOrganizedItemCount == plan.itemCount {
                    Label(L10n.text("Everything in this scope is already organized."), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    let oldFolderCount = Set(
                        plan.sourceItems.compactMap(\.subfolder)
                    ).count
                    Text(L10n.plural(
                        "%lld items will move out of %lld existing folders. Recognized XMP sidecars and grouped RAW+JPEG files follow their media. Nothing is overwritten.",
                        counts: [plan.movingItemCount, oldFolderCount]
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if plan.excludedACRCompanionCount > 0 {
                    Text(L10n.plural("%lld Lightroom .acr companions will remain in place.", plan.excludedACRCompanionCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.text("Choose at least one folder level."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    func confirmationView(
        _ plan: SourceOrganizationPlan
    ) -> some View {

        return SheetForm(
            title: L10n.plural("Move %lld files?", plan.movingFileCount),
            subtitle: L10n.plural("Into %lld folders inside “%@”", plan.previewGroups.count, arguments: [plan.configuration.containerName])
        ) {
            Text(L10n.text("Names and contents stay unchanged. Existing files are never overwritten."))
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.text("Other files and folders stay where they are. Undo with ⌘Z before closing this session."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if plan.storageSafety.usesReducedDirectoryDurability {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("ExFAT card — keep it connected"))
                            .font(.headline)
                        Text(L10n.text("An interruption may leave folders partly organized. Keep the card connected and Mac on until Louppe finishes."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } actions: {
            SheetActions {
                Button(L10n.text("Back")) { isReviewingMove = false }
            } trailing: {
                SheetCancelButton { store.isOrganizePresented = false }
                SheetPrimaryButton(L10n.text("Move Files"), runsOnReturn: true) {
                    store.startSourceOrganization(plan)
                }
            }
        }
    }

    private var confirmationSheetHeight: CGFloat {
        if store.organizationProgress == nil,
           store.organizationOutcome == nil,
           isReviewingMove,
           let plan {
            return plan.storageSafety.usesReducedDirectoryDurability ? 410 : 330
        }
        // A finished move with no error is a short confirmation, not a form.
        if store.organizationProgress == nil, let outcome = store.organizationOutcome,
           store.organizationError == nil, outcome.message == nil {
            return 250
        }
        return 650
    }

    private func summaryValue(_ value: String) -> some View {
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func levelBinding(
        _ kind: SourceOrganizationLevelKind
    ) -> Binding<Bool> {
        Binding(
            get: {
                configuration.levels.first(where: { $0.kind == kind })?
                    .isEnabled ?? false
            },
            set: { value in
                guard let index = configuration.levels.firstIndex(where: {
                    $0.kind == kind
                }) else { return }
                configuration.levels[index].isEnabled = value
            }
        )
    }

    private func dateGranularityLabel(
        _ value: SourceOrganizationDateGranularity
    ) -> String {
        let date = plan?.sourceItems.compactMap(\.captureDate).first ?? Date()
        let example = SourceOrganizationPlanner.dateFolderLabel(
            date,
            granularity: value
        )
        return "\(value.label) — \(example)"
    }

    private var canReviewMove: Bool {
        !isPlanning && plan?.canExecute == true
    }

    private var reviewButtonTitle: String {
        if let plan, plan.alreadyOrganizedItemCount == plan.itemCount {
            return L10n.text("Already Organized")
        }
        return L10n.text("Review Move…")
    }

    private func refreshPlan() {
        planningCancelFlag?.cancel()
        planningCancelFlag = nil
        planningTask?.cancel()
        isReviewingMove = false
        planningError = nil
        guard !configuration.enabledLevels.isEmpty else {
            plan = nil
            isPlanning = false
            return
        }
        guard let snapshot = store.sourceOrganizationPlanningSnapshot(
            scope: scope
        ) else {
            plan = nil
            isPlanning = false
            return
        }
        let requestedConfiguration = configuration
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
                        configuration: requestedConfiguration,
                        knownOriginFolderPathBytesByFileID:
                            snapshot.knownOriginFolderPathBytesByFileID,
                        pairedFiles: snapshot.pairedFiles,
                        isCancelled: { cancelFlag.isCancelled }
                    )
                }
            }.value
            guard !Task.isCancelled,
                  !cancelFlag.isCancelled,
                  configuration == requestedConfiguration else { return }
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
