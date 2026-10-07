import Foundation

/// One explicit rule for a Copy-only multi-destination export.  Deliberately
/// keeping v1 to one typed condition per route avoids an invisible "any"
/// fallback and makes the destination preview easy to audit.
enum MultiDestinationRoutePredicate: Equatable, Hashable, Sendable {
    case decision(Rating)
    case stars(PhotoItemStarRatingState)
    case color(PhotoItemColorLabelState)
    case fileType(String)
    case mediaKind(MediaKind)

    enum Dimension: CaseIterable, Hashable, Sendable {
        case decision
        case stars
        case color
        case fileType
        case mediaKind

        var title: String {
            switch self {
            case .decision: return L10n.text("Decision")
            case .stars: return L10n.text("Stars")
            case .color: return L10n.text("Color")
            case .fileType: return L10n.text("File type")
            case .mediaKind: return L10n.text("Media type")
            }
        }
    }

    var dimension: Dimension {
        switch self {
        case .decision: return .decision
        case .stars: return .stars
        case .color: return .color
        case .fileType: return .fileType
        case .mediaKind: return .mediaKind
        }
    }

    var displayName: String {
        switch self {
        case .decision(let rating):
            return L10n.text("Decision: \(rating.displayName)")
        case .stars(let state):
            return L10n.text("Stars: \(state.displayName)")
        case .color(let state):
            return L10n.text("Color: \(state.displayName)")
        case .fileType(let type):
            return L10n.text("File type: \(type)")
        case .mediaKind(let kind):
            return L10n.text("Media type: \(kind.label)")
        }
    }

    func matches(_ item: PhotoItem) -> Bool {
        let metadata = item.metadataState
        switch self {
        case .decision(let rating):
            return metadata.decision.effectiveRating == rating
        case .stars(let state):
            return metadata.stars == state
        case .color(let state):
            return metadata.color == state
        case .fileType(let type):
            return item.fileTypeLabel == type
        case .mediaKind(let kind):
            return item.mediaKind == kind
        }
    }
}

extension Rating {
    var displayName: String {
        switch self {
        case .yes: return L10n.text("Yes")
        case .no: return L10n.text("No")
        case .undecided: return L10n.text("Undecided")
        }
    }
}

extension PhotoItemStarRatingState {
    var displayName: String {
        switch self {
        case .unrated: return L10n.text("Unrated")
        case .stars(let rating):
            return rating == .one ? L10n.text("1 star") : L10n.text("\(rating.count) stars")
        case .mixed: return L10n.text("Mixed")
        }
    }
}

extension PhotoItemColorLabelState {
    var displayName: String {
        switch self {
        case .none: return L10n.text("None")
        case .label(let label): return label.displayName
        case .mixed: return L10n.text("Mixed")
        }
    }
}

struct MultiDestinationExportRoute: Identifiable, Equatable, Sendable {
    let id: UUID
    var predicate: MultiDestinationRoutePredicate
    /// Nil is intentionally invalid. There is no default folder and no
    /// implicit use of a previously chosen normal Export destination.
    var destination: URL?

    init(
        id: UUID = UUID(),
        predicate: MultiDestinationRoutePredicate,
        destination: URL? = nil
    ) {
        self.id = id
        self.predicate = predicate
        self.destination = destination
    }
}

/// Pure route membership projection. It is intentionally separate from
/// filesystem planning so the UI and tests can prove that each item is either
/// routed once, shown as unmatched, or blocks confirmation as an overlap.
struct MultiDestinationExportEvaluation: Equatable, Sendable {
    struct RouteMatch: Equatable, Sendable {
        let routeID: UUID
        var itemIndices: [Int]

        var itemCount: Int { itemIndices.count }
    }

    let routeMatches: [RouteMatch]
    let unmatchedItemIndices: [Int]
    let overlappingItemIndices: [Int]

    var emptyRouteIDs: Set<UUID> {
        Set(routeMatches.filter { $0.itemIndices.isEmpty }.map(\.routeID))
    }

