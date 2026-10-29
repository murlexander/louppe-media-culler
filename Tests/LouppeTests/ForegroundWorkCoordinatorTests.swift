import Foundation
import XCTest
@testable import Louppe

@MainActor
final class ForegroundWorkCoordinatorTests: XCTestCase {
    func testIdleAdmissionAndSynchronousDeadline() async {
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .milliseconds(60))
        let idle = await coordinator.waitForBackgroundAdmission()
        XCTAssertTrue(idle)
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        XCTAssertFalse(coordinator.shouldAdmitBackgroundWork(deferredSince: .now))
        XCTAssertTrue(coordinator.shouldAdmitBackgroundWork(deferredSince: .now.advanced(by: .seconds(-1))))
    }

    func testInteractionDefersWithoutForegroundDemandThenAdmitsWhenQuiet() async throws {
        let coordinator = ForegroundWorkCoordinator(quietInterval: .milliseconds(80), maximumDeferral: .seconds(2))
        coordinator.noteInteraction()
        let task = Task { await coordinator.waitForBackgroundAdmission() }
        defer { task.cancel() }
        try await boundary { coordinator.waitingCountForTesting == 1 }
        let admitted = await task.value
        XCTAssertTrue(admitted)
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
    }

    func testCancellationRetiresWaitingAndAlreadyCancelledAdmission() async throws {
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let task = Task { await coordinator.waitForBackgroundAdmission() }
        try await boundary { coordinator.waitingCountForTesting == 1 }
        task.cancel()
        let admitted = await task.value
        XCTAssertFalse(admitted)
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
        let alreadyCancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.waitForBackgroundAdmission()
        }.value
        XCTAssertFalse(alreadyCancelled)
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
    }

    func testDemandCompletionIsIdempotentAndLastDemandReleasesWaiters() async throws {
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10))
        let first = coordinator.beginForegroundDemand()
        var second: ForegroundWorkCoordinator.Demand? = coordinator.beginForegroundDemand()
        let task = Task { await coordinator.waitForBackgroundAdmission() }
        defer { task.cancel(); first.finish(); second?.finish() }
        try await boundary { coordinator.waitingCountForTesting == 1 }
        first.finish()
        first.finish()
        XCTAssertEqual(coordinator.foregroundDemandCountForTesting, 1)
        XCTAssertEqual(coordinator.waitingCountForTesting, 1)
        XCTAssertNotNil(second)
        second = nil // Deinit retires a forgotten demand exactly once.
        let admitted = await task.value
        XCTAssertTrue(admitted)
        XCTAssertEqual(coordinator.foregroundDemandCountForTesting, 0)
    }

    func testSustainedInteractionAndForegroundDemandCannotStarveBackground() async throws {
        let coordinator = ForegroundWorkCoordinator(quietInterval: .seconds(10), maximumDeferral: .milliseconds(80))
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let pulse = Task {
            while !Task.isCancelled {
                coordinator.noteInteraction()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { pulse.cancel() }
        let admitted = await coordinator.waitForBackgroundAdmission()
        XCTAssertTrue(admitted, "the per-admission deadline must survive ongoing interaction")
        XCTAssertEqual(coordinator.foregroundDemandCountForTesting, 1)
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
    }

    func testWaiterStorageIsBoundedAndOverflowBypassesOnlyTheHint() async throws {
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(10), waitingLimit: 2)
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        let first = Task { await coordinator.waitForBackgroundAdmission() }
        let second = Task { await coordinator.waitForBackgroundAdmission() }
        defer { first.cancel(); second.cancel() }
        try await boundary { coordinator.waitingCountForTesting == 2 }
        let overflow = await coordinator.waitForBackgroundAdmission()
        XCTAssertTrue(overflow, "overload must not drop required callers or retain an unbounded backlog")
        XCTAssertEqual(coordinator.waitingCountForTesting, 2)
        first.cancel()
        second.cancel()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [false, false])
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
    }

    func testCancellationRegistrationRacesLeaveNoRetainedWaiters() async {
        let coordinator = ForegroundWorkCoordinator(maximumDeferral: .seconds(1), waitingLimit: 8)
        let demand = coordinator.beginForegroundDemand()
        defer { demand.finish() }
        for _ in 0..<100 {
            let task = Task { await coordinator.waitForBackgroundAdmission() }
            task.cancel()
            let admitted = await task.value
            XCTAssertFalse(admitted)
        }
        XCTAssertEqual(coordinator.waitingCountForTesting, 0)
    }

    private func boundary(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "admission did not reach the expected boundary")
        if !condition() { throw ForegroundAdmissionTestError.boundaryTimeout }
    }
}

private enum ForegroundAdmissionTestError: Error { case boundaryTimeout }
