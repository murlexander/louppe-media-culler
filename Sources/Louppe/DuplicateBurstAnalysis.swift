import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A local, bounded helper for the optional grouped-review view. It deliberately
/// produces leads for a photographer to inspect; it never changes session
/// metadata or touches a source file beyond reading it.
enum DuplicateBurstAnalysis {
    /// The review layouts supported by v1. Keeping the three explanations
    /// separate avoids pretending that a visual match is as certain as a
    /// byte-for-byte duplicate.
    enum ReviewMode: String, CaseIterable, Equatable, Hashable, Sendable {
        case off
        case exactDuplicates
        case likelySimilarPhotos
        case captureBursts

        var displayName: String {
            switch self {
            case .off: return L10n.text("Normal review")
            case .exactDuplicates: return L10n.text("Exact duplicates")
            case .likelySimilarPhotos: return L10n.text("Likely similar photos")
            case .captureBursts: return L10n.text("Capture bursts")
            }
        }

        var shortDescription: String {
            switch self {
            case .off:
                return L10n.text("Show the folder in its normal filtered and sorted order.")
            case .exactDuplicates:
                return L10n.text("Groups only files with the same verified bytes.")
            case .likelySimilarPhotos:
                return L10n.text("Groups similar small local previews; review every match yourself.")
            case .captureBursts:
                return L10n.text("Groups consecutive photo dates within the chosen gap. File creation dates are inferred; separate shutter presses and cameras can mix.")
            }
        }

        var analysisTitle: String {
            switch self {
            case .off: return L10n.text("Normal review")
            case .exactDuplicates: return L10n.text("Exact duplicates")
            case .likelySimilarPhotos: return L10n.text("Likely similar photos")
            case .captureBursts: return L10n.text("Capture bursts")
            }
        }
    }

    enum AnalysisMode: Equatable, Sendable {
        case all
        case captureBursts
    }

    /// Per-call injection verifies the metadata-only contract without global
    /// probes, real decoding, or hanging sentinel files.
    struct FileAccess: Sendable {
        let exactDigest: @Sendable (ExactFile) throws -> String?
        let visualHash: @Sendable ([VisualFile]) -> UInt64?

        static let live = FileAccess(
            exactDigest: { try DuplicateBurstAnalysis.exactDigestIfUnchanged($0) },
            visualHash: { DuplicateBurstAnalysis.perceptualHash(from: $0) }
        )
    }

    struct ExactFile: Sendable {
        let reviewItemID: String
        let url: URL
        let fileSize: Int64
        let expectedIdentity: FileOperationJournal.FileIdentity?

        init(
            reviewItemID: String,
            url: URL,
            fileSize: Int64,
            expectedIdentity: FileOperationJournal.FileIdentity? = nil
        ) {
            self.reviewItemID = reviewItemID
            self.url = url
            self.fileSize = fileSize
            self.expectedIdentity = expectedIdentity
        }
    }

    struct VisualFile: Sendable {
        let url: URL
        let expectedIdentity: FileOperationJournal.FileIdentity?

        init(
            url: URL,
            expectedIdentity: FileOperationJournal.FileIdentity? = nil
        ) {
            self.url = url
            self.expectedIdentity = expectedIdentity
        }
    }

    /// One displayed item. In RAW+JPEG-together mode, `exactFiles` contains
    /// both physical files while visual analysis tries the visible primary file
    /// before its JPEG partner. The result remains one stable review-item ID.
    struct Input: Sendable {
        let id: String
        let mediaKind: MediaKind
        let captureDate: Date?
        let captureDateEvidence: CaptureDateEvidence?
        let exactFiles: [ExactFile]
        let visualFiles: [VisualFile]

        init(
            id: String,
            mediaKind: MediaKind,
            captureDate: Date?,
            captureDateEvidence: CaptureDateEvidence? = nil,
            exactFiles: [ExactFile],
            visualFiles: [VisualFile]
        ) {
            self.id = id
            self.mediaKind = mediaKind
            self.captureDate = captureDate
            self.captureDateEvidence = captureDateEvidence
            self.exactFiles = exactFiles
            self.visualFiles = visualFiles
        }
    }

    struct VisualFingerprint: Equatable, Sendable {
        let itemID: String
        let hash: UInt64
    }

    struct BurstCandidate: Equatable, Sendable {
        let itemID: String
        let captureDate: Date
        let captureDateEvidence: CaptureDateEvidence?

        init(
            itemID: String,
            captureDate: Date,
            captureDateEvidence: CaptureDateEvidence? = nil
        ) {
            self.itemID = itemID
            self.captureDate = captureDate
            self.captureDateEvidence = captureDateEvidence
        }
    }

