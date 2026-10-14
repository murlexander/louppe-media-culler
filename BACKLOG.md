# Louppe Media Culler backlog

App product and engineering work lives here. Research, publicity, and CAS notes
stay in Obsidian. Latest public release: [1.10.0 (12)](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.10.0).

Reviewed 12–13 October 2026 against current code, tests, and published releases.
The working version is 1.11.0 (13), unreleased. Checked items describe verified
outcomes; measurements or an active implementation alone do not close a task.

## Completed readiness work — 7 October 2026

- [x] **AUD-01:** a shared 512 MiB read/CAS/write limit rejects oversized saves
  before either saved copy changes. Retry, dirty Close, and Quit remain safe.
- [x] **AUD-02:** check lazy JPEG identity before/after metadata reads. Replacement
  offers Rescan; completed RAW Trash and Undo remain accurate on enrichment failure.
- [x] **AUD-04:** cancellation covers saved-session reads and final scan validation.
- [x] Published the privacy policy and added Help/About links.
- [x] Reproduced external status/hidden-flag changes in Documents test fixtures
  without Louppe running. Temporary-storage fixtures pass all 75 checks and 20
  pairing repeats; byte assertions, identity guards, and five-second waits remain.
  The external writer is unidentified.
- [x] Unsupported ExFAT export destinations fail before media/journal creation.
  ExFAT-source → APFS Copy works.

Signed Store picker, cold Recent, routed Copy/Back, Move, Rename/Trash/Organize
with Undo, media previews and safe Copy Stop passed. AUD-03 retains untested
grant/failure cases. Case-sensitive APFS/ExFAT and image detach/remount passed;
physical/provider/power tests remain under AUD-05/AUD-18.
[Readiness and submission evidence](Docs/APP_STORE_READINESS_2026-10-07.md).

## Waiting on Alex or collaborators

- [ ] **AUD-23 — Native accessibility.** Check spoken VoiceOver, Full Keyboard
  Access, increased contrast, and Reduce Motion in review, recovery, Gallery,
  and drive actions. Record settings/results; hotkey tests cover only part of this.
- [ ] **AUD-24 — Display/provider cases.** Check Welcome/Scanning/Ready on a small
  display, after resize/display changes, with long warnings, many drives, and
  delayed File Provider drops. Keep every message/action reachable with feedback.
- [ ] Back up and restore-test the private updater signing key.
- [ ] Test a clean install and real culling workflow with Katerina.
- [ ] Ask Andrey for code review; decide co-authorship separately.
- [ ] Obtain Masha’s final shared app/site brand asset.
- [ ] Check XMP in Bridge, Lightroom Classic, and darktable; repeat separate
  RAW/JPEG conflict/reload in Capture One. Packet/resolver tests passed; editor
  acceptance remains open.

## Implemented in 1.10.0

- [x] Source-folder hierarchy in Sort, with full relative-path headers.
- [x] Review preferences: decision advancement, default sort/group dividers,
  and Gallery/Grid view.
- [x] External drive/card capacity and a folder chooser at the selected drive.

Released in 1.10.0 with RAW display, Apple Default / RAW 9, and early-user
feedback. See [review evidence](Docs/REVIEW_BUILD.md).
Configurable shortcuts remain deferred to preserve keyboard safety.

## Product improvements

- [x] **Quality Cues local prototype — 12 October 2026.** Filter sections,
  Browser/Grid glyphs, compact measured values in Info, independent area rules, and
  bounded checks with Info closed are implemented. Metadata-only capture bursts
  retain date provenance and run membership work off-main. Local review only;
  release acceptance gaps remain in the [review record](Docs/QUALITY_CUES_REVIEW_2026-10-12.md).
  [Prototype scope](Docs/QUALITY_CUES_PROTOTYPE_2026-10-12.md).
- [x] **Saved-decision recovery local prototype — 12 October 2026.** Folders
  open without discarding changed-file decisions. Verified copies and returning
  originals restore automatically; older entries offer explicit restoration,
  preserved history and a dismissible notice. Clear All and Undo remain cleared after
  background checks and reopen. [Review and precommit evidence](Docs/SESSION_RECOVERY_REVIEW_2026-10-12.md).
- [ ] **Burst-photo acceptance.** Filter discovery, fractional timestamps,
  date provenance, partial groups and independent RAW+JPEG decisions are
  implemented and tested. Verify real high-speed Fuji sequences and separate
  shutter presses; nearby cameras/presses can still merge by time. Related:
  AUD-07/AUD-08/AUD-22; inline comparison remains a followup.
- [ ] **Automatic blur detection.** After the first cue prototype, experiment
  with measured relative softness within bursts and verified detail crops.
  Flag uncertain photos for human review; retain low-texture/intentional-blur
  uncertainty. Early-user feedback recorded 11 October 2026.
