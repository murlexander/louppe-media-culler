import SwiftUI

/// One grouped, scrolling form owns settings margins and native control sizing.
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
    }
}
