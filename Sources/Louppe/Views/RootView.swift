import SwiftUI
import AppKit

extension Color {
    /// The single background gray used everywhere in the app (Browser, photo
    /// pane, info panel, Grid view) so there's one consistent shade.
    static let appBackground = Color(nsColor: .windowBackgroundColor)

    /// Louppe's brand purple (#9853A6). The one accent color for everything
    /// that isn't a yes/no rating (those stay green/red): selection borders,
    /// the export button, links, toggles, and the app-icon glyph.
    static let louppeAccent = Color(red: 0x98 / 255, green: 0x53 / 255, blue: 0xA6 / 255)
}

/// Top-level switch between the three app phases:
/// welcome screen → scanning progress → the culling session.
struct RootView: View {
    @ObservedObject var store: SessionStore
    @AppStorage(EarlyUserFeedback.shownKey) private var hasShownEarlyUserFeedback = false
    @State private var welcomeContentSize: CGSize = .zero
    @State private var warningHeight: CGFloat = 0
    @State private var availableContentSize: CGSize?

    var body: some View {
        Group {
            switch store.phase {
            case .welcome:
                WelcomeView(
                    store: store,
                    availableScreenWidth: availableContentSize?.width
                        ?? NSScreen.main?.visibleFrame.width ?? 1280,
                    scrollsVertically: MainWindowLayout.welcome.needsVerticalScrolling(
                        measuredWelcome: welcomeContentSize,
                        warningHeight: warningHeight,
                        availableContentSize: availableContentSize
                    )
                )
            case .scanning(let found):
                ScanningView(store: store, found: found)
            case .ready:
                SessionView(store: store)
            }
        }
        .sheet(isPresented: $store.isEarlyUserFeedbackPresented) {
            EarlyUserFeedbackView()
                .onAppear { hasShownEarlyUserFeedback = true }
        }
        .task(id: canPresentEarlyUserFeedback) {
            if canPresentEarlyUserFeedback {
                store.isEarlyUserFeedbackPresented = true
            }
        }
        .accessibilityHidden(store.isRecoveringInterruptedOperations)
        // Tint every standard control (buttons, links, pickers, toggles,
        // progress bars — including sheets and popovers) with the brand purple.
        .tint(Color.louppeAccent)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if store.recoveryNeedsAttention {
                    RecoveryWarningBanner(
                        message: store.recoveryAttentionMessage
                            ?? L10n.text("Some interrupted files are still untouched."),
                        canRetry: store.canRetryInterruptedOperationRecovery,
                        retry: store.retryInterruptedOperationRecovery,
                        keepFilesAsTheyAre: store.keepInterruptedFilesAsTheyAre
                    )
                }
                if let warning = store.persistenceWarning {
                    PersistenceWarningBanner(
                        message: warning,
                        showsRetry: store.canRetryPersistence,
                        retry: store.retryPersistence
                    )
                }
            }
            .accessibilityHidden(store.isRecoveringInterruptedOperations)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: WindowWarningSizeKey.self,
                        value: geometry.size
                    )
                }
            }
        }
        .frame(
            minWidth: minimumContentSize.width,
            minHeight: minimumContentSize.height
        )
        .onPreferenceChange(WelcomeContentSizeKey.self) { welcomeContentSize = $0 }
        .onPreferenceChange(WindowWarningSizeKey.self) { warningHeight = $0.height }
        .overlay {
            if store.isRecoveringInterruptedOperations {
                InterruptedOperationRecoveryOverlay()
            }
        }
        .alert(
            L10n.text("Interrupted operation recovered"),
            isPresented: operationRecoveryReportIsPresented
        ) {
            Button(L10n.text("OK")) {
                store.dismissOperationRecoveryReport()
            }
        } message: {
            Text(recoveryMessage)
        }
        // The same NSWindow survives all three phases. Welcome/Scanning use a
        // compact full-size-content layout; the active session expands and
        // opts out so photos cannot scroll behind the glass toolbar.
        .background(WindowContentLayout(
            layout: windowLayout,
            minimumContentSize: minimumContentSize,
            onAvailableContentSizeChange: { availableContentSize = $0 }
        ))
    }

    private var canPresentEarlyUserFeedback: Bool {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
        guard EarlyUserFeedback.shouldPresent(
            version: version,
            hasBeenShown: hasShownEarlyUserFeedback
        ), !store.isFileOperationRunning,
           !store.isXMPPublicationRunning,
           !store.isSessionCommandPresentationActive else { return false }
        if case .scanning = store.phase { return false }
        return true
    }

    private var windowLayout: MainWindowLayout {
        switch store.phase {
        case .welcome:
            return .welcome
        case .scanning:
            return .scanning
        case .ready:
            return .session
        }
    }

    private var minimumContentSize: CGSize {
        windowLayout.minimumContentSize(
            measuredWelcome: welcomeContentSize,
            warningHeight: warningHeight,
            availableContentSize: availableContentSize
        )
    }

    private var operationRecoveryReportIsPresented: Binding<Bool> {
        Binding(
            get: {
                store.operationRecoveryReportRequiresAcknowledgement
            },
            set: {
                if !$0 { store.dismissOperationRecoveryReport() }
            }
        )
    }

    private var recoveryMessage: String {
        guard let report = store.operationRecoveryReport else { return "" }
        let interruptionPrefix = store.operationRecoveryCause.map {
            $0.hasSuffix(".") ? "\($0) " : "\($0). "
        } ?? ""
        var actions: [String] = []
        if report.preservedCopies > 0 {
            actions.append(report.preservedCopies == 1 ? L10n.text("kept 1 completed copy at the destination") : L10n.text("kept \(report.preservedCopies) completed copies at the destination"))
        }
        if report.preservedMoves > 0 {
            actions.append(report.preservedMoves == 1 ? L10n.text("kept 1 completed Move file at the destination") : L10n.text("kept \(report.preservedMoves) completed Move files at the destination"))
        }
        if report.restoredFiles > 0 {
            actions.append(report.restoredFiles == 1 ? L10n.text("restored 1 original file") : L10n.text("restored \(report.restoredFiles) original files"))
        }
        if report.removedPartialCopies > 0 {
            actions.append(report.removedPartialCopies == 1 ? L10n.text("removed 1 incomplete copy") : L10n.text("removed \(report.removedPartialCopies) incomplete copies"))
        }
        return interruptionPrefix
            + L10n.text("Louppe \(actions.joined(separator: L10n.text(" and "))). No existing file was overwritten.")
    }
}

