import SwiftUI

/// One locale and layout rule shared by the main window, Help, and Settings.
/// Media timelines and shortcut glyphs retain explicit left-to-right ordering.
struct LocalizedInterfaceModifier: ViewModifier {
    var language: String = L10n.language

    func body(content: Content) -> some View {
        content
            .environment(\.locale, Locale(identifier: language))
            .environment(\.layoutDirection, language == "ar" ? .rightToLeft : .leftToRight)
    }
}

extension View {
    func localizedInterface(language: String = L10n.language) -> some View {
        modifier(LocalizedInterfaceModifier(language: language))
    }
}
