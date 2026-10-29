import Foundation
import XCTest
import AppKit
import SwiftUI
@testable import Louppe

final class PhotosLibraryRangeTests: XCTestCase {
    func testEightyThousandItemsStayInBoundedNonOverlappingBatches() {
        for size in PhotosBatchRange.sizes {
            let total = 80_013
            var visited = 0
            let first = PhotosBatchRange(total: total, page: 0, size: size)
            for page in 0..<first.pageCount {
                let batch = PhotosBatchRange(total: total, page: page, size: size)
                XCTAssertEqual(batch.start, visited)
                XCTAssertLessThanOrEqual(batch.indices.count, size)
                XCTAssertEqual(batch.hasPrevious, page > 0)
                XCTAssertEqual(batch.hasNext, page < first.pageCount - 1)
                visited += batch.indices.count
            }
            XCTAssertEqual(visited, total)
        }
        XCTAssertEqual(PhotosBatchRange(total: 80_013, page: Int.max, size: 100).end, 80_013)
        XCTAssertEqual(PhotosBatchRange(total: -1, page: Int.min, size: 0).indices, 0..<0)
    }

    func testRecentDateRangesUseCalendarBoundariesAcrossDaylightSavingAndYears() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }
        let lastWeek = try XCTUnwrap(PhotosRecentDateRange.lastWeek.interval(
            relativeTo: date(2026, 10, 22, 12), calendar: calendar))
        XCTAssertEqual(lastWeek.start, try date(2026, 10, 12))
        XCTAssertEqual(lastWeek.end, try date(2026, 10, 19))
        let autumn = try XCTUnwrap(PhotosRecentDateRange.lastWeek.interval(
            relativeTo: date(2026, 10, 26, 12), calendar: calendar))
        XCTAssertEqual(autumn.start, try date(2026, 10, 19))
        XCTAssertEqual(autumn.end, try date(2026, 10, 26))
        XCTAssertEqual(autumn.duration, 169 * 3600)
        let recent = try XCTUnwrap(PhotosRecentDateRange.lastSevenDays.interval(
            relativeTo: date(2026, 10, 26, 12), calendar: calendar))
        XCTAssertEqual(recent.start, try date(2026, 10, 20))
        XCTAssertEqual(recent.end, try date(2026, 10, 27))
        let year = try XCTUnwrap(PhotosRecentDateRange.lastWeek.interval(
            relativeTo: date(2027, 1, 1, 12), calendar: calendar))
        XCTAssertEqual(year.start, try date(2026, 12, 21))
        XCTAssertEqual(year.end, try date(2026, 12, 28))
    }

    func testFilenameCannotEscapeItsBatchOrHideFromTheScanner() {
        XCTAssertEqual(PhotosLibraryService.safeFilename("../../IMG.JPG", type: "public.jpeg"), "IMG.JPG")
        XCTAssertEqual(PhotosLibraryService.safeFilename(".hidden.JPG", type: "public.jpeg"), "Photo.jpeg")
        XCTAssertEqual(PhotosLibraryService.safeFilename("wrong.app", type: "public.jpeg"), "Photo.jpeg")
        XCTAssertFalse(PhotosLibraryService.safeFilename("nul\0.jpg", type: "public.jpeg").contains("\0"))
    }
}

