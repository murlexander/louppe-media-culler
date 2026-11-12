import Foundation
import XCTest
@testable import Louppe

@MainActor
final class ExportXMPInspectionTests: XCTestCase {
    func testFailureIsNotAnEmptyInspectionAndPreservesAutomaticInclusion() {
        let state = ExportXMPInspectionState()
        state.complete(.success(.init(recognizedPacketCount: 2, excludedACRCompanionCount: 1)))
        XCTAssertTrue(state.inclusionChoice.isIncluded)
        state.begin()
        state.complete(.failure(CocoaError(.fileReadNoPermission)))
        XCTAssertEqual(state.status, .failed)
        XCTAssertNil(state.inspection, "Failure must never become a successful zero-sidecar result")
        XCTAssertTrue(state.inclusionChoice.isIncluded)
        XCTAssertFalse(state.inclusionChoice.wasManuallySet)
        state.begin()
        state.complete(.success(.init(recognizedPacketCount: 0, excludedACRCompanionCount: 0)))
        XCTAssertEqual(state.inspection?.recognizedPacketCount, 0)
        XCTAssertFalse(state.inclusionChoice.isIncluded, "Only a successful empty check changes the default")
    }

    func testFailureAndRetryPreserveManualChoice() {
        for included in [false, true] {
            let state = ExportXMPInspectionState()
            state.inclusionChoice.setManually(included)
            state.begin()
            state.complete(.failure(CocoaError(.fileReadNoPermission)))
            XCTAssertEqual(state.inclusionChoice.isIncluded, included)
            state.begin()
            state.complete(.success(.init(recognizedPacketCount: included ? 0 : 3, excludedACRCompanionCount: 0)))
            XCTAssertEqual(state.inclusionChoice.isIncluded, included)
        }
    }

    func testCancellationDoesNotShowFailureOrChangeInclusion() {
        let state = ExportXMPInspectionState()
        state.complete(.success(.init(recognizedPacketCount: 1, excludedACRCompanionCount: 0)))
        state.begin()
        state.complete(.failure(CancellationError()))
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.inspection)
        XCTAssertTrue(state.inclusionChoice.isIncluded)
    }

    func testTryAgainRunsTheInjectedInspectorAgain() async throws {
        let counter = InspectorCounter()
        let state = ExportXMPInspectionState { _, _ in
            if counter.next() == 1 { throw CocoaError(.fileReadNoPermission) }
            return .init(recognizedPacketCount: 0, excludedACRCompanionCount: 0)
        }
        state.inspect(selected: [], familyContextItems: [])
        try await wait { state.status == .failed }
        XCTAssertNil(state.inspection)
        XCTAssertEqual(counter.calls, 1)
        // This is the action passed directly to the failure row's Try Again button.
        state.retry()
        try await wait { state.inspection != nil }
        XCTAssertEqual(counter.calls, 2)
        XCTAssertEqual(state.inspection?.recognizedPacketCount, 0)
        state.cancel()
    }

    func testSupersededFailureCannotReplaceTheNewInspection() async throws {
        let counter = InspectorCounter()
        let release = DispatchSemaphore(value: 0)
        let state = ExportXMPInspectionState { _, _ in
            let call = counter.next()
            defer { counter.finish() }
            if call == 1 {
                release.wait()
                throw CocoaError(.fileReadNoPermission)
            }
            return .init(recognizedPacketCount: 2, excludedACRCompanionCount: 0)
        }
        defer { release.signal(); state.cancel() }
        state.inspect(selected: [], familyContextItems: [])
        try await wait { counter.calls == 1 }
        state.inspect(selected: [], familyContextItems: [])
        try await wait { state.inspection?.recognizedPacketCount == 2 }
        release.signal()
        try await wait { counter.finished == 2 }
        await Task.yield()
        XCTAssertEqual(state.inspection?.recognizedPacketCount, 2)
        XCTAssertTrue(state.inclusionChoice.isIncluded)
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private final class InspectorCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var completed = 0
        var finished: Int { lock.withLock { completed } }
        func finish() { lock.withLock { completed += 1 } }
        var calls: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
}
