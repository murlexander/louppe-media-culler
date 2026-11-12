import SwiftUI

/// The fixed action row of a `SheetForm`: optional leading items (Back, Undo,
/// Show in Finder, a planning indicator), then the trailing Cancel and primary
/// buttons. Escape belongs to Cancel when the step shows one; otherwise it
/// belongs to Back (Export review steps). Callers retain disabled gates and
/// explicitly assign Back's cancel shortcut when no Cancel is present.
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
    let action: () -> Void

    init(_ title: String = L10n.text("Cancel"), action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, role: .cancel, action: action)
            .keyboardShortcut(.cancelAction)
    }
}

/// A prominent trailing action. Callers explicitly choose whether Return runs
/// it; an acknowledgment gate alone must never imply a default action.
struct SheetPrimaryButton: View {
    let title: String
    let runsOnReturn: Bool
    let action: () -> Void

    init(
        _ title: String,
        runsOnReturn: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.runsOnReturn = runsOnReturn
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(runsOnReturn ? .defaultAction : nil)
            .buttonStyle(.borderedProminent)
            .tint(Color.louppeFilledAccent)
    }
}
