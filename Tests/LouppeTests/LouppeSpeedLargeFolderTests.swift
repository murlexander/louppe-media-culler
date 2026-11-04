import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// Real files and mounted surfaces. These measurements establish a native
/// baseline; a matching pixel-state publication is not a physical display frame.
@MainActor
final class LouppeSpeedLargeFolderTests: XCTestCase {
    func testMountedLargeGridAndBrowserNavigation() async throws {
        try SpeedBenchmark.requireEnabled()
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required") }
        _ = NSApplication.shared
        let report = SpeedReport(suite: "large-folder-mounted")
        var resources: [[String: Any]] = []
        for count in Array(Set(SpeedBenchmark.sizes.map { min($0, 10_000) })).sorted() {
            let root = URL(fileURLWithPath: "/private/tmp/louppe-large-mounted-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bytes = try jpegBytes()
            for index in 0..<count {
                try bytes.write(to: root.appendingPathComponent(String(format: "FRAME_%06d.JPG", index)))
            }
            let items = try await Task.detached {
                try FolderScanner.scan(root, progress: { _ in })
            }.value
            XCTAssertEqual(items.count, count)
            let defaultsName = "LouppeLargeMounted.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isEnabled)
            let store = SessionStore(reviewDefaults: defaults)
            store.items = items
            store.rebuildDerivedDataForTesting()
            store.phase = .ready
            store.pauseQualityCueAnalysis(userInitiated: true)
            defer { store.beginTerminationPreparation() }

            for browser in [false, true] {
                let label = browser ? "browser" : "grid"
                store.viewMode = browser ? .gallery : .grid
                store.currentIndex = 0
                let view = browser ? AnyView(BrowserView(store: store)) : AnyView(GridView(store: store))
                let started = ContinuousClock.now
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                    width: browser ? BrowserView.width : 1100, height: 720),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                try await waitForVisiblePixels(items[0], in: host)
                print("LARGE_MOUNT first_\(label)_matching_pixels_ms=\(SpeedBenchmark.milliseconds(started)) count=\(count) cache_state=first_grid_then_shared_browser filesystem=warm")
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)

                var gaps: [Double] = []
                var peakRSS = residentBytes()
                let sampler = Task { @MainActor in
                    var previous = ContinuousClock.now
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(2))
                        let now = ContinuousClock.now
                        gaps.append(milliseconds(previous.duration(to: now)))
                        peakRSS = max(peakRSS, residentBytes())
                        previous = now
                    }
                }
                defer { sampler.cancel() }
                await Task.yield() // Start sampling before cache-hit navigation can finish synchronously.
                for (name, target) in [("middle", count / 2), ("tail", count - 1), ("reverse", count / 3), ("head", 0)] {
                    var inputSamples: [Double] = []
                    try await report.measureAsync(name: "\(label).jump-cycle.\(name).including-reset", count: count) {
                        // Move away first so every repetition generates a follow request.
                        store.setIndex(target == 0 ? count - 1 : 0)
                        try await self.waitForVisiblePixels(items[store.currentIndex], in: host)
                        let input = ContinuousClock.now
                        store.setIndex(target)
                        try await self.waitForVisiblePixels(items[target], in: host)
                        inputSamples.append(SpeedBenchmark.milliseconds(input))
                        XCTAssertEqual(store.currentItem?.id, items[target].id)
                        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
                    }
                    try report.recordSamples(name: "\(label).input-to-matching-pixels.\(name).warm-after-first", count: count,
                        samplesMS: Array(inputSamples.dropFirst()))
                }
                sampler.cancel()
                await sampler.value
                let document = descendants(host).compactMap { $0 as? ReviewCollectionDocument }.first
                resources.append(["surface": label, "count": count,
                    "peakResidentBytes": peakRSS, "residentAfterNavigationBytes": residentBytes(),
                    "realizedItemCount": document?.realizedItemCount ?? 0,
                    "retainedHostCount": document?.retainedHostCount ?? 0,
                    "createdHostCount": document?.createdHostCount ?? 0,
                    "mainActorGapSamplesMS": gaps, "maxMainActorGapMS": gaps.max() ?? 0,
                    "samplingIntervalMS": 2, "physicalFrameMeasurement": false])
                // The synchronous native gesture tracker is a correctness gate;
                // exclude its deliberate tracking loop from navigation gap samples.
                try VerticalScrollRegression.assertWheelInputStaysVertical(scroll)
            }
            await ImagePipeline.shared.waitForPendingDiskWrites()
            resources.append(["surface": "after-surface-teardown-and-disk-drain", "count": count,
                              "residentBytes": residentBytes(), "physicalFrameMeasurement": false])
            for item in items {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: item.primaryURL.path)[.size] as? Int, bytes.count)
            }
            XCTAssertEqual(try Data(contentsOf: items[0].primaryURL), bytes)
            XCTAssertEqual(try Data(contentsOf: items[count - 1].primaryURL), bytes)
        }
        try report.finish()
        let output = ProcessInfo.processInfo.environment["LOUPPE_SPEED_OUTPUT"] ?? "/private/tmp/louppe-speed-results"
        try JSONSerialization.data(withJSONObject: resources, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("large-folder-mounted-resources.json"))
    }

    private func waitForVisiblePixels(_ item: PhotoItem, in host: NSView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        repeat {
            host.layoutSubtreeIfNeeded()
            if descendants(host).compactMap({ $0 as? ThumbnailRenderMarker.MarkerView }).contains(where: {
                $0.revision == item.contentRevision && $0.hasImage && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }) { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
        XCTFail("The requested photo did not mount with matching pixels")
        throw NSError(domain: "LouppeLargeMounted", code: 1)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func jpegBytes() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 768,
            bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.45, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
