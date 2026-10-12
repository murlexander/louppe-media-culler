import SwiftUI
import AppKit

#if !APP_STORE
import Combine
import Sparkle

/// Publishes Sparkle's KVO state so the application-menu command is disabled
/// while another check is already running.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}

/// Sparkle owns the update window and download/install flow. Louppe only
/// supplies a native menu command and keeps it out of the way of active file
/// operations. Automatic installation is also stopped by the app delegate's
/// termination guard while an operation is running.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    let isFileOperationRunning: Bool

    init(updater: SPUUpdater, isFileOperationRunning: Bool) {
        self.updater = updater
        self.isFileOperationRunning = isFileOperationRunning
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(L10n.text("Check for Updates…"), action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates || isFileOperationRunning)
    }
}

/// Sparkle persists these choices in Louppe's existing defaults domain. The
/// state is only written when the photographer changes a toggle, preserving
/// both Sparkle's defaults and any earlier preference.
struct UpdaterSettingsView: View {
    private let updater: SPUUpdater
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecksForUpdates = State(
            initialValue: updater.automaticallyChecksForUpdates)
        _automaticallyDownloadsUpdates = State(
            initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        Group {
            Toggle(L10n.text("Automatically check for updates"), isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                    if !newValue {
                        automaticallyDownloadsUpdates = false
                        updater.automaticallyDownloadsUpdates = false
                    }
                }

            Toggle(L10n.text("Automatically download and install updates"),
                   isOn: $automaticallyDownloadsUpdates)
                .disabled(!automaticallyChecksForUpdates)
                .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                    updater.automaticallyDownloadsUpdates = newValue
                }
        }
        .tint(Color.louppeAccent)
    }
}
#endif

/// One scrolling home for preferences, onboarding, updates, and support.
struct LouppeSettingsView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    #if !APP_STORE
    let updater: SPUUpdater
    #endif

    var body: some View {
        LouppeSettingsForm {
            ReviewPreferencesSettingsView()
            CameraQualityWarningsSettingsView()

            Section {
                DisclosureGroup(L10n.text("Get started")) {
                    LouppeQuickStartContent()
                }
                Button(L10n.text("Keyboard shortcuts")) {
                    openWindow(id: LouppeHelpWindow.id)
                }
            }

            Section {
                LabeledContent(L10n.text("Version"), value: AppBuildInfo.versionDescription)
                #if APP_STORE
                Button(L10n.text("Open App Store")) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text(L10n.text("Updates are managed by the App Store."))
                    .foregroundStyle(.secondary)
                #else
                if AppBuildInfo.isReviewBuild {
                    Text(L10n.text("Updates are disabled in this review build."))
                        .foregroundStyle(.secondary)
                } else {
                    CheckForUpdatesView(updater: updater, isFileOperationRunning: store.isFileOperationRunning)
                    UpdaterSettingsView(updater: updater)
                }
                #endif
                Link(L10n.text("Version History"), destination: AppBuildInfo.releaseHistoryURL)
                    .foregroundStyle(Color.louppeAccent)
            } header: {
                Text(L10n.text("Updates"))
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    #if APP_STORE
                    Button(L10n.text("Support Louppe…")) {
                        openWindow(id: TipView.windowID)
                    }
                    #else
                    Link(L10n.text("Support Louppe…"), destination: AppBuildInfo.directTipURL)
                        .foregroundStyle(Color.louppeAccent)
                    #endif
                    Text(L10n.text("Louppe is always free and open source. Tips are optional."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    Link(L10n.text("Source code"), destination: AppBuildInfo.sourceCodeURL)
                    Link(L10n.text("Contact Alex"), destination: URL(string: "mailto:a@alex-markin.com")!)
                    Link(L10n.text("Privacy Policy"), destination: AppBuildInfo.privacyPolicyURL)
                }
                .font(.callout)
                .foregroundStyle(Color.louppeAccent)
            } header: {
                Text(L10n.text("Support Louppe"))
            }
        }
        .frame(width: 520, height: 600)
        .tint(Color.louppeAccent)
    }
}