- [ ] Show Fuji film simulation in metadata. Camera previews include it; Apple
  RAW rendering bypasses it. Keep originals intact and avoid a redundant toggle.
- [ ] Extend format support where macOS allows.

## Technical hardening

- [ ] **RAW 9 compatibility.** Check older/unsupported Macs, missing resources,
  failed downloads, and compressed/lossless-compressed Fuji RAFs. Verify retry/
  default remedies, fresh pixels after decoder changes, and intact originals.
  macOS 27 X-T50 uncompressed decoding/regressions passed.
- [ ] **AUD-05 — ExFAT path replacement.** Reproduce path-based Move fallback and
  launch recovery on disposable ExFAT. Standard Move/Rename/Organize/undo bind
  parent descriptors; retain ExFAT’s no-overwrite probe and durability warning.
- [ ] **Toolchain test backend.** Xcode 27's default SwiftPM backend failed
  signing an XCTest bundle with Finder metadata in Documents; native passed
  the 13 October final full suite (714 tests, 31 explicit skips, zero failures) but is
  deprecated. Optimized tests currently need `-DDEBUG` for existing test seams.
  Verify a supported backend and separate those seams from production flags;
  keep the current SDK and checks until a replacement passes.
- [ ] **AUD-21 — Media/AV APIs.** Modernize asynchronous AV-property loading
  behind synchronous worker bridges and macOS 27 reader/player notifications.
  A UI-thread semaphore stall has not been established. Measure mixed-media scan
  throughput/cancellation and retain finite timeouts, macOS 14, bounded lanes,
  reader exit, and playback/audio cancellation tests.
- [ ] **AUD-18 — Volume/interruption tests.** Extend fault injection on case-sensitive
  APFS, ExFAT, removable/network volumes, disconnect/remount, lid-close, and simulated
  power loss. Verify no overwrite, accurate durability, retained recovery, and safe
  undo/retry. Record actual coverage. UI: AUD-23/24; Release baselines: AUD-06/19.

Check current code and reproduce suspected bugs before changing behavior.

## Audit follow-ups

All 17 confirmed [29 September findings](Docs/Audits/2026-09-29/README.md) are
implemented; [tests/evidence](Docs/Audits/2026-09-29/implementation.md) are retained.
Follow-ups include verified performance fixes, remaining investigations, and
acceptance. Keep IDs stable and preserve originals/identity/CAS/journals. Website
work lives in its `BACKLOG.md` (WEB-AUD-01).

### Correctness investigations — start here

- [ ] **AUD-03 — Sandbox recents/routing.** Signed Store picker, cold Recent and
  routed Copy/Back passed. Still test stale/revoked grants, card reconnect, and
  Review → Back → Review → Copy after cancellation/failure. Keep recents and
  destinations authorized for their intended lifetime; hardware gaps remain open.

### Performance — measured results and remaining work

The [12 October inspection](Docs/PERFORMANCE_REVIEW_2026-10-12.md) retains two
independent optimized runs, real JPEG/RAW checks, and candidate-equivalence tests.
The [speed-test guide](Docs/SPEED_TESTS.md) covers reruns and comparison. Large-session
figures use 100k items; media entries specify their own fixtures. These are local
stage medians, not shipping or whole-app speedups.
The separate implementation chat completed the confirmed fixes. Checked items
have production comparisons and affected safety/native checks; gaps stay open.

- [ ] **AUD-06 — Index, review projection, and save capture.** Finite metadata
  buckets, sort-only map reuse and exact cached coverage are implemented and
  tested. At 100k: metadata sort 37–39 ms (formerly 172–255), coverage 0.009 ms
  (formerly 81), ordinary rating 0.025 ms, decision-sorted rating 120 ms and
  frozen capture 17.8 ms in final confirmation. The 14 October cue follow-up
  replaces repeated warning/filename-set construction with one-byte item matches:
  two optimized 100k runs give 16–44 ms for warm metadata-cue switches,
  versus 128–159 ms on the new baseline; first use is 53 versus 152 ms.
  Accepted evidence updates only its own slots. See the [cue-filter review](Docs/QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md).
  Remaining: incremental visible/group projection (clearing cues still exposes
  every row), retained memory and interaction under load. Profile batch recovery
  under active sorts before choosing projection/progress batching; preserve
  serial proofs, arbitrary-input ties, physical/recovery maps, selection and saves.
- [x] **AUD-07 — Zero-I/O capture-burst analysis.** Capture requests return before
  identity/hash/preview access; all-mode still invokes its workers. Instrumented
  checks pass. Unused payload allocation is also removed under AUD-08.
- [x] **AUD-08 — Analysis preparation and background groups.** Capture-only inputs
  now cost 15.1 ms versus the former 126 ms at 100k. Exact/similar membership runs
  off-main with cancellation, latest mode/sensitivity/generation, prior layout
  and navigation guards. Worker CPU is 29/70–157 ms; lower UI blocking, rather
  than faster grouping, is the gain. Future measurement: count hashing/preview
  demand for exact-only/similar-only requests before adding mode capabilities.
