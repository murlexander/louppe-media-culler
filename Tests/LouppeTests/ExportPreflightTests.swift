import Foundation
import XCTest
@testable import Louppe

/// Balanced, injectable security-scope accounting (no real sandbox grants).
private final class LeaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var active: Int { lock.lock(); defer { lock.unlock() }; return starts - stops }
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }

    var access: SecurityScopedResourceAccess {
        .init(start: { _ in
            self.lock.lock(); defer { self.lock.unlock() }
            self.starts += 1
            return true
        }, stop: { _ in
            self.lock.lock(); defer { self.lock.unlock() }
            self.stops += 1
        })
    }
}

/// Blocks an injected preflight on its detached thread, standing in for a
/// slow, sleeping, or network destination volume.
private final class ValidationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var waiting = 0

    var waiterCount: Int { condition.lock(); defer { condition.unlock() }; return waiting }

    func wait() {
        condition.lock()
        waiting += 1
        while !isOpen { condition.wait() }
        waiting -= 1
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class OperationGate {
    var allowStart = true
    var started: [ExportMode] = []
    var finished: [(mode: ExportMode, movedIDs: [String], recovery: Bool)] = []

    func willStart(_ mode: ExportMode) -> Bool {
        guard allowStart else { return false }
        started.append(mode)
        return true
    }
}

/// AUD-14 (ordinary export preflight off the main actor) and the routing
/// portion of AUD-03 (Review → Back → Review → Copy after cancellation or
/// failure keeps grants balanced). Every case uses disposable folders under
/// /private/tmp and a disposable journal root.
@MainActor
final class ExportPreflightTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private var otherDestination: URL!
    private var journals: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: "/private/tmp/LouppeExportPreflight-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        otherDestination = root.appendingPathComponent("Other", isDirectory: true)
        journals = root.appendingPathComponent("Journals", isDirectory: true)
        for folder in [source!, destination!, otherDestination!, journals!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - AUD-14 ordinary preflight

    func testCopyPreflightRunsOffMainBeforeAnyFileWorkThenCopies() async throws {
        let item = try makeItem("KEEP.JPG")
        let recorder = LeaseRecorder()
        let gate = ValidationGate()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { [destination] _ in destination }, gate: gate)

        let returned = ContinuousClock.now
        prompt(manager, items: [item], mode: .copy, operations: operations)
        XCTAssertLessThan(ContinuousClock.now - returned, .milliseconds(500),
                          "Choosing a destination must return before a slow volume answers")
        XCTAssertEqual(manager.state, .validatingDestination(.copy))
        try await eventually { gate.waiterCount == 1 }
        // The main actor stays available while the volume is still answering.
        let responsive = await Task { @MainActor in true }.value
        XCTAssertTrue(responsive)
        XCTAssertEqual(recorder.active, 2, "UI lease plus the detached preflight's own lease")
        XCTAssertTrue(operations.started.isEmpty, "No shared file-operation authority before validation")
        XCTAssertEqual(try contents(destination), [])
        XCTAssertEqual(try contents(journals), [], "No journal before validation completes")

        gate.open()
        let outcome = try await finishedOutcome(manager)
        XCTAssertEqual(outcome.mode, .copy)
        XCTAssertEqual(outcome.files, 1)
        XCTAssertTrue(outcome.isClean)
        XCTAssertEqual(operations.started, [.copy])
        XCTAssertEqual(operations.finished.count, 1)
        XCTAssertEqual(try contents(destination), ["KEEP.JPG"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.primaryURL.path), "Copy keeps the original")
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        try await eventually { recorder.active == 0 }
        manager.reset()
        XCTAssertEqual(recorder.active, 0)
        XCTAssertEqual(recorder.startCount, recorder.stopCount)
    }

    func testMovePreflightLeavesOriginalsInPlaceUntilValidatedThenMoves() async throws {
        let item = try makeItem("MOVE.JPG")
        let recorder = LeaseRecorder()
        let gate = ValidationGate()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { [destination] _ in destination }, gate: gate)

        prompt(manager, items: [item], mode: .move, operations: operations)
        XCTAssertEqual(manager.state, .validatingDestination(.move))
        try await eventually { gate.waiterCount == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.primaryURL.path))
        XCTAssertEqual(try contents(destination), [])
        XCTAssertTrue(operations.started.isEmpty)

        gate.open()
        let outcome = try await finishedOutcome(manager)
        XCTAssertEqual(outcome.mode, .move)
        XCTAssertEqual(outcome.files, 1)
        XCTAssertEqual(operations.finished.first?.movedIDs, [item.id])
        XCTAssertEqual(try contents(destination), ["MOVE.JPG"])
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        try await eventually { recorder.active == 0 }
    }

    func testCancelledPreflightRejectsItsLateResultAndBalancesLeases() async throws {
        let item = try makeItem("KEEP.JPG")
        let recorder = LeaseRecorder()
        let gate = ValidationGate()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { [destination] _ in destination }, gate: gate)

        prompt(manager, items: [item], mode: .copy, operations: operations)
        try await eventually { gate.waiterCount == 1 }
        manager.cancelDestinationValidation()
        XCTAssertEqual(manager.state, .summary)
        XCTAssertEqual(recorder.active, 1, "The still-running check keeps only its own lease")

        gate.open()
        try await eventually { recorder.active == 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.state, .summary, "A cancelled result must not advance the dialog")
        XCTAssertTrue(operations.started.isEmpty)
        XCTAssertEqual(try contents(destination), [])
        XCTAssertEqual(try contents(journals), [])
        XCTAssertEqual(recorder.startCount, recorder.stopCount)
    }

    func testSupersededPreflightCannotStartTheEarlierDestination() async throws {
        let item = try makeItem("KEEP.JPG")
        let recorder = LeaseRecorder()
        let gate = ValidationGate()
        let operations = OperationGate()
        var choices = [destination!, otherDestination!]
        let gatedDestination = destination!
        let manager = makeManager(
            recorder: recorder,
            choose: { _ in choices.removeFirst() },
            gate: gate,
            gateApplies: { FileOperationJournal.exactPathsEqual($0.destination, gatedDestination) }
        )

        prompt(manager, items: [item], mode: .copy, operations: operations)
        try await eventually { gate.waiterCount == 1 }
        manager.cancelDestinationValidation()
        prompt(manager, items: [item], mode: .copy, operations: operations)
        let outcome = try await finishedOutcome(manager)
        XCTAssertEqual(outcome.destinations.map(\.lastPathComponent), ["Other"])
        XCTAssertEqual(try contents(otherDestination), ["KEEP.JPG"])

        gate.open()
        try await eventually { recorder.active == 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(operations.started, [.copy], "Only the newest preflight may start file work")
        XCTAssertEqual(try contents(destination), [])
        if case .finished = manager.state {} else { XCTFail("A stale preflight replaced the result: \(manager.state)") }
    }

    func testFailedPreflightReportsErrorWithoutWorkAndRetryStillCopies() async throws {
        let item = try makeItem("KEEP.JPG")
        let inside = source.appendingPathComponent("Inside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let recorder = LeaseRecorder()
        let operations = OperationGate()
        var choices = [inside, destination!]
        let manager = makeManager(recorder: recorder, choose: { _ in choices.removeFirst() })

        prompt(manager, items: [item], mode: .copy, operations: operations)
        XCTAssertEqual(manager.state, .validatingDestination(.copy))
        try await eventually { if case .failed = manager.state { return true }; return false }
        XCTAssertEqual(manager.state, .failed(
            ExportDestinationValidator.ValidationError.insideSourceFolder.localizedDescription
        ))
        try await eventually { recorder.active == 0 }
        XCTAssertTrue(operations.started.isEmpty)
        XCTAssertEqual(try contents(inside), [])
        XCTAssertEqual(try contents(journals), [])

        manager.reset(keepingRoutingDestinations: true)
        prompt(manager, items: [item], mode: .copy, operations: operations)
        let outcome = try await finishedOutcome(manager)
        XCTAssertEqual(outcome.files, 1)
        XCTAssertEqual(try contents(destination), ["KEEP.JPG"])
        try await eventually { recorder.active == 0 }
        XCTAssertEqual(recorder.startCount, recorder.stopCount)
    }

    func testDismissingDuringPreflightNeverStartsWork() async throws {
        let item = try makeItem("KEEP.JPG")
        let recorder = LeaseRecorder()
        let gate = ValidationGate()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { [destination] _ in destination }, gate: gate)

        prompt(manager, items: [item], mode: .move, operations: operations)
        try await eventually { gate.waiterCount == 1 }
        manager.reset()
        XCTAssertEqual(recorder.active, 1)
        gate.open()
        try await eventually { recorder.active == 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.state, .summary)
        XCTAssertTrue(operations.started.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.primaryURL.path))
        XCTAssertEqual(try contents(destination), [])
    }

    func testRefusedPickerLeavesNoLeaseOrState() {
        let recorder = LeaseRecorder()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { _ in nil })
        prompt(manager, items: [PhotoItem(id: "X", primaryURL: source.appendingPathComponent("X.JPG"),
                                          pairedURL: nil, captureDate: nil, cameraModel: nil,
                                          lensModel: nil, fileSize: 1)],
               mode: .copy, operations: operations)
        XCTAssertEqual(manager.state, .summary)
        XCTAssertEqual(recorder.startCount, 0)
    }

    // MARK: - AUD-03 routing grants across Back, cancellation, and failure

    func testRoutingReviewBackReviewCopyAfterCancellationAndFailureKeepsGrantsBalanced() async throws {
        let keep = try makeItem("KEEP.JPG", rating: .yes)
        let leave = try makeItem("LEAVE.JPG", rating: .no)
        let recorder = LeaseRecorder()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { _ in nil })
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: destination)
        manager.retainRoutingDestinationAccess(destination, for: route.id)
        XCTAssertEqual(recorder.active, 1)

        // Review → Back.
        prepareRoute(manager, route: route, items: [keep, leave], operations: operations)
        try await awaitingConfirmation(manager)
        manager.backFromMultiDestinationConfirmation()
        try await eventually { recorder.active == 1 }

        // Review → cancel while checking.
        prepareRoute(manager, route: route, items: [keep, leave], operations: operations)
        manager.cancelMultiDestinationPreparation()
        XCTAssertEqual(manager.state, .summary)
        try await eventually { recorder.active == 1 }

        // Review → Copy refused by the shared operation authority → OK.
        prepareRoute(manager, route: route, items: [keep, leave], operations: operations)
        try await awaitingConfirmation(manager)
        operations.allowStart = false
        manager.confirmMultiDestinationExport()
        guard case .failed = manager.state else { return XCTFail("Expected the refused start to fail") }
        XCTAssertEqual(try contents(destination), [])
        XCTAssertEqual(try contents(journals), [])
        manager.reset(keepingRoutingDestinations: true)
        try await eventually { recorder.active == 1 }

        // Review → Back → Review → Copy.
        operations.allowStart = true
        prepareRoute(manager, route: route, items: [keep, leave], operations: operations)
        try await awaitingConfirmation(manager)
        manager.backFromMultiDestinationConfirmation()
        prepareRoute(manager, route: route, items: [keep, leave], operations: operations)
        try await awaitingConfirmation(manager)
        manager.confirmMultiDestinationExport()
        XCTAssertGreaterThanOrEqual(recorder.active, 2, "The worker holds an independent lease")
        let outcome = try await finishedOutcome(manager)
        XCTAssertTrue(outcome.isClean)
        XCTAssertEqual(outcome.files, 1)
        XCTAssertEqual(operations.started, [.copy])
        XCTAssertEqual(try contents(destination), ["KEEP.JPG"], "Unmatched media is never copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leave.primaryURL.path))
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        try await eventually { recorder.active == 0 }
        manager.reset()
        XCTAssertEqual(recorder.active, 0)
        XCTAssertEqual(recorder.startCount, recorder.stopCount)
    }

    func testStoppedRoutingCopyReleasesEveryGrant() async throws {
        let items = try (0..<24).map { try makeItem(String(format: "KEEP_%02d.JPG", $0), rating: .yes) }
        let recorder = LeaseRecorder()
        let operations = OperationGate()
        let manager = makeManager(recorder: recorder, choose: { _ in nil })
        let route = MultiDestinationExportRoute(predicate: .decision(.yes), destination: destination)
        manager.retainRoutingDestinationAccess(destination, for: route.id)
        prepareRoute(manager, route: route, items: items, operations: operations)
        try await awaitingConfirmation(manager)
        manager.confirmMultiDestinationExport()
        manager.requestCopyStopConfirmation()
        manager.confirmCopyStop()
        let outcome = try await finishedOutcome(manager)
        // Whether the stop lands before or after the last file, completed
        // copies match the disk and no grant or journal remains.
        XCTAssertEqual(try contents(destination).count, outcome.files)
        if outcome.cancelled { XCTAssertEqual(outcome.cancellationReason, .userConfirmed) }
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: journals))
        try await eventually { recorder.active == 0 }
        manager.reset()
        XCTAssertEqual(recorder.startCount, recorder.stopCount)
    }

    // MARK: - Helpers

    private func makeManager(
        recorder: LeaseRecorder,
        choose: @escaping @MainActor (ExportMode) -> URL?,
        gate: ValidationGate? = nil,
        gateApplies: @escaping @Sendable (ExportManager.DestinationValidationRequest) -> Bool = { _ in true }
    ) -> ExportManager {
        ExportManager(
            makeFolderAccess: { .init(url: $0, resourceAccess: recorder.access) },
            chooseDestination: choose,
            validateDestination: { request in
                if let gate, gateApplies(request) { gate.wait() }
                return try ExportDestinationValidator.validateBound(
                    sourceFolder: request.sourceFolder,
                    destination: request.destination,
                    items: request.items,
                    mode: request.mode
                )
            },
            journalDirectory: journals
        )
    }

    private func prompt(
        _ manager: ExportManager, items: [PhotoItem], mode: ExportMode, operations: OperationGate
    ) {
        manager.promptDestinationAndExport(
            sourceFolder: source, selected: items, familyContextItems: items,
            sessionGeneration: 0, mode: mode, includeXMP: false, xmpProfile: .universal,
            visibleDecisionKeywords: false, allowExternalLabelReplacement: false,
            onOperationWillStart: { operations.willStart($0) },
            onOperationDidFinish: { mode, moved, recovery, _ in
                operations.finished.append((mode, moved, recovery))
            }
        )
    }

    private func prepareRoute(
        _ manager: ExportManager, route: MultiDestinationExportRoute,
        items: [PhotoItem], operations: OperationGate
    ) {
        manager.prepareMultiDestinationExport(
            routes: [route], items: items, sourceFolder: source, includeXMP: false,
            familyContextItems: items, sessionGeneration: 0, xmpProfile: .universal,
            visibleDecisionKeywords: false, allowExternalLabelReplacement: false,
            onOperationWillStart: { operations.willStart($0) },
            onOperationDidFinish: { mode, moved, recovery, _ in
                operations.finished.append((mode, moved, recovery))
            }
        )
    }

    private func makeItem(_ name: String, rating: Rating = .yes) throws -> PhotoItem {
        let url = source.appendingPathComponent(name)
        try Data("bytes of \(name)".utf8).write(to: url)
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return PhotoItem(id: name, primaryURL: url, pairedURL: nil, captureDate: nil,
                         cameraModel: nil, lensModel: nil, mediaKind: .photo,
                         fileSize: size, rating: rating)
    }

    private func contents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func awaitingConfirmation(_ manager: ExportManager) async throws {
        try await eventually {
            if case .awaitingMultiDestinationConfirmation = manager.state { return true }
            return false
        }
    }

    private func finishedOutcome(_ manager: ExportManager) async throws -> ExportManager.Outcome {
        var outcome: ExportManager.Outcome?
        try await eventually {
            if case .finished(let value) = manager.state { outcome = value; return true }
            if case .failed(let message) = manager.state { XCTFail("Export failed: \(message)"); return true }
            return false
        }
        return try XCTUnwrap(outcome)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The asynchronous export contract did not settle")
    }
}
