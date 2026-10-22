import Foundation
import Combine

struct OpeningSessionSnapshot: Sendable {
    /// Complete globally paired inventory, with identity-validated saved badges.
    /// No metadata completion ever mutates this projection or its ordering.
    let items: [PhotoItem]
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
/// access, rating commands, file operations, metadata refresh or sorting API.
@MainActor
final class OpeningSessionState: ObservableObject {
    let items: [PhotoItem]
    let sourceAccess: MediaReadAccess?
    private let indexByID: [String: Int]
    @Published private(set) var currentIndex: Int
    @Published private(set) var selectedIDs: Set<String> = []
    @Published var viewMode: ViewMode
    @Published private(set) var keyboardNavigationGeneration: UInt64 = 0
    private(set) var gridColumnCount = 1
    private var selectionAnchor: Int?
    private var hasCurrentInteraction = false
    private var viewportReceipts: [OpeningViewportSurface: OpeningViewportReceipt] = [:]
    private var userViewportSurfaces: Set<OpeningViewportSurface> = []

    init(snapshot: OpeningSessionSnapshot, viewMode: ViewMode, sourceAccess: MediaReadAccess?) {
        items = snapshot.items
        indexByID = Dictionary(uniqueKeysWithValues: snapshot.items.enumerated().map { ($0.element.id, $0.offset) })
        currentIndex = snapshot.items.firstIndex { $0.rating == .undecided } ?? 0
        self.viewMode = viewMode
        self.sourceAccess = sourceAccess
    }

    var currentItem: PhotoItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }

    func select(_ id: String, extending: Bool = false, toggling: Bool = false) {
        guard let index = indexByID[id] else { return }
        hasCurrentInteraction = true
        if extending, let anchor = selectionAnchor {
            selectedIDs = Set(items[min(anchor, index)...max(anchor, index)].map(\.id))
        } else if toggling {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
            selectionAnchor = index
        } else {
            selectedIDs = [id]
            selectionAnchor = index
        }
        if selectedIDs.isEmpty || selectedIDs.contains(id) {
            currentIndex = index
        } else if let first = items.indices.first(where: { selectedIDs.contains(items[$0].id) }) {
            currentIndex = first
        }
    }

    func moveCurrent(by offset: Int) {
        guard !items.isEmpty else { return }
        select(items[min(max(currentIndex + offset, 0), items.count - 1)].id)
        keyboardNavigationGeneration &+= 1
    }

    func setGridColumnCount(_ count: Int) { gridColumnCount = max(1, count) }

    /// Scroll traffic stays outside ObservableObject publication.
    func recordViewport(_ receipt: OpeningViewportReceipt, userInitiated: Bool = true) {
        guard indexByID[receipt.physicalFileID] != nil, receipt.topOffset.isFinite else { return }
        viewportReceipts[receipt.surface] = receipt
        if userInitiated { userViewportSurfaces.insert(receipt.surface) }
    }

    func handoff() -> OpeningSessionHandoff {
        OpeningSessionHandoff(
            currentPhysicalFileID: hasCurrentInteraction ? currentItem?.primaryFile.id : nil,
            selectedPhysicalFileIDs: Set(selectedIDs.compactMap { indexByID[$0] }.flatMap { items[$0].individualFiles.map(\.id) }),
            viewMode: viewMode,
            viewportReceipts: viewportReceipts.filter { hasCurrentInteraction || userViewportSurfaces.contains($0.key) }
        )
    }
}
