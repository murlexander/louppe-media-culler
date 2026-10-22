import Foundation
import OSLog

/// Stages are separate from app phase: no incomplete scan is a Ready session.
enum SessionOpeningStage: String, CaseIterable, Sendable {
    case folderIdentity
    case discovery
    case pairing
    case metadata
    case metadataIdentityValidation
    case chronologicalSort
    case persistenceRead
    case decisionRestoration
    case previewIdentityValidation
    case previewPublication
    case finalIdentityValidation
    case derivedPreparation
    case mainPublication
}

struct SessionOpeningProgress: Equatable, Sendable {
    let stage: SessionOpeningStage
    let completed: Int
    let total: Int?
}

struct SessionOpeningMetrics: Sendable {
    let secondsByStage: [SessionOpeningStage: TimeInterval]
    let physicalFileCount: Int
    let itemCount: Int
    let elapsed: TimeInterval
}

/// One scan owns this recorder. Small locked writes let GCD workers report
/// completion without allocating a task or retaining a publication per file.
final class SessionOpeningRecorder: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: "com.alexandermarkin.louppe", category: "Folder Opening"
    )
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var durations: [SessionOpeningStage: TimeInterval] = [:]
    private var latestProgress: SessionOpeningProgress?
    private var physicalCount = 0
    private var projectedCount = 0

    func measure<T>(_ stage: SessionOpeningStage, _ operation: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let interval = Self.signposter.beginInterval("Opening Stage", "\(stage.rawValue, privacy: .public)")
        defer {
            Self.signposter.endInterval("Opening Stage", interval)
            record(stage, seconds: ProcessInfo.processInfo.systemUptime - start)
        }
        return try operation()
    }

    func record(_ stage: SessionOpeningStage, seconds: TimeInterval) {
        lock.lock()
        durations[stage, default: 0] += seconds
        lock.unlock()
    }

    func progress(_ stage: SessionOpeningStage, completed: Int, total: Int? = nil) {
        lock.lock()
        latestProgress = SessionOpeningProgress(stage: stage, completed: completed, total: total)
        lock.unlock()
    }

    func takeProgress() -> SessionOpeningProgress? {
        lock.lock()
        defer { lock.unlock() }
        let progress = latestProgress
        latestProgress = nil
        return progress
    }

    func setCounts(physical: Int, items: Int) {
        lock.lock()
        physicalCount = physical
        projectedCount = items
        lock.unlock()
    }

    func snapshot() -> SessionOpeningMetrics {
        lock.lock()
        defer { lock.unlock() }
        return SessionOpeningMetrics(
            secondsByStage: durations, physicalFileCount: physicalCount,
            itemCount: projectedCount,
            elapsed: ProcessInfo.processInfo.systemUptime - started
        )
    }
}