    struct Group: Equatable, Identifiable, Sendable {
        let id: String
        let mode: ReviewMode
        let itemIDs: [String]
        let captureDateNote: String?

        init(
            id: String,
            mode: ReviewMode,
            itemIDs: [String],
            captureDateNote: String? = nil
        ) {
            self.id = id
            self.mode = mode
            self.itemIDs = itemIDs
            self.captureDateNote = captureDateNote
        }

        var title: String {
            title(itemCount: itemIDs.count)
        }

        func title(itemCount count: Int) -> String {
            let itemText = count == 1 ? L10n.text("item") : L10n.text("items")
            switch mode {
            case .exactDuplicates:
                return L10n.text("Exact duplicates · \(count) \(itemText) · matching file fingerprints")
            case .likelySimilarPhotos:
                return L10n.text("Likely similar · \(count) \(itemText) · local preview comparison")
            case .captureBursts:
                let title = L10n.text("Capture burst · \(count) \(itemText)")
                return captureDateNote.map { "\(title) · \($0)" } ?? title
            case .off:
                return ""
            }
        }
    }

    /// Completed, in-memory analysis. No result is written to the media folder
    /// or cache: content revisions are checked by `SessionStore` before this
    /// value is ever shown.
    struct Result: Sendable {
        let exactDuplicateItemSets: [[String]]
        let visualFingerprints: [VisualFingerprint]
        let burstCandidates: [BurstCandidate]
        let analyzedExactFileCount: Int
        let analyzedVisualPhotoCount: Int
        let analysisMode: AnalysisMode

        init(
            exactDuplicateItemSets: [[String]],
            visualFingerprints: [VisualFingerprint],
            burstCandidates: [BurstCandidate],
            analyzedExactFileCount: Int,
            analyzedVisualPhotoCount: Int,
            analysisMode: AnalysisMode = .all
        ) {
            self.exactDuplicateItemSets = exactDuplicateItemSets
            self.visualFingerprints = visualFingerprints
            self.burstCandidates = burstCandidates
            self.analyzedExactFileCount = analyzedExactFileCount
            self.analyzedVisualPhotoCount = analyzedVisualPhotoCount
            self.analysisMode = analysisMode
        }

        func supports(_ mode: ReviewMode) -> Bool {
            mode == .off || mode == .captureBursts || analysisMode == .all
        }

        func groups(
            for mode: ReviewMode,
            visualDistance: Int,
            burstInterval: TimeInterval
        ) -> [Group] {
            groups(for: mode, visualDistance: visualDistance,
                   burstInterval: burstInterval, checkingCancellation: {})
        }

        /// Membership runs in the session's existing detached analysis owner.
        /// Cancellation never returns partial groups for publication.
        func groupsCancellable(
            for mode: ReviewMode,
            visualDistance: Int,
            burstInterval: TimeInterval
        ) throws -> [Group] {
            try groups(for: mode, visualDistance: visualDistance,
                       burstInterval: burstInterval,
                       checkingCancellation: DuplicateBurstAnalysis.checkCancellation)
        }

        /// A per-call checkpoint also makes cooperative cancellation testable
        /// without timing a worker against the scheduler.
        func groups(
            for mode: ReviewMode,
            visualDistance: Int,
            burstInterval: TimeInterval,
            checkingCancellation: () throws -> Void
        ) rethrows -> [Group] {
            try checkingCancellation()
            guard supports(mode) else { return [] }
            let itemSets: [[String]]
            switch mode {
            case .off:
                return []
            case .exactDuplicates:
                itemSets = exactDuplicateItemSets
            case .likelySimilarPhotos:
                itemSets = try visualDuplicateSets(
                    maxDistance: visualDistance,
                    checkingCancellation: checkingCancellation
                )
            case .captureBursts:
                itemSets = try burstSets(
                    maximumGap: burstInterval,
                    checkingCancellation: checkingCancellation
                )
            }
            return try makeGroups(from: itemSets, mode: mode,
                                  checkingCancellation: checkingCancellation)
        }

