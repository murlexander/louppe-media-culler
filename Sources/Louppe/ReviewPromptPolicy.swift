#if APP_STORE
import Foundation

/// Local, bounded progress for the current marketing version. A request is an
/// attempt: StoreKit does not tell us whether Apple displayed its prompt.
struct ReviewPromptPolicy: Equatable {
    var version = ""
    var successfulCopies = 0
    var successfulCopyDays: [Date] = []
    var lastRequestedVersion: String?

    mutating func record(
        _ outcome: ExportManager.Outcome,
        version: String,
        date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard !version.isEmpty, outcome.mode == .copy, outcome.files > 0,
              outcome.isClean, outcome.failureMessage == nil else { return false }
        if self.version != version {
            self.version = version
            successfulCopies = 0
            successfulCopyDays = []
        }
        successfulCopies = min(successfulCopies + 1, 3)
        if successfulCopyDays.count < 2,
           !successfulCopyDays.contains(where: { calendar.isDate($0, inSameDayAs: date) }) {
            successfulCopyDays.append(calendar.startOfDay(for: date))
        }
        return isEligible(version: version)
    }

    func isEligible(version: String) -> Bool {
        !version.isEmpty && self.version == version
            && lastRequestedVersion != version
            && successfulCopies >= 3 && successfulCopyDays.count >= 2
    }
}
#endif
