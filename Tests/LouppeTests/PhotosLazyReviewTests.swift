import AppKit
import Photos
import SwiftUI
import XCTest
@testable import Louppe

final class PhotosImageRequestTests: XCTestCase, @unchecked Sendable {
    func testDegradedCallbackIsNeverAcceptedAsOriginalOrCompletedPreview() async throws {
        let pixel = try MockPhotosMedia.image(pixels: 32)
        let request = PhotosImageRequest(cancel: { _ in })
        do {
            _ = try await request.read { reply in
                reply(pixel.image, [PHImageResultIsDegradedKey: true])
                reply(nil, [PHImageResultIsInCloudKey: true])
                reply(pixel.image, nil) // late callback must not overwrite failure
                return 17
            }
            XCTFail("Cloud-only final result must remain unavailable")
        } catch PhotosRepresentationError.cloud {}
    }

    func testCancellationBeforeRequestIDAndNoCancelCallback() async throws {
        let probe = ImageCancelProbe()
        let request = PhotosImageRequest(cancel: probe.cancel)
        let task = Task {
            try await request.read { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 99
            }
        }
        do { _ = try await task.value; XCTFail("Must cancel without a PhotoKit callback") }
        catch is CancellationError {}
        XCTAssertEqual(probe.ids, [99])
    }

    func testFastLocalFallbackMayAcceptDegradedPixelsOnlyAsAReviewImage() async throws {
        let pixel = try MockPhotosMedia.image(pixels: 32)
        let request = PhotosImageRequest(cancel: { _ in })
        let image = try await request.read(acceptDegraded: true) { reply in
            reply(pixel.image, [PHImageResultIsDegradedKey: true])
            return 18
        }
        XCTAssertEqual(image.size, pixel.image.size)
    }

    func testExplicitUnadjustedAndNetworkOptions() {
        let options = ApplePhotosMediaProvider.options(network: false)
        XCTAssertEqual(options.version, .unadjusted)
        XCTAssertEqual(options.resizeMode, .exact)
        XCTAssertEqual(options.deliveryMode, .highQualityFormat)
        XCTAssertFalse(options.isSynchronous)
        XCTAssertFalse(options.isNetworkAccessAllowed)
        XCTAssertTrue(ApplePhotosMediaProvider.options(network: true).isNetworkAccessAllowed)
    }
}

