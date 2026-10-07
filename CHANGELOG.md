# Version History

## 1.10.0 (12) — 2026-10-07

- Added Spanish, Simplified Chinese, Hindi, Portuguese, and Arabic across the
  app, including menus, Help, VoiceOver actions, and file-safety messages.
  macOS language preferences select the interface, with English fallback;
  Arabic uses right-to-left layout while shortcuts and filenames stay stable.

- Prevented oversized session saves from replacing readable ratings files, and
  kept Retry, Close, and Quit safe when saving fails.
- Checked lazy JPEG metadata against the original scanned file before and after
  reading; changed files now offer Rescan without mixing identities or decisions.
- Made scan cancellation stop the final identity pass after saved-session loading.
- Kept selected-folder access when reopening Recent folders, routing Back or
  Retry, and handing exports to background workers. Refreshed stale bookmarks
  without losing saved access.
- Refused unsupported export destinations before creating media or recovery
  records, with an APFS remedy; ExFAT source cards can still copy onto the Mac.
- Added Privacy Policy links in Help and About.
- Declared the Store category and existing local privacy API uses; verified
  Store signing identities and package payloads before replacing upload artifacts.

- Kept zoomed photos inside the Gallery pane so pinching no longer covers the Browser.

- Removed explanatory footers beneath Review and Quality Cues settings.

- Added a closable, one-time invitation for early users to email Alex their
  experience, workflow, and feature requests. Its shown status stays local.

- Added a compact RAW display choice for Apple RAW rendering at every zoom
  level, with Preview/RAW source labels and explicit preview fallback.
  The zoom slider now spans 30–400% while Fit still shows the whole photo.
- Added opt-in RAW 9 on supported macOS 27 files, bounded model preparation, explicit Retry/Apple Default remedies, and decoder-specific preview/100% caches.

- Fixed all 17 confirmed findings from the full audit: exact RAW/JPEG Clean Up
  scope, save durability and Retry, filtered selection, source-bound XMP and
  media reads, interrupted file recovery, transparent-image analysis, precise
  filters, persistent video controls, and actionable save errors.
- Made repeated-basename export planning scale with batch size; cancelled abandoned audio analysis before it delays the next recording.

- Clarified how to load saved ratings after moving or renaming a folder.
- Anchored the start-page Help button to the window's bottom-right corner.
- Added **Open in Louppe** to Finder's Services menu for a selected media folder.
- Simplified the start page. Quality thresholds are directly editable; disabling a cue retains its threshold.
- Added folder-hierarchy review in Sort, with parent folders before their
  descendants and full relative folder names in Browser and Grid.
- Added Review settings for advancement after a decision and the starting
  view, sort, and group dividers for new folders. Rating under a decision
  filter now advances without skipping the next undecided item.
- Added connected drives and cards to the compact start screen with available capacity, drive-specific folder selection, and scrollable overflow.
- Isolated the local “louppe - to review” app from the stable app's identity,
  preferences, recents, and window restoration; automatic updates stay off.

- Strengthened Move, Rename, Organize, and undo against folder-path replacement
  on standard macOS volumes.
- Moved the heavier session-save preparation off the main thread so large
  folders stay more responsive while ratings are saved.
- Improved VoiceOver labels, recovery focus, progress feedback, Reduce Motion,
  increased contrast, and long folder names without adding visible instructions.
- Added Homebrew distribution with automatic cask updates for new releases.

## 1.9.0 (11) — 2026-09-27

