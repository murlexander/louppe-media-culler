# Louppe app backlog

Reviewed on 15 October 2026. Alex reports manual checking complete and accepts
1.11.0 (13) for release preparation, keeping the existing screenshots.
[1.11.0 (13)](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.11.0)
is now the public GitHub release. See the
[current preparation record](Docs/RELEASE_1.11_PREPARATION_2026-10-15.md).

[Release acceptance](#release-acceptance) ·
[Correctness and compatibility](#correctness-and-compatibility) ·
[Performance](#performance) · [People and access](#people-and-access) ·
[Product follow-ups](#product-follow-ups) · [Later and research](#later-and-research)

[App guide](README.md#development-and-release) · [Website backlog](../website/BACKLOG.md)

Keep audit IDs stable and each task in one list. Check current code and reproduce
suspected bugs before changing behavior. Implementation alone does not close
manual acceptance. Research, publicity plans, and CAS notes stay in Obsidian.

## Release acceptance

Alex accepted the manual review on 15 October 2026 and deferred screenshot
refresh. This records owner acceptance; it does not invent per-case transaction,
linguistic, hardware, or energy measurements. The investigations below remain open.

- [x] **Local packages.** Rebuilt Developer ID and signed Store candidates from
  current source, verified archives/installer, and retained exact checksums,
  fresh validation, and public notes. See the current preparation record.
- [x] **Notarization and feed.** Apple accepted the explicitly approved candidate;
  the stapled ZIP passed Gatekeeper and complete archive verification. The signed
  1.11 feed matches the exact published archive. Checksums/results are retained.
- [x] **Manual review.** Alex reports all looks good for release after checking.
  This closes the release hold for Store workflows/tips, accessibility (AUD-23),
  display/provider layouts (AUD-24), burst behavior (AUD-22), languages/older-system
  layouts, and representative responsiveness. Detailed measurements under
  AUD-28/AUD-29 and broader compatibility work remain follow-ups.
- [x] **Store media decision.** Keep the staged 36 screenshots and six previews
  for now, as Alex requested. They use 1.10 captures. No dark-icon change is planned
  for this release. Check Apple-required listing fields during submission.
- [x] **GitHub publication.** Published the exact notarized 1.11 archive and
  matching signed feed as authorized on 15 October, without waiting for Store
  approval. Public download/feed identity, Homebrew, six website download links,
  and a real Sparkle installer upgrade from 1.10 pass. The update-dialog UI was
  not checked because desktop capture was unavailable; API evidence is retained.
- [ ] **Store publication.** Keep the Store channel shipping alongside GitHub,
  with Apple updates/StoreKit tips; direct downloads retain Sparkle/Revolut tips.
  Complete upload/submission and required product/listing/account checks separately.

1.11 saves session format 7; 1.10 cannot read it. Preserve saved-session copies
before testing a downgrade. GitHub releases continue alongside the Store channel.

## Correctness and compatibility

- [ ] **AUD-03 — Sandbox recents/routing.** Signed Store picker, cold Recent and
  routed Copy/Back passed. Still test stale/revoked grants, card reconnect, and
  Review → Back → Review → Copy after cancellation/failure. Keep recents and
  destinations authorized for their intended lifetime; hardware gaps remain open.
- [ ] **AUD-05 — ExFAT path replacement.** Reproduce path-based Move fallback and
  launch recovery on disposable ExFAT. Standard Move/Rename/Organize/undo bind
  parent descriptors; retain ExFAT’s no-overwrite probe and durability warning.
- [ ] **RAW 9 compatibility.** Check older/unsupported Macs, missing resources,
  failed downloads, and compressed/lossless-compressed Fuji RAFs. Verify retry/
  default remedies, fresh pixels after decoder changes, and intact originals.
  macOS 27 X-T50 uncompressed decoding/regressions passed.
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

## Performance

Start with AUD-12/AUD-14 for possible interface stalls, then AUD-17/AUD-09 for
retained memory and disk growth. Measure before changing behavior; these remain
investigations. AUD-06 has measured fixes and outstanding projection work.
AUD-28/AUD-29 cover native responsiveness and sustained resource acceptance.

Keep IDs stable. Close a task only with production measurements and affected
safety/native checks. Local stage medians are not whole-app speedups.

### Projection

- [ ] **AUD-06 — Index, review projection, and save capture.** Finite metadata
  buckets, sort-only map reuse and exact cached coverage are implemented and
  tested. At 100k: metadata sort 37–39 ms (formerly 172–255), coverage 0.009 ms
  (formerly 81), ordinary rating 0.025 ms, decision-sorted rating 120 ms and
  frozen capture 17.8 ms in final confirmation. The 14 October cue follow-up
  replaces repeated warning/filename-set construction with one-byte item matches:
  two optimized 100k runs give 16–44 ms for warm metadata-cue switches,
  versus 128–159 ms on the new baseline; first use is 53 versus 152 ms.
  Accepted evidence updates only its own slots. See the [cue-filter review](Docs/Archive/2026-10-14/QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md).
  Remaining: incremental visible/group projection (clearing cues still exposes
  every row), retained memory and interaction under load. Profile batch recovery
  under active sorts before choosing projection/progress batching; preserve
  serial proofs, arbitrary-input ties, physical/recovery maps, selection and saves.
  The 20 October 1.12 quality run records 100k camera-sort median 755 ms and
  decision-sorted rating 123 ms (1k camera sort 6 ms). Keep large-folder sort/
  projection profiling open; no comparable pre-1.12 run establishes a regression.
  See the [quality review](Docs/QUALITY_REVIEW_1.12_2026-10-20.md).

### Next measurements

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

### Native and sustained acceptance

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

## People and access

- [ ] Back up and restore-test the private updater signing key.
- [ ] Test a clean install and real culling workflow with a tester.
- [ ] Ask a collaborator for code review.
- [ ] Obtain the designer’s final shared app/site brand asset.
- [ ] Check XMP in Bridge, Lightroom Classic, and darktable; repeat separate
  RAW/JPEG conflict/reload in Capture One. Packet/resolver tests passed; editor
  acceptance remains open.

## Product follow-ups

- [ ] **1.12 local acceptance.** Review Dock cold/warm opens, direct folder
  replacement and retained window geometry, custom layout/physical shortcuts,
  and Fuji simulation Info/filtering with Alex's real shoot. Native shortcut
  editing and Fuji Info/filtering pass; read-only ExifTool comparison matches
  39 real JPEGs and 23 RAFs. Actual Dock dragging, owner workflow acceptance and
  folder grants in a sandboxed Store candidate remain. Implementation and local evidence are in the
  [review record](Docs/REVIEW_1.12_2026-10-20.md); publication remains separate.
- [x] **Renaming discovery — Aymeric feedback, 20 October 2026.** Help now
  explains Filter Yes → Command Palette → Rename Files from Metadata → Filtered,
  with exact name preview and Undo. No renaming behavior changed. New recipe
  controls stay deferred until Alex supplies the desired ExifRenamer pattern;
  retain family/collision checks and journaled undo.
- [ ] **Temporary preview softness — Aymeric feedback, 20 October 2026.**
  A small indicator beside zoom now distinguishes the thumbnail stand-in from
  ready fitted detail, with deterministic delayed/success/failure and stale-
  navigation coverage. Local/SD-card cold and warm navigation measurements remain
  before changing decoding/prefetch. Reuse AUD-28 measurements; keep cache and
  concurrency bounds. This state indication does not claim a decoding speedup.
- [ ] **Photo location lookup — Aymeric feedback, 20 October 2026.** Alex deferred
  this from 1.12 on 20 October; finish the current scope first. Later, add an
  explicit Open in Maps action to valid GPS coordinates in Info. No location
  lookup before the click. Consider an embedded shoot map separately only if
  demand justifies its interface and resource costs.
- [ ] **Automatic blur detection.** After the first cue prototype, experiment
  with measured relative softness within bursts and verified detail crops.
  Flag uncertain photos for human review; retain low-texture/intentional-blur
  uncertainty. Early-user feedback recorded 11 October 2026.
- Fuji film simulation is implemented for 1.12 in Info and Filter; native
  acceptance is tracked above. Camera previews include it; Apple RAW rendering
  bypasses it. Keep originals intact and avoid a redundant rendering toggle.
- [ ] Extend format support where macOS allows.

Burst acceptance is AUD-22 above; inline comparison stays in the research list.

## Later and research

These are deferred ideas, not committed implementation scope.

- [ ] Portable recovery beyond the same relative filename: copied-and-renamed
  or reorganized copies need explicit remapping/verified content discovery.
  Physical originals already follow unique disk identity. Design recovery-history
  retention limits without losing unresolved decisions or the saved generation.
- [ ] SD-card ingest, naming templates, and review during copy.
- [ ] Preview-first EXIF routing/auto-culling; never silently move originals.
- [ ] Arbitrary metadata filters beyond Fuji film simulation. Design supported
  tag discovery, typed value matching and bounded indexing; avoid repeated
  per-file reads when changing filters. Aymeric feedback, 20 October 2026.
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

## Decisions already made

- Keep one neutral photo background; custom backgrounds are not planned.
- XMP export supports Capture One. Further integration needs a separate proposal.
