import SwiftUI

extension View {
    /// Apply to every popover's content. The system thick material fills the
    /// arrow and body alike, stays legible over bright photos, and turns opaque
    /// with Reduce Transparency; `Color.appBackground` would leave the arrow as
    /// lighter glass.
    func louppePopoverSurface() -> some View {
        presentationBackground(.thickMaterial)
            .tint(Color.louppeAccent)
    }
}