- [x] **AUD-16 — Compact, sorted JSON.** Production encoding retains every field,
  history, deterministic backup bytes, exact-byte CAS and durability checks.
  The 100k fixture shrinks 93,933,586 → 63,933,555 bytes (31.9%); encoding remains
  about 1.2 seconds, so no large encode-speed gain is claimed. Size ceilings,
  lineage, sequence/generation and legacy roundtrips pass.
- [x] **AUD-25 — Abandoned image work and Gallery publication.** Already-cancelled
  requests now produce zero decoded images/cache writes. Full Gallery pixels
  publish independently of thumbnail backlog; a mounted native check passes.
  Live coalesced waiters, worker-exit capacity, operation identity, foreground
  promotion, revision guards and bounded prefetch pass. Physical-screen latency
  and sustained contention remain AUD-28 acceptance work.
- [x] **AUD-26 — Pairing preparation.** Production 100k pairing falls 1,351 → 719 ms
  for distinct stems and 1,175 → 563 ms for RAW+JPEG. Scanner and main-actor pair
  preparation, exact ordering, ambiguity, case/Unicode rules, independent media
  and complete physical membership are verified.
- [x] **AUD-27 — Background RAW cue scheduling.** A copied Fuji RAW measures
  164 ms without Info's dwell versus 886 ms before; Info retains its 700 ms dwell.
  Single utility RAW lane, bounded batches, leases, source bytes, mixed foreground
  JPEG latency and Info-closed evidence pass. The resource follow-up adds paced
  admission and durable user Pause; see AUD-29. Comparing per-result publication
  with pair completion remains a latency hypothesis, especially for mixed pairs.

The [implemented performance results](Docs/PERFORMANCE_IMPLEMENTATION_2026-10-12.md)
and [quality resource follow-up](Docs/QUALITY_CUE_RESOURCES_2026-10-12.md) retain
acceptance, raw measurements and remaining limits.


### Performance — next measurements

After the current pass, prioritize AUD-12/AUD-14 for interface stalls, then
AUD-17/AUD-09 for retained memory/disk growth. These are code-backed candidates,
not measured regressions. Export I/O work needs disposable storage fixtures.

- [ ] **AUD-12 — Lazy routing rows.** An outer lazy stack still contains eager
  route-file/unmatched stacks. Mount 10k+ single-route and unmatched previews;
  measure opening, realized rows, scrolling and memory. Test per-file lazy rows
  if justified, retaining every exact name/path and accessible safety detail.
- [ ] **AUD-14 — Ordinary export preflight.** Destination validation remains
  synchronous and Move queries each physical source's volume; routed/XMP planning
  already runs off-main. Count queries and measure large/local/delayed-volume
  selections. Freeze inputs for bounded off-main validation where justified;
  preserve grants, exact parent binding, progress/cancel and no early mutations.
- [ ] **AUD-17 — Undo retention.** The limit is 500 steps, without a byte budget.
  Select All alone creates no Undo step: measure repeated Select All → decision,
  star/color edits, Clear All and Undo at 1k/10k/100k. Record retained snapshots
  and peak RSS before choosing byte-based eviction. Preserve Mixed/independent
  physical decisions, per-photo Undo and journaled operation Undo.
- [ ] **AUD-09 — Live disk-thumbnail enforcement.** Delayed daily pruning,
  512 MiB target and 90-day age policy already exist. Test sustained writes and
  same-day launches with small injected limits, coalesced write/time maintenance,
  prune overlap and readable survivors. Measure peak overshoot and scroll latency;
  avoid per-thumbnail walks or unsupported increases to memory-cache budgets.
- [ ] **AUD-10 — Abandoned EXIF detail reads.** Histogram/RAW/audio work already
  has bounded lanes and cancellable/coalesced waiters. The remaining Info detail
  reader starts detached EXIF work after dwell. Use injected slow reads during
  rapid navigation to count concurrent/abandoned readers and stale publications;
  then confirm on disposable removable/network media before changing scheduling.
- [ ] **AUD-11 — Cold RAW source/navigation work.** High-resolution recipes are
  requested even for Fit dimensions; source-waiter retirement remains separate
  from AUD-25's image requests. Measure cold Fit/100% transitions and both decoders
  before caching dimensions or changing dwell. Test visible-first tile priority
  and mode-aware RAW prefetch as hypotheses, comparing first visible pixels and
  warm-pan latency. Keep two tile renders, 128 MiB and bounded source regions.
