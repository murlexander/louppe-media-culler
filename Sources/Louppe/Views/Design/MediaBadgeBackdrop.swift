import SwiftUI

/// The dark backdrop behind white badges drawn over media: duration, stars,
/// color labels use `.glyph`, quality cues use `.qualityCue`, and color names
/// use `.text`. Each badge keeps its own shape and ordinary opacity.
enum MediaBadgeBackdropRole {
    case glyph
    case qualityCue
    case text

    var opacity: Double {
        switch self {
        case .glyph: 0.68
        case .qualityCue: 0.72
        case .text: 0.85
        }
    }

    func opacity(increasedContrast: Bool, reduceTransparency: Bool) -> Double {
        if reduceTransparency { return 1 }
        return increasedContrast ? max(opacity, Self.text.opacity) : opacity
    }
}

struct MediaBadgeBackdrop<S: InsettableShape>: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let role: MediaBadgeBackdropRole

    func body(content: Content) -> some View {
        content.background(Color.black.opacity(role.opacity(
            increasedContrast: contrast == .increased, reduceTransparency: reduceTransparency
        )), in: shape)
    }
}

extension View {
    func mediaBadgeBackdrop<S: InsettableShape>(
        _ shape: S, role: MediaBadgeBackdropRole = .glyph
    ) -> some View {
        modifier(MediaBadgeBackdrop(shape: shape, role: role))
    }
}
