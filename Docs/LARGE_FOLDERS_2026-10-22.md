# Large-folder handling — 22 October 2026

Implemented and installed locally as **1.13.0 (15)**. This record owns the
implementation acceptance for the large-folder work in [BACKLOG.md](../BACKLOG.md).
Warm local measurements and regression checks are complete. RAW stress failures,
representative storage acceptance and specific physical UI checks remain open.

## Scope and baseline

- Starting commit: `87370f6`, clean `main`, equal to `origin/main` after fetch.
- Keep 1.13.0 (15); that release cycle is already open.
- Improve first usable review and foreground responsiveness for large folders.
  Measure discovery, identity, pairing, metadata, saved decisions, projection,
  and mounted first layout separately before choosing staged loading.
- Preserve complete physical membership, saved decisions/recovery, exact source
  identity, selection/current photo, stable geometry, bounded media work,
  cancellation, and the existing vertical-only scroll contracts.
- No commits, pushes, release publication, or unrelated backlog work requested.

## Acceptance

- [x] Record optimized before/after scan, projection, navigation and media timings.
- [x] Exercise 1k/10k disposable JPEG files and actual camera RAW+JPEG clones;
      distinguish one cloned RAW from independent camera captures.
- [ ] Complete representative varied RAW/mixed and cold/warm SD-card acceptance.
- [x] Show useful content earlier if staging proves beneficial; hold incomplete
      sort/filter data stable and protect unread decisions from saves/mutations.
- [x] Reject replaced files, incomplete traversal, cancelled scans, stale results,
      and old-folder publications. Preserve sidecars on failure/cancellation.
- [x] Keep current/selection, tile identity, geometry, and scroll anchor coherent
      during load, rapid navigation, reverse scroll, jumps, resize and view changes.
- [x] Measure mounted input/result latency, first useful thumbnail, readiness,
      and memory; separate cache hits, filesystem warmth and source reads.
- [x] Run focused contracts, full XCTest, 75 safety checks, and required hotkey/
      Browser/Grid/scroller gates. Build and launch the integrated app.
- [x] Inspect the installed native Grid/Browser and report hardware/tooling gaps.
- [ ] Complete physical diagonal/momentum and Welcome edge-drag acceptance.

## Work ownership

One implementation owner per shared file. Initial independent investigations:
scan/persistence, prepared projection, and mounted browsing/media. The parent
owns integrated scope, benchmark runs, build/install/native interaction and this
record. Delegated runs use GPT-6.1 Sol with high reasoning. Builds and native
interaction are serialized.

## Evidence and limits

Initial optimized run: `/private/tmp/louppe-large-before-20261022`, three measured
samples after one warmup, 1k/10k/100k synthetic models and generated JPEG workloads.
Final evidence is retained under `Docs/Archive/2026-10-22/performance/large-folders/`.

Native capture initially failed with ScreenCaptureKit error `-3811`. Later native
launcher activation restored full-size captures; earlier thumbnail/incomplete AX
observations are not treated as rendering failures. Mounted volumes are Macintosh
HD and Recovery; no SD card is available. Cold/warm removable-media acceptance
remains open. Do not call warm local filesystem measurements cold storage.

## Implemented behavior

- Complete discovery and global RAW+JPEG pairing precede every opening preview.
  Saved decisions and recovery authority are read/restored before badges appear.
  Conflicts, legacy confirmation, unavailable save access and same-folder rescans
  keep the existing full-opening path.
- A separate read-only Gallery/Grid mounts during metadata loading. The main
  store stays scanning with empty authoritative items. Navigation, selection and
  fitted photo previews work; ratings, file actions, filters, playback and 100%
  inspection wait for full validation. Pending nonphoto capabilities stay pending.
- Metadata uses up to eight fixed workers and deterministic result slots. No
  metadata batch reshuffles the inventory. One final validated projection becomes
  Ready, carrying current/selection by physical identity and the browsed viewport
  independently. A one-shot receipt is consumed after native restoration; later
  navigation expires unused receipts for dormant modes too.
  Automatic preview positioning does not choose the final current photo or
  viewport: untouched opening uses the requested final sort. Native user scrolling
  and explicit selection/navigation carry their separate choices into Ready.
