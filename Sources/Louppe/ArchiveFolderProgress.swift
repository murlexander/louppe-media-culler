import Foundation

/// Reviewed counts per folder for quiet completion marks. Counts follow the
/// index's pair-aware rules: an item counts once per folder and once at
/// shared ancestors. Built once per index generation, then updated per
/// changed decision in O(folder depth); it never reads media or the disk.
final class ArchiveFolderProgress {
    let generation: UUID
    let itemCount: Int
    private var reviewedItems: [Bool]
    private var subtreeReviewed: [Int32]
    private var directReviewed: [Int32]

    init(index: ArchiveFolderIndex, isReviewed: (Int) -> Bool) {
        generation = index.generation
        itemCount = index.indexedItemCount
        reviewedItems = Array(repeating: false, count: itemCount)
        subtreeReviewed = Array(repeating: 0, count: index.orderedFolderIDs.count)
        directReviewed = Array(repeating: 0, count: index.orderedFolderIDs.count)
        for item in 0..<itemCount where isReviewed(item) {
            reviewedItems[item] = true
            apply(item: item, delta: 1, index: index)
        }
    }

    /// Returns true when the item's reviewed state changed.
    @discardableResult
    func set(item: Int, reviewed: Bool, index: ArchiveFolderIndex) -> Bool {
        guard index.generation == generation, reviewedItems.indices.contains(item),
              reviewedItems[item] != reviewed else { return false }
        reviewedItems[item] = reviewed
        apply(item: item, delta: reviewed ? 1 : -1, index: index)
        return true
    }

    func reviewedCount(for id: String, includesDescendants: Bool, index: ArchiveFolderIndex) -> Int {
        guard index.generation == generation, let ordinal = index.ordinal(for: id) else { return 0 }
        return Int(id.isEmpty || includesDescendants ? subtreeReviewed[ordinal] : directReviewed[ordinal])
    }

    func isComplete(_ id: String, includesDescendants: Bool, index: ArchiveFolderIndex) -> Bool {
        guard let node = index.node(for: id) else { return false }
        let total = id.isEmpty || includesDescendants ? node.subtreeCount : node.directCount
        return total > 0 && reviewedCount(for: id, includesDescendants: includesDescendants, index: index) == total
    }

    private func apply(item: Int, delta: Int32, index: ArchiveFolderIndex) {
        let start = Int(index.itemFolderOffsets[item]), end = Int(index.itemFolderOffsets[item + 1])
        guard start < end else { return }
        if end - start == 1 {
            // The usual case: one folder, one ancestor chain, nothing shared.
            var ordinal = index.itemFolderOrdinals[start]
            directReviewed[Int(ordinal)] += delta
            while true {
                subtreeReviewed[Int(ordinal)] += delta
                guard ordinal != 0 else { break }
                ordinal = index.parentOrdinals[Int(ordinal)]
            }
            return
        }
        // Cross-folder pairs share ancestors; each folder counts the item once.
        var visited: Set<Int32> = []
        for position in start..<end {
            var ordinal = index.itemFolderOrdinals[position]
            directReviewed[Int(ordinal)] += delta
            while visited.insert(ordinal).inserted {
                subtreeReviewed[Int(ordinal)] += delta
                guard ordinal != 0 else { break }
                ordinal = index.parentOrdinals[Int(ordinal)]
            }
        }
    }
}
