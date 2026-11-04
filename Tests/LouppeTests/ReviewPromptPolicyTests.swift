#if APP_STORE
import XCTest
@testable import Louppe

@MainActor
final class ReviewPromptPolicyTests: XCTestCase {
    private let firstDay = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testRequiresThreeSuccessfulCopiesAndTwoDifferentCalendarDays() {
        var policy = ReviewPromptPolicy()
        XCTAssertFalse(record(&policy, day: 0))
        XCTAssertFalse(record(&policy, day: 1))
        XCTAssertTrue(record(&policy, day: 1))
        XCTAssertEqual(policy.successfulCopies, 3)
        XCTAssertEqual(policy.successfulCopyDays.count, 2)
    }

    func testAnyNumberOfCopiesOnOneDayIsInsufficientAndCountersStayBounded() {
        var policy = ReviewPromptPolicy()
        for _ in 0..<20 { XCTAssertFalse(record(&policy, day: 0)) }
        XCTAssertEqual(policy.successfulCopies, 3)
        XCTAssertEqual(policy.successfulCopyDays.count, 1)
        XCTAssertTrue(record(&policy, day: 1))
        XCTAssertTrue(record(&policy, day: 2))
        XCTAssertEqual(policy.successfulCopies, 3)
        XCTAssertEqual(policy.successfulCopyDays.count, 2)
    }

    func testCalendarDayBoundaryCountsWithoutWaitingTwentyFourHours() {
        var policy = ReviewPromptPolicy()
        let midnight = calendar.startOfDay(for: firstDay)
        XCTAssertFalse(policy.record(outcome(), version: "1.13.0", date: midnight.addingTimeInterval(-60), calendar: calendar))
        XCTAssertFalse(policy.record(outcome(), version: "1.13.0", date: midnight.addingTimeInterval(-30), calendar: calendar))
        XCTAssertTrue(policy.record(outcome(), version: "1.13.0", date: midnight, calendar: calendar))
    }

    func testRequestAttemptSuppressesTheRestOfThatVersionEvenIfAppleShowsNothing() {
        var policy = eligiblePolicy()
        policy.lastRequestedVersion = "1.13.0"
        XCTAssertFalse(policy.isEligible(version: "1.13.0"))
        XCTAssertFalse(record(&policy, day: 2))
        XCTAssertEqual(policy.lastRequestedVersion, "1.13.0")
    }

    func testNewVersionStartsFreshProgressAndCanBecomeEligibleAgain() {
        var policy = eligiblePolicy()
        policy.lastRequestedVersion = "1.13.0"
        XCTAssertFalse(policy.isEligible(version: "1.14.0"))
        XCTAssertFalse(record(&policy, day: 2, version: "1.14.0"))
        XCTAssertEqual(policy.successfulCopies, 1)
        XCTAssertEqual(policy.successfulCopyDays.count, 1)
        XCTAssertFalse(record(&policy, day: 2, version: "1.14.0"))
        XCTAssertTrue(record(&policy, day: 3, version: "1.14.0"))
    }

    func testEmptyFailedPartialCancelledMoveAndMetadataResultsNeverCount() {
        let results = [
            outcome(files: 0),
            outcome(failedPhotos: 1),
            outcome(inconsistentPhotos: 1),
            outcome(cancelled: true),
            outcome(journalFailure: true),
            outcome(recoveryRequired: true),
            outcome(failureMessage: "Copy failed"),
            outcome(mode: .move),
            outcome(mode: .metadataXMP)
        ]
        for result in results {
            var policy = eligiblePolicy()
            let before = policy
            XCTAssertFalse(policy.record(result, version: "1.14.0", date: firstDay, calendar: calendar))
            XCTAssertEqual(policy, before, "Invalid completions must neither count nor reset progress")
        }
        var policy = ReviewPromptPolicy()
        XCTAssertFalse(policy.record(outcome(), version: "", date: firstDay))
        XCTAssertEqual(policy, ReviewPromptPolicy())
    }

    func testXMPProblemsPreventAnOtherwiseSuccessfulCopyFromCounting() {
        let clean = ExportWorker.XMPResultSummary(plan:
            XMPExportPreparedPlan(selectedItemCount: 1, physicalFileCount: 1, families: []))
        for problem in [\ExportWorker.XMPResultSummary.unsupported, \.skipped, \.conflicts, \.failed] {
            var summary = clean
            summary[keyPath: problem] = 1
            var policy = ReviewPromptPolicy()
            XCTAssertFalse(policy.record(outcome(xmpSummary: summary), version: "1.13.0", date: firstDay))
            XCTAssertEqual(policy.successfulCopies, 0)
        }
    }

    func testProgressAndRequestAttemptSurviveCoordinatorRecreationInLocalDefaults() throws {
        let domain = "ReviewPromptPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let prompt = AppStoreReviewPrompt(defaults: defaults)
        prompt.recordCompletion(outcome(), version: "1.13.0", date: firstDay)
        prompt.recordCompletion(outcome(), version: "1.13.0", date: firstDay)
        let recreated = AppStoreReviewPrompt(defaults: defaults)
        XCTAssertEqual(recreated.policy.successfulCopies, 2)
        recreated.recordCompletion(outcome(), version: "1.13.0", date: firstDay.addingTimeInterval(86_400))
        XCTAssertTrue(recreated.policy.isEligible(version: "1.13.0"))
        defaults.set("1.13.0", forKey: AppStoreReviewPrompt.Keys.lastRequestedVersion)
        XCTAssertFalse(AppStoreReviewPrompt(defaults: defaults).policy.isEligible(version: "1.13.0"))
    }

    private func eligiblePolicy() -> ReviewPromptPolicy {
        var policy = ReviewPromptPolicy()
        _ = record(&policy, day: 0)
        _ = record(&policy, day: 0)
        _ = record(&policy, day: 1)
        return policy
    }

    private func record(_ policy: inout ReviewPromptPolicy, day: Double, version: String = "1.13.0") -> Bool {
        policy.record(outcome(), version: version, date: firstDay.addingTimeInterval(day * 86_400), calendar: calendar)
    }

    private func outcome(
        mode: ExportMode = .copy, files: Int = 1,
        failedPhotos: Int = 0, inconsistentPhotos: Int = 0,
        cancelled: Bool = false, journalFailure: Bool = false,
        recoveryRequired: Bool = false, failureMessage: String? = nil,
        xmpSummary: ExportWorker.XMPResultSummary? = nil
    ) -> ExportManager.Outcome {
        let destination = URL(fileURLWithPath: "/private/tmp/rating-policy-destination")
        return ExportManager.Outcome(
            mode: mode, files: files, failedPhotos: failedPhotos,
            inconsistentPhotos: inconsistentPhotos, cancelled: cancelled,
            cancellationReason: cancelled ? .userConfirmed : nil,
            journalFailure: journalFailure, recoveryRequired: recoveryRequired,
            failureMessage: failureMessage, destination: destination,
            destinations: [destination], xmpSummary: xmpSummary
        )
    }
}
#endif