- [ ] **AUD-13 — Copy flush costs.** Export Copy is not covered by the new speed
  suite. Instrument file/directory flush counts and time for small-file batches
  on local/removable storage, separating production and injected copiers. Remove
  only proven redundancy; preserve write → sync → stage → publish → directory
  sync/checkpoint and recovery after side effects.
- [ ] **AUD-15 — Within-file copy progress/cancel.** Completed-byte totals,
  throttling, rollback retraction and safe Stop already exist. A single large
  `fcopyfile` still lacks progress/cancel callbacks. Measure progress intervals
  and Stop-to-worker-exit on disposable large video/slow storage before choosing
  callbacks or chunks. Preserve identity-proven partial cleanup, metadata/forks,
  rollback and remount behavior.

### Performance — future verification

- [ ] **AUD-28 — Foreground latency under contention.** Extend the existing speed
  suite with mounted Gallery/Grid/Filter/zoom and frame/media-ready barriers during
  thumbnail, cue, fingerprint and save work. Record input-to-visible-result samples,
  memory and queue drain/cancel behavior, with warm/source/disk paths separated.
  Preserve large-session current/selection and test a representative mixed shoot.
  Establish repeatable baselines before setting regression limits; resolve native
  capture/AX tooling gaps rather than calling mirrored orchestration visual QA.
- [ ] **AUD-29 — Background energy and true idle.** Resource fixes are implemented:
  utility JPEG work, at most two scheduler measurements across generation retirement,
  linear selection priority, private batched evidence, persistent explicit Pause,
  and adaptive rest with Low Power/thermal backoff. Controlled worker/idle tests
  establish those contracts; synthetic CPU results do not establish battery drain.
  Measure sustained CPU/GPU, RSS, wakeups and decoder/helper exit on representative
  large RAW folders, after Pause/Close and complete drain. Compare battery/AC and
  foreground responsiveness. Preserve current/visible interest and accurate evidence;
  investigate an App Nap/inactive-window policy only after measurement.


### Further verification

- [ ] **AUD-19 — RAW/color/GPU baseline.** Build a licensed RAW/JPEG/profile corpus
  with orientation/transparency cases. Compare preview, RAW/histogram/clipping,
  and 100% tiles to reference renders; measure Release GPU/RSS under navigation/
  zoom. One copied 84 MiB Fuji RAF now has an optimized Apple Default preview/
  histogram baseline with byte/identity checks; synthetic 100 MP tile-budget tests
  also pass. Multi-camera/RAW 9, color/reference, cold-resource and sustained
  GPU/helper-process memory acceptance remain open. Record actual corpus coverage.
- [ ] **AUD-20 — Dependencies/security.** Record exact Sparkle/Expat/Adobe XMP/site
  pins, patches, licenses, and official advisories. The 7 October review found no
  published affected-range match; sources and confidential/vendor limits are in
  the submission packet. Investigate exposures and extend hostile-XMP tests as
  needed. Parser tests cover only the reviewed subset.

## Later / research

- [ ] Portable recovery beyond the same relative filename: copied-and-renamed
  or reorganized copies need explicit remapping/verified content discovery.
  Physical originals already follow unique disk identity. Design recovery-history
  retention limits without losing unresolved decisions or the saved generation.
- [ ] SD-card ingest, naming templates, and review during copy.
- [ ] Preview-first EXIF routing/auto-culling; never silently move originals.
- [ ] Focus peaking and detail/edge inspection.
- [ ] Inline burst comparison with matched crops/synchronized zoom in the existing
  Gallery/Info surfaces; avoid new screens or user-facing modes by default.
- [ ] Scrollable subject/detail inspection in Info: user-selected region first,
  then investigate local face/subject crops. Preserve revision and pixel mapping.
- [ ] Video/audio Quality Cues with timestamped evidence and seek-to-interval in
  existing Gallery. Report sampling/track/channel coverage; reuse bounded frame
  and PCM work. Collect audio overload evidence before waveform sanitization.
- [ ] ML/AI Quality Cues research — 12 October 2026. Evaluate local pairwise
  preferences, Vision feature/face/aesthetics evidence, and optional OpenAI
  finalist comparison. Recheck models/pricing/privacy and validate usefulness;
  no models, cloud/API calls, uploads or automatic ratings in the first prototype.
- [ ] Scenes / chronological-story review.
- [ ] iPad Grid companion.
- [ ] Embedded metadata in exported JPEG copies only, with a separate safety design.
- [ ] **AUD-22 — Burst dates.** EXIF original/digitized/TIFF, subseconds, offsets
  and inferred creation dates are retained; Info shows Captured/Time zone
  and marks fallback dates estimated. Synthetic same-second,
  mixed-camera and import-date cases pass. Real high-speed Fuji/shutter-press
  acceptance remains; date gaps can merge separate presses or cameras.

## Decisions already made

- Keep one neutral photo background; custom backgrounds are not planned.
- XMP export supports Capture One. Further integration needs a separate proposal.