private struct InterruptedOperationRecoveryOverlay: View {
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(L10n.text("Recovering interrupted files"))
            Text(L10n.text("Making interrupted file operations safe…"))
                .font(.headline)
            Text(L10n.text("Checking files before opening the folder."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
        .accessibilityElement(children: .combine)
        .accessibilityFocused($isAccessibilityFocused)
        .onAppear { isAccessibilityFocused = true }
    }
}

private struct RecoveryWarningBanner: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let keepFilesAsTheyAre: () -> Void
    @AccessibilityFocusState private var isWarningFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(L10n.text("Interrupted operation warning. \(message)"))
                .accessibilityFocused($isWarningFocused)
                .onAppear { isWarningFocused = true }
            Spacer(minLength: 12)
            Button(L10n.text("Keep Files As They Are"), action: keepFilesAsTheyAre)
                .disabled(!canRetry)
            Button(L10n.text("Retry Recovery"), action: retry)
                .disabled(!canRetry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Visible but non-modal: review can continue while a read-only folder uses
/// the backup, and an unsafe save can be retried without dismissing an alert.
private struct PersistenceWarningBanner: View {
    let message: String
    let showsRetry: Bool
    let retry: () -> Void
    @AccessibilityFocusState private var isWarningFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(L10n.text("Session save warning. \(message)"))
                .accessibilityFocused($isWarningFocused)
                .onAppear { isWarningFocused = true }
            Spacer(minLength: 12)
            if showsRetry {
                Button(L10n.text("Retry Saving"), action: retry)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Welcome reports its padded intrinsic content before its outer fill frame.
/// The measurement therefore describes needed space, not the current window.
struct WelcomeContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value.width = max(value.width, next.width)
        value.height = max(value.height, next.height)
    }
}

private struct WindowWarningSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value.width = max(value.width, next.width)
        value.height = max(value.height, next.height)
    }
}

enum MainWindowLayout: Equatable {
    case welcome
    case scanning
    case session

    var usesFullSizeContent: Bool { self != .session }

    var minimumContentSize: CGSize {
        switch self {
        case .welcome:
            return CGSize(width: 456, height: 180)
        case .scanning:
            return CGSize(width: 520, height: 520)
        case .session:
            return CGSize(width: 900, height: 600)
        }
    }

    func minimumContentSize(
        measuredWelcome: CGSize,
        warningHeight: CGFloat,
        availableContentSize: CGSize? = nil
    ) -> CGSize {
        let measured = self == .welcome ? measuredWelcome : .zero
        let requiredHeight = ceil(max(minimumContentSize.height, measured.height)
            + max(0, warningHeight))
        return CGSize(
            width: ceil(max(minimumContentSize.width, measured.width)),
            height: self == .welcome
                ? min(requiredHeight, availableContentSize?.height ?? requiredHeight)
                : requiredHeight
        )
    }

    func needsVerticalScrolling(
        measuredWelcome: CGSize,
        warningHeight: CGFloat,
        availableContentSize: CGSize?
    ) -> Bool {
        guard self == .welcome, let availableContentSize else { return false }
        return ceil(measuredWelcome.height + max(0, warningHeight))
            > availableContentSize.height
    }

    var preferredContentSize: CGSize {
        switch self {
        case .welcome:
            return minimumContentSize
        case .scanning:
            return CGSize(width: 560, height: 560)
        case .session:
            return CGSize(width: 1100, height: 700)
        }
    }
}

