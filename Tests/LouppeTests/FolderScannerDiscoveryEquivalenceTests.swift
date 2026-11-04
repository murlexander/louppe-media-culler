import Darwin
import Foundation
import XCTest
@testable import Louppe

/// The name-first discovery walk must reproduce the FileManager enumerator it
/// replaced byte for byte: saved decisions key on these IDs, URLs and
/// identities, so any drift would silently detach a photographer's ratings.
final class FolderScannerDiscoveryEquivalenceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            // Restore permissions and flags so cleanup can remove everything.
            if let walker = FileManager.default.enumerator(atPath: root.path) {
                for case let relative as String in walker {
                    let path = root.appendingPathComponent(relative).path
                    chmod(path, 0o755)
                }
            }
            chmod(root.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
    }

    // MARK: Equivalence

    func testAdversarialNamesHiddenEntriesLinksPackagesAndPairsMatchEnumerator() throws {
        let root = try makeRoot()
        try buildAdversarialTree(at: root)
        for mode in [RawJPEGPairingMode.separate, .together] {
            let new = try FolderScanner.discoverInventory(root, pairingMode: mode)
            let old = try FolderScanner.legacyEnumeratorInventoryForTesting(root, pairingMode: mode)
            try assertEquivalent(new, old)
            XCTAssertGreaterThan(new.physicalFileCount, 20)
        }
        let ids = Set(try FolderScanner.discoverInventory(root).items.flatMap(\.individualFiles).map(\.id))
        // FSKit exFAT lists composed names decomposed; APFS keeps both.
        let composed = fixtureParent == "/private/tmp" ? "%C3%A9" : "e%CC%81"
        XCTAssertTrue(ids.contains("nfc/Caf\(composed).jpg"))
        XCTAssertTrue(ids.contains("nfd/Cafe%CC%81.jpg"))
        XCTAssertTrue(ids.contains("Dir\(composed)/in.jpg"))
        XCTAssertTrue(ids.contains("semi%3Bcolon%20dir/in%3Bside.NEF"))
        XCTAssertTrue(ids.contains("shoot/A.NEF"))
        if fixtureParent == "/private/tmp" { XCTAssertTrue(ids.contains("hardlink.NEF")) }
        for excluded in [".dot.jpg", "uf-hidden.jpg", "invisible.jpg", "link-file.jpg", "fifo.jpg",
                         "Foo.app/x.jpg", "Bundle.bundle/y.jpg", "bundlebit/z.jpg", "uf-hidden-dir/u.jpg",
                         "invisible-dir/v.jpg", ".dotdir/d.jpg"] {
            XCTAssertFalse(ids.contains(excluded), excluded)
        }
        XCTAssertTrue(ids.contains("folder.JPG/inner/C.jpg"), "a media-named folder stays a folder")
    }

    /// Pairing was optimized on 30 October 2026: indexed candidates, shared
    /// root prefixes and parallel record construction. Full inventories must
    /// equal the previous pairing code: pairs, IDs, item order, every field.
    func testOptimizedPairingMatchesPreviousPairingExactly() throws {
        let root = try makeRoot()
        try buildAdversarialTree(at: root)
        try buildArchiveShapedTree(at: root, sessions: 48)
        for mode in [RawJPEGPairingMode.separate, .together] {
            let new = try FolderScanner.discoverInventory(root, pairingMode: mode)
            let old = try FolderScanner.legacyEnumeratorInventoryForTesting(root, pairingMode: mode,
                                                                             usesLegacyPairing: true)
            XCTAssertGreaterThan(new.physicalFileCount, 1_000, "large enough for parallel construction")
            try assertEquivalent(new, old, context: "\(mode)")
            XCTAssertEqual(new.items.flatMap(\.individualFiles).map(\.id),
                           old.items.flatMap(\.individualFiles).map(\.id), "\(mode)")
            XCTAssertEqual(new.items.map(\.fileTypeLabel), old.items.map(\.fileTypeLabel), "\(mode)")
            XCTAssertEqual(new.items.map(\.searchableText), old.items.map(\.searchableText), "\(mode)")
            XCTAssertEqual(new.items.map(\.contentRevision), old.items.map(\.contentRevision), "\(mode)")
            XCTAssertGreaterThan(new.rawJPEGFileIDs.count, 20, "\(mode)")
            if mode == .together {
                XCTAssertGreaterThan(new.items.filter { $0.pairedFile != nil }.count, 20)
            }
        }
        // Projection between modes uses the same pairing.
        let separate = try FolderScanner.discoverInventory(root, pairingMode: .separate)
        let projected = try FolderScanner.projectPairingMode(.together, from: separate.items, root: root,
                                                             loadMissingMetadata: false)
        let reference = FolderScanner.sortItems(try FolderScanner.legacyEnumeratorInventoryForTesting(
            root, pairingMode: .together, usesLegacyPairing: true).items)
        XCTAssertEqual(projected.items.map(\.id), reference.map(\.id))
        XCTAssertEqual(projected.items.map { $0.pairedFile?.id }, reference.map { $0.pairedFile?.id })
    }

    func testRootSpellingsMatchEnumerator() throws {
        let root = try makeRoot()
        try buildAdversarialTree(at: root)
        let physical = root.path
        let logical = physical.hasPrefix("/private/tmp/") ? String(physical.dropFirst("/private".count)) : physical
        let upper = (physical as NSString).deletingLastPathComponent + "/"
            + root.lastPathComponent.uppercased()
        for spelling in [
            URL(fileURLWithPath: physical, isDirectory: true),
            URL(fileURLWithPath: physical, isDirectory: false),
            URL(fileURLWithPath: logical, isDirectory: true),
            URL(fileURLWithPath: logical + "/./"),
            URL(fileURLWithPath: upper, isDirectory: true),
            URL(fileURLWithPath: physical + "/shoot/.."),
        ] {
            try assertEquivalent(try FolderScanner.discoverInventory(spelling),
                                 try FolderScanner.legacyEnumeratorInventoryForTesting(spelling),
                                 context: spelling.absoluteString)
        }
    }

    func testRandomNanosecondTimestampsAndSizesMatchFoundationResourceValues() throws {
        let root = try makeRoot()
        var generator = SystemRandomNumberGenerator()
        // exFAT and FAT store dates from 1980 onward.
        let earliest = fixtureParent == "/private/tmp" ? -400_000_000 : 400_000_000
        for index in 0..<400 {
            let path = root.appendingPathComponent("T\(index).JPG").path
            try Data(repeating: 1, count: index % 13).write(to: URL(fileURLWithPath: path))
            var times = [
                timespec(tv_sec: Int.random(in: earliest...2_100_000_000, using: &generator),
                         tv_nsec: Int.random(in: 0..<1_000_000_000, using: &generator)),
                timespec(tv_sec: Int.random(in: earliest...2_100_000_000, using: &generator),
                         tv_nsec: Int.random(in: 0..<1_000_000_000, using: &generator)),
            ]
            XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
            var request = attrlist()
            request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var birth = timespec(tv_sec: Int.random(in: earliest...2_100_000_000, using: &generator),
                                 tv_nsec: Int.random(in: 0..<1_000_000_000, using: &generator))
            XCTAssertEqual(setattrlist(path, &request, &birth, MemoryLayout<timespec>.size, 0), 0)
        }
        try assertEquivalent(try FolderScanner.discoverInventory(root),
                             try FolderScanner.legacyEnumeratorInventoryForTesting(root))
    }

    func testDeepNestingAndManyFoldersProduceDeterministicEnumeratorOrder() throws {
        let root = try makeRoot()
        var deep = root
        for level in 0..<48 {
            deep.appendPathComponent("level \(level)", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data().write(to: deep.appendingPathComponent("D\(level).NEF"))
        }
        for folder in 0..<60 {
            let wide = root.appendingPathComponent("wide-\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: wide.appendingPathComponent("empty"),
                                                    withIntermediateDirectories: true)
            for file in 0..<(folder % 7) {
                try Data().write(to: wide.appendingPathComponent("W\(folder)-\(file).JPG"))
            }
        }
        let old = try FolderScanner.legacyEnumeratorInventoryForTesting(root)
        for _ in 0..<5 {
            try assertEquivalent(try FolderScanner.discoverInventory(root), old)
        }
    }

    // MARK: Errors

    func testUnreadableSubfoldersAndRootsRaiseTheSameErrorAsEnumerator() throws {
        let fm = FileManager.default
        for permissions: mode_t in [0o000, 0o100, 0o400] {
            let root = try makeRoot()
            try fm.createDirectory(at: root.appendingPathComponent("A/Locked"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("A/Locked/x.jpg"))
            try Data().write(to: root.appendingPathComponent("A/ok.jpg"))
            XCTAssertEqual(chmod(root.appendingPathComponent("A/Locked").path, permissions), 0)
            try assertSameFailure(root, context: "subfolder \(String(permissions, radix: 8))")

            let lockedRoot = try makeRoot()
            try fm.createDirectory(at: lockedRoot.appendingPathComponent("A"), withIntermediateDirectories: true)
            try Data().write(to: lockedRoot.appendingPathComponent("A/x.jpg"))
            XCTAssertEqual(chmod(lockedRoot.path, permissions), 0)
            try assertSameFailure(lockedRoot, context: "root \(String(permissions, radix: 8))")
        }
    }

    func testSymbolicLinkAndFileRootsRaiseTheSameErrorAsEnumerator() throws {
        let target = try makeRoot()
        try Data().write(to: target.appendingPathComponent("A.JPG"))
        let holder = try makeRoot()
        let link = holder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try assertSameFailure(URL(fileURLWithPath: link.path, isDirectory: true), context: "link root")
        try assertSameFailure(URL(fileURLWithPath: link.path, isDirectory: false), context: "link root, no slash")
        try assertSameFailure(target.appendingPathComponent("A.JPG"), context: "file root")
    }

    func testMissingRootFailsBeforeTraversalLikeEnumerator() throws {
        let missing = try makeRoot().appendingPathComponent("missing", isDirectory: true)
        var new: Error?
        var old: Error?
        XCTAssertThrowsError(try FolderScanner.discoverInventory(missing)) { new = $0 }
        XCTAssertThrowsError(try FolderScanner.legacyEnumeratorInventoryForTesting(missing)) { old = $0 }
        XCTAssertEqual(String(reflecting: new), String(reflecting: old))
    }

    // MARK: Cancellation, progress, hooks

    func testCancellationDuringTheWalkStopsWithCancellationError() throws {
        let root = try makeRoot()
        for folder in 0..<40 {
            let url = root.appendingPathComponent("f\(folder)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in 0..<30 { try Data().write(to: url.appendingPathComponent("\(file).JPG")) }
        }
        let polls = DiscoveryPollCounter()
        XCTAssertThrowsError(try FolderScanner.discoverInventory(root, isCancelled: { polls.increment() > 2 })) {
            XCTAssertTrue($0 is CancellationError, String(describing: $0))
        }
        let flag = FolderScanner.CancelFlag()
        XCTAssertThrowsError(try FolderScanner.discoverInventory(root, isCancelled: { flag.isSet },
            progress: { _ in flag.set() })) {
            XCTAssertTrue($0 is CancellationError, String(describing: $0))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".louppe_session.json").path))
    }

    func testProgressIsCoalescedMonotonicAndFinalAndRecorderMatches() throws {
        let root = try makeRoot()
        for folder in 0..<12 {
            let url = root.appendingPathComponent("f\(folder)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in 0..<53 { try Data().write(to: url.appendingPathComponent("\(file).JPG")) }
        }
        var reported: [Int] = []
        let recorder = SessionOpeningRecorder()
        let inventory = try FolderScanner.discoverInventory(root, recorder: recorder, progress: { reported.append($0) })
        XCTAssertEqual(inventory.physicalFileCount, 636)
        XCTAssertEqual(reported.last, 636)
        XCTAssertEqual(reported, reported.sorted())
        XCTAssertTrue(reported.dropLast().allSatisfy { $0 % 25 == 0 && $0 > 0 }, "\(reported)")
    }

    func testHookSeesEveryIncludedFolderAndMediaFileInEnumeratorOrder() throws {
        let root = try makeRoot()
        try buildAdversarialTree(at: root)
        var seen: [URL] = []
        let inventory = try FolderScanner.discoverInventory(root, beforeEnumeratingURLForTesting: { seen.append($0) })
        XCTAssertEqual(seen.count, inventory.physicalFileCount + inventory.directories.count - 1)
        let folderURLs = seen.filter { $0.hasDirectoryPath }
        let seenFolderIDs: [String] = folderURLs.map { url in
            String(FolderScanner.relativeFileIdentity(of: url, under: root).dropLast())
        }
        let inventoryFolderIDs: [String] = inventory.directories.dropFirst().map { $0.id }
        XCTAssertEqual(seenFolderIDs, inventoryFolderIDs)
    }

    // MARK: App-managed cache folders

    func testCaptureOneCacheAndLightroomDataFoldersAreSkippedOnlyWithEvidence() throws {
        let root = try makeRoot()
        let fm = FileManager.default
        func file(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        func folder(_ path: String) throws {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // Capture One session: originals stay, the app's cache folder goes.
        try file("session/Capture/S1.NEF")
        try file("session/Capture/S1.JPG")
        try file("session/Capture/CaptureOne/Cache/Proxies/S1.NEF.cop")
        try file("session/Capture/CaptureOne/Cache/Thumbnails/P1.JPG")
        try file("session/Capture/CaptureOne/Settings153/S1.NEF.cos")
        try file("session/Capture/CaptureOne/.DS_Store")
        try file("session/Selects/S2.JPG")
        try file("session/Output/CaptureOne/Cache/P2.tif")
        try file("session/session.cosessiondb")
        // Case-insensitive name, Settings with digits only.
        try file("lower/captureone/Settings1680/P3.dng")
        // User folders that share the name are kept.
        try file("user1/CaptureOne/U1.JPG")
        try file("user1/CaptureOne/Cache/U2.JPG")
        try folder("user2/CaptureOne")
        try file("user3/CaptureOne/SettingsBackup/U3.JPG")
        try file("user4/CaptureOne/Cache.JPG")
        try file("user5/CaptureOne/notes.txt")
        try folder("user5/CaptureOne/Cache")
        // Lightroom Classic data folders, any case.
        try file("lr/Catalog Smart Previews.lrdata/A/B/L1.dng")
        try file("lr/Catalog Previews.LRDATA/L2.JPG")
        try file("lr/Catalog.lrcat")
        try file("lr/notes.lrdata.txt")

        let new = try FolderScanner.discoverInventory(root)
        let old = try FolderScanner.legacyEnumeratorInventoryForTesting(root)
        let skipped = ["session/Capture/CaptureOne", "session/Output/CaptureOne", "lower/captureone",
                       "lr/Catalog%20Smart%20Previews.lrdata", "lr/Catalog%20Previews.LRDATA"]
        try assertEquivalent(new, old, skippingFolders: skipped)
        let ids = Set(new.items.flatMap(\.individualFiles).map(\.id))
        XCTAssertEqual(ids, ["session/Capture/S1.NEF", "session/Capture/S1.JPG", "session/Selects/S2.JPG",
                             "user1/CaptureOne/U1.JPG", "user1/CaptureOne/Cache/U2.JPG",
                             "user3/CaptureOne/SettingsBackup/U3.JPG", "user4/CaptureOne/Cache.JPG",
                             "user5/CaptureOne/notes.txt", "lr/notes.lrdata.txt"])
        let folders = Set(new.directories.map(\.id))
        XCTAssertTrue(folders.isDisjoint(with: skipped))
        XCTAssertTrue(folders.isSuperset(of: ["user2/CaptureOne", "user5/CaptureOne/Cache", "session/Output"]))
        try FolderScanner.validateDirectories(in: new)
    }

    func testAppManagedFolderRuleIsSmallAndExplicit() {
        let c1: [(name: String, isDirectory: Bool)] = [("Cache", true), ("Settings153", true)]
        XCTAssertTrue(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: c1))
        XCTAssertTrue(FolderScanner.isAppManagedCacheFolder(name: "CAPTUREONE", visibleChildren: [("cache", true)]))
        XCTAssertTrue(FolderScanner.isAppManagedCacheFolder(name: "x.lrdata", visibleChildren: nil))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: nil))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: []))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: c1 + [("A.JPG", false)]))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: [("Settings", true)]))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: [("Settings15a", true)]))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "CaptureOne", visibleChildren: [("Cache", false)]))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "Capture One", visibleChildren: c1))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "Cache", visibleChildren: c1))
        XCTAssertFalse(FolderScanner.isAppManagedCacheFolder(name: "lrdata", visibleChildren: nil))
    }

    // MARK: Opt-in archive comparison (read-only)

    /// Set LOUPPE_DISCOVERY_EQUIVALENCE_ROOT to a folder to compare both
    /// implementations on it. Both only read: no sidecar, cache or index is
    /// written. Prints timings and counts.
    func testOptInFolderMatchesEnumeratorApartFromSkippedAppFolders() throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_DISCOVERY_EQUIVALENCE_ROOT"] else {
            throw XCTSkip("Set LOUPPE_DISCOVERY_EQUIVALENCE_ROOT to compare a real folder.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let order = ProcessInfo.processInfo.environment["LOUPPE_DISCOVERY_EQUIVALENCE_ORDER"] ?? "new-first"
        func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try body()
            return (value, ProcessInfo.processInfo.systemUptime - start)
        }
        let new: (FolderScanner.Inventory, Double)
        let old: (FolderScanner.Inventory, Double)
        if order == "old-first" {
            old = try time { try FolderScanner.legacyEnumeratorInventoryForTesting(root) }
            new = try time { try FolderScanner.discoverInventory(root) }
        } else {
            new = try time { try FolderScanner.discoverInventory(root) }
            old = try time { try FolderScanner.legacyEnumeratorInventoryForTesting(root) }
        }
        let newIDs = Set(new.0.directories.map { $0.id })
        let skipped: [String] = old.0.directories.map { $0.id }.filter { !newIDs.contains($0) }
        // Only top-most skipped folders: their descendants follow.
        let skippedRoots: [String] = skipped.filter { id in !skipped.contains { id.hasPrefix($0 + "/") } }
        let times = String(format: "new=%.3fs old=%.3fs", new.1, old.1)
        let files = "files new=\(new.0.physicalFileCount) old=\(old.0.physicalFileCount)"
        let items = "items new=\(new.0.items.count) old=\(old.0.items.count)"
        let folders = "dirs new=\(new.0.directories.count) old=\(old.0.directories.count)"
        let skips = "skippedFolders=\(skippedRoots.count) skippedIncludingDescendants=\(skipped.count)"
        print("DISCOVERY-EQUIVALENCE root=\(path) order=\(order) \(times) \(files) \(items) \(folders) \(skips)")
        var skippedNames: [String: Int] = [:]
        for id in skippedRoots {
            let name = id.split(separator: "/").last.map(String.init) ?? id
            skippedNames[name.lowercased().hasSuffix(".lrdata") ? "*.lrdata" : name, default: 0] += 1
        }
        print("DISCOVERY-EQUIVALENCE skipped folder names: \(skippedNames)")
        for id in skippedRoots {
            let name = (id.removingPercentEncoding ?? id).split(separator: "/").last.map(String.init) ?? id
            XCTAssertTrue(name.caseInsensitiveCompare("CaptureOne") == .orderedSame
                          || name.lowercased().hasSuffix(".lrdata"), "unexpected skipped folder \(id)")
        }
        try assertEquivalent(new.0, old.0, skippingFolders: skippedRoots)
    }

    /// Set LOUPPE_DISCOVERY_TIMING_ROOT to time discovery and pairing stages
    /// (read-only). LOUPPE_DISCOVERY_TIMING_IMPLEMENTATION=old|new|both.
    func testOptInDiscoveryStageTimings() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LOUPPE_DISCOVERY_TIMING_ROOT"] else {
            throw XCTSkip("Set LOUPPE_DISCOVERY_TIMING_ROOT to time a folder.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let which = environment["LOUPPE_DISCOVERY_TIMING_IMPLEMENTATION"] ?? "new"
        let runs = Int(environment["LOUPPE_DISCOVERY_TIMING_RUNS"] ?? "1") ?? 1
        for run in 1...runs {
            for name in which == "both" ? ["new", "old"] : [which] {
                let recorder = SessionOpeningRecorder()
                let start = ProcessInfo.processInfo.systemUptime
                let inventory = name == "old"
                    ? try FolderScanner.legacyEnumeratorInventoryForTesting(root, recorder: recorder)
                    : try FolderScanner.discoverInventory(root, recorder: recorder)
                let total = ProcessInfo.processInfo.systemUptime - start
                let stages = recorder.snapshot().secondsByStage
                print(String(format: "DISCOVERY-TIMING run=%d impl=%@ total=%.3fs discovery=%.3fs pairing=%.3fs files=%d dirs=%d",
                             run, name, total, stages[.discovery] ?? -1, stages[.pairing] ?? -1,
                             inventory.physicalFileCount, inventory.directories.count))
            }
        }
    }

    // MARK: Fixture

    /// LOUPPE_DISCOVERY_FIXTURE_PARENT runs the same fixtures on another
    /// disposable volume, such as an FSKit exFAT disk image.
    private var fixtureParent: String {
        ProcessInfo.processInfo.environment["LOUPPE_DISCOVERY_FIXTURE_PARENT"] ?? "/private/tmp"
    }

    /// Links and FIFOs are required on the default APFS fixture only.
    private func requireOnDefaultVolume(_ status: Int32, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        if fixtureParent == "/private/tmp" { XCTAssertEqual(status, 0, label, file: file, line: line) }
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: fixtureParent, isDirectory: true)
            .appendingPathComponent("LouppeDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func buildAdversarialTree(at root: URL) throws {
        let fm = FileManager.default
        func path(_ relative: String) -> String { root.path + "/" + relative }
        func file(_ relative: String, _ bytes: Int = 3) throws {
            let url = URL(fileURLWithPath: path(relative))
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        func folder(_ relative: String) throws {
            try fm.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
        }
        func finderFlags(_ relative: String, _ flags: UInt16) {
            var info = [UInt8](repeating: 0, count: 32)
            info[8] = UInt8(flags >> 8)
            info[9] = UInt8(flags & 0xff)
            XCTAssertEqual(setxattr(path(relative), "com.apple.FinderInfo", &info, 32, 0, 0), 0, relative)
        }
        // Names. APFS keeps one normalization per folder, so each spelling
        // lives in its own folder; each must keep its exact bytes.
        // Foundation path APIs decompose names, so composed (NFC) names are
        // created with their exact bytes.
        func rawFile(_ relative: String) throws {
            try folder((relative as NSString).deletingLastPathComponent)
            let descriptor = open(path(relative), O_CREAT | O_WRONLY | O_EXCL, 0o644)
            XCTAssertGreaterThanOrEqual(descriptor, 0, relative)
            close(descriptor)
        }
        func rawFolder(_ relative: String) {
            XCTAssertEqual(mkdir(path(relative), 0o755), 0, relative)
        }
        try rawFile("nfc/Caf\u{00E9}.jpg")
        try file("nfd/Cafe\u{0301}.jpg")
        rawFolder("Dir\u{00E9}")
        try rawFile("Dir\u{00E9}/in.jpg")
        try file("Dire\u{0301}x/in.JPG")
        rawFolder("semi;colon dir")
        try rawFile("semi;colon dir/in;side.NEF")
        try file("case/IMG_1.JPG")
        try file("case2/img_1.jpg")
        try file("a b.JPG")
        try file("100% #1?&.nef")
        try file("semi;colon+plus=eq,comma.JPG")
        try file("\u{1F600}.jpg")
        try file("UPPER.JPEG")
        try file("mixed.JpG")
        try file("multi.dot.name.NEF")
        try file("trail.")
        try file("noext")
        try file("x.xmp")
        try file("x.cof")
        try file("notes.txt")
        try file("data.json")
        try file("clip.MOV")
        try file("voice.m4a")
        // Hidden: leading dot, UF_HIDDEN, and the Finder invisible bit.
        try file(".dot.jpg")
        try file(".dotdir/d.jpg")
        try file("uf-hidden.jpg")
        try file("uf-hidden-dir/u.jpg")
        XCTAssertEqual(chflags(path("uf-hidden.jpg"), UInt32(UF_HIDDEN)), 0)
        XCTAssertEqual(chflags(path("uf-hidden-dir"), UInt32(UF_HIDDEN)), 0)
        try file("invisible.jpg")
        try file("invisible-dir/v.jpg")
        finderFlags("invisible.jpg", 0x4000)
        finderFlags("invisible-dir", 0x4000)
        // Links: files, folders, loops, dangling and hard links.
        try file("shoot/A.NEF", 11)
        try file("shoot/A.JPG", 5)
        try file("shoot/nested/B.NEF")
        requireOnDefaultVolume(symlink("shoot/A.JPG", path("link-file.jpg")), "link-file")
        requireOnDefaultVolume(symlink("shoot", path("link-dir")), "link-dir")
        requireOnDefaultVolume(symlink("..", path("shoot/loop")), "loop")
        requireOnDefaultVolume(symlink("missing", path("dangling.jpg")), "dangling")
        requireOnDefaultVolume(link(path("shoot/A.NEF"), path("hardlink.NEF")), "hard link")
        requireOnDefaultVolume(mkfifo(path("fifo.jpg"), 0o644), "fifo")
        // Packages by extension and by the Finder bundle bit; folders that
        // merely look like packages or media.
        try file("Foo.app/x.jpg")
        try file("Bundle.bundle/y.jpg")
        try file("bundlebit/z.jpg")
        finderFlags("bundlebit", 0x2000)
        try file("noext-app/Contents/Info.plist")
        try file("noext-app/Contents/MacOS/q.jpg")
        try file("folder.JPG/inner/C.jpg")
        try file("trailing./t.jpg")
        try folder("empty")
        try folder("empty-parent/empty-child")
        try file("deep/1/2/3/4/5/6/7/8/9/10/D.NEF")
        // RAW+JPEG: same folder, across folders, and ambiguous groups.
        try file("raw/X.NEF")
        try file("jpg/X.JPG")
        try file("amb/Y.NEF")
        try file("amb/Y.JPG")
        try file("amb2/Y.JPG")
        try file("pair/P.RAF")
        try file("pair/P.jpg")
    }

    /// Archive-like sessions: NEF and RAF with JXL conversions sharing stems,
    /// TIFF/PNG edits, videos and audio named like photos, RAW+JPEG pairs,
    /// camera counters repeating across folders, and ambiguous and
    /// case-varied stems. (App cache folders are covered separately.)
    private func buildArchiveShapedTree(at root: URL, sessions: Int) throws {
        let fm = FileManager.default
        func file(_ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(relative.utf8.prefix(7)).write(to: url)
        }
        for session in 0..<sessions {
            let folder = "archive/\(2023 + session % 4)/\(2023 + session % 4).\(String(format: "%02d", session % 12 + 1)).\(session)"
            for shot in 0..<14 {
                // Counters repeat across sessions, so stems recur globally.
                let nikon = String(format: "DSC_%04d", (session * 7 + shot) % 60)
                let fuji = String(format: "XT5%05d", session * 14 + shot)
                switch session % 4 {
                case 0:
                    try file("\(folder)/\(nikon).NEF")
                    try file("\(folder)/\(nikon).jxl")
                case 1:
                    try file("\(folder)/\(fuji).RAF")
                    try file("\(folder)/Output/\(fuji).jxl")
                case 2:
                    try file("\(folder)/\(nikon).\(shot % 2 == 0 ? "NEF" : "nef")")
                    if shot < 4 { try file("\(folder)/\(nikon).\(shot % 2 == 0 ? "JPG" : "Jpeg")") }
                    if shot == 5 { try file("\(folder)/\(nikon).MOV") }
                    if shot == 6 { try file("\(folder)/\(nikon).wav") }
                    if shot == 7 { try file("\(folder)/\(nikon).tif") }
                default:
                    try file("\(folder)/\(fuji).RAF")
                    // Exact-case pairs, plus pairs only a case-insensitive volume forms.
                    if shot < 6 { try file("\(folder)/\(shot < 3 ? fuji : fuji.lowercased()).jpg") }
                    if shot == 8 { try file("\(folder)/Edit \(fuji).png") }
                    if shot == 9 { try file("\(folder)/\(fuji).txt") }
                }
            }
        }
        // Ambiguous: two RAWs for one JPEG, and one RAW for two JPEGs.
        try file("archive/amb/AMB_1.NEF")
        try file("archive/amb/AMB_1.RAF")
        try file("archive/amb/AMB_1.JPG")
        try file("archive/amb2/AMB_2.NEF")
        try file("archive/amb2/AMB_2.JPG")
        try file("archive/amb3/AMB_2.jpeg")
    }

    // MARK: Assertions

    private func assertEquivalent(_ new: FolderScanner.Inventory, _ old: FolderScanner.Inventory,
                                  skippingFolders skipped: [String] = [], context: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        func isSkipped(_ id: String) -> Bool {
            skipped.contains { id == $0 || id.hasPrefix($0 + "/") }
        }
        let oldFiles = old.items.flatMap(\.individualFiles)
        let keptOldFiles = oldFiles.filter { !isSkipped($0.id) }
        let droppedFiles = oldFiles.count - keptOldFiles.count
        XCTAssertEqual(new.root, old.root, context, file: file, line: line)
        XCTAssertEqual(new.directories, old.directories.filter { !isSkipped($0.id) }, context, file: file, line: line)
        let newFiles = new.items.flatMap(\.individualFiles)
        XCTAssertEqual(newFiles.count, keptOldFiles.count, context, file: file, line: line)
        let oldByID = Dictionary(uniqueKeysWithValues: keptOldFiles.map { ($0.id, $0) })
        for current in newFiles {
            guard let previous = oldByID[current.id] else {
                XCTFail("unexpected file \(current.id) \(context)", file: file, line: line)
                continue
            }
            assertSameFile(current, previous, context: context, file: file, line: line)
        }
        if droppedFiles == 0 {
            XCTAssertEqual(new.items.map(\.id), old.items.map(\.id), context, file: file, line: line)
            XCTAssertEqual(new.items.map { $0.pairedFile?.id }, old.items.map { $0.pairedFile?.id },
                           context, file: file, line: line)
            XCTAssertEqual(new.rawJPEGFileIDs.map { "\($0.raw)|\($0.jpeg)" },
                           old.rawJPEGFileIDs.map { "\($0.raw)|\($0.jpeg)" }, context, file: file, line: line)
        } else {
            let keptPairs = old.rawJPEGFileIDs.filter { !isSkipped($0.raw) && !isSkipped($0.jpeg) }
            XCTAssertEqual(new.rawJPEGFileIDs.map { "\($0.raw)|\($0.jpeg)" },
                           keptPairs.map { "\($0.raw)|\($0.jpeg)" }, context, file: file, line: line)
        }
    }

    private func assertSameFile(_ new: PhotoFile, _ old: PhotoFile, context: String,
                                file: StaticString, line: UInt) {
        let label = "\(old.id) \(context)"
        XCTAssertEqual(new.url, old.url, label, file: file, line: line)
        XCTAssertEqual(new.url.absoluteString, old.url.absoluteString, label, file: file, line: line)
        XCTAssertNil(new.url.baseURL, label, file: file, line: line)
        XCTAssertEqual(FolderScanner.fileSystemIdentityPath(for: new.url),
                       FolderScanner.fileSystemIdentityPath(for: old.url), label, file: file, line: line)
        XCTAssertEqual(new.url.withUnsafeFileSystemRepresentation { String(cString: $0!) },
                       old.url.withUnsafeFileSystemRepresentation { String(cString: $0!) }, label, file: file, line: line)
        XCTAssertEqual(new.legacyPersistenceID, old.legacyPersistenceID, label, file: file, line: line)
        XCTAssertEqual(new.displayName, old.displayName, label, file: file, line: line)
        XCTAssertEqual(new.subfolder, old.subfolder, label, file: file, line: line)
        XCTAssertEqual(new.mediaKind, old.mediaKind, label, file: file, line: line)
        XCTAssertEqual(new.fileSize, old.fileSize, label, file: file, line: line)
        XCTAssertEqual(new.captureDate, old.captureDate, label, file: file, line: line)
        XCTAssertEqual(new.captureDate?.timeIntervalSinceReferenceDate.bitPattern,
                       old.captureDate?.timeIntervalSinceReferenceDate.bitPattern, label, file: file, line: line)
        XCTAssertEqual(new.modificationDate?.timeIntervalSinceReferenceDate.bitPattern,
                       old.modificationDate?.timeIntervalSinceReferenceDate.bitPattern, label, file: file, line: line)
        XCTAssertEqual(String(reflecting: new.captureDateEvidence), String(reflecting: old.captureDateEvidence),
                       label, file: file, line: line)
        XCTAssertEqual(new.scannedIdentity, old.scannedIdentity, label, file: file, line: line)
        XCTAssertNotNil(new.scannedIdentity, label, file: file, line: line)
        XCTAssertEqual(new.metadataIsLoaded, old.metadataIsLoaded, label, file: file, line: line)
        XCTAssertEqual(new.searchableText, old.searchableText, label, file: file, line: line)
    }

    private func assertSameFailure(_ root: URL, context: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        if fixtureParent != "/private/tmp", (try? FolderScanner.legacyEnumeratorInventoryForTesting(root)) != nil {
            // exFAT ignores POSIX permissions: both must then succeed alike.
            try assertEquivalent(try FolderScanner.discoverInventory(root),
                                 try FolderScanner.legacyEnumeratorInventoryForTesting(root), context: context)
            return
        }
        var newError: Error?
        var oldError: Error?
        XCTAssertThrowsError(try FolderScanner.discoverInventory(root), context, file: file, line: line) { newError = $0 }
        XCTAssertThrowsError(try FolderScanner.legacyEnumeratorInventoryForTesting(root), context,
                             file: file, line: line) { oldError = $0 }
        guard case .unreadableFolder(let newURL, let newCause) = newError as? FolderScanner.ScanError,
              case .unreadableFolder(let oldURL, let oldCause) = oldError as? FolderScanner.ScanError else {
            XCTFail("\(context): \(String(describing: newError)) vs \(String(describing: oldError))", file: file, line: line)
            return
        }
        let new = newCause as NSError, old = oldCause as NSError
        XCTAssertEqual(newURL.path, oldURL.path, context, file: file, line: line)
        XCTAssertEqual(new.domain, old.domain, context, file: file, line: line)
        XCTAssertEqual(new.code, old.code, context, file: file, line: line)
        XCTAssertEqual((new.userInfo[NSUnderlyingErrorKey] as? NSError)?.code,
                       (old.userInfo[NSUnderlyingErrorKey] as? NSError)?.code, context, file: file, line: line)
        XCTAssertEqual(new.userInfo[NSFilePathErrorKey] as? String, old.userInfo[NSFilePathErrorKey] as? String,
                       context, file: file, line: line)
        XCTAssertEqual(new.localizedDescription, old.localizedDescription, context, file: file, line: line)
        XCTAssertEqual(newError?.localizedDescription, oldError?.localizedDescription, context, file: file, line: line)
    }
}

private final class DiscoveryPollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
