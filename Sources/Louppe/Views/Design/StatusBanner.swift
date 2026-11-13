import SwiftUI

/// A full-width notice above the window content with its own remedies: folder
/// opening errors, interrupted-operation and save warnings, saved-decision
/// recovery and grouped review. 14 × 8-point margins, an opaque
/// `Color.appBackground` fill and a divider below, so the strip reads the same
/// wherever it is inset. Warnings use an orange symbol; set
/// `voiceOverLabel` to replace the message's spoken label, and opt into
/// `focusOnAppear` only when a warning needs immediate attention.
struct StatusBanner<Message: View, Actions: View>: View {
    enum Emphasis {
        case notice
        case warning
    }

    let systemImage: String
    let emphasis: Emphasis
    struct Dismissal {
        let label: String
        let action: () -> Void
    }

    let voiceOverLabel: String?
    let focusOnAppear: Bool
    let dismissal: Dismissal?
    @ViewBuilder var message: () -> Message
    @ViewBuilder var actions: () -> Actions
    @AccessibilityFocusState private var isMessageFocused: Bool

    init(
        systemImage: String,
        emphasis: Emphasis = .notice,
        voiceOverLabel: String? = nil,
        focusOnAppear: Bool = false,
        dismissal: Dismissal? = nil,
        @ViewBuilder message: @escaping () -> Message,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.systemImage = systemImage
        self.emphasis = emphasis
        self.voiceOverLabel = voiceOverLabel
        self.focusOnAppear = focusOnAppear
        self.dismissal = dismissal
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            AdaptiveControlLayout(spacing: 12, separatesGroups: true,
                                  minimumLeadingWidth: 240) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: systemImage)
                        .foregroundStyle(emphasis == .warning ? Color.orange : Color.louppeAccent)
                        .accessibilityHidden(true)
                    accessibleMessage
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let dismissal {
                        Button(action: dismissal.action) {
                            Image(systemName: "xmark")
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(dismissal.label)
                        .accessibilityLabel(dismissal.label)
                    }
                }
                actions()
            }
            .louppeAdaptiveButtonSizing()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            Divider()
        }
        .background(Color.appBackground)
        .accessibilityElement(children: .contain)
    }

    private var accessibleMessage: some View {
        labeledMessage
            .accessibilityFocused($isMessageFocused)
            .onAppear {
                if focusOnAppear { isMessageFocused = true }
            }
    }

    @ViewBuilder
    private var labeledMessage: some View {
        let content = message()
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        if let voiceOverLabel {
            content.accessibilityLabel(voiceOverLabel)
        } else {
            content
        }
    }
}

extension StatusBanner where Actions == EmptyView {
    init(
        systemImage: String,
        emphasis: Emphasis = .notice,
        voiceOverLabel: String? = nil,
        focusOnAppear: Bool = false,
        dismissal: Dismissal? = nil,
        @ViewBuilder message: @escaping () -> Message
    ) {
        self.init(
            systemImage: systemImage,
            emphasis: emphasis,
            voiceOverLabel: voiceOverLabel,
            focusOnAppear: focusOnAppear,
            dismissal: dismissal,
            message: message,
            actions: { EmptyView() }
        )
    }
}
