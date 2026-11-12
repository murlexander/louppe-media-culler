import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// All external folder requests share validation and the session's safe
/// save-before-switch path. Errors stay visible without interrupting review.
@MainActor
final class FolderOpening: ObservableObject {
    @Published var error: String?
    weak var store: SessionStore?

    private var requestID = UUID()
    private var requestFolderGeneration: UInt64?
    private var requestSourceGeneration: UInt64?
    private(set) var validationTask: Task<Void, Never>?
    private let readDirectory: @Sendable (URL) throws -> Bool
    private let resourceAccess: SecurityScopedResourceAccess

    init(
        readDirectory: @escaping @Sendable (URL) throws -> Bool = {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        },
        resourceAccess: SecurityScopedResourceAccess = .live
    ) {
        self.readDirectory = readDirectory
        self.resourceAccess = resourceAccess
    }

    static func requestError(for urls: [URL]) -> String? {
        guard urls.count == 1 else {
            return L10n.text("Open one folder at a time.")
        }
        let url = urls[0]
        guard url.isFileURL else {
            return L10n.text("Drop a folder containing photos, videos, audio, or text files, not an individual file.")
        }
        return nil
    }

    @discardableResult
    func open(_ urls: [URL]) -> String? {
        let id = beginRequest()
        if let message = Self.requestError(for: urls) ?? openingGateError() {
            error = message
            return message
        }
        validateAndOpen(urls[0], requestID: id)
        return nil
    }

    private func beginRequest() -> UUID {
        requestID = UUID()
        requestFolderGeneration = store?.folderOpenGeneration
        requestSourceGeneration = store?.beginExternalFolderRequest()
        validationTask?.cancel()
        validationTask = nil
        error = nil
        return requestID
    }

    private func validateAndOpen(_ url: URL, requestID: UUID) {
        guard let store else { return }
        let sourceFolder = store.sourceFolder
        let folderGeneration = store.folderOpenGeneration
        let sourceGeneration = store.sourceOpenRequestGeneration
        let readDirectory = readDirectory
        let resourceAccess = resourceAccess
        validationTask = Task { [weak self, weak store] in
            // This worker owns access until the filesystem call exits, even
            // when a newer request retires its result during a slow read.
            let message = await Task.detached(priority: .userInitiated) {
                let hasAccess = resourceAccess.start(url)
                defer { if hasAccess { resourceAccess.stop(url) } }
                do {
                    return try readDirectory(url) ? nil
                        : L10n.text("Drop a folder containing photos, videos, audio, or text files, not an individual file.")
                } catch {
                    return L10n.text("Louppe couldn't read the dropped folder. Please try again.")
                }
            }.value
            guard let self, let store, !Task.isCancelled,
                  self.requestID == requestID, self.store === store,
                  store.sourceFolder == sourceFolder,
                  store.folderOpenGeneration == folderGeneration,
                  store.sourceOpenRequestGeneration == sourceGeneration else { return }
            self.error = message ?? self.openingGateError()
            guard self.error == nil else { return }
            store.openFolder(url)
        }
    }

    private func openingGateError() -> String? {
        guard let store else { return nil }
        // Startup recovery already owns a deferred-open slot. Let it keep the
        // requested folder until recovery reaches its safe boundary.
        let canDeferForLaunchRecovery = store.isRecoveringInterruptedOperations
            && store.sourceFolder == nil
        let application = NSApplication.shared
        let message: String?
        if store.isFileOperationRunning && !canDeferForLaunchRecovery {
            message = L10n.text("Wait for Louppe to finish its current operation, then try again.")
        } else if !canDeferForLaunchRecovery && (store.isSessionCommandPresentationActive
            || application.modalWindow != nil
            || application.mainWindow?.attachedSheet != nil) {
            message = L10n.text("Close the current dialog or popover, then open the folder.")
        } else {
            message = nil
        }
        return message
    }

    func openDroppedFolder(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        let id = beginRequest()
        guard providers.count == 1, let provider = providers.first else {
            error = L10n.text("Open one folder at a time.")
            return true
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let value = item as? URL {
                url = value
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            Task { @MainActor in
                guard self.requestID == id,
                      self.store?.folderOpenGeneration == self.requestFolderGeneration,
                      self.store?.sourceOpenRequestGeneration == self.requestSourceGeneration else { return }
                guard let url else {
                    self.error = L10n.text("Louppe couldn't read the dropped folder. Please try again.")
                    return
                }
                if let message = Self.requestError(for: [url]) ?? self.openingGateError() {
                    self.error = message
                    return
                }
                self.validateAndOpen(url, requestID: id)
            }
        }
        return true
    }
}
