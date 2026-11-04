# Louppe app backlog

Updated on 4 November 2026 after the 1.13 release. **1.13.0 (15) is published**
on GitHub, Sparkle and Homebrew (4 November 2026); the App Store build is
**Waiting for Review**. **1.13.1 (16) is prepared and held** until Apple approves
1.13. Implemented changes belong in [CHANGELOG.md](CHANGELOG.md); this backlog
contains unfinished work only.

[1.13.1 held release](#1131-held-release) ·
[Manual acceptance](#manual-acceptance-needs-hardware-or-alex) ·
[Agent work](#agent-work) · [Later and research](#later-and-research)

[App guide](Docs/DEVELOPMENT.md) · [Website backlog](https://github.com/murlexander/louppe-website/blob/main/BACKLOG.md) ·
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

## 1.13.1 held release

Three fixes from the 1.13 release review, each with tests: failed thumbnail-cache
deletions are counted and backed off; Photos permission text is localized in all
six languages (direct and Store builds); the XMP namespace-capacity error is
localized. `VERSION` is 1.13.1 (16) with an open CHANGELOG entry.

**Hold.** Do not tag, notarize, publish or submit 1.13.1 while 1.13.0 (15) is
Waiting for Review or In Review: a new Store submission would cancel or restart
that review.

**Release steps after Apple approves 1.13.0** (follow [UPDATES.md](Docs/UPDATES.md),
[APP_STORE.md](Docs/APP_STORE.md) and the [1.13 record](Docs/RELEASE_1.13_PREPARATION_2026-11-04.md)):

1. Confirm App Store Connect shows 1.13.0 approved or released. On a clean `main`,
   `git fetch origin`; `gh release list` shows v1.13.0 as Latest.
2. Set the heading to `## 1.13.1 (16) — <date>`, commit, push fast-forward to
   `origin`, and wait for green CI.
3. Run the full suite, the window-raising suites (idle ≥ 300 s), the four install
   gates and `Tests/run_performance_checks.sh` on that commit.
4. `./build_app.sh --developer-id 'Developer ID Application: SAMO DANNI EOOD (P6F95J4ZPA)'`,
   `./Scripts/notarize_release.sh --keychain-profile louppe-notary`,
   `./Scripts/prepare_update_feed.sh`, `./Scripts/verify_release.sh --publishing`.
   Copy the app, ZIP, notarization files and feed to
   `dist/release-preparation/1.13.1-16-<date>/direct/`.
5. `git tag -a v1.13.1 <commit> -m "Louppe 1.13.1 (16)"`, push the tag, then
   `gh release create v1.13.1 <ZIP> --title "Louppe v1.13.1" --notes-file <notes> --verify-tag --latest`.
   Commit and push `appcast.xml`. Rerun the Homebrew workflow if it loses the push
   race with the feed commit. Check the public ZIP hash, feed bytes, both Sparkle
   signatures and the latest-download redirect.
6. Idle-gated, upgrade an isolated public 1.13.0 copy with the retained headless
   Sparkle driver (`dist/release-preparation/1.13.0-15-2026-11-04/headless-update.swift`
   and `run-idle-checks.sh`; update the version paths) and compare `Contents/`.
7. Replace `/Applications/Louppe.app` with the released archive after the install
   gates pass; quit Louppe by PID only if it is running; preserve preferences.
8. In a detached checkout of the tag: `./build_app.sh --app-store`,
   `./Scripts/verify_release.sh --app-store`, `./Scripts/package_app_store.sh
   --application-identity 'Apple Distribution: SAMO DANNI EOOD (P6F95J4ZPA)'
   --installer-identity '3rd Party Mac Developer Installer: SAMO DANNI EOOD (P6F95J4ZPA)'`.
   Alex delivers the package in Transporter (Add Package → Deliver). Create
   version 1.13.1 in App Store Connect, attach build 16, answer export compliance
   (Apple system cryptography only), add What's New without Revolut/GitHub, submit.
9. Write `Docs/RELEASE_1.13.1_PREPARATION_<date>.md` and update this backlog.

## Manual acceptance (needs hardware or Alex)

Agent-runnable work is done and recorded. Each item needs its environment or
person; none counts as passed until run there. Owner: **Alex** unless noted.

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

- [ ] **Apple review of 1.13.0 (15).** Submitted 4 November 2026; Waiting for
  Review with automatic release. Respond to any review request, then run the
  1.13.1 steps above. 1.12.0 went live on the Store on 22 October 2026.
- [ ] **TestFlight — out of scope (Alex, 4 November 2026).** Every delivery shows
  ITMS-90889: the bundle has no provisioning profile. Enabling TestFlight needs a
  Mac App Store provisioning profile for `com.alexandermarkin.louppe` (team
  P6F95J4ZPA) embedded as `Contents/embedded.provisionprofile` before signing,
  `com.apple.application-identifier` and `com.apple.developer.team-identifier`
  entitlements matching it, and `package_app_store.sh`/`verify_release.sh`
  changes to accept exactly that profile (they refuse unexpected profiles today).

## Agent work

- [ ] **AUD-06 — Remaining projection costs.** Date-grouped projection and filter
  toggles take ~100–130 ms at 100k; the content-check queue walk is ~58% of the
  363 ms Select All → decision. Measure first; preserve serial proofs, ties,
  physical/recovery maps, selection and saves.
- [ ] **Toolchain.** Move packaging and the speed runner to SwiftPM's default
  backend: handle its release resource-bundle layout (`Contents/Info.plist`) and
  folder-derived bundle identifier, then retire `--build-system native`.
- [ ] **AUD-20 — Expat 2.10.0.** Adopt it in the next dependency refresh (its four
  CVEs are unreachable in Louppe), with the vendored-file and license checks.

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
