# 1.13 backlog completion — 4 November 2026

Five parallel workstreams measured and fixed the agent-runnable 1.13 items on
`main` at `5e6b2c0` (Xcode 27.2, macOS 27.2 SDK). Hardware, people and manual
acceptance stay open in the [backlog](../BACKLOG.md). Timings were taken while
other builds ran: interleaved A/B samples (≥5 each), medians, noisy host. Treat
small differences as noise.

## Verification

| Check | Result |
| --- | --- |
| Full suite, final tree, native backend | 1,300 tests, 63 skips, 0 failures |
| Required gates in that run | HotkeyTests, BrowserScrollTests, GridScrollTests, PersistentVerticalScrollerTests passed |
| `Tests/run_performance_checks.sh` | 75/75, including the Trash round trip |
| `build_app.sh` + release preflight | Passed for 1.13.0 (15); not installed |
| Review | Independent council review; its four blocking findings were fixed before the final run |
| Not run | Window-raising suites (ConnectedDrives, FilterDisclosureHit, MountedLargeListInvalidation, NumericFilterDraft, StagedViewportHandoff, ViewSwitch, ZoomTransition) while Alex was using the Mac |

## Export (AUD-12, AUD-14, AUD-03 routing)

Routing preview, offscreen 640 × 620 window, old layout vs lazy rows:

| Preview | Open | 20 scroll steps | Rows realized |
| --- | --- | --- | --- |
| One route, 10k files | 3,093 → 18 ms | 1,313 → 223 ms | 10,000 → 454 |
| 10k unmatched | 3,918 → 24 ms | 1,262 → 283 ms | 10,001 → 508 |
| Both, 10k each | 3,235 → 19 ms | 8,111 → 251 ms | 20,000 → 493 |

Destination preflight, main actor blocked (old → new): Copy 10k 16.8 → 7.9 ms;
Move 10k 120 → 7.7 ms; Copy with an injected 750 ms volume delay 769 → 0.8 ms.
The remaining ~8 ms at 10k is the existing Photos-media scan. Move queries one
volume per physical source. Unmatched rows are now keyed by position, so
same-named items in different folders no longer share an ID.

Tests: `ExportPreflightTests`, `ExportRoutingPreviewTests` (measurement opt-in),
validator cancellation. Routed Review → Back → Review → Copy after cancelled,
refused and stopped attempts keeps every folder-access start matched by a stop.
Open: a real slow destination, the signed sandbox build, VoiceOver on the lazy list.

## Review projection and Undo (AUD-06, AUD-17)

| Workload, 100k items unless stated | Before | After |
| --- | ---: | ---: |
| Rating, decision sort, grouped | 168 ms | 29 ms |
| Star change under star sort | 166 ms | 28.5 ms |
| Select All → decision, decision sort | 1,295 ms | 363 ms |
| Clearing a cue filter, decision sort | 135 ms | 4 ms |
| Undo of one whole-folder step | 2,101 ms | 368 ms |
| Recovery of 5k files, decision sort | 28,475 ms | 372 ms |
| Recovery of 1k files, decision sort | 1,303 ms | 80 ms |

Unchanged by measurement: default-sort rating (0.03 ms), save capture (29 ms for
200k files), camera sort (95–100 ms), navigation. Causes: recovery copied the
whole recovery history per file and re-projected the session per file; batch
edits re-read the item list per file; grouped metadata sorts re-read buckets.

Undo costs 72 bytes per changed file; a whole-folder step at 100k pairs is
13.7 MiB, so 500 steps could reach ~6.7 GiB. Decision, star and color Undo now
stays within 256 MiB, a limit Alex approved on 4 November. Single-photo edits
still keep 500 steps. Very large edits keep fewer: about 18 whole-folder edits at
100k RAW+JPEG pairs. When the limit is reached, the oldest of these steps are
dropped first and the newest is always kept. Clean Up, Organize and Rename steps
are never dropped for memory; they follow only the 500-step limit. 10k photos ×
500 whole-folder steps: 687 → 255 MiB retained.

Saved-decision recovery applies verified results in batches: each batch applies
decisions, counts and one sort/filter pass in the same main-actor turn, at most
once per interval (at least 100 ms, up to 1 s by cost). The visible list therefore
always matches the ratings for selection, navigation and every operation scope.
A confirmed restoration applies at once. Pause, file operations, folder changes
and Quit discard unapplied results, which stay queued for re-verification.
Export's editable summary refreshes on review changes until its inputs freeze.
Undo charges reserved storage (unpaired sessions reserve one slot per photo).

Open: date-grouped projection/filter (~100–130 ms at 100k), the content-check
queue walk inside Select All, real hashing on removable media, mounted UI under
recovery load.

## Media (AUD-09, AUD-10, AUD-11, AUD-21, AUD-28, AUD-29, RAW stress)

- **AUD-09.** Maintenance previously ran once per launch at most daily, so a
  same-day relaunch or long session never pruned. With injected limits (600 KiB),
  the cache grew to 11× the limit without live passes; with them it peaked 8% over.
  A 20k-entry pass takes 0.24 s in 0.75 ms batches; disk-hit latency stays 0.7 ms.
