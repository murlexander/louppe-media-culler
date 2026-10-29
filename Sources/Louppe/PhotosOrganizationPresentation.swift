import Foundation
import Combine

/// Presentation state only. The caller owns authorization, snapshots, and operation gates.
@MainActor
final class PhotosOrganizationReviewModel: ObservableObject {
    @Published var hierarchy: [PhotosOrganizationCollection]
    @Published var choices: PhotosOrganizationChoices
    @Published var scopeCounts: [SourceOrganizationScope: Int]
    @Published var selectionLabel: String
    @Published var phase: PhotosOrganizationPhase
    @Published var hierarchyError: String?
    @Published var canCreateTopLevelAlbum: Bool

    init(
        hierarchy: [PhotosOrganizationCollection] = [],
        choices: PhotosOrganizationChoices = .empty,
        scopeCounts: [SourceOrganizationScope: Int] = [:],
        selectionLabel: String = L10n.text("Selected"),
        phase: PhotosOrganizationPhase = .loading,
        hierarchyError: String? = nil,
        canCreateTopLevelAlbum: Bool = true
    ) {
        self.hierarchy = hierarchy
        self.choices = choices
        self.scopeCounts = scopeCounts
        self.selectionLabel = selectionLabel
        self.phase = phase
        self.hierarchyError = hierarchyError
        self.canCreateTopLevelAlbum = canCreateTopLevelAlbum
    }
}

enum PhotosOrganizationPhase: Equatable {
    case loading
    case choosing
    case working(message: String, completed: Int, total: Int)
    case finished(PhotosOrganizationReport)
}

/// Counts are observations supplied by the worker's owner, never inferred from progress.
struct PhotosOrganizationReport: Equatable {
    enum Disposition: Equatable { case completed, partial, cancelled, failed }

    let disposition: Disposition
    let requested: Int
    let verified: Int
    let alreadyPresent: Int
    let missing: Int
    let uncertain: Int
    let unprocessed: Int
    let message: String?
    let destinationPath: String?

    init(
        disposition: Disposition, requested: Int, verified: Int, alreadyPresent: Int,
        missing: Int, uncertain: Int, unprocessed: Int,
        message: String? = nil, destinationPath: String? = nil
    ) {
        self.disposition = disposition
        self.requested = requested
        self.verified = verified
        self.alreadyPresent = alreadyPresent
        self.missing = missing
        self.uncertain = uncertain
        self.unprocessed = unprocessed
        self.message = message
        self.destinationPath = destinationPath
    }
}

struct PhotosOrganizationDraft: Equatable {
    let scope: SourceOrganizationScope
    let destination: PhotosOrganizationDraftDestination
}

enum PhotosOrganizationDraftDestination: Equatable {
    case existingAlbum(id: String)
    case newAlbum(title: String, parentFolderIdentifier: String?)
}

/// A single replaceable progress value keeps large-library UI publication bounded.
final class PhotosOrganizationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhotosOrganizationProgress?
    func record(_ progress: PhotosOrganizationProgress) { lock.withLock { value = progress } }
    func take() -> PhotosOrganizationProgress? {
        lock.withLock { defer { value = nil }; return value }
    }
}

enum PhotosOrganizationPresentation {
    static func failure(requested: Int, message: String) -> PhotosOrganizationReport {
        PhotosOrganizationReport(disposition: .failed, requested: requested, verified: 0,
            alreadyPresent: 0, missing: 0, uncertain: 0, unprocessed: requested, message: message)
    }

    static func report(_ result: PhotosOrganizationResult, destinationPath: String?) -> PhotosOrganizationReport {
        let complete = result.completion == .completed && result.issue == nil
            && result.requestedCount > 0 && result.verifiedCount == result.requestedCount
            && result.destinationVerified && result.placementVerified
            && result.missingAssetIdentifiers.isEmpty && result.unverifiedAssetIdentifiers.isEmpty
            && result.uncertainAssetIdentifiers.isEmpty && result.unprocessedAssetIdentifiers.isEmpty
        let disposition: PhotosOrganizationReport.Disposition = complete ? .completed
            : result.completion == .cancelled ? .cancelled
            : result.verifiedCount > 0 || result.createdAlbumIdentifier != nil ? .partial : .failed
        var messages: [String] = []
        if let issue = result.issue { messages.append(error(issue)) }
        if !result.unverifiedAssetIdentifiers.isEmpty {
            messages.append(L10n.text("Membership could not be verified for \(result.unverifiedAssetIdentifiers.count.formatted()) items."))
        }
        if result.createdAlbumIdentifier != nil && (!result.destinationVerified || !result.placementVerified) {
            messages.append(L10n.text("A new album may have been created. Its location could not be verified. Check Photos before trying again."))
        } else if !result.destinationVerified || !result.placementVerified {
            messages.append(L10n.text("The destination album or its location could not be verified."))
        }
        return PhotosOrganizationReport(disposition: disposition, requested: result.requestedCount,
            verified: result.verifiedCount, alreadyPresent: result.alreadyPresentAssetIdentifiers.count,
            missing: result.missingAssetIdentifiers.count, uncertain: result.uncertainAssetIdentifiers.count,
            unprocessed: result.unprocessedAssetIdentifiers.count,
            message: messages.isEmpty ? nil : messages.joined(separator: "\n\n"), destinationPath: destinationPath)
    }

    static func progressMessage(_ phase: PhotosOrganizationProgress.Phase) -> String {
        switch phase {
        case .preparing: return L10n.text("Checking Photos items and destination…")
        case .committing: return L10n.text("Updating album membership…")
        case .verifying: return L10n.text("Checking album membership…")
        case .finished: return L10n.text("Finishing album update…")
        }
    }

