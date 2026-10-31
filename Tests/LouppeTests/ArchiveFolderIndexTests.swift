import Foundation
import XCTest
@testable import Louppe

final class ArchiveFolderIndexTests: XCTestCase {
    private let syntheticRoot = URL(fileURLWithPath: "/archive", isDirectory: true)

    func testDiscoveryRetainsEmptyDirectoriesButExcludesHiddenPackagesAndSymlinks() throws {
        let root = try fixture(["shoot/A.JPG", "shoot/nested/B.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["empty", ".hidden", "Library.photoslibrary"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("shoot"))
        let inventory = try FolderScanner.discoverInventory(root)
        XCTAssertEqual(Set(inventory.directories.map(\.id)), ["", "empty", "shoot", "shoot/nested"])
        XCTAssertTrue(inventory.directories.allSatisfy { $0.identity != nil })
        let index = ArchiveFolderIndex(root: root, directories: inventory.directories, items: inventory.items)
        XCTAssertEqual(index.node(for: "empty")?.subtreeCount, 0)
        XCTAssertEqual(index.node(for: "")?.subtreeCount, 2)
        XCTAssertEqual(index.node(for: "shoot")?.directCount, 1)
        try FolderScanner.validateDirectories(in: inventory)
    }

    func testNaturalSiblingOrderingPrefixIsolationAndExactDirectScope() {
        let items = [photo("root.JPG"), photo("2/A.JPG"), photo("2/nested/B.JPG"),
                     photo("20/C.JPG"), photo("10/D.JPG")]
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [], items: items)
        XCTAssertEqual(index.children(of: ""), ["2", "10", "20"])
        XCTAssertEqual(index.itemIndices(in: "2", includingDescendants: false), [1])
        XCTAssertEqual(Set(index.itemIndices(in: "2", includingDescendants: true)), [1, 2])
        XCTAssertEqual(index.itemIndices(in: "20", includingDescendants: true), [3])
        XCTAssertEqual(index.itemIndices(in: "", includingDescendants: false), [0])
        XCTAssertEqual(index.itemIndices(in: "", includingDescendants: true), Array(items.indices))
        XCTAssertTrue(index.itemIndices(in: "missing", includingDescendants: true).isEmpty)
        XCTAssertEqual(index.breadcrumbs(to: "2/nested").map(\.id), ["", "2", "2/nested"])
    }

    func testSkippedEntriesCannotHideFollowingSiblingAndMediaNamedDirectoryRemainsAFolder() throws {
        let root = try fixture(["B-folder/nested/A.JPG", "C-folder.JPG/nested/B.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A-package.app"),
            withIntermediateDirectories: true)
        try Data("package contents are excluded".utf8).write(to:
            root.appendingPathComponent("A-package.app/hidden.JPG"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("A-link"),
            withDestinationURL: root.appendingPathComponent("B-folder"))
        // A back-link would loop if FileManager followed directory symlinks.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("B-folder/back"),
            withDestinationURL: root)
        let inventory = try FolderScanner.discoverInventory(root)
        XCTAssertEqual(Set(inventory.items.map(\.id)), ["B-folder/nested/A.JPG", "C-folder.JPG/nested/B.JPG"])
        XCTAssertEqual(Set(inventory.directories.map(\.id)),
                       ["", "B-folder", "B-folder/nested", "C-folder.JPG", "C-folder.JPG/nested"])
        XCTAssertFalse(inventory.items.contains { $0.id == "C-folder.JPG" },
            "recognized file extensions do not turn directory entries into media")
        try FolderScanner.validateDirectories(in: inventory)
    }

    func testUnicodeEquivalentDisplayNamesAndLiteralPercentPathsStayDistinct() {
        let first = "Caf%C3%A9", second = "Cafe%CC%81", literal = "Caf%25C3%25A9"
        let directories = [directory(first, name: "Caf\u{00e9}"), directory(second, name: "Cafe\u{0301}"),
                           directory(literal, name: "Caf%C3%A9")]
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: directories,
            items: [photo("\(first)/A.JPG"), photo("\(second)/B.JPG"), photo("\(literal)/C.JPG")])
        XCTAssertEqual(index.nodes.count, 4)
        for (id, offset) in [(first, 0), (second, 1), (literal, 2)] {
            XCTAssertEqual(index.itemIndices(in: id, includingDescendants: true), [offset])
            XCTAssertEqual(index.node(for: id)?.subtreeCount, 1)
        }
    }

