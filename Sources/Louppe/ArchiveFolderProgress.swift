import Foundation

/// Direct Yes/No counts per folder for Next Folder with Unmarked Items. An item counts
/// once in each physical parent folder it belongs to (a cross-folder pair
/// counts in both). Built once per index generation, then updated per changed
/// decision in O(parent folders); it never reads media or the disk.
final class ArchiveFolderProgress {
    let generation: UUID
    let itemCount: Int
    private var reviewedItems: [Bool]
    private var directReviewed: [Int32]

    init(index: ArchiveFolderIndex, isReviewed: (Int) -> Bool) {
        generation = index.generation
        itemCount = index.indexedItemCount
        reviewedItems = Array(repeating: false, count: itemCount)
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

    /// Items directly in `id` (not its subfolders) with Yes or No.
    func directReviewedCount(for id: String, index: ArchiveFolderIndex) -> Int {
        guard index.generation == generation, let ordinal = index.ordinal(for: id) else { return 0 }
        return Int(directReviewed[ordinal])
    }

    private func apply(item: Int, delta: Int32, index: ArchiveFolderIndex) {
        // The index lists each physical parent folder once per item.
        let start = Int(index.itemFolderOffsets[item]), end = Int(index.itemFolderOffsets[item + 1])
        for position in start..<end {
            directReviewed[Int(index.itemFolderOrdinals[position])] += delta
        }
    }
}
