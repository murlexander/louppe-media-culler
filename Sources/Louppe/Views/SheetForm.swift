import SwiftUI

enum SheetFormLayout: Equatable {
    case scrolling
    case grouped
}

/// Keeps lengthy setup and review text scrollable without moving the actions.
/// Shared header, margins, and native control sizing for operation sheets.
struct SheetForm<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    let layout: SheetFormLayout
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    init(
        title: String,
        subtitle: String? = nil,
        layout: SheetFormLayout = .scrolling,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.layout = layout
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)
            Divider()
            if layout == .grouped {
                LouppeSettingsForm {
                    content()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Divider()
            actions()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
        .controlSize(.regular)
    }
}
