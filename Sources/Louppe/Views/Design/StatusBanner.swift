import SwiftUI

/// A full-width notice above the window content with its own remedies: folder
/// opening errors, interrupted-operation and save warnings, saved-decision
/// recovery and grouped review. 14 × 8-point margins, an opaque
/// `Color.appBackground` fill and a divider below, so the strip reads the same
/// wherever it is inset. Warnings use an orange symbol; set
/// `accessibilityAnnouncement` to move VoiceOver to a message that needs action.
struct StatusBanner<Message: View, Actions: View>: View {
    enum Emphasis {
        case notice
        case warning
    }

    let systemImage: String
    let emphasis: Emphasis
    /// Spoken for the message when VoiceOver focuses it on appearance.
    let accessibilityAnnouncement: String?
    let dismissLabel: String?
    let dismiss: (() -> Void)?
    @ViewBuilder var message: () -> Message
    @ViewBuilder var actions: () -> Actions
    @AccessibilityFocusState private var isMessageFocused: Bool

    init(
        systemImage: String,
        emphasis: Emphasis = .notice,
        accessibilityAnnouncement: String? = nil,
        dismissLabel: String? = nil,
        dismiss: (() -> Void)? = nil,
        @ViewBuilder message: @escaping () -> Message,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.systemImage = systemImage
        self.emphasis = emphasis
        self.accessibilityAnnouncement = accessibilityAnnouncement
        self.dismissLabel = dismissLabel
        self.dismiss = dismiss
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(emphasis == .warning ? Color.orange : Color.louppeAccent)
                    .accessibilityHidden(true)
                announcedMessage
                Spacer(minLength: 12)
                actions()
                if let dismiss, let dismissLabel {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(dismissLabel)
                    .accessibilityLabel(dismissLabel)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            Divider()
        }
        .background(Color.appBackground)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var announcedMessage: some View {
        let content = message()
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        if let accessibilityAnnouncement {
            content
                .accessibilityLabel(accessibilityAnnouncement)
                .accessibilityFocused($isMessageFocused)
                .onAppear { isMessageFocused = true }
        } else {
            content
        }
    }
}

extension StatusBanner where Actions == EmptyView {
    init(
        systemImage: String,
        emphasis: Emphasis = .notice,
        accessibilityAnnouncement: String? = nil,
        dismissLabel: String? = nil,
        dismiss: (() -> Void)? = nil,
        @ViewBuilder message: @escaping () -> Message
    ) {
        self.init(
            systemImage: systemImage,
            emphasis: emphasis,
            accessibilityAnnouncement: accessibilityAnnouncement,
            dismissLabel: dismissLabel,
            dismiss: dismiss,
            message: message,
            actions: { EmptyView() }
        )
    }
}
