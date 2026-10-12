# Louppe Media Culler backlog

App product and engineering work lives here. Research, publicity, and CAS notes
stay in Obsidian. Latest public release: [1.10.0 (12)](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.10.0).

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
  627 tests but is deprecated upstream. Verify a supported replacement without
  downgrading the SDK; retain current native checks until then.
- [ ] **AUD-21 — Media/AV APIs.** Replace semaphore probing with structured async
  work and review macOS 27 reader/player-notification deprecations. Preserve
  macOS 14, decoder limits, cancellation/reader exit, and playback tests.
- [ ] **AUD-18 — Volume/interruption tests.** Extend fault injection on case-sensitive
  APFS, ExFAT, removable/network volumes, disconnect/remount, lid-close, and simulated
  power loss. Verify no overwrite, accurate durability, retained recovery, and safe
  undo/retry. Record actual coverage. UI: AUD-23/24; Release baselines: AUD-06/19.

Check current code and reproduce suspected bugs before changing behavior.

## Audit follow-ups

All 17 confirmed [29 September findings](Docs/Audits/2026-09-29/README.md) are
implemented; [tests/evidence](Docs/Audits/2026-09-29/implementation.md) are retained.
The tasks below are investigations, measurements, and acceptance. Keep IDs stable,
preserve originals/identity/CAS/journals, and measure before optimizing. Website
work lives in its `BACKLOG.md` (WEB-AUD-01).

### Correctness investigations — start here

- [ ] **AUD-03 — Sandbox recents/routing.** Signed Store picker, cold Recent and
  routed Copy/Back passed. Still test stale/revoked grants, card reconnect, and
  Review → Back → Review → Copy after cancellation/failure. Keep recents and
  destinations authorized for their intended lifetime; hardware gaps remain open.

### Performance — measure before changing

- [ ] **AUD-06 — Index/save capture.** Measure Release main-actor time/memory at
  1k/10k/100k files for rebuild, metadata sort, filter/group, and capture. Reuse
  unchanged ID/file maps on sort-only changes where useful. Preserve ordering,
  exact selection, shared metadata, and O(1) rating. Ready-session recovery
  scheduling now uses touched-file queues; the 12 October 100k rating check is
  0.3 ms. Also measure active cue-filter projection/coverage on large folders;
  refreshes now skip unchanged cue matches and coalesce to 100 ms.
- [x] **AUD-07 — Metadata-only bursts.** Capture requests return before identity,
  hashing or preview access; instrumented tests prove zero reads while all-mode
  analysis still invokes its workers. Generation/cancellation guards remain.
- [ ] **AUD-08 — Background groups.** Capture date grouping moved off-main after
  optimized 1k/10k/100k measurements (100k: 141/142 ms initial/interval change).
  Latest-interval, cancellation and navigation guards tested; exact/similar
  membership work remains. See the Quality Cues review record.
- [ ] **AUD-09 — Live thumbnail budget.** Coalesce utility-queue pruning by writes/
  time. Test a small size/age budget and same-day launch. Reach the target without
  per-thumbnail walks, blocking scroll, or discarding trustworthy pixels.
- [ ] **AUD-10 — Abandoned Info reads.** Measure cold removable/network reads after
  dwell. If material, bound/coalesce by content revision and cancel lost interest.
  Rapid navigation must neither accumulate readers nor publish stale metadata.
- [ ] **AUD-11 — RAW fit sources.** Measure cold navigation/scale work. Use cached
  oriented dimensions or dwell where useful; cancel uninterested waiters. Preserve
  100% inspection, two tile operations, and 128 MiB limit; avoid full-image bitmaps.
- [ ] **AUD-12 — Lazy routing rows.** Flatten route/unmatched rows into lazy elements.
  Test tens of thousands of files: construct viewport rows and retain every exact
  name/path in the safety preview without truncation.
- [ ] **AUD-13 — Copy flushes.** Measure small-file batches on local/removable storage.
  Remove proven duplicates only; preserve write → sync → stage → publish → directory
  sync/checkpoint, copier injection, and recovery after side effects.
- [ ] **AUD-14 — Export preflight.** Measure per-source volume queries on large/remote
  selections; freeze inputs and validate off-main. Retain chosen-folder access,
  progress/cancellation, and the exact binding. No early media/journal changes.
- [ ] **AUD-15 — Large-copy progress/cancel.** Test `fcopyfile` callbacks or chunks on
  disposable large videos. Show byte progress and allow safe cancellation before
  whole-file completion. Retain only identity-proven partials and rollback/remount.
- [ ] **AUD-16 — Compact JSON.** Compare bytes/save/CAS costs at 1k/10k/100k entries.
  Check the need for editable formatting before removing it. Preserve sorted keys,
  schema/lineage compatibility, and exact byte CAS.
- [ ] **AUD-17 — Undo bytes.** Measure repeated Select All/Clear All at large counts.
  If the 500-step cap retains too much, add a byte limit and clear eviction. Preserve
  per-photo undo, independent ratings, and journaled operation undo.

### Further verification

- [ ] **AUD-19 — RAW/color/GPU baseline.** Build a licensed RAW/JPEG/profile corpus
  with orientation/transparency cases. Compare preview, RAW/histogram/clipping,
  and 100% tiles to reference renders; measure Release GPU/RSS under navigation/
  zoom. Record coverage and decoder bounds. Real-camera acceptance remains open.
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
