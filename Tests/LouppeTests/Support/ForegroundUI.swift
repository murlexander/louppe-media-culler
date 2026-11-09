import Foundation
import XCTest

/// Tests that order windows front or activate the app run only when LOUPPE_FOREGROUND_UI=1
/// (Scripts/test.sh --foreground, or CI), so a default run never takes the user's focus.
func requireForegroundUI() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["LOUPPE_FOREGROUND_UI"] == "1",
                      "Raises windows; run with Scripts/test.sh --foreground while the desktop is handed over.")
}
