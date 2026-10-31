import CryptoKit
import Foundation
import XCTest
@testable import Louppe

/// Background preparation of pinned folders. Disposable /private/tmp folders
/// with real discovery, identity and index I/O; the EXIF reader, bookmarks,
/// scope calls, volume UUIDs and power/thermal state are injected.
@MainActor
final class PinnedFolderPreparationTests: XCTestCase {
    // MARK: Triggers

    func testMatchingMountRunsOneJobAndOtherVolumesRunNone() async throws {
        let fixture = try PreparationFixture(files: 3)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let reads = PreparationReads()
        let log = PreparationLog()
        let uuid = try XCTUnwrap(fixture.identity.volumeUUIDString)
        var configuration = fixture.configuration(reads: reads, log: log)
        configuration.volumeUUID = { $0.lastPathComponent == "Match" ? uuid : "00000000-0000-0000-0000-000000000000" }
        let owner = fixture.owner(pins: pins, configuration: configuration)

        pins.noteVolumeEventForTesting(.mounted(volumeURL: URL(fileURLWithPath: "/Volumes/Other")))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(log.reports.isEmpty, "a different volume must not start a job")
        XCTAssertFalse(owner.isRunningForTesting)

        pins.noteVolumeEventForTesting(.mounted(volumeURL: URL(fileURLWithPath: "/Volumes/Match")))
        try await until { log.reports.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(log.reports.count, 1)
        XCTAssertEqual(log.pinIDs, [id])
        XCTAssertEqual(log.reports.first?.outcome, .committed)
        XCTAssertEqual(reads.count, 3)
        XCTAssertTrue(fixture.indexWritten)
    }

    func testMountAwayFromWelcomeWaitsAndResetsTheCooldown() async throws {
        let fixture = try PreparationFixture(files: 2)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let log = PreparationLog()
        let uuid = try XCTUnwrap(fixture.identity.volumeUUIDString)
        var configuration = fixture.configuration(reads: PreparationReads(), log: log)
        configuration.volumeUUID = { _ in uuid }
        let owner = fixture.owner(pins: pins, configuration: configuration)
        owner.welcomeDidAppear()
        try await until { log.reports.count == 1 }

        var eligible = false
        owner.isEligible = { eligible }
        pins.noteVolumeEventForTesting(.mounted(volumeURL: URL(fileURLWithPath: "/Volumes/Match")))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.reports.count, 1, "no job away from an idle Welcome")

        eligible = true
        owner.welcomeDidAppear()
        try await until { log.reports.count == 2 }
        XCTAssertEqual(log.pinIDs, [id, id], "a new mount overrides the cool-down")
    }

    func testMountsSerializeOneJobAtATime() async throws {
        let fixture = try PreparationFixture(files: 4, secondFolder: true)
        defer { fixture.remove() }
        let (pins, first) = try await fixture.pinnedStore()
        let secondValue = await pins.pinSelectedFolder(url: fixture.secondFolder)
        let second = try XCTUnwrap(secondValue)
        let log = PreparationLog()
        let gate = PreparationGate()
        let uuid = try XCTUnwrap(fixture.identity.volumeUUIDString)
        var configuration = fixture.configuration(reads: PreparationReads(), log: log)
        configuration.volumeUUID = { _ in uuid }
        configuration.hooks.willBeginStage = { stage in
            guard stage == .discovery else { return }
            gate.enter()
        }
        let owner = fixture.owner(pins: pins, configuration: configuration)

        pins.noteVolumeEventForTesting(.mounted(volumeURL: URL(fileURLWithPath: "/Volumes/One")))
        try await until { gate.entered == 1 }
        pins.noteVolumeEventForTesting(.mounted(volumeURL: URL(fileURLWithPath: "/Volumes/Two")))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gate.entered, 1, "a second job must wait for the first")
        XCTAssertEqual(gate.maximumConcurrent, 1)
        gate.release()
        try await until { log.reports.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(log.reports.count, 2, "repeated mounts do not duplicate queued pins")
        XCTAssertEqual(Set(log.pinIDs), [first, second])
        XCTAssertEqual(gate.maximumConcurrent, 1)
        XCTAssertFalse(owner.isRunningForTesting)
    }