    func testCrossFolderPairsCountOnceAtSharedAncestorsAndBelongToEitherParent() {
        let pair = PhotoItem(primaryFile: file("shoot/raw/A.NEF"), pairedFile: file("shoot/jpeg/A.JPG"))
        let nestedPair = PhotoItem(primaryFile: file("shoot/B.NEF"), pairedFile: file("shoot/jpeg/B.JPG"))
        let sameParentPair = PhotoItem(primaryFile: file("shoot/raw/C.NEF"), pairedFile: file("shoot/raw/C.JPG"))
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [], items: [pair, nestedPair, sameParentPair])
        XCTAssertEqual(index.node(for: "")?.subtreeCount, 3)
        XCTAssertEqual(index.node(for: "shoot")?.subtreeCount, 3)
        XCTAssertEqual(index.node(for: "shoot")?.directCount, 1)
        XCTAssertEqual(index.node(for: "shoot/raw")?.directCount, 2)
        XCTAssertEqual(Set(index.itemIndices(in: "shoot/jpeg", includingDescendants: false)), [0, 1])
        XCTAssertEqual(Set(index.itemIndices(in: "shoot", includingDescendants: true)), [0, 1, 2])
    }

    func testReprojectionRetainsScannedEmptyFoldersAndInfersNewParentsWithoutIdentity() {
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [directory("empty")],
            items: [photo("old/A.JPG")])
        let moved = index.reproject(items: [photo("new/nested/A.JPG")])
        XCTAssertNotEqual(index.generation, moved.generation)
        XCTAssertEqual(moved.node(for: "empty")?.subtreeCount, 0)
        XCTAssertEqual(moved.node(for: "old")?.subtreeCount, 0)
        XCTAssertNil(moved.node(for: "new")?.identity)
        XCTAssertEqual(moved.itemIndices(in: "new", includingDescendants: true), [0])
        XCTAssertEqual(moved.node(for: "")?.subtreeCount, 1)
    }

    func testManifestRejectsReplacedEmptyDirectoryEvenWithoutAnyMedia() throws {
        let root = try fixture([])
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let inventory = try FolderScanner.discoverInventory(root)
        try FileManager.default.moveItem(at: empty, to: root.appendingPathComponent("old-empty"))
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try FolderScanner.validateDirectories(in: inventory))
    }

    func testDirectoryContentsTimestampDoesNotChangeStableDirectoryIdentity() throws {
        let root = try fixture(["shoot/A.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let inventory = try FolderScanner.discoverInventory(root)
        try Data("new unrelated contents".utf8).write(to: root.appendingPathComponent("shoot/readme.unknown"))
        XCTAssertNoThrow(try FolderScanner.validateDirectories(in: inventory))
    }

    func testDirectoryReplacementDuringMetadataCannotReturnReadyItems() throws {
        let root = try fixture(["A.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let inventory = try FolderScanner.discoverInventory(root)
        XCTAssertThrowsError(try FolderScanner.prepareMetadata(in: inventory,
            beforeFinalIdentityValidation: {
                try FileManager.default.moveItem(at: empty, to: root.appendingPathComponent("old-empty"))
                try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            }, metadataReaderForTesting: { _ in MetadataExtractor.ScanInfo() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".louppe_session.json").path))
    }

    func testCancellationDuringDirectoryDiscoveryAndValidationStopsWithoutSidecarWrites() throws {
        let root = try fixture(["shoot/A.JPG", "other/B.JPG"])
        defer { try? FileManager.default.removeItem(at: root) }
        let flag = FolderScanner.CancelFlag()
        XCTAssertThrowsError(try FolderScanner.discoverInventory(root, isCancelled: { flag.isSet },
            beforeEnumeratingURLForTesting: { _ in flag.set() }))
        let inventory = try FolderScanner.discoverInventory(root)
        XCTAssertThrowsError(try FolderScanner.validateDirectories(in: inventory, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".louppe_session.json").path))
    }

    func testScopedPreparedFilterKeepsSortGroupsAndRejectsInvalidOrDuplicateIndices() {
        let items = [photo("a/Z.JPG", date: 30), photo("b/A.JPG", date: 10),
                     photo("a/B.JPG", date: 20), photo("b/C.JPG", date: 40)]
        for key in [PhotoSort.Key.captureDate, .name, .folderHierarchy, .decision, .camera] {
            for ascending in [true, false] {
                let sort = PhotoSort(key: key, ascending: ascending)
                var index = PreparedSessionIndex()
                index.rebuildItems(items, sort: sort)
                let expected = index.sortedIndices.filter { [0, 2].contains($0) }
                index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true,
                    candidateIndices: [2, -1, 0, 2, 400])
                XCTAssertEqual(index.visibleIndices, expected)
                XCTAssertEqual(index.visibleGroups.flatMap(\.indices), expected)
                XCTAssertEqual(index.visibleEntries.map(\.index), expected)
                XCTAssertNil(index.location(forItemIndex: 1))
                index.applyFilter(PhotoFilter(), to: items, sort: sort, isGroupingEnabled: true, candidateIndices: [])
                XCTAssertTrue(index.visibleIndices.isEmpty)
            }
        }
    }

    func testDeepHierarchyDoesNotRequireRecursiveTraversalOrExpandedMembershipLists() {
        let id = Array(repeating: "deep", count: 512).joined(separator: "/")
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [], items: [photo("\(id)/A.JPG")])
        XCTAssertEqual(index.nodes.count, 513)
        XCTAssertEqual(index.breadcrumbs(to: id).count, 513)
        XCTAssertEqual(index.node(for: "deep")?.subtreeCount, 1)
        XCTAssertEqual(index.itemIndices(in: id, includingDescendants: true), [0])
    }

    func testHundredThousandItemScopeUsesPreparedMembershipAndSortRanks() {
        let items = (0..<100_000).map { photo("folder\($0 / 100)/photo\($0).JPG", date: Double($0)) }
        let start = ProcessInfo.processInfo.systemUptime
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [], items: items)
        let preparedAt = ProcessInfo.processInfo.systemUptime
        var prepared = PreparedSessionIndex()
        prepared.rebuildItems(items, sort: PhotoSort())
        let queryStart = ProcessInfo.processInfo.systemUptime
        for offset in stride(from: 0, to: 1_000, by: 5) {
            let candidates = index.itemIndices(in: "folder\(offset)", includingDescendants: true)
            XCTAssertEqual(candidates.count, 100)
            prepared.applyFilter(PhotoFilter(), to: items, sort: PhotoSort(), isGroupingEnabled: false,
                candidateIndices: candidates)
            XCTAssertEqual(prepared.visibleIndices.count, 100)
            XCTAssertEqual(prepared.visibleIndices.first, offset * 100)
        }
        print("Archive folder index 100k: prepare \(preparedAt - start)s; 200 scoped filter queries \(ProcessInfo.processInfo.systemUptime - queryStart)s")
        XCTAssertEqual(index.node(for: "")?.subtreeCount, 100_000)
        XCTAssertEqual(index.nodes.count, 1_001)
    }

    func testFolderProgressCountsCrossFolderPairsOnceAtSharedAncestors() {
        // A pair split across raw/ and jpeg/ belongs to both folders, but
        // counts once at shoot/ and All Media, exactly like the item counts.
        let pair = PhotoItem(primaryFile: file("shoot/raw/A.NEF"), pairedFile: file("shoot/jpeg/A.JPG"))
        let jpegOnly = photo("shoot/jpeg/B.JPG")
        let other = photo("other/C.JPG")
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [directory("empty")],
                                       items: [pair, jpegOnly, other])
        var reviewed: Set<Int> = []
        let progress = ArchiveFolderProgress(index: index) { reviewed.contains($0) }
        func count(_ id: String, _ descendants: Bool = true) -> Int {
            progress.reviewedCount(for: id, includesDescendants: descendants, index: index)
        }
        XCTAssertEqual(count(""), 0)
        XCTAssertTrue(progress.set(item: 0, reviewed: true, index: index))
        XCTAssertFalse(progress.set(item: 0, reviewed: true, index: index), "repeated state is a no-op")
        XCTAssertEqual(count("shoot/raw"), 1)
        XCTAssertEqual(count("shoot/jpeg"), 1)
        XCTAssertEqual(count("shoot"), 1, "a split pair counts once at the shared parent")
        XCTAssertEqual(count(""), 1)
        XCTAssertTrue(progress.isComplete("shoot/raw", includesDescendants: true, index: index))
        XCTAssertFalse(progress.isComplete("shoot/jpeg", includesDescendants: true, index: index))
        XCTAssertFalse(progress.isComplete("shoot", includesDescendants: true, index: index))
        XCTAssertFalse(progress.isComplete("empty", includesDescendants: true, index: index), "empty folders are never complete")
        progress.set(item: 1, reviewed: true, index: index)
        XCTAssertTrue(progress.isComplete("shoot", includesDescendants: true, index: index))
        XCTAssertFalse(progress.isComplete("shoot", includesDescendants: false, index: index),
                       "direct mode: shoot has no direct media")
        XCTAssertFalse(progress.isComplete("", includesDescendants: true, index: index))
        progress.set(item: 2, reviewed: true, index: index)
        XCTAssertTrue(progress.isComplete("", includesDescendants: false, index: index), "All Media always includes subfolders")
        progress.set(item: 0, reviewed: false, index: index)
        XCTAssertEqual(count("shoot"), 1)
        XCTAssertEqual(count(""), 2)
        XCTAssertFalse(progress.isComplete("shoot/raw", includesDescendants: true, index: index))
        let rebuilt = ArchiveFolderProgress(index: index) { $0 != 0 }
        for id in index.orderedFolderIDs {
            for descendants in [true, false] {
                XCTAssertEqual(rebuilt.reviewedCount(for: id, includesDescendants: descendants, index: index),
                               count(id, descendants), "incremental and rebuilt counts agree for \(id)")
            }
        }
        let replaced = index.reproject(items: [pair, jpegOnly, other])
        XCTAssertFalse(progress.set(item: 0, reviewed: true, index: replaced), "a replaced index is rejected")
        XCTAssertEqual(index.url(for: "shoot/raw")?.path, syntheticRoot.appendingPathComponent("shoot/raw").path)
        XCTAssertNil(index.url(for: "missing"))
    }

    func testFolderProgressStaysLinearInDepthIncludingDeepSplitPairs() {
        var path = "d0"
        for level in 1..<200 { path += "/d\(level)" }
        var items = (0..<2_000).map { photo(path + "/IMG_\($0).JPG") }
        items.append(PhotoItem(primaryFile: file(path + "/raw/P.NEF"), pairedFile: file(path + "/jpeg/P.JPG")))
        let index = ArchiveFolderIndex(root: syntheticRoot, directories: [], items: items)
        let clock = ContinuousClock()
        var progress: ArchiveFolderProgress!
        let elapsed = clock.measure { progress = ArchiveFolderProgress(index: index) { _ in true } }
        XCTAssertLessThan(elapsed, .seconds(1), "init is O(items × depth), not quadratic in depth")
        XCTAssertEqual(progress.reviewedCount(for: "", includesDescendants: true, index: index), 2_001)
        XCTAssertEqual(progress.reviewedCount(for: path, includesDescendants: true, index: index), 2_001,
                       "the deep split pair counts once at its shared parent")
        XCTAssertTrue(progress.isComplete(path + "/raw", includesDescendants: true, index: index))
    }

    private func directory(_ id: String, name: String? = nil) -> ArchiveFolderIndex.Directory {
        .init(id: id, parentID: id.lastIndex(of: "/").map { String(id[..<$0]) } ?? "",
              name: name ?? (id as NSString).lastPathComponent)
    }

    private func photo(_ id: String, date: Double = 0) -> PhotoItem { PhotoItem(primaryFile: file(id, date: date)) }

    private func file(_ id: String, date: Double = 0) -> PhotoFile {
        PhotoFile(id: id, url: URL(string: syntheticRoot.absoluteString + id)!,
                  captureDate: Date(timeIntervalSince1970: date), cameraModel: nil, lensModel: nil, fileSize: 1)
    }

    private func fixture(_ paths: [String]) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-folder-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("disposable image fixture".utf8).write(to: url)
        }
        return root
    }
}
