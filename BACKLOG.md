# Louppe app backlog

Reviewed on 21 October 2026 against current source, version history, and the
[1.12 release record](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md).
The next planned release is **1.13.0 (15)**. Implemented changes belong in
[CHANGELOG.md](CHANGELOG.md); this backlog contains unfinished work only.

[1.13 planned release](#113-planned-release) ·
[Correctness and compatibility](#correctness-and-compatibility) ·
[Performance](#performance) · [People and access](#people-and-access) ·
[Release acceptance](#release-acceptance) · [Later and research](#later-and-research)

[App guide](README.md#development-and-release) · [Website backlog](../website/BACKLOG.md)

Keep audit IDs stable and each task in one list. Check current code and reproduce
suspected bugs before changing behavior. Implementation alone does not close
manual acceptance. Completed outcomes stay in version history and dated reports.
Research notes, publicity plans, and CAS notes stay in Obsidian.

## 1.13 planned release

Carry unfinished work from older releases into this plan. The correctness and
performance queues below retain their acceptance criteria; investigations need
measurements before choosing a fix. Later ideas remain deferred.

- [ ] **Fast, stable opening and browsing of large folders.** Make folders with
  thousands of photos usable sooner and keep navigation/scrolling responsive
  during processing. Alex requested this on 21 October 2026.
  - **Approach to validate:** profile discovery, identity checks, RAW+JPEG pairing,
    metadata extraction, saved-decision loading, and first layout separately.
    Evaluate showing a stable file inventory with placeholders before all metadata
    is ready, then prioritize visible/current items and fill the rest through
    bounded background work and batched UI updates. A raw file count alone cannot
    identify cells or establish the paired item count. Adopt staged opening only
    if measurements show a useful improvement without weakening correctness.
  - **Grid and Browser stability:** reserve cell geometry; retain stable item IDs,
    the visible scroll anchor, current photo, and selection as results arrive.
    Define how incomplete date/sort/filter data settles without repeated reshuffling,
    disappearing rows, wrong thumbnails, flashing placeholders, or sideways drift,
    including during rapid scrolling, resizing, and Gallery/Grid switches.
  - **Safe partial loading:** preserve pairing, source identity, saved decisions,
    and recovery gates. Do not overwrite unread decisions with a partial save or
    permit file mutations based on incomplete data. Cancel promptly on folder
    changes/Close and reject late results from the previous scan.
  - **Acceptance:** compare current and proposed behavior on representative 1k/10k+
    JPEG, RAW+JPEG, and mixed-media folders, cold/warm on local storage and an
    SD card. Measure first usable view, first useful thumbnails, full readiness,
    input-to-visible latency, and memory while processing and scrolling. Exercise
    fast reverse scrolling, long jumps, Info, resizing, and cancellation in the
    actual mounted Grid/Browser. Reuse AUD-06/AUD-28 measurements and the existing
    scroll regression gates; a faster loading screen alone is not completion.
  - **22 October implementation:** installed locally in 1.13 (15): safe read-only
    early browsing, worker-owned opening preparation, bounded native Grid/Browser,
    cached projection/sorts and owned media work. Full suite: 913 tests, 42 skips,
    zero failures; safety: 75/75. Warm 10k Grid tail: 961→56 ms; 10k RAW+JPEG-pair
    first pixels: 6.73→2.97 s, with slower full readiness (6.73→8.17 s).
    [Implementation and acceptance record](Docs/LARGE_FOLDERS_2026-10-22.md).
    Keep this item open for unresolved RawCamera stress stall/crash evidence,
    varied RAW/mixed and SD-card acceptance, physical diagonal/momentum/Welcome
    edge dragging, and remaining main-actor/readiness costs. Failed stress runners
    are recorded separately from completed samples; no general RAW reliability claim.
- [ ] **Photo location lookup — Aymeric feedback, 20 October 2026.** Add an
  explicit Open in Maps action to valid GPS coordinates in Info. Do not look up
  locations before the click. Carry this forward from the deferred 1.12 work;
  an embedded shoot map remains a separate later idea.
- [ ] **Native workflow acceptance carried from 1.12.** Exercise physical Dock
  dragging at cold launch and with an open folder, retained window geometry,
  and physical rename-row dragging on disposable media. Review custom shortcuts
  in Alex's real-shoot workflow, then cover ISO/JIS/dead-key/IME input, VoiceOver,
  older macOS, and the two-display transition in their actual environments.
  Native shortcut editing and Fuji Info/filtering already passed; their completed
  checks are in the [review record](Docs/REVIEW_1.12_2026-10-20.md).
  Sandbox grant/reconnect cases belong to AUD-03, not a second checklist here.

Temporary preview softness is now a measurement follow-up under AUD-28. The
loading indicator shipped in 1.12; do not reimplement it as an unfinished feature.

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
- [ ] **Toolchain test backend.** Verify a supported replacement for Xcode 27's
  deprecated native SwiftPM backend and separate optimized test seams from
  production `-DDEBUG` flags. The default backend previously failed XCTest signing
  after Finder metadata appeared in Documents. Keep the current SDK and checks
  until the replacement passes; the latest full-suite baseline is in the
  [1.12 release record](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md#verification).
- [ ] **AUD-21 — Media/AV APIs.** Modernize asynchronous AV-property loading
  behind synchronous worker bridges and macOS 27 reader/player notifications.
  A UI-thread semaphore stall has not been established. Measure mixed-media scan
  throughput/cancellation and retain finite timeouts, macOS 14, bounded lanes,
  reader exit, and playback/audio cancellation tests.
- [ ] **AUD-18 — Volume/interruption tests.** Extend fault injection beyond the
  recorded case-sensitive APFS and detach/remount cases: ExFAT, removable/network
  volumes, interrupted operations, lid-close, and simulated power loss. ExFAT
  image creation was unavailable on the release host, not a pass. Verify no
  overwrite, accurate durability, retained recovery, and safe undo/retry. Record
  actual coverage; related performance baselines remain AUD-06/AUD-19.
- [ ] **AUD-19 — RAW/color/GPU baseline.** Build a licensed RAW/JPEG/profile corpus
  with orientation/transparency cases. Compare preview, RAW/histogram/clipping,
  and 100% tiles to reference renders; measure Release GPU/RSS under navigation/
  zoom. One copied 84 MiB Fuji RAF now has an optimized Apple Default preview/
  histogram baseline with byte/identity checks; synthetic 100 MP tile-budget tests
  also pass. Multi-camera/RAW 9, color/reference, cold-resource and sustained
  GPU/helper-process memory acceptance remain open. Record actual corpus coverage.
- [ ] **AUD-20 — Dependencies/security.** Refresh the recorded Sparkle/Expat/
  Adobe XMP pins, patches, licenses, and official-advisory review for 1.13;
  coordinate the independent website dependency check with its release work.
  The bounded 7 October review is historical evidence, not a current security
  clearance. Investigate exposures and extend hostile-XMP tests as needed;
  parser tests cover only the reviewed subset.

## Performance

Start with AUD-12/AUD-14 for possible interface stalls, then AUD-17/AUD-09 for
retained memory and disk growth. Measure before changing behavior; these remain
investigations. AUD-06 has measured fixes and outstanding projection work.
AUD-28/AUD-29 cover native responsiveness and sustained resource acceptance.

Keep IDs stable. Close a task only with production measurements and affected
safety/native checks. Local stage medians are not whole-app speedups.

### Projection

- [ ] **AUD-06 — Index, review projection, and save capture.** Profile incremental
  visible/group projection, clearing cues, decision-sorted ratings, and batch
  recovery under active sorts at 1k/10k/100k. Measure retained memory and interaction
  under load before choosing projection/progress batching. Preserve serial proofs,
  arbitrary-input ties, physical/recovery maps, selection, and saves.
  The latest 1.12 release run records 100k camera-sort median 756 ms; the quality
  review records decision-sorted rating at 123 ms. These are current baselines,
  not evidence of a regression against an equivalent pre-1.12 run.
  [Release measurements](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md#verification) ·
  [Quality review](Docs/QUALITY_REVIEW_1.12_2026-10-20.md) ·
  [Implemented cue-filter optimizations](Docs/Archive/2026-10-14/QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md).

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
  from image-request cancellation. Measure cold Fit/100% transitions and both decoders
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
  Include cold/warm local and SD-card navigation to measure temporary preview
  softness (Aymeric feedback, 20 October): time first thumbnail, fitted detail,
  and loading-indicator settlement before changing decoding or prefetch. Retain
  cache/concurrency bounds. Preserve large-session current/selection and test a
  representative mixed shoot.
  Establish repeatable baselines before setting regression limits; resolve native
  capture/AX tooling gaps rather than calling mirrored orchestration visual QA.
- [ ] **AUD-29 — Background energy and true idle.** Measure sustained CPU/GPU,
  RSS, wakeups, and decoder/helper exit on representative large RAW folders,
  after Pause/Close and complete drain. Compare battery/AC and foreground
  responsiveness. Existing bounded scheduling, explicit Pause, and thermal/
  Low Power backoff are implemented; worker tests and synthetic CPU results do
  not establish battery drain. Preserve current/visible interest and accurate
  evidence; investigate an App Nap/inactive-window policy only after measurement.
  Keep the resource contracts in [PERFORMANCE.md](Docs/PERFORMANCE.md).

## People and access

- [ ] Back up and restore-test the private updater signing key.
- [ ] Test a clean install and real culling workflow with a tester.
- [ ] Ask a collaborator for code review.
- [ ] Obtain the designer’s final shared app/site brand asset.
- [ ] Check XMP in Bridge, Lightroom Classic, and darktable; repeat separate
  RAW/JPEG conflict/reload in Capture One. Packet/resolver tests passed; editor
  acceptance remains open.

## Release acceptance

- [ ] **Apple review follow-up.** Check the outcome of the submitted 1.12 build
  14 and respond to any review request. The last recorded state on 21 October is
  Waiting for Review, with automatic release after approval; current approval
  has not been rechecked during this backlog cleanup. This is a distribution
  follow-up, separate from the 1.13 feature plan.
  [Submission evidence](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md#publication-and-installed-app).

Keep the existing Store screenshots/previews unless Alex changes that decision.
GitHub/Sparkle and App Store distribution remain separate. Saved sessions use
format 7; preserve copies before testing a downgrade to 1.10.

## Later and research

These are deferred ideas, not committed implementation scope for 1.13.

- [ ] **Automatic blur detection.** Experiment with measured relative softness
  within bursts and verified detail crops. Flag uncertainty for human review,
  including low-texture and intentional-blur cases. Early-user feedback,
  11 October 2026; the 1.12 review explicitly deferred this research.
- [ ] **Additional media formats.** Identify a specific unsupported format and
  representative licensed fixtures before expanding support where macOS allows.
  JPEG XL, AVIF, and WebP decode routes already have regression fixtures.
- [ ] **Additional rename recipes.** Obtain Alex's desired ExifRenamer filename
  pattern before adding recipe controls. Keep exact previews, family/collision
  checks, and journaled undo.
- [ ] **Embedded shoot map.** Consider only after demand justifies the interface
  and resource costs; the explicit GPS-to-Maps action belongs to the 1.13 plan.
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
