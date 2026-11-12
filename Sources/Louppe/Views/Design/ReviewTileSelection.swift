import SwiftUI

/// Media corner radius shared by Browser, Grid and opening tiles.
enum ReviewTileMetrics {
    static let mediaCornerRadius: CGFloat = 6
    static let selectionLineWidth: CGFloat = 3
}

/// The current/selected outline around a tile's fitted media, used by Ready
/// and opening tiles. Increase Contrast and Differentiate Without Color make a
/// selected (not current) outline opaque; the latter also dashes it.
struct ReviewTileSelectionOutline: ViewModifier {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast
    let isCurrent: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: ReviewTileMetrics.mediaCornerRadius)
                .strokeBorder(color, style: StrokeStyle(
                    lineWidth: ReviewTileMetrics.selectionLineWidth,
                    dash: differentiateWithoutColor && isSelected && !isCurrent ? [4, 3] : []
                ))
        }
    }

    private var color: Color {
        if isCurrent { return .louppeAccent }
        if isSelected { return .louppeAccent.opacity(contrast == .increased || differentiateWithoutColor ? 1 : 0.45) }
        return .clear
    }
}

extension View {
    func reviewTileSelectionOutline(isCurrent: Bool, isSelected: Bool) -> some View {
        modifier(ReviewTileSelectionOutline(isCurrent: isCurrent, isSelected: isSelected))
    }
}