@MainActor
final class PhotosLibraryTests: XCTestCase {
    func testLargeLibraryUsesOnlySelectedBatchAndRestoresDecisionsAcrossBatchSizes() async throws {
        let fixture = try Fixture(total: 80_005)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        XCTAssertEqual(store.photosBrowser.snapshot?.count, 80_005)
        XCTAssertFalse(store.photosBrowser.allowNetwork, "Downloads require an explicit choice.")
        store.openPhotosBatch(page: 800)
        try await wait { if case .ready = store.phase { return true }; return false }
        XCTAssertEqual(store.items.count, 5)
        XCTAssertEqual(store.photosBatch?.range.indices, 80_000..<80_005)
        let requested = await fixture.library.requestedRanges
        XCTAssertEqual(requested, [80_000..<80_005])
        XCTAssertEqual(store.visibleIndices.count, 5)
        XCTAssertTrue(store.items.allSatisfy { $0.primaryFile.subfolder == nil })
        XCTAssertEqual(store.currentItem?.captureDateEvidence?.source, .photosLibrary)
        XCTAssertFalse(store.sort.ascending, "The chosen Photos order also owns the initial review order.")
        XCTAssertFalse(MetadataExtractor.fields(for: try XCTUnwrap(store.currentItem))
            .contains { $0.id == "Captured" && $0.value.contains("estimated") })
        XCTAssertEqual(store.recentFolders, [], "Private Photos cache folders must never enter recents.")
        store.rate(.yes, at: 0)
        store.setStarRating(.five, at: 0)
        store.setColorLabel(.purple, at: 0)
        let firstPath = try XCTUnwrap(store.items.first?.primaryURL.path)
        let assetID = try XCTUnwrap(store.photosBatch?.assetIDsByPath[firstPath])
        let saved = await store.saveSessionForTermination()
        XCTAssertTrue(saved?.canDiscardInMemoryState != false)
        let checkpoint = try await fixture.decisions.load()
        XCTAssertEqual(checkpoint[assetID]?.rating, .yes)
        XCTAssertEqual(checkpoint[assetID]?.stars, .five)
        XCTAssertEqual(checkpoint[assetID]?.color, .purple)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.sourceFolder).appendingPathComponent(SessionConstants.sidecarName).path))
        store.viewMode = .grid
        store.openPhotosBatch(page: 799, continuing: true)
        try await wait {
            guard case .ready = store.phase else { return false }
            return store.photosBatch?.range.page == 799 && store.items.count == 100 && !store.isFileOperationRunning
        }
        XCTAssertEqual(store.viewMode, .grid, "Next/Previous must preserve the review layout.")
        // A differently sized, overlapping selection recovers by Photos ID,
        // even though every temporary pathname and physical file has changed.
        store.photosBrowser.batchSize = 50
        store.openPhotosBatch(page: 1600)
        try await wait {
            // The requested batch changes before its inventory becomes authoritative.
            // Await actual publication before inspecting/restoring its members.
            guard case .ready = store.phase else { return false }
            return store.photosBatch?.range.size == 50 && store.photosBatch?.range.page == 1600
                && store.items.count == 5 && !store.isFileOperationRunning
        }
        let matching = try XCTUnwrap(store.items.first { item in
            store.photosBatch?.assetIDsByPath[item.primaryURL.path] == assetID
        })
        XCTAssertEqual(matching.rating, .yes)
        XCTAssertEqual(matching.primaryFile.starRating, .five)
        XCTAssertEqual(matching.primaryFile.colorLabel, .purple)
        store.rate(.undecided, at: try XCTUnwrap(store.items.firstIndex { $0.id == matching.id }))
        _ = await store.saveSessionForTermination()
        let cleared = try await fixture.decisions.load()
        XCTAssertEqual(cleared[assetID]?.rating, .undecided)
    }

    func testPhotosBlocksCacheMutationsAndSwitchesBackToOrdinaryFolder() async throws {
        let fixture = try Fixture(total: 2)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosBatch(page: 0)
        try await wait { if case .ready = store.phase { return true }; return false }
        XCTAssertTrue(store.canRate)
        XCTAssertTrue(store.canExport)
        XCTAssertFalse(store.canCleanUp)
        XCTAssertFalse(store.canOrganizeSource)
        XCTAssertFalse(store.canRenameSource)
        XCTAssertFalse(store.exportWillStart(mode: .move))
        XCTAssertFalse(store.exportWillStart(mode: .metadataXMP))
        store.requestCleanUp(.selection)
        store.performCleanUp(.selection)
        store.presentMetadataFileRenaming()
        XCTAssertNil(store.pendingCleanUp)
        XCTAssertFalse(store.isRenamePresented)
        XCTAssertTrue(store.items.allSatisfy { FileManager.default.fileExists(atPath: $0.primaryURL.path) })
        store.rate(.no, at: 0)
        store.openFolder(fixture.ordinaryFolder)
        try await wait { store.photosBatch == nil && store.items.count == 1 && !store.isFileOperationRunning }
        XCTAssertTrue(store.canCleanUp)
        XCTAssertTrue(store.canRenameSource)
        let decisions = try await fixture.decisions.load()
        XCTAssertTrue(decisions.values.contains { $0.rating == .no })
    }

    func testCancellationAndDownloadFailureKeepExistingSession() async throws {
        let fixture = try Fixture(total: 2)
        defer { fixture.remove() }
        let store = fixture.store()
        store.openFolder(fixture.ordinaryFolder)
        try await wait { if case .ready = store.phase { return true }; return false }
        store.rate(.yes, at: 0)
        let original = store.sourceFolder
        await store.photosBrowser.load()
        await fixture.library.setMode(.slow)
        store.openPhotosBatch(page: 0)
        try await wait { store.photosBrowser.isOpening }
        store.cancelPhotosOpening()
        try await wait { !store.photosBrowser.isOpening }
        XCTAssertEqual(store.sourceFolder, original)
        XCTAssertNil(store.photosBatch)
        XCTAssertEqual(store.items.first?.rating, .yes)
        await fixture.library.setMode(.failure)
        store.openPhotosBatch(page: 0)
        try await wait { !store.photosBrowser.isOpening }
        XCTAssertNotNil(store.photosBrowser.error)
        XCTAssertEqual(store.sourceFolder, original)
        XCTAssertTrue(store.canRate)
        XCTAssertFalse(store.isFileOperationRunning)
    }

    func testICloudFailureOffersAnExplicitDownloadRetryForTheSameSelection() async throws {
        let fixture = try Fixture(total: 2)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        let snapshotID = store.photosBrowser.snapshot?.id
        await fixture.library.setMode(.cloud)
        store.openPhotosBatch(page: 0)
        try await wait { !store.photosBrowser.isOpening }
        XCTAssertTrue(store.photosBrowser.failure?.requiresDownload == true)
        XCTAssertFalse(store.photosBrowser.failure?.isSelectionFailure == true)
        XCTAssertFalse(store.photosBrowser.allowNetwork)
        XCTAssertEqual(store.photosBrowser.snapshot?.id, snapshotID)
        await fixture.library.setMode(.normal)
        store.photosReviewNetwork = true
        store.openPhotosBatch(page: 0)
        try await wait { if case .ready = store.phase { return true }; return false }
        XCTAssertNil(store.photosBrowser.failure)
        let networkChoices = await fixture.library.networkChoices
        XCTAssertEqual(networkChoices, [false, true])
    }

    func testNextBatchDownloadRetryKeepsRequestedPageAndPinnedSelection() async throws {
        let fixture = try Fixture(total: 102)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosBatch(page: 0)
        try await wait { store.photosBatch?.range.page == 0 && store.items.count == 100 && !store.isFileOperationRunning }
        let activeSnapshot = try XCTUnwrap(store.photosBatch?.snapshot)
        // An abandoned chooser selection must not take over a Next Batch retry.
        store.photosBrowser.query.newestFirst = false
        await store.photosBrowser.load()
        store.photosBrowser.batchSize = 50
        store.photosBrowser.page = 2
        await fixture.library.setMode(.cloud)
        store.openPhotosBatch(page: 1, continuing: true)
        try await wait { !store.photosBrowser.isOpening }
        XCTAssertTrue(store.photosBrowser.failure?.requiresDownload == true)
        XCTAssertEqual(store.photosBatch?.range.page, 0, "Failure retains the current review.")
        XCTAssertEqual(store.photosBrowser.snapshot?.id, activeSnapshot.id)
        XCTAssertEqual(store.photosBrowser.query, activeSnapshot.query)
        XCTAssertEqual(store.photosBrowser.range.indices, 100..<102)
        await fixture.library.setMode(.normal)
        store.photosReviewNetwork = true
        store.openPhotosBatch(page: store.photosBrowser.page)
        try await wait { store.photosBatch?.range.page == 1 && store.items.count == 2 && !store.isFileOperationRunning }
        XCTAssertEqual(store.photosBatch?.snapshot.id, activeSnapshot.id)
        let requested = await fixture.library.requestedRanges
        XCTAssertEqual(requested, [0..<100, 100..<102])
        let networkChoices = await fixture.library.networkChoices
        XCTAssertEqual(networkChoices, [false, false, true])
    }

    func testFailedDecisionSaveBlocksSwitchAndRetriesWithoutDiscardingRatings() async throws {
        let fixture = try Fixture(total: 2)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.openPhotosBatch(page: 0)
        try await wait { if case .ready = store.phase { return true }; return false }
        _ = await store.saveSessionForTermination()
        let json = fixture.decisionsDirectory.appendingPathComponent("decisions.json")
        let goodBytes = try Data(contentsOf: json)
        try Data("damaged checkpoint".utf8).write(to: json)
        store.rate(.no, at: 0)
        let original = store.sourceFolder
        store.openFolder(fixture.ordinaryFolder)
        try await wait { !store.isSessionTransitioning }
        XCTAssertEqual(store.sourceFolder, original)
        XCTAssertNotNil(store.persistenceWarning)
        XCTAssertEqual(store.items.first?.rating, .no)
        XCTAssertEqual(try Data(contentsOf: json), Data("damaged checkpoint".utf8))
        try goodBytes.write(to: json)
        store.retryPersistence()
        try await wait { store.persistenceWarning == nil }
        let decisions = try await fixture.decisions.load()
        XCTAssertTrue(decisions.values.contains { $0.rating == .no })
    }

    func testDecisionsMergeAcrossStoreInstancesAndRejectCorruptData() async throws {
        let fixture = try Fixture(total: 1)
        defer { fixture.remove() }
        let a = PhotosReviewDecisions(directory: fixture.decisionsDirectory)
        let b = PhotosReviewDecisions(directory: fixture.decisionsDirectory)
        let yes = PhotosReviewDecision(.init(fileID: "ignored", rating: .yes, ratedAt: Date()))
        async let saveA = a.save(["asset-a": yes])
        async let saveB = b.save(["asset-b": yes])
        _ = try await (saveA, saveB)
        let combined = try await a.load()
        XCTAssertEqual(combined.count, 2)
        let json = fixture.decisionsDirectory.appendingPathComponent("decisions.json")
        let bad = Data("{\"version\":99,\"assets\":{}}".utf8)
        try bad.write(to: json)
        do { try await b.save(["asset-c": yes]); XCTFail("Unknown schema must remain untouched") } catch {}
        XCTAssertEqual(try Data(contentsOf: json), bad)
    }

    func testLateOlderCheckpointCannotReplaceNewerDecisions() async throws {
        let fixture = try Fixture(total: 1)
        defer { fixture.remove() }
        let writer = UUID()
        let yes = PhotosReviewDecision(.init(fileID: "ignored", rating: .yes, ratedAt: Date()))
        let no = PhotosReviewDecision(.init(fileID: "ignored", rating: .no, ratedAt: Date()))
        let newer = try await fixture.decisions.save(["asset": yes], writerID: writer, sequence: 2)
        let stale = try await fixture.decisions.save(["asset": no], writerID: writer, sequence: 1)
        XCTAssertTrue(newer)
        XCTAssertFalse(stale)
        let saved = try await fixture.decisions.load(assetIDs: ["asset"])
        XCTAssertEqual(saved["asset"]?.rating, .yes)
    }

    func testNativeChooserAndStandardReviewWindowRenderWithoutForegroundControl() async throws {
        let fixture = try Fixture(total: 80_005)
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 528, height: 530),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: AnyView(
            PhotosLibraryView(store: store, browser: store.photosBrowser)
                .frame(width: 528, height: 530, alignment: .top)))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try capture(host, name: "chooser")
        store.openPhotosBatch(page: 800)
        try await wait { if case .ready = store.phase { return true }; return false }
        window.setContentSize(CGSize(width: 1150, height: 760))
        host.rootView = AnyView(SessionView(store: store).frame(width: 1150, height: 760))
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        try capture(host, name: "gallery")
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: URL(fileURLWithPath: "/private/tmp/louppe-photos-\(name).png"))
    }

    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
        if !condition() { throw CocoaError(.userCancelled) }
    }

    private struct Fixture {
        let root: URL
        let ordinaryFolder: URL
        let decisionsDirectory: URL
        let decisions: PhotosReviewDecisions
        let library: FakePhotosLibrary
        let defaults: UserDefaults
        init(total: Int) throws {
            root = URL(fileURLWithPath: "/private/tmp/LouppePhotos-\(UUID().uuidString)")
            ordinaryFolder = root.appendingPathComponent("Ordinary")
            decisionsDirectory = root.appendingPathComponent("Decisions")
            decisions = PhotosReviewDecisions(directory: decisionsDirectory)
            let image = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ModernImages/square.webp")
            library = FakePhotosLibrary(root: root, image: image, total: total, decisions: decisions)
            defaults = UserDefaults(suiteName: "LouppePhotosTests-\(UUID().uuidString)")!
            try FileManager.default.createDirectory(at: ordinaryFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: image, to: ordinaryFolder.appendingPathComponent("Photo.webp"))
        }
        @MainActor func store() -> SessionStore {
            SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
                photosDecisions: decisions, photosLibrary: library,
                saveTrailingDelay: 60, saveMaximumDelay: 60,
                operationJournalDirectory: root.appendingPathComponent("Operations"), reviewDefaults: defaults)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor FakePhotosLibrary: PhotosLibraryClient {
    enum Mode { case normal, slow, failure, cloud }
    var networkChoices: [Bool] = []
    var requestedRanges: [Range<Int>] = []
    private let root: URL
    private let image: URL
    private let total: Int
    private let decisions: PhotosReviewDecisions
    private var mode = Mode.normal
    init(root: URL, image: URL, total: Int, decisions: PhotosReviewDecisions) {
        self.root = root; self.image = image; self.total = total; self.decisions = decisions
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func authorize() {}
    func albums() -> [PhotosLibraryAlbum] { [] }
    func select(_ query: PhotosLibraryQuery) -> PhotosLibrarySnapshot {
        PhotosLibrarySnapshot(id: UUID(), count: total, title: "Fixture Photos", query: query)
    }
    func prepare(snapshot: PhotosLibrarySnapshot, page: Int, size: Int, allowNetwork: Bool,
                 recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        networkChoices.append(allowNetwork)
        if mode == .cloud { throw PhotosLibraryError.iCloudDownloadRequired }
        if mode == .slow { try await Task.sleep(for: .seconds(30)) }
        if mode == .failure { throw CocoaError(.fileReadNoSuchFile) }
        let range = PhotosBatchRange(total: total, page: page, size: size)
        requestedRanges.append(range.indices)
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var ids: [String: String] = [:]
        var dates: [String: Date] = [:]
        for index in range.indices {
            let url = folder.appendingPathComponent("\(index).webp")
            try FileManager.default.copyItem(at: image, to: url)
            ids[url.path] = "asset-\(index)"
            dates[url.path] = Date(timeIntervalSince1970: Double(index))
        }
        return PhotosReviewBatch(folder: folder, snapshot: snapshot, range: range, assetIDsByPath: ids,
                                 decisions: try await decisions.load(), captureDatesByPath: dates)
    }
    func remove(_ batch: PhotosReviewBatch) { try? FileManager.default.removeItem(at: batch.folder) }
}
