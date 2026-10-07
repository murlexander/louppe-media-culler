import SwiftUI

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
        Form {
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
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Color.louppeAccent)
    }
}
#endif

/// Focused native pages keep review choices out of the working toolbar.
struct LouppeSettingsView: View {
    #if !APP_STORE
    let updater: SPUUpdater
    #endif

    var body: some View {
        TabView {
            ReviewPreferencesSettingsView()
                .tabItem {
                    Label(L10n.text("Review"), systemImage: "photo.on.rectangle")
                }

            CameraQualityWarningsSettingsView()
                .tabItem {
                    Label(L10n.text("Quality Cues"), systemImage: "waveform.path.ecg")
                }

            #if !APP_STORE
            if !AppBuildInfo.isReviewBuild {
                UpdaterSettingsView(updater: updater)
                    .tabItem {
                        Label(L10n.text("Updates"), systemImage: "arrow.down.circle")
                    }
            }
            #endif
        }
        .frame(width: 480, height: 420)
        .tint(Color.louppeAccent)
    }
}
