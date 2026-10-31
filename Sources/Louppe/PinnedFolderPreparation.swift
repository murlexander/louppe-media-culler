import Combine
import Foundation
import os

/// Stages of one background preparation job, in order.
enum PinnedFolderPreparationStage: String, Sendable, CaseIterable {
    case folderIdentity, discovery, indexLoad, extraction, identityBarrier, commit
}

/// Counts and timings only; never paths or metadata.
struct PinnedFolderPreparationReport: Sendable, Equatable {
    enum Outcome: String, Sendable {
        /// The metadata index was written after a complete identity barrier.
        case committed
        /// The index already matched the folder; nothing was written.
        case unchanged
        /// Low Power Mode: discovery and the index check only.
        case lowPower
        /// Serious or critical thermal state; retried later on Welcome.
        case postponed
        /// A file or folder changed during the job; nothing was written.
        case changed
        case cancelled
        /// The pin could not be resolved, verified or cached.
        case unavailable
        case failed
    }

    var outcome: Outcome = .failed
    var folders = 0
    var files = 0
    var items = 0
    var misses = 0
    var extracted = 0
    /// True when the per-job extraction cap left misses for the next open.
    var capped = false
    var discoverySeconds = 0.0
    var extractionSeconds = 0.0
    var barrierSeconds = 0.0
    var totalSeconds = 0.0
}

/// One read-only pass over a pinned folder: discovery warms the volume's
/// directory and attribute caches, then metadata misses are read with the
/// opening's extractor and committed to `ArchiveMetadataIndex` after a
/// complete identity barrier. It never reads or writes the decision sidecar,
/// backups, navigation memory or pin positions, and never writes to the
/// source volume.
enum PinnedFolderPreparationJob {
    struct Hooks: Sendable {
        /// Runs before each stage; may block (tests) or throw.
        var willBeginStage: @Sendable (PinnedFolderPreparationStage) throws -> Void = { _ in }
        /// Replaces the EXIF reader and the foreground admission wait.
        var metadataReader: (@Sendable (URL) throws -> MetadataExtractor.ScanInfo)? = nil
        var volumeResolver: FileOperationJournal.VolumeLookup.Resolver? = nil
    }

    struct Settings: Sendable {
        var pairingMode: RawJPEGPairingMode = .separate
        var discoveryWorkers = 3
        var extractionWorkers = 2
        var extractionLimit = 2_000
        var extractionDuration: Duration = .seconds(60)
        var extractionBatch = 32
        /// Nil uses the app's metadata cache (and its one-time v1 migration).
        var metadataCacheDirectory: URL? = nil
        var resources: @Sendable () -> QualityCueWorkPolicy.Resources = { .current }
        var scopeAccess: SecurityScopedResourceAccess = .live
        var hooks = Hooks()
    }

    private struct Postpone: Error {}
    private struct Unavailable: Error {}

    /// Synchronous: every discovery, metadata and barrier worker has exited
    /// when this returns, so the scope it holds covers all of them.
    static func run(_ access: PinnedFolderPreparationAccess, settings: Settings,
                    isCancelled: @escaping @Sendable () -> Bool) -> PinnedFolderPreparationReport {
        let started = ContinuousClock.now
        var report = PinnedFolderPreparationReport()
        let scoped = settings.scopeAccess.start(access.authorityURL)
        defer { if scoped { settings.scopeAccess.stop(access.authorityURL) } }
        do {
            report.outcome = try prepare(access, settings: settings, isCancelled: isCancelled, report: &report)
        } catch {
            if isCancelled() || error is CancellationError {
                report.outcome = .cancelled
            } else if error is Postpone {
                report.outcome = .postponed
            } else if error is Unavailable {
                report.outcome = .unavailable
            } else if case FolderScanner.ScanError.filesChangedDuringScan = error {
                report.outcome = .changed
            } else if case FolderScanner.ScanError.fileChangedDuringMetadataLoad = error {
                report.outcome = .changed
            } else {
                report.outcome = .failed
            }
        }
        report.totalSeconds = seconds(since: started)
        return report
    }