        private func makeGroups(
            from itemSets: [[String]],
            mode: ReviewMode,
            checkingCancellation: () throws -> Void
        ) rethrows -> [Group] {
            var inferredDateIDs = Set<String>()
            if mode == .captureBursts {
                for candidate in burstCandidates {
                    try checkingCancellation()
                    if candidate.captureDateEvidence?.isInferred ?? true {
                        inferredDateIDs.insert(candidate.itemID)
                    }
                }
            }
            return try itemSets.enumerated().compactMap { index, itemIDs in
                try checkingCancellation()
                var seen = Set<String>()
                var unique: [String] = []
                for itemID in itemIDs {
                    try checkingCancellation()
                    if seen.insert(itemID).inserted { unique.append(itemID) }
                }
                if mode != .captureBursts { unique.sort() }
                try checkingCancellation()
                guard unique.count >= 2 else { return nil }
                return Group(
                    id: "\(mode.rawValue)-\(index)-\(unique[0])",
                    mode: mode,
                    itemIDs: unique,
                    captureDateNote: unique.contains(where: inferredDateIDs.contains)
                        ? L10n.text("inferred dates") : nil
                )
            }
        }

        /// This is intentionally conservative. Equal perceptual hashes are
        /// always joined. Near-hash comparison uses four 16-bit locality
        /// buckets and caps pair checks, so large folders cannot turn the
        /// review feature into an unbounded all-pairs search.
        private func visualDuplicateSets(
            maxDistance: Int,
            checkingCancellation: () throws -> Void
        ) rethrows -> [[String]] {
            guard visualFingerprints.count >= 2 else { return [] }
            let distance = min(max(maxDistance, 0), 64)
            let ordered = visualFingerprints.sorted { $0.itemID < $1.itemID }
            try checkingCancellation()
            var sets = DisjointSets(itemIDs: ordered.map(\.itemID))
            var identifiersByHash: [UInt64: [String]] = [:]
            for fingerprint in ordered {
                try checkingCancellation()
                identifiersByHash[fingerprint.hash, default: []].append(
                    fingerprint.itemID
                )
            }
            for identifiers in identifiersByHash.values where identifiers.count > 1 {
                for identifier in identifiers.dropFirst() {
                    try checkingCancellation()
                    sets.union(identifiers[0], identifier)
                }
            }

            var distinctHashesByBucket: [UInt16: [UInt64]] = [:]
            for hash in identifiersByHash.keys.sorted() {
                try checkingCancellation()
                for bucket in DuplicateBurstAnalysis.visualBuckets(for: hash) {
                    distinctHashesByBucket[bucket, default: []].append(hash)
                }
            }

            var checkedPairs = Set<HashPair>()
            var checkedCount = 0
            outer: for bucket in distinctHashesByBucket.keys.sorted() {
                try checkingCancellation()
                let hashes = distinctHashesByBucket[bucket, default: []].sorted()
                // An extremely common low-detail thumbnail can share a bucket
                // with thousands of images. Exact fingerprint matches above
                // still appear, while broad near-match probing stops here.
                guard hashes.count <= DuplicateBurstAnalysis.maximumHashesPerVisualBucket else {
                    continue
                }
                for leftIndex in hashes.indices {
                    for rightIndex in hashes.indices.dropFirst(leftIndex + 1) {
                        try checkingCancellation()
                        let left = hashes[leftIndex]
                        let right = hashes[rightIndex]
                        let pair = HashPair(left, right)
                        guard checkedPairs.insert(pair).inserted else { continue }
                        checkedCount += 1
                        guard checkedCount <= DuplicateBurstAnalysis.maximumVisualPairChecks else {
                            break outer
                        }
                        guard (left ^ right).nonzeroBitCount <= distance,
                              let leftItem = identifiersByHash[left]?.first,
                              let rightItem = identifiersByHash[right]?.first
                        else { continue }
                        // Equal hashes already form one component each. One
                        // representative joins both complete families; joining
                        // every cross-product member would be quadratic even
                        // though the number of compared hashes is bounded.
                        sets.union(leftItem, rightItem)
                    }
                }
            }
            return try sets.components(minimumCount: 2,
                                       checkingCancellation: checkingCancellation)
        }

        private func burstSets(
            maximumGap: TimeInterval,
            checkingCancellation: () throws -> Void
        ) rethrows -> [[String]] {
            guard burstCandidates.count >= 2 else { return [] }
            let gap = min(max(maximumGap, 0.1), 30)
            let ordered = burstCandidates.sorted {
                if $0.captureDate != $1.captureDate {
                    return $0.captureDate < $1.captureDate
                }
                return $0.itemID < $1.itemID
            }
            try checkingCancellation()
            var groups: [[String]] = []
            var current: [String] = []
            var previousDate: Date?
            for candidate in ordered {
                try checkingCancellation()
                if let previousDate,
                   candidate.captureDate.timeIntervalSince(previousDate) > gap {
                    if current.count >= 2 { groups.append(current) }
                    current = []
                }
                current.append(candidate.itemID)
                previousDate = candidate.captureDate
            }
            if current.count >= 2 { groups.append(current) }
            return groups
        }
    }

