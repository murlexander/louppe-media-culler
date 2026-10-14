import Foundation
import OSLog

/// Pure, non-observable session indexing state.
///
/// `SessionStore` remains the UI-facing source of truth, but delegates
/// structure-dependent lookup work here so sorting, filtering, grouping, and
/// navigation maps can be tested without creating a window or observable
/// object. The item array itself stays owned by `SessionStore`.
struct PreparedSessionIndex {
    private static let signposter = OSSignposter(
        subsystem: "com.alexandermarkin.louppe",
        category: "Session Index"
    )

    struct VisibleLocation: Equatable {
        let position: Int
        let groupIndex: Int
        let positionInGroup: Int
    }

    /// Stable Browser identity prepared only when visibility changes. Keeping
    /// this beside `visibleIndices` avoids rebuilding an O(N) id/index array
    /// every time a rating or loading indicator publishes the store.
    struct VisibleEntry: Identifiable, Equatable {
        let id: String
        let index: Int
    }

    private(set) var sortedIndices: [Int] = []
    /// Immutable capture-date/name/ID order for the current item structure.
    /// Review metadata mutations share small stores and cannot change this order.
    private var chronologicalIndices: [Int]?
    private(set) var itemIndexByID: [String: Int] = [:]
    private(set) var visibleIndices: [Int] = []
    private(set) var visibleEntries: [VisibleEntry] = []
    private(set) var visibleGroups: [PhotoGroup] = []
    private(set) var visibleGroupTitles: [Int: String] = [:]
    private(set) var visibleLocations: [Int: VisibleLocation] = [:]