    func testWelcomeRunsAvailablePinsMostRecentlyOpenedFirstOnlyWhenEligible() async throws {
        let fixture = try PreparationFixture(files: 1, secondFolder: true)
        defer { fixture.remove() }
        let (pins, first) = try await fixture.pinnedStore()
        let secondValue = await pins.pinSelectedFolder(url: fixture.secondFolder)
        let second = try XCTUnwrap(secondValue)
        let log = PreparationLog()
        let owner = fixture.owner(pins: pins, configuration: fixture.configuration(reads: PreparationReads(), log: log),
                                  eligible: false)
        // Pins list newest-pinned first; recents order wins.
        XCTAssertEqual(pins.folders.map(\.id), [second, first])
        owner.recentPaths = { ["/elsewhere", fixture.folder.standardizedFileURL.path] }

        owner.welcomeDidAppear()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(log.reports.isEmpty, "not on an idle Welcome: nothing runs")

        owner.isEligible = { true }
        owner.welcomeDidAppear()
        try await until { log.reports.count == 2 }
        XCTAssertEqual(log.pinIDs, [first, second])

        // A second visit within the cool-down repeats nothing.
        owner.welcomeDidAppear()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.reports.count, 2)
    }

    func testClosingAPinnedSessionSkipsThatPinOnReturnToWelcome() async throws {
        let fixture = try PreparationFixture(files: 2, secondFolder: true)
        defer { fixture.remove() }
        let (pins, opened) = try await fixture.pinnedStore()
        let otherValue = await pins.pinSelectedFolder(url: fixture.secondFolder)
        let other = try XCTUnwrap(otherValue)
        let log = PreparationLog()
        fixture.defaults.set(true, forKey: PinnedFolderPreparation.disabledDefaultsKey)
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            reviewDefaults: fixture.defaults, pinnedFolders: pins,
            pinnedFolderPreparationConfiguration: fixture.configuration(reads: PreparationReads(), log: log),
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: fixture.navigationFile))
        store.openPinnedFolder(try XCTUnwrap(pins.folders.first { $0.id == opened }))
        try await until { if case .ready = store.phase { return true }; return false }
        XCTAssertEqual(store.currentPinnedFolderID, opened)
        fixture.defaults.removeObject(forKey: PinnedFolderPreparation.disabledDefaultsKey)
        store.closeSession()
        try await until { log.reports.count == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.pinIDs, [other], "the just-closed pin is already warm")
    }

    func testKillSwitchStopsEveryTrigger() async throws {
        let fixture = try PreparationFixture(files: 2)
        defer { fixture.remove() }
        let (pins, _) = try await fixture.pinnedStore()
        let log = PreparationLog()
        let reads = PreparationReads()
        let uuid = try XCTUnwrap(fixture.identity.volumeUUIDString)
        var configuration = fixture.configuration(reads: reads, log: log)
        configuration.volumeUUID = { _ in uuid }
        fixture.defaults.set(true, forKey: PinnedFolderPreparation.disabledDefaultsKey)
        let owner = fixture.owner(pins: pins, configuration: configuration)

        owner.welcomeDidAppear()
        pins.noteVolumeEventForTesting(.mounted(volumeURL: URL(fileURLWithPath: "/Volumes/Match")))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(log.reports.isEmpty)
        XCTAssertEqual(reads.count, 0)
        XCTAssertFalse(fixture.indexWritten)

        fixture.defaults.removeObject(forKey: PinnedFolderPreparation.disabledDefaultsKey)
        owner.welcomeDidAppear()
        try await until { log.reports.count == 1 }
        XCTAssertEqual(log.reports.first?.outcome, .committed)
    }

    // MARK: Cancellation

    func testOpeningAFolderDuringAJobCancelsPromptlyAndWritesNothing() async throws {
        let fixture = try PreparationFixture(files: 40)
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: other.appendingPathComponent("X.txt"))
        let (pins, _) = try await fixture.pinnedStore()
        let pinDocument = try fixture.pinDocumentState()
        let reads = PreparationReads(delay: 0.025)
        let log = PreparationLog()
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            reviewDefaults: fixture.defaults, pinnedFolders: pins,
            pinnedFolderPreparationConfiguration: fixture.configuration(reads: reads, log: log),
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: fixture.navigationFile))
        try await until { reads.count >= 2 }
        XCTAssertTrue(store.pinnedFolderPreparation.isRunningForTesting)

        let opened = ContinuousClock.now
        store.openFolder(other)
        try await until { log.reports.count == 1 }
        let elapsed = opened.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(500), "cancellation must be prompt")
        XCTAssertEqual(log.reports.first?.outcome, .cancelled)
        let readsAtCancel = reads.count
        XCTAssertLessThan(readsAtCancel, 40)
        try await until { if case .ready = store.phase { return true }; return false }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, readsAtCancel, "no read after the job ended")
        XCTAssertFalse(fixture.indexWritten, "nothing is committed after cancellation")
        XCTAssertEqual(try fixture.pinDocumentState(), pinDocument)
        XCTAssertFalse(store.pinnedFolderPreparation.isRunningForTesting)
        XCTAssertTrue(store.pinnedFolderPreparation.queuedForTesting.isEmpty)
    }

    func testUnmountOrRenameOfTheJobVolumeCancelsButOtherVolumesDoNot() async throws {
        for event in ["unrelated", "unmount", "rename"] {
            let fixture = try PreparationFixture(files: 24)
            defer { fixture.remove() }
            let (pins, _) = try await fixture.pinnedStore()
            let reads = PreparationReads(delay: 0.02)
            let log = PreparationLog()
            let owner = fixture.owner(pins: pins, configuration: fixture.configuration(reads: reads, log: log))
            owner.welcomeDidAppear()
            try await until { reads.count >= 2 }
            let volume = fixture.root
            switch event {
            case "unmount": pins.noteVolumeEventForTesting(.unmounted(volumeURL: volume))
            case "rename": pins.noteVolumeEventForTesting(.renamed(oldVolumeURL: volume, volumeURL: nil))
            default: pins.noteVolumeEventForTesting(.unmounted(volumeURL: URL(fileURLWithPath: "/Volumes/Unrelated")))
            }
            try await until { log.reports.count == 1 }
            if event == "unrelated" {
                XCTAssertEqual(log.reports.first?.outcome, .committed, event)
                XCTAssertEqual(reads.count, 24, event)
                XCTAssertTrue(fixture.indexWritten, event)
            } else {
                XCTAssertEqual(log.reports.first?.outcome, .cancelled, event)
                XCTAssertLessThan(reads.count, 24, event)
                XCTAssertFalse(fixture.indexWritten, event)
            }
        }
    }

    func testQuitPreparationCancelsAndAwaitsExit() async throws {
        let fixture = try PreparationFixture(files: 30)
        defer { fixture.remove() }
        let (pins, _) = try await fixture.pinnedStore()
        let reads = PreparationReads(delay: 0.02)
        let log = PreparationLog()
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
            reviewDefaults: fixture.defaults, pinnedFolders: pins,
            pinnedFolderPreparationConfiguration: fixture.configuration(reads: reads, log: log),
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: fixture.navigationFile))
        try await until { reads.count >= 1 }
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
        XCTAssertEqual(log.reports.map(\.outcome), [.cancelled], "Quit awaits the job's exit")
        XCTAssertFalse(fixture.indexWritten)
    }

    // MARK: Bounds

    func testLowPowerChecksOnlyAndThermalPostponesThenRetries() async throws {
        let fixture = try PreparationFixture(files: 3)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let accessValue = await pins.preparationAccess(id: id)
        let access = try XCTUnwrap(accessValue)
        let reads = PreparationReads()
        let state = PreparationResources(.init(lowPower: true, thermal: .nominal))

        var settings = fixture.settings(reads: reads)
        settings.resources = { state.value }
        let lowPower = await Self.run(access, settings)
        XCTAssertEqual(lowPower.outcome, .lowPower)
        XCTAssertEqual(lowPower.files, 3)
        XCTAssertEqual(lowPower.misses, 3)
        XCTAssertEqual(reads.count, 0, "Low Power reads no metadata")
        XCTAssertFalse(fixture.indexWritten)

        for thermal in [QualityCueWorkPolicy.Resources.Thermal.serious, .critical] {
            state.value = .init(lowPower: false, thermal: thermal)
            let report = await Self.run(access, settings)
            XCTAssertEqual(report.outcome, .postponed)
            XCTAssertEqual(report.files, 0, "postponed before discovery")
        }
        // Re-sampled between stages: heat during the job postpones before reading.
        state.value = .init(lowPower: false, thermal: .nominal)
        settings.hooks.willBeginStage = { if $0 == .extraction { state.value = .init(lowPower: false, thermal: .serious) } }
        let midJob = await Self.run(access, settings)
        XCTAssertEqual(midJob.outcome, .postponed)
        XCTAssertEqual(reads.count, 0)
        XCTAssertFalse(fixture.indexWritten)

        // The owner retries a postponed pin while Welcome stays idle.
        state.value = .init(lowPower: false, thermal: .serious)
        let log = PreparationLog()
        var configuration = fixture.configuration(reads: reads, log: log)
        configuration.postponeDelay = .milliseconds(200)
        let owner = PinnedFolderPreparation(pins: pins, defaults: fixture.defaults, configuration: configuration,
                                            resources: { state.value })
        owner.isEligible = { true }
        owner.welcomeDidAppear()
        try await until { log.reports.count == 1 }
        XCTAssertEqual(log.reports.first?.outcome, .postponed)
        state.value = .init(lowPower: false, thermal: .fair)
        try await until { log.reports.count == 2 }
        XCTAssertEqual(log.reports.last?.outcome, .committed)
        XCTAssertEqual(reads.count, 3)
    }

    func testExtractionCapCommitsCompletedReadsAndTheNextJobContinues() async throws {
        let fixture = try PreparationFixture(files: 5)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let accessValue = await pins.preparationAccess(id: id)
        let access = try XCTUnwrap(accessValue)
        let reads = PreparationReads()
        var settings = fixture.settings(reads: reads)
        settings.extractionLimit = 2
        settings.extractionBatch = 1
        let first = await Self.run(access, settings)
        XCTAssertEqual(first.outcome, .committed)
        XCTAssertEqual(first.extracted, 2)
        XCTAssertTrue(first.capped)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(try fixture.indexEntryCount(), 2)

        settings.extractionLimit = 2_000
        let second = await Self.run(access, settings)
        XCTAssertEqual(second.misses, 3)
        XCTAssertEqual(second.extracted, 3)
        XCTAssertFalse(second.capped)
        XCTAssertEqual(reads.count, 5)
        XCTAssertEqual(try fixture.indexEntryCount(), 5)

        // A zero time budget reads nothing and has nothing to commit.
        settings.extractionDuration = .zero
        try Data("new".utf8).write(to: fixture.folder.appendingPathComponent("a/NEW.JPG"))
        let timed = await Self.run(access, settings)
        XCTAssertEqual(timed.misses, 1)
        XCTAssertEqual(timed.extracted, 0)
        XCTAssertTrue(timed.capped)
        XCTAssertEqual(reads.count, 5)
    }

    // MARK: Read-only contract

    func testPreparationTouchesNoSessionStatePinsOrOriginals() async throws {
        let fixture = try PreparationFixture(files: 6)
        defer { fixture.remove() }
        let sidecar = fixture.folder.appendingPathComponent(".louppe_session.json")
        try Data(#"{"disposable":true}"#.utf8).write(to: sidecar)
        let sidecarBytes = try Data(contentsOf: sidecar)
        let sidecarDate = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date)
        let digests = try fixture.originalDigests()
        let (pins, _) = try await fixture.pinnedStore()
        let pinDocument = try fixture.pinDocumentState()
        let persistence = PreparationSpyPersistence(
            backing: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")))
        let reads = PreparationReads()
        let log = PreparationLog()
        let scopes = PreparationScopes()
        var configuration = fixture.configuration(reads: reads, log: log)
        configuration.scopeAccess = scopes.access
        let store = SessionStore(
            persistence: persistence, reviewDefaults: fixture.defaults, pinnedFolders: pins,
            pinnedFolderPreparationConfiguration: configuration,
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: fixture.navigationFile))
        try await until { log.reports.count == 1 }
        XCTAssertEqual(log.reports.first?.outcome, .committed)
        XCTAssertEqual(reads.count, 6)

        let calls = await persistence.calls
        XCTAssertEqual(calls, 0, "no sidecar read or write")
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.modificationDate] as? Date, sidecarDate)
        XCTAssertEqual(try fixture.originalDigests(), digests)
        XCTAssertEqual(try fixture.pinDocumentState(), pinDocument, "pins and positions are untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.navigationFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("backups").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).sorted(),
                       [".louppe_session.json", "a", "b", "empty"])
        XCTAssertEqual(scopes.starts, 1)
        XCTAssertEqual(scopes.stops, 1)
        XCTAssertEqual(scopes.urls, [fixture.folder.absoluteString])
        if case .welcome = store.phase {} else { XCTFail("preparation never opens a session") }
        XCTAssertTrue(store.items.isEmpty)
    }

    func testExtractorReadsOnlyNewAndChangedFiles() async throws {
        let fixture = try PreparationFixture(files: 6)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let accessValue = await pins.preparationAccess(id: id)
        let access = try XCTUnwrap(accessValue)
        let reads = PreparationReads()
        let settings = fixture.settings(reads: reads)
        let first = await Self.run(access, settings)
        XCTAssertEqual(first.outcome, .committed)
        XCTAssertEqual(reads.count, 6)

        let unchanged = await Self.run(access, settings)
        XCTAssertEqual(unchanged.outcome, .unchanged)
        XCTAssertEqual(unchanged.misses, 0)
        XCTAssertEqual(reads.count, 6, "cache hits read nothing")

        let changed = fixture.folder.appendingPathComponent("a/IMG_0001.JPG")
        try Data("changed contents".utf8).write(to: changed)
        try Data("new".utf8).write(to: fixture.folder.appendingPathComponent("b/NEW.JPG"))
        reads.reset()
        let third = await Self.run(access, settings)
        XCTAssertEqual(third.outcome, .committed)
        XCTAssertEqual(third.misses, 2)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(Set(reads.names), ["IMG_0001.JPG", "NEW.JPG"])
        XCTAssertEqual(try fixture.indexEntryCount(), 7)
    }

    func testReplacementDuringTheJobPreventsTheCommit() async throws {
        for stage in [PinnedFolderPreparationStage.extraction, .identityBarrier] {
            let fixture = try PreparationFixture(files: 4)
            defer { fixture.remove() }
            let (pins, id) = try await fixture.pinnedStore()
            let accessValue = await pins.preparationAccess(id: id)
            let access = try XCTUnwrap(accessValue)
            var settings = fixture.settings(reads: PreparationReads())
            let target = fixture.folder.appendingPathComponent("b/IMG_0002.JPG")
            settings.hooks.willBeginStage = { current in
                guard current == stage else { return }
                let replacement = target.deletingLastPathComponent().appendingPathComponent(".replacement")
                try? Data("replacement".utf8).write(to: replacement)
                _ = replacement.withUnsafeFileSystemRepresentation { from in
                    target.withUnsafeFileSystemRepresentation { to in rename(from!, to!) }
                }
            }
            let report = await Self.run(access, settings)
            XCTAssertEqual(report.outcome, .changed, "\(stage)")
            XCTAssertFalse(fixture.indexWritten, "\(stage)")
        }
    }

    func testScopedAccessIsBalancedOnEveryOutcome() async throws {
        let fixture = try PreparationFixture(files: 3)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let accessValue = await pins.preparationAccess(id: id)
        let access = try XCTUnwrap(accessValue)
        let scopes = PreparationScopes()
        var settings = fixture.settings(reads: PreparationReads())
        settings.scopeAccess = scopes.access
        _ = await Self.run(access, settings)                                    // committed
        _ = await Self.run(access, settings)                                    // unchanged
        settings.hooks.willBeginStage = { if $0 == .indexLoad { throw CancellationError() } }
        let failed = await Self.run(access, settings)
        XCTAssertEqual(failed.outcome, .cancelled)
        let cancelled = await Task.detached {
            PinnedFolderPreparationJob.run(access, settings: settings, isCancelled: { true })
        }.value
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(scopes.starts, 4)
        XCTAssertEqual(scopes.stops, 4)
        XCTAssertEqual(Set(scopes.urls), [access.authorityURL.absoluteString])
    }

    func testLaterOpenHitsTheIndexForPreparedFiles() async throws {
        let fixture = try PreparationFixture(files: 8)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let accessValue = await pins.preparationAccess(id: id)
        let access = try XCTUnwrap(accessValue)
        let prepared = await Self.run(access, fixture.settings(reads: PreparationReads()))
        XCTAssertEqual(prepared.outcome, .committed)

        let openReads = PreparationReads()
        var hooks = SessionOpeningWorker.Hooks()
        hooks.metadataReader = openReads.reader
        hooks.metadataIndex = try XCTUnwrap(ArchiveMetadataIndex(folder: fixture.folder, cacheDirectory: fixture.cache))
        let folder = fixture.folder
        let result = try await Task.detached {
            try await SessionOpeningWorker.prepare(
                folder: folder, pairingMode: .separate,
                persistence: SessionPersistence(backupDirectory: fixture.root.appendingPathComponent("backups")),
                recorder: SessionOpeningRecorder(), allowsPreview: false, hooks: hooks)
        }.value
        XCTAssertEqual(openReads.count, 0, "every prepared file is an index hit")
        XCTAssertEqual(result.restoration.items.count, 8)
        XCTAssertTrue(result.restoration.items.allSatisfy { $0.primaryFile.cameraModel == "Prepared" })
    }

    // MARK: Helpers

    // MARK: Review regressions (30 October)

    /// Background resolution runs outside the pin actor, so a stalled volume
    /// cannot hold a user's pin open or position read behind it.
    func testStalledBackgroundResolutionNeverDelaysAPinOpen() async throws {
        let fixture = try PreparationFixture(files: 2)
        defer { fixture.remove() }
        let gate = ResolutionGate()
        let worker = PinnedFoldersPersistence(storageDirectory: fixture.storage, operations: fixture.operations(gate: gate))
        let pins = PinnedFoldersStore(storageDirectory: fixture.storage, persistence: worker, observesSystemChanges: false)
        let idValue = await pins.pinSelectedFolder(url: fixture.folder)
        let id = try XCTUnwrap(idValue)
        gate.arm()
        let background = Task { await pins.preparationAccess(id: id) }
        try await until { gate.isHolding }
        let started = ContinuousClock.now
        let request = await pins.prepareOpen(id: id)
        _ = await pins.position(for: fixture.identity)
        XCTAssertNotNil(request)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "the user open waited for background resolution")
        gate.release()
        _ = await background.value
    }

    /// Each postponed pin is retried; a later postponement never drops an earlier one.
    func testEveryThermallyPostponedPinIsRetried() async throws {
        let fixture = try PreparationFixture(files: 2, secondFolder: true)
        defer { fixture.remove() }
        let (pins, first) = try await fixture.pinnedStore()
        let secondValue = await pins.pinSelectedFolder(url: fixture.secondFolder)
        let second = try XCTUnwrap(secondValue)
        let state = PreparationResources(.init(lowPower: false, thermal: .serious))
        let log = PreparationLog()
        var configuration = fixture.configuration(reads: PreparationReads(), log: log)
        configuration.postponeDelay = .milliseconds(150)
        let owner = PinnedFolderPreparation(pins: pins, defaults: fixture.defaults, configuration: configuration,
                                            resources: { state.value })
        owner.isEligible = { true }
        owner.welcomeDidAppear()
        try await until { log.reports.count == 2 }
        XCTAssertEqual(log.reports.map(\.outcome), [.postponed, .postponed])
        state.value = .init(lowPower: false, thermal: .nominal)
        try await until { log.reports.count == 4 }
        let committed = zip(log.pinIDs, log.reports).dropFirst(2).filter { $0.1.outcome == .committed }.map(\.0)
        XCTAssertEqual(Set(committed), [first, second])
        await owner.cancelAndWait()
    }

    /// The time budget is checked before each file, not only between batches.
    func testExtractionDeadlineStopsWithinABatch() async throws {
        let fixture = try PreparationFixture(files: 32)
        defer { fixture.remove() }
        let (pins, id) = try await fixture.pinnedStore()
        let accessValue = await pins.preparationAccess(id: id)
        let access = try XCTUnwrap(accessValue)
        let reads = PreparationReads(delay: 0.02)
        var settings = fixture.settings(reads: reads)
        settings.extractionDuration = .milliseconds(30)
        let report = await Self.run(access, settings)
        XCTAssertTrue(report.capped)
        XCTAssertLessThan(reads.count, 16, "workers kept claiming files after the deadline")
        XCTAssertLessThan(report.extractionSeconds, 0.25)
    }

    private static func run(_ access: PinnedFolderPreparationAccess,
                            _ settings: PinnedFolderPreparationJob.Settings) async -> PinnedFolderPreparationReport {
        await Task.detached { PinnedFolderPreparationJob.run(access, settings: settings, isCancelled: { false }) }.value
    }

    private func until(timeout: Duration = .seconds(10), _ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Fixtures

@MainActor
private final class PreparationFixture {
    let root: URL
    let folder: URL
    let secondFolder: URL
    let storage: URL
    let cache: URL
    let navigationFile: URL
    let identity: PinnedFolderIdentity
    let defaults: UserDefaults
    private let defaultsName = "Louppe-Preparation-\(UUID().uuidString)"

    init(files: Int, secondFolder makesSecond: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppePrepare-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Photos", isDirectory: true)
        secondFolder = root.appendingPathComponent("Second", isDirectory: true)
        storage = root.appendingPathComponent("Support", isDirectory: true)
        cache = root.appendingPathComponent("Cache", isDirectory: true)
        navigationFile = root.appendingPathComponent("Navigation.json")
        let manager = FileManager.default
        for name in ["a", "b", "empty"] {
            try manager.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true),
                                        withIntermediateDirectories: true)
        }
        for index in 1...files {
            let sub = index % 2 == 1 ? "a" : "b"
            try Data("original \(index)".utf8).write(
                to: folder.appendingPathComponent(sub).appendingPathComponent(String(format: "IMG_%04d.JPG", index)))
        }
        if makesSecond {
            try manager.createDirectory(at: secondFolder, withIntermediateDirectories: true)
            try Data("second".utf8).write(to: secondFolder.appendingPathComponent("S.JPG"))
        }
        identity = PinnedFolderIdentity(source: try .capture(at: folder))
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    func pinnedStore() async throws -> (PinnedFoldersStore, UUID) {
        let worker = PinnedFoldersPersistence(storageDirectory: storage, operations: operations())
        let store = PinnedFoldersStore(storageDirectory: storage, persistence: worker, observesSystemChanges: false)
        let idValue = await store.pinSelectedFolder(url: folder)
        let id = try XCTUnwrap(idValue)
        return (store, id)
    }

    func operations(gate: ResolutionGate? = nil) -> SecurityScopedFolderBookmarks.Operations {
        .init(resolve: { data in
            gate?.pass()
            guard let string = String(data: data, encoding: .utf8), let url = URL(string: string) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return .init(url: url, isStale: false)
        }, create: { Data($0.absoluteString.utf8) },
              exists: { FileManager.default.fileExists(atPath: $0.path) },
              access: .init(start: { _ in true }, stop: { _ in }))
    }

    func settings(reads: PreparationReads) -> PinnedFolderPreparationJob.Settings {
        var settings = PinnedFolderPreparationJob.Settings()
        settings.metadataCacheDirectory = cache
        settings.resources = { .init(lowPower: false, thermal: .nominal) }
        settings.scopeAccess = .init(start: { _ in true }, stop: { _ in })
        settings.hooks.metadataReader = reads.reader
        return settings
    }

    func configuration(reads: PreparationReads, log: PreparationLog) -> PinnedFolderPreparation.Configuration {
        var configuration = PinnedFolderPreparation.Configuration()
        configuration.settleDelay = .zero
        configuration.metadataCacheDirectory = cache
        configuration.scopeAccess = .init(start: { _ in true }, stop: { _ in })
        configuration.volumeUUID = { _ in nil }
        configuration.hooks.metadataReader = reads.reader
        configuration.jobDidFinish = { id, report in log.record(id, report) }
        return configuration
    }

    func owner(pins: PinnedFoldersStore, configuration: PinnedFolderPreparation.Configuration,
               eligible: Bool = true) -> PinnedFolderPreparation {
        let owner = PinnedFolderPreparation(pins: pins, defaults: defaults, configuration: configuration,
                                            resources: { .init(lowPower: false, thermal: .nominal) })
        owner.isEligible = { eligible }
        return owner
    }

    var indexFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ArchiveMetadataIndex.snapshotExtension }
    }
    var indexWritten: Bool { !indexFiles.isEmpty }

    func indexEntryCount() throws -> Int {
        let index = try XCTUnwrap(ArchiveMetadataIndex(folder: folder, cacheDirectory: cache))
        return try XCTUnwrap(index.storedEntriesForTesting()).count
    }

    func pinDocumentState() throws -> (Data, Date) {
        let url = storage.appendingPathComponent("PinnedFolders.json")
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return (try Data(contentsOf: url), try XCTUnwrap(date))
    }

    func originalDigests() throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "JPG" else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: url))
            result[url.path] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