    static func evaluate(
        routes: [MultiDestinationExportRoute],
        items: [PhotoItem]
    ) -> MultiDestinationExportEvaluation {
        var matches = routes.map { RouteMatch(routeID: $0.id, itemIndices: []) }
        var unmatched: [Int] = []
        var overlapping: [Int] = []

        for (itemIndex, item) in items.enumerated() {
            let matchingRouteIndices = routes.indices.filter {
                routes[$0].predicate.matches(item)
            }
            switch matchingRouteIndices.count {
            case 0:
                unmatched.append(itemIndex)
            case 1:
                matches[matchingRouteIndices[0]].itemIndices.append(itemIndex)
            default:
                overlapping.append(itemIndex)
            }
        }
        return MultiDestinationExportEvaluation(
            routeMatches: matches,
            unmatchedItemIndices: unmatched,
            overlappingItemIndices: overlapping
        )
    }
}

/// The immutable multi-destination Copy plan shown immediately before the
/// journal is activated.  Every source and final target is represented in the
/// existing ExportWorker plan, so one recovery record covers all folders.
struct MultiDestinationExportPlan: Equatable, Sendable {
    struct RoutePreview: Identifiable, Equatable, Sendable {
        struct FilePreview: Identifiable, Equatable, Sendable {
            let id: String
            let sourceName: String
            let destinationName: String
            let sourcePath: String
            let destinationPath: String
            let role: FileOperationJournal.PlannedFileRole
        }

        let route: MultiDestinationExportRoute
        let destination: URL
        let itemCount: Int
        let mediaFileCount: Int
        let files: [FilePreview]

        var id: UUID { route.id }
        var fileCount: Int { files.count }
    }

    let routes: [RoutePreview]
    let unmatchedNames: [String]
    let workerPlan: ExportWorker.Plan
    let xmpPlan: XMPExportPreparedPlan?

    var totalFiles: Int { workerPlan.totalFiles }
    var destinations: [URL] { routes.map(\.destination) }
}

enum MultiDestinationExportPlanner {
    enum PlannerError: LocalizedError, Equatable {
        case noRoutes
        case missingDestination
        case emptyRoute
        case overlappingRoutes
        case splitXMPFamily

        var errorDescription: String? {
            switch self {
            case .noRoutes:
                return L10n.text("Add at least one route before reviewing the copy plan.")
            case .missingDestination:
                return L10n.text("Choose a destination folder for every route before reviewing the copy plan.")
            case .emptyRoute:
                return L10n.text("Each route must match an item. Remove empty routes or change their criteria.")
            case .overlappingRoutes:
                return L10n.text("Some items match more than one route. Make the routes exclusive before reviewing the copy plan.")
            case .splitXMPFamily:
                return L10n.text("XMP would split a same-stem media family across destinations. Keep it in one route or turn off Include XMP sidecars.")
            }
        }
    }

    struct PreparationInput: Sendable {
        let routes: [MultiDestinationExportRoute]
        let items: [PhotoItem]
        let sourceFolder: URL?
        let includeXMP: Bool
        let familyContextItems: [PhotoItem]
        let sessionGeneration: UInt64
        let xmpProfile: XMPApplicationProfile
        let visibleDecisionKeywords: Bool
        let allowExternalLabelReplacement: Bool
    }

    struct PreparedWork: Sendable {
        let plan: MultiDestinationExportPlan
        let selectedItems: [PhotoItem]
    }

