# UI feedback — 13 October 2026

Get started now opens the existing Help window from its own Louppe Help section
in Settings, separate from Capture bursts. Settings retains the tips preference;
Help retains the guide without another preference control. Filter disclosure
buttons own their vertical padding instead of leaving stack spacing outside the
hit target. Expanded child controls remain independent.

- Focused tests: 47 executed, 45 passed, two explicit hosted accessibility skips,
  zero failures. Includes 35 HotkeyTests, four numeric-filter checks and four
  native Filter hit tests. Native mouse events verify Help routing and the tips
  preference in both directions even when the host accessibility tree is empty.
- Filter tests click all four padded corners in LTR/RTL, both sides of a divider,
  an expanded child control, and the top padding of the actual Filter popover.
  The real popover expands without changing predicates.
- Required performance/file-safety checks: 75/75, including disposable Trash and
  restore. No performance-engine code changed in this UI follow-up.
- Cached NSHostingView renders were inspected for Settings, Help and collapsed /
  expanded Filter. These are actual mounted production views in XCTest; the
  version displayed in Settings belongs to the XCTest host. The installed app
  version and binary hash are in installed-review.json.
- Release packaging verifies both the app and archive. A review-marked archive
  is independently extracted and signed-content equality is checked against the
  staged and installed app. Earlier app and packaging copies are moved to Trash.
- The existing 34-file review fixture is reused. Media bytes and existing saved
  decisions are checked before and after replacement; preferences keep the same
  bundle identity. No version bump, commit or push.

See focused-tests.log, safety-checks.log, release-build.log, source-and-test-sha256.json,
and installed-review.json for exact evidence. The earlier 714-test full-suite
baseline remains applicable to unchanged core source; this update changes three
UI views and their interaction tests.

The final inventory also records published 1.10 reference/capture copies used by
the newer, separately authorized App Store media chat. They are preserved to
avoid disrupting that production work; only one 1.11 review app remains.
