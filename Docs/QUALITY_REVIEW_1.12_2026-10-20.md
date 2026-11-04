# 1.12 stability and performance review — 20 October 2026

Review the current 1.12.0 (14) working copy before further UI refinement.
Baseline HEAD: `429839b`; the candidate includes the existing uncommitted work.
Three independent reviews covered shortcuts/menu lifecycle, performance, and
folder/media integration. The parent owns all builds, measurements and native
interaction; shared test/build runs are serialized.

Acceptance:

- Preserve decisions and safe-save/recovery gates during folder replacement.
- Preserve shortcut migration, independent mode maps, scoped conflicts and
  native text/modal/control ownership. Keep traditional and visual editors in sync.
- Keep Fuji simulation correct for JPEG/RAF, partial metadata and malformed notes;
  preserve source bytes and bounded metadata I/O.
- Avoid unnecessary menu work during review and unrelated picker updates.
- Retain revision-bound preview loading, bounded queues/caches and idle behavior.
- Pass affected regressions, the full suite and file-safety checks; collect
  optimized repeatable speed measurements and verify the installed candidate.

## Findings

1. Partial ImageIO Fuji data could expose a color FilmMode while omitting the
   monochrome Saturation override. The reader returned the color result before
   inspecting the complete JPEG/RAF note. The fix checks the bounded container
   when Saturation is missing, retains complete numeric-tag precedence, and
   preserves numeric evidence if the container has no tags. Malformed or unknown
   notes remain Unknown. Generated JPEG/RAF regressions cover all these paths
   and unchanged file bytes.
2. The shortcut-column bridge subscribed to all menu structure notifications,
   including detached Settings/context menus, and synchronously rebuilt the main
   menu hints each time. A temporary AppKit diagnostic demonstrated redundant
   traversal; remediation and final measurements are recorded below.
3. Two plain Grid-click tests inherited live `NSEvent.modifierFlags`, so unrelated
   Command/Shift input could alter their semantics. They now pass explicit empty
   modifiers. Production pointer routing continues to read the actual modifiers.

The added background-notification regression also reproduced an actor-isolation
assertion in the menu callback. A main-thread guard alone cannot protect an
implicitly main-actor callback: the runtime asserts before its body starts.
The callback is explicitly Sendable and enters the main actor only after
rejecting background deliveries. This keeps first-open updates synchronous.

No critical production defect was substantiated by the reviews.
Folder transitions retain safe-save, XMP cancellation, recovery and operation
gates. Preview readiness remains revision-bound. Shortcut migration, conflict
checks, focus gates, resets and accessibility behavior were reviewed separately.

## Baseline evidence

The complete pre-remediation suite passed: 814 cases, 778 passed, 36 explicit
skips, zero failures. The performance/file-safety runner passed 75/75, including
disposable Trash/restore. These are baseline results, not substitutes for final
candidate validation.

The temporary menu diagnostic uses a three-submenu, roughly 80-item main menu,
one warmup and seven measured samples. Each detached-menu workload performs
1,000 add/change/remove sequences. It uses the native debug XCTest build and
is a focused mechanism measurement, not a shipping frame-rate benchmark.
Before the fix, detached work without the bridge had a 2.882 ms median; with
the bridge it took 4,074.434 ms. Warmup plus measured detached operations caused
48,000 main-menu item-array reads. Separately, 1,000 forced refreshes had a
1,331.263 ms median. Raw samples are in
`/private/tmp/Louppe-1.12-menu-before.log`.

After remediation, the same detached workload with the bridge has a 9.292 ms
median (2.848 ms without the bridge) and **zero main-menu item-array reads**.
Forced refresh cost remains comparable at 1,320.094 ms per 1,000 calls. All
eight menu regression tests plus the temporary diagnostic pass. This demonstrates
removal of redundant work; it does not imply a corresponding frame-rate gain.
Raw samples are in `/private/tmp/Louppe-1.12-menu-after.log`. The temporary
diagnostic was removed from the test target; permanent regressions assert zero
traversal for detached/background notifications, cached unrelated state changes,
live context/preference updates and synchronous late menu attachment.

## Final correctness validation

