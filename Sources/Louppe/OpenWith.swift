import AppKit
import UniformTypeIdentifiers

/// The editors Open With offers. Only installed copies are listed; every
/// installed copy stays listed, including several Capture One versions.
enum PhotoEditorKind: Int, CaseIterable, Sendable {
    case lightroomClassic
    case captureOne
    case photoshop
    case preview

    /// Exact identifiers, newest first. Capture One 20+ uses
    /// `com.captureone.captureoneNN`; 12 and older used `com.phaseone`.
    var bundleIdentifiers: [String] {
        switch self {
        case .lightroomClassic: return ["com.adobe.LightroomClassicCC7"]
        case .captureOne:
            return (13...40).reversed().map { "com.captureone.captureone\($0)" }
                + ["com.captureone.captureone"]
                + (7...12).reversed().map { "com.phaseone.captureone\($0)" }
                + ["com.phaseone.captureone"]
        case .photoshop: return ["com.adobe.Photoshop"]
        case .preview: return ["com.apple.Preview"]
        }
    }

    func matches(bundleIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        switch self {
        case .captureOne:
            for prefix in ["com.captureone.captureone", "com.phaseone.captureone"]
            where identifier.hasPrefix(prefix) {
                return identifier.dropFirst(prefix.count).allSatisfy(\.isNumber)
            }
            return false
        default:
            return bundleIdentifiers.contains { $0.lowercased() == identifier }
        }
    }

    /// Capture One versions register under numbered identifiers that the
    /// exact list may not know yet; its RAW/JPEG handlers fill the gap.
    var discoversHandlers: Bool { self == .captureOne }
}

struct PhotoEditorApplication: Identifiable, Equatable, Sendable {
    let kind: PhotoEditorKind
    let url: URL
    let bundleIdentifier: String
    let title: String
    var id: String { url.standardizedFileURL.path }
}

/// Launch Services access, injectable so tests never open an editor.
protocol OpenWithWorkspace: Sendable {
    func applicationURLs(bundleIdentifier: String) -> [URL]
    func applicationURLs(toOpen contentType: UTType) -> [URL]
    func bundleIdentifier(ofApplicationAt url: URL) -> String?
    func displayName(ofApplicationAt url: URL) -> String
    func version(ofApplicationAt url: URL) -> String?
    func defaultApplicationURL(toOpen fileURL: URL) -> URL?
    func open(_ urls: [URL], withApplicationAt applicationURL: URL,
              completion: @escaping @Sendable ((any Error)?) -> Void)
}

struct LiveOpenWithWorkspace: OpenWithWorkspace {
    func applicationURLs(bundleIdentifier: String) -> [URL] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
    }

    func applicationURLs(toOpen contentType: UTType) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: contentType)
    }

    func bundleIdentifier(ofApplicationAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    func displayName(ofApplicationAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
    }

    func version(ofApplicationAt url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func defaultApplicationURL(toOpen fileURL: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: fileURL)
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL,
              completion: @escaping @Sendable ((any Error)?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL,
                                configuration: configuration) { _, error in completion(error) }
    }
}

/// A short-lived snapshot of installed editors. Lookups run off-main and are
/// never repeated per tile or per redraw; menus read the published list.
@MainActor
final class PhotoEditorCatalog: ObservableObject {
    static let shared = PhotoEditorCatalog(workspace: LiveOpenWithWorkspace())
    static let refreshInterval: Duration = .seconds(30)

