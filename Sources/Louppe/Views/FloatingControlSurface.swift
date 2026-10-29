import SwiftUI

/// One adaptive surface for controls floating above photo or video content.
/// Input remains owned by the native buttons and sliders inside the surface.
struct FloatingControlSurface<Surface: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shape: Surface
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.appBackground, in: shape)
                .overlay { border }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay { border }
        }
    }

    private var border: some View {
        shape.strokeBorder(
            Color.primary.opacity(contrast == .increased ? 1 : 0.25),
            lineWidth: contrast == .increased ? 2 : 1
        )
        .allowsHitTesting(false)
    }
}
