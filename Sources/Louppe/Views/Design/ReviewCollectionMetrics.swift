import CoreGraphics

/// Browser and Grid geometry for Ready and opening collections. Rendered
/// layout, arrow-key columns and measurement all read these values, so the
/// columns a user sees and the columns arrows move through cannot diverge.
enum ReviewCollectionMetrics {
    /// Browser thumbnails are square; tiles without a proposal use this too.
    static let browserTileSize: CGFloat = 102
    static let browserHorizontalInset: CGFloat = 10
    /// The original padded thumbnail column, excluding the scrollbar gutter.
    static let browserColumnWidth = browserTileSize + 2 * browserHorizontalInset
    /// The column plus exactly enough room for a native non-overlay scrollbar.
    @MainActor
    static let browserWidth = browserColumnWidth + PersistentVerticalScroller.gutterWidth
    static let browserSpacing: CGFloat = 6
    static let browserTopPadding: CGFloat = 10

    static let gridSpacing: CGFloat = 10
    static let gridTopPadding: CGFloat = 12
    static let gridLeadingInset: CGFloat = 12
    static let gridTrailingInset: CGFloat = 6
    /// Tiles may grow this much past the chosen size to fill a row.
    static let gridMaximumTileGrowth: CGFloat = 1.4
    /// Between a Grid tile's media square and its filename caption.
    static let captionSpacing: CGFloat = 3

    /// The leading edge of Grid content in physical coordinates.
    static func gridLeadingOrigin(rightToLeft: Bool) -> CGFloat {
        rightToLeft ? gridTrailingInset : gridLeadingInset
    }

    /// Width available to Grid tiles inside the scroll view's clip.
    static func gridAvailableWidth(clipWidth: CGFloat) -> CGFloat {
        max(1, clipWidth - gridLeadingInset - gridTrailingInset)
    }

    /// The rendered column count for a clip width (pane minus gutter).
    static func gridColumnCount(clipWidth: CGFloat, thumbnailSize: CGFloat) -> Int {
        let available = gridAvailableWidth(clipWidth: clipWidth)
        return max(1, Int((available + gridSpacing) / (max(1, thumbnailSize) + gridSpacing)))
    }

    /// Arrow-key columns from the pane width a GeometryReader reports. The
    /// persistent legacy scroller owns a real gutter inside that width.
    @MainActor
    static func gridColumnCount(
        paneWidth: CGFloat, thumbnailSize: CGFloat,
        gutterWidth: CGFloat = PersistentVerticalScroller.gutterWidth
    ) -> Int {
        gridColumnCount(clipWidth: max(1, paneWidth - gutterWidth), thumbnailSize: thumbnailSize)
    }
}