private func XCTAssertEqual(_ lhs: (Data, Date), _ rhs: (Data, Date), _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.0, rhs.0, message, file: file, line: line)
    XCTAssertEqual(lhs.1, rhs.1, message, file: file, line: line)
}

private final class PreparationReads: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    var count: Int { lock.withLock { urls.count } }
    var names: [String] { lock.withLock { urls.map(\.lastPathComponent) } }
    func reset() { lock.withLock { urls = [] } }

    var reader: @Sendable (URL) throws -> MetadataExtractor.ScanInfo {
        { [self] url in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.withLock { urls.append(url) }
            return MetadataExtractor.ScanInfo(captureDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                              cameraModel: "Prepared")
        }
    }
}

@MainActor
private final class PreparationLog {
    private(set) var reports: [PinnedFolderPreparationReport] = []
    private(set) var pinIDs: [UUID] = []
    func record(_ id: UUID, _ report: PinnedFolderPreparationReport) {
        pinIDs.append(id)
        reports.append(report)
    }
}

/// Holds jobs at a stage and records how many were inside at once.
private final class PreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var inside = 0
    private var total = 0
    private var maximum = 0
    private var released = false

    var entered: Int { lock.withLock { total } }
    var maximumConcurrent: Int { lock.withLock { maximum } }

    func enter() {
        let wait: Bool = lock.withLock {
            inside += 1
            total += 1
            maximum = max(maximum, inside)
            return !released
        }
        if wait { _ = semaphore.wait(timeout: .now() + 10) }
        lock.withLock { inside -= 1 }
    }

    func release() {
        lock.withLock { released = true }
        semaphore.signal()
    }
}