/// Keeps the persistent app window's size and content layout in sync with the
/// current SwiftUI phase. Window corner geometry remains entirely system-owned.
struct WindowContentLayout: NSViewRepresentable {
    let layout: MainWindowLayout
    /// Required usable area, excluding the native titlebar and toolbar.
    let minimumContentSize: CGSize
    var onAvailableContentSizeChange: (CGSize) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = Configurator()
        view.windowLayout = layout
        view.minimumContentSize = minimumContentSize
        view.onAvailableContentSizeChange = onAvailableContentSizeChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? Configurator else { return }
        view.windowLayout = layout
        view.minimumContentSize = minimumContentSize
        view.onAvailableContentSizeChange = onAvailableContentSizeChange
        view.apply()
    }

    final class Configurator: NSView {
        var windowLayout = MainWindowLayout.welcome
        var minimumContentSize = MainWindowLayout.welcome.minimumContentSize
        private var appliedLayout: MainWindowLayout?
        var onAvailableContentSizeChange: (CGSize) -> Void = { _ in }
        private var isApplying = false
        private var reportedAvailableContentSize: CGSize?
        private var shouldFitToCurrentScreen = false

        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeScreenNotification, object: nil
            )
            NotificationCenter.default.removeObserver(
                self, name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(screenChanged),
                    name: NSWindow.didChangeScreenNotification, object: window
                )
                // Resolution, scaling, and display arrangement can change
                // while this window remains on the same NSScreen instance.
                NotificationCenter.default.addObserver(
                    self, selector: #selector(screenChanged),
                    name: NSApplication.didChangeScreenParametersNotification, object: nil
                )
            }
            apply()
            // SwiftUI may install the native toolbar after attaching this
            // bridge. Recheck once then; later layout passes track its inset.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func layout() {
            super.layout()
            apply()
        }

        @objc private func screenChanged() {
            shouldFitToCurrentScreen = true
            apply()
        }

        private func reportAvailableContentSize(_ size: CGSize) {
            guard size != reportedAvailableContentSize else { return }
            reportedAvailableContentSize = size
            // Defer SwiftUI state changes out of native layout; retain only
            // the newest display/toolbar measurement during reflow.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reportedAvailableContentSize == size,
                      self.window != nil else { return }
                self.onAvailableContentSizeChange(size)
            }
        }

        func apply() {
            guard let window, !isApplying else { return }
            isApplying = true
            defer { isApplying = false }
            if window.styleMask.contains(.fullSizeContentView) != windowLayout.usesFullSizeContent {
                if windowLayout.usesFullSizeContent {
                    window.styleMask.insert(.fullSizeContentView)
                } else {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }

            let current = window.contentRect(forFrameRect: window.frame).size
            let usable = window.contentLayoutRect.size
            let covered = CGSize(
                width: max(0, current.width - usable.width),
                height: max(0, current.height - usable.height)
            )
            let available = window.screen.map {
                window.contentRect(forFrameRect: $0.visibleFrame).size
            }
            if let available {
                reportAvailableContentSize(CGSize(
                    width: max(1, available.width - covered.width),
                    height: max(1, available.height - covered.height)
                ))
            }
            let nativeMinimum = CGSize(
                width: minimumContentSize.width + covered.width,
                height: windowLayout == .welcome
                    ? min(minimumContentSize.height + covered.height,
                          available?.height ?? .greatestFiniteMagnitude)
                    : minimumContentSize.height + covered.height
            )
            window.contentMinSize = nativeMinimum

            let changedPhase = appliedLayout != windowLayout
            let wasLaunch = appliedLayout?.usesFullSizeContent == true
            appliedLayout = windowLayout
            var target = current
            if changedPhase {
                let preferred = CGSize(
                    width: windowLayout.preferredContentSize.width + covered.width,
                    height: windowLayout.preferredContentSize.height + covered.height
                )
                if windowLayout == .welcome {
                    target = nativeMinimum
                } else if windowLayout == .session {
                    target = available ?? preferred
                } else if !wasLaunch {
                    target = preferred
                }
            }
            target.width = max(target.width, nativeMinimum.width)
            target.height = max(target.height, nativeMinimum.height)
            if windowLayout == .session, shouldFitToCurrentScreen, let available {
                target.width = max(available.width, nativeMinimum.width)
                target.height = max(available.height, nativeMinimum.height)
                shouldFitToCurrentScreen = false
            }
            if windowLayout == .welcome, let available {
                // Vertical overflow remains reachable through the welcome
                // scroll fallback. Width waits for the columns to reflow.
                target.height = min(target.height, available.height)
                if shouldFitToCurrentScreen, nativeMinimum.width <= available.width {
                    target.width = min(target.width, available.width)
                    shouldFitToCurrentScreen = false
                }
            }
            guard target != current else { return }
            window.setContentSize(target)
            keepWindowOnScreen(window)
        }

        private func keepWindowOnScreen(_ window: NSWindow) {
            guard let visible = window.screen?.visibleFrame,
                  window.frame.width <= visible.width,
                  window.frame.height <= visible.height else { return }
            let origin = CGPoint(
                x: min(max(window.frame.minX, visible.minX), visible.maxX - window.frame.width),
                y: min(max(window.frame.minY, visible.minY), visible.maxY - window.frame.height)
            )
            if window.frame.origin != origin { window.setFrameOrigin(origin) }
        }
    }
}