    enum AnalysisError: Error {
        case cancelled
    }

    /// Freeze only the payload needed by this request. Capture grouping reads
    /// cached metadata and never constructs physical-file or preview arrays.
    static func inputs(from items: [PhotoItem], mode: AnalysisMode) -> [Input] {
        items.map { item in
            if mode == .captureBursts {
                return Input(id: item.id, mediaKind: item.mediaKind,
                             captureDate: item.captureDate,
                             captureDateEvidence: item.captureDateEvidence,
                             exactFiles: [], visualFiles: [])
            }
            let files = item.individualFiles
            return Input(
                id: item.id, mediaKind: item.mediaKind,
                captureDate: item.captureDate,
                captureDateEvidence: item.captureDateEvidence,
                exactFiles: files.map {
                    ExactFile(reviewItemID: item.id, url: $0.url,
                              fileSize: $0.fileSize, expectedIdentity: $0.scannedIdentity)
                },
                visualFiles: item.mediaKind == .photo && item.isSupported
                    ? files.map { VisualFile(url: $0.url, expectedIdentity: $0.scannedIdentity) }
                    : []
            )
        }
    }

    /// Runs on the caller's detached utility task. Capture bursts use only
    /// scanned dates. Full analysis streams bytes with one 1 MiB buffer and
    /// decodes a 9×8 grayscale signature; no full-resolution image is retained.
    static func analyze(
        _ inputs: [Input],
        mode: AnalysisMode = .all,
        fileAccess: FileAccess = .live
    ) throws -> Result {
        try checkCancellation()
        var burstCandidates: [BurstCandidate] = []
        burstCandidates.reserveCapacity(inputs.count)
        for input in inputs {
            try checkCancellation()
            guard input.mediaKind == .photo, let captureDate = input.captureDate else { continue }
            burstCandidates.append(BurstCandidate(
                itemID: input.id,
                captureDate: captureDate,
                captureDateEvidence: input.captureDateEvidence
            ))
        }
        // A burst request ends here: no file identities, bytes or previews are
        // read. Result capability prevents later exact/similar cache reuse.
        if mode == .captureBursts {
            return Result(
                exactDuplicateItemSets: [], visualFingerprints: [],
                burstCandidates: burstCandidates, analyzedExactFileCount: 0,
                analyzedVisualPhotoCount: 0, analysisMode: mode
            )
        }
        let order = Dictionary(
            uniqueKeysWithValues: inputs.enumerated().map { ($0.element.id, $0.offset) }
        )

        var exactBySize: [Int64: [ExactFile]] = [:]
        for input in inputs {
            for file in input.exactFiles where file.fileSize >= 0 {
                exactBySize[file.fileSize, default: []].append(file)
            }
        }
        var exactItemSets: [[String]] = []
        var exactFileCount = 0
        for size in exactBySize.keys.sorted() {
            try checkCancellation()
            guard let files = exactBySize[size], files.count >= 2 else { continue }
            var itemIDsByDigest: [String: Set<String>] = [:]
            for file in files {
                try checkCancellation()
                guard let digest = try fileAccess.exactDigest(file) else { continue }
                exactFileCount += 1
                itemIDsByDigest[digest, default: []].insert(file.reviewItemID)
            }
            exactItemSets += itemIDsByDigest.values
                .filter { $0.count >= 2 }
                .map { Self.ordered(Array($0), by: order) }
        }

        var visualFingerprints: [VisualFingerprint] = []
        for input in inputs {
            try checkCancellation()
            guard input.mediaKind == .photo else { continue }
            guard let hash = fileAccess.visualHash(input.visualFiles) else { continue }
            visualFingerprints.append(VisualFingerprint(itemID: input.id, hash: hash))
        }

        return Result(
            exactDuplicateItemSets: mergeOverlapping(
                exactItemSets,
                order: order
            ),
            visualFingerprints: visualFingerprints,
            burstCandidates: burstCandidates,
            analyzedExactFileCount: exactFileCount,
            analyzedVisualPhotoCount: visualFingerprints.count
        )
    }

    private static let maximumHashesPerVisualBucket = 256
    private static let maximumVisualPairChecks = 50_000
    private static let hashReadSize = 1_024 * 1_024

    private static func exactDigestIfUnchanged(
        _ file: ExactFile
    ) throws -> String? {
        guard fileMatchesExpectedIdentity(file.url, expected: file.expectedIdentity),
              let digest = try streamDigest(at: file.url),
              fileMatchesExpectedIdentity(file.url, expected: file.expectedIdentity)
        else {
            return nil
        }
        return digest
    }

