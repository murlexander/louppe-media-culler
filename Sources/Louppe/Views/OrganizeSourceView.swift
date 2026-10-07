import SwiftUI
import UniformTypeIdentifiers

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
    @State private var draggedKind: SourceOrganizationLevelKind?

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
                progressView(progress)
            } else if let outcome = store.organizationOutcome {
                outcomeView(outcome)
            } else if isReviewingMove, let plan {
                confirmationView(plan)
            } else {
                setupView
            }
        }
        .frame(width: 680, height: confirmationSheetHeight)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
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
        VStack(spacing: 0) {
            sheetHeader(
                title: L10n.text("Organize Source Folder"),
                subtitle: L10n.text("Move media into folders built from review and capture metadata.")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

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

                    section(L10n.text("Folder order")) {
                        Text(L10n.text("Choose folder levels and drag enabled rows into order. The top row comes first."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 0) {
                            ForEach(configuration.levels) { level in
                                levelRow(level)
                                if level.id != configuration.levels.last?.id {
                                    Divider().padding(.leading, 44)
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

                    Divider()

                    section(L10n.text("Place inside source folder")) {
                        TextField(L10n.text("Folder name"), text: $configuration.containerName)
                            .textFieldStyle(.roundedBorder)
                        Text(L10n.text("Previous folders and unrelated files stay untouched."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    previewSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }

            Divider()

            HStack {
                if isPlanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("Checking paths and sidecars…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isOrganizePresented = false
                }
                Button(reviewButtonTitle) {
                    isReviewingMove = true
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.louppeAccent)
                .disabled(!canReviewMove)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
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
            .toggleStyle(.checkbox)

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
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Remove \(level.kind.label)"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onDrag {
            guard level.isEnabled else { return NSItemProvider() }
            draggedKind = level.kind
            return NSItemProvider(object: level.kind.rawValue as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: OrganizationLevelDropDelegate(
                destination: level.kind,
                dragged: $draggedKind,
                levels: $configuration.levels,
                reduceMotion: reduceMotion
            )
        )
        .opacity(level.isEnabled ? 1 : 0.62)
        .accessibilityElement(children: .contain)
        .accessibilityHint(
            level.isEnabled
                ? L10n.text("Drag to change folder priority")
                : L10n.text("Enable this level before reordering it")
        )
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
        section(L10n.text("Preview")) {
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
                    summaryValue(L10n.text("\(plan.previewGroups.count) folders"))
                    summaryValue(L10n.text("\(plan.itemCount) items"))
                    summaryValue(L10n.text("\(plan.mediaFileCount) media files"))
                    if plan.sidecarFileCount > 0 {
                        summaryValue(L10n.text("\(plan.sidecarFileCount) XMP"))
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
                                Text("\(group.itemCount)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        if plan.previewGroups.count > 6 {
                            Text(L10n.text("…and \(plan.previewGroups.count - 6) more"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !plan.collisions.isEmpty {
                    Label(
                        (plan.collisions.count == 1 ? L10n.text("\(plan.collisions.count) filename or sidecar conflict must be resolved before moving.") : L10n.text("\(plan.collisions.count) filename or sidecar conflicts must be resolved before moving.")),
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
                    Text((oldFolderCount == 1 ? L10n.text("\(plan.movingItemCount) items will move out of \(oldFolderCount) existing folder. Recognized XMP sidecars and grouped RAW+JPEG files follow their media. Nothing is overwritten.") : L10n.text("\(plan.movingItemCount) items will move out of \(oldFolderCount) existing folders. Recognized XMP sidecars and grouped RAW+JPEG files follow their media. Nothing is overwritten.")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if plan.excludedACRCompanionCount > 0 {
                    Text((plan.excludedACRCompanionCount == 1 ? L10n.text("\(plan.excludedACRCompanionCount) Lightroom .acr companion will remain in place.") : L10n.text("\(plan.excludedACRCompanionCount) Lightroom .acr companions will remain in place.")))
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

    private func confirmationView(
        _ plan: SourceOrganizationPlan
    ) -> some View {

        return VStack(spacing: 0) {
            sheetHeader(
                title: plan.movingFileCount == 1 ? L10n.text("Move 1 file?") : L10n.text("Move \(plan.movingFileCount) files?"),
                subtitle: plan.previewGroups.count == 1
                    ? L10n.text("Into 1 folder inside “\(plan.configuration.containerName)”")
                    : L10n.text("Into \(plan.previewGroups.count) folders inside “\(plan.configuration.containerName)”")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                }
                .padding(24)
            }

            Divider()

            HStack {
                Button(L10n.text("Back")) { isReviewingMove = false }
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    store.isOrganizePresented = false
                }
                Button(L10n.text("Move Files")) {
                    store.startSourceOrganization(plan)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.louppeAccent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private var confirmationSheetHeight: CGFloat {
        if store.organizationProgress == nil,
           store.organizationOutcome == nil,
           isReviewingMove,
           let plan {
            return plan.storageSafety.usesReducedDirectoryDurability ? 410 : 330
        }
        return 650
    }

    private func progressView(
        _ progress: SourceOrganizationProgress
    ) -> some View {
        VStack(spacing: 16) {
            ProgressView(
                value: Double(progress.done),
                total: Double(max(progress.total, 1))
            )
            .accessibilityLabel(progress.title)
            .accessibilityValue(L10n.text("\(progress.done) of \(progress.total) files"))
            .frame(width: 360)
            Text(progress.title)
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

    private func outcomeView(
        _ outcome: SourceOrganizationOutcome
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: outcome.succeeded
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(outcome.succeeded
                    ? Color.louppeAccent
                    : Color.secondary)
            Text(outcome.title(for: .organization))
                .font(.title2.weight(.semibold))
            Text(outcome.fileCountDescription(for: .organization))
                .foregroundStyle(.secondary)
            if let message = store.organizationError ?? outcome.message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            } else if !outcome.wasUndo {
                Text(L10n.text("Restore the previous layout with ⌘Z before closing this session."))
                    .foregroundStyle(.secondary)
            }
            if case .scanning = store.phase {
                ProgressView(L10n.text("Refreshing the session…"))
                    .padding(.top, 8)
            }
            Button(L10n.text("Done")) {
                store.isOrganizePresented = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(store.isFileOperationRunning)
        }
        .padding(30)
    }

    private func sheetHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
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

private struct OrganizationLevelDropDelegate: DropDelegate {
    let destination: SourceOrganizationLevelKind
    @Binding var dragged: SourceOrganizationLevelKind?
    @Binding var levels: [SourceOrganizationLevel]
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        guard let dragged,
              dragged != destination,
              let from = levels.firstIndex(where: { $0.kind == dragged }),
              let to = levels.firstIndex(where: { $0.kind == destination }),
              levels[from].isEnabled,
              levels[to].isEnabled else { return }
        withAnimation(reduceMotion ? nil : .default) {
            levels.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
