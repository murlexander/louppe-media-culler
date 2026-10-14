import XCTest
@testable import Louppe

/// Production measurements alongside retained research candidate algorithms.
/// Fixture construction, structural preparation and equivalence checks stay
/// outside measured closures. Run using the opt-in speed benchmark harness.
@MainActor
final class LouppeSpeedScanTests: XCTestCase {
    /// The pure production index accepts an arbitrary item permutation for
    /// metadata sorting. This deliberately disproves a blanket raw-order bucket
    /// shortcut; a production optimization must retain chronological tie order.
    func testMetadataBucketRequiresCanonicalOrder() throws {
        try SpeedBenchmark.requireEnabled()
        for date in [Date?.none, Date(timeIntervalSince1970: 1_700_000_000)] {
            let items = ["Z.JPG", "A.JPG"].map { name in
                PhotoItem(primaryFile: PhotoFile(
                    id: name, url: URL(fileURLWithPath: "/private/tmp/louppe-speed-precondition/\(name)"),
                    captureDate: date, cameraModel: nil, lensModel: nil,
                    fileSize: 1, rating: .yes, starRating: .three, colorLabel: .green
                ))
            }
            for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
                for ascending in [true, false] {
                    let sort = PhotoSort(key: key, ascending: ascending)
                    var production = PreparedSessionIndex()
                    production.rebuildSort(items, sort: sort)
                    XCTAssertEqual(production.sortedIndices, [1, 0])
                    XCTAssertEqual(metadataBucketSort(items, sort: sort), [0, 1])
                    XCTAssertNotEqual(metadataBucketSort(items, sort: sort), production.sortedIndices,
                                      "A raw-order shortcut loses chronological/name ties on uncanonical input")
                    let canonical = FolderScanner.sortItems(items)
                    let normalizedIDs = metadataBucketSort(canonical, sort: sort).map { canonical[$0].id }
                    XCTAssertEqual(normalizedIDs, production.sortedIndices.map { items[$0].id })
                }
            }
        }
    }

    func testPairingWithoutGlobalSort() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "scan-pairing")

        // All ordering and membership boundaries before the large timing runs:
        // independent audio/video/text; extras; ambiguous cross-folder stems;
        // ASCII-only case folding; canonically equivalent Unicode byte names.
        let edgeFiles = [
            "a/IMG_1.NEF", "a/IMG_1.JPG", "b/IMG_1.NEF", "b/IMG_1.jpeg",
            "a/IMG_2.NEF", "b/IMG_2.JPG", "a/IMG_2.PNG", "a/IMG_2.MOV",
            "a/IMG_2.WAV", "a/IMG_2.txt", "a/SHOT.NEF", "a/shot.JPG",
            "a/caf\u{00e9}.NEF", "a/cafe\u{0301}.JPG",
            "a/IMG_10.JPG", "a/IMG_9.JPG", "a/onlyRAW.RAF", "a/onlyJPEG.JPG",
            "a/dotted.stem.CR3", "a/dotted.stem.JPEG",
        ].map { URL(fileURLWithPath: "/private/tmp/louppe-speed-urls/\($0)") }
        for caseSensitive in [true, false] {
            for mode in [RawJPEGPairingMode.separate, .together] {
                let expected = signatures(FolderScanner.pairFiles(
                    edgeFiles, pairingMode: mode, caseSensitiveNames: caseSensitive
                ))
                for seed in [UInt64(1), 17, 9_157] {
                    let shuffled = shuffled(edgeFiles, seed: seed)
                    XCTAssertEqual(signatures(pairFilesWithoutGlobalSort(
                        shuffled, mode: mode, caseSensitive: caseSensitive
                    )), expected)
                }
            }
        }

        for count in SpeedBenchmark.sizes {
            for paired in [false, true] {
                let urls = pairingFixture(count: count, paired: paired)
                let mode: RawJPEGPairingMode = paired ? .together : .separate
                let expected = FolderScanner.pairFiles(
                    urls, pairingMode: mode, caseSensitiveNames: false
                )
                let expectedSignatures = signatures(expected)
                XCTAssertEqual(
                    signatures(pairFilesWithoutGlobalSort(urls, mode: mode, caseSensitive: false)),
                    expectedSignatures
                )
                XCTAssertEqual(
                    expected.reduce(0) { $0 + ($1.paired == nil ? 1 : 2) },
                    count,
                    "No original may disappear from a pairing projection"
                )
                var result: [(primary: URL, paired: URL?)] = []
                let workload = paired ? "raw-jpeg" : "distinct-stems"
                try report.measure(name: "pairing.\(workload).production", count: count) {
                    result = FolderScanner.pairFiles(
                        urls, pairingMode: mode, caseSensitiveNames: false
                    )
                }
                XCTAssertEqual(signatures(result), expectedSignatures)
                try report.measure(name: "pairing.\(workload).no-global-sort", count: count) {
                    result = pairFilesWithoutGlobalSort(urls, mode: mode, caseSensitive: false)
                }
                XCTAssertEqual(signatures(result), expectedSignatures)

                // The same projection also runs on the UI actor while preparing
                // pair-component Clean Up. Include its physical lookup capture.
                let items = urls.map { url in
                    PhotoItem(primaryFile: PhotoFile(
                        id: FolderScanner.fileSystemIdentityPath(for: url), url: url,
                        captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1
                    ))
                }
                var preparedPairs: [(raw: PhotoFile, jpeg: PhotoFile)] = []
                try report.measure(name: "pairing.\(workload).physical-pair-preparation.production", count: count) {
                    preparedPairs = FolderScanner.rawJPEGPairs(
                        from: items, root: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                    )
                }
                XCTAssertEqual(preparedPairs.count, paired ? count / 2 : 0)
                XCTAssertEqual(Set(preparedPairs.flatMap { [$0.raw.id, $0.jpeg.id] }).count,
                               paired ? count : 0)
            }
        }
        try report.finish()
    }

    func testFiniteMetadataBucketSort() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "scan-metadata-sort")
        for count in SpeedBenchmark.sizes {
            // Prepare the structural generation once, as SessionStore does.
            // Metadata edits reuse its validated chronology; the retained raw
            // candidate still requires physically canonical input.
            let items = FolderScanner.sortItems(metadataFixture(count: count))
            XCTAssertEqual(items.count, count)
            XCTAssertTrue(items.contains { $0.captureDate == nil })
            XCTAssertTrue(items.contains { $0.ratingState == .mixed })
            XCTAssertTrue(items.contains { $0.starRatingState == .mixed })
            XCTAssertTrue(items.contains { $0.colorLabelState == .mixed })
            for key in [PhotoSort.Key.decision, .starRating, .colorLabel] {
                for ascending in [true, false] {
                    let sort = PhotoSort(key: key, ascending: ascending)
                    var production = PreparedSessionIndex()
                    production.rebuildItems(items, sort: sort)
                    let expected = items.indices.sorted {
                        sort.areInOrder(items[$0], items[$1])
                    }
                    XCTAssertEqual(production.sortedIndices, expected)
                    XCTAssertEqual(metadataBucketSort(items, sort: sort), expected)
                    XCTAssertEqual(Set(expected).count, count)
                    let direction = ascending ? "ascending" : "descending"
                    let name = "metadata.\(key).\(direction)"
                    try report.measure(name: "\(name).production", count: count) {
                        production.rebuildPreparedSort(items, sort: sort)
                    }
                    XCTAssertEqual(production.sortedIndices, expected)
                    var candidate: [Int] = []
                    try report.measure(name: "\(name).stable-buckets", count: count) {
                        candidate = metadataBucketSort(items, sort: sort)
                    }
                    XCTAssertEqual(candidate, expected)
                }
            }
        }
        try report.finish()
    }

    private struct PairSignature: Equatable {
        let primary: String
        let paired: String?
    }

    private func signatures(_ pairs: [(primary: URL, paired: URL?)]) -> [PairSignature] {
        pairs.map {
            PairSignature(
                primary: FolderScanner.fileSystemIdentityPath(for: $0.primary),
                paired: $0.paired.map(FolderScanner.fileSystemIdentityPath(for:))
            )
        }
    }

    /// Identical to production pairing except that stem grouping receives the
    /// unsorted input. Each group still sorts exact paths, and groups still emit
    /// in exact stem-byte order. Thus the output contract is unchanged.
    private func pairFilesWithoutGlobalSort(
        _ files: [URL], mode: RawJPEGPairingMode, caseSensitive: Bool
    ) -> [(primary: URL, paired: URL?)] {
        var groups: [Data: [URL]] = [:]
        for url in files {
            groups[stemKey(url, caseSensitive: caseSensitive), default: []].append(url)
        }
        var result: [(primary: URL, paired: URL?)] = []
        result.reserveCapacity(files.count)
        for key in groups.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let grouped = groups[key] else { continue }
            let urls = grouped.sorted {
                FolderScanner.fileSystemIdentityPath(for: $0)
                    < FolderScanner.fileSystemIdentityPath(for: $1)
            }
            var independent: [URL] = []
            var images: [URL] = []
            for url in urls {
                if FolderScanner.isVideoExtension(url.pathExtension)
                    || FolderScanner.isAudioExtension(url.pathExtension)
                    || FolderScanner.isTextExtension(url.pathExtension) {
                    independent.append(url)
                } else {
                    images.append(url)
                }
            }
            for url in independent { result.append((url, nil)) }
            let raws = images.filter {
                FolderScanner.rawExtensions.contains($0.pathExtension.lowercased())
            }
            let jpegs = images.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            if mode == .together, raws.count == 1, jpegs.count == 1,
               let raw = raws.first, let jpeg = jpegs.first {
                result.append((raw, jpeg))
                for extra in images where extra != raw && extra != jpeg {
                    result.append((extra, nil))
                }
            } else {
                for url in images { result.append((url, nil)) }
            }
        }
        return result
    }

    private func stemKey(_ url: URL, caseSensitive: Bool) -> Data {
        let bytes = url.withUnsafeFileSystemRepresentation { pointer -> [UInt8] in
            guard let pointer else { return Array(url.path(percentEncoded: true).utf8) }
            var count = 0
            while pointer[count] != 0 { count += 1 }
            return UnsafeBufferPointer(start: pointer, count: count).map(UInt8.init(bitPattern:))
        }
        let start = bytes.lastIndex(of: 47).map { $0 + 1 } ?? bytes.startIndex
        let end = bytes[start...].lastIndex(of: 46) ?? bytes.endIndex
        let stem = bytes[start..<end]
        return caseSensitive ? Data(stem) : Data(stem.map { (65...90).contains($0) ? $0 + 32 : $0 })
    }

    /// Finite ranks exactly copy PhotoSort's ordering semantics. Missing stars
    /// and colors precede Mixed and remain last in either direction. Decision
    /// direction reverses all four decision buckets.
    private func metadataBucketSort(_ items: [PhotoItem], sort: PhotoSort) -> [Int] {
        let metadata = items.map(\.metadataState)
        var buckets = Array(repeating: [Int](), count: sort.key == .decision ? 4 : 7)
        for index in items.indices {
            let rank: Int
            switch sort.key {
            case .decision:
                let natural: Int
                switch metadata[index].decision {
                case .yes: natural = 0
                case .undecided: natural = 1
                case .mixed: natural = 2
                case .no: natural = 3
                }
                rank = sort.ascending ? natural : 3 - natural
            case .starRating:
                switch metadata[index].stars {
                case .stars(let value): rank = sort.ascending ? value.count - 1 : 5 - value.count
                case .unrated: rank = 5
                case .mixed: rank = 6
                }
            case .colorLabel:
                switch metadata[index].color {
                case .label(let label):
                    let natural = PhotoColorLabel.allCases.firstIndex(of: label)!
                    rank = sort.ascending ? natural : 4 - natural
                case .none: rank = 5
                case .mixed: rank = 6
                }
            default:
                preconditionFailure("Only finite review metadata sorts are covered")
            }
            buckets[rank].append(index)
        }
        var result: [Int] = []
        result.reserveCapacity(items.count)
        for bucket in buckets { result.append(contentsOf: bucket) }
        return result
    }

    private func pairingFixture(count: Int, paired: Bool) -> [URL] {
        let urls = (0..<count).map { index in
            let stem = paired ? index / 2 : index
            let ext = paired && index.isMultiple(of: 2) ? "NEF" : "JPG"
            return URL(fileURLWithPath: String(format:
                "/private/tmp/louppe-speed-urls/folder-%02d/IMG_%06d.%@", stem % 25, stem, ext
            ))
        }
        return shuffled(urls, seed: 79_843)
    }

    private func metadataFixture(count: Int) -> [PhotoItem] {
        let equalNames = ["IMG_2", "IMG_10", "caf\u{00e9}", "cafe\u{0301}", "Same", "same"]
        return (0..<count).map { index in
            let filename = equalNames[index % equalNames.count] + ".JPG"
            let url = URL(fileURLWithPath: "/private/tmp/louppe-speed-metadata/folder-\(index)/\(filename)")
            let date = index.isMultiple(of: 7) ? nil : Date(timeIntervalSince1970: 1_700_000_000 + Double(index % 31))
            let rating: Rating = index % 3 == 0 ? .yes : (index % 3 == 1 ? .no : .undecided)
            let stars = index.isMultiple(of: 6) ? nil : StarRating.allCases[index % 5]
            let color = index.isMultiple(of: 6) ? nil : PhotoColorLabel.allCases[index % 5]
            let primary = PhotoFile(
                id: url.path(percentEncoded: true), url: url,
                captureDate: date, cameraModel: nil, lensModel: nil, fileSize: 1,
                rating: rating, starRating: stars, colorLabel: color
            )
            var partner: PhotoFile?
            if index.isMultiple(of: 4) {
                let partnerURL = url.deletingPathExtension().appendingPathExtension("RAF")
                let mixed = index.isMultiple(of: 8)
                partner = PhotoFile(
                    id: partnerURL.path(percentEncoded: true), url: partnerURL,
                    captureDate: date, cameraModel: nil, lensModel: nil, fileSize: 1,
                    rating: mixed ? (rating == .yes ? .no : .yes) : rating,
                    starRating: mixed ? (stars == .one ? .five : .one) : stars,
                    colorLabel: mixed ? (color == .red ? .purple : .red) : color
                )
            }
            return PhotoItem(primaryFile: primary, pairedFile: partner)
        }
    }

    private func shuffled<T>(_ input: [T], seed: UInt64) -> [T] {
        var result = input
        guard result.count > 1 else { return result }
        var state = seed
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result.swapAt(index, Int(state % UInt64(index + 1)))
        }
        return result
    }
}