    private static func prepare(_ access: PinnedFolderPreparationAccess, settings: Settings,
                                isCancelled: @escaping @Sendable () -> Bool,
                                report: inout PinnedFolderPreparationReport) throws -> PinnedFolderPreparationReport.Outcome {
        func checkpoint(_ stage: PinnedFolderPreparationStage) throws {
            if isCancelled() { throw CancellationError() }
            try settings.hooks.willBeginStage(stage)
            if isCancelled() { throw CancellationError() }
        }
        /// Sampled between stages and extraction batches.
        func resources() throws -> QualityCueWorkPolicy.Resources {
            let current = settings.resources()
            switch current.thermal {
            case .serious, .critical: throw Postpone()
            case .nominal, .fair: return current
            }
        }

        try checkpoint(.folderIdentity)
        _ = try resources()
        // The same spelling an open uses, so the metadata index key matches.
        let folder = access.authorityURL.standardizedFileURL
        guard let identity = try? SessionPersistence.SourceFolderIdentity.capture(at: folder),
              access.expectedIdentity.matches(identity) else { throw Unavailable() }

        try checkpoint(.discovery)
        var stageStart = ContinuousClock.now
        let inventory = try FolderScanner.discoverInventory(
            folder, pairingMode: settings.pairingMode, isCancelled: isCancelled,
            walkWorkers: settings.discoveryWorkers, walkQoS: .utility)
        report.discoverySeconds = seconds(since: stageStart)
        report.folders = inventory.directories.count
        report.files = inventory.physicalFileCount
        report.items = inventory.items.count

        try checkpoint(.indexLoad)
        guard let index = ArchiveMetadataIndex(folder: folder, folderIdentity: identity,
                                               cacheDirectory: settings.metadataCacheDirectory,
                                               isCancelled: isCancelled) else {
            if isCancelled() { throw CancellationError() }
            throw Unavailable()
        }
        // Opening reads metadata for primary files only; hidden partners keep
        // whatever the index already knows.
        let misses = inventory.items.indices.filter { index.metadata(for: inventory.items[$0].primaryFile) == nil }
        report.misses = misses.count
        if try resources().lowPower { return .lowPower }

        try checkpoint(.extraction)
        stageStart = ContinuousClock.now
        var prepared = inventory.items
        let deadline = stageStart.advanced(by: settings.extractionDuration)
        let target = min(misses.count, max(0, settings.extractionLimit))
        let batchSize = max(1, settings.extractionBatch)
        var position = 0
        while position < target {
            if ContinuousClock.now >= deadline { break }
            if try resources().lowPower { break }
            let slots = Array(misses[position..<min(position + batchSize, target)])
            let batch = FolderScanner.Inventory(root: inventory.root, items: slots.map { inventory.items[$0] },
                                                rawJPEGFileIDs: [])
            // Each miss waits for foreground admission, then checks identity
            // before and after its read. The barrier below covers the rest.
            // Workers check the deadline before claiming each file; reads in
            // flight finish, and only the interrupted batch is discarded.
            let pastDeadline: @Sendable () -> Bool = { isCancelled() || ContinuousClock.now >= deadline }
            let results: [PhotoItem]
            do {
                results = try FolderScanner.prepareMetadata(
                    in: batch, isCancelled: pastDeadline,
                    metadataReaderForTesting: settings.hooks.metadataReader, metadataIndex: index,
                    commitsMetadataIndex: false, validatesIdentities: false,
                    metadataWorkers: settings.extractionWorkers)
            } catch is CancellationError where !isCancelled() {
                break
            }
            var slotByID: [String: Int] = [:]
            for slot in slots { slotByID[inventory.items[slot].primaryFile.id] = slot }
            for item in results {
                guard let slot = slotByID[item.primaryFile.id] else { continue }
                prepared[slot] = item
            }
            position += slots.count
            report.extracted = position
        }
        report.capped = position < misses.count
        report.extractionSeconds = seconds(since: stageStart)

        try checkpoint(.identityBarrier)
        _ = try resources()
        stageStart = ContinuousClock.now
        // Comparison and encoding are pure; nil means nothing to write, so
        // no barrier is needed either.
        guard let commit = index.prepareCommit(prepared, isCancelled: isCancelled) else {
            if isCancelled() { throw CancellationError() }
            return .unchanged
        }
        try FolderScanner.validateScannedIdentities(prepared, isCancelled: isCancelled,
            volumes: .init(resolver: settings.hooks.volumeResolver))
        try FolderScanner.validateDirectories(in: inventory, isCancelled: isCancelled,
            volumes: .init(resolver: settings.hooks.volumeResolver))
        guard identity.matches(folder: folder) else { throw FolderScanner.ScanError.filesChangedDuringScan }
        report.barrierSeconds = seconds(since: stageStart)

        try checkpoint(.commit)
        // Entries carry the identities the barrier just verified; a later
        // replacement can never hit them.
        guard commit.commit(isCancelled: isCancelled) else {
            if isCancelled() { throw CancellationError() }
            return .unchanged
        }
        return .committed
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The single owner of background pinned-folder preparation. At most one job
/// runs, at utility priority, and only while Welcome is idle. Triggers: a
/// mount whose volume UUID matches a pin (after a settle delay), and launch or
/// a return to Welcome (available pins, most recently opened first). Any
/// folder open, Quit, leaving Welcome, or an unmount/rename of the job's
/// volume cancels it. Holds no job data after a job ends.
@MainActor
final class PinnedFolderPreparation {
    /// Hidden diagnostic kill switch:
    /// `defaults write com.alexandermarkin.louppe disablePinnedFolderPreparation -bool YES`.
    static let disabledDefaultsKey = "disablePinnedFolderPreparation"
    private static let logger = Logger(subsystem: "com.alexandermarkin.louppe", category: "PinnedFolderPreparation")

    struct Configuration: Sendable {
        var settleDelay: Duration = .seconds(3)
        var postponeDelay: Duration = .seconds(120)
        /// Welcome triggers skip a pin prepared this recently. Mounts reset it.
        var welcomeCooldown: Duration = .seconds(15 * 60)
        var discoveryWorkers = 3
        var extractionWorkers = 2
        var extractionLimit = 2_000
        var extractionDuration: Duration = .seconds(60)
        var metadataCacheDirectory: URL? = nil
        var scopeAccess: SecurityScopedResourceAccess = .live
        var volumeUUID: @Sendable (URL) -> String? = {
            try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }
        var hooks = PinnedFolderPreparationJob.Hooks()
        var jobDidFinish: (@MainActor @Sendable (UUID, PinnedFolderPreparationReport) -> Void)? = nil
    }

    private struct Running {
        let pinID: UUID
        let cancel: FolderScanner.CancelFlag
        var task: Task<Void, Never>?
        /// The resolved mount path, known once access is verified.
        var authorityPath: String?
    }

    private let pins: PinnedFoldersStore
    private let defaults: UserDefaults
    /// Nil disables every trigger (isolated test stores).
    private let configuration: Configuration?
    private let resources: @Sendable () -> QualityCueWorkPolicy.Resources
    private var queue: [UUID] = []
    private var running: Running?
    private var welcomeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// Pins postponed by heat, retried together by `retryTask`.
    private var postponed: [UUID] = []
    private var preparedAt: [UUID: ContinuousClock.Instant] = [:]
    private var subscription: AnyCancellable?
    /// SessionStore's Welcome-idle gate.
    var isEligible: () -> Bool = { false }
    var pairingMode: () -> RawJPEGPairingMode = { .separate }
    /// Standardized recent-folder paths, most recent first.
    var recentPaths: () -> [String] = { [] }

    init(pins: PinnedFoldersStore, defaults: UserDefaults, configuration: Configuration?,
         resources: @escaping @Sendable () -> QualityCueWorkPolicy.Resources) {
        self.pins = pins
        self.defaults = defaults
        self.configuration = configuration
        self.resources = resources
        guard configuration != nil else { return }
        subscription = pins.volumeEvents.sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    var isRunningForTesting: Bool { running != nil }
    var queuedForTesting: [UUID] { queue }

    private var isDisabled: Bool { configuration == nil || defaults.bool(forKey: Self.disabledDefaultsKey) }
    private var canRun: Bool { !isDisabled && isEligible() }

    // MARK: Triggers

    /// Launch, or a return to Welcome.
    func welcomeDidAppear() {
        guard let configuration, !isDisabled else { return }
        welcomeTask?.cancel()
        welcomeTask = Task { [weak self] in
            do { try await Task.sleep(for: configuration.settleDelay) } catch { return }
            guard let self, self.canRun else { return }
            let now = ContinuousClock.now
            for id in self.welcomeOrder() where self.running?.pinID != id && !self.queue.contains(id) {
                if let last = self.preparedAt[id], last.duration(to: now) < configuration.welcomeCooldown { continue }
                self.queue.append(id)
            }
            self.pump()
        }
    }

    private func welcomeOrder() -> [UUID] {
        let recents = recentPaths()
        let available = pins.folders.enumerated().filter { $0.element.availability == .available }
        return available.sorted { lhs, rhs in
            let left = recents.firstIndex(of: URL(fileURLWithPath: lhs.element.path).standardizedFileURL.path) ?? Int.max
            let right = recents.firstIndex(of: URL(fileURLWithPath: rhs.element.path).standardizedFileURL.path) ?? Int.max
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element.id)
    }

    private func handle(_ event: PinnedFolderVolumeEvent) {
        switch event {
        case .mounted(let url):
            guard let configuration, !isDisabled, let url else { return }
            // Not cancelled with jobs: a mount always resets the cool-down,
            // and the eligibility check below gates any job.
            Task { [weak self] in
                do { try await Task.sleep(for: configuration.settleDelay) } catch { return }
                // Volume lookups stay off the main actor.
                let uuid = await Task.detached(priority: .utility) { configuration.volumeUUID(url) }.value
                guard let self, let uuid else { return }
                let matching = self.pins.folders.filter { $0.identity.volumeUUIDString == uuid }.map(\.id)
                // A fresh mount has cold caches whether or not we run now.
                for id in matching { self.preparedAt[id] = nil }
                guard self.canRun else { return }
                for id in matching where self.running?.pinID != id && !self.queue.contains(id) {
                    self.queue.append(id)
                }
                self.pump()
            }
        case .unmounted(let url):
            cancelRunning(onVolume: url)
        case .renamed(let oldURL, _):
            cancelRunning(onVolume: oldURL)
        }
    }

    /// Unknown volumes and jobs whose path is not yet known cancel conservatively.
    private func cancelRunning(onVolume url: URL?) {
        guard let running else { return }
        if let url, let path = running.authorityPath {
            let root = url.standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path == root || path.hasPrefix(prefix) else { return }
        }
        running.cancel.set()
    }

    /// A closed session warmed its pin like a job would; restart the cool-down.
    func noteRecentlyOpened(pinID: UUID) {
        guard configuration != nil else { return }
        preparedAt[pinID] = .now
    }

    // MARK: Cancellation

    /// Cancels pending triggers and the running job. Returns the job's task
    /// so a caller can await its exit; the job drops itself when it ends.
    @discardableResult
    func cancel() -> Task<Void, Never>? {
        welcomeTask?.cancel()
        welcomeTask = nil
        retryTask?.cancel()
        retryTask = nil
        postponed = []
        queue = []
        running?.cancel.set()
        return running?.task
    }

    /// Cancels, then waits for the job's exit for at most `timeout`. A job is
    /// cancelled between files, so the wait is normally milliseconds.
    func cancelAndWait(timeout: Duration = .seconds(2)) async {
        guard let task = cancel() else { return }
        await Self.awaitExit(task, timeout: timeout)
    }

    nonisolated static func awaitExit(_ task: Task<Void, Never>, timeout: Duration) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.set(continuation)
            Task.detached { await task.value; gate.resume() }
            Task.detached { try? await Task.sleep(for: timeout); gate.resume() }
        }
    }

    // MARK: Jobs

    private func pump() {
        guard running == nil, let configuration, canRun, !queue.isEmpty else { return }
        let pinID = queue.removeFirst()
        let cancel = FolderScanner.CancelFlag()
        running = Running(pinID: pinID, cancel: cancel)
        let settings = PinnedFolderPreparationJob.Settings(
            pairingMode: pairingMode(), discoveryWorkers: configuration.discoveryWorkers,
            extractionWorkers: configuration.extractionWorkers, extractionLimit: configuration.extractionLimit,
            extractionDuration: configuration.extractionDuration,
            metadataCacheDirectory: configuration.metadataCacheDirectory, resources: resources,
            scopeAccess: configuration.scopeAccess, hooks: configuration.hooks)
        let pins = self.pins
        running?.task = Task { [weak self] in
            var report = PinnedFolderPreparationReport(outcome: .unavailable)
            if let access = await pins.preparationAccess(id: pinID), !cancel.isSet {
                self?.running?.authorityPath = access.authorityURL.standardizedFileURL.path
                report = await Task.detached(priority: .utility) {
                    PinnedFolderPreparationJob.run(access, settings: settings, isCancelled: { cancel.isSet })
                }.value
            } else if cancel.isSet {
                report.outcome = .cancelled
            }
            self?.finish(pinID, report: report)
        }
    }

    private func finish(_ pinID: UUID, report: PinnedFolderPreparationReport) {
        guard running?.pinID == pinID else { return }
        running = nil
        Self.logger.log("""
            Pinned folder preparation \(report.outcome.rawValue, privacy: .public): \
            \(report.folders) folders, \(report.files) files, \(report.items) items, \
            \(report.misses) misses, \(report.extracted) read\(report.capped ? " (capped)" : "", privacy: .public); \
            discovery \(report.discoverySeconds, format: .fixed(precision: 3))s, \
            extraction \(report.extractionSeconds, format: .fixed(precision: 3))s, \
            barrier \(report.barrierSeconds, format: .fixed(precision: 3))s, \
            total \(report.totalSeconds, format: .fixed(precision: 3))s
            """)
        switch report.outcome {
        case .committed, .unchanged, .lowPower:
            preparedAt[pinID] = .now
        case .postponed:
            // Every postponed pin is retried by one timer (bounded by the pin
            // count); a later postponement never drops an earlier one.
            if let delay = configuration?.postponeDelay {
                if !postponed.contains(pinID) { postponed.append(pinID) }
                if retryTask == nil {
                    retryTask = Task { [weak self] in
                        do { try await Task.sleep(for: delay) } catch { return }
                        guard let self else { return }
                        self.retryTask = nil
                        let due = self.postponed
                        self.postponed = []
                        guard self.canRun else { return }
                        for id in due.reversed() where self.running?.pinID != id && !self.queue.contains(id) {
                            self.queue.insert(id, at: 0)
                        }
                        self.pump()
                    }
                }
            }
        case .changed, .cancelled, .unavailable, .failed:
            break
        }
        configuration?.jobDidFinish?(pinID, report)
        pump()
    }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        lock.withLock {
            if resumed { continuation.resume() } else { self.continuation = continuation }
        }
    }

    func resume() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
