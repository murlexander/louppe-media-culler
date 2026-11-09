import SwiftUI
import UniformTypeIdentifiers

/// Pure insertion arithmetic for drag-to-reorder lists. A gap is an insertion
/// point: 0 is before the first row and `count` is after the last row.
enum ReorderInsertion {
    /// The upper half of a row inserts before it; the lower half after it.
    static func gap(hoveredRow row: Int, pointerY: CGFloat, rowHeight: CGFloat) -> Int {
        pointerY < rowHeight / 2 ? row : row + 1
    }

    /// The `toOffset` for `Array.move(fromOffsets:toOffset:)` that places the
    /// row at `source` into `gap`, or nil when the drop would change nothing.
    static func moveOffset(from source: Int, toGap gap: Int, count: Int) -> Int? {
        guard (0..<count).contains(source), (0...count).contains(gap),
              gap != source, gap != source + 1 else { return nil }
        return gap
    }
}

/// Drag state for one reorderable list, owned by the list's view.
struct ReorderDragState<ID: Hashable>: Equatable {
    /// Scopes payloads to this list so drags from another window cannot reorder it.
    let token = UUID().uuidString
    var dragged: ID?
    /// The gap the drop will insert into; nil when no indicator shows.
    var gap: Int?
}

extension View {
    /// Makes a list row draggable and shows an accent insertion line over the
    /// separator where the dragged row will land, like native macOS lists.
    func reorderableRow<ID: RawRepresentable & Hashable & Sendable>(
        _ id: ID,
        in ids: [ID],
        state: Binding<ReorderDragState<ID>>,
        isDraggable: Bool = true,
        sectionEdges: VerticalEdge.Set = [],
        move: @escaping @MainActor (_ source: Int, _ toOffset: Int) -> Void
    ) -> some View where ID.RawValue == String {
        modifier(ReorderableRowModifier(
            id: id, ids: ids, state: state, isDraggable: isDraggable,
            sectionEdges: sectionEdges, move: move
        ))
    }
}

private struct ReorderableRowModifier<ID: RawRepresentable & Hashable & Sendable>: ViewModifier
where ID.RawValue == String {
    let id: ID
    let ids: [ID]
    @Binding var state: ReorderDragState<ID>
    let isDraggable: Bool
    /// List ends that meet the section's rounded edge rather than a separator.
    let sectionEdges: VerticalEdge.Set
    let move: @MainActor (Int, Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowHeight: CGFloat = 0

    /// Grouped-form rows sit inside vertical insets with the separator 10.5
    /// points beyond the content. The drop target extends 10 points into those
    /// insets so the pointer never falls between rows, without changing layout.
    private static var rowInset: CGFloat { 10 }
    /// Line offset from the extended edge: centred on the separator, or kept
    /// inside the rounded background where the list meets the section edge.
    private static var separatorOffset: CGFloat { 2 }
    private static var sectionEdgeOffset: CGFloat { -4 }

    private func offset(at edge: VerticalEdge) -> CGFloat {
        let isListEnd = edge == .top ? index == 0 : index == ids.count - 1
        return isListEnd && sectionEdges.contains(edge == .top ? .top : .bottom)
            ? Self.sectionEdgeOffset : Self.separatorOffset
    }

    private var index: Int? { ids.firstIndex(of: id) }

    func body(content: Content) -> some View {
        content
            .padding(.vertical, Self.rowInset)
            .contentShape(Rectangle())
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { rowHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { rowHeight = proxy.size.height }
                }
            }
            // Both neighbouring rows draw the gap, so the line stays whole even
            // if a row clips its overlay at the separator.
            .overlay(alignment: .top) {
                if let index, state.gap == index {
                    ReorderInsertionLine().offset(y: -offset(at: .top))
                }
            }
            .overlay(alignment: .bottom) {
                if let index, state.gap == index + 1 {
                    ReorderInsertionLine().offset(y: offset(at: .bottom))
                }
            }
            .onDrag {
                guard isDraggable else { return NSItemProvider() }
                state.dragged = id
                state.gap = nil
                return NSItemProvider(object: "\(state.token):\(id.rawValue)" as NSString)
            }
            .onDrop(of: [UTType.text], delegate: ReorderRowDropDelegate(
                id: id, ids: ids, rowHeight: rowHeight, state: $state,
                reduceMotion: reduceMotion, move: move
            ))
            .padding(.vertical, -Self.rowInset)
    }
}

/// A 3-point accent line that covers the hairline separator at an insertion gap.
struct ReorderInsertionLine: View {
    var body: some View {
        Capsule()
            .fill(Color.louppeAccent)
            .frame(height: 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ReorderRowDropDelegate<ID: RawRepresentable & Hashable & Sendable>: DropDelegate
where ID.RawValue == String {
    let id: ID
    let ids: [ID]
    let rowHeight: CGFloat
    @Binding var state: ReorderDragState<ID>
    let reduceMotion: Bool
    let move: @MainActor (Int, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        state.dragged != nil && info.hasItemsConforming(to: [UTType.text])
    }

    func dropEntered(info: DropInfo) { updateGap(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateGap(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Another row may already own the gap when exit arrives after its enter.
        guard let index = ids.firstIndex(of: id),
              state.gap == index || state.gap == index + 1 else { return }
        state.gap = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let gap = state.gap
        let expected = state.dragged.map { "\(state.token):\($0.rawValue)" }
        state.gap = nil
        state.dragged = nil
        guard let gap, let expected,
              let provider = info.itemProviders(for: [UTType.text]).first
        else { return false }
        let ids = ids
        let reduceMotion = reduceMotion
        let move = move
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            // The token rejects stale state from a drag that ended elsewhere.
            guard let payload = object as? String, payload == expected else { return }
            Task { @MainActor in
                guard let raw = payload.split(separator: ":", maxSplits: 1).last,
                      let dragged = ID(rawValue: String(raw)),
                      let source = ids.firstIndex(of: dragged),
                      let offset = ReorderInsertion.moveOffset(
                        from: source, toGap: gap, count: ids.count)
                else { return }
                withAnimation(reduceMotion ? nil : .default) { move(source, offset) }
            }
        }
        return true
    }

    private func updateGap(_ info: DropInfo) {
        guard let index = ids.firstIndex(of: id),
              let dragged = state.dragged,
              let source = ids.firstIndex(of: dragged) else { return }
        let gap = ReorderInsertion.gap(
            hoveredRow: index, pointerY: info.location.y, rowHeight: rowHeight)
        // No line where dropping would leave the order unchanged.
        let next = ReorderInsertion.moveOffset(from: source, toGap: gap, count: ids.count) == nil
            ? nil : gap
        if state.gap != next { state.gap = next }
    }
}
