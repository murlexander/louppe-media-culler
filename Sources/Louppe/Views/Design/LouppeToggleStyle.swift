import SwiftUI

/// Keep the native toggle presentation and behavior while using a fill that
/// contrasts with its white checkmark or switch thumb.
struct LouppeToggleStyle: ToggleStyle {
    enum Kind { case automatic, checkbox, switchControl }
    let kind: Kind
    init(_ kind: Kind = .automatic) { self.kind = kind }

    func makeBody(configuration: Configuration) -> some View {
        Group {
            switch kind {
            case .automatic: Toggle(configuration).toggleStyle(.automatic)
            case .checkbox: Toggle(configuration).toggleStyle(.checkbox)
            case .switchControl: Toggle(configuration).toggleStyle(.switch)
            }
        }
        .tint(Color.louppeFilledAccent)
    }
}
