import Foundation

enum AppBuildInfo {
    static let sourceCodeURL = URL(string: "https://github.com/murlexander/louppe-media-culler")!
    static let userGuideURL = sourceCodeURL.appendingPathComponent("blob/main/Docs/USER_GUIDE.md")
    static let releaseHistoryURL = sourceCodeURL.appendingPathComponent("releases")
    static let privacyPolicyURL = URL(string: "https://louppe.eu/privacy/")!
    #if !APP_STORE
    static let directTipURL = URL(string: "https://revolut.me/murlexander")!
    #endif

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    static var isReviewBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "LouppeReviewBuild") as? Bool == true
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Louppe"
    }
}