    static func error(_ error: Error) -> String {
        guard let issue = error as? PhotosOrganizationIssue else { return error.localizedDescription }
        switch issue {
        case .emptySelection: return L10n.text("Choose photos to add to an album.")
        case .invalidIdentifier, .invalidLibraryResponse: return L10n.text("The Photos selection could not be validated.")
        case .invalidTitle: return L10n.text("Enter a name for the new album.")
        case .busy: return L10n.text("Another Photos organization operation is still running.")
        case .permissionDenied: return L10n.text("Allow read and write access to the Photos library, then try again.")
        case .collectionUnavailable: return L10n.text("The selected Photos album or folder is no longer available.")
        case .collectionNotWritable: return L10n.text("The selected Photos album or folder cannot be edited.")
        case .unsupportedAssets: return L10n.text("Some selected photos cannot be added to an album.")
        case .assetsUnavailable: return L10n.text("Some selected photos are no longer available.")
        case .requestUnavailable: return L10n.text("Photos could not prepare the album change.")
        case .changeFailed(let message), .verificationFailed(let message): return message
        case .verificationMismatch: return L10n.text("Photos did not confirm all requested album memberships or the album’s folder.")
        case .hierarchyTooLarge: return L10n.text("The Photos album and folder list exceeds the supported limit.")
        }
    }

    static func destinationPath(_ destination: PhotosOrganizationDestination,
                                choices: PhotosOrganizationChoices) -> String? {
        switch destination {
        case .existingAlbum(let id): return choices.albumsByID[id]?.label
        case .newAlbum(let title, let parent):
            let prefix: String
            if let parent {
                guard let option = choices.foldersByID[parent] else { return nil }
                prefix = option.label
            } else { prefix = L10n.text("Photos Library") }
            return prefix + " › " + title
        }
    }
}

struct PhotosOrganizationCollectionOption: Identifiable, Equatable, Sendable {
    let collection: PhotosOrganizationCollection
    let label: String
    var id: String { collection.id }
}

/// Prepared once off-main for each hierarchy revision. Rendering and text entry
/// read cached arrays/ID lookups; path data is bounded even for deep folder trees.
struct PhotosOrganizationChoices: Sendable {
    let albums: [PhotosOrganizationCollectionOption]
    let folders: [PhotosOrganizationCollectionOption]
    let albumsByID: [String: PhotosOrganizationCollectionOption]
    let foldersByID: [String: PhotosOrganizationCollectionOption]
    static let empty = PhotosOrganizationChoices(albums: [], folders: [], albumsByID: [:], foldersByID: [:])

    static func prepare(_ hierarchy: [PhotosOrganizationCollection],
                        maximumPathBytes: Int = 8 * 1024 * 1024) throws -> PhotosOrganizationChoices {
        guard hierarchy.count <= 50_000 else { throw PhotosOrganizationIssue.hierarchyTooLarge }
        var byID: [String: PhotosOrganizationCollection] = [:]
        for node in hierarchy {
            try Task.checkCancellation()
            guard !node.id.isEmpty, byID.updateValue(node, forKey: node.id) == nil else {
                throw PhotosOrganizationIssue.invalidLibraryResponse
            }
        }
        var paths: [String: String] = [:], bytes = 0
        let root = L10n.text("Photos Library")
        // Iterative ancestor memoization avoids recursion and repeated ancestry walks.
        for node in hierarchy {
            try Task.checkCancellation()
            if paths[node.id] != nil { continue }
            var chain: [PhotosOrganizationCollection] = [], visited = Set<String>()
            var next: String? = node.id
            var prefix = root
            while let id = next {
                try Task.checkCancellation()
                if let cached = paths[id] { prefix = cached; break }
                guard visited.insert(id).inserted, let current = byID[id] else {
                    throw PhotosOrganizationIssue.invalidLibraryResponse
                }
                chain.append(current)
                if let parent = current.parentIdentifier {
                    guard let parentNode = byID[parent], parentNode.kind == .folder else {
                        throw PhotosOrganizationIssue.invalidLibraryResponse
                    }
                }
                next = current.parentIdentifier
            }
            for part in chain.reversed() {
                let remaining = maximumPathBytes - bytes
                guard remaining >= 0, prefix.utf8.count + part.title.utf8.count + 5 <= remaining else {
                    throw PhotosOrganizationIssue.hierarchyTooLarge
                }
                prefix += " › " + part.title
                bytes += prefix.utf8.count
                paths[part.id] = prefix
            }
        }
        let counts = Dictionary(grouping: paths.values, by: { $0 }).mapValues(\.count)
        var albums: [PhotosOrganizationCollectionOption] = [], folders: [PhotosOrganizationCollectionOption] = []
        var albumsByID: [String: PhotosOrganizationCollectionOption] = [:]
        var foldersByID: [String: PhotosOrganizationCollectionOption] = [:]
        for node in hierarchy {
            try Task.checkCancellation()
            guard let path = paths[node.id] else { throw PhotosOrganizationIssue.invalidLibraryResponse }
            let label = counts[path, default: 0] > 1 ? L10n.text("\(path) (ID: \(node.id))") : path
            // Include disambiguation storage in the same finite display budget.
            bytes += label == path ? 0 : label.utf8.count
            guard bytes <= maximumPathBytes else { throw PhotosOrganizationIssue.hierarchyTooLarge }
            let option = PhotosOrganizationCollectionOption(collection: node, label: label)
            if node.kind == .album, node.canAddAssets { albums.append(option); albumsByID[node.id] = option }
            if node.kind == .folder, node.canCreateAlbum { folders.append(option); foldersByID[node.id] = option }
        }
        return PhotosOrganizationChoices(albums: albums, folders: folders,
            albumsByID: albumsByID, foldersByID: foldersByID)
    }
}
