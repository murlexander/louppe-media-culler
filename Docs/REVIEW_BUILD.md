# Local review builds

Build a separate review copy with full Xcode and the current SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_review.sh
open "dist/louppe - to review.app" --args -openFolder /path/to/disposable/photos
```

The script creates `dist/louppe - to review.app` and its ZIP, using the version
in `VERSION`. Its identifier is `com.alexandermarkin.louppe.review2`; preferences,
recents, and window state are separate from the stable app. Automatic updates
are disabled, and the review copy does not advertise a duplicate Finder service.

Both apps use `.louppe_session.json`. Opening the same folder shares decisions;
use disposable copies of media. 1.11 saves format 7, which 1.10 cannot read.
Keep saved-session copies before evaluating a downgrade.

Run the affected tests and the checks in [AGENTS.md](../AGENTS.md). Record the
source revision, build identity, fixtures, results, explicit skips, and native
acceptance limits. Always launch with `-openFolder`.

## Latest recorded review

15 October preparation: 755 XCTest tests executed, 719 passed, 36 explicit
skips, and zero failures; all 35 HotkeyTests and 75 safety checks pass. A freshly
signed direct candidate opened generated disposable media and saved a decision
without changing its bytes. This did not install or replace the review app.
See [current preparation](RELEASE_1.11_PREPARATION_2026-10-15.md) for package
identity, owner acceptance, and the pending notarization approval.

## 14 October review

The 14 October 1.11 review combined the floating zoom control, Grid/Browser
bounds fixes, localization, Quality Cues, recovery, and performance work.
The full suite executed 754 tests: 718 passed, 36 explicit skips, zero failures.
All 35 HotkeyTests and 75 required performance/file-safety checks passed.
These are dated results, not validation of subsequent changes.

- [Release preparation and remaining acceptance](RELEASE_1.11_READINESS_2026-10-14.md)
- [Current open work](../BACKLOG.md)
- [Dated implementation reviews](../README.md#historical-records)
- [Complete review history](Archive/2026-10-14/REVIEW_BUILD_HISTORY.md)
- [Installed-review manifest](Archive/2026-10-14/performance/cue-filter/installed-review.json)