/// Blocks the first bookmark resolution after `arm()` until `release()`.
private final class ResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var holding = false

    var isHolding: Bool { lock.withLock { holding } }
    func arm() { lock.withLock { armed = true } }
    func release() { semaphore.signal() }

    func pass() {
        let blocks: Bool = lock.withLock {
            guard armed else { return false }
            armed = false
            holding = true
            return true
        }
        guard blocks else { return }
        _ = semaphore.wait(timeout: .now() + 10)
        lock.withLock { holding = false }
    }
}

private final class PreparationResources: @unchecked Sendable {
    private let lock = NSLock()
    private var current: QualityCueWorkPolicy.Resources
    init(_ value: QualityCueWorkPolicy.Resources) { current = value }
    var value: QualityCueWorkPolicy.Resources {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private final class PreparationScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var stopped = 0
    var starts: Int { lock.withLock { started.count } }
    var stops: Int { lock.withLock { stopped } }
    var urls: [String] { lock.withLock { Array(Set(started)).sorted() } }
    var access: SecurityScopedResourceAccess {
        .init(start: { [self] url in lock.withLock { started.append(url.absoluteString) }; return true },
              stop: { [self] _ in lock.withLock { stopped += 1 } })
    }
}

private actor PreparationSpyPersistence: SessionPersistenceClient {
    private let backing: SessionPersistence
    private(set) var calls = 0

    init(backing: SessionPersistence) { self.backing = backing }

    func save(_ session: SessionFile, for folder: URL, sequence: UInt64,
              access: SessionPersistence.AccessContext) async -> SessionPersistence.SaveResult {
        calls += 1
        return await backing.save(session, for: folder, sequence: sequence, access: access)
    }

    func read(for folder: URL, folderIdentity: SessionPersistence.SourceFolderIdentity,
              legacySidecarRelocationAuthorization: SessionPersistence.LegacySidecarRelocationAuthorization?)
        async -> SessionPersistence.ReadResult {
        calls += 1
        return await backing.read(for: folder, folderIdentity: folderIdentity,
                                  legacySidecarRelocationAuthorization: legacySidecarRelocationAuthorization)
    }
}
