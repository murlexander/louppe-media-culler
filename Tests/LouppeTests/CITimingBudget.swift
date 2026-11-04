import Foundation

/// Wall-clock budgets stay strict locally. Shared hosted CI runners (which set
/// `CI`) can be several times slower, so only there a budget is multiplied.
enum CITimingBudget {
    static let isCI = ProcessInfo.processInfo.environment["CI"] != nil

    static func scaled(_ budget: Duration, onCI factor: Int) -> Duration {
        isCI ? budget * factor : budget
    }

    static func scaled(_ seconds: TimeInterval, onCI factor: Double) -> TimeInterval {
        isCI ? seconds * factor : seconds
    }
}