    static func prepare(_ input: PreparationInput) async throws -> PreparedWork {
        guard !input.routes.isEmpty else { throw PlannerError.noRoutes }
        guard input.routes.allSatisfy({ $0.destination != nil }) else {
            throw PlannerError.missingDestination
        }

        let evaluation = MultiDestinationExportEvaluation.evaluate(
            routes: input.routes,
            items: input.items
        )
        guard evaluation.overlappingItemIndices.isEmpty else {
            throw PlannerError.overlappingRoutes
        }
        guard evaluation.emptyRouteIDs.isEmpty else {
            throw PlannerError.emptyRoute
        }

        let selections = zip(input.routes, evaluation.routeMatches).map {
            route, match in
            (route: route, items: match.itemIndices.map { input.items[$0] })
        }
        let requests = selections.compactMap { selection -> ExportDestinationValidator.MultiDestinationRequest? in
            guard let destination = selection.route.destination else { return nil }
            return ExportDestinationValidator.MultiDestinationRequest(
                routeID: selection.route.id,
                destination: destination,
                items: selection.items
            )
        }
        let validatedDestinations = try ExportDestinationValidator.validateMultiple(
            sourceFolder: input.sourceFolder,
            requests: requests
        )
        guard validatedDestinations.count == selections.count else {
            throw PlannerError.missingDestination
        }
        let destinationByRouteID = Dictionary(
            uniqueKeysWithValues: zip(requests.map(\.routeID), validatedDestinations)
        )

        var preparedXMPByRoute: [UUID: XMPExportPreparedPlan] = [:]
        if input.includeXMP {
            for selection in selections {
                try Task.checkCancellation()
                preparedXMPByRoute[selection.route.id] = try await XMPExportPlanner.prepare(
                    selected: selection.items,
                    familyContextItems: input.familyContextItems,
                    sessionGeneration: input.sessionGeneration,
                    profile: input.xmpProfile,
                    visibleDecisionKeywords: input.visibleDecisionKeywords,
                    allowExternalLabelReplacement:
                        input.allowExternalLabelReplacement
                )
            }
            let routeIDsByFamily = preparedXMPByRoute.reduce(
                into: [String: Set<UUID>]()
            ) { result, entry in
                for family in entry.value.families {
                    result[family.id, default: []].insert(entry.key)
                }
            }
            guard routeIDsByFamily.values.allSatisfy({ $0.count == 1 }) else {
                throw PlannerError.splitXMPFamily
            }
        }

        var combinedItems: [ExportWorker.PlannedItem] = []
        var unplannedSidecarFamilyCount = 0
        var previews: [MultiDestinationExportPlan.RoutePreview] = []
        for selection in selections {
            try Task.checkCancellation()
            guard let destination = destinationByRouteID[selection.route.id] else {
                throw PlannerError.missingDestination
            }
            let routePlan = try ExportWorker.makePlan(
                for: selection.items,
                in: destination.url,
                xmpPlan: preparedXMPByRoute[selection.route.id],
                mode: .copy,
                destinationBinding: destination.binding
            )
            combinedItems.append(contentsOf: routePlan.items)
            unplannedSidecarFamilyCount += routePlan.unplannedSidecarFamilyCount
            let files = routePlan.items.flatMap(\.files).map { file in
                MultiDestinationExportPlan.RoutePreview.FilePreview(
                    id: file.target.path,
                    sourceName: file.source.lastPathComponent,
                    destinationName: file.target.lastPathComponent,
                    sourcePath: file.source.path,
                    destinationPath: file.target.path,
                    role: file.role
                )
            }
            previews.append(.init(
                route: selection.route,
                destination: destination.url,
                itemCount: selection.items.count,
                mediaFileCount: selection.items.reduce(0) { $0 + $1.allURLs.count },
                files: files
            ))
        }

        let combinedXMP: XMPExportPreparedPlan?
        if input.includeXMP {
            combinedXMP = XMPExportPreparedPlan(
                selectedItemCount: selections.reduce(0) { $0 + $1.items.count },
                physicalFileCount: selections.reduce(0) {
                    $0 + $1.items.reduce(0) { $0 + $1.allURLs.count }
                },
                families: selections.flatMap {
                    preparedXMPByRoute[$0.route.id]?.families ?? []
                }
            )
        } else {
            combinedXMP = nil
        }
        let unmatchedNames = evaluation.unmatchedItemIndices.map {
            input.items[$0].displayName
        }
        return PreparedWork(
            plan: MultiDestinationExportPlan(
                routes: previews,
                unmatchedNames: unmatchedNames,
                workerPlan: ExportWorker.Plan(
                    items: combinedItems,
                    unplannedSidecarFamilyCount: unplannedSidecarFamilyCount,
                    destinationBindings: validatedDestinations.map(\.binding)
                ),
                xmpPlan: combinedXMP
            ),
            selectedItems: selections.flatMap(\.items)
        )
    }
}
