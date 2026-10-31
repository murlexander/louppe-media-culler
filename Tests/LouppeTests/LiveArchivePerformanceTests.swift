import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Louppe

/// Explicitly opted-in, read-only inspection of a mounted archive. Unlike a
/// SessionStore folder open, this never obtains source save/mutation authority.
@MainActor
final class LiveArchivePerformanceTests: XCTestCase {
    func testReadOnlyMountedArchiveOpeningAndNavigation() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_LIVE_ARCHIVE_ROOT"],
              let output = ProcessInfo.processInfo.environment["LOUPPE_LIVE_ARCHIVE_OUTPUT"] else {
            throw XCTSkip("Requires an explicitly selected live archive and evidence directory")
        }
        guard NSScreen.main != nil else { throw XCTSkip("Requires WindowServer") }
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let evidence = URL(fileURLWithPath: output, isDirectory: true)
        let sourcePath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let outputPath = evidence.resolvingSymlinksInPath().standardizedFileURL.path
        guard outputPath != sourcePath, !outputPath.hasPrefix(sourcePath + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-LiveReadOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let persistence = SessionPersistence(backupDirectory: scratch.appendingPathComponent("backups"))
        let authority = MediaReadAccess(authorizedURL: folder, resourceAccess: .live)
        let lease = authority.begin()
        defer { withExtendedLifetime(lease) {} }
        let source = try SessionPersistence.SourceFolderIdentity.capture(at: folder)
        let sidecar = folder.appendingPathComponent(SessionConstants.sidecarName)
        let originalSidecar = try? Data(contentsOf: sidecar)
        var records: [[String: Any]] = []
        func saveReport() throws {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("live-archive.json"))
        }
        var prepared: SessionOpeningPreparation?
        for iteration in 0..<4 {
            let mount = ArchiveOpeningMount(authority: authority)
            defer { mount.close() }
            let recorder = SessionOpeningRecorder()
            let start = ContinuousClock.now
            let task = Task.detached(priority: .userInitiated) {
                try await SessionOpeningWorker.prepare(folder: folder, pairingMode: .together,
                    persistence: persistence, recorder: recorder,
                    preview: { snapshot in await mount.show(snapshot) },
                    hooks: .init(metadataIndex: ArchiveMetadataIndex(folder: folder,
                        cacheDirectory: scratch.appendingPathComponent("index"))))
            }
            var firstPixels: Double?
            var peak = residentBytes()
            var gaps: [Double] = []
            var previous = ContinuousClock.now
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    gaps.append(SpeedBenchmark.milliseconds(previous))
                    previous = .now
                    peak = max(peak, residentBytes())
                    if firstPixels == nil, mount.hasVisiblePixels() {
                        firstPixels = SpeedBenchmark.milliseconds(start)
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            do { prepared = try await task.value }
            catch { sampler.cancel(); await sampler.value; throw error }
            let ready = SpeedBenchmark.milliseconds(start)
            sampler.cancel(); await sampler.value
            // The app writes the metadata cache after Ready; later iterations reuse it.
            let commitStart = ContinuousClock.now
            let commit = prepared?.metadataCommit
            _ = await Task.detached(priority: .utility) { commit?.run(isCancelled: { false }) }.value
            let postReadyCommit = SpeedBenchmark.milliseconds(commitStart)
            let metrics = recorder.snapshot()
            records.append(["kind": "opening", "iteration": iteration,
                "metadataIndex": iteration == 0 ? "cold-isolated" : "warm-isolated",
                "filesystemCache": "uncontrolled-warmed-by-inventory-and-prior-profile",
                "firstMatchingVisibleThumbnailMS": firstPixels.map { $0 as Any } ?? NSNull(),
                "fullWorkerReadinessMS": ready, "postReadyIndexCommitMS": postReadyCommit,
                "physicalFiles": metrics.physicalFileCount,
                "items": metrics.itemCount,
                "stagesMS": metrics.secondsByStage.reduce(into: [String: Double]()) { $0[$1.key.rawValue] = $1.value * 1000 },
                "peakResidentBytes": peak, "maxMainActorSamplingGapMS": gaps.max() ?? 0,
                "samplingIntervalMS": 10, "physicalFrameMeasurement": false])
            try saveReport()
            mount.close()
        }
        let items = try XCTUnwrap(prepared).restoration.items
        XCTAssertFalse(items.isEmpty)
        let name = "LouppeLiveArchive.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: CameraQualityWarningPreferences.Keys.isEnabled)
        defaults.set(true, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(true, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        let store = SessionStore(reviewDefaults: defaults)
        store.pauseQualityCueAnalysis(userInitiated: true)
        store.items = items
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        defer { store.beginTerminationPreparation() }
        // No sourceFolder or persistence access is installed: even an accidental
        // rating/save path cannot write this source. This is a viewing harness.
        for background in [false, true] {
            if background {
                store.resumeQualityCueAnalysis()
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while store.qualityCueCoverageCountsForTesting.measured < 2, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertGreaterThan(store.qualityCueCoverageCountsForTesting.measured, 0,
                    "Real quality work must make progress before this can be called a background-contention sample")
                records.append(["kind": "background-before-navigation",
                    "measured": store.qualityCueCoverageCountsForTesting.measured])
                try saveReport()
            }
            for mode in [ViewMode.grid, .gallery] {
                store.viewMode = mode
                let view = mode == .grid ? AnyView(GridView(store: store)) : AnyView(BrowserView(store: store))
                let host = NSHostingView(rootView: view.environment(\.mediaReadAccess, authority))
                let window = NSWindow(contentRect: .init(x: 0, y: 0,
                    width: mode == .grid ? 1100 : BrowserView.width, height: 720),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                let targets = [items.count / 2, items.count - 1, items.count / 3, 0]
                    .compactMap { index in
                        items.indices.dropFirst(index).first { items[$0].hasVisualPreview && items[$0].isSupported }
                            ?? items.indices.prefix(index).reversed().first { items[$0].hasVisualPreview && items[$0].isSupported }
                    }
                XCTAssertFalse(targets.isEmpty, "The archive has no supported visual navigation targets")
                for pass in 0..<2 {
                    for target in targets {
                        let start = ContinuousClock.now
                        store.setIndex(target)
                        let matched = await waitForPixels(items[target], in: host)
                        records.append(["kind": "navigation", "surface": mode == .grid ? "grid" : "browser",
                            "qualityBackgroundRequested": background,
                            "pass": pass, "cache": pass == 0 ? "first-travel-shared-cache" : "repeat-travel",
                            "index": target, "matchingVisiblePixels": matched,
                            "inputToMatchingPixelsMS": SpeedBenchmark.milliseconds(start),
                            "residentBytes": residentBytes(), "physicalFrameMeasurement": false])
                        try saveReport()
                        XCTAssertTrue(matched, "A supported real archive target failed to display")
                        XCTAssertEqual(store.currentItem?.id, items[target].id)
                        let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first
                        XCTAssertEqual(try XCTUnwrap(scroll).contentView.bounds.minX, 0, accuracy: 0.5)
                    }
                }
                window.orderOut(nil); window.contentView = nil; window.close()
            }
        }
        store.pauseQualityCueAnalysis(userInitiated: true)
        records.append(["kind": "background", "measured": store.qualityCueCoverageCountsForTesting.measured,
            "total": store.qualityCueCoverageCountsForTesting.total, "allWorkDrain": false])
        XCTAssertTrue(source.matches(folder: folder))
        XCTAssertEqual(try? Data(contentsOf: sidecar), originalSidecar)
        await ImagePipeline.shared.waitForPendingDiskWrites()
        try saveReport()
    }

    private func waitForPixels(_ item: PhotoItem, in host: NSView) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            host.layoutSubtreeIfNeeded()
            if descendants(host).compactMap({ $0 as? ThumbnailRenderMarker.MarkerView }).contains(where: {
                $0.hasImage && $0.revision == item.contentRevision && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return false
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

@MainActor
private final class ArchiveOpeningMount {
    let authority: MediaReadAccess
    private var host: NSHostingView<OpeningSessionView>?
    private var window: NSWindow?
    private var revisions: Set<PhotoContentRevision> = []
    init(authority: MediaReadAccess) { self.authority = authority }
    func show(_ snapshot: OpeningSessionSnapshot) {
        revisions = Set(snapshot.items.map(\.contentRevision))
        let state = OpeningSessionState(snapshot: snapshot, viewMode: .grid, sourceAccess: authority)
        let host = NSHostingView(rootView: OpeningSessionView(state: state, cancel: {}))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        self.host = host; self.window = window
    }
    func hasVisiblePixels() -> Bool {
        guard let host else { return false }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return descendants(host).compactMap { $0 as? ThumbnailRenderMarker.MarkerView }.contains {
            $0.hasImage && revisions.contains($0.revision) && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
    }
    func close() { window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil; host = nil; revisions = [] }
}