- **AUD-10.** Simulated 300 ms serial reads at key-repeat speed: the old pattern
  ran 10 readers at once and settled after 3.08 s; one lane settles in ~0.4 s.
  No stale publications in either.
- **AUD-11 (no change).** The Fit recipe costs 53–76 ms with either decoder and
  adds at most 5–16 ms to the Fast Fit preview, none in RAW mode. 100%: first tile
  131 ms, surrounding ring 200 ms, warm pan 54 ms. Visible-first priority and RAW
  prefetch are not justified.
- **AUD-21.** `AVPlayerItem` end/failure notifications use current names (same
  constants, macOS 14 safe). Movie scan: ~1 ms per file; the 15 s bridge is not a
  bottleneck. Async audio reader (macOS 26+) not justified.
- **AUD-28.** Under background work: Gallery input → matching thumbnail 32 ms;
  Grid 74 ms (p95 126 ms). 1,000 background items drained in 87 s; longest
  main-actor gap 68 ms.
- **AUD-29.** After drain the test process returned to 0.1% CPU with zero idle
  wakeups, threads 9 → 6. Whole-app battery/AC energy remains open.
- **RAW stress.** Ten fresh-process runs (3,328 operations; metadata-only and new
  mixed metadata/thumbnail/preview mode; distinct and cloned RAFs; both cache
  options) completed with no stall or crash. This does not reproduce or explain
  the October stall/crash and makes no general RAW reliability claim.

Tests: `MediaMaintenanceTests`, `LouppeSpeedMediaResponsivenessTests`;
`RAWStressChecks` gains `mixed`. `LouppeSpeedMediaTests`' backlog assertion now
allows the 32-write pending cap (it failed identically on `5e6b2c0`).

## File durability (AUD-05, AUD-13, AUD-15, AUD-18, AUD-03 grants)

- **AUD-13.** Counted with an fsync interposer on production sources: the media
  side ran 5 full flushes per file; `fcopyfile` already synced the temporary and
  `publish` already synced the same folder. Now 3 per file; 4 journal flushes are
  unchanged. 50 × 200 KB: local −9 to −24%, APFS image ~0 to −6%, ExFAT source −8
  to −12%.
- **AUD-15.** 2 GiB file: previously one progress update at the end, and Stop was
  ignored until the file finished. A `copyfile` status callback now reports every
  ~0.1 s; Stop-to-exit is 0.12 s (image) and 0.38 s (local) including rollback.
  Error callbacks quit with the real errno.
- **AUD-05.** Reproduced on a real ExFAT image and locally. Destination-folder
  replacement rolls back. Source-folder replacement can move a same-named foreign
  file into a hidden `.partial`; the original stays intact and the journal stays
  retryable. No loss or overwrite; no safe fix without `RENAME_EXCL`.
- **AUD-18.** `Tests/run_copy_crash_boundary_check.sh` kills the process before
  every flush (and during the data write), then runs launch recovery in a fresh
  process: Copy 25 boundaries local/APFS image; Organize 36 local/APFS and 40
  ExFAT. All passed. A crash during the data write leaves an unrecorded partial
  needing attention; the ExFAT move probe can leave one hidden
  `.louppe-move-probe-*` file. SIGKILL is not power loss.
- **AUD-03 grant core.** `GrantLifecycleTests` keep leases balanced across Back,
  cancel, failure, retry, revocation and dropped tasks.

Image passes cover 512 MB images on the internal SSD with local journals only.

## Toolchain and dependencies (toolchain backend, AUD-20)

- Default SwiftPM backend: focused XMP 55/55 and full-suite results match native
  when build products live outside File Provider (`--scratch-path`). Packaging and
  the speed runner stay native: the default backend's release resource bundle uses
  `Contents/Info.plist` and takes its identifier from the checkout folder name.
- Test seams now compile under `LOUPPE_TEST_SEAMS` (defined for debug builds in
  `Package.swift`) instead of `DEBUG`; speed runs and the crash-boundary check pass
  `-DLOUPPE_TEST_SEAMS`, so optimized measurements no longer carry other
  debug-only code. A few counters on measured paths remain. The speed runner now
  uses `find` instead of an undeclared `rg` dependency.
- Sparkle 2.10.1 checksum matches and is the latest; all advisories affect ≤2.9.5.
  Expat 2.9.0 files and Adobe's copy are byte-identical to upstream; 275 of 278
  XMP Toolkit files match the pin, the other 3 are the recorded patches. Licenses
  match. Expat 2.10.0 (2 November) fixes four CVEs that are unreachable here
  (no parser reset, no external-entity parsers, `XML_GE=0`, DOCTYPE banned);
  adopt it in the next refresh. Adobe Trust Center needs a manual check.
- **Fixed:** the XMP Toolkit keeps every declared namespace in a process-wide
  table for the life of the app. Hostile packets could retain hundreds of MiB and
  slow every later parse. URIs are capped at 1,024 bytes and prefixes at 64; new
  namespaces are limited to 4,096 and 1 MiB per launch. Exhaustion reports
  "Quit and reopen Louppe" separately from a malformed sidecar. Adobe, Lightroom
  and already-read namespaces keep working after exhaustion; an unread vendor
  namespace needs a relaunch.
