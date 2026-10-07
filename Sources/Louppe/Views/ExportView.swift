import SwiftUI

private enum XMPConflictResolutionOrigin {
    case standalone
    case copyOrMove
}

private struct XMPConflictResolverPresentation: Identifiable {
    let id = UUID()
    let conflicts: [XMPSameStemConflictDescriptor]
    let origin: XMPConflictResolutionOrigin
}

struct ExportView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var exporter = ExportManager()
    @AccessibilityFocusState private var isStopCopyingFocused: Bool
    @AccessibilityFocusState private var isExportResultFocused: Bool
    // The sheet's content is recreated per presentation. An explicit selection
    // starts with all its items; otherwise Copy starts with keepers.
    @State private var mode: ExportMode = .copy
    /// Routing is intentionally a Copy-only subflow. Keeping it out of the
    /// toolbar and separate from Move makes the non-destructive default clear.
    @State private var isRoutingCopies = false
    @State private var routingRoutes: [MultiDestinationExportRoute] = [
        MultiDestinationExportRoute(predicate: .decision(.yes))
    ]
    @State private var routingIncludesXMP = false
    @State private var routingEvaluation = MultiDestinationExportEvaluation
        .evaluate(routes: [], items: [])
    @State private var selectedRatings: Set<Rating> = [.yes]
    @State private var selectedStars = ExportSelectionPredicate.allStarStates
    @State private var selectedColors = ExportSelectionPredicate.allColorStates
    @State private var scope: CleanUpScope = .filtered
    @State private var selectionSnapshot = ExportSelectionSnapshot.empty
    @State private var xmpProfile: XMPApplicationProfile = .universal
    @State private var universalDecisionKeywords = false
    @State private var allowExternalLabelReplacement = false
    @State private var showXMPDetails = false
    @State private var showEditingAppOptions = false
    @State private var xmpInclusionChoice = ExportXMPInclusionChoice()
    @State private var existingXMPCount = 0
    @State private var excludedACRCompanionCount = 0
    @State private var isCheckingExistingXMP = false
    @State private var xmpInspectionID = UUID()
    @State private var xmpInspectionTask: Task<Void, Never>?
    /// The detached scan itself. A detached task is not a child, so cancelling
    /// only the awaiting wrapper would leave a superseded whole-session scan
    /// running behind the newer one.
    @State private var xmpInspectionWork:
        Task<XMPExportSourceInspection?, Never>?
    @State private var conflictResolver: XMPConflictResolverPresentation?
    @State private var conflictResolutionNotice: String?

    var body: some View {
        VStack(spacing: 16) {
            if mode == .metadataXMP {
                xmpContent
            } else {
                switch exporter.state {
                case .summary:
                    summaryView
                case .preparingXMP(let mode):
                    xmpExportPreparationView(mode: mode)
                case .awaitingXMPConfirmation(let confirmation):
                    xmpExportPreflightView(confirmation)
                case .preparingMultiDestination:
                    multiDestinationPreparationView
                case .awaitingMultiDestinationConfirmation(let plan):
                    multiDestinationConfirmationView(plan)
                case .working(let mode, let completedBytes, let totalBytes):
                    workingView(
                        mode: mode,
                        completedBytes: completedBytes,
                        totalBytes: totalBytes
                    )
                case .finished(let outcome):
                    finishedView(outcome: outcome)
                case .failed(let message):
                    failedView(message: message)
                }
            }
        }
        .padding(usesFormLayout ? 0 : 24)
        .frame(width: 640, height: 620)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
        .interactiveDismissDisabled(isWorking)
        .confirmationDialog(
            L10n.text("Stop copying?"),
            isPresented: Binding(
                get: { exporter.isCopyStopConfirmationPresented },
                set: { isPresented in
                    if !isPresented {
                        exporter.dismissCopyStopConfirmation()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Stop Copying")) { exporter.confirmCopyStop() }
            Button(L10n.text("Keep Copying"), role: .cancel) {
                exporter.dismissCopyStopConfirmation()
            }
        } message: {
            Text(L10n.text("Completed media stays at the destination. Only the file being copied rolls back."))
        }
        .onAppear {
            xmpInclusionChoice = ExportXMPInclusionChoice()
            routingIncludesXMP = false
            existingXMPCount = 0
            excludedACRCompanionCount = 0
            applyConfiguration(
                .initial(
                    hasExplicitSelection: !store.selectedIndices.isEmpty,
                    keepersOnly: store.exportKeepersRequested
                )
            )
            refreshSelectionSnapshot()
            refreshRoutingEvaluation()
        }
        .onDisappear {
            cancelXMPInspection()
            exporter.reset()
            store.resetXMPPublication()
        }
        .onChange(of: mode) {
            showXMPDetails = false
            showEditingAppOptions = false
            if mode != .copy { isRoutingCopies = false }
            store.resetXMPPublication()
            refreshSelectionSnapshot()
        }
        .onChange(of: isRoutingCopies) { refreshRoutingEvaluation() }
        .onChange(of: routingRoutes) { refreshRoutingEvaluation() }
        .onChange(of: selectedRatings) { refreshSelectionSnapshot() }
        .onChange(of: selectedStars) { refreshSelectionSnapshot() }
        .onChange(of: selectedColors) { refreshSelectionSnapshot() }
        .onChange(of: scope) {
            refreshSelectionSnapshot()
            refreshRoutingEvaluation()
        }
        .onChange(of: store.items.count) {
            refreshSelectionSnapshot()
            refreshRoutingEvaluation()
        }
        .onChange(of: store.selectedIndices) {
            refreshSelectionSnapshot()
            refreshRoutingEvaluation()
        }
        .sheet(item: $conflictResolver) { presentation in
            XMPConflictResolverView(
                conflicts: presentation.conflicts,
                onCancel: { conflictResolver = nil },
                onApply: { requests in
                    applyConflictResolutions(
                        requests,
                        origin: presentation.origin
                    )
                }
            )
        }
    }

    private var usesFormLayout: Bool {
        if mode == .metadataXMP {
            switch store.xmpPublicationState {
            case .idle, .awaitingConfirmation: return true
            default: return false
            }
        }
        switch exporter.state {
        case .summary, .awaitingXMPConfirmation, .awaitingMultiDestinationConfirmation:
            return true
        default: return false
        }
    }

    private var isWorking: Bool {
        if store.isXMPPublicationRunning { return true }
        if case .preparingXMP = exporter.state { return true }
        if case .preparingMultiDestination = exporter.state { return true }
        if case .working = exporter.state { return true }
        return false
    }

    @ViewBuilder
    private var summaryView: some View {
        if isRoutingCopies && mode == .copy {
            routingSummaryView
        } else {
        SheetForm(title: L10n.text("Export")) {
            Picker(L10n.text("Mode"), selection: $mode) {
                Text(L10n.text("Copy")).tag(ExportMode.copy)
                Text(L10n.text("Move")).tag(ExportMode.move)
                Text("Metadata (XMP)").tag(ExportMode.metadataXMP)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .copy {
                Toggle(L10n.text("Route copies to multiple folders"), isOn: $isRoutingCopies)
                    .accessibilityHint(L10n.text("Create Copy routes, each with its own chosen folder"))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Media to include"))
                    .font(.subheadline.weight(.semibold))

                quickPickRow

                exportScopeRow

                Text(L10n.text("Decisions, stars, and colors are independent. Items must match every chosen criterion."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    ratingTile(.yes, count: scopeRatingCount(.yes), label: L10n.text("Yes"), color: .green)
                    ratingTile(.no, count: scopeRatingCount(.no), label: L10n.text("No"), color: .red)
                    ratingTile(.undecided, count: scopeRatingCount(.undecided), label: L10n.text("Undecided"), color: .secondary)
                }

                exportMenuRow(L10n.text("Stars")) {
                    Menu(starSelectionSummary) {
                        Toggle(
                            L10n.text("Unrated"),
                            isOn: membershipBinding(
                                .unrated,
                                in: $selectedStars
                            )
                        )
                        ForEach(StarRating.allCases, id: \.self) { rating in
                            Toggle(
                                rating == .one
                                    ? L10n.text("1 star")
                                    : L10n.text("\(rating.count) stars"),
                                isOn: membershipBinding(
                                    .stars(rating),
                                    in: $selectedStars
                                )
                            )
                        }
                        Toggle(
                            L10n.text("Mixed"),
                            isOn: membershipBinding(.mixed, in: $selectedStars)
                        )
                    }
                    .accessibilityLabel(L10n.text("Star ratings"))
                    .accessibilityValue(starSelectionSummary)
                }

                exportMenuRow(L10n.text("Color")) {
                    Menu(colorSelectionSummary) {
                        Toggle(
                            L10n.text("None"),
                            isOn: membershipBinding(
                                .none,
                                in: $selectedColors
                            )
                        )
                        ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                            Toggle(
                                isOn: membershipBinding(
                                    .label(label),
                                    in: $selectedColors
                                )
                            ) {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(label.swatchColor)
                                        .frame(width: 10, height: 10)
                                    Text(label.localizedDisplayName)
                                }
                            }
                        }
                        Toggle(
                            L10n.text("Mixed"),
                            isOn: membershipBinding(.mixed, in: $selectedColors)
                        )
                    }
                    .accessibilityLabel(L10n.text("Color labels"))
                    .accessibilityValue(colorSelectionSummary)
                }

                exportPreview
            }

            if mode == .metadataXMP {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Write decisions, stars, and colors to XMP sidecars for editing apps. Originals stay unchanged."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    editingAppOptions
                }
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        L10n.text("Include XMP sidecars for editing apps"),
                        isOn: includeXMPBinding
                    )

                    Text(copyMoveXMPExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if excludedACRCompanionCount > 0 {
                        Text((excludedACRCompanionCount == 1 ? L10n.text("\(excludedACRCompanionCount) Lightroom .acr companion will stay in the source folder, unexported.") : L10n.text("\(excludedACRCompanionCount) Lightroom .acr companions will stay in the source folder, unexported.")))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if xmpInclusionChoice.isIncluded {
                        editingAppOptions
                    }
                }
            }

            if mode == .move {
                Text(L10n.text("Move works on the same drive only; use Copy for another drive or card. Moved items leave this session and cannot be undone in Louppe."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }

            if selectionSnapshot.mixedDecisionCount > 0 {
                Text((selectionSnapshot.mixedDecisionCount == 1 ? L10n.text("\(selectionSnapshot.mixedDecisionCount) included RAW+JPEG pair has different file decisions and is treated as undecided.") : L10n.text("\(selectionSnapshot.mixedDecisionCount) included RAW+JPEG pairs have different file decisions and are treated as undecided.")))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }

            if scopeMixedStarCount > 0 || scopeMixedColorCount > 0 {
                Text(mixedMetadataNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }

            if scopeRatingCount(.undecided) > 0 && !selectedRatings.contains(.undecided) {
                let count = scopeRatingCount(.undecided)
                Text((count == 1 ? L10n.text("\(count) item still undecided in this scope — they won't be exported.") : L10n.text("\(count) items still undecided in this scope — they won't be exported.")))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

        } actions: {
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { store.isExportPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .metadataXMP ? L10n.text("Review Sidecars…") : L10n.text("Choose Destination…")) {
                    if mode == .metadataXMP {
                        store.prepareXMPPublication(
                            selected: selectionSnapshot.selectedItems(from: store.items),
                            profile: xmpProfile,
                            visibleDecisionKeywords: effectiveVisibleDecisionKeywords,
                            allowExternalLabelReplacement: allowExternalLabelReplacement
                        )
                    } else {
                        exporter.promptDestinationAndExport(
                            sourceFolder: store.sourceFolder,
                            selected: selectionSnapshot.selectedItems(from: store.items),
                            familyContextItems: store.items,
                            sessionGeneration:
                                store.xmpConflictSessionGeneration,
                            mode: mode,
                            includeXMP: xmpInclusionChoice.isIncluded,
                            xmpProfile: xmpProfile,
                            visibleDecisionKeywords: effectiveVisibleDecisionKeywords,
                            allowExternalLabelReplacement: allowExternalLabelReplacement,
                            onOperationWillStart: { store.exportWillStart(mode: $0) },
                            onOperationDidFinish: {
                                store.finishExport(
                                    mode: $0,
                                    movedIDs: $1,
                                    requiresRecovery: $2,
                                    interruptionMessage: $3
                                )
                            }
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectionSnapshot.itemCount == 0
                        || (mode != .metadataXMP && isCheckingExistingXMP)
                )
            }
        }
        }
    }

    private var selectionPredicate: ExportSelectionPredicate {
        ExportSelectionPredicate(
            decisions: selectedRatings,
            starStates: selectedStars,
            colorStates: selectedColors
        )
    }

    private var currentConfiguration: ExportSelectionConfiguration {
        ExportSelectionConfiguration(
            scope: scope,
            predicate: selectionPredicate
        )
    }

    private var activeQuickPick: ExportQuickPick? {
        if !store.selectedIndices.isEmpty,
           currentConfiguration == .preset(.allSelected) {
            return .allSelected
        }
        if currentConfiguration == .preset(
            .keepers,
            keeperScope: store.exportKeepersRequested ? .all : .filtered
        ) {
            return .keepers
        }
        if currentConfiguration == .preset(.fourFiveStars) {
            return .fourFiveStars
        }
        return nil
    }

    private var quickPickRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Quick picks"))
                    .font(.caption.weight(.semibold))
                if activeQuickPick == nil {
                    Text(L10n.text("Custom"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                quickPickButton("Keepers (Yes)", pick: .keepers)
                    .help(store.exportKeepersRequested
                        ? L10n.text("Yes decisions, with any stars or colors, from the whole folder")
                        : L10n.text("Yes decisions, with any stars or colors, from the current filter"))
                quickPickButton("4–5 Stars", pick: .fourFiveStars)
                    .help(L10n.text("4 or 5 stars with any decision or color, from the current filter"))
                quickPickButton(L10n.text("All Selected"), pick: .allSelected)
                    .help(L10n.text("Every explicitly selected item, regardless of decision, stars, or color"))
                    .disabled(store.selectedIndices.isEmpty)
            }
        }
    }

    private func quickPickButton(
        _ title: String,
        pick: ExportQuickPick
    ) -> some View {
        let isActive = activeQuickPick == pick
        return Button {
            applyQuickPick(pick)
        } label: {
            HStack(spacing: 4) {
                if isActive { Image(systemName: "checkmark") }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func applyQuickPick(_ pick: ExportQuickPick) {
        if pick == .allSelected && store.selectedIndices.isEmpty { return }
        applyConfiguration(.preset(
            pick,
            keeperScope: store.exportKeepersRequested ? .all : .filtered
        ))
    }

    private func applyConfiguration(_ configuration: ExportSelectionConfiguration) {
        scope = configuration.scope
        selectedRatings = configuration.predicate.decisions
        selectedStars = configuration.predicate.starStates
        selectedColors = configuration.predicate.colorStates
    }

    private var exportPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exportDescription)
                .font(.callout.weight(.semibold))
            Text(exclusionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var exclusionDescription: String {
        let excludedByChoices = max(0, scopeIndices.count - selectionSnapshot.itemCount)
        let outsideScope = max(0, store.items.count - scopeIndices.count)
        var parts: [String] = []
        if excludedByChoices > 0 {
            parts.append(L10n.text("\(excludedByChoices) excluded by decision, stars, or color"))
        }
        if outsideScope > 0 {
            parts.append(L10n.text("\(outsideScope) outside this scope"))
        }
        return parts.isEmpty ? L10n.text("Nothing excluded.") : parts.joined(separator: " · ") + "."
    }

    private var editingAppOptions: some View {
        DisclosureGroup(L10n.text("Editing app options"), isExpanded: $showEditingAppOptions) {
            VStack(alignment: .leading, spacing: 9) {
                exportMenuRow(L10n.text("Application")) {
                    Picker(L10n.text("Application"), selection: $xmpProfile) {
                        ForEach(XMPApplicationProfile.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
                if xmpProfile == .universal {
                    Toggle(
                        L10n.text("Make decisions visible as keywords"),
                        isOn: $universalDecisionKeywords
                    )
                }
                Toggle(
                    L10n.text("Allow replacing or removing external color labels"),
                    isOn: $allowExternalLabelReplacement
                )
                if allowExternalLabelReplacement {
                    Text(L10n.text("Confirmed: conflicting external xmp:Label values may be replaced or removed by the chosen Louppe color."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
        .font(.caption)
    }

    // MARK: - Multi-destination Copy

    private var routingSummaryView: some View {
        SheetForm(title: L10n.text("Route Copies")) {
            Picker(L10n.text("Mode"), selection: $mode) {
                Text(L10n.text("Copy")).tag(ExportMode.copy)
                Text(L10n.text("Move")).tag(ExportMode.move)
                Text("Metadata (XMP)").tag(ExportMode.metadataXMP)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(L10n.text("Route copies to multiple folders"), isOn: $isRoutingCopies)
                .accessibilityHint(L10n.text("Turn off to return to normal one-folder Copy"))

            exportScopeRow

            Text(L10n.text("Choose media for each destination. Unmatched items stay in the source folder."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Group {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($routingRoutes) { $route in
                        routingRouteEditor($route)
                    }
                }
                .padding(.horizontal, 1)
            }

            HStack {
                Button(L10n.text("Add Route")) {
                    routingRoutes.append(MultiDestinationExportRoute(
                        predicate: .decision(.no)
                    ))
                }
                .disabled(routingRoutes.count >= 12)
                Spacer()
                Text(routingMatchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = routingValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(L10n.text("Routing issue: \(message)"))
            }

            if !routingEvaluation.unmatchedItemIndices.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Unmatched — will stay in the source folder"))
                        .font(.caption.weight(.semibold))
                    Text(routingItemList(routingEvaluation.unmatchedItemIndices))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            Toggle(L10n.text("Include XMP sidecars (off by default)"), isOn: $routingIncludesXMP)
            Text(L10n.text("Sidecars follow media. Files sharing XMP must go to one folder."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

        } actions: {
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { store.isExportPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Review Copy Plan…")) {
                    exporter.prepareMultiDestinationExport(
                        routes: routingRoutes,
                        items: scopedItems,
                        sourceFolder: store.sourceFolder,
                        includeXMP: routingIncludesXMP,
                        familyContextItems: store.items,
                        sessionGeneration: store.xmpConflictSessionGeneration,
                        xmpProfile: xmpProfile,
                        visibleDecisionKeywords: effectiveVisibleDecisionKeywords,
                        allowExternalLabelReplacement:
                            allowExternalLabelReplacement,
                        onOperationWillStart: { store.exportWillStart(mode: $0) },
                        onOperationDidFinish: {
                            store.finishExport(
                                mode: $0,
                                movedIDs: $1,
                                requiresRecovery: $2,
                                interruptionMessage: $3
                            )
                        }
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!routingCanReview)
            }
        }
    }

    private func routingRouteEditor(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> some View {
        let routeID = route.wrappedValue.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(route.wrappedValue.predicate.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(L10n.text("Remove")) {
                    exporter.removeRoutingDestinationAccess(for: routeID)
                    routingRoutes.removeAll { $0.id == routeID }
                }
                .disabled(routingRoutes.count == 1)
            }

            HStack {
                Picker(L10n.text("Match"), selection: routingDimensionBinding(route)) {
                    ForEach(MultiDestinationRoutePredicate.Dimension.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .frame(width: 145)

                routingValuePicker(route)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Text(L10n.text("Destination"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(route.wrappedValue.destination?.lastPathComponent ?? L10n.text("Choose Folder…")) {
                    chooseRoutingDestination(routeID)
                }
                .accessibilityLabel(
                    route.wrappedValue.destination == nil
                        ? L10n.text("Choose destination for \(route.wrappedValue.predicate.displayName)")
                        : L10n.text("Change destination for \(route.wrappedValue.predicate.displayName)")
                )
            }
            if let destination = route.wrappedValue.destination {
                Text(destination.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25))
        }
    }

    @ViewBuilder
    private func routingValuePicker(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> some View {
        switch route.wrappedValue.predicate.dimension {
        case .decision:
            Picker(L10n.text("Decision"), selection: routingDecisionBinding(route)) {
                ForEach([Rating.yes, .no, .undecided], id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .labelsHidden()
        case .stars:
            Picker(L10n.text("Stars"), selection: routingStarsBinding(route)) {
                ForEach(routingStarStates, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .labelsHidden()
        case .color:
            Picker(L10n.text("Color"), selection: routingColorBinding(route)) {
                ForEach(routingColorStates, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .labelsHidden()
        case .fileType:
            Picker(L10n.text("File type"), selection: routingFileTypeBinding(route)) {
                ForEach(store.availableTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .labelsHidden()
            .disabled(store.availableTypes.isEmpty)
        case .mediaKind:
            Picker(L10n.text("Media type"), selection: routingMediaKindBinding(route)) {
                Text(MediaKind.photo.label).tag(MediaKind.photo)
                Text(MediaKind.video.label).tag(MediaKind.video)
                Text(MediaKind.audio.label).tag(MediaKind.audio)
                Text(MediaKind.text.label).tag(MediaKind.text)
            }
            .labelsHidden()
        }
    }

    private var routingStarStates: [PhotoItemStarRatingState] {
        [.unrated] + StarRating.allCases.map(PhotoItemStarRatingState.stars) + [.mixed]
    }

    private var routingColorStates: [PhotoItemColorLabelState] {
        [.none] + PhotoColorLabel.allCases.map(PhotoItemColorLabelState.label) + [.mixed]
    }

    private func routingDimensionBinding(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> Binding<MultiDestinationRoutePredicate.Dimension> {
        Binding {
            route.wrappedValue.predicate.dimension
        } set: { dimension in
            switch dimension {
            case .decision: route.wrappedValue.predicate = .decision(.yes)
            case .stars: route.wrappedValue.predicate = .stars(.unrated)
            case .color: route.wrappedValue.predicate = .color(.none)
            case .fileType:
                route.wrappedValue.predicate = .fileType(
                    store.availableTypes.first ?? L10n.text("Unknown")
                )
            case .mediaKind: route.wrappedValue.predicate = .mediaKind(.photo)
            }
        }
    }

    private func routingDecisionBinding(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> Binding<Rating> {
        Binding {
            if case .decision(let value) = route.wrappedValue.predicate {
                return value
            }
            return .yes
        } set: { route.wrappedValue.predicate = .decision($0) }
    }

    private func routingStarsBinding(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> Binding<PhotoItemStarRatingState> {
        Binding {
            if case .stars(let value) = route.wrappedValue.predicate {
                return value
            }
            return .unrated
        } set: { route.wrappedValue.predicate = .stars($0) }
    }

    private func routingColorBinding(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> Binding<PhotoItemColorLabelState> {
        Binding {
            if case .color(let value) = route.wrappedValue.predicate {
                return value
            }
            return .none
        } set: { route.wrappedValue.predicate = .color($0) }
    }

    private func routingFileTypeBinding(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> Binding<String> {
        Binding {
            if case .fileType(let value) = route.wrappedValue.predicate {
                return value
            }
            return store.availableTypes.first ?? L10n.text("Unknown")
        } set: { route.wrappedValue.predicate = .fileType($0) }
    }

    private func routingMediaKindBinding(
        _ route: Binding<MultiDestinationExportRoute>
    ) -> Binding<MediaKind> {
        Binding {
            if case .mediaKind(let value) = route.wrappedValue.predicate {
                return value
            }
            return .photo
        } set: { route.wrappedValue.predicate = .mediaKind($0) }
    }

    private var routingCanReview: Bool {
        !routingRoutes.isEmpty
            && routingRoutes.allSatisfy { $0.destination != nil }
            && routingEvaluation.overlappingItemIndices.isEmpty
            && routingEvaluation.emptyRouteIDs.isEmpty
    }

    private var routingMatchSummary: String {
        let routed = scopedItems.count
            - routingEvaluation.unmatchedItemIndices.count
            - routingEvaluation.overlappingItemIndices.count
        return L10n.text("\(max(routed, 0)) routed · \(routingEvaluation.unmatchedItemIndices.count) unmatched")
    }

    private var routingValidationMessage: String? {
        if routingRoutes.isEmpty { return L10n.text("Add at least one route.") }
        if routingRoutes.contains(where: { $0.destination == nil }) {
            return L10n.text("Choose a destination folder for every route.")
        }
        if !routingEvaluation.overlappingItemIndices.isEmpty {
            return (routingEvaluation.overlappingItemIndices.count == 1 ? L10n.text("\(routingEvaluation.overlappingItemIndices.count) item match more than one route: \(routingItemList(routingEvaluation.overlappingItemIndices)).") : L10n.text("\(routingEvaluation.overlappingItemIndices.count) items match more than one route: \(routingItemList(routingEvaluation.overlappingItemIndices))."))
        }
        if !routingEvaluation.emptyRouteIDs.isEmpty {
            return L10n.text("Each route must match at least one item.")
        }
        return nil
    }

    private func routingItemList(_ indices: [Int], limit: Int = 8) -> String {
        let names = indices.prefix(limit).compactMap { index in
            scopedItems.indices.contains(index) ? scopedItems[index].displayName : nil
        }
        let remainder = max(0, indices.count - names.count)
        return names.joined(separator: ", ")
            + (remainder > 0 ? L10n.text(" and \(remainder) more") : "")
    }

    private func refreshRoutingEvaluation() {
        routingEvaluation = MultiDestinationExportEvaluation.evaluate(
            routes: routingRoutes,
            items: scopedItems
        )
    }

    private func chooseRoutingDestination(_ routeID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("Choose this route’s destination.")
        panel.prompt = L10n.text("Use Folder")
        guard panel.runModal() == .OK, let destination = panel.url,
              let index = routingRoutes.firstIndex(where: { $0.id == routeID }) else {
            return
        }
        exporter.retainRoutingDestinationAccess(destination, for: routeID)
        routingRoutes[index].destination = destination
    }

    private var multiDestinationPreparationView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityLabel(L10n.text("Checking routing copy plan"))
            Text(L10n.text("Checking routing copy plan…"))
                .font(.headline)
            Text(L10n.text("Checking destinations and filenames…"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.text("Cancel")) { exporter.cancelMultiDestinationPreparation() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func multiDestinationConfirmationView(
        _ plan: MultiDestinationExportPlan
    ) -> some View {
        SheetForm(title: L10n.text("Review Copy Plan")) {
            Text((plan.totalFiles == 1 ? L10n.text("\(plan.totalFiles) file will be copied. Originals stay in place.") : L10n.text("\(plan.totalFiles) files will be copied. Originals stay in place.")))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Group {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(plan.routes) { route in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(route.route.predicate.displayName) → \(route.destination.path)")
                                .font(.subheadline.weight(.semibold))
                            Text((route.itemCount == 1 ? (route.mediaFileCount == 1 ? L10n.text("\(route.itemCount) item · \(route.mediaFileCount) media file") : L10n.text("\(route.itemCount) item · \(route.mediaFileCount) media files")) : (route.mediaFileCount == 1 ? L10n.text("\(route.itemCount) items · \(route.mediaFileCount) media file") : L10n.text("\(route.itemCount) items · \(route.mediaFileCount) media files"))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(route.files) { file in
                                Text(filePreviewText(file))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(file.role == .media ? .primary : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Unmatched — not copied"))
                            .font(.subheadline.weight(.semibold))
                        if plan.unmatchedNames.isEmpty {
                            Text(L10n.text("Every current item is routed exactly once."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(plan.unmatchedNames, id: \.self) { name in
                                Text(name)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if let xmp = plan.xmpPlan {
                        Divider()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.text("XMP sidecars"))
                                .font(.subheadline.weight(.semibold))
                            Text((xmp.applicationPacketCount == 1 ? L10n.text("\(xmp.existingRecognizedPacketCount) existing · \(xmp.count(.create)) to create · \(xmp.count(.update)) to update · \(xmp.applicationPacketCount) application packet copied unchanged") : L10n.text("\(xmp.existingRecognizedPacketCount) existing · \(xmp.count(.create)) to create · \(xmp.count(.update)) to update · \(xmp.applicationPacketCount) application packets copied unchanged")))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !xmp.issueFamilies.isEmpty {
                                Text((xmp.issueFamilies.count == 1 ? L10n.text("\(xmp.issueFamilies.count) sidecar family is skipped after safety checks; listed media files still copy.") : L10n.text("\(xmp.issueFamilies.count) sidecar families are skipped after safety checks; listed media files still copy.")))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            Text(L10n.text("Completed copies stay at their destinations after interruption. Originals stay unchanged."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

        } actions: {
            HStack {
                Button(L10n.text("Back")) { exporter.backFromMultiDestinationConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Start Copy")) { exporter.confirmMultiDestinationExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func filePreviewText(
        _ file: MultiDestinationExportPlan.RoutePreview.FilePreview
    ) -> String {
        let copy = file.sourcePath == file.destinationPath
            ? file.sourcePath
            : "\(file.sourcePath) → \(file.destinationPath)"
        switch file.role {
        case .media: return copy
        case .applicationXMP: return L10n.text("\(copy) (XMP application packet)")
        case .preparedXMP: return L10n.text("\(copy) (prepared XMP sidecar)")
        case .retiredXMPSource: return L10n.text("\(copy) (XMP safety record)")
        }
    }

    private func refreshSelectionSnapshot() {
        selectionSnapshot = currentConfiguration.snapshot(
            items: store.items,
            filtered: store.visibleIndices,
            selected: store.selectedIndices
        )
        scheduleXMPInspection()
    }

    private func applyConflictResolutions(
        _ requests: [XMPConflictResolutionRequest],
        origin: XMPConflictResolutionOrigin
    ) {
        let outcome = store.applyXMPConflictResolutions(requests)
        conflictResolver = nil
        conflictResolutionNotice = resolutionNotice(outcome)

        // Resolution may change the active Export predicate. Rebuild it from
        // the authoritative session before either planner captures new input.
        refreshSelectionSnapshot()
        let selected = selectionSnapshot.selectedItems(from: store.items)
        switch origin {
        case .standalone:
            store.resetXMPPublication()
            guard !selected.isEmpty else { return }
            store.prepareXMPPublication(
                selected: selected,
                profile: xmpProfile,
                visibleDecisionKeywords: effectiveVisibleDecisionKeywords,
                allowExternalLabelReplacement:
                    allowExternalLabelReplacement
            )
        case .copyOrMove:
            exporter.reprepareXMPExportAfterResolution(
                selected: selected,
                familyContextItems: store.items,
                sessionGeneration: store.xmpConflictSessionGeneration
            )
        }
    }

    private func resolutionNotice(
        _ outcome: XMPConflictResolutionOutcome
    ) -> String? {
        var parts: [String] = []
        if outcome.appliedCount > 0 {
            parts.append(
                (outcome.appliedCount == 1 ? L10n.text("Unified \(outcome.appliedCount) RAW+JPEG conflict in Louppe. Review the new plan before continuing.") : L10n.text("Unified \(outcome.appliedCount) RAW+JPEG conflicts in Louppe. Review the new plan before continuing."))
            )
        }
        let stale = outcome.staleConflictIDs.count
        if stale > 0 {
            parts.append(
                (stale == 1 ? L10n.text("\(stale) conflict changed while the resolver was open and was not overwritten. The refreshed plan shows the current values.") : L10n.text("\(stale) conflicts changed while the resolver was open and were not overwritten. The refreshed plan shows the current values."))
            )
        }
        let ineligible = outcome.ineligibleConflictIDs.count
        if ineligible > 0 {
            parts.append(
                (ineligible == 1 ? L10n.text("\(ineligible) conflict choice was rejected because the files no longer formed one safe RAW+JPEG pair.") : L10n.text("\(ineligible) conflict choices were rejected because the files no longer formed one safe RAW+JPEG pair."))
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var includeXMPBinding: Binding<Bool> {
        Binding {
            xmpInclusionChoice.isIncluded
        } set: { value in
            xmpInclusionChoice.setManually(value)
        }
    }

    private func scheduleXMPInspection() {
        cancelXMPInspection()
        guard mode != .metadataXMP else {
            isCheckingExistingXMP = false
            excludedACRCompanionCount = 0
            return
        }
        let requestID = UUID()
        xmpInspectionID = requestID
        isCheckingExistingXMP = true
        let selected = selectionSnapshot.selectedItems(from: store.items)
        let context = store.items
        let work = Task.detached(priority: .utility) {
            try? XMPExportPlanner.inspectSources(
                selected: selected,
                familyContextItems: context
            )
        }
        xmpInspectionWork = work
        xmpInspectionTask = Task {
            let inspection = await work.value
            guard !Task.isCancelled, xmpInspectionID == requestID else {
                return
            }
            existingXMPCount = inspection?.recognizedPacketCount ?? 0
            excludedACRCompanionCount =
                inspection?.excludedACRCompanionCount ?? 0
            isCheckingExistingXMP = false
            xmpInclusionChoice.applyRecognizedPacketCount(existingXMPCount)
        }
    }

    private func cancelXMPInspection() {
        xmpInspectionWork?.cancel()
        xmpInspectionWork = nil
        xmpInspectionTask?.cancel()
        xmpInspectionTask = nil
    }

    private var copyMoveXMPExplanation: String {
        if isCheckingExistingXMP {
            return L10n.text("Checking the selected photos for existing XMP sidecars…")
        }
        if xmpInclusionChoice.isIncluded {
            return L10n.text("XMP shares decisions, stars, and colors with editing apps. Include existing sidecars and create missing ones.")
        }
        if existingXMPCount > 0 {
            return mode == .move
                ? L10n.text("Existing XMP sidecars will remain in the source folder.")
                : L10n.text("Existing sidecars will stay at the source and will not be copied.")
        }
        return L10n.text("No XMP sidecars found. Enable to create editing-app ratings beside exported media.")
    }

    private var exportDescription: String {
        if selectedRatings.isEmpty {
            return L10n.text("Select at least one decision tile above to export.")
        }
        if selectedStars.isEmpty {
            return L10n.text("Select at least one star rating to export.")
        }
        if selectedColors.isEmpty {
            return L10n.text("Select at least one color label to export.")
        }
        if selectionSnapshot.itemCount == 0 {
            return selectedRatings == [.yes]
                && selectedStars == ExportSelectionPredicate.allStarStates
                && selectedColors == ExportSelectionPredicate.allColorStates
                ? L10n.text("Mark some items Yes (press F) before exporting.")
                : L10n.text("No items match all selected metadata.")
        }
        let count = selectionSnapshot.itemCount
        var text: String
        switch mode {
        case .copy:
            text = count == 1 ? L10n.text("1 item will be copied") : L10n.text("\(count) items will be copied")
        case .move:
            text = count == 1 ? L10n.text("1 item will be moved") : L10n.text("\(count) items will be moved")
        case .metadataXMP:
            text = count == 1 ? L10n.text("1 item will be prepared for XMP publication") : L10n.text("\(count) items will be prepared for XMP publication")
        }
        if selectionSnapshot.physicalFileCount != selectionSnapshot.itemCount {
            text += L10n.text(" (\(selectionSnapshot.physicalFileCount) files, including RAW+JPEG pairs)")
        }
        text += mode == .copy || mode == .metadataXMP
            ? L10n.text(". Originals are never touched.")
            : "."
        return text
    }

    private var effectiveVisibleDecisionKeywords: Bool {
        xmpProfile == .universal
            ? universalDecisionKeywords
            : xmpProfile.usesVisibleDecisionKeywordsByDefault
    }

    private var mixedMetadataNote: String {
        var parts: [String] = []
        var total = 0
        if scopeMixedStarCount > 0 {
            parts.append((scopeMixedStarCount == 1 ? L10n.text("\(scopeMixedStarCount) mixed-star pair") : L10n.text("\(scopeMixedStarCount) mixed-star pairs")))
            total += scopeMixedStarCount
        }
        if scopeMixedColorCount > 0 {
            parts.append((scopeMixedColorCount == 1 ? L10n.text("\(scopeMixedColorCount) mixed-color pair") : L10n.text("\(scopeMixedColorCount) mixed-color pairs")))
            total += scopeMixedColorCount
        }
        let pairs = parts.joined(separator: L10n.text(" and "))
        return total == 1
            ? L10n.text("\(pairs) matches only when Mixed is selected in the corresponding menu.")
            : L10n.text("\(pairs) match only when Mixed is selected in the corresponding menu.")
    }

    private var scopeIndices: [Int] {
        currentConfiguration.candidateIndices(
            all: store.items.indices,
            filtered: store.visibleIndices,
            selected: store.selectedIndices
        )
    }

    private var scopedItems: [PhotoItem] {
        scopeIndices.compactMap {
            store.items.indices.contains($0) ? store.items[$0] : nil
        }
    }

    private func scopeRatingCount(_ rating: Rating) -> Int {
        scopedItems.count { $0.ratingState.effectiveRating == rating }
    }

    private var scopeMixedStarCount: Int {
        scopedItems.count { $0.starRatingState == .mixed }
    }

    private var scopeMixedColorCount: Int {
        scopedItems.count { $0.colorLabelState == .mixed }
    }

    private var exportScopeRow: some View {
        exportMenuRow(L10n.text("Scope")) {
            Picker(L10n.text("Scope"), selection: $scope) {
                exportScopeLabel(L10n.text("All Media"), scope: .all)
                    .tag(CleanUpScope.all)
                exportScopeLabel(L10n.text("Filtered"), scope: .filtered)
                    .tag(CleanUpScope.filtered)
                exportScopeLabel(L10n.text("Selected"), scope: .selected)
                    .tag(CleanUpScope.selected)
                    .disabled(store.selectedIndices.isEmpty)
            }
            .pickerStyle(.menu)
            .accessibilityLabel(L10n.text("Media to consider"))
        }
    }

    private func exportScopeLabel(_ title: String, scope: CleanUpScope) -> Text {
        let count = scope.candidateIndices(
            all: store.items.indices,
            filtered: store.visibleIndices,
            selected: store.selectedIndices
        ).count
        return Text("\(title) (\(count))")
    }

    private var starSelectionSummary: String {
        selectionSummary(
            selectedStars,
            all: ExportSelectionPredicate.allStarStates,
            label: starStateLabel
        )
    }

    private var colorSelectionSummary: String {
        selectionSummary(
            selectedColors,
            all: ExportSelectionPredicate.allColorStates,
            label: colorStateLabel
        )
    }

    private func selectionSummary<Value: Hashable>(
        _ selected: Set<Value>,
        all: Set<Value>,
        label: (Value) -> String
    ) -> String {
        if selected == all { return L10n.text("All selected") }
        if selected.isEmpty { return L10n.text("None selected") }
        if selected.count == 1, let only = selected.first {
            return label(only)
        }
        return L10n.text("\(selected.count) selected")
    }

    private func starStateLabel(_ state: PhotoItemStarRatingState) -> String {
        switch state {
        case .unrated: return L10n.text("Unrated")
        case .stars(let rating):
            return rating == .one ? L10n.text("1 star") : "\(rating.count) stars"
        case .mixed: return L10n.text("Mixed")
        }
    }

    private func colorStateLabel(_ state: PhotoItemColorLabelState) -> String {
        switch state {
        case .none: return L10n.text("None")
        case .label(let label): return label.localizedDisplayName
        case .mixed: return L10n.text("Mixed")
        }
    }

    private func membershipBinding<Value: Hashable>(
        _ value: Value,
        in selection: Binding<Set<Value>>
    ) -> Binding<Bool> {
        Binding {
            selection.wrappedValue.contains(value)
        } set: { isSelected in
            if isSelected {
                selection.wrappedValue.insert(value)
            } else {
                selection.wrappedValue.remove(value)
            }
        }
    }

    private func exportMenuRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            content()
                .labelsHidden()
                .frame(width: 170)
        }
    }

    private func ratingTile(_ rating: Rating, count: Int, label: String, color: Color) -> some View {
        let isSelected = selectedRatings.contains(rating)
        return Button {
            if isSelected {
                selectedRatings.remove(rating)
            } else {
                selectedRatings.insert(rating)
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.title.bold())
                    .foregroundStyle(isSelected ? color : Color.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 70, maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.12) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected
                        ? color.opacity(0.4)
                        : Color(nsColor: .separatorColor))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(isSelected ? L10n.text("Click to leave \(label) items out") : L10n.text("Click to include \(label) items"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var xmpContent: some View {
        switch store.xmpPublicationState {
        case .idle:
            summaryView
        case .preflighting(let done, let total):
            xmpProgressView(
                title: L10n.text("Checking sidecars…"),
                done: done,
                total: total,
                stopTitle: L10n.text("Stop Checking")
            )
        case .awaitingConfirmation(let plan):
            xmpPreflightView(plan)
        case .publishing(let done, let total):
            xmpProgressView(
                title: L10n.text("Writing Metadata (XMP)…"),
                done: done,
                total: total,
                stopTitle: L10n.text("Stop Writing")
            )
        case .cancelling:
            VStack(spacing: 12) {
                ProgressView()
                    .accessibilityLabel(L10n.text("Stopping metadata work"))
                Text(L10n.text("Stopping at a safe boundary…"))
                    .font(.headline)
                Text(L10n.text("The current sidecar finishes safely first."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .finished(let result):
            xmpFinishedView(result)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                Button(L10n.text("OK")) { store.resetXMPPublication() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func xmpProgressView(
        title: String,
        done: Int,
        total: Int,
        stopTitle: String
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            ProgressView(
                value: Double(done),
                total: Double(max(total, 1))
            )
            .accessibilityLabel(title)
            .accessibilityValue(L10n.text("\(done) of \(total) sidecar families"))
            Text(L10n.text("\(done) of \(total) sidecar families"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(stopTitle) { store.cancelXMPPublication() }
        }
    }

    private func xmpPreflightView(_ plan: XMPPublicationPlan) -> some View {
        let issues = plan.entries.filter { !$0.category.canPublish }
        let changes = plan.changeCounts
        return SheetForm(title: "Metadata (XMP)") {
            Text(L10n.text("Ready to write with \(plan.profile.displayName)"))
                .font(.headline)

            VStack(spacing: 6) {
                xmpCountRow(L10n.text("Selected Louppe items"), plan.selectedItemCount)
                xmpCountRow(L10n.text("Physical photo files"), plan.physicalFileCount)
                xmpCountRow(L10n.text("Sidecars to create"), plan.count(.create))
                xmpCountRow(L10n.text("Sidecars to update"), plan.count(.update))
                xmpCountRow(L10n.text("Already current"), plan.count(.alreadyCurrent))
                xmpCountRow(
                    L10n.text("Existing recognized sidecars"),
                    plan.existingRecognizedSidecarCount
                )
                ForEach(
                    XMPPublicationCategory.allCases.filter {
                        !$0.canPublish
                            && $0 != .copyUnchangedApplicationPacket
                            && plan.count($0) > 0
                    },
                    id: \.rawValue
                ) { category in
                    xmpCountRow(category.label, plan.count(category))
                }
            }

            Text(xmpApplicationNote(plan.profile))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            if !plan.bestEffortFilenames.isEmpty {
                warningText(L10n.text("This app may expect embedded metadata and ignore JPEG, TIFF, DNG, HEIC, or PNG sidecars. Originals stay unchanged. Affected: \(fileList(plan.bestEffortFilenames))"))
            }
            if changes.stars + changes.colors + changes.flags + changes.keywords > 0 {
                warningText(
                    L10n.text("Existing non-empty values will change — stars: \(changes.stars), colors: \(changes.colors), flags: \(changes.flags), reserved decision keywords: \(changes.keywords).")
                )
            }
            if plan.applicationPacketCount > 0 {
                Text((plan.applicationPacketCount == 1 ? L10n.text("\(plan.applicationPacketCount) extension-qualified application packet will stay unchanged beside originals.") : L10n.text("\(plan.applicationPacketCount) extension-qualified application packets will stay unchanged beside originals.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            if plan.excludedACRCompanionCount > 0 {
                warningText((plan.excludedACRCompanionCount == 1 ? L10n.text("\(plan.excludedACRCompanionCount) Lightroom .acr companion will stay untouched beside originals. Louppe never reads or changes Lightroom heavy-edit data.") : L10n.text("\(plan.excludedACRCompanionCount) Lightroom .acr companions will stay untouched beside originals. Louppe never reads or changes Lightroom heavy-edit data.")))
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("These files will be skipped"))
                        .font(.caption.weight(.semibold))
                    ForEach(issues.prefix(6)) { issue in
                        Text("\(issue.filenames.joined(separator: ", ")) — \(issue.category.label)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if issues.count > 6 {
                        Text(L10n.text("…and \(issues.count - 6) more"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let conflictResolutionNotice {
                warningText(conflictResolutionNotice)
            }

        } actions: {
            HStack {
                Button(L10n.text("Back")) { store.resetXMPPublication() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !plan.resolvableSameStemConflicts.isEmpty {
                    Button(L10n.text("Resolve RAW + JPEG Conflicts…")) {
                        conflictResolutionNotice = nil
                        conflictResolver = XMPConflictResolverPresentation(
                            conflicts: plan.resolvableSameStemConflicts,
                            origin: .standalone
                        )
                    }
                }
                Button(L10n.text("Write Sidecars")) {
                    store.startXMPPublication(planID: plan.id)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan.publishableCount == 0)
            }
        }
    }

    private func xmpFinishedView(_ result: XMPPublicationResult) -> some View {
        let hasDetails = !result.details.isEmpty
        return VStack(spacing: 14) {
            Image(systemName: result.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(result.isClean ? Color.louppeAccent : Color.secondary)
            Text(result.cancelled
                ? L10n.text("Metadata writing stopped")
                : result.isClean
                    ? "Metadata (XMP) complete"
                    : L10n.text("Metadata (XMP) finished with problems"))
                .font(.title3.bold())

            VStack(spacing: 6) {
                xmpCountRow(L10n.text("Created"), result.created)
                xmpCountRow(L10n.text("Updated"), result.updated)
                xmpCountRow(L10n.text("Already current"), result.alreadyCurrent)
                xmpCountRow(L10n.text("Skipped"), result.skipped)
                xmpCountRow(L10n.text("Conflicts"), result.conflicts)
                xmpCountRow(L10n.text("Failed"), result.failed)
            }

            if result.cancelled {
                Text(L10n.text("Completed sidecars stay written. No packet was partly replaced."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if showXMPDetails, hasDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.details) { detail in
                            Text("\(detail.filenames.joined(separator: ", ")) — \(detail.category.label): \(detail.message)")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            HStack {
                if hasDetails {
                    Button(showXMPDetails ? L10n.text("Hide Details") : L10n.text("Show Details")) {
                        showXMPDetails.toggle()
                    }
                }
                Button(L10n.text("Done")) {
                    store.resetXMPPublication()
                    store.isExportPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func xmpCountRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func warningText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
    }

    private func fileList(_ names: [String]) -> String {
        if names.count <= 4 { return names.joined(separator: ", ") }
        return names.prefix(4).joined(separator: ", ")
            + L10n.text(", and \(names.count - 4) more")
    }

    private func xmpApplicationNote(_ profile: XMPApplicationProfile) -> String {
        switch profile {
        case .lightroomClassic:
            return L10n.text("After writing, choose Lightroom Classic’s Read Metadata from Files to load the sidecars.")
        case .captureOne:
            return L10n.text("Capture One may need XMP Auto Sync or a manual metadata reload.")
        case .darktable:
            return L10n.text("darktable reads stem sidecars on import; its processing history stays unchanged.")
        case .bridge:
            return L10n.text("Bridge reads sidecar stars, colors, and Louppe decision keywords.")
        case .universal:
            return L10n.text("Universal XMP stores stars, colors, and the full Louppe decision in portable fields.")
        }
    }

    private func workingView(
        mode: ExportMode,
        completedBytes: Int64,
        totalBytes: Int64
    ) -> some View {
        let completed = ByteCountFormatter.string(
            fromByteCount: max(0, completedBytes),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: max(0, totalBytes),
            countStyle: .file
        )
        return VStack(spacing: 12) {
            Text(mode == .copy ? L10n.text("Copying media…") : L10n.text("Moving media…"))
                .font(.headline)
            ProgressView(
                value: Double(max(0, completedBytes)),
                total: Double(max(totalBytes, 1))
            )
            .accessibilityLabel(mode == .copy ? L10n.text("Copying media") : L10n.text("Moving media"))
            .accessibilityValue((mode == .copy ? L10n.text("\(completed) of \(total) copied") : L10n.text("\(completed) of \(total) moved")))
            Text((mode == .copy ? L10n.text("\(completed) of \(total) copied") : L10n.text("\(completed) of \(total) moved")))
                .font(.caption)
                .foregroundStyle(.secondary)
            if mode == .copy {
                Button(exporter.isCancellingCopy ? L10n.text("Stopping…") : L10n.text("Stop Copying…")) {
                    exporter.requestCopyStopConfirmation()
                }
                .disabled(exporter.isCancellingCopy)
                .accessibilityFocused($isStopCopyingFocused)
                .onAppear { isStopCopyingFocused = true }
            }
        }
    }

    private func xmpExportPreparationView(mode: ExportMode) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .accessibilityLabel(L10n.text("Checking XMP sidecars"))
            Text(L10n.text("Checking XMP sidecars…"))
                .font(.headline)
            Text((mode == .copy ? L10n.text("Checking files and sidecars before copying.") : L10n.text("Checking files and sidecars before moving.")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.text("Stop Checking")) {
                exporter.cancelXMPPreparation()
            }
        }
    }

    private func xmpExportPreflightView(
        _ confirmation: ExportManager.XMPConfirmation
    ) -> some View {
        let plan = confirmation.plan
        let changes = plan.changeCounts
        return SheetForm(title: confirmation.mode == .copy ? L10n.text("Copy with XMP") : L10n.text("Move with XMP")) {
            Text(L10n.text("Ready for \(confirmation.destination.lastPathComponent)"))
                .font(.headline)

            VStack(spacing: 6) {
                xmpCountRow(L10n.text("Selected Louppe items"), plan.selectedItemCount)
                xmpCountRow(L10n.text("Physical media files"), plan.physicalFileCount)
                xmpCountRow(
                    L10n.text("Existing recognized sidecars"),
                    plan.existingRecognizedPacketCount
                )
                xmpCountRow(L10n.text("Sidecars to create"), plan.count(.create))
                xmpCountRow(L10n.text("Sidecars to update"), plan.count(.update))
                xmpCountRow(
                    L10n.text("Already current"),
                    plan.count(.alreadyCurrent)
                )
                if plan.applicationPacketCount > 0 {
                    xmpCountRow(
                        L10n.text("Application packets copied unchanged"),
                        plan.applicationPacketCount
                    )
                }
                ForEach(
                    XMPPublicationCategory.allCases.filter {
                        !$0.canPublish
                            && $0 != .copyUnchangedApplicationPacket
                            && plan.count($0) > 0
                    },
                    id: \.rawValue
                ) { category in
                    xmpCountRow(category.label, plan.count(category))
                }
                if plan.excludedACRCompanionCount > 0 {
                    xmpCountRow(
                        L10n.text("Lightroom .acr companions excluded"),
                        plan.excludedACRCompanionCount
                    )
                }
            }

            if changes.stars + changes.colors + changes.flags
                + changes.keywords > 0 {
                Text(L10n.text("Existing values to update: \(changes.stars) star, \(changes.colors) color, \(changes.flags) decision flag, \(changes.keywords) keyword set."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }

            if !plan.bestEffortFilenames.isEmpty {
                Text(L10n.text("Some apps may ignore sidecars for: \(plan.bestEffortFilenames.joined(separator: ", ")). Original media stays unchanged."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }

            if !plan.issueFamilies.isEmpty {
                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.issueFamilies, id: \.id) { family in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(family.filenames.joined(separator: ", "))
                                    .font(.caption.weight(.semibold))
                                Text(family.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let conflictResolutionNotice {
                Text(conflictResolutionNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }

            Text(L10n.text("Included XMP sidecars follow media."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

        } actions: {
            HStack {
                Button(L10n.text("Back")) { exporter.backFromXMPConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !plan.resolvableSameStemConflicts.isEmpty {
                    Button(L10n.text("Resolve RAW + JPEG Conflicts…")) {
                        conflictResolutionNotice = nil
                        conflictResolver = XMPConflictResolverPresentation(
                            conflicts: plan.resolvableSameStemConflicts,
                            origin: .copyOrMove
                        )
                    }
                }
                Button(confirmation.mode == .copy ? L10n.text("Start Copy") : L10n.text("Start Move")) {
                    exporter.confirmXMPExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func finishedView(outcome: ExportManager.Outcome) -> some View {
        VStack(spacing: 14) {
            Image(systemName: outcome.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(outcome.isClean ? Color.louppeAccent : Color.secondary)
            VStack(spacing: 14) {
                Text(finishedTitle(for: outcome))
                    .font(.title3.bold())
                Text(finishedMessage(for: outcome))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityFocused($isExportResultFocused)
            .onAppear { isExportResultFocused = true }
            if let xmp = outcome.xmpSummary {
                VStack(spacing: 6) {
                    xmpCountRow((outcome.mode == .copy ? L10n.text("Media copied") : L10n.text("Media moved")), xmp.mediaFiles)
                    xmpCountRow(L10n.text("Sidecars created"), xmp.created)
                    xmpCountRow(L10n.text("Sidecars updated"), xmp.updated)
                    xmpCountRow(L10n.text("Sidecars already current"), xmp.alreadyCurrent)
                    xmpCountRow(
                        L10n.text("Application packets copied unchanged"),
                        xmp.copiedUnchanged
                    )
                    if xmp.unsupported > 0 {
                        xmpCountRow(L10n.text("Unsupported media"), xmp.unsupported)
                    }
                    if xmp.skipped > 0 {
                        xmpCountRow(L10n.text("Skipped"), xmp.skipped)
                    }
                    if xmp.conflicts > 0 {
                        xmpCountRow(L10n.text("Conflicts"), xmp.conflicts)
                    }
                    if xmp.failed > 0 {
                        xmpCountRow(L10n.text("XMP failures"), xmp.failed)
                    }
                }
            }
            HStack {
                Button(outcome.destinations.count > 1 ? L10n.text("Show First Folder") : L10n.text("Show in Finder")) {
                    exporter.revealInFinder(outcome.destination)
                }
                Button(L10n.text("Done")) {
                    store.isExportPresented = false
                    exporter.reset()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func finishedTitle(for outcome: ExportManager.Outcome) -> String {
        if outcome.recoveryRequired {
            return outcome.mode == .copy
                ? L10n.text("Securing copied files")
                : L10n.text("Securing moved files")
        }
        if outcome.cancelled { return L10n.text("Copy stopped") }
        return outcome.isClean ? L10n.text("Export complete") : L10n.text("Export finished with problems")
    }

    private func finishedMessage(for outcome: ExportManager.Outcome) -> String {
        if outcome.recoveryRequired {
            let cause = outcome.failureMessage.map {
                $0.hasSuffix(".") ? "\($0) " : "\($0). "
            } ?? ""
            if outcome.mode == .copy {
                return cause
                    + L10n.text("Louppe recorded the interruption and keeps verified completed copies. Wait for recovery to check unfinished work before another file operation.")
            }
            return cause
                + L10n.text("Completed groups stay at the destination; incomplete groups return to the source. Wait for recovery before another file operation.")
        }
        let count = outcome.files
        var text: String
        if outcome.destinations.count > 1 {
            text = outcome.mode == .copy
                ? L10n.text("Copied files: \(count). Destination folders: \(outcome.destinations.count).")
                : L10n.text("Moved files: \(count). Destination folders: \(outcome.destinations.count).")
        } else {
            let folder = outcome.destination.lastPathComponent
            text = outcome.mode == .copy
                ? L10n.text("Copied files: \(count). Destination: \(folder)")
                : L10n.text("Moved files: \(count). Destination: \(folder)")
        }
        switch outcome.mode {
        case .copy:
            if outcome.cancelled {
                text += L10n.text(". Completed photos stay at the destination; the photo in progress rolled back.")
                if let reason = outcome.cancellationReason {
                    text += " \(reason.userMessage)"
                } else {
                    text += L10n.text(" The stop reason is missing. Send the diagnostic log with this report.")
                }
            } else if outcome.failedPhotos > 0 {
                text += (outcome.failedPhotos == 1 ? L10n.text(" — \(outcome.failedPhotos) item couldn't be copied and rolled back.") : L10n.text(" — \(outcome.failedPhotos) items couldn't be copied and rolled back."))
            } else {
                text += "."
            }
            if outcome.inconsistentPhotos > 0 {
                text += L10n.text(" For \(outcome.inconsistentPhotos), rollback also failed; check the destination for a partial pair.")
            }
        case .move:
            if outcome.failedPhotos > 0 {
                text += (outcome.failedPhotos == 1 ? L10n.text(" — \(outcome.failedPhotos) item couldn't be moved and stayed in the session.") : L10n.text(" — \(outcome.failedPhotos) items couldn't be moved and stayed in the session."))
            } else {
                text += "."
            }
            if outcome.inconsistentPhotos > 0 {
                text += L10n.text(" For \(outcome.inconsistentPhotos), rollback also failed; check both the source folder and the destination.")
            }
        case .metadataXMP:
            break
        }
        if outcome.journalFailure {
            text += L10n.text(" Safety checks stopped the operation before the next file. Affected originals remain at their last verified location.")
        }
        if let failure = outcome.failureMessage {
            text += failure.hasSuffix(".") ? " \(failure)" : " \(failure)."
        }
        return text
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityFocused($isExportResultFocused)
                .onAppear { isExportResultFocused = true }
            Button(L10n.text("OK")) {
                exporter.reset(keepingRoutingDestinations: true)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }
}