    @Published private(set) var editors: [PhotoEditorApplication] = []
    private(set) var workspace: any OpenWithWorkspace
    private var refreshedAt: ContinuousClock.Instant?
    private var refreshTask: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]

    private var activationObserver: (any NSObjectProtocol)?
    /// Set when Louppe became active during a lookup, so that result is not
    /// treated as fresh.
    private var staleDuringRefresh = false

    init(workspace: any OpenWithWorkspace, notificationCenter: NotificationCenter = .default) {
        self.workspace = workspace
        // Editors installed or removed while Louppe was in the background:
        // activation only marks the list stale; the next Open With menu or
        // palette that is built refreshes it off-main.
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.markStale() }
        }
    }

    func markStale() {
        refreshedAt = nil
        if refreshTask != nil { staleDuringRefresh = true }
    }

    /// Called by every Open With menu and the palette when they are built.
    func refreshIfStale() {
        guard refreshTask == nil else { return }
        if let refreshedAt, ContinuousClock.now - refreshedAt < Self.refreshInterval { return }
        let workspace = workspace
        staleDuringRefresh = false
        refreshTask = Task { [weak self] in
            let editors = await Task.detached(priority: .utility) {
                Self.resolve(using: workspace)
            }.value
            guard let self else { return }
            self.refreshTask = nil
            self.refreshedAt = self.staleDuringRefresh ? nil : .now
            if self.editors != editors { self.editors = editors }
        }
    }

    #if LOUPPE_TEST_SEAMS
    func waitForRefreshForTesting() async { await refreshTask?.value }
    #endif

    func icon(for editor: PhotoEditorApplication) -> NSImage {
        if let icon = icons[editor.id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: editor.url.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[editor.id] = icon
        return icon
    }

    #if LOUPPE_TEST_SEAMS
    func replaceWorkspaceForTesting(_ workspace: any OpenWithWorkspace) async {
        await refreshTask?.value
        self.workspace = workspace
        refreshedAt = nil
        editors = Self.resolve(using: workspace)
        refreshedAt = .now
    }
    #endif

    /// Every installed copy of each editor, in Launch Services order, with
    /// duplicate display names disambiguated by version.
    nonisolated static func resolve(using workspace: any OpenWithWorkspace) -> [PhotoEditorApplication] {
        var seen = Set<String>()
        var found: [(PhotoEditorKind, URL, String)] = []
        for kind in PhotoEditorKind.allCases {
            var candidates = kind.bundleIdentifiers.flatMap(workspace.applicationURLs(bundleIdentifier:))
            if kind.discoversHandlers {
                candidates += [UTType.rawImage, .jpeg].flatMap(workspace.applicationURLs(toOpen:))
            }
            for url in candidates {
                let key = url.standardizedFileURL.path
                guard !seen.contains(key),
                      let identifier = workspace.bundleIdentifier(ofApplicationAt: url),
                      kind.matches(bundleIdentifier: identifier) else { continue }
                seen.insert(key)
                found.append((kind, url, identifier))
            }
        }
        let names = found.map { workspace.displayName(ofApplicationAt: $0.1) }
        return found.enumerated().map { offset, entry in
            var title = names[offset]
            if names.filter({ $0 == title }).count > 1,
               let version = workspace.version(ofApplicationAt: entry.1) {
                title = "\(title) (\(version))"
            }
            return PhotoEditorApplication(kind: entry.0, url: entry.1, bundleIdentifier: entry.2, title: title)
        }
    }
}

enum OpenWithChoice: Equatable, Sendable {
    case editor(PhotoEditorApplication)
    /// Each file goes to its own default app, so a RAW and its JPEG may differ.
    case defaultApplication
}

/// What one Open With request will send, decided off-main from the
/// originals that still exist. Louppe asks Launch Services to open the files
/// in place; it never moves, imports or changes them.
struct OpenWithPlan: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        let applicationURL: URL
        let urls: [URL]
    }
    var requests: [Request] = []
    var missing: [URL] = []
    var unhandled: [URL] = []
    var editorUnavailable = false

    static func make(targets: OriginalFileTargets, choice: OpenWithChoice,
                     workspace: any OpenWithWorkspace) -> OpenWithPlan {
        var plan = OpenWithPlan()
        // Same identity rule as drag-out: a same-name replacement is missing.
        let present = targets.existing()?.urls ?? []
        let presentSet = Set(present)
        plan.missing = targets.urls.filter { !presentSet.contains($0) }
        guard !present.isEmpty else { return plan }
        switch choice {
        case .editor(let editor):
            guard let identifier = workspace.bundleIdentifier(ofApplicationAt: editor.url),
                  editor.kind.matches(bundleIdentifier: identifier) else {
                plan.editorUnavailable = true
                return plan
            }
            plan.requests = [Request(applicationURL: editor.url, urls: present)]
        case .defaultApplication:
            var order: [String] = []
            var groups: [String: (URL, [URL])] = [:]
            for url in present {
                guard let application = workspace.defaultApplicationURL(toOpen: url) else {
                    plan.unhandled.append(url)
                    continue
                }
                let key = application.standardizedFileURL.path
                if groups[key] == nil { order.append(key); groups[key] = (application, []) }
                groups[key]?.1.append(url)
            }
            plan.requests = order.compactMap { key in
                groups[key].map { Request(applicationURL: $0.0, urls: $0.1) }
            }
        }
        return plan
    }
}

