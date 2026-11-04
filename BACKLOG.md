# Louppe app backlog

Reviewed on 21 October 2026 against current source, version history, and the
[1.12 release record](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md). Agent-runnable
1.13 correctness and performance work was measured and updated on 4 November 2026:
[4 November record](Docs/BACKLOG_1.13_2026-11-04.md).
The next planned release is **1.13.0 (15)**. Implemented changes belong in
[CHANGELOG.md](CHANGELOG.md); this backlog contains unfinished work only.

[1.13 planned release](#113-planned-release) ·
[Correctness and compatibility](#correctness-and-compatibility) ·
[Performance](#performance) · [People and access](#people-and-access) ·
[Release acceptance](#release-acceptance) · [Later and research](#later-and-research)

[App guide](Docs/DEVELOPMENT.md) · [Website backlog](../website/BACKLOG.md)

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
  - **4 November:** ten fresh-process mixed RAW stress runs (3,328 operations, both
    cache options, distinct and cloned RAFs) completed without a stall or crash; the
    October failures did not reproduce. A sustained installed-app run on a large RAW
    folder, SD-card and physical-input acceptance remain. [4 November record](Docs/BACKLOG_1.13_2026-11-04.md).
- [ ] **Remembered archives and pinned folders — Alex, 25 October 2026.** Include
  this foundation with the overnight large-folder work, ahead of later archive
  product ideas. Keep casual folder opening simple; pinning retains a folder
  across visits without moving originals or introducing a required import mode.
  - Persist pins and browsing position across relaunch. Unavailable folders stay
    pinned and slightly dimmed, with an accessible unavailable state and explicit
    unpin action. Reconnect only to the verified source, not a replacement at the
    same path; retain existing sandbox/grant recovery behavior.
  - Retain a rebuildable metadata/preview index with incremental validation of
    changes, bounded storage and work, and foreground-first scheduling. Keep
    durable decisions separate from disposable indexes and preview caches.
  - Make browsing and individual metadata/detail capabilities available as their
    evidence becomes ready, keeping incomplete results clear and positions stable.
    Preserve full validation for file operations and safe save authority.
  - Verify first visit/reopen, relaunch, pin/unpin, unavailable/reconnected source,
    changed/replaced files and cache loss/corruption on disposable fixtures. Measure
    repeated-opening benefits without treating cached metadata as current proof.
  - **25 October local build:** remembered metadata, progressive details, pins and
    independent current/viewport restoration are implemented with bounded shared
    interaction admission. The full 1,034-case suite has 46 documented skips and
    zero failures; safety is 75/75. Live-bookmark APFS detach/remount and focused
    replacement/cache/grant contracts passed. Installed-app visual/input checks are
    blocked by macOS screen lock; physical card/TCC/older-system checks remain.
    [Build, measurements and morning sequence](Docs/ARCHIVES_2026-10-25.md).
  - **25 October live follow-up:** the real ExFAT SSD's 16,975 media files passed
    read-only mounted opening/navigation checks; its actual pin survives relaunch.
    Full Photos review now opens all 80,708 items without batches. Separate iCloud
    permissions live in General Settings and persist across relaunch. Final suite:
    1,060 cases, 48 skips, zero failures; safety 75/75. Cold archive discovery and
    Photos membership/publication remain measured bottlenecks; physical SD/ExFAT
    reconnect, older-system runtime and physical frame pacing remain unverified.
    [Live measurements, final installation and limitations](Docs/SSD_PHOTOS_2026-10-25.md).
- [x] **Photos album organization — Alex, 25 October 2026.** Add confirmed
  current/selected/filtered/all reviewed items to an exact existing album, or
  create an album inside an existing Photos folder. Preserve prior memberships,
  originals and Louppe decisions. Bounded PhotoKit updates retain shared
  save/operation/Quit gates and verified partial/cancellation results. Move
  Choose Photos into Filter to keep the review view clear. Installed 1.13.0 (15),
  full suite 1,096/48 skips/zero failures, safety 75/75. Native hierarchy, exact
  confirmation and chooser handoff verified. Alex-approved live test created one
  album inside arts and verified one photo, with separate count/placement readback.
  Multi-batch/cancellation/revocation runtime gaps remain. Validation and limitations: [acceptance record](Docs/PHOTOS_ORGANIZATION_2026-10-25.md).
- [ ] **Archive folder navigation — Alex, 25 October 2026.** Show the actual
  SSD folder hierarchy as a compact collapsible native outline in Gallery and
  Grid. Implemented on 29 October 2026 and installed as the official app on
  30 October. Connected-archive opening and drive-remount checks passed on
  30 October; keep open for physical input/assistive-technology and compatibility
  acceptance. [Implementation and validation](Docs/ARCHIVE_FOLDER_NAVIGATION_2026-10-29.md).
  - **30 October review:** corrected aligned headers/native value menus, flat-folder
    layout, folder progress/Clear enablement and explicit corrupt-memory recovery.
  - **30 October night:** one-click Browser/Folders switch, Expand/Collapse All,
    resizable remembered pane, completion checkmarks, Show in Finder, T/[/]/⌘↑
    shortcuts with View menu and palette (including Next Unfinished Folder), and
    click focus returning to media. Audit fixes: unbounded live expansion,
    single-report recursive disclosure, single scope change on recursive collapse,
    first-mount reveal, deep-nesting layout and empty-folder/filter state. Physical
    input, VoiceOver and composited appearance remain open, as below.
  - Share the leading navigation pane with Gallery's thumbnail Browser via
    Folders/Browser modes; retain Info trailing and the existing Browser width.
    Include All Media, breadcrumbs, prepared item counts, and descendants by
    default, with direct-folder-only as a small context option.
  - Keep one archive session/root/save authority. Folder navigation scopes the
    prepared inventory before metadata filters, without reopening or rescanning.
    Collect a lightweight directory manifest during existing discovery so empty
    folders remain truthful; reuse exact encoded identities and native row reuse.
  - Prepare subtree postings/ranges and sort-rank lookup off-main. Do not rebuild
    paths/counts/layout per view body, rating, or folder click; ordinary navigation
    must not walk the entire archive or issue media/metadata requests.
  - Include a paired review item when either physical constituent belongs to the
    scope; deduplicate parent counts and retain pair-wide review/action semantics.
    Confirm scopes clearly as current folder/filtered/selected or entire archive;
    never let a folder view silently authorize a whole-archive operation.
  - Remember bounded per-folder current/Browser/Grid anchors and expansion state,
    scoped to verified root/directory identities. Reject stale viewport callbacks
    and replaced folders; fall back to a surviving ancestor/root. Keep decision
    sidecars unchanged. Preserve explicit Pause, permission and reconnect gates.
  - Cover empty/filter-miss states, prefix siblings, duplicate/Unicode names,
    cross-folder pairs, selection pruning, rescan/rename/undo, changed source
    identities, keyboard/accessibility, and both layouts with Info visible.
    Measure real archive navigation and synthetic large item/folder trees;
    run required keyboard/scroll/safety gates before installing an implementation.
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
  4 November: routed Review → Back → Review → Copy after cancelled, refused and
  stopped attempts, and the grant core across Back/cancel/failure/retry/revocation,
  keep leases balanced in tests. Signed-sandbox stale/revoked grants and card
  reconnect remain.
- [x] **AUD-05 — ExFAT path replacement.** Reproduced on a disposable ExFAT image
  and locally (4 November). Destination replacement rolls back; source-folder
  replacement can move a same-named foreign file into a hidden `.partial` while the
  original stays intact and the journal stays retryable. No loss or overwrite; no
  safe fix without `RENAME_EXCL`, so it is a documented residual.
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
  4 November (Xcode 27.2): the default backend matches native suite results with
  `--scratch-path` outside File Provider. Packaging and the speed runner stay native
  (release resource-bundle layout and folder-derived identifier). Test seams now
  use `LOUPPE_TEST_SEAMS`, so speed runs no longer define `DEBUG`. Remaining:
  migrate packaging to the default backend.
- [ ] **AUD-21 — Media/AV APIs.** Modernize asynchronous AV-property loading
  behind synchronous worker bridges and macOS 27 reader/player notifications.
  A UI-thread semaphore stall has not been established. Measure mixed-media scan
  throughput/cancellation and retain finite timeouts, macOS 14, bounded lanes,
  reader exit, and playback/audio cancellation tests. 4 November: player end/failure
  notifications use current names (macOS 14 safe); movie scan ~1 ms per file, so
  the 15 s bridge is not a bottleneck. The async audio reader (macOS 26+) is not
  justified by measurement.
- [ ] **AUD-18 — Volume/interruption tests.** Extend fault injection beyond the
  recorded case-sensitive APFS and detach/remount cases: ExFAT, removable/network
  volumes, interrupted operations, lid-close, and simulated power loss. ExFAT
  image creation was unavailable on the release host, not a pass. Verify no
  overwrite, accurate durability, retained recovery, and safe undo/retry. Record
  actual coverage; related performance baselines remain AUD-06/AUD-19.
  4 November: process kills before every flush, then fresh-process launch recovery,
  passed for Copy (local, APFS image) and Organize (local, APFS and ExFAT images).
  A crash during the data write leaves an unrecorded partial needing attention; the
  ExFAT move probe can leave one hidden file. Unplug, network, lid-close and power
  loss remain.
- [ ] **AUD-19 — RAW/color/GPU baseline.** Build a licensed RAW/JPEG/profile corpus
  with orientation/transparency cases. Compare preview, RAW/histogram/clipping,
  and 100% tiles to reference renders; measure Release GPU/RSS under navigation/
  zoom. One copied 84 MiB Fuji RAF now has an optimized Apple Default preview/
  histogram baseline with byte/identity checks; synthetic 100 MP tile-budget tests
  also pass. Multi-camera/RAW 9, color/reference, cold-resource and sustained
  GPU/helper-process memory acceptance remain open. Record actual corpus coverage.
  4 November: three local RAFs benchmarked with both decoders (Apple Default
  previews 0.24–0.39 s; RAW 9 0.72–1.78 s after a 5.9 s first warm-up).
- [ ] **AUD-20 — Dependencies/security.** Refresh the recorded Sparkle/Expat/
  Adobe XMP pins, patches, licenses, and official-advisory review for 1.13;
  coordinate the independent website dependency check with its release work.
  The bounded 7 October review is historical evidence, not a current security
  clearance. Investigate exposures and extend hostile-XMP tests as needed;
  parser tests cover only the reviewed subset. 4 November: app pins, checksums,
  patches and licenses verified and advisories reviewed; fixed unbounded growth of
  the XMP namespace table with hostile-input tests. Expat 2.10.0's CVEs are
  unreachable here; adopt it in the next refresh. Open: Adobe Trust Center (manual)
  and the website dependency check.

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
  4 November: fixed proven hot paths. 5k-file recovery under Decision sort
  28.5 s → 0.37 s; 100k grouped decision rating 168 → 29 ms; Select All → decision
  1.3 → 0.36 s; batch Undo 2.1 → 0.37 s. Save capture (29 ms) and camera sort were
  unchanged. Open: date-grouped projection/filter (~100–130 ms at 100k), the
  content-check queue walk in Select All, real hashing on removable media and
  mounted UI under recovery load.
  [Release measurements](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md#verification) ·
  [Quality review](Docs/QUALITY_REVIEW_1.12_2026-10-20.md) ·
  [Implemented cue-filter optimizations](Docs/Archive/2026-10-14/QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md).

### Next measurements

- [ ] **AUD-12 — Lazy routing rows.** 4 November: rows are lazy; a 10k-file
  preview opens in ~20 ms instead of ~3 s and realizes ~500 rows instead of 10–20k,
  keeping every exact path. VoiceOver and visual spacing checks remain. An outer lazy stack still contains eager
  route-file/unmatched stacks. Mount 10k+ single-route and unmatched previews;
  measure opening, realized rows, scrolling and memory. Test per-file lazy rows
  if justified, retaining every exact name/path and accessible safety detail.
- [ ] **AUD-14 — Ordinary export preflight.** Destination validation remains
  synchronous and Move queries each physical source's volume; routed/XMP planning
  already runs off-main. Count queries and measure large/local/delayed-volume
  selections. Freeze inputs for bounded off-main validation where justified;
  preserve grants, exact parent binding, progress/cancel and no early mutations.
  4 November: preflight runs off-main on frozen inputs with Cancel and stale-result
  rejection. Main-actor block: Move 10k 120 → ~8 ms; 750 ms injected slow volume
  → <1 ms. A real slow destination and the signed sandbox build remain.
- [x] **AUD-17 — Undo retention.** The limit is 500 steps, without a byte budget.
  Select All alone creates no Undo step: measure repeated Select All → decision,
  star/color edits, Clear All and Undo at 1k/10k/100k. Record retained snapshots
  and peak RSS before choosing byte-based eviction. Preserve Mixed/independent
  physical decisions, per-photo Undo and journaled operation Undo.
  4 November: 72 bytes per changed file; a 100k-pair whole-folder step is 13.7 MiB,
  so 500 steps could reach ~6.7 GiB. Decision/star/color Undo now stays within
  256 MiB (approved by Alex, 4 November): single-photo edits keep 500 steps, about
  18 whole-folder edits remain at 100k pairs, oldest dropped first. Clean Up,
  Organize and Rename steps are never dropped for memory. 10k × 500 steps:
  687 → 255 MiB retained.
- [ ] **AUD-09 — Live disk-thumbnail enforcement.** Delayed daily pruning,
  512 MiB target and 90-day age policy already exist. Test sustained writes and
  same-day launches with small injected limits, coalesced write/time maintenance,
  prune overlap and readable survivors. Measure peak overshoot and scroll latency;
  avoid per-thumbnail walks or unsupported increases to memory-cache budgets.
  4 November: live passes now enforce the limit during a session (injected limit:
  peak 8% over instead of 11×); a 20k-entry pass takes 0.24 s and disk-hit latency
  is unchanged. A long installed-app session remains.
- [ ] **AUD-10 — Abandoned EXIF detail reads.** Histogram/RAW/audio work already
  has bounded lanes and cancellable/coalesced waiters. The remaining Info detail
  reader starts detached EXIF work after dwell. Use injected slow reads during
  rapid navigation to count concurrent/abandoned readers and stale publications;
  then confirm on disposable removable/network media before changing scheduling.
  4 November: simulated slow serial reads ran 10 concurrent readers (3.08 s to
  settle); one lane with retired waiters settles in ~0.4 s. Physical removable/
  network media remain.
- [x] **AUD-11 — Cold RAW source/navigation work.** 4 November: measured, no
  change justified. The Fit recipe costs 53–76 ms with either decoder and adds at
  most 5–16 ms to the Fast Fit preview; 100% first tile 131 ms, ring 200 ms, warm
  pan 54 ms. High-resolution recipes are
  requested even for Fit dimensions; source-waiter retirement remains separate
  from image-request cancellation. Measure cold Fit/100% transitions and both decoders
  before caching dimensions or changing dwell. Test visible-first tile priority
  and mode-aware RAW prefetch as hypotheses, comparing first visible pixels and
  warm-pan latency. Keep two tile renders, 128 MiB and bounded source regions.
- [x] **AUD-13 — Copy flush costs.** 4 November: 2 of 5 media-side full flushes
  per file were redundant and are removed (journal flushes unchanged); 50 small
  files copy 0–24% faster on local and image volumes. Export Copy is not covered by the new speed
  suite. Instrument file/directory flush counts and time for small-file batches
  on local/removable storage, separating production and injected copiers. Remove
  only proven redundancy; preserve write → sync → stage → publish → directory
  sync/checkpoint and recovery after side effects.
- [ ] **AUD-15 — Within-file copy progress/cancel.** Completed-byte totals,
  throttling, rollback retraction and safe Stop already exist. A single large
  `fcopyfile` still lacks progress/cancel callbacks. Measure progress intervals
  and Stop-to-worker-exit on disposable large video/slow storage before choosing
  callbacks or chunks. Preserve identity-proven partial cleanup, metadata/forks,
  rollback and remount behavior. 4 November: a `copyfile` status callback reports
  progress every ~0.1 s on a 2 GiB file and Stop exits in 0.1–0.4 s with rollback.
  A real slow card/network volume remains.

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
  4 November: under background work Gallery input → matching thumbnail 32 ms, Grid
  74 ms (p95 126 ms); 1,000 items drained in 87 s with a 68 ms longest main-actor
  gap. Physical frames and SD-card softness remain.
- [ ] **AUD-29 — Background energy and true idle.** Measure sustained CPU/GPU,
  RSS, wakeups, and decoder/helper exit on representative large RAW folders,
  after Pause/Close and complete drain. Compare battery/AC and foreground
  responsiveness. Existing bounded scheduling, explicit Pause, and thermal/
  Low Power backoff are implemented; worker tests and synthetic CPU results do
  not establish battery drain. Preserve current/visible interest and accurate
  evidence; investigate an App Nap/inactive-window policy only after measurement.
  Keep the resource contracts in [PERFORMANCE.md](Docs/PERFORMANCE.md).
  4 November: media pipelines return to 0.1% CPU with zero idle wakeups after
  drain in the test process. Whole-app battery/AC measurement remains.

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

- [ ] **Photo location lookup — Aymeric feedback, 20 October 2026.** Add an
  explicit Open in Maps action to valid GPS coordinates in Info. Do not look up
  locations before the click. Deferred from 1.13 by Alex on 29 October 2026;
  an embedded shoot map remains a separate idea.
- [ ] **Archive gateway — Alex, 25 October 2026.** Make Louppe a familiar front
  door to existing media, with culling as one activity. Product ideas below are
  deferred; large-folder performance and remembered/pinned archives belong to
  the 1.13 plan above.
  - **Offline browsing.** Retain budgeted thumbnails/metadata for disconnected
    archives, clearly distinguish unavailable originals, and identify the drive
    needed for full detail or export.
  - **Navigation through time.** Move from years to months to shoots to images;
    retain folder navigation and stable browsing anchors.
  - **Return to meaningful places.** Saved searches and shoot shortcuts extend
    the remembered browsing positions included in the archive foundation.
  - **Collections across folders.** Gather media for prints, portfolios or other
    projects without moving or duplicating originals.
  - **Rediscovery.** Explore older favorites, overlooked shoots and unreviewed
    media using existing dates/decisions first; semantic search is later research.
  - **Editor and file handoffs.** Make revealing originals, opening an editor and
    exporting a rediscovered selection straightforward; reuse existing actions.
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
