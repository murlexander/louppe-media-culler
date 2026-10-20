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

The final CI run at `b86dc26` passes 856 cases: 818 passed, 38 explicit skips,
zero failures. Run: https://github.com/murlexander/louppe-media-culler/actions/runs/39508338837.
An initial runner failure exposed a fixture requesting a window taller than its
screen. The fixture now fits the actual display, and a separate regression checks
that Back correctly fits oversized sessions. This changes tests only. All 491
frozen packaging inputs remain byte-identical. The post-fix local installation
gates pass 68 cases: 67 passed, one two-display skip, zero failures.

## Signed artifacts

The final direct archive has 7,414,266 bytes; SHA-256:
`2cd47cf21aaceeb0919b306a9b14093cb9f1ab1283dc932cc29d57eb3396c99e`.
Apple notarization accepted request `734a3341-d193-4d47-a91c-799838b369b0`.
Stapling, Gatekeeper, strict deep signatures, complete loose/archive Contents
comparison, Sparkle signatures and publishing preflight pass.

The Apple Distribution/installer-signed Store package has 6,317,190 bytes;
SHA-256: `f47ced4d0ce66cbd7694f10b28530820b2814c04e0411c4184da9bd3ca1a9ef5`.
Expanded installer payload and signing checks pass. Artifacts and validation
logs are retained in ignored `dist/release-preparation/1.12.0-14-2026-10-21/`.

The sandbox-entitled Store executable opened four disposable real Fuji copies
through its picker, saved a Yes decision, switched folders safely, and reopened
Recent with that decision intact. Accessible ordering changed the rename preview;
confirmed renaming changed both JPEG/RAF names, and journaled Undo restored them.
All four original content hashes remained unchanged after both operations.

## Publication and installed app

[GitHub v1.12.0](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.12.0)
is published after Alex explicitly confirmed publication. Its tag points to
`b86dc26`. The downloaded public archive matches the exact ZIP hash/length above;
the public signed feed matches generated bytes and both Sparkle signatures verify.
Homebrew workflow [39510520815](https://github.com/murlexander/louppe-media-culler/actions/runs/39510520815)
passes and commits the matching version/checksum. All six website language pages
serve their GitHub download links, and latest-download resolves to 1.12.0.

A real Sparkle installer upgrades an isolated copy of the exact public 1.11.0 (13)
to 1.12.0 (14). It downloads the public archive, verifies/extracts and installs
without terminating or relaunching an app. Its complete updated Contents tree
matches the release; strict signatures, Gatekeeper and stapling pass. Evidence:
`/private/tmp/Louppe-1.12-public-update.log` and
`/private/tmp/Louppe-1.12-public-update-result.json`.

The single `/Applications/Louppe.app` was replaced with the same archive after
all mandatory installation gates passed. Complete Contents comparison, strict
signatures, Gatekeeper and stapling pass. Previous copy:
`/private/tmp/Louppe-shortcut-settings-h7cdwspa/previous-Louppe.app`.
Native launch shows the Welcome screen with retained recent folders. Preferences
and folder grants were not reset. Final media-folder and physical horizontal
scroll checks could not finish: native capture returned blank/partial images and
ScreenCaptureKit errors. Earlier sandbox media acceptance and automated native
scroll input tests remain the available evidence; this is an explicit coverage
limit, not an additional pass.

The Store package was delivered through Transporter with Alex completing Deliver
because native capture was unreliable. Build 1.12.0 (14) was selected, export
compliance completed for Apple-system-only cryptography, and submitted. App Store
Connect confirms **Waiting for Review**. Automatic release after approval and
existing ratings/media remain selected. All six translated What's New texts were
saved and read back after reload; the existing sample-media.zip is attached.
Apple's review is pending, not a publication pass. Receipt and exact artifacts
are retained under the preparation directory.

## Acceptance limits

The physical rename drag still cannot be delivered: CUA returns
`noWindowsAvailable` before input, even with a foreground readable sheet.
Accessible/context-menu ordering and the common pure reorder operation are
verified in the existing review record. This is an interaction coverage limit,
not a proven mutation defect; exact confirmation and journal gates are unchanged.

Physical Dock dragging, ISO/JIS/dead-key/IME input, full VoiceOver, older macOS,
stale/revoked sandbox grants, real X-T4 simulation brackets and removable/network timing remain
unverified in their dedicated environments. Folder URL validation includes one
synchronous directory-metadata query; stalled-volume UI latency is not measured.
No claim of a hard process CPU/memory cap or sustained energy acceptance is made.
Large-folder sort/projection remains AUD-06; tiny modern-format fixtures establish
supported decode routes, not large-image speed or older-OS decoder availability.
