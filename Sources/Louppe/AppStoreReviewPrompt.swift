#if APP_STORE
import AppKit
import StoreKit

@MainActor
final class AppStoreReviewPrompt {
    enum Keys {
        static let version = "louppe.appStoreReview.version"
        static let successfulCopies = "louppe.appStoreReview.successfulCopies"
        static let successfulCopyDays = "louppe.appStoreReview.successfulCopyDays"
        static let lastRequestedVersion = "louppe.appStoreReview.lastRequestedVersion"
    }

    private let defaults: UserDefaults
    private var pending = false
    private var requestTask: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var policy: ReviewPromptPolicy {
        ReviewPromptPolicy(
            version: defaults.string(forKey: Keys.version) ?? "",
            successfulCopies: min(max(defaults.integer(forKey: Keys.successfulCopies), 0), 3),
            successfulCopyDays: Array((defaults.array(forKey: Keys.successfulCopyDays) as? [Date] ?? []).prefix(2)),
            lastRequestedVersion: defaults.string(forKey: Keys.lastRequestedVersion)
        )
    }

    /// Called once for a worker-confirmed finished result, including routing
    /// and Photos Copy. Failed/empty/stopped results never advance progress.
    func recordCompletion(_ outcome: ExportManager.Outcome, version: String, date: Date = .now) {
        requestTask?.cancel()
        var progress = policy
        pending = progress.record(outcome, version: version, date: date)
        defaults.set(progress.version, forKey: Keys.version)
        defaults.set(progress.successfulCopies, forKey: Keys.successfulCopies)
        defaults.set(progress.successfulCopyDays, forKey: Keys.successfulCopyDays)
    }

    /// Dismissing Export leaves its completion UI untouched. Try once after
    /// the sheet settles; if anything else needs attention, wait for a future
    /// successful Copy instead of presenting an unrelated prompt later.
    func exportDidDismiss(store: SessionStore) {
        guard pending else { return }
        pending = false
        requestTask?.cancel()
        let sourceFolder = store.sourceFolder
        guard NSApp.isActive, let window = NSApp.mainWindow else { return }
        requestTask = Task { @MainActor [weak self, weak store, weak window] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, let store, let window,
                  case .ready = store.phase,
                  store.sourceFolder == sourceFolder,
                  !store.isNewFileOperationBlocked,
                  !store.isSessionCommandPresentationActive,
                  NSApp.isActive, NSApp.mainWindow === window, NSApp.keyWindow === window,
                  NSApp.modalWindow == nil,
                  !NSApp.windows.contains(where: { $0.attachedSheet != nil || ($0.isVisible && $0.isSheet) }),
                  let controller = window.contentViewController,
                  let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  self.policy.isEligible(version: version) else { return }
            // Persist before requesting, even if Apple suppresses its UI.
            self.defaults.set(version, forKey: Keys.lastRequestedVersion)
            // The selected SDK exposes the NSViewController API from macOS 13;
            // Louppe's macOS 14 minimum needs no deprecated fallback.
            AppStore.requestReview(in: controller)
        }
    }
}
#endif