The complete integrated suite passes **817 cases: 781 passed, 36 explicit skips,
zero failures**, with the real Fuji validation manifest enabled. All HotkeyTests
are included. Generated partial-metadata regressions pass for JPEG and RAF;
the existing real-corpus validation retains its independent simulation and
source-integrity checks. The standalone real-video/media runner also passes.
All 2,084 literal localization calls are covered; `git diff --check` is clean.
Logs: `/private/tmp/Louppe-1.12-quality-final-all.log`,
`/private/tmp/Louppe-1.12-quality-video.log` and the focused menu logs above.
After the test-only actor-annotation cleanup, the full 817-case suite passes
again with the same 781/36 split and no new actor-isolation warnings. Final
performance/file-safety checks pass 75/75 on the fixed source. Logs:
`/private/tmp/Louppe-1.12-quality-final-clean-tests.log` and
`/private/tmp/Louppe-1.12-quality-final-safety.log`.

## Optimized measurements

The optimized runner passes **19/19 tests**, with **225 measured workloads** in
18 reports. Each workload has one warmup and seven measured samples. Fixtures
cover 1,000/10,000/100,000 synthetic items, generated real JPEG I/O, cache fanout,
cancellation, mounted Gallery settlement, persistence, cue work and a copied
camera RAF. RAW preview/histogram checks verify the source hash and identity.
Results: `/private/tmp/Louppe-1.12-quality-speed.AYNCxf`; console:
`/private/tmp/Louppe-1.12-quality-speed-run.log`.

Representative medians, milliseconds:

| Session work | 1,000 items | 10,000 items | 100,000 items |
| --- | ---: | ---: | ---: |
| Rate, default chronological sort | 0.032 | 0.029 | 0.026 |
| Rate, decision sort | 1.132 | 9.910 | 123.122 |
| Filter decisions and rebuild groups | 0.840 | 8.284 | 94.476 |
| Camera sort through SessionStore | 6.093 | 54.770 | 754.878 |
| Navigate 100 steps | 4.102 | 4.331 | 4.183 |

The 100k camera-sort p95 is 774.233 ms. Large-folder sort/projection remains a
follow-up under the existing performance backlog. These are current timings;
there is no comparable pre-1.12 run here to call this a new regression or an
improvement. Common 1k-folder interactions are much smaller. Navigation rows
exercise SessionStore rather than physical display frames or the app delegate;
the separate menu diagnostic covers the new bridge.

Generated 1,000-JPEG warm-filesystem scan median is 72.449 ms (p95 75.052).
Real RAW 320px fast preview is 21.690 ms; Apple Default 1024px preview is
194.263 ms; background RAW histogram is 169.679 ms. A foreground JPEG full
preview during background RAW analysis is 4.379 ms (p95 5.166). These measure
the documented pipeline workloads, with warm OS/framework caches.

The source/resource/fixture hash manifest contains 214 files, including untracked
new source omitted from ordinary `git diff`. Its SHA-256 is
`3b442ee3b7cb5b8e8f38690cd4709b42e44d75ab6b08f9f20ec9aecdb1528582`;
file: `candidate-source-sha256.json` in the results directory. A subsequent
test-only annotation cleanup removes an invalid actor-isolated NSMenu fixture
override; it changes no measured production code.
Verified production hashes remain unchanged. The final 214-file manifest is
`final-candidate-source-sha256.json`, SHA-256
`c6e17fc39b1e088e42c24156bca1c765662d748dc26342be46ceca23ff08bb89`.

## Installed candidate

Store configuration compiles with the current SDK. Release and review package
preflight pass. Installed 1.12.0 (14) archive SHA-256:
`085a17839e273f934cf9e5663ebc13b4a2ce6a6d0582339a6110f34e2f9a0272`.
The independently extracted archive and installed review app pass strict deep
signature verification and their complete Contents trees match. Previous review
copy: `/private/tmp/Louppe-keyboard-final-x05_iqu2/previous-review.app`.

The installed app launched on the disposable four-file Fuji JPEG/RAF folder;
native state shows CLASSIC Neg. in JPEG Info and all files undecided. First
opening Edit and View exposes the expected separate hints and clean action names,
including lazy items. Settings still shows the saved layout mode and working
selected-F/Mark Yes editor. No test aliases or preference changes were made in
this final native pass. Context/remapping cache changes are covered by the new
permanent AppKit tests; the prior native remapping exercise remains in the
1.12 implementation record. A transient ScreenCaptureKit launch-binding failure
was resolved by bringing the confirmed running app forward; no app crash was
observed. No commits or publication occurred.

## Remaining acceptance limits

Native dead-key/IME and ISO/JIS recording, a full VoiceOver interaction pass,
older macOS versions, sandbox folder grants, and stalled/removable/network-volume
timing still require their dedicated acceptance environments. Synthetic large
folders do not establish real SD-card latency or a hard process-memory/CPU cap.
Optimized speed tests use warm filesystem/framework caches and the existing
DEBUG test seams; small timing changes need repeated comparable runs.