/// One dispatcher for File, tile and Gallery menus and the Command Palette.
@MainActor
enum OriginalFilesOpener {
    #if LOUPPE_TEST_SEAMS
    static var didFinishPlanning: ((OpenWithPlan) -> Void)?
    #endif

    static func open(_ origin: OriginalFilesOrigin, with choice: OpenWithChoice, store: SessionStore,
                     workspace: (any OpenWithWorkspace)? = nil) {
        guard let targets = store.originalFileTargets(for: origin) else {
            // The item behind a menu was replaced or left the view: say so.
            store.originalHandoffAlert = OriginalHandoffAlert(
                title: L10n.text("Open With"),
                message: L10n.text("The originals are missing or changed since Louppe scanned them. Rescan the folder or reconnect its drive, then try again."))
            return
        }
        let workspace = workspace ?? PhotoEditorCatalog.shared.workspace
        let token = store.mediaReadAccess?.begin()
        let source = store.sourceFolder
        Task { @MainActor [weak store] in
            let plan = await Task.detached(priority: .userInitiated) {
                withExtendedLifetime(token) {
                    OpenWithPlan.make(targets: targets, choice: choice, workspace: workspace)
                }
            }.value
            #if LOUPPE_TEST_SEAMS
            didFinishPlanning?(plan)
            #endif
            guard let store, store.sourceFolder == source else { return }
            execute(plan, choice: choice, store: store, workspace: workspace, readToken: token)
        }
    }

    private static func execute(_ plan: OpenWithPlan, choice: OpenWithChoice, store: SessionStore,
                                workspace: any OpenWithWorkspace, readToken: MediaReadAccess.Token?) {
        let title = L10n.text("Open With")
        if plan.editorUnavailable, case .editor(let editor) = choice {
            store.originalHandoffAlert = OriginalHandoffAlert(
                title: title, message: L10n.text("\(editor.title) is no longer installed on this Mac."))
            return
        }
        guard !plan.requests.isEmpty || !plan.unhandled.isEmpty else {
            store.originalHandoffAlert = OriginalHandoffAlert(
                title: title,
                message: L10n.text("The originals are missing or changed since Louppe scanned them. Rescan the folder or reconnect its drive, then try again."))
            return
        }
        for request in plan.requests {
            workspace.open(request.urls, withApplicationAt: request.applicationURL) { error in
                withExtendedLifetime(readToken) {}
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in
                    store.originalHandoffAlert = OriginalHandoffAlert(title: title, message: message)
                }
            }
        }
        var notes: [String] = []
        if !plan.missing.isEmpty {
            notes.append(L10n.plural("%lld originals are missing or changed since Louppe scanned them, so they weren't opened. Rescan the folder or reconnect its drive.",
                                     plan.missing.count))
        }
        if !plan.unhandled.isEmpty {
            notes.append(L10n.plural("No app on this Mac opens %lld of these files by default. Choose an app from Open With instead.",
                                     plan.unhandled.count))
        }
        if !notes.isEmpty {
            store.originalHandoffAlert = OriginalHandoffAlert(title: title, message: notes.joined(separator: " "))
        }
    }
}
