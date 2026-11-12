import SwiftUI

extension View {
    /// Apply to every popover's content. The system thick material fills the
    /// arrow and body alike, stays legible over bright photos, and turns opaque
    /// with Reduce Transparency; `Color.appBackground` would leave the arrow as
    /// lighter glass.
    func louppePopoverSurface() -> some View {
        // A content-sized popover rounds its window to whole points; content of
        // fractional height (a 16.42-point checkbox) then stops short of the
        // arrow and the material leaves it as lighter glass. Filling the
        // popover keeps one surface without changing its fitted size.
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationBackground(.thickMaterial)
            .tint(Color.louppeAccent)
    }
}
