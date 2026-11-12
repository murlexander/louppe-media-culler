import SwiftUI

/// One adaptive surface for controls floating above photo or video content.
/// Input remains owned by the native buttons and sliders inside the surface.
/// `.panel` is for passive status floating over the window (recovery, folder
/// drop): it keeps regular material instead of interactive glass but shares the
/// Reduce Transparency and Increase Contrast fallbacks.
struct FloatingControlSurface<Surface: InsettableShape>: ViewModifier {
    enum Role {
        case controls
        case panel
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let shape: Surface
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast
    var role: Role = .controls

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.appBackground, in: shape)
                .overlay { border }
        } else if role == .controls, #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: shape)
                .overlay {
                    if contrast == .increased { border }
                }
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay {
                    if role == .controls || contrast == .increased { border }
                }
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
