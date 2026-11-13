import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class PhotosOriginalVideoTests: XCTestCase {
    func testMultipleDrainWaitersIncludingCancelledRetirementResumeAfterWorkerExit() async throws {
        let gate = PhotosVideoScanGate()
        let fixture = try PhotosVideoFixture(scanVideo: gate.scan)
        defer { gate.release(); fixture.remove() }
        let item = try XCTUnwrap(fixture.batch().reviewItems?.first)
        let original = Task { try await fixture.session.original(for: item) }
        await gate.waitForStart()
        let premature = expectation(description: "Drain must retain staging through native worker exit")
        premature.isInverted = true
        let retirements = (0..<3).map { _ in
            Task {
                await fixture.session.stopAndDrainOriginalRequests()
                if !gate.firstExited { premature.fulfill() }
            }
        }
        retirements[0].cancel()
        await fixture.provider.waitForStop()
        await fulfillment(of: [premature], timeout: 0.2)
        gate.release()
        for retirement in retirements { await retirement.value }
        do { let lease = try await original.value; await lease.close(); XCTFail("Retired original must not publish") }
        catch is CancellationError {} catch PhotosRepresentationError.retired {}
        await fixture.session.stopAndDrainOriginalRequests()
        XCTAssertTrue(gate.firstSourceSurvivedUntilExit)
        let requests = await fixture.session.inFlightRequestCountForTesting
        XCTAssertEqual(requests, 0)
    }

    func testBatchRetirementWaitsForOriginalScanBeforeRemovingStaging() async throws {
        let gate = PhotosVideoScanGate()
        let fixture = try PhotosVideoFixture(scanVideo: gate.scan)
        defer { gate.release(); fixture.remove() }
        let batch = try fixture.batch()
        let item = try XCTUnwrap(batch.reviewItems?.first)
        let service = PhotosLibraryService(cacheRoot: fixture.root,
            decisionsStore: PhotosReviewDecisions(directory: fixture.root.appendingPathComponent("Decisions")),
            operationJournalDirectory: fixture.root.appendingPathComponent("Operations"))
        let original = Task { try await fixture.session.original(for: item) }
        await gate.waitForStart()
        let prematureRemoval = expectation(description: "Retirement must wait for the held original worker")
        prematureRemoval.isInverted = true
        let removal = Task {
            await service.remove(batch)
            if !gate.firstExited { prematureRemoval.fulfill() }
        }
        await fixture.provider.waitForStop()
        await fulfillment(of: [prematureRemoval], timeout: 0.5)
        if let source = gate.firstSourceURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                "Responsive Stop must not let batch cleanup remove a worker's source")
        } else { XCTFail("The worker must have acquired an original") }
        gate.release()
        do { let lease = try await original.value; await lease.close(); XCTFail("Retired original must not publish") }
        catch is CancellationError {} catch PhotosRepresentationError.retired {}
        await removal.value
        XCTAssertTrue(gate.firstSourceSurvivedUntilExit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
    }

    func testPortraitAndRotatedOriginalsReachActualGalleryWithOrientedDimensions() async throws {
        for name in ["portrait", "rotated"] {
            let fixture = try PhotosVideoFixture(name: name)
            defer { fixture.remove() }
            let membership = try fixture.batch()
            let requestsBefore = await fixture.provider.originalRequests
            XCTAssertEqual(requestsBefore, 0, "Opening membership must remain metadata-only")
            let item = try XCTUnwrap(membership.reviewItems?.first)
            XCTAssertNil(item.videoDimensions)
            let lease = try await fixture.session.original(for: item)
            let scan = await Task.detached { VideoMetadataExtractor.scanInfo(for: lease.item.primaryURL) }.value
            XCTAssertEqual(scan.dimensions, CGSize(width: 180, height: 320), "Fixture must exercise oriented portrait metadata")
            XCTAssertEqual(lease.item.videoDimensions, scan.dimensions)
            XCTAssertEqual(lease.item.videoCodec, scan.codec)
            XCTAssertEqual(lease.item.videoFrameRate, scan.frameRate)
            XCTAssertEqual(lease.item.id, item.id)
            XCTAssertEqual(lease.item.captureDateEvidence, item.captureDateEvidence)
            XCTAssertEqual(lease.item.primaryFile.metadataSnapshot, item.primaryFile.metadataSnapshot)
            XCTAssertEqual(try Data(contentsOf: lease.item.primaryURL), try Data(contentsOf: fixture.provider.source))
            XCTAssertNotNil(lease.item.primaryFile.scannedIdentity)
            let playback = VideoPlaybackController()
            let controller = OffscreenCapture.host(GalleryVideoPlayerView(item: lease.item, playback: playback),
                defaults: fixture.defaults, appearance: .light, bridgesScene: false)
            try await OffscreenCapture.capture(controller, size: CGSize(width: 800, height: 600),
                title: "Disposable Photos portrait", appearance: .light, to: fixture.root.appendingPathComponent("gallery.png")) { host in
                let surface = try XCTUnwrap(OffscreenCapture.descendants(of: host.view).compactMap { $0 as? GalleryVideoSurfaceView }.first)
                surface.layoutSubtreeIfNeeded()
                print("PHOTOS VIDEO \(name) size=\(surface.presentationSize) bounds=\(surface.bounds) layer=\(surface.playerLayer.frame)")
                XCTAssertEqual(surface.presentationSize, CGSize(width: 180, height: 320))
                XCTAssertEqual(surface.playerLayer.frame, CGRect(x: 231.25, y: 0, width: 337.5, height: 600))
                XCTAssertEqual(surface.playerLayer.videoGravity, .resizeAspectFill)
            }
            playback.stop()
            // Verify the actual oriented frame has distinct full-width end bars;
            // a landscape aspect-fill layer would discard both of these edges.
            let frame = try await Task.detached {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: lease.item.primaryURL))
                generator.appliesPreferredTrackTransform = true
                return try await generator.image(at: .zero).image
            }.value
            XCTAssertEqual(frame.width, 180)
            XCTAssertEqual(frame.height, 320)
            let bitmap = NSBitmapImageRep(cgImage: frame)
            let top = try XCTUnwrap(bitmap.colorAt(x: 90, y: 12)?.usingColorSpace(.deviceRGB))
            let bottom = try XCTUnwrap(bitmap.colorAt(x: 90, y: 308)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(abs(top.redComponent - bottom.redComponent), 0.7)
            XCTAssertGreaterThan(abs(top.blueComponent - bottom.blueComponent), 0.7)
            await lease.close()
            await fixture.session.stop()
            let charged = await fixture.session.originalBytes
            XCTAssertEqual(charged, 0)
        }
    }
    func testCancellationDrainsScanBeforeReleasingOriginalLaneAndLeavesActorResponsive() async throws {
        let gate = PhotosVideoScanGate()
        let fixture = try PhotosVideoFixture(scanVideo: gate.scan)
        defer { gate.release(); fixture.remove() }
        let item = try XCTUnwrap(fixture.batch().reviewItems?.first)
        let first = Task { try await fixture.session.original(for: item) }
        await gate.waitForStart()
        let second = Task { try await fixture.session.original(for: item) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await fixture.session.inFlightRequestCountForTesting < 2 {
            guard ContinuousClock.now < deadline else { gate.release(); first.cancel(); second.cancel(); throw CocoaError(.coderInvalidValue) }
            await Task.yield()
        }
        // These actor calls must complete while the native metadata worker is
        // still held. Cancellation must not release its lane or delete its file.
        await fixture.session.setOriginalNetwork(true)
        first.cancel()
        let requested = await fixture.provider.originalRequests
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertTrue(gate.offMain)
        XCTAssertFalse(gate.firstExited, "Consent update completed while the worker is still held")
        gate.release()
        do { _ = try await first.value; XCTFail("Cancelled metadata must not publish a lease") }
        catch is CancellationError {}
        let lease = try await second.value
        XCTAssertEqual(lease.item.videoDimensions, CGSize(width: 180, height: 320))
        await lease.close()
        await fixture.session.stop()
        let charged = await fixture.session.originalBytes
        XCTAssertEqual(charged, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.appendingPathComponent("Originals").path), [])
    }

    func testStopReturnsWhileScanDrainsAndPreventsLateLeasePublication() async throws {
        let gate = PhotosVideoScanGate()
        let fixture = try PhotosVideoFixture(scanVideo: gate.scan)
        defer { gate.release(); fixture.remove() }
        let item = try XCTUnwrap(fixture.batch().reviewItems?.first)
        let task = Task { try await fixture.session.original(for: item) }
        await gate.waitForStart()
        await fixture.session.stop()
        XCTAssertFalse(gate.firstExited, "Stop must return without waiting for the scan bridge")
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        do { _ = try await task.value; XCTFail("Closed review must not publish metadata or an original") }
        catch is CancellationError {} catch PhotosRepresentationError.retired {}
        let charged = await fixture.session.originalBytes
        XCTAssertEqual(charged, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.appendingPathComponent("Originals").path), [])
    }

}

