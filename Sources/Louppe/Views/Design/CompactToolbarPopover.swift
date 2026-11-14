import SwiftUI

/// Use for compact toolbar configuration popovers. Choices apply at once, so
/// there is no Done button: Esc or a click outside closes it. Reset sits beside
/// the title. Callers own section dividers and scrolling; omit height to fit
/// content, or set it to keep the footer fixed.
struct CompactToolbarPopover<Content: View, Footer: View>: View {
    let title: String
    let height: CGFloat?
    let done: () -> Void
    let reset: (() -> Void)?
    let canReset: Bool
    let content: Content
    let footer: Footer

    init(
        title: String, height: CGFloat? = nil, done: @escaping () -> Void,
        reset: (() -> Void)? = nil, canReset: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.height = height
        self.done = done
        self.reset = reset
        self.canReset = canReset
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let reset {
                    ShortcutAccessoryButton(symbol: "arrow.counterclockwise", title: L10n.text("Reset"), action: reset)
                        .help(L10n.text("Reset"))
                        .disabled(!canReset)
                }
            }
            content
            if Footer.self != EmptyView.self {
                footer
            }
        }
        // Esc closes even while a field inside has focus.
        .background {
            Button("", action: done)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .toggleStyle(LouppeToggleStyle(.checkbox))
        .padding(14)
        .frame(width: 340, height: height)
        .fixedSize(horizontal: false, vertical: height == nil)
        .louppePopoverSurface()
    }
}
