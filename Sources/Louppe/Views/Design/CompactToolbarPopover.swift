import SwiftUI

/// Use for compact toolbar configuration popovers. Callers own section dividers
/// and scrolling; omit height to fit content, or set it to keep the footer fixed.
struct CompactToolbarPopover<Content: View, FooterLeading: View, FooterActions: View>: View {
    let title: String
    let height: CGFloat?
    let done: () -> Void
    let content: Content
    let footerLeading: FooterLeading
    let footerActions: FooterActions

    init(
        title: String, height: CGFloat? = nil, done: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footerLeading: () -> FooterLeading = { EmptyView() },
        @ViewBuilder footerActions: () -> FooterActions = { EmptyView() }
    ) {
        self.title = title
        self.height = height
        self.done = done
        self.content = content()
        self.footerLeading = footerLeading()
        self.footerActions = footerActions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.headline)
            content
            HStack {
                footerLeading
                Spacer()
                footerActions
                Button(L10n.text("Done"), action: done)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .toggleStyle(LouppeToggleStyle(.checkbox))
        .padding(14)
        .frame(width: 340, height: height)
        .fixedSize(horizontal: false, vertical: height == nil)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
    }
}
