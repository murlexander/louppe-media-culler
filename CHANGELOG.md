# Version History

Every public Louppe update is recorded here. The version and build number used
by the app are defined in `VERSION`; `build_app.sh` verifies that the marketing
version and build number have a matching entry below before it creates a
release bundle.

## 1.10.0 (12) — 2026-10-06

- Kept zoomed photos inside the Gallery pane so pinching no longer covers the Browser.

- Removed explanatory footers beneath Review and Quality Cues settings.

- Added a closable, one-time invitation for early users to email Alex their
  experience, workflow, and feature requests. Its shown status stays local.

- Added a compact RAW display choice for Apple RAW rendering at every zoom
  level, with Preview/RAW source labels and explicit preview fallback.
  The zoom slider now spans 30–400% while Fit still shows the whole photo.
- Added a persisted Apple RAW decoder choice, with RAW 9 opt-in on supported
  macOS 27 files, bounded model-resource preparation, visible retry/default
  remedies, and decoder-specific preview and 100% caches.

- Fixed all 17 confirmed findings from the full audit: exact RAW/JPEG Clean Up
  scope, save durability and Retry, filtered selection, source-bound XMP and
  media reads, interrupted file recovery, transparent-image analysis, precise
  filters, persistent video controls, and actionable save errors.
- Made repeated-basename export planning scale with the batch size and stopped
  abandoned audio analysis before it delays the next recording.

- Clarified how to load saved ratings after moving or renaming a folder.
- Anchored the start-page Help button to the window's bottom-right corner.
- Added **Open in Louppe** to Finder's Services menu for a selected media folder.
- Simplified the start page by removing the large branding block and reducing
  its top spacing. Quality cue thresholds are directly editable, and each cue
  can be switched off independently without losing its threshold.
- Added folder-hierarchy review in Sort, with parent folders before their
  descendants and full relative folder names in Browser and Grid.
- Added Review settings for advancement after a decision and the starting
  view, sort, and group dividers for new folders. Rating under a decision
  filter now advances without skipping the next undecided item.
- Added connected external drives and memory cards to the start screen, with
  available capacity and a folder chooser that starts on the selected drive.
  Five recent folders and all connected drives share a compact, aligned start
  page whose window minimum follows the space its content needs. On smaller
  displays, overflow can scroll so every drive and long message stays reachable.
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
- Pinned CI checkout, disabled saved checkout credentials, added redacted
  credential checks and weekly action updates, and ignored local signing secrets.

- Shortened the bottom-panel save status to “Saved” or “Saving…” so it stays
  compact while ratings are written.

- Made the start screen a compact window and let folders be dropped anywhere
  in it to open them.

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
- Combined filter information, save feedback, and review completion into one
  compact bottom panel without repeating the toolbar's actions.
- Kept the bottom panel height consistent across photos, video, and audio,
  centered photo zoom, and removed clipped QuickTime artwork from audio controls.
- Added a continuous photo zoom slider and pinch-to-zoom while retaining the
  S (100%) and A (Phone size) shortcuts.
- Prevented the zoom slider from briefly jumping to its minimum and flickering
  when A or S switches back to Phone size or Fit.
- Fixed a stuck loading spinner caused by late layout updates restarting
  high-resolution loading after leaving the zoomed photo view.
- Fixed pinch completion so the enlarged photo remains pannable and the
  slider keeps responding. Added click-and-drag panning and a smooth return
  from custom zoom to centered 100% with S.
- Replaced separate RAW + JPEG palette commands with one searchable toggle
  that explains the current mode and any temporary availability restriction.
- Made explicit selections the default export scope, added keeper and star
  quick picks, clarified independent review metadata and same-drive Move,
  and simplified editing-app options.
- Added quick decision filters, visible active filters, direct filter reset,
  a RAW + JPEG pairing choice, and preview retry and Finder actions.
- Clarified Trash No + Undecided with separate counts, refreshed first-run
  instructions, and added separately named local review packaging.

- Reorganized the Command Palette into predictable sections, improved search
  ranking and aliases, displayed all applicable keyboard shortcuts, and added
  missing folder, search, selection, and zoom actions.
- Kept the native macOS toolbar appearance in local release builds by recording
  the current SDK version in the packaged app.

## 1.8.0 (10) — 2026-09-18

- Added ⌘F to open the Filter menu with its Search field ready for typing.

- Matched the RAW + JPEG pairing wording in Filter and the command palette,
  while retaining the previous wording as a search term.

- Simplified the source-organization confirmation to show only where files
  will move, what stays unchanged, and how to safely move from an ExFAT card.

- Added Developer ID signing, hardened-runtime, Apple notarization, stapling,
  Gatekeeper, and release-provenance checks for trusted direct downloads.

- Removed the explanatory paragraph from the welcome screen so the folder
  action is the clear starting point.

- Updated the welcome screen and folder-related messages to use **media folder**
  terminology, reflecting support for photos, videos, and audio.

- Renamed the public project and GitHub repository to **Louppe Media Culler**
  for clearer discovery while keeping the installed app, executable, bundle
  identifier, preferences, sessions, and XMP namespace named **Louppe**.

- Reused cards and folders no longer become impossible to open when their new
  files reuse names from an identity-bound saved session. Louppe still refuses
  to apply the old ratings automatically, but now offers **Open as New Session**
  with an explicit confirmation that replaces only the stale decisions and
  leaves every photo and video untouched.

- Large multi-selections reuse their Info summary across redraws. Decision,
  star, and color controls avoid repeated selection sorting and stop checking
  once a mixed value is found. Inline filename editing always targets the
  displayed photo family, cancels when that content changes, and waits until
  typing pauses before preparing its snapshot. Return during a filename check
  now completes the rename when that check succeeds instead of being ignored.
  Rename and Organize now report partial Undo failures accurately and use
  singular file counts for single-file results.

