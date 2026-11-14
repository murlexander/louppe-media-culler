# Louppe app backlog

Updated on 14 November 2026. **1.14.0 (18) is published** on GitHub, Sparkle and
Homebrew ([release record](Docs/RELEASE_1.14.0_PREPARATION_2026-11-13.md)).
**1.14.1 (19) is built from `0f8b861` but not published**: the notarized ZIP, the
signed feed and the Store package wait in ignored
`dist/release-preparation/1.14.1-19-2026-11-14/` for Alex's go-ahead. The App
Store has 1.13.2 (17), submitted for review on 8 November.
Implemented changes belong in [CHANGELOG.md](CHANGELOG.md); this backlog
contains unfinished work only.

[Release procedure](#release-procedure) ·
[Manual acceptance](#manual-acceptance-needs-hardware-or-alex) ·
[Agent work](#agent-work) · [Later and research](#later-and-research)

[App guide](Docs/DEVELOPMENT.md) · [Website backlog](https://github.com/murlexander/louppe-website/blob/main/BACKLOG.md) ·
[1.14.0 release record](Docs/RELEASE_1.14.0_PREPARATION_2026-11-13.md) ·
[1.13.1 release record](Docs/RELEASE_1.13.1_PREPARATION_2026-11-04.md) ·
[1.13 release record](Docs/RELEASE_1.13_PREPARATION_2026-11-04.md) ·
[1.13 backlog record](Docs/BACKLOG_1.13_2026-11-04.md)

Keep audit IDs stable and each task in one list. Check current code and reproduce
suspected bugs before changing behavior. Implementation alone does not close
manual acceptance. Completed outcomes stay in version history and dated reports.
Research notes, publicity plans, and CAS notes stay in Obsidian.

Closed in 1.13, with evidence in the dated records: large-folder opening, pinned
archives, Photos album organization and archive folder navigation (agent work);
AUD-05, 09, 10, 11, 12, 13, 14, 15, 17 and 21; and the agent-runnable parts of
AUD-03, 18, 19, 20, 28 and 29. Their remaining hardware and people checks are
listed once under Manual acceptance.

## Release procedure

The 1.13 and 1.13.1 releases followed these steps; reuse them for the next
version (see [UPDATES.md](Docs/UPDATES.md), [APP_STORE.md](Docs/APP_STORE.md) and
the [1.13.1 record](Docs/RELEASE_1.13.1_PREPARATION_2026-11-04.md)). A new Store
submission replaces one still in review, so coordinate with the App Store session.

1. Bump `VERSION` once, finalize `## <version> (<build>) — <date>`, push
   fast-forward to `origin` (never the `murlexander` remote) and wait for green CI.
2. Run the full suite, the window-raising suites (idle ≥ 300 s), the four install
   gates and `Tests/run_performance_checks.sh` on that commit.
3. After `source Scripts/lib/xcode_env.sh` and
   `export LOUPPE_SCRATCH_PATH="$LOUPPE_RELEASE_SCRATCH_PATH"` (the Mac's default
   toolchain is the Command Line Tools, which can't build SwiftUI macros):
   `./build_app.sh --developer-id 'Developer ID Application: SAMO DANNI EOOD (P6F95J4ZPA)'`,
   `./Scripts/notarize_release.sh --keychain-profile louppe-notary`,
   `./Scripts/prepare_update_feed.sh`, `./Scripts/verify_release.sh --publishing`.
   Keep the app, ZIP, notarization files and feed in
   `dist/release-preparation/<version>-<build>-<date>/direct/`.
4. `git tag -a v<version> <commit>`, push the tag, `gh release create v<version>
   <ZIP> --title "Louppe v<version>" --notes-file <notes> --verify-tag --latest`,
   then commit and push `appcast.xml`. Rerun the Homebrew workflow if it loses the
   push race with the feed commit. Check the public ZIP hash, feed bytes, both
   Sparkle signatures, latest-download and the six website pages.
5. Idle-gated, upgrade an isolated copy of the previous public archive with the
   retained headless Sparkle driver (`headless-update.swift`, `run-idle-checks.sh`
   in the newest release-preparation folder; update the paths) and compare `Contents/`.
6. Replace `/Applications/Louppe.app` with the released archive after the install
   gates; quit Louppe by PID only if it is running; preserve preferences.
7. In a detached checkout of the tag: `./build_app.sh --app-store`,
   `./Scripts/verify_release.sh --app-store`, `./Scripts/package_app_store.sh
   --application-identity 'Apple Distribution: SAMO DANNI EOOD (P6F95J4ZPA)'
   --installer-identity '3rd Party Mac Developer Installer: SAMO DANNI EOOD (P6F95J4ZPA)'`.
   Hand the pkg path, SHA-256, size and commit to the App Store session; Alex
   clicks Deliver in Transporter.
8. Write `Docs/RELEASE_<version>_PREPARATION_<date>.md` and update this backlog.

## Manual acceptance (needs hardware or Alex)

These are verification gaps, not evidence that each area needs new implementation.
None counts as passed until run in its stated environment. Owner: **Alex** unless noted.

### 1.15 checks

- [ ] **VoiceOver:** opening and Ready tile names, reading order and actions after scrolling; Undo after a partly failed Rename or Organize; Sort/Filter headings and focus while warning remedies stack.
- [ ] **macOS 14:** toolbar popovers, the Range/Year/Date chooser, adaptive sheet actions, inactive thumbnail selection and accessibility fallbacks.
- [ ] **Window activity and accessibility:** selection outlines while switching real windows with Increase Contrast and Differentiate Without Color, over bright and dark media.
- [ ] **Cards and folder switching:** Rename/Organize, Undo and interrupted recovery on an exFAT card; quick Finder, Dock and pinned-folder switching in the signed sandboxed build.
- [ ] **Displays and playback:** Retina/non-Retina display changes, resizing and full screen while photos decode; video full screen and Picture in Picture.

- [ ] **Photos portrait playback:** verify full top/bottom bars while playing and resizing portrait/rotated originals; live light/dark captures verify the paused first-frame fit.
- [ ] **Store Photos cache cleanup:** verify batch retirement and retry inside the sandboxed Store build; restricted-ancestor filesystem tests do not replace runtime acceptance.
- [ ] **Opening gestures:** verify native Shift/Command input through Opening-to-Ready handoff; composed tests exercise public controls and captures verify outlines.
- [ ] **Live choice menus:** open the native choices inside Sort/Filter; live captures cover the toolbar popovers themselves.
- [ ] **Shortcut keyboard map:** VoiceOver and Full Keyboard Access through the chosen-key row, **Assign…** and focus returning to the key after Clear; the open Assign menu in a live capture. Keys stay 27 points high (arrows 12), below the 36-point touch target, and the map has one Tab stop per key rather than arrow-key movement.
- [ ] **100% RAW panning:** inspect recovered sharp tiles and unavailable overlays while panning away and back on real RAW media; deterministic mounted tests cover the cancellation race.

### Hardware and environments

- [ ] **Physical storage.** SD-card and exFAT reconnect of pinned archives;
  unplug during Copy/Organize; lid-close and power loss; network volumes; a slow
  destination for Export preflight and Copy Stop; removable/network media for
  Info EXIF reads; full-file recovery hashing on removable media
  (AUD-03, 06, 10, 14, 15, 18).
- [ ] **Sustained installed-app runs.** A large RAW folder (the October RawCamera
  stall/crash did not reproduce in 3,328 test operations), a long session for live
  thumbnail pruning, and battery vs AC energy (AUD-09, 29).
- [ ] **Physical input and display.** Trackpad diagonal/momentum and touch, Dock
  dragging at cold launch and with an open folder, rename-row and Welcome edge
  dragging, physical frame pacing, SD-card preview softness, composited glass and
  the two-display transition (AUD-28).
- [ ] **Keyboards and assistive technology.** Custom shortcuts in a real shoot;
  ISO/JIS/dead-key/IME input; VoiceOver walkthroughs of the Folders outline and
  the lazy Export routing list.
- [ ] **File-tool sheets.** VoiceOver walkthrough of Export XMP retry and Rename/Organize/Export progress and results in LTR and RTL.
- [ ] **Compatibility.** Runtime on older macOS (14, 15, 26); RAW 9 on older or
  unsupported Macs, missing resources, failed downloads and compressed Fuji RAFs;
  the signed Store sandbox with stale/revoked grants and card reconnect (AUD-03).
- [ ] **Photos organization runtime.** Multi-batch, cancellation, revocation and
  process death on a real library, only with Alex's approval for library changes.
- [ ] **RAW corpus.** A licensed multi-camera RAW/JPEG/profile corpus with
  reference renders and sustained GPU/helper memory (AUD-19).

### People and accounts

- [ ] Back up the private Sparkle signing key and restore-test it.
- [ ] Clean install and real culling workflow with a tester.
- [ ] Code review by a collaborator.
- [ ] The designer's final shared app/site brand asset.
- [ ] External-editor XMP in Bridge, Lightroom Classic and darktable; separate
  RAW/JPEG conflict/reload in Capture One. Packet/resolver tests pass.
- [ ] Adobe Trust Center bulletins since October 2026; the page refuses automated
  access (AUD-20).
- [ ] Website dependency review. Owner: the website repository's release work (AUD-20).

### Distribution

- [ ] **App Store 1.14.1 (19).** Upload the package built from `0f8b861` (or rebuild
  from tag `v1.14.1`, release step 7) and submit for review (Alex, 13 November 2026); 1.14.0 had no Store build. 1.13.2 (17) was
  submitted on 8 November with automatic release; respond to any review request.
- [ ] **TestFlight — out of scope (Alex, 4 November 2026).** Every delivery shows
  ITMS-90889: the bundle has no provisioning profile. Enabling TestFlight needs a
  Mac App Store provisioning profile for `com.alexandermarkin.louppe` (team
  P6F95J4ZPA) embedded as `Contents/embedded.provisionprofile` before signing,
  `com.apple.application-identifier` and `com.apple.developer.team-identifier`
  entitlements matching it, and `package_app_store.sh`/`verify_release.sh`
  changes to accept exactly that profile (they refuse unexpected profiles today).

## Agent work

The 1.15 cycle's fixes ship as 1.14.1 (19) (Alex, 13 November 2026). Optimized
whole-job XMP measurements put ordinary Copy, Move and publication jobs within
0.69–1.17× of 1.14.0, so the census redesign below waits. The 1.15 checks above
remain unverified for 1.14.1.

- [x] **Photos staging cleanup:** yield bounded, freshly journal-checked chunks to pending file-command workers; retain recovery sources and retry markers.
- [x] **Grid follow after filtering:** pointer decisions preserve browsing position without suppressing the next keyboard follow.
- [x] **Opening modifier selection:** implicit current, range anchors and Command toggles match Ready through physical-file handoff.
- [ ] **Later — XMP job cost:** census visits grow with families × folder size (4k flat-folder Move ≈ 6.4 min, as in 1.14.0). Whole-job runner: `Tests/run_xmp_job_cost.sh`. Candidate design: one census per directory per batch with a kqueue change proof on the verified descriptor and a full re-census on any event; local APFS/HFS only. Ship only with a confirmed ≥20% 4k flat-folder gain, keeping fresh descriptor-bound checks and the between-family regression.
- [x] **Follow-up — suite isolation:** await visible Grid thumbnail pixels even after shared-cache eviction; isolate view preferences and close the host. Match the collection’s nonconcurrent document and await isolated native wheel bounds changes before mixed gestures. Keep viewport, media-read and timing assertions.
- [ ] **Follow-up — connected-drive accessibility harness:** verify capacity and Choose through system accessibility when XCTest's hosted SwiftUI tree exposes no children.

- [ ] **Later — alternate-track analysis:** the enabled default track is analyzed when disabled alternatives name it as fallback (spatial audio); language alternatives still report analysis unavailable.
- [ ] **Verify** stereo/APAC fallback analysis with a real iPhone spatial recording; sandboxed Copy from a granted external-drive subfolder; XMP planning on a volume with unknown case sensitivity.
- [ ] **Bound and drain** native video-header reads after `VideoMetadataExtractor.scanInfo`'s 15-second timeout (no hang reproduced; the inner task is cancelled, not joined, as in 1.14.0).

- [ ] **1.15 follow-ups from the 1.14.0 release (13 November 2026).**
  - `PopoverSurfaceTests` fails with ScreenCaptureKit `InvalidTransition` when it
    runs after `ConnectedDrivesTests` in one `--foreground` run (passes alone);
    restoring the activation policy alone didn't fix it.
  - The `sheet-rename-partial` and `sheet-organize-partial` capture scenarios fail
    live with the same error.
  - [x] Prevent hardened-runtime signature false failures from early-exit pipes; fixtures retain unsigned, wrong-team and missing-runtime rejection.
  - [x] Check native Filter search focus-ring coloring: retain the system keyboard-focus indicator. The macOS 27.2 SDK has no per-field color setter; suppressing/replacing the ring would lose native focus behavior.
- [ ] **AUD-06 — Remaining projection costs.** Date-grouped projection and filter
  toggles take ~100–130 ms at 100k; the content-check queue walk is ~58% of the
  363 ms Select All → decision. Measure first; preserve serial proofs, ties,
  physical/recovery maps, selection and saves.
- [ ] **Toolchain.** Move packaging and the speed runner to SwiftPM's default
  backend: handle its release resource-bundle layout (`Contents/Info.plist`) and
  folder-derived bundle identifier, then retire `--build-system native`.
- [ ] **AUD-20 — Expat 2.10.0.** Adopt it in the next dependency refresh (its four
  CVEs are unreachable in Louppe), with the vendored-file and license checks.
- [ ] **Agent tooling follow-ups (audit of 20 agent threads, 9 November 2026).**
  The entry-point scripts landed; these remain, highest value first.
  - A guarded installed-app smoke driver (screen lock, frontmost app and point
    ownership checked before every event) for folder click focus, view switching
    and playback; runs only when Alex hands over the desktop.
  - CI: skip the Swift build and tests for docs-only changes while keeping the
    credential and link checks.
  - Homebrew workflow: retry its cask push after a non-fast-forward instead of
    needing a manual rerun.
  - Move the dated `Docs/*_2026-*.md` reports into `Docs/Archive/<date>/` with
    a link pass.

## Later and research

These are deferred ideas, not committed implementation scope for 1.13.

- [ ] **Photo location lookup — Aymeric feedback, 20 October 2026.** Add an
  explicit Open in Maps action to valid GPS coordinates in Info. Do not look up
  locations before the click. Deferred from 1.13 by Alex on 29 October 2026;
  an embedded shoot map remains a separate idea.
- [ ] **Archive gateway — Alex, 25 October 2026.** Make Louppe a familiar front
  door to existing media, with culling as one activity. Product ideas below are
  deferred; large-folder performance and remembered/pinned archives shipped in 1.13.
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
  and resource costs; the explicit GPS-to-Maps action is the location lookup above.
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
- [ ] **UI review follow-ups — post-1.13, Alex, 4 November 2026.** From the
  blind screenshot review of the 1.13 UI polish; not for 1.13.
  - **Decision filter counts.** Show All/Undecided/Yes/No totals with the
    segmented control. Segments are equal width, so counts inside labels overflow
    the 340-point Filter panel at large totals; a row aligned under the segments
    fits Hindi but must follow NSSegmentedControl's app-level RTL mirroring.
  - **Denser Browser filmstrip.** About 11 frames instead of 8 (for example
    102 × 80 slots). Check that portrait tiles still fit star, label and decision
    badges, and keep the 122-point column and 36-point targets.
  - **Optional neutral-grey photo surround in light mode.** Reduces glare when
    judging exposure. Reopens the decision below to keep one neutral photo
    background; decide that first.
  - **Rejected:** stars and color under the thumbnail. It conflicts with the
    contact-sheet Grid rows, where photos rest on their filenames.

## Decisions already made

- Keep one neutral photo background; custom backgrounds are not planned.
- XMP export supports Capture One. Further integration needs a separate proposal.
- Grid keeps bottom-aligned media on the filename, contact-sheet style (Alex,
  9 November 2026). Overlays and hit tests follow the fitted media frame, not
  the square slot.
