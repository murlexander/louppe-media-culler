import Foundation
import Combine

struct OpeningSessionSnapshot: Sendable {
    /// A fresh complete inventory, or provisional cached observations. Cached
    /// snapshots contain no saved badges and can include removed files.
    /// No metadata completion ever mutates this projection or its ordering.
    let items: [PhotoItem]
    var isCached = false
}

enum OpeningViewportSurface: Hashable, Sendable { case browser, grid }

struct OpeningViewportReceipt: Equatable, Sendable {
    let surface: OpeningViewportSurface
    let physicalFileID: String
    /// Native document points from the viewport top, including partial rows.
    let topOffset: Double
}

struct OpeningSessionHandoff {
    let currentPhysicalFileID: String?
    let selectedPhysicalFileIDs: Set<String>
    let viewMode: ViewMode
    let viewportReceipts: [OpeningViewportSurface: OpeningViewportReceipt]
}

/// Read-only browse projection. It has no SessionStore reference, persistence
/// access, rating commands, file operations, source reads or sorting API.
@MainActor
final class OpeningSessionState: ObservableObject {
    let items: [PhotoItem]
    let isCached: Bool
    let sourceAccess: MediaReadAccess?
    private let indexByID: [String: Int]
    private var readyItems: [String: PhotoItem] = [:]
    /// Observable without its own publisher: `applyMetadata` sends one
    /// `objectWillChange` per accepted batch, and the store drains batches at
    /// most every 100 ms, so the toolbar count never updates per file.
    private(set) var readyMetadataCount = 0
    @Published private(set) var currentIndex: Int
    @Published private(set) var selectedIDs: Set<String> = []
    @Published var viewMode: ViewMode
    @Published private(set) var keyboardNavigationGeneration: UInt64 = 0
    private(set) var gridColumnCount = 1
    private var hasCurrentInteraction = false
    private var viewportReceipts: [OpeningViewportSurface: OpeningViewportReceipt] = [:]
    private var userViewportSurfaces: Set<OpeningViewportSurface> = []

    init(snapshot: OpeningSessionSnapshot, viewMode: ViewMode, sourceAccess: MediaReadAccess?,
         initialPhysicalFileID: String? = nil) {
        items = snapshot.items
        isCached = snapshot.isCached
        indexByID = Dictionary(uniqueKeysWithValues: snapshot.items.enumerated().map { ($0.element.id, $0.offset) })
        currentIndex = initialPhysicalFileID.flatMap { id in
            snapshot.items.firstIndex { $0.individualFiles.contains { $0.id == id } }
        } ?? snapshot.items.firstIndex { $0.rating == .undecided } ?? 0
        readyMetadataCount = snapshot.items.count { $0.primaryFile.metadataIsLoaded }
        // Sized once: growing rehashes the whole table on the main actor
        // (about 100 ms near 100k items) in the middle of a metadata batch.
        readyItems.reserveCapacity(snapshot.items.count - readyMetadataCount)
        self.viewMode = viewMode
        self.sourceAccess = sourceAccess
    }

    var currentItem: PhotoItem? {
        items.indices.contains(currentIndex) ? itemWithReadyMetadata(items[currentIndex]) : nil
    }

    func itemWithReadyMetadata(_ item: PhotoItem) -> PhotoItem { readyItems[item.id] ?? item }

    func metadataIsReady(for itemID: String) -> Bool {
        guard let index = indexByID[itemID] else { return false }
        return readyItems[itemID] != nil || items[index].primaryFile.metadataIsLoaded
    }

    /// Immutable inventory keeps the native collection's geometry/selection
    /// stable. Only an observation overlay changes; it cannot grant save access.
    @discardableResult
    func applyMetadata(_ updates: [OpeningMetadataUpdate]) -> Int {
        var accepted = 0
        for update in updates {
            let ready = update.item
            guard ready.primaryFile.metadataIsLoaded,
                  readyItems[ready.id] == nil, let index = indexByID[ready.id],
                  !items[index].primaryFile.metadataIsLoaded else { continue }
            let original = items[index]
            guard ready.contentRevision == original.contentRevision,
                  ready.individualFiles.map(\.id) == original.individualFiles.map(\.id),
                  ready.individualFiles.map(\.scannedIdentity) == original.individualFiles.map(\.scannedIdentity),
                  ready.individualFiles.map({ FolderScanner.fileSystemIdentityPath(for: $0.url) })
                    == original.individualFiles.map({ FolderScanner.fileSystemIdentityPath(for: $0.url) }),
                  ready.metadataSnapshots == original.metadataSnapshots else { continue }
            if accepted == 0 { objectWillChange.send() }
            readyItems[ready.id] = ready
            accepted += 1
        }
        readyMetadataCount += accepted
        return accepted
    }

