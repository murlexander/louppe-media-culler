import SwiftUI

enum PhotosLibraryFailure {
    case selection(String)
    case preparation(String)
    case iCloudDownloadRequired

    var message: String {
        switch self {
        case .selection(let message), .preparation(let message): return message
        case .iCloudDownloadRequired: return PhotosLibraryError.iCloudDownloadRequired.localizedDescription
        }
    }
    var requiresDownload: Bool {
        if case .iCloudDownloadRequired = self { return true }
        return false
    }
    var isSelectionFailure: Bool {
        if case .selection = self { return true }
        return false
    }
}

@MainActor
final class PhotosLibraryBrowser: ObservableObject {
    @Published var query: PhotosLibraryQuery
    @Published var batchSize: Int
    @Published var page: Int
    /// Read-only compatibility for callers that inspect the chooser's consent.
    /// Settings owns changes; a query must never carry its own permission.
    var allowNetwork: Bool { PhotosNetworkPreferences.load(from: defaults).reviewImages }
    @Published private(set) var albums: [PhotosLibraryAlbum] = []
    @Published private(set) var snapshot: PhotosLibrarySnapshot?
    @Published private(set) var isLoading = false
    @Published var isOpening = false
    @Published var progress: PhotosBatchProgress?
    @Published var failure: PhotosLibraryFailure?
    @Published private(set) var openingSelection: PhotosReviewSelection = .entireSelection
    var error: String? { failure?.message }
    private var generation = UUID()
    private let defaults: UserDefaults
    private let service: any PhotosLibraryClient

    init(defaults: UserDefaults = .standard, service: any PhotosLibraryClient = PhotosLibraryService.shared) {
        self.defaults = defaults
        self.service = service
        query = defaults.data(forKey: "photosReview.query").flatMap {
            try? JSONDecoder().decode(PhotosLibraryQuery.self, from: $0)
        } ?? PhotosLibraryQuery()
        let savedSize = defaults.integer(forKey: "photosReview.batchSize")
        batchSize = PhotosBatchRange.sizes.contains(savedSize) ? savedSize : 100
        page = max(0, defaults.integer(forKey: "photosReview.page"))
    }
    var range: PhotosBatchRange {
        if openingSelection == .entireSelection {
            return PhotosBatchRange(entireSelection: snapshot?.count ?? 0)
        }
        return PhotosBatchRange(total: snapshot?.count ?? 0, page: page, size: batchSize)
    }
    /// New chooser presentations always review the complete query. Legacy batch
    /// defaults remain available only to compatibility callers.
    func reviewEntireSelection() { openingSelection = .entireSelection; page = 0 }

    func stageOpening(snapshot: PhotosLibrarySnapshot, selection: PhotosReviewSelection) {
        generation = UUID()
        isLoading = false
        self.snapshot = snapshot
        query = snapshot.query
        openingSelection = selection
        if case .batch(let page, let size) = selection {
            batchSize = size
            self.page = PhotosBatchRange(total: snapshot.count, page: page, size: size).page
        } else {
            page = 0
        }
    }
    /// Keep a compatibility retry bound to its exact request.
    func stageOpening(snapshot: PhotosLibrarySnapshot, page: Int, size: Int) {
        stageOpening(snapshot: snapshot, selection: .batch(page: page, size: size))
    }
    func load() async {
        let token = UUID()
        generation = token
        isLoading = true
        snapshot = nil
        failure = nil
        let selection = query
        do {
            try await service.authorize()
            let albums = try await service.albums()
            guard generation == token else { return }
            try Task.checkCancellation()
            let result = try await service.select(selection)
            guard generation == token else { return }
            try Task.checkCancellation()
            self.albums = albums
            snapshot = result
            page = range.page
            remember()
        } catch is CancellationError {
            if generation == token { isLoading = false }
        } catch {
            guard generation == token else { return }
            if !Task.isCancelled { self.failure = .selection(error.localizedDescription) }
        }
        if generation == token { isLoading = false }
    }
    func remember() {
        if let data = try? JSONEncoder().encode(query) { defaults.set(data, forKey: "photosReview.query") }
        defaults.set(batchSize, forKey: "photosReview.batchSize")
        defaults.set(page, forKey: "photosReview.page")
    }
}
