import Foundation
import XCTest
@testable import Louppe

/// Read-only opt-in opening profile. The caller provides disposable fixtures;
/// no sidecar, recovery checkpoint or source-file change is made here.
@MainActor
final class LouppeSpeedOpeningTests: XCTestCase {
    func testOpeningStagesOnProvidedFolders() async throws {
        try SpeedBenchmark.requireEnabled()
        guard let paths = ProcessInfo.processInfo.environment["LOUPPE_OPENING_FOLDERS"] else {
            throw XCTSkip("Set LOUPPE_OPENING_FOLDERS to colon-separated disposable fixture folders")
        }
        let report = SpeedReport(suite: "opening-stages")
        for path in paths.split(separator: ":") {
            let root = URL(fileURLWithPath: String(path), isDirectory: true)
            let backup = FileManager.default.temporaryDirectory
                .appendingPathComponent("Louppe-Opening-Profile-\(UUID())")
            defer { try? FileManager.default.removeItem(at: backup) }
            let persistence = SessionPersistence(backupDirectory: backup)
            for mode in [RawJPEGPairingMode.separate, .together] {
                var samples: [SessionOpeningMetrics] = []
                var order: [String]?
                for iteration in 0...SpeedBenchmark.repetitions {
                    let metrics = try await Task.detached(priority: .userInitiated) {
                        let recorder = SessionOpeningRecorder()
                        let prepared = try await SessionOpeningWorker.prepare(
                            folder: root, pairingMode: mode, persistence: persistence, recorder: recorder
                        )
                        let metrics = recorder.snapshot()
                        // As the app does after Ready, outside the measured opening.
                        prepared.metadataCommit?.run(isCancelled: { false })
                        return (metrics, prepared.restoration.items.map(\.id))
                    }.value
                    if let order { XCTAssertEqual(metrics.1, order) } else { order = metrics.1 }
                    if iteration > 0 { samples.append(metrics.0) }
                }
                let count = try XCTUnwrap(samples.first).physicalFileCount
                let prefix = "opening.\(root.lastPathComponent).\(mode.rawValue)"
                for stage in SessionOpeningStage.allCases {
                    guard samples.allSatisfy({ $0.secondsByStage[stage] != nil }) else { continue }
                    try report.recordSamples(name: "\(prefix).\(stage.rawValue)", count: count,
                                             samplesMS: samples.map { $0.secondsByStage[stage]! * 1000 })
                }
                try report.recordSamples(name: "\(prefix).complete", count: count,
                                         samplesMS: samples.map { $0.elapsed * 1000 })
            }
        }
        try report.finish()
    }
}