- Browser/Grid use one indexed native document, viewport cells plus one row of
  overscan, and a bounded pool of empty reusable SwiftUI hosts. Distant following
  resolves its target directly. Caption/header geometry uses the visible SwiftUI
  templates. Native gutter, scroller, X pin, controls, RTL and lifecycle remain.
  Immutable projections survive identical-input SwiftUI reevaluations.
- Camera/lens sorts reuse distinct-value ranks with canonical ties and nil-last
  behavior. Unrestricted and unchanged projections avoid repeated work. Rating
  under a decision sort still has collection-wide costs; no constant-time claim.
- Neighbor prefetch has replaceable cancellation ownership. Coalesced foreground
  interests survive; executing native work keeps its lane/access until exit.
  Same-revision thumbnails retain pixels after NSCache eviction. Optional disk
  writes coalesce and cap retained work at 8 MiB/32 entries, active write included.
- Compact Welcome sizing is included in the same 1.13 cycle, preserving the
  chosen review frame and honoring an explicit native edge drag.

## Validation log

- Initial logic/media/layout/pairing/order run: 78 tests, one two-display skip,
  zero failures. Only one display is available.
- Staged authority, media-access and restoration contracts passed in focused
  runs. Initial Browser invalidation failure exposed identical-input SwiftUI
  reconstruction; persistent immutable projection caching fixed actual O(N) work.
- Final integrated interaction gate: **66 tests passed, zero failures**. Includes
  complete Hotkey, BrowserScroll, GridScroll, PersistentVerticalScroller, controls,
  selection, ViewSwitch, native collection, projection and viewport handoff tests.
- Complete final debug suite: **913 tests, 42 documented skips, zero failures**.
  The first full run found a missing brand/catalog distinction and a provisional
  current photo overriding the saved default sort; both were fixed. New contracts
  distinguish automatic positioning, user scrolling and explicit current choices.
  Focused intent/localization/preferences/handoff rerun: 49 tests, zero failures.
- **75/75 safety checks passed.** A new Swift concurrency capture warning in the
  preview delivery closure was then removed without changing its generation gates.
- Independent source reviews covered media ownership, opening/restoration,
  projection semantics, staged mutation isolation/access lifetime, and native
  collection integration. The native review found dormant handoff receipts could
  override later navigation; the fix and mounted cross-mode regression are included.
- A stalled synthetic wheel run was stopped and sampled. The custom document now
  explicitly opts out of responsive scrolling because main-thread host realization
  does not promise AppKit worker overdraw coverage. The isolated wheel test and
  complete scroll gate subsequently passed; no input assertion was weakened.

Final safety rerun: **75/75 passed**. Packaging passed release preflight for
1.13.0 (15), including loose/archive verification. The installed app passes strict
deep signature verification; all 178 Contents entries match the build by file
bytes, executable modes and symlink targets. Finder metadata reappeared in the
File Provider-managed dist bundle after packaging; copying without extended
attributes and cleaning the installed bundle resolved its verification failure.

Installation used a reversible move of the previous bundle to a temporary local
rollback folder, after a command containing `rm -rf` was automatically rejected.
Only `/Applications/Louppe.app` is installed. No version bump, commit, push or
release publication was added.

## Final measured results

One warmup, three measured samples; release optimization with DEBUG test seams.
Values below are medians on warm local storage. Pixel barriers require visible
matching-revision image state, not only cache availability or a render marker.
They are not physical display-frame measurements.

| Workload | Original | Current |
| --- | ---: | ---: |
| 10k Grid tail, input to matching pixels | 961.420 ms | 55.991 ms |
| 10k Browser tail, input to matching pixels | 611.240 ms | 11.786 ms |
| 10k JPEG first useful pixels | 1,535.515 ms | 1,309.845 ms |
| 10k RAW+JPEG pairs, first useful pixels | 6,729.332 ms | 2,967.319 ms |
| 10k JPEG full readiness | 1,535.523 ms | 2,023.297 ms |
| 10k RAW+JPEG pairs, full readiness | 6,729.340 ms | 8,173.880 ms |
| 100k camera sort, full store | 685.891 ms | 122.237 ms |
| 100k decision filter and groups | 89.995 ms | 28.108 ms |
| 100k rating under decision sort | 120.768 ms | 115.283 ms |
| 1k JPEG synchronous scanner | 66.071 ms | 85.206 ms |

