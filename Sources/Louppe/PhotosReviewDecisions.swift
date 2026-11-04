import Foundation

struct PhotosReviewDecision: Codable, Equatable, Sendable {
    var rating: Rating
    var ratedAt: Date?
    var stars: StarRating?
    var starsChangedAt: Date?
    var color: PhotoColorLabel?
    var colorChangedAt: Date?

    init(_ metadata: PhotoFileMetadataSnapshot) {
        rating = metadata.rating; ratedAt = metadata.ratedAt
        stars = metadata.starRating; starsChangedAt = metadata.starsChangedAt
        color = metadata.colorLabel; colorChangedAt = metadata.colorChangedAt
    }
    func metadata(fileID: String) -> PhotoFileMetadataSnapshot {
        PhotoFileMetadataSnapshot(fileID: fileID, rating: rating, ratedAt: ratedAt,
            starRating: stars, starsChangedAt: starsChangedAt, colorLabel: color, colorChangedAt: colorChangedAt)
    }
}

/// Independent of cache paths and batch boundaries. Lock + fresh read/merge +
/// durable atomic replacement preserves decisions from other batches/processes.
actor PhotosReviewDecisions {
    static let shared = PhotosReviewDecisions()
    private let directory: URL
    private let maximumBytes = 64 * 1024 * 1024
    private var latestSequences: [UUID: UInt64] = [:]
    private struct Document: Codable {
        var version = 1
        var assets: [String: PhotosReviewDecision] = [:]
    }
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.alexandermarkin.louppe/PhotosReview", isDirectory: true)) {
        self.directory = directory
    }
    func load(assetIDs: Set<String>? = nil) throws -> [String: PhotosReviewDecision] {
        try locked {
            let assets = try read().assets
            return assetIDs.map { ids in assets.filter { ids.contains($0.key) } } ?? assets
        }
    }
    @discardableResult
    func save(_ decisions: [String: PhotosReviewDecision], writerID: UUID? = nil,
              sequence: UInt64 = 0) throws -> Bool {
        if let writerID, let latest = latestSequences[writerID], sequence <= latest { return false }
        guard !decisions.isEmpty else { return true }
        try locked {
            var document = try read()
            document.assets.merge(decisions) { _, new in new }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try DurableFileIO.atomicWrite(data, to: directory.appendingPathComponent("decisions.json"), fullSync: true)
        }
        if let writerID { latestSequences[writerID] = sequence }
        return true
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try DurableFileIO.withExclusiveFileLock(at: directory.appendingPathComponent("decisions.lock"), perform: body)
    }
    private func read() throws -> Document {
        let url = directory.appendingPathComponent("decisions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let data = try DurableFileIO.readRegularFile(at: url, maximumBytes: maximumBytes)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return document
    }
}