@MainActor
final class PhotosLazyReviewTests: XCTestCase {
    func testThousandItemsMountWithoutImagesOrOriginalsThenPersistAcrossOverlapAndReopen() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.photosBrowser.batchSize = 1_000
        let start = ProcessInfo.processInfo.systemUptime
        store.openPhotosBatch(page: 0)
        try await wait { store.items.count == 1_000 && !store.isFileOperationRunning }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("Photos lazy 1000 mount seconds: \(elapsed)")
        XCTAssertEqual(store.visibleIndices.count, 1_000)
        let requests = await fixture.provider.requests
        XCTAssertTrue(requests.images.isEmpty)
        XCTAssertTrue(requests.originals.isEmpty)
        XCTAssertTrue(store.items.allSatisfy { !FileManager.default.fileExists(atPath: $0.primaryURL.path) })
        XCTAssertFalse(store.canCleanUp)
        XCTAssertTrue(store.canExport)
        XCTAssertTrue(MetadataExtractor.fields(for: store.items[0]).contains { $0.id == "Availability" })
        XCTAssertFalse(MetadataExtractor.fields(for: store.items[0]).contains { $0.id == "File size" })
        let id = store.items[0].id
        store.rate(.yes, at: 0)
        store.setStarRating(.five, at: 0)
        store.setColorLabel(.purple, at: 0)
        let saved = await store.saveSessionForTermination()
        XCTAssertTrue(saved?.canDiscardInMemoryState != false)
        store.viewMode = .grid
        store.photosBrowser.batchSize = 500
        store.openPhotosBatch(page: 0)
        try await wait { store.items.count == 500 && !store.isFileOperationRunning }
        XCTAssertEqual(store.viewMode, .grid)
        let overlap = try XCTUnwrap(store.items.first { $0.id == id })
        XCTAssertEqual(overlap.rating, .yes)
        XCTAssertEqual(overlap.primaryFile.starRating, .five)
        XCTAssertEqual(overlap.primaryFile.colorLabel, .purple)
        let reopened = fixture.store()
        await reopened.photosBrowser.load()
        reopened.openPhotosBatch(page: 0)
        try await wait { !reopened.items.isEmpty && !reopened.isFileOperationRunning }
        XCTAssertEqual(reopened.items.first { $0.id == id }?.rating, .yes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.sourceFolder).appendingPathComponent(SessionConstants.sidecarName).path))
    }

    func testLocalCloudOfflineAndIndependentOriginalConsent() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let batch = try await fixture.batch(size: 1_000)
        let session = try XCTUnwrap(batch.mediaSession)
        let items = try XCTUnwrap(batch.reviewItems)
        _ = try await session.image(assetID: "asset-0", pixels: 384)
        do { _ = try await session.image(assetID: "asset-1", pixels: 384); XCTFail("Cloud needs consent") }
        catch PhotosRepresentationError.cloud {}
        await session.setImageNetwork(true)
        _ = try await session.image(assetID: "asset-1", pixels: 384)
        await fixture.provider.setOffline(true)
        // A previously loaded representation is available without network.
        _ = try await session.image(assetID: "asset-1", pixels: 384)
        do { _ = try await session.image(assetID: "asset-3", pixels: 384); XCTFail("Offline miss") }
        catch PhotosRepresentationError.cloud {}
        await fixture.provider.setOffline(false)
        do { _ = try await session.original(for: items[1]); XCTFail("Review consent must not authorize originals") }
        catch PhotosLibraryError.iCloudDownloadRequired {}
        await session.setOriginalNetwork(true)
        let lease = try await session.original(for: items[1])
        XCTAssertEqual(try Data(contentsOf: lease.item.primaryURL), MockPhotosMedia.originalBytes("asset-1"))
        await lease.close()
        let bytes = await session.originalBytes
        XCTAssertEqual(bytes, 0)
        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.originals, ["asset-1", "asset-1"])
        XCTAssertEqual(requests.originalNetwork, [false, true])
        await session.stop()
    }

    func testRequestConcurrencyCachePreheatAndCancellationAreBounded() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let batch = try await fixture.batch(size: 1_000)
        let session = try XCTUnwrap(batch.mediaSession)
        await session.setImageNetwork(true)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<90 {
                group.addTask { _ = try? await session.image(assetID: "asset-\(index)", pixels: 2_048) }
            }
        }
        let requests = await fixture.provider.requests
        XCTAssertLessThanOrEqual(requests.maximumConcurrentImages, 4)
        XCTAssertLessThan(requests.images.count, 90, "Pending queue must reject excess admission")
        let cacheBytes = await session.cachedBytes
        XCTAssertLessThanOrEqual(cacheBytes, PhotosMediaSession.memoryLimit)
        XCTAssertGreaterThan(cacheBytes, 0)
        await session.preheat(assetIDs: (0..<1_000).map { "asset-\($0)" })
        let preheat = await fixture.provider.requests.preheat
        XCTAssertEqual(preheat.count, 8)
        let task = Task { try await session.image(assetID: "slow", pixels: 384) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled view must not receive late pixels") }
        catch is CancellationError {}
        let active = Task { try await session.image(assetID: "slow", pixels: 384) }
        try await Task.sleep(for: .milliseconds(20))
        await session.stop()
        do { _ = try await active.value; XCTFail("Closed batch must retire work") }
        catch is CancellationError {} catch PhotosRepresentationError.retired {}
        do { _ = try await session.image(assetID: "asset-0", pixels: 384); XCTFail("No requests after close") }
        catch PhotosRepresentationError.retired {}
        let originals = await fixture.provider.requests.originals
        XCTAssertTrue(originals.isEmpty)
    }

    func testSparseCopyExportsExactOriginalsWithCollisionAndReleasesDisk() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let batch = try await fixture.batch(size: 1_000)
        let session = try XCTUnwrap(batch.mediaSession)
        let items = try XCTUnwrap(batch.reviewItems)
        await session.setOriginalNetwork(true)
        // The review PNG is intentionally different from the original payload.
        _ = try await session.image(assetID: "asset-0", pixels: 384)
        let existing = fixture.destination.appendingPathComponent("Photo.raw")
        try Data("existing file".utf8).write(to: existing)
        let binding = try DurableFileIO.DirectoryBinding(url: fixture.destination)
        let result = await PhotosCopyWorker.copy([items[0], items[1], items[2]], sourceFolder: batch.folder,
            destination: fixture.destination, binding: binding, journalDirectory: fixture.journals,
            cancelFlag: ExportWorker.CancelFlag(), progress: { _, _ in })
        XCTAssertEqual(result.copiedFiles, 3, result.failureMessage ?? "")
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        let exported = try FileManager.default.contentsOfDirectory(at: fixture.destination, includingPropertiesForKeys: nil)
        let bytes = try exported.map { try Data(contentsOf: $0) }
        for id in ["asset-0", "asset-1", "asset-2"] { XCTAssertTrue(bytes.contains(MockPhotosMedia.originalBytes(id))) }
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing file".utf8))
        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.originals, ["asset-0", "asset-1", "asset-2"])
        XCTAssertEqual(requests.maximumConcurrentOriginals, 1)
        let stagedBytes = await session.originalBytes
        XCTAssertEqual(stagedBytes, 0)
        let originals = batch.folder.appendingPathComponent("Originals")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: originals.path), [])
    }

    func testOriginalBudgetAndCancellationLeaveNoPartialFiles() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let batch = try await fixture.batch(size: 1_000)
        let session = try XCTUnwrap(batch.mediaSession)
        let item = try XCTUnwrap(batch.reviewItems?.first)
        await fixture.provider.setOversize(true)
        do { _ = try await session.original(for: item); XCTFail("Streaming budget must propagate") }
        catch PhotosLibraryError.batchTooLarge {}
        await fixture.provider.setOversize(false)
        await fixture.provider.setSlowOriginals(true)
        let task = Task { try await session.original(for: item) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Original cancel must propagate") }
        catch is CancellationError {}
        let bytes = await session.originalBytes
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: batch.folder.appendingPathComponent("Originals").path), [])
    }

    func testSwitchCancelsSparseOriginalAndSavesOutgoingDecisions() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        await store.photosBrowser.load()
        store.photosBrowser.batchSize = 1_000
        store.openPhotosBatch(page: 0)
        try await wait { store.items.count == 1_000 && !store.isFileOperationRunning }
        let batch = try XCTUnwrap(store.photosBatch)
        let item = try XCTUnwrap(batch.reviewItems?.first)
        let session = try XCTUnwrap(batch.mediaSession)
        await fixture.provider.setSlowOriginals(true)
        let original = Task { try await session.original(for: item) }
        try await Task.sleep(for: .milliseconds(30))
        store.rate(.yes, at: 0)
        let ratedID = try XCTUnwrap(store.photosBatch?.assetIDsByPath[store.items[0].primaryURL.path])
        store.openPhotosBatch(page: 1, continuing: true)
        try await wait { store.photosBatch?.range.page == 1 && store.items.count == 1_000 && !store.isFileOperationRunning }
        do { _ = try await original.value; XCTFail("Outgoing sparse request must be cancelled") }
        catch is CancellationError {} catch PhotosRepresentationError.retired {}
        let saved = try await fixture.decisions.load()
        XCTAssertEqual(saved[ratedID]?.rating, .yes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.folder.path))
        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.originals.count, 1)
    }

    func testCancelledCopyDuringCloudDownloadPreservesCompletedFiles() async throws {
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let batch = try await fixture.batch(size: 1_000)
        let session = try XCTUnwrap(batch.mediaSession)
        await session.setOriginalNetwork(true)
        await fixture.provider.setSlowOriginalAsset("asset-1")
        let flag = ExportWorker.CancelFlag()
        let task = Task {
            await PhotosCopyWorker.copy(try XCTUnwrap(batch.reviewItems), sourceFolder: batch.folder,
                destination: fixture.destination, binding: try DurableFileIO.DirectoryBinding(url: fixture.destination),
                journalDirectory: fixture.journals, cancelFlag: flag, progress: { _, _ in })
        }
        for _ in 0..<100 {
            if await fixture.provider.requests.originals.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = flag.request(.userConfirmed); task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.cancellationReason, .userConfirmed)
        XCTAssertEqual(result.copiedFiles, 1)
        let completed = fixture.destination.appendingPathComponent("Photo.raw")
        XCTAssertEqual(try Data(contentsOf: completed), MockPhotosMedia.originalBytes("asset-0"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["Photo.raw"])
    }

    func testCaptureLazyPhotosSurfacesWithoutForegroundControl() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["LOUPPE_PHOTOS_SNAPSHOTS"] else {
            throw XCTSkip("Set LOUPPE_PHOTOS_SNAPSHOTS for offscreen native captures.")
        }
        _ = NSApplication.shared
        let fixture = try LazyPhotosFixture()
        defer { fixture.remove() }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = fixture.store()
        await store.photosBrowser.load()
        store.photosBrowser.batchSize = 1_000
        for scheme in [ColorScheme.light, .dark] {
            try await capture(PhotosLibraryView(store: store, browser: store.photosBrowser),
                name: "chooser-\(scheme)", size: CGSize(width: 540, height: 560), scheme: scheme,
                defaults: fixture.defaults, output: output)
        }
        store.openPhotosBatch(page: 0)
        try await wait { store.items.count == 1_000 && !store.isFileOperationRunning }
        store.showBrowser = true; store.showMetadataPanel = true
        for scheme in [ColorScheme.light, .dark] {
            store.viewMode = .gallery
            store.setIndex(0)
            try await capture(PhotosBatchBar(store: store, batch: try XCTUnwrap(store.photosBatch)),
                name: "batch-bar-\(scheme)", size: CGSize(width: 1200, height: 64), scheme: scheme,
                defaults: fixture.defaults, output: output)
            try await capture(SessionView(store: store), name: "gallery-local-\(scheme)",
                size: CGSize(width: 1512, height: 900), scheme: scheme, defaults: fixture.defaults, output: output)
            store.setIndex(1)
            try await capture(SessionView(store: store), name: "gallery-cloud-\(scheme)",
                size: CGSize(width: 1200, height: 760), scheme: scheme, defaults: fixture.defaults, output: output)
            store.viewMode = .grid
            try await capture(SessionView(store: store), name: "grid-mixed-\(scheme)",
                size: CGSize(width: 1512, height: 900), scheme: scheme, defaults: fixture.defaults, output: output)
            try await capture(ExportView(store: store), name: "copy-setup-\(scheme)",
                size: CGSize(width: 640, height: 620), scheme: scheme, defaults: fixture.defaults, output: output)
        }
        // Alex may switch between his own apps while this test runs. Only our
        // own activation would violate the background-capture contract.
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          ProcessInfo.processInfo.processIdentifier)
        let requests = await fixture.provider.requests
        XCTAssertTrue(requests.originals.isEmpty, "Visual review must not stage originals")
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme,
                                  defaults: UserDefaults, output: URL) async throws {
        let host = NSHostingView(rootView: view.defaultAppStorage(defaults).preferredColorScheme(scheme)
            .frame(width: size.width, height: size.height).background(Color.appBackground).tint(Color.louppeAccent))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
        if name.hasPrefix("chooser") || name.hasPrefix("copy-setup") {
            func scrolls(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            let owners = scrolls(host)
            XCTAssertEqual(owners.count, 1, "Grouped Photos forms own one scrolling region")
            if let scroll = owners.first, let document = scroll.documentView {
                document.scroll(NSPoint(x: 0, y: document.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                let lower = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: lower)
                try XCTUnwrap(lower.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(name)-bottom.png"))
            }
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            if Date() > deadline { XCTFail("Timed out waiting for lazy Photos state"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ImageCancelProbe: @unchecked Sendable {
    let lock = NSLock()
    private var values: [Int32] = []
    var ids: [Int32] { lock.withLock { values } }
    func cancel(_ id: Int32) { lock.withLock { values.append(id) } }
}

actor MockPhotosMedia: PhotosMediaProvider {
    struct Requests: Sendable {
        var images: [String] = []
        var originals: [String] = []
        var originalNetwork: [Bool] = []
        var maximumConcurrentImages = 0
        var maximumConcurrentOriginals = 0
        var preheat: [String] = []
    }
    private(set) var requests = Requests()
    private var imageCount = 0
    private var originalCount = 0
    private var offline = false
    private var oversize = false
    private var slowOriginals = false
    private var slowOriginalAsset: String?
    func setOffline(_ value: Bool) { offline = value }
    func setOversize(_ value: Bool) { oversize = value }
    func setSlowOriginals(_ value: Bool) { slowOriginals = value }
    func setSlowOriginalAsset(_ value: String) { slowOriginalAsset = value }
    nonisolated static func originalBytes(_ id: String) -> Data { Data("exact-original-resource:\(id):RAW-not-preview".utf8) }
    nonisolated static func image(pixels: Int) throws -> PhotosReviewImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let cg = try XCTUnwrap(context.makeImage())
        return PhotosReviewImage(image: NSImage(cgImage: cg, size: .zero), pixels: CGSize(width: pixels, height: pixels))
    }
    func image(assetID: String, pixels: Int, network: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PhotosReviewImage {
        requests.images.append(assetID)
        imageCount += 1
        requests.maximumConcurrentImages = max(requests.maximumConcurrentImages, imageCount)
        defer { imageCount -= 1 }
        try await Task.sleep(for: assetID == "slow" ? .seconds(5) : .milliseconds(12))
        if (Int(assetID.split(separator: "-").last ?? "0") ?? 0) % 2 == 1, (!network || offline) {
            throw PhotosRepresentationError.cloud
        }
        progress(1)
        return try Self.image(pixels: pixels)
    }
    func original(assetID: String, destination: URL, maximumBytes: Int64, network: Bool,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        requests.originals.append(assetID); requests.originalNetwork.append(network)
        originalCount += 1
        requests.maximumConcurrentOriginals = max(requests.maximumConcurrentOriginals, originalCount)
        defer { originalCount -= 1 }
        if (Int(assetID.split(separator: "-").last ?? "0") ?? 0) % 2 == 1, (!network || offline) {
            throw PhotosLibraryError.iCloudDownloadRequired
        }
        try Data("partial".utf8).write(to: destination)
        try await Task.sleep(for: (slowOriginals || slowOriginalAsset == assetID) ? .seconds(5) : .milliseconds(5))
        let bytes = Self.originalBytes(assetID)
        guard !oversize, Int64(bytes.count) <= maximumBytes else { throw PhotosLibraryError.batchTooLarge }
        try bytes.write(to: destination)
        progress(1)
        return Int64(bytes.count)
    }
    func preheat(assetIDs: [String]) { requests.preheat = assetIDs }
    func stop() {}
}

@MainActor
final class LazyPhotosFixture {
    let root: URL
    let destination: URL
    let journals: URL
    let decisions: PhotosReviewDecisions
    let library: LazyMockPhotosLibrary
    let provider = MockPhotosMedia()
    let defaults: UserDefaults
    private let suite = "Louppe.LazyPhotosTests.\(UUID())"
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/LouppeLazyPhotos-\(UUID())", isDirectory: true)
        destination = root.appendingPathComponent("Export")
        journals = root.appendingPathComponent("Journals")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        decisions = PhotosReviewDecisions(directory: root.appendingPathComponent("Decisions"))
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        ReviewPreferences(advancesAfterDecision: false).save(to: defaults)
        library = LazyMockPhotosLibrary(root: root, provider: provider, decisions: decisions)
    }
    func store() -> SessionStore {
        SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups")),
            photosDecisions: decisions, photosLibrary: library, operationJournalDirectory: journals, reviewDefaults: defaults)
    }
    func batch(size: Int) async throws -> PhotosReviewBatch {
        try await library.prepare(snapshot: library.select(PhotosLibraryQuery()), page: 0, size: size,
            allowNetwork: false, recorder: PhotosBatchProgressRecorder())
    }
    func remove() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

actor LazyMockPhotosLibrary: PhotosLibraryClient {
    let root: URL
    let provider: MockPhotosMedia
    let decisions: PhotosReviewDecisions
    init(root: URL, provider: MockPhotosMedia, decisions: PhotosReviewDecisions) {
        self.root = root; self.provider = provider; self.decisions = decisions
    }
    func authorize() {}
    func albums() -> [PhotosLibraryAlbum] { [] }
    nonisolated func select(_ query: PhotosLibraryQuery) -> PhotosLibrarySnapshot {
        PhotosLibrarySnapshot(id: UUID(), count: 2_003, title: "Mock Photos", query: query)
    }
    func prepare(snapshot: PhotosLibrarySnapshot, page: Int, size: Int, allowNetwork: Bool,
                 recorder: PhotosBatchProgressRecorder) async throws -> PhotosReviewBatch {
        let range = PhotosBatchRange(total: snapshot.count, page: page, size: size)
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = PhotosMediaSession(provider: provider, folder: folder, allowNetwork: allowNetwork)
        let assets = range.indices.map {
            PhotosReviewAsset(id: "asset-\($0)", filename: "Photo.raw", captureDate: Date(timeIntervalSince1970: Double(2_003 - $0)))
        }
        return PhotosReviewBatch.lazy(folder: folder, snapshot: snapshot, range: range,
            assets: assets, decisions: try await decisions.load(), mediaSession: session)
    }
    func remove(_ batch: PhotosReviewBatch) async {
        await batch.mediaSession?.stop()
        try? FileManager.default.removeItem(at: batch.folder)
    }
}
