import SwiftUI

/// The fixed action row of a `SheetForm`: optional leading items (Back, Undo,
/// Show in Finder, a planning indicator), then the trailing Cancel and primary
/// buttons. Callers retain their roles, keyboard shortcuts and disabled gates.
struct SheetActions<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            leading()
            Spacer()
            trailing()
        }
    }
}

extension SheetActions where Leading == EmptyView {
    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

/// The sheet's Escape button. Its title is Cancel unless the sheet has no
/// pending change to discard (Session recovery's Done).
struct SheetCancelButton: View {
    let title: String
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String = L10n.text("Cancel"), role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(title, role: role, action: action)
            .keyboardShortcut(.cancelAction)
    }
}

/// A prominent trailing action. Callers explicitly choose whether Return runs
/// it; an acknowledgment gate alone must never imply a default action.
struct SheetPrimaryButton: View {
    let title: String
    let role: ButtonRole?
    let isDefault: Bool
    let action: () -> Void

    init(
        _ title: String,
        role: ButtonRole? = nil,
        isDefault: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.isDefault = isDefault
        self.action = action
    }

    var body: some View {
        Button(title, role: role, action: action)
            .keyboardShortcut(isDefault ? .defaultAction : nil)
            .buttonStyle(.borderedProminent)
            .tint(Color.louppeFilledAccent)
    }
}
