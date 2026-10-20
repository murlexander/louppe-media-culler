# Louppe 1.12.0 (14) release — 21 October 2026

Alex authorized an independent review of all accumulated changes and release
when quality gates pass, including fixes, commits, tags and publication.
Version/build stay 1.12.0 (14) for this release cycle.

Review baseline: published v1.11.0 (`51225b9`), with current managed `main`
at `429839b`. The intervening committed changes are release/distribution records;
all accumulated tracked and new source, tests and fixtures were included.

## Independent review

Three separate reviewers inspected keyboard/menu/settings ownership, media/Fuji/
filter/scroll lifecycles, and folder persistence/rename safety. No release-blocking
correctness defect was substantiated. The integrated review fixed toolbar hints
that advertised view/media-scoped aliases outside their active context. A focused
regression exercises actual hint output and matching routes across Gallery/Grid
and photo/video contexts. Stale fixed-date documentation now matches preferred
Mac dates and sanitization; capture-time and extension bytes are unchanged.

Folder save-before-switch, operation/recovery/termination gates, revision-bound
preview publication, bounded metadata parsing and queues, exact rename family/
collision/ACR checks, journaling and undo remain intact. Broader EXIF filtering
and Maps stay deferred.

## Verification

The initial full run passes 854 cases: 818 passed, 36 explicit skips, zero
failures. The final integrated source passes **855 cases: 821 passed, 34 explicit
skips, zero failures**, with the real Fuji manifest and real RAW checks enabled.
All 41 HotkeyTests and all Browser/Grid/scroll-bridge installation gates pass.

- Performance/file-safety runner: 75/75, including disposable Trash/restore.
- Standalone scrollbar checks: 10/10; real video/media runner passes.
- Strict Swift 6 complete-concurrency/warnings-as-errors build passes.
- Localization source coverage: 2,118 literal calls, zero missing/unsupported.
- Redacted local credential scan passes for history and staged release files.
- Case-sensitive APFS image acceptance: eight passed, three explicit context
  skips. A separate actual detach/offline-save/remount/reopen test passes,
  preserving bytes and the newest rating; the disposable image was detached.
- ExFAT creation failed on this host with Operation not permitted using both
  default and explicit MBR layouts. Those checks remain unavailable, not passes.

One final-test compile attempt inherited the CLT SDK from Python's launcher and
could not find SwiftUI macros. Explicit full-Xcode DEVELOPER_DIR plus SDKROOT
resolved it without source changes or an older SDK. The successful final log is
`/private/tmp/Louppe-1.12-release-final-tests-xcode.log`.

The 34 final-suite skips were inspected individually: 19 optimized speed cases
run separately; ten volume cases need an explicit filesystem/coordinator (seven
then pass on case-sensitive APFS and the remount case passes separately; ExFAT
source/destination contexts remain unavailable); one optional decoder benchmark;
one two-display transition; and three in-process SwiftUI accessibility-host
checks. Native interaction evidence does not turn those hosted checks into passes.
The complete optimized run passes 19/19 tests with no skips: 225 workloads in
18 reports, one warmup and seven samples each, including a copied real camera
RAF with identity/hash checks. Current 100k camera-sort median is 756.056 ms
(p95 763.720 ms); navigation of 100 steps is 4.834 ms. These are current warm-cache
measurements, not a whole-app speedup claim. Results:
`/private/tmp/Louppe-1.12-release-speed-f70q7p8d`.

All correctness/release-source gates are accepted with the stated nonblocking
hardware/host limits. Signing and public-artifact checks follow when complete.

## Acceptance limits

The physical rename drag still cannot be delivered: CUA returns
`noWindowsAvailable` before input, even with a foreground readable sheet.
Accessible/context-menu ordering and the common pure reorder operation are
verified in the existing review record. This is an interaction coverage limit,
not a proven mutation defect; exact confirmation and journal gates are unchanged.

Physical Dock dragging, ISO/JIS/dead-key/IME input, full VoiceOver, older macOS,
sandbox grants, real X-T4 simulation brackets and removable/network timing remain
unverified in their dedicated environments. Folder URL validation includes one
synchronous directory-metadata query; stalled-volume UI latency is not measured.
No claim of a hard process CPU/memory cap or sustained energy acceptance is made.
Large-folder sort/projection remains AUD-06; tiny modern-format fixtures establish
supported decode routes, not large-image speed or older-OS decoder availability.
