import SwiftUI

/// Shared native configuration presentation for Settings and setup sheets.
/// The Form is the only scrolling owner; its controls adapt to current macOS.
struct LouppeSettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .controlSize(.regular)
            .scrollContentBackground(.hidden)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.appBackground)
            .tint(Color.louppeAccent)
    }
}
