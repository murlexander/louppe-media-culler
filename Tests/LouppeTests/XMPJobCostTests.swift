import Darwin
import Foundation
import XCTest
@testable import Louppe

/// Production planners, XMPCore, durable writes, journals and recovery cleanup.
/// Run via Tests/run_xmp_job_cost.sh: optimized, serialized, one process per case.
final class XMPJobCostTests: XCTestCase {
    func testOptimizedWholeJob() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOUPPE_XMP_JOB_COST"] == "1" else { throw XCTSkip("Opt-in optimized whole-job measurement") }
        let count = try XCTUnwrap(Int(env["LOUPPE_XMP_FAMILIES"] ?? ""))
        let dispersed = env["LOUPPE_XMP_LAYOUT"] == "dispersed"
        let move = env["LOUPPE_XMP_OPERATION"] == "move"
        let root = URL(fileURLWithPath: "/private/tmp/louppe-xmp-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        for path in [source, destination] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        let packet = try XMPFieldMapping.merge(packet: nil, metadata: .init(decision: .no, stars: .one, colorLabel: nil, profile: .universal))
        var items: [PhotoItem] = []
        for index in 0..<count {
            let parent = dispersed ? source.appendingPathComponent("folder-\(index / 32)") : source
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let name = String(format: "IMG_%05d", index)
            let raw = parent.appendingPathComponent("\(name).NEF")
            try Data("raw".utf8).write(to: raw)
            try packet.write(to: parent.appendingPathComponent("\(name).xmp"))
            items.append(PhotoItem(primaryFile: PhotoFile(id: name, url: raw, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 3,
                scannedIdentity: try FileOperationJournal.captureIdentity(at: raw), rating: .yes, starRating: .five, colorLabel: .red)))
        }
        // Warm the bridge before timing, excluding fixture construction and compiler work.
        _ = try XMPFieldMapping.merge(packet: packet, metadata: .init(decision: .yes, stars: .five, colorLabel: .red, profile: .universal))
        let initialRSS = residentBytes()
        XMPBoundaryMetrics.shared.start()
        let start = ContinuousClock.now
        if move {
            let xmp = try await XMPExportPlanner.prepare(selected: items, familyContextItems: items, profile: .universal,
                visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
            let plan = try ExportWorker.makePlan(for: items, in: destination, xmpPlan: xmp, mode: .move)
            let result = ExportWorker.move(items, to: destination, xmpPlan: xmp, preparedPlan: plan,
                journalDirectory: root.appendingPathComponent("Journals")) { _, _ in }
            XCTAssertEqual(result.movedItemIDs.count, count, result.failureMessage ?? "")
            XCTAssertEqual(result.failedPhotos, 0)
            XCTAssertFalse(result.requiresRecovery)
        } else {
            let input = try XMPPublicationInput(items: items, profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
            let preflight = await XMPPublicationPlanner.preflight(input, isCancelled: { false }) { _, _ in }
            let plan = try XCTUnwrap(preflight)
            XCTAssertEqual(plan.publishableCount, count)
            let result = await XMPPublicationWorker.publish(plan, cancelFlag: XMPPublicationCancelFlag()) { _, _ in }
            XCTAssertEqual(result.updated, count)
            XCTAssertEqual(result.failed + result.conflicts, 0)
        }
        let seconds = start.duration(to: .now).seconds
        let visits = XMPBoundaryMetrics.shared.stop()
        let retainedRSS = residentBytes()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var cancellation = "unavailable"
        if !move {
            // Already-current packets still take the complete fresh ownership census.
            let input = try XMPPublicationInput(items: items, profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
            let preflight = await XMPPublicationPlanner.preflight(input, isCancelled: { false }) { _, _ in }
            let plan = try XCTUnwrap(preflight)
            let flag = XMPPublicationCancelFlag()
            let request = Task.detached {
                try await Task.sleep(for: .milliseconds(10))
                flag.set()
                return ContinuousClock.now
            }
            let result = await XMPPublicationWorker.publish(plan, cancelFlag: flag) { _, _ in }
            let returned = ContinuousClock.now
            let requested = try await request.value
            XCTAssertTrue(result.cancelled)
            cancellation = String(format: "%.6f", max(0, requested.duration(to: returned).seconds))
        }
        print("XMP_JOB families=\(count) layout=\(dispersed ? "dispersed" : "flat") operation=\(move ? "move" : "publication") seconds=\(String(format: "%.6f", seconds)) directoryVisits=\(visits) cancelSeconds=\(cancellation) initialRSSBytes=\(initialRSS) retainedRSSBytes=\(retainedRSS) peakRSSBytes=\(usage.ru_maxrss)")
        fflush(nil)
    }

    private func residentBytes() -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_resident_size
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
