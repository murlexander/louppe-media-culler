import SwiftUI
import AppKit

/// One campaign shared by every 1.10 patch, stored only in app preferences.
enum EarlyUserFeedback {
    static let shownKey = "earlyUserFeedback1_10Shown"
    static let emailURL = URL(string: "mailto:a@alex-markin.com")!

    static func shouldPresent(version: String, hasBeenShown: Bool) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return !hasBeenShown && components.count >= 2
            && components[0] == "1" && components[1] == "10"
    }
}

struct EarlyUserFeedbackView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("You’re one of Louppe’s first users <3"))
                .font(.headline)
            Text(L10n.text("I don’t collect usage data. Tell me how you found Louppe, how you use it, and what to improve."))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button(L10n.text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Email me")) {
                    if NSWorkspace.shared.open(EarlyUserFeedback.emailURL) {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
    }
}