@MainActor
struct PhotosVideoFixture {
    let root: URL
    let folder: URL
    let provider: FixturePhotosVideoProvider
    let session: PhotosMediaSession
    let defaults: UserDefaults
    init(name: String = "rotated",
         scanVideo: @escaping @Sendable (URL) -> VideoScanInfo = { VideoMetadataExtractor.scanInfo(for: $0) }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosVideo-\(UUID())")
        folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("louppe-photos-review-v1".utf8).write(to: folder.appendingPathComponent(".louppe-photos-batch"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        provider = FixturePhotosVideoProvider(source: repository.appendingPathComponent("Tests/Fixtures/PhotosPortrait/\(name).mov"))
        session = PhotosMediaSession(provider: provider, folder: folder, scanVideo: scanVideo)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "PhotosVideo.\(UUID())"))
    }
    func batch() throws -> PhotosReviewBatch {
        let date = Date(timeIntervalSince1970: 100)
        let decision = PhotosReviewDecision(.init(fileID: "video", rating: .yes, ratedAt: date,
            starRating: .four, starsChangedAt: date, colorLabel: .purple, colorChangedAt: date))
        return try PhotosReviewBatch.prepared(folder: folder,
            snapshot: .init(id: UUID(), count: 1, title: "Disposable Photos", query: .init()),
            range: .init(entireSelection: 1),
            assets: [.init(id: "video", filename: "Video 1", captureDate: date, mediaKind: .video, duration: 0.6)],
            decisions: ["video": decision], mediaSession: session)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

actor FixturePhotosVideoProvider: PhotosMediaProvider {
    nonisolated let source: URL
    private(set) var originalRequests = 0
    private var stopped = false
    private var stopWaiter: CheckedContinuation<Void, Never>?
    func waitForStop() async {
        guard !stopped else { return }
        await withCheckedContinuation { stopWaiter = $0 }
    }
    init(source: URL) { self.source = source }
    func image(assetID: String, pixels: Int, network: Bool,
               progress: @escaping @Sendable (Double) -> Void) throws -> PhotosReviewImage {
        throw PhotosRepresentationError.unavailable
    }
    func originalFilename(assetID: String) -> String? { "PORTRAIT.mov" }
    func original(assetID: String, destination: URL, maximumBytes: Int64, network: Bool,
                  progress: @escaping @Sendable (Double) -> Void) throws -> Int64 {
        originalRequests += 1
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes <= maximumBytes else { throw PhotosLibraryError.batchTooLarge }
        try FileManager.default.copyItem(at: source, to: destination)
        return bytes
    }
    func preheat(assetIDs: [String]) {}
    func stop() {
        stopped = true
        stopWaiter?.resume()
        stopWaiter = nil
    }
}

/// Deterministic native-worker boundary: no sleep races or foreground input.
private final class PhotosVideoScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var count = 0
    private var ranOffMain = true
    private var firstFinished = false
    private var firstSource: URL?
    private var sourceSurvived = false
    var firstExited: Bool { lock.withLock { firstFinished } }
    var firstSourceURL: URL? { lock.withLock { firstSource } }
    var firstSourceSurvivedUntilExit: Bool { lock.withLock { sourceSurvived } }
    var calls: Int { lock.withLock { count } }
    var offMain: Bool { lock.withLock { ranOffMain } }
    func waitForStart() async {
        await withCheckedContinuation { value in
            lock.withLock {
                if started { value.resume() } else { continuation = value }
            }
        }
    }
    func scan(_ url: URL) -> VideoScanInfo {
        let (first, waiter) = lock.withLock {
            count += 1; ranOffMain = ranOffMain && !Thread.isMainThread
            if count == 1 { firstSource = url }
            started = true
            let waiter = continuation; continuation = nil
            return (count == 1, waiter)
        }
        waiter?.resume()
        if first {
            _ = semaphore.wait(timeout: .now() + 10)
            lock.withLock {
                sourceSurvived = FileManager.default.fileExists(atPath: url.path)
                firstFinished = true
            }
        }
        return VideoScanInfo(duration: 0.6, dimensions: CGSize(width: 180, height: 320),
            codec: "H.264", frameRate: 10, isPlayable: true)
    }
    func release() { semaphore.signal() }
}