    mutating func rebuildItems(
        _ items: [PhotoItem],
        sort: PhotoSort
    ) {
        let interval = Self.signposter.beginInterval("Rebuild Item Index")
        defer {
            Self.signposter.endInterval("Rebuild Item Index", interval)
        }
        var indicesByID: [String: Int] = [:]
        indicesByID.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            indicesByID[item.id] = index
        }
        itemIndexByID = indicesByID
        chronologicalIndices = Self.chronologicalOrder(for: items)
        rebuildPreparedSort(items, sort: sort)
    }

    /// Pure entry point for arbitrary input, including a different permutation
    /// or same-count replacement. It never trusts an earlier item's chronology.
    mutating func rebuildSort(
        _ items: [PhotoItem],
        sort: PhotoSort
    ) {
        invalidateItemOrder()
        rebuildPreparedSort(items, sort: sort)
    }

    /// Call when immutable items change, before any sort-only projection. The
    /// structural owner still rebuilds ID/maps through `rebuildItems` as usual.
    mutating func invalidateItemOrder() {
        chronologicalIndices = nil
    }

    /// Sort-only entry point for the item structure prepared by `rebuildItems`.
    /// Callers must invalidate/rebuild after replacing, reordering or enriching
    /// immutable items. Ratings, stars and colors do not invalidate chronology.
    mutating func rebuildPreparedSort(
        _ items: [PhotoItem],
        sort: PhotoSort
    ) {
        let interval = Self.signposter.beginInterval("Sort Session")
        defer {
            Self.signposter.endInterval("Sort Session", interval)
        }
        if sort == PhotoSort() {
            sortedIndices = preparedChronologicalOrder(for: items)
            return
        }
        switch sort.key {
        case .folderHierarchy:
            rebuildFolderHierarchySort(items, ascending: sort.ascending)
        case .decision, .starRating, .colorLabel:
            rebuildMetadataSort(items, sort: sort)
        default:
            sortedIndices = items.indices.sorted {
                sort.areInOrder(items[$0], items[$1])
            }
        }
    }

    private mutating func preparedChronologicalOrder(for items: [PhotoItem]) -> [Int] {
        if let chronologicalIndices, chronologicalIndices.count == items.count {
            return chronologicalIndices
        }
        let order = Self.chronologicalOrder(for: items)
        chronologicalIndices = order
        return order
    }

    /// Scans normally arrive canonical, so verify once in O(N). Exceptional
    /// reconstruction and pure callers may supply any permutation; normalize
    /// those with the same comparator instead of assuming raw array order.
    private static func chronologicalOrder(for items: [PhotoItem]) -> [Int] {
        let chronological = PhotoSort()
        let indices = Array(items.indices)
        for index in items.indices.dropFirst() {
            if chronological.areInOrder(items[index], items[index - 1]) {
                return indices.sorted {
                    chronological.areInOrder(items[$0], items[$1])
                }
            }
        }
        return indices
    }

    /// Finite review values use a stable linear pass over canonical chronology.
    /// Direction changes the value buckets only: equal values retain oldest,
    /// Finder-name and exact-ID order. Missing stars/colors precede Mixed and
    /// stay last in either direction, matching `PhotoSort`.
    private mutating func rebuildMetadataSort(_ items: [PhotoItem], sort: PhotoSort) {
        let chronological = preparedChronologicalOrder(for: items)
        let valueCount = sort.key == .decision ? 4 : (
            sort.key == .starRating ? StarRating.allCases.count : PhotoColorLabel.allCases.count
        )
        let bucketCount = sort.key == .decision ? valueCount : valueCount + 2
        var buckets = Array(repeating: [Int](), count: bucketCount)
        for index in chronological {
            let metadata = items[index].metadataState
            let rank: Int
            switch sort.key {
            case .decision:
                let natural: Int
                switch metadata.decision {
                case .yes: natural = 0
                case .undecided: natural = 1
                case .mixed: natural = 2
                case .no: natural = 3
                }
                rank = sort.ascending ? natural : valueCount - 1 - natural
            case .starRating:
                switch metadata.stars {
                case .stars(let value):
                    rank = sort.ascending ? value.count - 1 : valueCount - value.count
                case .unrated: rank = valueCount
                case .mixed: rank = valueCount + 1
                }
            case .colorLabel:
                switch metadata.color {
                case .label(let label):
                    let natural = PhotoColorLabel.allCases.firstIndex(of: label)!
                    rank = sort.ascending ? natural : valueCount - 1 - natural
                case .none: rank = valueCount
                case .mixed: rank = valueCount + 1
                }
            default:
                preconditionFailure("A finite metadata key is required")
            }
            buckets[rank].append(index)
        }
        var result: [Int] = []
        result.reserveCapacity(items.count)
        for bucket in buckets { result.append(contentsOf: bucket) }
        sortedIndices = result
    }

    /// Compare each distinct directory only once, then sort by small ranks.
    /// Large folders should not repeatedly split paths or perform localized
    /// component comparisons for every pair of photos in the sort.
    private mutating func rebuildFolderHierarchySort(
        _ items: [PhotoItem],
        ascending: Bool
    ) {
        var folderIndexByIdentity: [Data: Int] = [:]
        var folders: [PhotoSort.FolderPath] = []
        let itemFolders = items.map { item in
            let identity = PhotoSort.FolderPath.identity(for: item)
            if let index = folderIndexByIdentity[identity] { return index }
            let index = folders.count
            folderIndexByIdentity[identity] = index
            folders.append(PhotoSort.FolderPath(identity: identity))
            return index
        }
        let orderedFolders = folders.indices.sorted {
            folders[$0].isOrdered(before: folders[$1], ascending: ascending)
        }
        var ranks = Array(repeating: 0, count: folders.count)
        for (rank, index) in orderedFolders.enumerated() { ranks[index] = rank }
        let chronological = PhotoSort()
        sortedIndices = items.indices.sorted {
            let leftRank = ranks[itemFolders[$0]]
            let rightRank = ranks[itemFolders[$1]]
            if leftRank != rightRank { return leftRank < rightRank }
            return chronological.areInOrder(items[$0], items[$1])
        }
    }

    mutating func applyFilter(
        _ filter: PhotoFilter,
        to items: [PhotoItem],
        sort: PhotoSort,
        isGroupingEnabled: Bool,
        qualityCueMatches: [QualityCueMatch]? = nil
    ) {
        let interval = Self.signposter.beginInterval("Filter Session")
        defer {
            Self.signposter.endInterval("Filter Session", interval)
        }
        let prepared = PreparedPhotoFilter(filter)
        if let qualityCueMatches, !filter.selectedQualityCues.isEmpty {
            precondition(qualityCueMatches.count == items.count, "Cue matches must follow the item structure")
            let selected = QualityCueMatch(filter.selectedQualityCues)
            visibleIndices = sortedIndices.filter {
                !qualityCueMatches[$0].intersection(selected).isEmpty && prepared.matches(items[$0])
            }
        } else {
            visibleIndices = sortedIndices.filter { prepared.matches(items[$0]) }
        }
        rebuildGroups(
            for: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled
        )
    }

    mutating func rebuildGroups(
        for items: [PhotoItem],
        sort: PhotoSort,
        isGroupingEnabled: Bool
    ) {
        let interval = Self.signposter.beginInterval("Build Visible Groups")
        defer {
            Self.signposter.endInterval("Build Visible Groups", interval)
        }
        visibleGroups = makeGroups(
            for: items,
            sort: sort,
            isGroupingEnabled: isGroupingEnabled
        )
        rebuildVisiblePresentation(for: items)
    }

    /// Projects one already-filtered session into a review-only group layout.
    /// The analyzer owns stable item IDs; this index maps them back into the
    /// current item generation. Capture bursts retain partially filtered
    /// membership (even one remaining member) with full/visible counts; exact
    /// and similar groups still require two visible members. The original sorted
    /// list remains untouched, so leaving grouped review is a cheap rebuild.
    mutating func applyGroupedReview(
        _ reviewGroups: [DuplicateBurstAnalysis.Group],
        to items: [PhotoItem]
    ) {
        guard !reviewGroups.isEmpty, !visibleIndices.isEmpty else {
            visibleIndices = []
            visibleGroups = []
            rebuildVisiblePresentation(for: items)
            return
        }

        let visibleSet = Set(visibleIndices)
        let normalPosition = Dictionary(
            uniqueKeysWithValues: visibleIndices.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        var projectedGroups: [PhotoGroup] = []
        var seenIndices = Set<Int>()
        for reviewGroup in reviewGroups {
            let indices = reviewGroup.itemIDs.compactMap(itemIndex(forID:))
                .filter { visibleSet.contains($0) && !seenIndices.contains($0) }
                .sorted {
                    (normalPosition[$0] ?? .max) < (normalPosition[$1] ?? .max)
                }
            guard !indices.isEmpty,
                  reviewGroup.mode == .captureBursts || indices.count >= 2 else { continue }
            seenIndices.formUnion(indices)
            projectedGroups.append(
                PhotoGroup(
                    id: PhotoGroup.ID(
                        key: nil,
                        value: .text("review-\(reviewGroup.id)")
                    ),
                    title: reviewGroup.mode != .captureBursts || indices.count == reviewGroup.itemIDs.count
                        ? reviewGroup.title(itemCount: indices.count)
                        : reviewGroup.title(itemCount: indices.count)
                            + L10n.text(" (\(indices.count) of \(reviewGroup.itemIDs.count) shown)"),
                    indices: indices
                )
            )
        }
        projectedGroups.sort {
            (normalPosition[$0.indices[0]] ?? .max) < (normalPosition[$1.indices[0]] ?? .max)
        }
        visibleGroups = projectedGroups
        visibleIndices = projectedGroups.flatMap(\.indices)
        rebuildVisiblePresentation(for: items)
    }

    private mutating func rebuildVisiblePresentation(for items: [PhotoItem]) {
        visibleEntries = visibleIndices.compactMap { index in
            guard items.indices.contains(index) else { return nil }
            return VisibleEntry(id: items[index].id, index: index)
        }

        var titles: [Int: String] = [:]
        var locations: [Int: VisibleLocation] = [:]
        locations.reserveCapacity(visibleIndices.count)
        var visiblePosition = 0
        for (groupIndex, group) in visibleGroups.enumerated() {
            if let title = group.title, let first = group.indices.first {
                titles[first] = title
            }
            for (positionInGroup, itemIndex) in group.indices.enumerated() {
                locations[itemIndex] = VisibleLocation(
                    position: visiblePosition,
                    groupIndex: groupIndex,
                    positionInGroup: positionInGroup
                )
                visiblePosition += 1
            }
        }
        visibleGroupTitles = titles
        visibleLocations = locations
    }

    func itemIndex(forID id: String) -> Int? {
        itemIndexByID[id]
    }

    func location(forItemIndex index: Int) -> VisibleLocation? {
        visibleLocations[index]
    }

    mutating func reset() {
        self = PreparedSessionIndex()
    }

    private func makeGroups(
        for items: [PhotoItem],
        sort: PhotoSort,
        isGroupingEnabled: Bool
    ) -> [PhotoGroup] {
        guard !visibleIndices.isEmpty else { return [] }
        guard isGroupingEnabled, sort.key != .name else {
            return [
                PhotoGroup(
                    id: .ungrouped,
                    title: nil,
                    indices: visibleIndices
                )
            ]
        }

        let key = sort.key
        var groups: [PhotoGroup] = []
        var run: [Int] = []
        var previousItem: PhotoItem?

        func closeRun() {
            guard let first = run.first else { return }
            let firstItem = items[first]
            groups.append(
                PhotoGroup(
                    id: key.groupID(for: firstItem),
                    title: key.groupTitle(for: firstItem),
                    indices: run
                )
            )
        }

        for index in visibleIndices {
            let item = items[index]
            if let previousItem, !key.sameGroup(previousItem, item) {
                closeRun()
                run = []
            }
            run.append(index)
            previousItem = item
        }
        closeRun()
        return groups
    }
}
