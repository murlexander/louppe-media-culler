import AppKit
import CoreImage
import XCTest
@testable import Louppe

@MainActor
final class ActualSizeCancellationTests: XCTestCase {
    func testReturnToCancelledVisibleRegionRequestsFreshTilesWithoutFailure() async throws {
        try await exerciseReturnToRegion(failsRenewedTile: false)
    }

    func testGenuineRenewedTileFailureStillReportsUnavailable() async throws {
        try await exerciseReturnToRegion(failsRenewedTile: true)
    }

    private func exerciseReturnToRegion(failsRenewedTile: Bool) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tile-cancellation-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pan.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8192, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        memset(try XCTUnwrap(bitmap.bitmapData), 127, bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
        let item = PhotoItem(primaryFile: PhotoFile(
            id: UUID().uuidString, url: url, captureDate: nil,
            cameraModel: nil, lensModel: nil, fileSize: Int64(try Data(contentsOf: url).count)
        ))
        let probe = TileCancellationProbe()
        defer { probe.release() }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let pipeline = HighResolutionImagePipeline(testingSourceConcurrency: 2, tileRenderer: { source, coordinate in
            let call = probe.begin(coordinate)
            if call == 1 { probe.wait() }
            if failsRenewedTile, coordinate.column == 0, call > 1 { return nil }
            guard let rect = coordinate.pixelRect(sourceSize: source.pixelSize),
                  let image = context.createCGImage(source.image, from: rect) else { return nil }
            return ZoomImageTile(coordinate: coordinate, pixelRect: rect, image: image)
        }, source: { revision, key, decoder in
            guard let image = CIImage(contentsOf: revision.url, options: [.applyOrientationProperty: true]) else { return nil }
            return ZoomImageSource(key: key, image: image, pixelSize: image.extent.size,
                                   sourceRevision: revision, decoder: decoder)
        })
        let scroll = ActualSizeScrollView(tilePipeline: pipeline)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 240, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroll
        defer { scroll.prepareForRemoval(); window.contentView = nil; window.orderOut(nil) }
        let viewport = ActualSizeViewport()
        viewport.update(position: NormalizedImagePosition(x: 0, y: 0.5))
        var failures: [Bool] = []
        var loading: [Bool] = []
        var representations: [PhotoRepresentation] = []
        scroll.configure(item: item, preview: nil, showsClippingWarnings: false,
                         viewport: viewport, onLoading: { loading.append($0) },
                         onRenderingFailure: { failures.append($0) },
                         onRepresentation: { representations.append($0) })
        scroll.layoutSubtreeIfNeeded()
        try await waitUntil { probe.started == 2 }
        XCTAssertEqual(probe.count(column: 0), 1)

        // Do not yield the main actor: cancelled continuations cannot resume
        // until both actual clip-view pans have returned to the original region.
        scroll.contentView.scroll(to: CGPoint(x: scroll.documentView!.bounds.maxX - 240, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        for _ in 0..<10 { await Task.yield() }
        probe.release()
        await pipeline.waitForSourceWorkForTesting()
        try await waitUntil { loading.last == false }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(probe.count(column: 0), 2, "Returning to A must renew its cancelled visible tile")
        if failsRenewedTile {
            XCTAssertEqual(failures.last, true, "Real render failures must still reach the RAW-unavailable presentation")
        } else {
            XCTAssertFalse(failures.contains(true), "An old cancelled waiter must never become a visible rendering failure")
            XCTAssertEqual(representations.last, .raw) // all visible source-pixel tiles ready
        }
        // Include any replacement operations submitted after the first barrier.
        await pipeline.waitForSourceWorkForTesting()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard condition() else {
            XCTFail("Timed out waiting for actual viewport tile work")
            throw NSError(domain: "ActualSizeCancellationTests", code: 1)
        }
    }
}

private final class TileCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var counts: [ZoomTileCoordinate: Int] = [:]
    var started: Int { lock.withLock { counts.values.reduce(0, +) } }
    func count(column: Int) -> Int { lock.withLock { counts.filter { $0.key.column == column }.values.reduce(0, +) } }
    func begin(_ coordinate: ZoomTileCoordinate) -> Int {
        lock.withLock { counts[coordinate, default: 0] += 1; return counts[coordinate]! }
    }
    func wait() { _ = gate.wait(timeout: .now() + 8) }
    func release() { for _ in 0..<20 { gate.signal() } }
}