Separate is the fresh-session default: 10k RAW+JPEG pairs are 20k displayed
physical files. Those RAWs are APFS clones of one disposable copy of a camera RAF.
The original's digest and physical identity remained unchanged. Full readiness
and the synchronous scanner became slower despite earlier content and much faster
distant navigation. This is not a blanket scanning speedup. The readiness tradeoff
and remaining collection-wide decision-sort/save work need further profiling.

Fresh-process mounted 10k peak RSS fell from 526.6 to 340.8 MiB in Grid and 589.9
to 342.7 MiB in Browser; after surface teardown/disk drain, 521.7 to 333.6 MiB.
Current realized/retained hosts were Grid 20/35 and Browser 8/9. These are process
measurements, including runtime and caches. They do not isolate cache-owned pixels.
Maximum scheduling gaps under contiguous benchmark cycles remained 916 ms in Grid
and 399 ms in Browser; opening poll-gap median maxima were 304 ms at 10k JPEG and
384 ms at 20k RAW+JPEG. Native window/layout work and harness scheduling are included.
Do not infer smooth physical frames or constant-time mutations from these samples.

Under production cue/hash/save activity with an explicitly injected 30 ms hash
delay, 10k median input-to-thumbnail was 71.227 ms in Grid and 26.126 ms in Gallery.
This is a contention measurement, not a comparison or an SD-card simulation.

The combined optimized runner completed ten tests before crashing during later
RAW stage profiling. The six-test isolated JPEG/opening/scan/session run and the
matching original mounted rerun passed. Failed runners are retained separately;
their completion is never counted as a pass. See the
[full comparison and raw samples](Archive/2026-10-22/performance/large-folders/comparison.md).

## Installed native inspection

- Cold launch to Welcome and cold `-openFolder` launch to the generated 1k folder
  succeeded. Native recent-folder opening also loaded the 10k folder, with a Saved
  status and unchanged zero reviewed count.
- Browser/Grid showed the intended generated pixels with Info visible. Native
  horizontal inputs, vertical travel/reversal and Info toggles were exercised.
  Grid browsing moved to `FRAME_000066.JPG` while current stayed `FRAME_000000.JPG`;
  Info toggles retained that browsed position. Reverse scrolling returned to
  `FRAME_000000.JPG`. A distant Browser jump and repeated Gallery/Grid switching
  retained current `FRAME_009999.JPG`.
- Back compacted Welcome to a 912×974-pixel capture; reopening restored the
  3024×1898-pixel review capture. Real edge-drag attempts through the automation
  bridge produced no resize, so they are not a pass. The focused layout tests cover
  native live-resize notifications, late frame restoration and detached observers.
- A suspected follow drift did not reproduce after fresh control snapshots.
  Inactive Stage Manager snapshots and invalid AX control IDs made some early
  observations inconclusive; no source change was made for that suspicion.
- Physical combined diagonal/momentum input, two-display placement, varied RAW/
  mixed storage and SD-card runs remain unverified. Controlled native wheel tests
  cover diagonal/momentum/X-lock contracts; they are not a physical trackpad run.

## RAW stress limitation

Original production sources were checked against a `git archive 87370f6`; only an
inert DEBUG pixel marker differs. A resource-instrumented original opening rerun
stalled for over three minutes inside Apple ImageIO/RawCamera cache operations
during untimed fixture preparation. It was sampled and stopped; no timing or
resource result from that attempt is counted. The earlier completed original
opening run remains available. See retained artifacts for the exact distinction.

The candidate combined runner later crashed in RawCamera → `cache_release_value`
during ImageIO properties extraction, with eight independent metadata sources.
Read-only source review found no concrete ownership/concurrency defect explaining
it. The original stall and candidate crash do not establish a common root cause,
nor prove a platform defect. They prevent a general RAW reliability claim.
Next investigation: a fresh-process metadata-only reproducer comparing cloned,
byte-copied and distinct RAW files, then varying only the documented properties-call
cache option. Preserve native failures for an Apple report before changing
production concurrency. The current code and successful first-use measurements
remain unchanged; no unmeasured serialization workaround was added.
