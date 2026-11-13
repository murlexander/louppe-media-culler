import SwiftUI

/// Keeps native controls at their ideal width, stacking when a row cannot fit.
/// The same children stay mounted during resize, preserving focus and shortcuts.
struct AdaptiveControlLayout: Layout {
    var spacing: CGFloat = 12
    var separatesGroups = false
    /// A banner message can wrap; its full single-line width must not force stacking.
    var minimumLeadingWidth: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, frame) in result.frames {
            // SwiftUI mirrors layout coordinates automatically in RTL.
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.midX,
                                             y: bounds.minY + frame.midY),
                                  anchor: .center, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [(Int, CGRect)]) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let indices = ideals.indices.filter { ideals[$0].width > 0 || ideals[$0].height > 0 }
        guard !indices.isEmpty else { return (.zero, []) }
        let gaps = spacing * CGFloat(indices.count - 1)
        let naturalWidth = indices.reduce(gaps) { $0 + ideals[$1].width }
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? naturalWidth
        var requiredWidth = naturalWidth
        if let minimumLeadingWidth, indices.contains(0) {
            requiredWidth -= max(0, ideals[0].width - minimumLeadingWidth)
        }
        let stacked = requiredWidth > width && indices.count > 1
        var sizes = ideals
        for index in indices {
            var offered = min(width, ideals[index].width)
            if !stacked, index == 0, minimumLeadingWidth != nil {
                offered = max(0, width - gaps - indices.filter { $0 != 0 }.reduce(0) { $0 + ideals[$1].width })
            }
            sizes[index] = subviews[index].sizeThatFits(ProposedViewSize(width: offered, height: nil))
        }
        let height = stacked
            ? indices.reduce(gaps) { $0 + sizes[$1].height }
            : indices.map { sizes[$0].height }.max() ?? 0
        let occupiedWidth = indices.reduce(0) { $0 + sizes[$1].width }
        let rowGap = separatesGroups && indices.count > 1
            ? max(spacing, (width - occupiedWidth) / CGFloat(indices.count - 1)) : spacing
        var x = separatesGroups && indices.contains(0) ? 0 : max(0, width - occupiedWidth - gaps)
        var y: CGFloat = 0
        var frames: [(Int, CGRect)] = []
        for index in indices {
            let size = sizes[index]
            if stacked {
                x = separatesGroups && index == 0 ? 0 : max(0, width - size.width)
            } else {
                y = (height - size.height) / 2
            }
            frames.append((index, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            if stacked { y += size.height + spacing } else { x += size.width + rowGap }
        }
        return (CGSize(width: width, height: height), frames)
    }
}
