import Darwin
import Foundation
import ImageIO
import XCTest
@testable import Louppe

/// AUD-06/AUD-17 opt-in measurements. Real `SessionStore` mutations publish,
/// project and reconcile selection; mounted SwiftUI rendering is excluded.
/// Fixtures are synthetic RAW+JPEG pairs in memory (no originals touched),
/// except the recovery case, which uses disposable files under /private/tmp.
@MainActor
final class LouppeSpeedReviewRetentionTests: XCTestCase {
    func testReviewProjectionMutationsUnderActiveSortsAndFilters() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "review-projection")
        for count in SpeedBenchmark.sizes {
            let (store, cleanup) = makeStore(count: count)
            defer { cleanup() }
            let middle = count / 2

            var flip = false
            func alternate(at index: Int) {
                flip.toggle()
                store.rate(flip ? .no : .yes, at: index)
            }

            try report.measure(name: "rating.default-sort", count: count) { alternate(at: middle) }

            store.filter.excludedDecisionStates = [.no]
            try report.measure(name: "rating.decision-filter.membership-toggle", count: count) {
                alternate(at: middle)
            }
            assertProjection(store)
            store.filter.excludedDecisionStates = []

            store.sort = PhotoSort(key: .decision, ascending: true)
            try report.measure(name: "rating.decision-sort.grouped", count: count) { alternate(at: middle) }
            assertProjection(store)
            store.isGroupingEnabled = false
            try report.measure(name: "rating.decision-sort.ungrouped", count: count) { alternate(at: middle) }
            assertProjection(store)
            store.isGroupingEnabled = true

            store.sort = PhotoSort(key: .starRating, ascending: false)
            var star: StarRating = .one
            try report.measure(name: "stars.star-sort.grouped", count: count) {
                star = star == .one ? .five : .one
                store.setStarRating(star, at: middle)
            }
            assertProjection(store)

            // Stage breakdown on the pure index with the store's current items.
            let sort = PhotoSort(key: .decision, ascending: true)
            var index = PreparedSessionIndex()
            index.rebuildItems(store.items, sort: sort)
            index.applyFilter(PhotoFilter(), to: store.items, sort: sort, isGroupingEnabled: true)
            try report.measure(name: "stage.decision-sort.rebuild-prepared-sort", count: count) {
                index.rebuildPreparedSort(store.items, sort: sort)
            }
            try report.measure(name: "stage.decision-sort.apply-filter-unchanged", count: count) {
                index.applyFilter(PhotoFilter(), to: store.items, sort: sort, isGroupingEnabled: true)
            }
            try report.measure(name: "stage.decision-sort.apply-filter-after-change", count: count, prepare: {
                flip.toggle()
                store.items[middle].setRating(flip ? .no : .yes, ratedAt: nil)
                index.rebuildPreparedSort(store.items, sort: sort)
            }) {
                index.applyFilter(PhotoFilter(), to: store.items, sort: sort, isGroupingEnabled: true)
            }

            // Select All → decision as one batch under a decision sort.
            store.sort = sort
            store.selectAllVisible()
            XCTAssertEqual(store.selectedIndices.count, count)
            var batch: Rating = .yes
            try report.measure(name: "batch.select-all-rate.decision-sort", count: count) {
                batch = batch == .yes ? .no : .yes
                store.rate(batch)
            }
            assertProjection(store)
            XCTAssertEqual(store.selectedIndices.count, count)
            store.clearSelection()

            // Cue clearing: one cue, then an empty selection (neutral filter).
            store.sort = PhotoSort()
            try report.measure(name: "cue.clear.default-sort", count: count, prepare: {
                store.filter.selectedQualityCues = [.highISO]
            }) {
                store.filter.selectedQualityCues = []
            }
            XCTAssertEqual(store.visibleIndices.count, count)
            store.sort = sort
            try report.measure(name: "cue.clear.decision-sort", count: count, prepare: {
                store.filter.selectedQualityCues = [.highISO]
            }) {
                store.filter.selectedQualityCues = []
            }
            XCTAssertEqual(store.visibleIndices.count, count)
            assertProjection(store)

            // Frozen main-actor save capture for paired items (production type).
            var capture = SessionSnapshotCapture(sourcePath: "/private/tmp/louppe-speed", items: store.items,
                                                 retainedEntries: [], originPaths: [:])
            try report.measure(name: "save.capture.paired", count: count) {
                capture = SessionSnapshotCapture(sourcePath: "/private/tmp/louppe-speed", items: store.items,
                                                 retainedEntries: [], originPaths: [:])
            }
            XCTAssertEqual(capture.files.count, count * 2)
            store.beginTerminationPreparation()
        }
        try report.finish()
    }

    /// Repeated whole-folder edits: retained before-images and process memory.
    func testUndoRetentionForRepeatedBatchEdits() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "undo-retention")
        let cycles = Int(ProcessInfo.processInfo.environment["LOUPPE_UNDO_CYCLES"] ?? "") ?? 5
        var rows: [[String: Any]] = []
        let changeStride = SessionStore.undoMetadataChangeStrideForTesting
        for count in SpeedBenchmark.sizes {
            autoreleasepool {}
            let footprintBefore = Self.footprint()
            let (store, cleanup) = makeStore(count: count)
            let footprintFixture = Self.footprint()
            var stepTimes: [Double] = []
            var footprints: [UInt64] = []
            // Ratings/stars/colors before each step (cheap value enums).
            var before: [[(Rating, StarRating?, PhotoColorLabel?)]] = []
            func values() -> [(Rating, StarRating?, PhotoColorLabel?)] {
                store.items.flatMap(\.metadataSnapshots).map { ($0.rating, $0.starRating, $0.colorLabel) }
            }
            func step(_ body: () -> Void) {
                before.append(values())
                let start = ContinuousClock.now
                body()
                stepTimes.append(SpeedBenchmark.milliseconds(start))
                footprints.append(Self.footprint())
            }
            for cycle in 0..<cycles {
                store.selectAllVisible()
                step { store.rate(.yes) }
                store.selectAllVisible()
                step { store.rate(.no) }
                store.selectAllVisible()
                step { store.setStarRating(cycle.isMultiple(of: 2) ? .three : .five) }
                store.selectAllVisible()
                step { store.setColorLabel(cycle.isMultiple(of: 2) ? .red : .purple) }
                step { store.clearAllRatings() }
            }
            let steps = store.undoStepCountForTesting
            let changes = store.undoRetainedMetadataChangesForTesting
            // A byte budget may retain only the newest steps.
            XCTAssertLessThanOrEqual(steps, cycles * 5)
            XCTAssertGreaterThan(steps, 0)
            let footprintPeakEdits = footprints.max() ?? 0
            var undoTimes: [Double] = []
            while store.canUndo {
                let start = ContinuousClock.now
                store.undo()
                undoTimes.append(SpeedBenchmark.milliseconds(start))
            }
            let footprintAfterUndo = Self.footprint()
            let expected = before[before.count - steps]
            let restored = values()
            XCTAssertTrue(restored.elementsEqual(expected) { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 },
                          "Undoing every retained step restores the state before the oldest one.")
            try report.recordSamples(name: "undo.batch-step.edit", count: count,
                                     samplesMS: Array(stepTimes.prefix(SpeedBenchmark.repetitions)))
            try report.recordSamples(name: "undo.batch-step.undo", count: count,
                                     samplesMS: Array(undoTimes.prefix(SpeedBenchmark.repetitions)))
            XCTAssertEqual(undoTimes.count, steps)
            store.beginTerminationPreparation()
            cleanup()
            let mib = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
            let row: [String: Any] = [
                "items": count, "files": count * 2, "steps": steps,
                "retainedChanges": changes, "changeStrideBytes": changeStride,
                "retainedPayloadMiB": Double(changes * changeStride) / 1_048_576,
                "perStepPayloadMiB": Double(changes * changeStride) / 1_048_576 / Double(max(steps, 1)),
                "projected500StepMiB": Double(changes * changeStride) / 1_048_576 / Double(max(steps, 1)) * 500,
                "footprintBeforeMiB": mib(footprintBefore),
                "footprintFixtureMiB": mib(footprintFixture),
                "footprintPeakDuringEditsMiB": mib(footprintPeakEdits),
                "footprintGrowthDuringEditsMiB": mib(footprintPeakEdits &- min(footprintPeakEdits, footprintFixture)),
                "footprintAfterUndoMiB": mib(footprintAfterUndo),
                "editMedianMS": median(stepTimes), "undoMedianMS": median(undoTimes),
                "footprintTrajectoryMiB": stride(from: 0, to: footprints.count, by: max(1, footprints.count / 10))
                    .map { (mib(footprints[$0]) * 10).rounded() / 10 }
            ]
            print("UNDO_RETENTION \(row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            rows.append(row)
        }
        try report.finish()
        let output = ProcessInfo.processInfo.environment["LOUPPE_SPEED_OUTPUT"] ?? "/private/tmp/louppe-speed-results"
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("undo-retention-memory.json"))
    }

    /// Automatic identical-copy recovery of every file in a disposable folder,
    /// with default and decision sorts interleaved. Verification is injected
    /// (instant, matching digest), so the wall time is main-actor application
    /// and projection, not hashing.
    func testBatchRecoveryUnderActiveSorts() async throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "batch-recovery")
        let sizes = (ProcessInfo.processInfo.environment["LOUPPE_RECOVERY_SIZES"] ?? "1000,5000")
            .split(separator: ",").compactMap { Int($0) }
        let digest = String(repeating: "ab", count: 32)
        let bytes = try Self.tinyPNG()
        for count in sizes {
            let root = URL(fileURLWithPath: "/private/tmp/LouppeSpeedRecovery-\(UUID().uuidString)")
            let photos = root.appendingPathComponent("Photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var entries: [SessionEntry] = []
            for i in 0..<count {
                let name = String(format: "IMG_%06d.png", i)
                let url = photos.appendingPathComponent(name)
                try bytes.write(to: url)
                let current = try FileOperationJournal.captureIdentity(at: url)
                // A different physical identity at the same path: the saved
                // decision becomes recovery history awaiting a content match.
                let old = FileOperationJournal.FileIdentity(
                    volumeRootPath: current.volumeRootPath, volumeUUIDString: current.volumeUUIDString,
                    systemNumber: current.systemNumber, fileNumber: current.fileNumber &+ 1_000_000_000,
                    logicalSize: current.logicalSize, modificationTime: current.modificationTime,
                    statusChangeTime: current.statusChangeTime, birthTime: current.birthTime)
                entries.append(SessionEntry(
                    filename: name, pairedFilename: nil, rating: (i.isMultiple(of: 2) ? Rating.yes : .no).rawValue,
                    ratedAt: Date(timeIntervalSince1970: 123), stars: .four, colorLabel: .purple,
                    fileIdentity: old, contentSHA256: digest))
            }
            let seedBackups = root.appendingPathComponent("SeedBackups")
            let saved = await SessionPersistence(backupDirectory: seedBackups).save(
                SessionFile(version: 7, sourcePath: photos.path, scannedAt: Date(), entries: entries,
                            fileIDEncoding: .percentEncodedFileSystemPath), for: photos, sequence: 1)
            XCTAssertEqual(saved, .savedToSidecar)
            let sidecar = photos.appendingPathComponent(SessionConstants.sidecarName)
            let template = try Data(contentsOf: sidecar)

            var samples: [String: [Double]] = ["default": [], "decision": []]
            for repetition in 0...SpeedBenchmark.repetitions {
                let arms = (ProcessInfo.processInfo.environment["LOUPPE_RECOVERY_ARMS"] ?? "default,decision")
                    .split(separator: ",").map(String.init)
                for key in repetition.isMultiple(of: 2) ? arms : arms.reversed() {
                    try template.write(to: sidecar)
                    let defaultsName = "LouppeSpeedRecovery.\(UUID().uuidString)"
                    let defaults = UserDefaults(suiteName: defaultsName)!
                    defer { defaults.removePersistentDomain(forName: defaultsName) }
                    defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
                    defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
                    if key == "decision" { defaults.set("decision", forKey: ReviewPreferences.Keys.defaultSortKey) }
                    let store = SessionStore(
                        persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("Backups-\(UUID())")),
                        reviewDefaults: defaults,
                        sessionContentVerification: { file, _ in
                            SessionContentProof(identity: file.scannedIdentity!, sha256: digest)
                        })
                    store.openFolder(photos)
                    try await wait(seconds: 120) { if case .ready = store.phase { return true }; return false }
                    store.pauseQualityCueAnalysis()
                    let start = ContinuousClock.now
                    try await wait(seconds: 900) { store.sessionContentCheck == .finished }
                    let elapsed = SpeedBenchmark.milliseconds(start)
                    XCTAssertEqual(store.automaticallyRestoredSessionFiles, count)
                    XCTAssertEqual(store.yesCount, (count + 1) / 2)
                    XCTAssertEqual(store.noCount, count / 2)
                    XCTAssertEqual(store.sort.key, key == "decision" ? .decision : .captureDate)
                    assertProjection(store)
                    if repetition > 0 { samples[key]!.append(elapsed) }
                    _ = await store.saveSessionForTermination()
                    _ = await store.waitForPersistenceIdleForTesting()
                    store.beginTerminationPreparation()
                }
            }
            for key in ["default", "decision"] where !samples[key]!.isEmpty {
                try report.recordSamples(name: "recovery.identical-copies.\(key)-sort", count: count,
                                         samplesMS: samples[key]!)
            }
        }
        try report.finish()
    }

    private func wait(seconds: Int, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    // MARK: - Fixtures

    private func makeStore(count: Int) -> (SessionStore, () -> Void) {
        let defaultsName = "LouppeSpeedRetention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isHighlightClippingEnabled)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isShadowClippingEnabled)
        defaults.set(false, forKey: ReviewPreferences.Keys.advancesAfterDecision)
        let store = SessionStore(reviewDefaults: defaults)
        store.items = (0..<count).map { i in
            let folder = String(format: "2026-10-%02d", 1 + i % 28)
            let stem = String(format: "DSCF%06d", i)
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            func file(_ ext: String) -> PhotoFile {
                PhotoFile(
                    id: "\(folder)/\(stem).\(ext)",
                    url: URL(fileURLWithPath: "/private/tmp/louppe-speed-synthetic/\(folder)/\(stem).\(ext)"),
                    captureDate: date, cameraModel: "Camera \(i % 25)", lensModel: "Lens \(i % 4)",
                    shutterSpeed: 0.001, iso: i.isMultiple(of: 2) ? 6_400 : 100, fileSize: 1,
                    rating: i.isMultiple(of: 3) ? .yes : .undecided,
                    starRating: i.isMultiple(of: 5) ? .four : nil
                )
            }
            return PhotoItem(primaryFile: file("RAF"), pairedFile: file("JPG"))
        }
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.pauseQualityCueAnalysis()
        return (store, { defaults.removePersistentDomain(forName: defaultsName) })
    }

    private func assertProjection(_ store: SessionStore, file: StaticString = #filePath, line: UInt = #line) {
        var reference = PreparedSessionIndex()
        reference.rebuildItems(store.items, sort: store.sort)
        reference.applyFilter(store.filter, to: store.items, sort: store.sort,
                              isGroupingEnabled: store.isGroupingEnabled)
        XCTAssertEqual(store.visibleIndices, reference.visibleIndices, file: file, line: line)
        XCTAssertEqual(store.visibleGroups.map(\.id), reference.visibleGroups.map(\.id), file: file, line: line)
        XCTAssertEqual(store.visibleGroups.map(\.indices), reference.visibleGroups.map(\.indices), file: file, line: line)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Generated in memory so profiling launches need no repository access.
    static func tinyPNG() throws -> Data {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
