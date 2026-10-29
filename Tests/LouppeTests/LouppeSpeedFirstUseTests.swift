import AppKit
import CryptoKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// End-to-end opening through the mounted root, including saved decisions.
/// RAWs are APFS clones of one disposable copy, never independent camera shots.
@MainActor
final class LouppeSpeedFirstUseTests: XCTestCase {
    func testMountedOpeningFirstUsefulPixelsAndFullReadiness() async throws {
        try SpeedBenchmark.requireEnabled()
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required") }
        _ = NSApplication.shared
        let report = SpeedReport(suite: "opening-first-use")
        var resources: [[String: Any]] = []
        let rawURL = ProcessInfo.processInfo.environment["LOUPPE_SPEED_RAW_FILE"].map { URL(fileURLWithPath: $0) }
        let originalDigest = try rawURL.map(digest)
        let originalIdentity = try rawURL.map { try FileOperationJournal.captureIdentity(at: $0) }
        for count in Array(Set(SpeedBenchmark.sizes.map { min($0, 10_000) })).sorted() {
            for paired in rawURL == nil ? [false] : [false, true] {
                let root = URL(fileURLWithPath: "/private/tmp/louppe-first-use-\(UUID())", isDirectory: true)
                let folder = root.appendingPathComponent("media", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let jpeg = try jpegBytes()
                let seed = root.appendingPathComponent("seed.RAF")
                if paired { try FileManager.default.copyItem(at: try XCTUnwrap(rawURL), to: seed) }
                for index in 0..<count {
                    let name = String(format: "FRAME_%06d", index)
                    try jpeg.write(to: folder.appendingPathComponent(name + ".JPG"))
                    if paired {
                        let raw = folder.appendingPathComponent(name + ".RAF")
                        guard clonefile(seed.path, raw.path, 0) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                userInfo: [NSLocalizedDescriptionKey: "APFS cloning failed; refusing a large full-copy fallback"])
                        }
                    }
                }
                let items = try await Task.detached {
                    try FolderScanner.scan(folder, progress: { _ in })
                }.value
                items[0].rating = .yes
                items[items.count - 1].rating = .no
                let persistence = SessionPersistence(backupDirectory: root.appendingPathComponent("backups"))
                let read = await persistence.read(for: folder)
                let saved = await persistence.save(
                    SessionSnapshotCapture(sourcePath: folder.path, items: items, retainedEntries: [], originPaths: [:]).makeSession(),
                    for: folder, sequence: 1, access: try XCTUnwrap(read.access))
                XCTAssertEqual(saved, .savedToSidecar)
                let revisions = Set(items.map(\.contentRevision))
                var firstPixels: [Double] = []
                var readiness: [Double] = []
                var publication: [Double] = []
                var mainPublication: [Double] = []
                for iteration in 0...SpeedBenchmark.repetitions {
                    let defaultsName = "LouppeFirstUse.\(UUID())"
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
                    defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isEnabled)
                    defaults.set(ViewMode.grid.rawValue, forKey: ReviewPreferences.Keys.defaultView)
                    defer { defaults.removePersistentDomain(forName: defaultsName) }
                    let store = SessionStore(persistence: persistence, reviewDefaults: defaults)
                    let host = NSHostingView(rootView: RootView(store: store))
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720),
                                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.orderFront(nil)
                    // Fixture preparation scanned these files to create decision evidence.
                    // Remove only this disposable folder's optional metadata snapshot for
                    // app-cache-cold runs; the filesystem remains warm in both modes.
                    let archiveCacheWarm = ProcessInfo.processInfo.environment["LOUPPE_SPEED_ARCHIVE_CACHE"] == "warm"
                    if !archiveCacheWarm, let index = ArchiveMetadataIndex(folder: folder) {
                        try? FileManager.default.removeItem(at: index.cacheURL)
                    }
                    let start = ContinuousClock.now
                    store.openFolder(folder)
                    var pixelsAt: Double?
                    var readyAt: Double?
                    var publishedAt: Double?
                    var peakRSS = residentBytes()
                    var previousPoll = start
                    var mainActorGapsMS: [Double] = []
                    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                    repeat {
                        let poll = ContinuousClock.now
                        mainActorGapsMS.append(SpeedBenchmark.milliseconds(previousPoll))
                        previousPoll = poll
                        peakRSS = max(peakRSS, residentBytes())
                        host.layoutSubtreeIfNeeded()
                        let markers = descendants(host).compactMap { $0 as? ThumbnailRenderMarker.MarkerView }
                            .filter { $0.hasImage && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
                        if pixelsAt == nil, markers.contains(where: { revisions.contains($0.revision) }) {
                            pixelsAt = SpeedBenchmark.milliseconds(start)
                        }
                        if case .ready = store.phase {
                            if readyAt == nil { readyAt = SpeedBenchmark.milliseconds(start) }
                            if let current = store.currentItem,
                               markers.contains(where: { $0.revision == current.contentRevision }) {
                                publishedAt = SpeedBenchmark.milliseconds(start)
                            }
                        }
                        if publishedAt != nil { break }
                        if let error = store.scanError { XCTFail(error); break }
                        try await Task.sleep(for: .milliseconds(2))
                    } while ContinuousClock.now < deadline
                    let first = try XCTUnwrap(pixelsAt, "No useful mounted pixels")
                    let ready = try XCTUnwrap(readyAt, "Opening did not become Ready")
                    let displayed = try XCTUnwrap(publishedAt, "Ready current photo did not mount")
                    XCTAssertEqual(store.items.count, items.count)
                    XCTAssertEqual(store.items.first { $0.id == items[0].id }?.rating, .yes)
                    XCTAssertEqual(store.items.first { $0.id == items[items.count - 1].id }?.rating, .no)
                    if iteration > 0 {
                        firstPixels.append(first); readiness.append(ready); publication.append(displayed)
                        if let seconds = store.openingMetrics?.secondsByStage[.mainPublication] {
                            mainPublication.append(seconds * 1000)
                        }
                    }
                    window.orderOut(nil); window.contentView = nil; window.close()
                    store.beginTerminationPreparation()
                    _ = await store.saveSessionForTermination()
                    let idle = await store.waitForPersistenceIdleForTesting()
                    XCTAssertTrue(idle)
                    resources.append(["fixture": paired ? "raw-jpeg-clones" : "jpeg-generated",
                        "count": items.count, "iteration": iteration, "warmup": iteration == 0,
                        "archiveMetadataCache": ProcessInfo.processInfo.environment["LOUPPE_SPEED_ARCHIVE_CACHE"] == "warm" ? "warm" : "cold",
                        "filesystem": "warm-local",
                        "firstUsefulPixelsMS": first, "fullReadinessMS": ready,
                        "readyCurrentPixelsMS": displayed,
                        "peakResidentBytes": peakRSS,
                        "residentAfterWindowDetachAndSaveDrainBytes": residentBytes(),
                        "mainActorGapSamplesMS": mainActorGapsMS,
                        "maxMainActorGapMS": mainActorGapsMS.max() ?? 0,
                        "pollSleepMS": 2, "physicalFrameMeasurement": false])
                }
                let prefix = paired ? "raw-jpeg-clones" : "jpeg-generated"
                for (name, samples) in [("first-useful-pixels", firstPixels), ("fully-ready-state", readiness),
                                        ("ready-current-pixels", publication), ("main-publication", mainPublication)] {
                    guard samples.count == SpeedBenchmark.repetitions else { continue }
                    try report.recordSamples(name: "\(prefix).\(name).warm-local", count: items.count, samplesMS: samples)
                }
            }
        }
        if let rawURL {
            XCTAssertEqual(try digest(rawURL), originalDigest)
            XCTAssertEqual(try FileOperationJournal.captureIdentity(at: rawURL), originalIdentity)
        }
        try report.finish()
        let output = ProcessInfo.processInfo.environment["LOUPPE_SPEED_OUTPUT"] ?? "/private/tmp/louppe-speed-results"
        try JSONSerialization.data(withJSONObject: resources, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("opening-first-use-resources.json"))
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

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

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
