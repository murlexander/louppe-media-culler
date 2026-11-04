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

/// Native macOS settings pages, with one scrolling form per page.
struct LouppeSettingsView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    #if !APP_STORE
    let updater: SPUUpdater
    #endif

    @State private var selectedPage: SettingsPage = .general

    var body: some View {
        pages
            .frame(width: 620, height: 600)
            .tint(Color.louppeAccent)
            .toggleStyle(LouppeToggleStyle())
            .navigationTitle(selectedPage.title)
    }

    @ViewBuilder
    private var pages: some View {
        if #available(macOS 15.0, *) {
            TabView(selection: $selectedPage) {
                Tab(L10n.text("General"), systemImage: "gearshape", value: SettingsPage.general) {
                    generalSettings
                }
                Tab(L10n.text("Keyboard shortcuts"), systemImage: "keyboard", value: SettingsPage.shortcuts) {
                    shortcutSettings
                }
            }
        } else {
            TabView(selection: $selectedPage) {
                generalSettings
                    .tabItem { Label(L10n.text("General"), systemImage: "gearshape") }
                    .tag(SettingsPage.general)
                shortcutSettings
                    .tabItem { Label(L10n.text("Keyboard shortcuts"), systemImage: "keyboard") }
                    .tag(SettingsPage.shortcuts)
            }
        }
    }

    private var shortcutSettings: some View {
        LouppeSettingsForm {
            ReviewShortcutsSettingsView()
        }
        .accessibilityIdentifier("louppe.settings.shortcuts")
    }

    private var generalSettings: some View {
        LouppeSettingsForm {
            ReviewPreferencesSettingsView()

            Section {
                Toggle(L10n.text("Allow iCloud Review Images"), isOn: $store.photosReviewNetwork)
                Toggle(L10n.text("Allow iCloud Originals"), isOn: $store.photosOriginalNetwork)
            } header: {
                Text(L10n.text("iCloud Access"))
            } footer: {
                Text(L10n.text("Review images load as you browse. Photos may fetch source data to render a preview. Originals stream only when you request original detail, playback, or Copy. Each choice is remembered independently."))
                    .fixedSize(horizontal: false, vertical: true)
            }

            CameraQualityWarningsSettingsView()

            Section {
                HStack {
                    Text(L10n.text("Burst interval"))
                    Spacer()
                    CaptureBurstIntervalField(store: store)
                    Text(L10n.text("s"))
                        .foregroundStyle(.secondary)
                }
                .help(L10n.text("0.5–10 seconds between photos. Separate shutter presses or cameras may be grouped together."))
            } header: {
                Text(L10n.text("Capture bursts"))
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

            LouppeGetStartedSettingsView { id in
                openWindow(id: id)
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
                HStack(spacing: 0) {
                    Link(L10n.text("Source code"), destination: AppBuildInfo.sourceCodeURL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Link(L10n.text("Contact Alex"), destination: URL(string: "mailto:a@alex-markin.com")!)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Link(L10n.text("Privacy Policy"), destination: AppBuildInfo.privacyPolicyURL)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.callout)
                .foregroundStyle(Color.louppeAccent)
            } header: {
                Text(L10n.text("Louppe info"))
            }
        }
        .accessibilityIdentifier("louppe.settings.general")
    }
}

private enum SettingsPage: Hashable {
    case general, shortcuts

    var title: String {
        switch self {
        case .general: L10n.text("General")
        case .shortcuts: L10n.text("Keyboard shortcuts")
        }
    }
}

/// Keep the guide in Help while its review preference stays in Settings.
struct LouppeGetStartedSettingsView: View {
    let openWindow: (String) -> Void
    @AppStorage("louppe.showQuickStart") private var showQuickStart = true

    var body: some View {
        Section {
            Button(L10n.text("Get started")) {
                openWindow(LouppeHelpWindow.id)
            }
            .buttonStyle(.link)
            .foregroundStyle(Color.louppeAccent)
            .accessibilityIdentifier("louppe.settings.getStarted")
            Toggle(L10n.text("Show quick-start tips while reviewing"), isOn: $showQuickStart)
                .accessibilityIdentifier("louppe.settings.quickStartTips")
        } header: {
            Text(L10n.text("Louppe Help"))
        }
    }
}

/// Keep incomplete edits local so clamping cannot rewrite a number mid-entry.
private struct CaptureBurstIntervalField: View {
    @ObservedObject var store: SessionStore
    @Environment(\.locale) private var locale
    @FocusState private var isFocused: Bool
    @State private var draft = ""

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 76)
            .focused($isFocused)
            .accessibilityLabel(L10n.text("Capture burst interval"))
            .onAppear { refreshDraft() }
            .onSubmit { commit() }
            .onDisappear { commit() }
            .onExitCommand { refreshDraft() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: store.burstGroupingInterval) { _, _ in
                if !isFocused { refreshDraft() }
            }
            .onChange(of: locale) { _, _ in
                if !isFocused { refreshDraft() }
            }
    }

    private func commit() {
        if let value = CaptureBurstIntervalInput.parse(draft, locale: locale) {
            store.setBurstGroupingInterval(value)
        }
        refreshDraft()
    }

    private func refreshDraft() {
        draft = CaptureBurstIntervalInput.format(store.burstGroupingInterval, locale: locale)
    }
}
