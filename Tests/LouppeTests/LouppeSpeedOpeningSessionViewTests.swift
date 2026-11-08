#if LOUPPE_TEST_SEAMS
import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Full `SessionView` (bridged toolbar, Browser, Info) over a synthetic opening
/// while 100 ms metadata batches arrive through `SessionStore`'s forwarding of
/// `OpeningSessionState.objectWillChange`. Offscreen, never ordered or keyed.
/// Per batch: synchronous `applyMetadata` + layout/display, then the main-actor
/// work SwiftUI defers to the next run-loop turn (sleep overshoot). Files do
/// not exist; thumbnail/preview reads fail without changing the inventory.
@MainActor
final class LouppeSpeedOpeningSessionViewTests: XCTestCase {
    private enum Configuration: String, CaseIterable {
        case galleryBrowserInfo = "gallery-browser-info"
        case gridBrowser = "grid-browser"
    }

    /// About 500 ready files per 100 ms on a fast local disk (eight ImageIO
    /// workers); 5000 models warm metadata-index hits arriving in one drain.
    private static let batchSizes = [500, 5_000]
    private static let maximumBatches = 200
    private static let batchInterval = Duration.milliseconds(20)

    func testMountedOpeningSessionViewMetadataBatches() async throws {
        try SpeedBenchmark.requireEnabled()
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required") }
        _ = NSApplication.shared
        let report = SpeedReport(suite: "opening-session-view")
        let defaultsName = "LouppeSpeedOpeningSessionView.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        // Never created: every media read fails fast and leaves no files.
        let root = URL(fileURLWithPath: "/private/tmp/louppe-opening-view-absent-\(UUID())", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        for count in SpeedBenchmark.sizes {
            let fixture = makeItems(count: count, root: root)
            for configuration in Configuration.allCases {
                for batchSize in Self.batchSizes {
                    try await measure(configuration: configuration, batchSize: batchSize, fixture: fixture,
                                      defaults: defaults, report: report,
                                      measuresHandoff: batchSize == Self.batchSizes.last)
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try report.finish()
    }

    private func measure(configuration: Configuration, batchSize: Int,
                         fixture: (inventory: [PhotoItem], ready: [PhotoItem]),
                         defaults: UserDefaults, report: SpeedReport, measuresHandoff: Bool) async throws {
        let count = fixture.inventory.count
        let store = SessionStore(reviewDefaults: defaults)
        store.showBrowser = true
        store.showMetadataPanel = configuration == .galleryBrowserInfo
        let opening = OpeningSessionState(snapshot: .init(items: fixture.inventory),
                                          viewMode: configuration == .gridBrowser ? .grid : .gallery,
                                          sourceAccess: nil)
        store.presentOpeningSessionForTesting(opening)

        let controller = NSHostingController(rootView: SessionView(store: store))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrame(NSRect(x: -20_000, y: -20_000, width: 1440, height: 900), display: false)
        defer {
            window.contentViewController = nil
            window.close()
            store.beginTerminationPreparation()
        }
        let host = controller.view
        // Theme frame: includes the bridged toolbar as well as the content.
        let frameView = host.superview ?? host
        try await settle(frameView)
        XCTAssertFalse(window.isVisible, "Speed fixtures must stay offscreen and unshown")
        XCTAssertNotNil(window.toolbar, "SessionView's toolbar must be bridged into the window")
        XCTAssertEqual(host.bounds.width, 1440, accuracy: 1)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.openingSession)

        let documents = nativeDocuments(in: host)
        XCTAssertEqual(documents.count, 1, "\(configuration.rawValue) mounts exactly one native collection")
        let projections = documents.map(\.projectionGeneration)
        let geometries = documents.map(\.geometryGeneration)
        let binds = documents.map(\.contentBindCount)

        // Wake-up jitter with no batch, so deferred samples can be read against it.
        var idleOvershoot: [Double] = []
        for _ in 0..<10 {
            let idle = ContinuousClock.now
            try await Task.sleep(for: Self.batchInterval, tolerance: .zero)
            idleOvershoot.append(max(0, SpeedBenchmark.milliseconds(idle) - 20))
        }
        let batches = min(Self.maximumBatches, (count + batchSize - 1) / batchSize)
        var synchronous: [Double] = []
        var applies: [Double] = []
        var deferred: [Double] = []
        for batch in 0..<batches {
            let lower = batch * batchSize
            let updates = fixture.ready[lower..<min(count, lower + batchSize)].map { OpeningMetadataUpdate(item: $0) }
            let start = ContinuousClock.now
            let accepted = opening.applyMetadata(updates)
            applies.append(SpeedBenchmark.milliseconds(start))
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()
            synchronous.append(SpeedBenchmark.milliseconds(start))
            XCTAssertEqual(accepted, updates.count)
            // Anything SwiftUI defers to the next run-loop turn delays this wake-up.
            let idle = ContinuousClock.now
            try await Task.sleep(for: Self.batchInterval, tolerance: .zero)
            deferred.append(max(0, SpeedBenchmark.milliseconds(idle) - 20))
        }
        try await settle(frameView)
        XCTAssertEqual(opening.readyMetadataCount, min(count, batches * batchSize))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(nativeDocuments(in: host).map(ObjectIdentifier.init), documents.map(ObjectIdentifier.init),
                       "Metadata batches must not remount the native collection")
        XCTAssertEqual(documents.map(\.projectionGeneration), projections,
                       "Metadata batches must not rebuild the O(N) collection projection")
        XCTAssertEqual(documents.map(\.geometryGeneration), geometries,
                       "Metadata batches must not regenerate collection geometry")

        let label = "\(configuration.rawValue).batch-\(batchSize)"
        try report.recordObservations(name: "\(label).apply-layout-display", count: count, samplesMS: synchronous)
        try report.recordObservations(name: "\(label).apply-only", count: count, samplesMS: applies)
        try report.recordObservations(name: "\(label).deferred-main-actor", count: count, samplesMS: deferred)
        let sorted = synchronous.sorted()
        let maxBatch = synchronous.firstIndex(of: sorted.last ?? 0) ?? 0
        print(String(format: "OPENING_VIEW %@ n=%d batches=%d apply-p50=%.3fms apply-p95=%.3fms sync-p50=%.3fms sync-p95=%.3fms sync-max=%.3fms (batch %d) sync-total=%.1fms deferred-p50=%.3fms deferred-p95=%.3fms deferred-max=%.3fms idle-overshoot-max=%.3fms cell-rebinds=%d",
                     label, count, batches, percentile(applies.sorted(), 0.5), percentile(applies.sorted(), 0.95),
                     percentile(sorted, 0.5), percentile(sorted, 0.95), sorted.last ?? 0, maxBatch,
                     synchronous.reduce(0, +), percentile(deferred.sorted(), 0.5), percentile(deferred.sorted(), 0.95),
                     deferred.max() ?? 0, idleOvershoot.max() ?? 0, zip(documents.map(\.contentBindCount), binds).map { $0 - $1 }.reduce(0, +)))

        guard measuresHandoff else { return }
        // Seam approximation of finishScan's swap: authoritative items and
        // derived data are installed untimed (production prepares them off-main).
        store.items = fixture.ready
        store.rebuildDerivedDataForTesting()
        try await settle(frameView)
        let start = ContinuousClock.now
        store.finishOpeningSessionForTesting()
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let handoff = SpeedBenchmark.milliseconds(start)
        let idle = ContinuousClock.now
        try await Task.sleep(for: Self.batchInterval, tolerance: .zero)
        let handoffDeferred = max(0, SpeedBenchmark.milliseconds(idle) - 20)
        XCTAssertNil(store.openingSession)
        XCTAssertFalse(window.isVisible)
        try report.recordObservations(name: "\(configuration.rawValue).finish-handoff", count: count, samplesMS: [handoff])
        print(String(format: "OPENING_VIEW %@.finish-handoff n=%d sync=%.3fms deferred=%.3fms",
                     configuration.rawValue, count, handoff, handoffDeferred))
    }

    private func makeItems(count: Int, root: URL) -> (inventory: [PhotoItem], ready: [PhotoItem]) {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        var inventory: [PhotoItem] = []
        var ready: [PhotoItem] = []
        inventory.reserveCapacity(count)
        ready.reserveCapacity(count)
        for index in 0..<count {
            let name = String(format: "OPENING_%06d.JPG", index)
            let url = root.appendingPathComponent(name)
            inventory.append(PhotoItem(primaryFile: PhotoFile(
                id: name, url: url, captureDate: nil, cameraModel: nil, lensModel: nil,
                fileSize: 1, metadataIsLoaded: false)))
            ready.append(PhotoItem(primaryFile: PhotoFile(
                id: name, url: url, captureDate: date.addingTimeInterval(Double(index)),
                cameraModel: "Synthetic camera", lensModel: "Synthetic lens",
                aperture: 2.8, shutterSpeed: 1 / 250, iso: 400, fileSize: 1, metadataIsLoaded: true)))
        }
        return (inventory, ready)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    private func nativeDocuments(in view: NSView) -> [ReviewCollectionDocument] {
        (view as? ReviewCollectionDocument).map { [$0] } ?? view.subviews.flatMap { nativeDocuments(in: $0) }
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }
}
#endif