    func select(_ id: String, extending: Bool = false, toggling: Bool = false) {
        guard let index = indexByID[id] else { return }
        hasCurrentInteraction = true
        if extending {
            // Ready ranges from current and leaves it as the anchor, including
            // the initial implicit selection and repeated Shift-clicks.
            selectedIDs = Set(items[min(currentIndex, index)...max(currentIndex, index)].map(\.id))
        } else if toggling {
            let currentID = items[currentIndex].id
            var updated = selectedIDs.isEmpty ? [currentID] : selectedIDs
            if updated.contains(id), updated.count > 1 {
                updated.remove(id)
            } else {
                updated.insert(id)
            }
            selectedIDs = updated == [currentID] ? [] : updated
            if !selectedIDs.isEmpty, !selectedIDs.contains(currentID) {
                // Match Ready's surviving-current rule using the existing ID
                // map; a small selection never scans the whole inventory.
                currentIndex = selectedIDs.contains(id) ? index
                    : selectedIDs.compactMap { indexByID[$0] }.min() ?? currentIndex
            }
        } else {
            selectedIDs = []
            currentIndex = index
        }
    }

    func moveCurrent(by offset: Int) {
        guard !items.isEmpty else { return }
        select(items[min(max(currentIndex + offset, 0), items.count - 1)].id)
        keyboardNavigationGeneration &+= 1
    }

    /// Moves by one row in Grid and by one item in Gallery.
    func moveVertically(by rows: Int) {
        moveCurrent(by: viewMode == .grid ? rows * gridColumnCount : rows)
    }

    func toggleViewMode() { viewMode = viewMode == .gallery ? .grid : .gallery }

    /// Esc's first stage. Keeps the current photo, like Ready.
    func clearSelection() -> Bool {
        guard !selectedIDs.isEmpty else { return false }
        selectedIDs = []
        return true
    }

    func setGridColumnCount(_ count: Int) { gridColumnCount = max(1, count) }

    /// Scroll traffic stays outside ObservableObject publication.
    func recordViewport(_ receipt: OpeningViewportReceipt, userInitiated: Bool = true) {
        guard indexByID[receipt.physicalFileID] != nil, receipt.topOffset.isFinite else { return }
        viewportReceipts[receipt.surface] = receipt
        if userInitiated { userViewportSurfaces.insert(receipt.surface) }
    }

    func handoff(validatedItems: [PhotoItem]? = nil) -> OpeningSessionHandoff {
        // Provisional paths never transfer intent onto a replacement file.
        let validIDs: Set<String>?
        if let validatedItems {
            let identities = Dictionary(uniqueKeysWithValues: validatedItems.flatMap(\.individualFiles).map { ($0.id, $0.scannedIdentity) })
            validIDs = Set(items.flatMap(\.individualFiles).compactMap { file in
                guard let old = file.scannedIdentity, let fresh = identities[file.id] ?? nil,
                      ArchiveMetadataIndex.cachedIdentity(old, matches: fresh) else { return nil }
                return file.id
            })
        } else { validIDs = nil }
        func accepts(_ id: String) -> Bool { validIDs?.contains(id) ?? true }
        let current = hasCurrentInteraction ? currentItem?.primaryFile.id : nil
        return OpeningSessionHandoff(
            currentPhysicalFileID: current.flatMap { accepts($0) ? $0 : nil },
            selectedPhysicalFileIDs: Set(selectedIDs.compactMap { indexByID[$0] }.flatMap { items[$0].individualFiles.map(\.id) }.filter(accepts)),
            viewMode: viewMode,
            viewportReceipts: viewportReceipts.filter {
                accepts($0.value.physicalFileID) && (hasCurrentInteraction || userViewportSurfaces.contains($0.key))
            }
        )
    }
}