- Folder scans now report unreadable subfolders instead of opening incomplete
  sessions, and honor Cancel during final file-identity validation. Similar-photo
  grouping avoids repeated comparisons within already-matched families and
  reuses membership across filter, sort, and rating changes. Group headers count
  only visible members, and rerunning analysis refreshes the active review.

- Standardized Filter and Sort popovers and Export/XMP dialogs with consistent
  spacing, purple primary actions, and scrollable setup and review content.
  Export keeps its header and actions visible as options grow, and single-file
  Rename now scrolls long previews and conflicts instead of crowding its buttons.

- Single-file renaming now works inline from the filename in the Info panel,
  following Finder's direct-edit pattern. The separate File-menu and single-file
  Command Palette entry are removed; batch metadata renaming remains available from
  the multi-selection Info panel and Command Palette.

- Added safe source-file renaming. The Info panel now renames one filename stem
  while preserving its extension, and File → Rename Files offers a minimal
  All/Filtered/Selected batch builder for date, time, camera, lens, original
  name, and deterministic sequence parts. Both actions are searchable through
  **⌘K**, show exact previews, keep RAW+JPEG and recognized XMP names together,
  refuse collisions, misleading new pair stems, ambiguous sidecars, and `.acr`
  companions, and restore every previous name with one **⌘Z**. Rename and undo
  use dedicated crash-recovery journals and preserve ratings and current-item
  continuity through the required same-folder rescan.

- Polished Organize Source Folder with a stable header and action bar, one
  scrollable setup area, clearer folder-level guidance, and wrapping or
  middle-truncated previews so long paths and explanations stay inside the
  sheet. The move-confirmation step now scrolls independently as well.

- Added archival RAW+JPEG cleanup. From the shared Clean Up menu or the **⌘K**
  Command Palette, photographers can move only the JPEG or only the RAW member
  of unambiguous pairs to the macOS Trash within the current All Media,
  Filtered, or Selected scope. Standalone files and XMP sidecars stay untouched,
  the retained member remains in the session, and one **⌘Z** restores the batch.

- Added All Media, Filtered, and Selected scopes to Export. The chosen scope
  now bounds regular Copy, Move, Metadata (XMP), and routed Copy operations,
  while decision, star, and color choices narrow that scope further. Clean Up
  now also calls its complete-folder choice All Media.

- Improved video review with in-session resume positions, precise half-second
  Gallery seeks on **←/→**, and five-second seeks on **⇧←/⇧→**. **J/L** always
  select the adjacent item, including after the native player has focus.
  **⌘←/⌘→** choose a slower or faster media speed, and the Info indicator now
  follows native-player speed changes instead of remaining at 1×. Video and
  audio can play at 1×, 1.5×, 2×, or 2.5×; **K** joins Space as a play/pause
  key for video and audio. Gallery video now stays at its original brightness
  when controls appear, with the same gray surround used for photos instead of
  black letterboxing. The Command Palette includes every matching navigation,
  transport, and speed action.

- Added independent live playback loudness meters to the Info panel for videos
  and audio recordings. Each channel gets green, orange, and red dBFS zones,
  while standalone audio uses its whole-file waveform and moving playhead in
  the main Gallery area. Video folders can now also filter and sort by
  resolution, frame rate, and codec.

- Added a separate Mac App Store product: it omits the standalone updater,
  uses least-privilege sandboxed access only to folders the photographer
  chooses, remembers those folders with balanced security-scoped bookmarks,
  and includes a no-tracking privacy manifest. The Store release check rejects
  a missing entitlement, malformed privacy declaration, or accidental Sparkle
  framework/link/feed. A new signed-package helper and submission checklist
  cover the remaining Apple certificate and App Store Connect steps.

- Added native audio review and playback. Common audio recordings and every
  macOS-advertised audio type now scan as an independent **Audio** media type,
  with duration, codec details, waveform tiles, Gallery and Grid playback,
  media filters/sorting, and the same safe rating and export workflow as photos
  and videos.

- Export Copy and Move progress now measures the amount of media transferred,
  rather than treating every file equally. The in-progress screen shows the
  data moved and total size, so a handful of large videos no longer make the
  progress bar misleading.

- Copy cancellation is now a deliberate two-step action. Louppe records and
  displays whether the photographer confirmed **Stop Copying**; any
  unexplained cancellation is logged and reported as an app issue rather than
  being mistaken for a card failure.

- Fixed Clean Up's stale-scan warning: if a photo file changed after scanning,
  Louppe reports only the affected review items, moves nothing, and offers a
  save-first folder rescan before the photographer deliberately confirms Clean
  Up again.

- Fixed the Clean Up confirmation so Return activates **Move to Trash**, while
  Escape still cancels.

- Added **Duplicate + Burst Groups**: an optional, local review layout for
  verified exact duplicates, conservatively labelled likely-similar photos, and
  nearby capture times. It respects the current filter and never changes a
  rating, export, original, or Clean Up target automatically.

- Added **Route copies to multiple folders** in Export. This Copy-only
  workflow previews explicit decision, stars, color, file-type, or media-type
  routes; unmatched items remain in the source folder. Overlapping/empty
  routes, duplicate or unsafe folders, split XMP families, and insufficient
  combined space on a shared destination drive are blocked before Copy starts.