    private static func streamDigest(at url: URL) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try checkCancellation()
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: hashReadSize) ?? Data()
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func perceptualHash(from files: [VisualFile]) -> UInt64? {
        for file in files {
            guard fileMatchesExpectedIdentity(file.url, expected: file.expectedIdentity),
                  let hash = perceptualHash(at: file.url),
                  fileMatchesExpectedIdentity(file.url, expected: file.expectedIdentity)
            else {
                continue
            }
            return hash
        }
        return nil
    }

    private static func perceptualHash(at url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for row in 0..<height {
            for column in 0..<(width - 1) {
                let left = pixels[row * width + column]
                let right = pixels[row * width + column + 1]
                if left >= right { hash |= bit }
                bit <<= 1
            }
        }
        return hash
    }

    private static func fileMatchesExpectedIdentity(
        _ url: URL,
        expected: FileOperationJournal.FileIdentity?
    ) -> Bool {
        guard let expected else { return true }
        guard let actual = try? FileOperationJournal.captureIdentity(at: url) else {
            return false
        }
        return FileOperationJournal.identitiesMatch(
            expected: expected,
            actual: actual,
            includeStatusChange: true
        )
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw AnalysisError.cancelled }
    }

    private static func visualBuckets(for hash: UInt64) -> [UInt16] {
        [
            UInt16(truncatingIfNeeded: hash),
            UInt16(truncatingIfNeeded: hash >> 16),
            UInt16(truncatingIfNeeded: hash >> 32),
            UInt16(truncatingIfNeeded: hash >> 48),
        ]
    }

    private static func ordered(
        _ itemIDs: [String],
        by order: [String: Int]
    ) -> [String] {
        itemIDs.sorted {
            let left = order[$0] ?? .max
            let right = order[$1] ?? .max
            return left == right ? $0 < $1 : left < right
        }
    }

    /// Exact physical duplicates can be found through both a RAW and a JPEG
    /// inside one projected item. Coalescing overlapping sets keeps that item
    /// in one review group rather than showing duplicate copies of it.
    private static func mergeOverlapping(
        _ itemSets: [[String]],
        order: [String: Int]
    ) -> [[String]] {
        let identifiers = Set(itemSets.flatMap { $0 }).sorted()
        var sets = DisjointSets(itemIDs: identifiers)
        for itemSet in itemSets where itemSet.count > 1 {
            for identifier in itemSet.dropFirst() {
                sets.union(itemSet[0], identifier)
            }
        }
        return sets.components(minimumCount: 2).map { ordered($0, by: order) }
    }
}

private struct HashPair: Hashable {
    let first: UInt64
    let second: UInt64

    init(_ left: UInt64, _ right: UInt64) {
        first = min(left, right)
        second = max(left, right)
    }
}

/// A tiny deterministic union-find used only for completed review results.
/// It owns stable IDs rather than item indices, so rescan/pairing generation
/// checks remain the authority before a result can reach SwiftUI.
private struct DisjointSets {
    private var parent: [String: String]

    init(itemIDs: [String]) {
        parent = Dictionary(uniqueKeysWithValues: itemIDs.map { ($0, $0) })
    }

    mutating func union(_ left: String, _ right: String) {
        guard let leftRoot = root(of: left), let rightRoot = root(of: right),
              leftRoot != rightRoot else { return }
        if leftRoot < rightRoot {
            parent[rightRoot] = leftRoot
        } else {
            parent[leftRoot] = rightRoot
        }
    }

    mutating func components(minimumCount: Int) -> [[String]] {
        components(minimumCount: minimumCount, checkingCancellation: {})
    }

    mutating func components(
        minimumCount: Int,
        checkingCancellation: () throws -> Void
    ) rethrows -> [[String]] {
        try checkingCancellation()
        var values: [String: [String]] = [:]
        for identifier in parent.keys.sorted() {
            try checkingCancellation()
            guard let root = root(of: identifier) else { continue }
            values[root, default: []].append(identifier)
        }
        let result = values.values
            .filter { $0.count >= minimumCount }
            .map { $0.sorted() }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
        try checkingCancellation()
        return result
    }

    private mutating func root(of identifier: String) -> String? {
        guard let parentID = parent[identifier] else { return nil }
        guard parentID != identifier else { return identifier }
        guard let rootID = root(of: parentID) else { return nil }
        parent[identifier] = rootID
        return rootID
    }
}

/// The Settings field accepts seconds in the current locale, without rounding.
enum CaptureBurstIntervalInput {
    static let range = 0.5...10.0

    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(normalized), value.isFinite, range.contains(value)
        else { return nil }
        return value
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        var text = String(value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
