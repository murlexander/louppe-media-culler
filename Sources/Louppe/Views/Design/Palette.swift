import SwiftUI
import AppKit

extension Color {
    /// The single background gray used everywhere in the app (Browser, photo
    /// pane, info panel, Grid view) so there's one consistent shade.
    static let appBackground = Color(nsColor: .windowBackgroundColor)

    /// Louppe's brand purple (#9853A6). The one accent color for everything
    /// that isn't a yes/no rating (those stay green/red): selection borders,
    /// the export button, links, toggles, and the app-icon glyph.
    static let louppeAccent = Color(nsColor: .louppeAccentColor)

    /// Native filled controls keep white ink, so their purple must stay dark
    /// even when links and other foreground accents brighten in dark mode.
    static let louppeFilledAccent = Color(nsColor: .louppeFilledAccentColor)
}

extension NSColor {
    static let louppeFilledAccentColor = NSColor(name: "LouppeFilledAccent") { appearance in
        louppeFilledAccentColor(for: appearance.bestMatch(from: [.accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua, .aqua, .darkAqua]) ?? .aqua)
    }

    static func louppeFilledAccentColor(for appearance: NSAppearance.Name) -> NSColor {
        // Dark glass adds a light reflection over its tint; retain extra
        // contrast headroom for the native white labels and symbols.
        louppeAccentColor(for: appearance == .aqua ? .aqua : .accessibilityHighContrastAqua)
    }

    static let louppeAccentColor = NSColor(name: "LouppeAccent") { appearance in
        louppeAccentColor(for: appearance.bestMatch(from: [.accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua, .aqua, .darkAqua]) ?? .aqua)
    }

    static func louppeAccentColor(for appearance: NSAppearance.Name) -> NSColor {
        let color: (CGFloat, CGFloat, CGFloat)
        switch appearance {
        case .darkAqua: color = (0xB9, 0x80, 0xC6)
        case .accessibilityHighContrastAqua: color = (0x79, 0x40, 0x87)
        case .accessibilityHighContrastDarkAqua: color = (0xCE, 0x99, 0xDA)
        default: color = (0x98, 0x53, 0xA6)
        }
        return NSColor(srgbRed: color.0 / 255, green: color.1 / 255, blue: color.2 / 255, alpha: 1)
    }
}