- Added optional **Quality cues** for high ISO, slow shutter, and substantial
  clipping. One quiet shooting-metadata row opens exact cue values and sources;
  supported RAW files replace the immediate rendered histogram and clipping
  estimate after a delayed, bounded Core Image RAW decode. The X overlay stays
  explicitly preview-based. Adjust the three thresholds in **Louppe → Settings
  → Quality Cues**; cues never affect ratings, filters, sidecars, exports, or
  files.

- Added a drag-and-drop target on the start screen: drop a photo or video
  source folder there to open it for review, alongside **Choose Photo
  Folder…**. Individual files are politely rejected so the source always
  remains a folder.

- Replaced the opaque different-folder session warning for older sessions
  with a neutral explanation and an explicit **Open Anyway** button. Louppe
  binds that choice to the exact session file shown, rescans, verifies saved
  filenames, and then quietly migrates a recognized session to the current
  folder path; unrelated or changed data remains blocked.

- Added a searchable **Command Palette** (⌘K). It provides a quick, keyboard-
  driven route to export, source-folder organization, Clean Up, XMP metadata,
  filters and sorting, RAW+JPEG pairing, stars, color labels, and view tools.
  Existing confirmation and preview screens still guard actions that can alter
  files. **Organize by Date Taken Only…** opens the organizer with Full date as
  its sole enabled folder level for a faster chronological workflow, while
  retaining the normal scope, preview, and move confirmation.

- Added **Organize Source Folder…** to the File menu. It previews and moves
  All, Filtered, or Selected items into nested, draggable-priority folder
  levels built from the existing folder, decision, date, stars, color, camera,
  lens, file type, or media type. Date folders follow the Mac's regional and
  custom short-date formatting at full-date, year-and-month, or year
  granularity. Existing structure can be flattened, kept at top-level depth,
  or preserved in full; old and unrelated folders/files are never deleted.
  Grouped RAW+JPEG and recognized XMP files move atomically while `.acr`
  companions stay put. Exact preflight blocks filename and sidecar-family
  conflicts without overwriting or inventing suffixes. The operation uses the
  durable file journal, survives interruption conservatively, remembers the
  files' original relative folders across future reorganizations, and supports
  ⌘Z restoration during the open session. ExFAT camera cards remain supported
  behind an explicit reduced-crash-protection warning: Louppe first proves a
  disposable Foundation move refuses an occupied destination and preserves the
  same physical file identity, then uses that no-overwrite fallback for the
  journaled move, undo, and recovery. It also tolerates only the directory-sync
  operation ExFAT does not implement. Other storage and other errors remain on
  the stricter POSIX boundary.

- Fixed session hotkeys stopping after app activation, an organizer sheet, or
  a source-folder refresh when SwiftUI focused the whole window-hosting root.
  Louppe no longer mistakes selectable metadata nested somewhere inside that
  root for actively focused text. It also tolerates macOS briefly omitting the
  key-window and event-window objects when the event's nonzero window number
  still exactly identifies Louppe's live photo window. That fallback applies
  only while Louppe is active; genuinely focused text, other windows, and
  modal UI remain excluded.

- Fixed the release-quality gate so routine builds validate their own app and
  archive without comparing a freshly created ZIP to the immutable signed
  v1.7.0 download. The publishing preflight still requires the exact archive,
  version, URL, length, and EdDSA signature to match before an update can ship.
  No app behavior changed.

- Fixed the standalone native-video Quality check so it compiles the shared
  source-organization storage-safety helper used by the file-operation journal.

## 1.7.0 (9) — 2026-08-14

