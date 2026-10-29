import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// Matching-revision mounted pixels across first-visit/cached destinations and
/// active/paused quality+hash work. Warm local filesystem; no physical-frame claim.
/// Hash delay is an explicit 30 ms injection, never an SD-card simulation.
@MainActor
final class LouppeSpeedInteractionMatrixTests: XCTestCase {
    func testMountedCachedUncachedAndActivePausedMatrix() async throws {
        try SpeedBenchmark.requireEnabled()
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required") }
        _ = NSApplication.shared
        let report = SpeedReport(suite: "interaction-matrix")
        let count = min(SpeedBenchmark.sizes.max() ?? 1000, 10_000)
        let root = URL(fileURLWithPath: "/private/tmp/louppe-contention-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try jpegBytes()
        for index in 0..<count {
            try bytes.write(to: folder.appendingPathComponent(String(format: "FRAME_%06d.JPG", index)))
        }
        let items = try await Task.detached { try FolderScanner.scan(folder, progress: { _ in }) }.value
        for item in items { item.rating = .yes }
        let persistence = SessionPersistence(backupDirectory: root.appendingPathComponent("backups"))
        let read = await persistence.read(for: folder)
        let saved = await persistence.save(
            SessionSnapshotCapture(sourcePath: folder.path, items: items, retainedEntries: [], originPaths: [:]).makeSession(),
            for: folder, sequence: 1, access: try XCTUnwrap(read.access))
        XCTAssertEqual(saved, .savedToSidecar)
        let defaultsName = "LouppeContention.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: CameraQualityWarningPreferences.Keys.isEnabled)
        defaults.set(true, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(true, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        let store = SessionStore(persistence: persistence, saveTrailingDelay: 0.01, saveMaximumDelay: 0.05,
            reviewDefaults: defaults, sessionContentVerification: { file, proof in
                try await Task.sleep(for: .milliseconds(30))
                return try await SessionContentVerificationLane.shared.verify(file, knownProof: proof)
            })
        store.openFolder(folder)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !isReady(store), ContinuousClock.now < deadline {
            if let error = store.scanError { XCTFail(error); break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(isReady(store))
        store.viewMode = .grid
        let host = NSHostingView(rootView: SessionView(store: store))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close(); store.beginTerminationPreparation() }
        try await pixels(store.items[0], in: host)
        for paused in [false, true] {
            if paused {
                store.pauseQualityCueAnalysis(userInitiated: true)
                store.toggleSessionContentChecks()
                _ = await store.waitForPersistenceIdleForTesting()
            }
            for (modeIndex, mode) in [ViewMode.grid, .gallery].enumerated() {
                store.viewMode = mode
                store.showBrowser = true
                // Each matrix cell has different, previously unvisited destinations.
                let base = (paused ? 300 : 0) + modeIndex * 100
                let targets = [count - 1 - base, count / 2 - base, count / 3 - base, count / 4 - base]
                    .map { max(1, $0) }
                for cached in [false, true] {
                    var samples: [Double] = []
                    var gaps: [Double] = []
                    let sampler = Task { @MainActor in
                        var previous = ContinuousClock.now
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(2))
                            gaps.append(SpeedBenchmark.milliseconds(previous))
                            previous = .now
                        }
                    }
                    for (repetition, target) in targets.enumerated() {
                        store.setIndex(0)
                        try await pixels(store.items[0], in: host)
                        if !paused { store.setStarRating(repetition.isMultiple(of: 2) ? .one : .five, at: target) }
                        let start = ContinuousClock.now
                        store.setIndex(target)
                        try await pixels(store.items[target], in: host)
                        if repetition > 0 { samples.append(SpeedBenchmark.milliseconds(start)) }
                        XCTAssertEqual(store.currentItem?.id, store.items[target].id)
                    }
                    sampler.cancel()
                    await sampler.value
                    let state = "\(paused ? "paused" : "active").\(cached ? "cached" : "uncached-first-visit")"
                    try report.recordSamples(name: "\(mode.rawValue).\(state).input-to-matching-thumbnail", count: count, samplesMS: samples)
                    print("INTERACTION_MATRIX \(mode.rawValue).\(state) max-mainactor-gap-ms=\(gaps.max() ?? 0) physical-frame-measurement=false")
                }
            }
        }
        store.pauseQualityCueAnalysis(userInitiated: true)
        store.beginTerminationPreparation()
        let result = await store.saveSessionForTermination()
        XCTAssertNotEqual(result?.canDiscardInMemoryState, false)
        let idle = await store.waitForPersistenceIdleForTesting()
        XCTAssertTrue(idle)
        XCTAssertEqual(try Data(contentsOf: items[0].primaryURL), bytes)
        XCTAssertEqual(try Data(contentsOf: items[count - 1].primaryURL), bytes)
        try report.finish()
    }

    private func isReady(_ store: SessionStore) -> Bool {
        if case .ready = store.phase { return true }
        return false
    }

    private func pixels(_ item: PhotoItem, in host: NSView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        repeat {
            host.layoutSubtreeIfNeeded()
            if descendants(host).compactMap({ $0 as? ThumbnailRenderMarker.MarkerView }).contains(where: {
                $0.hasImage && $0.revision == item.contentRevision && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }) { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
        XCTFail("Current photo did not display during background work")
        throw NSError(domain: "LouppeContention", code: 1)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func jpegBytes() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 768, bitsPerComponent: 8,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.45, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