Read [A Proper Hello](https://louppe.eu/blog/a-proper-hello/) for an introduction
to Louppe and its approach to reviewing media.

- Made the start-page logo open [louppe.eu](https://louppe.eu/).

- Fixed the standalone video check's missing exact-path dependency so the
  complete GitHub quality workflow can run after the Copy safety changes.
- Pinned CI checkout, disabled saved credentials, added redacted credential checks and weekly action updates, and ignored local signing secrets.

- Shortened the bottom-panel save status to “Saved” or “Saving…” so it stays
  compact while ratings are written.

- Made the start window compact and accepted folder drops anywhere in it.

- Removed the explanatory text below the Info panel's star rating.

- Added read-only serif text previews for TXT, Markdown, XML, and common text
  formats, with basic Markdown formatting and clickable web/email links.

- Updated Sparkle to 2.10.0 and Expat to 2.8.5 with current security fixes.
- Made unusually complex XMP sidecars fail gracefully while keeping originals
  and unrelated metadata intact; affected media can still export without XMP.
- Bound Copy writes to the chosen folder so replacing its path cannot redirect
  exported photos; a changed destination can be selected again and retried.

- Updated the About description to say “for creators.”
- Added a working Help window, searchable shortcuts, and dismissible review tips.
- Combined filters, save status, and review completion in one bottom panel.
- Kept the bottom panel height consistent, centered photo zoom, and removed clipped QuickTime artwork from audio controls.
- Added a continuous photo zoom slider and pinch-to-zoom while retaining the
  S (100%) and A (Phone size) shortcuts.
- Fixed zoom-slider jumps and flicker when A or S returns to Phone size or Fit.
- Fixed late layout updates restarting high-resolution loading after leaving zoom.
- Fixed panning and slider response after pinching. Added drag panning and S to reset custom zoom to centered 100%.
- Replaced separate RAW + JPEG palette commands with one searchable toggle
  that explains the current mode and any temporary availability restriction.
- Made selection the default Export scope; added keeper/star quick picks, independent-rating explanations, same-drive Move guidance, and simpler editing-app options.
- Added quick decision filters, visible active filters, direct filter reset,
  a RAW + JPEG pairing choice, and preview retry and Finder actions.
- Clarified Trash No + Undecided counts, shortened first-run guidance, and added separately named local review packaging.

- Reorganized the Command Palette, improved search/aliases, showed all matching shortcuts, and added folder, search, selection, and zoom actions.
- Kept the native macOS toolbar appearance in local release builds by recording
  the current SDK version in the packaged app.

## 1.8.0 (10) — 2026-09-18

- Added ⌘F to open the Filter menu with its Search field ready for typing.

- Matched RAW + JPEG wording in Filter and the palette; kept old wording searchable.

- Simplified Organize confirmation: destinations, unchanged files, and ExFAT safety guidance.

- Added Developer ID signing, hardened-runtime, Apple notarization, stapling,
  Gatekeeper, and release-provenance checks for trusted direct downloads.

- Removed the welcome paragraph to emphasize folder selection.

- Used media folder wording for photo, video, and audio support.

- Renamed the public project/repository to Louppe Media Culler; kept Louppe app identity, preferences, sessions, and XMP namespace.

- Added Open as New Session for reused filenames with incompatible saved identities. Confirmation replaces stale decisions only; photos and videos remain untouched.

- Cached multi-selection summaries and mixed values. Inline rename follows the displayed family, cancels on content change, debounces checks, and honors Return after a successful check. Rename/Organize report partial Undo failures and singular counts correctly.

- Reported unreadable subfolders and honored cancellation during final identity checks. Similarity grouping reuses membership, counts visible members, and refreshes after reanalysis.

- Standardized popover/sheet spacing and purple primary actions. Export keeps controls visible; Rename and Organize scroll long previews and conflicts.

- Moved single-file rename into the Info filename, replacing its File-menu/palette entry. Batch rename remains in multi-selection Info and the palette.

- Added stem-only Rename with metadata/sequence batch parts and exact previews. RAW+JPEG/XMP families follow; extensions and contents stay unchanged. Collisions, false pair stems, ambiguous sidecars, and .acr companions block Rename. One ⌘Z restores names during the open session; journals support interrupted recovery and preserve ratings/current item through rescan.

- Made Organize setup and confirmation scrollable, with stable controls and wrapping/truncated paths.

- Added RAW-only/JPEG-only Trash for unambiguous pairs via Clean Up or ⌘K, within All Media/Filtered/Selected. Standalones and XMP stay untouched; the retained file stays in the session. One ⌘Z restores the batch.

- Added All Media, Filtered, and Selected Export scopes for Copy, Move, XMP, and routed Copy; decisions/stars/colors narrow them. Clean Up also uses All Media wording.

- Added in-session resume, Gallery seeks of 0.5 seconds (←/→) or 5 seconds (⇧←/⇧→), J/L navigation, K playback, and ⌘←/⌘→ speed changes. Video/audio support 1×, 1.5×, 2×, and 2.5×; Info follows native speed. Video keeps its brightness and gray surround when controls appear. The palette includes matching transport actions.

- Added per-channel dBFS meters with green/orange/red zones, audio waveform/playhead, and video resolution/frame-rate/codec filtering and sorting.

- Added a sandboxed Store product with selected-folder bookmarks, no standalone updater, and no-tracking manifest. Release checks reject missing entitlements, malformed privacy data, or Sparkle. Packaging/checklist cover Apple signing and submission.

- Added native audio review: macOS audio formats, duration/codec metadata, tiled waveforms, Gallery/Grid playback, filters/sorting, ratings, and export.

- Changed Copy/Move progress to transferred bytes, with moved/total sizes for large media.

- Added confirmed Stop Copying; unexplained cancellation is logged/reported as an app issue.

- Fixed stale-scan Clean Up warnings: report affected items, move nothing, save before rescan, and require a new confirmation.

- Fixed the Clean Up confirmation so Return activates **Move to Trash**, while
  Escape still cancels.

- Added local Duplicate + Burst Groups for verified duplicates, likely similar photos, and capture times. Filters apply; grouping never changes ratings, exports, originals, or Clean Up targets.

- Added Copy-only routing by decisions, stars, colors, file types, or media types. Unmatched media stays at source. Preflight blocks overlapping/empty routes, duplicate/unsafe folders, split XMP families, and insufficient combined space.

- Added optional ISO, shutter, and clipping cues with editable thresholds and exact values/sources. Supported RAW replaces rendered estimates after bounded Core Image analysis; X remains preview-based. Cues never affect ratings, filters, sidecars, export, or files.

- Added start-screen folder drops beside Choose Photo Folder; individual files are rejected.

- Added Open Anyway for relocated legacy sessions: bind authorization to the shown sidecar, rescan, verify filenames, and migrate recognized sessions. Changed/unrelated data stays blocked.

- Added ⌘K Command Palette for export, Organize, Clean Up, XMP, filters/sort, pairing, stars/colors, and view tools. File-changing actions retain previews/confirmations. Organize by Date Taken Only uses Full date with normal scope and confirmation.

- Added Organize Source Folder for All/Filtered/Selected media. Drag folder levels for existing folder, decision, date, stars/color, camera/lens, file/media type. Dates follow regional formats; existing hierarchy can be flattened, kept at top level, or preserved. Old/unrelated folders and files remain untouched. RAW+JPEG/XMP families move together; .acr stays put. Preflight refuses filename/sidecar conflicts without overwrite or suffixes. Journals retain original folders, recover interruptions, and support ⌘Z during the open session. ExFAT uses a tested no-overwrite Foundation fallback after a reduced-crash-protection warning; only unsupported directory sync is tolerated. Other storage/errors keep the stricter POSIX boundary.

- Fixed hotkey loss after activation, sheets, or refresh. Root-window focus no longer counts as active text editing; missing macOS window objects can fall back to the exact live window number while Louppe is active. Text, other windows, and modal UI retain input.

- Routine release checks validate the new app/ZIP without comparing it to immutable v1.7.0. Publishing still requires exact archive, version, URL, length, and signature.

- Fixed the standalone native-video Quality check so it compiles the shared
  source-organization storage-safety helper used by the file-operation journal.

## 1.7.0 (9) — 2026-08-14

- Added [louppe.eu](https://louppe.eu) to the About panel and README. PNG
  histograms now exclude fully transparent pixels instead of treating them as
  black.

- Added beta XMP interoperability; verify a small batch in your editor before a large job. Pinned Adobe XMPCore round-trips Universal, Lightroom Classic, Bridge, Capture One, and darktable packets, preserves foreign edits/keywords/namespaces, and disables XML entities. Independent per-file decisions/stars/colors support Mixed pairs, batch editing, Undo, filters/sort/groups, Info, thumbnails, VoiceOver, and 0–5 keys. Export combines rating criteria with exact counts; star/color choices are multi-select. Exact sidecar plans detect casing, Unicode, and shared-stem conflicts. XMP mode previews changed values and non-RAW limits, confirms external color-label replacement, writes atomically through bounded background lanes, rejects late edits, and reports separate Created/Updated/Current/Skipped/Conflict/Failed counts. Saving ratings never writes XMP. Copy/Move optionally include sidecars: shared packets stay when a member remains, complete-family Move transfers them, application packets copy unchanged, and destination merges leave Copy sources unchanged. Media/XMP share collision names and recovery journals; conflicts can skip sidecars while media exports. Video sidecars are excluded; .acr heavy-edit companions stay at source.

- Fresh launches show RAW+JPEG separately. Optional pairing applies review/actions to both without synchronizing divergent ratings. The explicit shared-XMP resolver chooses RAW or JPEG values for both as one Undo action, rejects stale/overlapping/unsafe requests, verifies exact paths, and requires a rebuilt plan and confirmation before file work.

- Reduced 2,000-photo XMP preflight from 14 seconds to under 0.1 seconds by indexing once; selection changes cancel stale checks. Completed Move media leaves the session even if source-sidecar cleanup needs recovery. Cross-folder pairs report both skipped shared sidecars before confirmation. Copy/Move execute the exact confirmed plan and refuse late collisions. Recovery keeps completed Move groups at destination and returns incomplete groups. Failed packet creation no longer inflates existing counts; progress totals stay stable.

- Restored full-size Grid tiles and unambiguous cross-folder RAW+JPEG pairing. Native scroll indicators track fast scrolling. Hotkeys follow the live session window across lifecycle changes. The histogram clipping control is a compact purple-on-active icon.

- Fixed Quit after card ejection: new ratings save to the identity-bound local backup without recreating paths or touching replacement cards. Unchanged sessions need no extra save. Optional repair waits but cannot block Quit; new ratings require a successful folder or backup save and show the actual failure. Ancestor identities reject replacement directories/symlinks.

- Removed persistent display/lid instructions from Copy/Move progress.

- Fixed Clean Up recovery deadlock by avoiding direct sync/search of protected Trash. Intentional Trash stays trashed; incomplete paired work keeps visible evidence. Recovery pauses new file mutations while review, ratings, saving, folder changes, updates, and Quit remain available. Reconnect appears only for unavailable drives. Keep Files As They Are retires the recovery record without deleting media. Completed Move stays at destination; partial Trash Undo preserves restored originals. Rating-save locks have finite waits.

- Legacy filename-only sessions upgrade automatically when all names remain in the original folder. Missing items or unowned backups require a decision.

- Fixed interrupted Copy from removable HDDs: verified completed/staged copies survive source loss and publish during recovery. Capacity checks cross-check false Zero KB reports. Test journals are isolated. Transactions prevent automatic sleep; after forced sleep, Copy allows one minute for the same source to remount and retries an untouched file. Provenance metadata no longer rejects completed copies. Recovery verifies interrupted staged copies byte-for-byte or removes only its identified partial artifact. Notices retain the first I/O error.

- Fixed incomplete Move recovery: verify source before removing staged files; retain complete items at destination. Copy preserves verified copies when sources disappear/change; Trash rejects replacements. Recovery checks destination identities, size/timestamps, owned temporary paths, duplicates, journal/plan semantics, aliases, and protected storage paths. Commit markers bind operation IDs and raw-plan SHA-256. Copy supports distinct hard-linked names; mutations reject ambiguous hard links. Authentic legacy journals/markers remain recoverable; regressions cover rollback crashes and altered records.

- Added a cross-process file-operation/recovery lock and single-instance declaration. Active journals block new mutations until recovery or explicit retirement. Move requires the same volume, verifies sources, and uses exclusive rename without copy-delete fallback or overwrite. Cross-volume export uses Copy.

- Journal v3 preserves raw source/destination/temporary/Trash paths and exact Unicode spelling; malformed paths fail closed. Legacy v1/v2 remains readable.

- File operations verify scan-time physical identities immediately before mutation, reconcile thrown-after-effect paths, preserve replacements, stop ambiguous batches, and retain retryable journals. Plans use resolved destinations; rollbacks refresh identities, volume UUIDs survive remounts, checkpoints verify worker results, and duplicate cleanup rechecks bytes after quarantine. Mutations reject external hard links.

- Schema-4 ratings follow verified file/folder renames and retain missing originals’ decisions until return. Replacements cannot inherit ratings; relocated sessions require an exact original. Folder identity is checked before/after scanning and before applying ratings.

- Added raw-byte session conflict checks, monotonic generations, and identity-keyed backups; newest valid generation wins. External edits remain untouched. Legacy path backups are fallback only. Schema 1–3 upgrades when all names remain; missing/unowned data needs an explicit choice. Forget Missing drops obsolete decisions only; Close/Quit preserve legacy bytes.

- Serialized sidecar and backup saves across processes under stable-folder locks and revision checks. Exact Unicode paths and unreadable backups remain intact. A backup becoming readable or disappearing while a writer waits rejects the stale save.

- Added synced plans/checkpoints, media/directory flushes, full-sync commit records, and write-sync-rename-directory-sync snapshots. Failed commit markers retain journals. Cross-directory renames sync new names first; journals retire atomically before cleanup. Bounded regular-file reads reject leaf symlinks.

- Bounded/coalesced save latency and awaited newest ratings on reopen. Quit freezes mutations until cancelled. Invalid snapshots preserve both copies and show an internal-error remedy instead of futile Retry; slow-storage tests verify deferred ratings flush.

- Pairing uses exact directory/name bytes and ASCII folding only on known case-insensitive volumes. It preserves accents/Unicode spelling, treats unknown volumes as case-sensitive, and rejects ambiguous groups. Byte-exact IDs persist through selection, ratings, migration, pairing, and caches; schema 3 rejects overlapping identities.

- Scoped hotkeys/menu actions to the live session window. Text, modal UI, other windows, VoiceOver/Fn/Help chords, and unsupported modifiers retain input. Review letters survive button focus; native controls keep Space/Tab/Escape/arrows. One monitor owns Command shortcuts; unknown keys pass through during file work.

- Grid rating clicks advance once, including rapid repeated clicks. Rating/Play dragging cannot start selection; disabled controls and VoiceOver reflect rating availability.

- Removed Grid selection delay; second clicks still open Gallery. Shift/Command-click, rubber-band, rating/play controls, and focus retain behavior.

- Restored instant view switching. v5 thumbnails bind to scan identity; legacy entries migrate only with proof, corruption self-heals, and pruning is delayed. Removed extra Grid probes and retained shared Info. Thumbnails, previews, EXIF, histograms, tiles, and video follow content revisions to reject stale same-path media.

- Guarded video callbacks against stale playback generations. Starting file operations stops playback before files move.

- Release checks independently verify loose/archived signatures, identity, Sparkle, versions, and links, then compare full Contents trees.

- Omitted nonfinite, unrepresentable, or physically invalid media/EXIF numbers instead of crashing or misleading users.

- Gallery/Grid empty states distinguish intact Move destinations from Trash. Trash Undo is limited to the open session; file actions disable without targets.

- Recorded build/test/performance/launch evidence and a prioritized safety, architecture, accessibility, testing, and release audit.

- Grid clicks select; status controls cycle Undecided/Yes/No. Ratings refresh immediately after mouse, keyboard, Clear All, and Undo without recentering.

- Double-click a photo detail for true 100%; double-click again for Fit. Background clicks do nothing; S stays centered.

- Delayed analysis for transient selections, reused Browser identities/type detection/default ordering, and updated only per-file ratings. The 100,000-item rating check fell from 20.5 ms to about 0.2 ms.

- Added photo luminance histograms, near-black/white percentages, and warnings above 10%. X overlays clipped pixels in Fit/Phone/100% without whole-image allocation; video, unsupported media, and selections omit histograms.

- Pairing reprojects without rescan and caches hidden JPEG metadata after first split. Ratings remain per physical file; Mixed decisions survive splitting and block rating-based Clean Up until resolved.

- Removed the explanation below Keep RAW + JPEG together.

- Added VoiceOver filenames, media types, ratings, selection/current state, and open/rate/select actions. Toolbar icons announce purpose and state.

- Added true source-pixel 100% on standard/Retina screens with visible tiles and a 128 MiB cache. Navigation retains relative pan; S resets the next view to center.

- Added daily signed updates, background downloads, installation on quit, manual checks, and settings. Feed/archive signatures verify before extraction.

- Copy/Move pairs share collision suffixes; incomplete Copy rolls back and Stop preserves whole pairs. Active work blocks Quit, folder changes, and update installation. Destinations inside source, unwritable folders, and insufficient space are rejected.

- Added identity-bound atomic journals for Copy/Move/Trash/Undo. Launch recovery removes owned partial copies or restores originals without overwrite; unavailable drives offer Retry Recovery.

- Adopted Swift 6 concurrency checks with explicit scanner/export/video ownership.

- Made pairing deterministic across rescans and preserved case-only names on case-sensitive volumes.

- Removed the five-level scan cutoff; skipped symlink directories to prevent loops.

- Separated selected-item and physical-file counts; paired metadata shows component and total sizes.

- Added local backups, newest-valid-snapshot loading, visible save warnings, and Retry. Corrupt, mismatched, unsafe, or unsupported sessions remain untouched.

- Folder changes, rescan, pairing, Close, and Quit await the newest ratings asynchronously. Total failure offers Retry/Cancel/explicit Quit Without Saving.

- Release builds verify app/ZIP signatures, versions, Sparkle keys/framework, feed, and extraction. Publishing also checks cryptographic signatures and enclosure data.
- Added macOS 26 CI for strict Swift 6, unit/logic/scrollbar/video checks, and packaging without private updater keys. Trash round trips remain local release checks.

- Added native video thumbnails/playback, dimensions/duration, current-item playback ownership, visible loading/failure, and Grid play/pause.
- Video uses local AVFoundation formats/codecs. Undecodable movies remain visible, rateable, filterable, and exportable with a clear message.
- Added Photos/Videos, duration, and media-type filters/sort/groups, with focused metadata, pairing, cache, and playback tests.
- Fixed player focus intercepting review keys and Grid play also rating. Arrows navigate items/rows.
- Space plays/pauses video in either view; photos retain next-item behavior.
- Kept the native video view and anchored controls stable during rapid navigation.
- Fixed Browser current-item highlights after Trash/Move by following stable IDs.

- Made Clear All, batch rating, and Undo immediate in large folders; removed per-photo full refreshes and stale badges.
- Cached visible locations for constant-time navigation, range selection, prefetch, and position display.
- Moved sort/filter/group/location logic into a tested index with stable group IDs, 1k/10k/100k baselines, and signposts.
- Moved selection rules into stable-ID state; tested filtering, anchors, batch rating/Undo, and zero-match safety.
- Rescan/pairing preserve current item and selection by file ID; Undo follows the intended item.
- Fixed stale Browser badges and current-item frames by observing session changes directly.
- Browser clicks keep scroll position; keyboard review follows the current item.
- Long Browser jumps reliably center the current item.
- Added Move alongside default Copy. Move removes items from the session, keeps files at destination, and warns that ⌘Z cannot undo it.
- Export supports any Yes/No/Undecided mix. Yes-only Copy remains default; paired files travel together.

## 1.6.0 (8) — 2026-07-17

- Expanded Sort to a popover with Sort by, Order, and Groups.
- Groups follow the sort facet; Name stays continuous. Divide into groups disables them.
- Added named group dividers to Grid and Browser.
- Dates/times follow Mac region settings, including custom dates and 12/24-hour clocks.
- Added subfolder filters with counts, None for root files, and Subfolder sorting.
- Showed Browser toggle only in Gallery; Q does nothing in Grid.
- Gallery ↑/↓ moves between items; Grid retains row navigation.
- Placed collapsed Subfolders below File types.
- Parallel EXIF reads made benchmark scans nearly 3× faster.
- Separate thumbnail decoding roughly doubled Grid loading speed without delaying Gallery.
- Removed per-key scrollbar layout and group-divider overhead.
- Repaired logic-check compilation after Sort changes.

## 1.5.0 (7) — 2026-07-15

- Expanded filtering with automatic date and exposure ranges, specific capture
  dates, aperture, shutter speed, and ISO controls.
- Added sorting by every available filter facet, with capture date as the
  default.
- Made Specific Dates open its checklist directly.
- Added All Photos, Filtered, and Selected scopes for rating-based Clean Up.
- Added a complete multi-selection summary to the Info panel.
- Refined disclosures, toolbar, thumbnails, and persistent scrollbars.
- Improved Grid scrolling performance and added confirmation before clearing
  many ratings.
- Added Cancel Scan/Escape to discard partial scans and return to start.
- Showed folder name, path, and localized running count during scanning.
- Prevented rating/selection-based Clean Up of hidden items when filters match nothing; reduced repeated filter work.

## 1.4.0 (6) — 2026-07-15

- Hardened scanning, filtering, caching, persistence, and Clean Up performance.
- Refined the metadata panel and Clean Up confirmations.
- Renamed the primary views to Gallery and Grid and simplified the toolbar.

## 1.3.0 (5) — 2026-07-14

- Added recoverable Clean Up actions that move files to the macOS Trash.
- Added multi-selection and batch rating.
- Added Undo for ratings and Clean Up operations.

## 1.2.0 (4) — 2026-07-13

- Added photo sorting.
- Added camera and lens filtering.

## 1.1.0 (3) — 2026-07-12

- Added Louppe's purple brand accent throughout the interface.
- Expanded file filtering and polished loading and About behavior.

## 1.0.1 (2) — 2026-07-12

- Replaced the app icon with the glyph-only design on a system-standard
  background.

## 1.0.0 (1) — 2026-07-12

- First public Louppe release.
- Established the native macOS photo-culling workflow and Louppe identity.