- Added [louppe.eu](https://louppe.eu) to the About panel and README. PNG
  histograms now exclude fully transparent pixels instead of treating them as
  black.

- Added XMP interoperability as a beta feature on top of an audited parser
  foundation. Its supported mappings and round trips are extensively tested,
  but photographers should verify a small batch in their own editing workflow
  before relying on it for a large job.
  A pinned Adobe XMPCore Objective-C++/Swift bridge now round-trips synthetic
  Lightroom Classic, Bridge, Capture One, darktable, and universal packets
  without losing unrelated edits, keywords, or custom namespaces. The proof
  rejects malformed packets and explicitly disables XML entity use. Louppe now
  also keeps independent Yes/No decisions, 0–5 stars, and five color labels per
  physical file in schema-5 sessions, including mixed RAW+JPEG states, batch
  editing, dimension-specific undo, Info-panel controls, thumbnail indicators,
  VoiceOver actions, and 0–5 shortcuts. Decision, star, and color facets now
  filter the normal session independently; each dimension can also sort and
  form stable Browser/Grid groups. Export applies decision + star + color as
  one prepared AND selection with exact item and physical-file counts. Star
  and color Export menus are true multi-selects with Unrated/None, every
  concrete value, and Mixed checked by default instead of a synthetic Any
  choice. The pinned parser now also ships as an audited source target with
  complete license resources. Typed Universal, Lightroom, Bridge, Capture One,
  and darktable mappings preserve foreign edits and keywords; exact-path sidecar
  planning detects shared-stem, casing, and Unicode conflicts; and the bounded
  actor store rejects unsafe files and external edits before a flushed,
  atomic, verified replacement. Export now includes the explicit
  **Metadata (XMP)** mode with Universal, Lightroom Classic, Bridge, Capture
  One, and darktable presets. It preflights immutable same-stem plans, warns
  about changed values and best-effort non-RAW formats, reports each conflict,
  requires explicit confirmation before replacing or removing external color
  labels, writes through three bounded background lanes, and shows separate
  Created, Updated, Already current, Skipped, Conflict, and Failed results. Stop,
  Open/Close Folder, Rescan, and Quit all await a safe atomic boundary, and a
  late external packet change is never overwritten. Ordinary session saving
  still never writes XMP sidecars. Copy and Move now conditionally include XMP:
  the option defaults from exact associated packets in the selected scope and
  respects a manual choice for the sheet lifetime. Destination stem packets are
  merged without changing Copy sources, application-private packets transfer
  byte-for-byte, shared same-stem packets stay behind when one member remains,
  and a complete-family Move transfers its packet. Media and XMP use one
  versioned crash-recovery plan with common collision naming, exact identities,
  packet digests, and interruption-tested rollback/forward recovery.
  Copy/Move now confirms that immutable plan with separate create, update,
  already-current, unchanged-application-packet, unsupported, conflict, and
  failure counts before touching files, and reports media and sidecar outcomes
  separately afterward. Conflicted shared packets are skipped without blocking
  the media export or safe application-private packets. Video sidecars remain
  outside this first XMP release and do not turn the option on automatically.
  Preflight also detects exact associated Lightroom Classic `.acr` heavy-edit
  companions and warns that Louppe will leave them untouched at the source.

- Changed matching RAW+JPEG captures to appear as separate photos on every
  fresh launch. The optional **Treat matching RAW + JPEG as one photo** setting
  remains under Filter → File types for pair-wide rating, selection, Export,
  Move, and Clean Up, and never synchronizes divergent metadata merely by
  being enabled. Eligible shared-XMP conflicts now expose an explicit resolver
  that can use the RAW or JPEG decision, stars, and color for both files. The
  batch is one undoable Louppe action, rejects stale choices, performs no file
  work itself, and discards and fully rebuilds the Export/XMP plan before a new
  confirmation. The resolver also rejects duplicate or overlapping internal
  requests before any metadata changes, verifies the displayed exact paths at
  apply time, and presents labeled decision, star, and color indicators with
  full filenames available on hover.

- Made the Export sheet respond immediately in folders that already contain one
  XMP sidecar per photo. Louppe now reads the folder listing once instead of
  rescanning it for every photo, which took 14 seconds for 2,000 photos and
  grew four times worse each time the folder doubled; the same folder is now
  checked in under a tenth of a second. Changing the decision, star, or color
  selection also stops the previous check instead of leaving several full scans
  running at once. Alongside that: a Move whose photos all transferred is now
  reported as moved even when the old sidecar beside the originals could not be
  cleared afterwards, so those photos leave the session immediately even while
  recovery remains available; a RAW+JPEG pair matched across two subfolders
  reports both skipped shared sidecars before confirmation instead of changing
  the plan after Start; Copy/Move executes the exact destination and XMP plan
  that was confirmed and fails safely if another process claims a destination
  name meanwhile; Move recovery now explains that complete groups remain at the
  destination while incomplete groups return to the source; the sidecar
  preflight no longer counts a packet it failed to create as one that already
  exists; and its progress total no longer jumps on the first update.

- Restored full-size Grid tiles after the native immediate-click surface made
  cells adopt the preview image's intrinsic size, and made pairing group an
  unambiguous RAW+JPEG match even when its files live in different subfolders.
  Fast Grid scrolling now keeps AppKit's native scrolling indicator instead of
  redrawing a custom thumb and coalesces its one-time setup, so the indicator
  tracks a quick scroll smoothly without changing the always-visible gutter.
  Session hotkeys now stay attached to the actual photo-review window across
  folder, scan, and view lifecycle changes instead of relying on SwiftUI
  appearance state that could silently leave the shortcuts disconnected. The
  clipping-warning control is now a compact half-circle icon in the
  histogram's top-right corner and turns purple while active.

- Removed the false save failure shown when quitting after ejecting a photo
  card. New ratings now save to that exact folder's identity-bound local backup
  while its volume is offline, without recreating the missing path or touching
  a different card mounted under the same name. A just-opened, unchanged
  session no longer starts another save on Quit. If optional sidecar
  maintenance is already running, Quit waits for that checkpoint, but its
  failure is nonblocking because the opened session is already a discard-safe
  baseline. New ratings still require a successful sidecar or backup save, with
  the specific remaining failure shown instead of a generic
  permissions/space/volume list. Exact ancestor identities also prevent a
  replacement directory or symlink from impersonating an ejected card path.

- Simplified the Copy/Move progress dialog by removing the persistent display
  and MacBook-lid instruction.

- Removed the recovery deadlock that could appear after a successful Clean Up.
  Louppe no longer tries to directly sync or search macOS's privacy-protected
  Trash, and interrupted intentional Trash actions stay deleted instead of
  being silently restored. Unresolved bookkeeping now pauses only new Copy,
  Move, Clean Up, and Trash undo actions; reviewing, rating, folder changes,
  saving, updating, and Quit keep working. Recovery messages mention reconnecting
  a drive only when a drive is actually unavailable, and **Keep Files As They
  Are** sets aside only the canonical recovery record without deleting any of
  its contents, so file workflows can never be locked forever. Completed Move
  items stay at their chosen destination,
  interrupted paired Trash actions retain a visible decision instead of losing
  evidence, and a partial Trash Undo keeps every successfully restored original
  rather than risking it in an unsyncable move back into protected Trash.
  Cross-process rating-save locks now have a finite wait, so another stale
  process cannot freeze Close or Quit indefinitely.

- Older filename-only sessions now upgrade quietly when every saved filename
  is still present in its original folder. Louppe asks for a decision only
  when an old item is genuinely missing or the ratings came from an unowned
  legacy backup.

- Fixed Copy exports from removable HDDs. A drive disconnect after a file had
  already copied, flushed, and passed source verification no longer turns that
  success into a batch-wide rollback. Interrupted Copy recovery now preserves
  identity-verified staged and completed files—even while the source drive is
  offline—and durably publishes verified temporary copies at their planned
  destination. Destination preflight also cross-checks macOS's ambiguous
  “Zero KB available” result against the underlying filesystem, eliminating
  false disk-full failures for File Provider-managed folders. Test stores are
  now isolated from the live Application Support recovery journal by default.
  Active filesystem transactions prevent automatic system sleep (while still
  allowing the display to turn off). If a closed MacBook lid forces sleep,
  Copy now gives the exact same source drive/file up to one minute to remount
  after wake and retries one untouched file instead of immediately abandoning
  the batch. Normal macOS metadata such as provenance no longer makes Louppe
  reject a completed copy after the bytes have arrived. If the completed-copy
  checkpoint itself was interrupted, recovery verifies the temporary copy
  byte-for-byte and keeps it; if the copy call genuinely leaves a partial,
  Louppe records that exact file identity and removes only its own artifact
  without trapping the app in repeated recovery. Export and recovery notices
  retain the concrete first I/O failure instead of reducing it to a generic
  interruption.

- Closed the audit's stop-ship recovery bug. Incomplete Move recovery now
  verifies the original at its source path before removing any staged file,
  while a fully completed item stays at its chosen destination;
  Copy preserves every verified copy when its source is missing, replaced, or
  rewritten in place; and Trash rejects same-named replacements. Recovery
  also uses checkpointed destination identities plus size and nanosecond file
  timestamps, validates exact operation-owned temporary paths, fails closed
  on ambiguous duplicates and journal-inspection errors, validates complete
  plan semantics, rejects every unsafe source/destination/temporary pathname,
  resolved alias, inode alias, and path inside journal storage, and binds every
  new committed marker to the exact operation and a SHA-256 digest of the
  immutable raw plan bytes. Copy safely supports distinct hard-linked source
  names; Move, Clean Up, and Trash undo reject such batches before mutation
  because changing one shared inode would make sibling recovery ambiguous.
  Authentic legacy markers—including empty committed v1 plans—remain
  recoverable. Deterministic regressions now execute pair rollback, cover the
  crash before a rollback checkpoint, and detect altered plans and commit
  records without touching the original.

- Added one exclusive process lock around every Copy, Move, Trash, restore, and
  launch-recovery transaction, plus a single-instance app declaration. A
  second Louppe process now leaves the live operation untouched, and a stale
  journal blocks every new file-changing transaction until recovery completes
  or the photographer explicitly keeps the files where they are. Move is
  limited to the same storage volume, revalidates the source immediately, and
  uses the OS's exclusive rename primitive so it can neither fall back to
  copy-then-delete nor overwrite a late collision; Copy remains available for
  exports to another drive or card.

- Upgraded new file-operation journals to plan v3, storing the exact raw
  filesystem bytes for source, destination, temporary, and resolved Trash
  paths. Recovery no longer normalizes composed/decomposed Unicode names;
  malformed raw paths fail closed, while existing v1/v2 journals remain
  readable. Export validation and Copy/Move also preserve the exact selected
  destination spelling instead of normalizing it to a different Unicode
  sibling.

- Bound every mutable file operation to the physical identity captured during
  scanning. Copy, Move, Trash, restore, and pair rollback now recheck each
  source immediately before touching it, reconcile thrown-after-effect paths
  by identity, preserve same-path replacements, stop the remaining batch on
  ambiguity, and retain a retryable journal. Destination preflight returns the
  exact symlink-resolved directory used by the worker. Successful app-owned
  rollbacks refresh the live identity so the next operation works without a
  rescan, and stable volume UUIDs keep recovery valid across remounts. Journal
  checkpoints independently verify the exact identity a worker just proved,
  duplicate cleanup repeats its byte comparison after an exclusive quarantine
  rename, and mutating operations reject even a single externally hard-linked
  source whose pre-checkpoint recovery would be ambiguous.

- Added schema-4 physical identities to rating entries. Ratings now follow a
  verified file or folder rename, dormant entries survive while an original
  is temporarily missing, and a returning file recovers its decision. A
  same-named replacement cannot inherit or overwrite the old rating; copied
  or unrelated relocated sidecars remain blocked unless at least one exact
  original proves the move. The opened directory is itself bound to stable
  volume, inode, and birth identity before scanning, after metadata work, and
  again before applying ratings, so swapping a card or folder at the same path
  cannot redirect a read or save.

- Added exact session-file conflict detection and monotonic snapshot
  generations. Louppe compares the raw sidecar bytes it actually read again at
  the final replacement boundary, leaves external edits untouched, keys
  backups by physical folder identity, and chooses the newest valid copy by
  generation instead of wall-clock time. Older path-keyed backups remain
  available only when no authoritative current copy exists. Filename-only
  schema 1–3 ratings upgrade automatically when every saved filename is still
  present in the original folder. Missing entries or an unowned legacy backup
  require an explicit decision: **Open Folder and Forget Missing Items** drops
  only those obsolete ratings and upgrades the remaining session, while Close
  Folder and Quit preserve the legacy files byte-for-byte.

- Serialized session persistence across Louppe processes with one advisory
  lock keyed by stable folder identity. The lock covers exact sidecar and
  identity-keyed backup revision checks, replacement or fallback, and lineage
  update; backup-only saves use the same compare-and-swap boundary. Exact
  Unicode folder spelling is retained, and an unreadable backup is preserved
  without preventing an otherwise safe sidecar save. If that unknown backup
  becomes readable or disappears while a writer waits, the stale save now
  fails closed instead of tying and outranking a newer backup-only snapshot.

- Added a shared power-loss durability boundary for session snapshots and
  filesystem transactions. Plans and checkpoints are written and synced
  before activation, copied media and affected directories are flushed before
  step advancement, commit records receive a full sync, and sidecars/backups
  use write-sync-rename-directory-sync ordering. Commit-marker failure now
  retains the active journal instead of deleting the only recovery evidence.
  Cross-directory renames flush the new name before the old name, active
  journals retire through an atomic root-synced rename before recursive
  housekeeping, and journal/session reads are bounded regular-file reads that
  refuse leaf symlinks.

- Bounded rating-save latency during continuous culling, coalesced checkpoints
  behind slow storage, and made same-folder reopen wait for the newest
  snapshot. Quit now freezes mutating commands before its final snapshot and
  releases that barrier only when Quit is cancelled. The persistence boundary
  now rejects a malformed current-schema snapshot before replacing either valid
  copy, preserves both copies byte-for-byte, and reports that internal
  inconsistency separately instead of offering a futile save retry. A gated
  regression proves slow storage automatically flushes the newest deferred
  rating.

- Made RAW+JPEG pairing fail closed on uncertain filename equality. Pairing
  now keys exact filesystem bytes per directory, applies only ASCII case
  folding when a volume explicitly reports case-insensitive names, preserves
  accents and normalization spellings, treats unknown volume behavior as
  case-sensitive, and refuses ambiguous one-to-many groups. Byte-exact,
  percent-encoded file identity now continues through pairing reprojection,
  selection, ratings, sidecar reload, and image caches. Schema 3 makes that
  encoding explicit and requires canonical IDs with no primary/paired
  identity overlap, while legacy sidecars preserve byte-distinct Unicode
  ratings during migration.

- Scoped every session hotkey and menu action to the focused Louppe session
  window while keeping the culling workflow independent of button focus.
  Sheets, popovers, other windows, text editors, selectable metadata,
  VoiceOver chords, Fn/Globe, Help, and undocumented modifier combinations
  retain their input. Clicking Rating, View, toolbar, or video controls no
  longer disables F/D/G or the other review letters, while Space, Tab, Escape,
  and arrows remain native when a control has keyboard focus. The session
  monitor is the single owner of session Command shortcuts, so duplicate menu
  equivalents cannot bypass focus rules; unknown keys are no longer swallowed
  during file operations.

- Fixed the Grid rating status control so every native activation advances
  exactly once. Rapid second and third clicks are no longer discarded as
  accidental double-clicks, dragging from a Rating or Play control no longer
  starts rubber-band selection, and both Grid and Info rating controls now
  show a real disabled state whenever the session cannot accept a rating.
  VoiceOver exposes rating actions only while rating is available.

- Removed the Grid's single-click delay. Clicking a photo now updates the
  selection immediately on mouse-up instead of waiting for the double-click
  interval to expire; a second click still opens Gallery. Shift/Command-click,
  rubber-band selection, Rating/Play controls, and keyboard focus retain their
  existing behavior.

- Restored instant Gallery/Grid switching after the cache-identity upgrade.
  The v5 thumbnail namespace binds pixels to scan-time physical identity;
  production scans deliberately rebuild older identity-less thumbnails once
  rather than risk showing a same-path replacement. Only legacy items without
  a scanned identity may promote timestamp-proven v4 or unambiguous ASCII-path
  v3 entries, and a corrupt v5 entry self-heals from a fresh source decode.
  Disk pruning runs as delayed daily maintenance rather than competing with
  launch, per-control Grid geometry probes were removed, and the shared Info
  panel survives view changes.
  Thumbnail, preview, EXIF, histogram, 100% tile, and video state now follows a
  content revision, so replacing a same-named file cannot retain stale media
  even when its item ID and modification date are unchanged.

- Generation-guarded video end/failure/status callbacks so an old A→B→A
  playback task cannot poison the replacement item. Starting Copy, Move,
  Clean Up, or restore now stops playback before any file can move.

- Strengthened release preflight so the loose and archived apps each repeat
  signature, identity, Sparkle, version, and linkage checks, then compare the
  complete `Contents/` trees before the archive is accepted.

- Sanitized untrusted photo and video numbers before converting or formatting
  them. Nonfinite or unrepresentable durations, dimensions, frame rates, EXIF
  values, shutter reciprocals, and physically nonsensical finite metadata are
  now omitted safely instead of risking a trap or misleading display.

- Added one shared, truthful empty-session state to Gallery and Grid. Moving
  every item now points to the intact export destination and never claims the
  files are in Trash or undoable; Clean Up states limit their undo promise to
  the current open session. Export and Clean Up actions are disabled when the
  session has no eligible targets.

- Added a fresh, evidence-backed codebase audit with the verified build,
  test, performance, and launch baseline plus a prioritized safety,
  architecture, accessibility, testing, and release-quality improvement plan.

- Split Grid selection from rating: clicking a photo now selects it without
  changing its decision, while a larger clickable status circle cycles
  Undecided, Yes, and No. Grid cells now observe rating changes directly, so
  their status circles refresh immediately after pointer, keyboard, Clear All,
  and undo actions. Selecting or rating a visible tile no longer re-centers the
  Grid under the pointer.

- Added location-aware Gallery zoom: double-clicking the displayed photo now
  enters true 100% zoom at the clicked detail; double-clicking it again returns
  to Fit. The letterboxed background does nothing and S keeps its centered
  behavior.

- Smoothed fast culling and large-folder opening. Transient key-repeat photos
  no longer immediately start EXIF, histogram, or clipping-warning work;
  Browser row identities are reused between structural changes; known photo
  formats avoid repeated system type detection; and the prepared session index
  reuses the scanner's exact default order instead of sorting the full folder
  a second time on the main UI thread. Rating one photo now updates only its
  tiny per-file decision record instead of copying every photo's scan metadata;
  the 100,000-item performance check dropped from 20.5 ms to about 0.2 ms.

- Added a photo-only luminance histogram to the Info panel, including
  near-black and near-white percentages with red warnings when either exceeds
  10%. Gallery clipping inspection can now be toggled with **X** or the Info
  panel button, painting the matching pixels red in Fit, phone-size, and true
  100% tiled views without allocating a whole full-resolution bitmap. Videos,
  unsupported files, and multi-selections omit the complete histogram section.

- Made the RAW+JPEG switch reproject the current session instead of rescanning
  the source folder. The first split reads metadata only from hidden JPEG
  partners, and subsequent toggles reuse it instantly. Ratings now persist per
  physical file; conflicting RAW/JPEG decisions appear as Mixed, can be
  restored by splitting again, and are protected from rating-based Clean Up
  until the pair is resolved.

- Simplified the File types filter by removing the explanatory line beneath
  **Keep RAW + JPEG together**.

- Made the main review workflow usable without color or pointer-only
  gestures. Browser and Grid items now announce their filename, media type,
  rating, current/selected state, and offer VoiceOver actions to open, rate,
  or select them. Icon-only toolbar controls also announce their purpose and
  changing state explicitly.

- Made **100%** a true source-pixel view on both standard and Retina displays.
  Louppe now keeps its fast preview visible while rendering only the visible
  full-resolution tiles, with a strict 128 MiB tile-cache limit instead of
  decoding an entire very large photo. Panning also follows the same relative
  image position while arrows, rating, Space, or the Browser move between
  files; pressing S again resets the next 100% view to the center.

- Added secure automatic updates. Louppe checks daily, downloads verified
  releases in the background, installs them safely on quit, and offers a
  manual **Check for Updates…** command plus Settings toggles for automatic
  checks and downloads. Both the update feed and archive are cryptographically
  signed, and archives are verified before extraction.

- Made Export safer for RAW+JPEG pairs. Copy and Move now reserve one matching
  collision suffix for both files, partial Copy failures roll back the first
  file, and Copy can be stopped without leaving half a pair. Active copies also
  block Quit, folder changes, and update installation until they finish or
  stop safely. Export now rejects destinations inside the reviewed folder and
  checks write permission and available space before starting.

- Added process-crash recovery for Copy, Move, Clean Up, and Clean Up undo.
  Each file change now has an atomic persistent checkpoint tied to the exact
  volume and file identity. On the next launch Louppe safely removes incomplete
  copies or restores originals before opening a folder, never overwrites an
  existing file, and offers Retry Recovery when a drive is unavailable.

- Adopted Swift 6 language mode with complete concurrency checking. Scanner
  chunk collection, export callbacks, video metadata reads, and playback
  observer cleanup now have explicit thread-safe ownership.

- Made RAW+JPEG pairing deterministic across rescans and preserved distinct
  case-only basenames on case-sensitive volumes.

- Removed the silent five-level scan cutoff. Legitimately deep photo folders
  are now scanned while symbolic-link directories are explicitly skipped to
  prevent loops.

- Corrected Info-panel counts and sizes for RAW+JPEG pairs. Multi-selection
  now distinguishes selected photos/media items from the underlying file
  count, and paired metadata shows both component sizes plus the total.

- Made rating persistence observable and recoverable. Louppe now keeps a
  current Application Support backup, loads whichever valid snapshot is
  newest, warns when a folder is read-only or neither save destination works,
  and offers an inline Retry Saving action. Corrupt, mismatched, unsafe, and
  unsupported-version session files are left untouched instead of silently
  replaced.

- Folder switching, rescanning, pairing-mode changes, Close Session, and Quit
  now wait asynchronously for the newest ratings to reach the folder or
  backup. Quit offers retry/cancel/explicit quit-without-saving choices on a
  total save failure instead of blocking the main thread.

- Added an automatic release-package preflight. Every release build now
  verifies the app and archive signatures, versions, Sparkle framework and
  security keys, feed structure, and archive extraction; publishing mode also
  verifies the feed/archive cryptographically and checks all enclosure data.
- Added a least-privilege macOS 26 GitHub Actions gate for strict Swift 6
  compilation, unit/logic/scrollbar/video checks, and release packaging. It
  requires no private updater key; real Trash round trips remain a local
  release check.

- Added first-class video review using native macOS playback. Videos now use
  their first frame as the thumbnail, always show their duration in the
  Gallery Browser and Grid, open with the full native player in Gallery, and
  play inline in Grid with a single play/pause control.
- Video support follows the movie types and codecs available to AVFoundation
  on the Mac. Recognised movies that macOS cannot decode remain visible,
  rateable, filterable, and exportable with a clear unsupported message.
- Filtering and sorting now understand mixed media: filter Photos/Videos and
  video duration, or sort/group by media type and duration. Video metadata,
  RAW+JPEG pairing, first-frame caching, and one-player-at-a-time behavior are
  covered by focused regression checks.
- Fixed video-player focus intercepting Louppe's review hotkeys. Arrow keys
  always move the current item (including Grid rows), and the Grid play/pause
  control no longer also triggers the tile's rating gesture.
- Space now plays or pauses the current video in Gallery or Grid. It retains
  its previous next-item behavior when the current item is a photo.
- Stabilized Gallery playback controls when moving rapidly between videos.
  Louppe now preserves the native player view and uses AVKit's anchored inline
  control pane instead of rebuilding a floating pane for every selection.
- Fixed the Browser's purple current-item indicator disappearing after the
  selected video was moved to Trash or moved during export. Browser rows now
  follow stable media IDs rather than reusing a removed item's numeric index.

- Clearing all ratings in a large folder is now instant. Previously every
  photo triggered its own full refresh, which could freeze the app for
  seconds and leave stale ✓/✗ badges in the Browser column. The same fix
  speeds up rating a large selection (⌘A then F/D) and undoing such a batch
  with ⌘Z.
- Keyboard navigation, range selection, prefetch, and the toolbar position no
  longer scan the full visible photo list on every step. One cached location
  map is rebuilt with filtering/grouping, keeping those interactions constant
  time in very large folders.
- Moved session sorting, filtering, grouping, and item/location lookup into a
  pure tested index behind the existing app state. Grid groups now retain
  stable identities without allocating an enumerated copy on each render, and
  1k/10k/100k baselines plus Instruments signposts make future performance
  work measurable.
- Moved range, edge, command-click, rubber-band, filter, and rescan selection
  rules into a pure stable-ID state behind the session controller. Expanded
  app-level tests verify selection filtering, anchor movement, batch
  rating/undo, and the zero-match safety boundary.
- Rescanning or rebuilding RAW+JPEG pairing now preserves the exact current
  photo and multi-selection by stable file ID even when array positions
  change. Rating undo also follows the intended photo by ID rather than an old
  numeric position.
- Fixed the Browser column freezing its contents in long sessions: thumbnails
  could keep old ✓/✗ badges (most visibly after Clear All Ratings) and the
  purple current-photo frame could sit on the wrong thumbnail until the view
  was switched to Grid and back. Each strip row now tracks the session
  directly, so badges and the frame always match what's on screen.
- Clicking a thumbnail in the Browser no longer scrolls the strip to center
  that thumbnail — the list stays put under the cursor. Keyboard navigation
  (F/D, arrows, Space) still follows the current photo as before.
- After a long jump (for example F/D advancing to a far-away undecided
  photo), the Browser now lands centered on the current photo reliably
  instead of stopping slightly off-target in big folders.
- The Export dialog now offers two modes: **Copy to…** (the previous
  behavior) and **Move to…**, which transfers the files and removes those
  photos from the session. Moved files stay safe at the chosen destination,
  but a move isn't undoable with ⌘Z — the dialog warns before it happens.
- Export is no longer keepers-only: the Yes / No / Undecided counts in the
  dialog are clickable tiles, so any mix of ratings can be exported. Copy
  with only Yes selected stays the default, and RAW+JPEG pairs still travel
  together.

## 1.6.0 (8) — 2026-07-17

- The toolbar sort menu is now a full popover matching the filter's look, with
  **Sort by**, **Order**, and a new **Groups** section.
- Group division now follows the active sort option: sorting by camera divides
  the photos into camera groups, by subfolder into subfolder groups, and so on
  (Name sorting shows one continuous list). A **Divide into groups** checkbox
  turns the division off entirely.
- Group dividers now carry the group's name: the Grid and the Browser column
  show the date, camera, lens, or other group label at the start of the line,
  with the divider continuing after it.
- All dates and times shown in the app (info panel, selection summary, filter
  day list, group dividers) now follow the Mac's Language & Region settings,
  including the custom **Date format** picker and the 12/24-hour clock.
- Added subfolder support to filtering and sorting: the filter popover lists
  every subfolder of the opened folder (plus **None** for files lying directly
  in it) as checkboxes with photo counts, and the sort menu gains a
  **Subfolder** option between Name and File type.
- The Browser toggle now appears in the toolbar only while the Gallery view is
  showing, and the Q shortcut is ignored in the Grid view — the Browser column
  exists only in the Gallery.
- In the Gallery view, ↓ now steps to the next photo and ↑ to the previous
  one, mirroring the top-to-bottom order of the Browser column. The Grid view
  keeps its row-by-row ↑/↓ movement.
- In the filter popover, **Subfolders** now sits below **File types** and
  starts collapsed.
- Opening a folder is much faster: photo details (EXIF) are now read on
  several CPU cores at once instead of one file at a time — nearly 3× quicker
  in benchmarks, with more expected on large cards.
- The Grid view fills its thumbnails about twice as fast (thumbnails got their
  own decoding lane), and the big Gallery photo no longer waits in line behind
  thumbnail work.
- Removed hidden per-keystroke layout work in the always-visible scrollbars
  and a small group-divider slowdown introduced by the sort update, keeping
  rating and navigation snappy in large sessions.
- Repaired the logic-check script, which had stopped compiling after the sort
  update.

## 1.5.0 (7) — 2026-07-15

- Expanded filtering with automatic date and exposure ranges, specific capture
  dates, aperture, shutter speed, and ISO controls.
- Added sorting by every available filter facet, with capture date as the
  default.
- Made Specific Dates reveal its checklist immediately, without a redundant
  nested disclosure.
- Added All Photos, Filtered, and Selected scopes for rating-based Clean Up.
- Added a complete multi-selection summary to the Info panel.
- Refined disclosure behavior, toolbar organization, thumbnail rounding, and
  persistent Browser and Grid scrollbars.
- Improved Grid scrolling performance and added confirmation before clearing
  many ratings.
- Added a Cancel Scan toolbar control and Escape shortcut that stop the active
  folder scan, discard partial results, and return to the start screen.
- Added the scanned folder's name, full path, and localized running photo count
  to the scanning window.
- Hardened zero-result filtering so hidden photos cannot receive ratings or be
  passed to selection-based Clean Up, and reduced redundant filter work while
  typing camera-setting ranges or rebuilding folder metadata.

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
