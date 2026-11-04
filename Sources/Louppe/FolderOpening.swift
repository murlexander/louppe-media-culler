import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// All external folder requests share validation and the session's safe
/// save-before-switch path. Errors stay visible without interrupting review.
@MainActor
final class FolderOpening: ObservableObject {
    @Published var error: String?
    weak var store: SessionStore?

    static func validationError(for urls: [URL]) -> String? {
        guard urls.count == 1 else {
            return L10n.text("Open one folder at a time.")
        }
        let url = urls[0]
        guard url.isFileURL else {
            return L10n.text("Drop a folder containing photos, videos, audio, or text files, not an individual file.")
        }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return L10n.text("Louppe couldn't read the dropped folder. Please try again.")
        }
        guard values.isDirectory == true else {
            return L10n.text("Drop a folder containing photos, videos, audio, or text files, not an individual file.")
        }
        return nil
    }

    @discardableResult
    func open(_ urls: [URL]) -> String? {
        if let message = Self.validationError(for: urls) {
            error = message
            return message
        }
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
        error = message
        guard message == nil else { return message }
        store.openFolder(urls[0])
        return nil
    }

    func openDroppedFolder(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty,
              providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
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
                guard let url else {
                    self.error = L10n.text("Louppe couldn't read the dropped folder. Please try again.")
                    return
                }
                self.open([url])
            }
        }
        return true
    }
}
