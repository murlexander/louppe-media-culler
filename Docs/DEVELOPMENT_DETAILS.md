# Development details

Subsystem rules linked from [AGENTS.md](../AGENTS.md). Read the relevant sections
before editing; update them when behavior changes. Project-wide rules stay in
`AGENTS.md`.

## Architecture map

`LouppeApp` creates one `SessionStore` (`@MainActor ObservableObject`) and passes
it to every view.

| File | Responsibility |
|---|---|
| `Sources/Louppe/LouppeApp.swift` | `@main`, window scene, menu-bar commands |
| `Sources/Louppe/SessionStore.swift` | Main-actor ratings/counts, undo, navigation, selection, prepared filters/sort/day groups, file operations, save snapshots, recents |
| `Sources/Louppe/ReviewPreferences.swift` | App-domain review defaults; independent of folder session snapshots |
| `Sources/Louppe/ConnectedDrives.swift` | Read-only physical-drive discovery, capacity snapshots, mounted-device identity, and welcome-screen refresh lifecycle |
| `Sources/Louppe/PreparedSessionIndex.swift` | Pure item-ID/sort/filter/group/header/location maps projected by `SessionStore`; owns stable Grid group identity and performance signposts |
| `Sources/Louppe/SelectionState.swift` | Pure stable-ID/index selection authority: range, edge, toggle, rubber-band, filter intersection, and generation remapping; projected by `SessionStore` |
| `Sources/Louppe/SessionRatingRecovery.swift` | Bounded full-content fingerprints, fresh descriptor/identity validation, and saved-decision recovery policy |
| `Sources/Louppe/SessionPersistence.swift` | Folder identity, typed sidecar/backup outcomes, process locks, raw-byte CAS, generations, schema validation, durable actor writes |
| `Sources/Louppe/DurableFileIO.swift` | POSIX write/sync/rename/directory-sync boundary shared by sessions and file-operation journals |
| `Sources/Louppe/FileOperationJournal.swift` | Per-file durable Copy/Move/Rename/Organize/Trash/undo checkpoints, stable file identity, and launch recovery |
| `Sources/Louppe/CleanUpWorker.swift` | Background Trash/restore file loops, progress throttling, pair rollback, O(n+k) restoration merge |
| `Sources/Louppe/FolderScanner.swift` | Recursive scans, deterministic volume-aware RAW+JPEG pairing, lazy JPEG metadata, pairing projection, chronological sort |
| `Sources/Louppe/SessionOpeningWorker.swift` and `SessionOpening*` helpers | Cancellable complete inventory/metadata preparation, saved-decision restoration, facets/index preparation, and opening-stage measurements before session publication |
| `Sources/Louppe/ImagePipeline.swift` | ImageIO decoding, AVFoundation first frames, thumbnail memory/disk caches, prefetch |
| `Sources/Louppe/HistogramPipeline.swift` | Bounded photo-only luminance analysis plus cached Fit/phone-size clipping-warning previews |
| `Sources/Louppe/CameraQualityWarnings.swift` | Pure independent ISO/shutter/near-white/near-black rules and exact evidence text |
| `Sources/Louppe/QualityCueAnalysis.swift` | Small revision-bound numeric cue summaries and honest coverage states; reuses histogram workers |
| `Sources/Louppe/DuplicateBurstAnalysis.swift` | Local, bounded exact-duplicate, likely-similar-preview, and capture-burst analysis for review-only groups |
| `Sources/Louppe/HighResolutionImagePipeline.swift` | Lazy Core Image regions and bounded 100% tiles |
| `Sources/Louppe/ZoomViewport.swift` | Pure backing-scale/normalized-position geometry and persistent non-published 100% viewport state |
| `Sources/Louppe/TextPreviewLoader.swift` | Bounded actor-based Unicode text loading and native Markdown parsing for the current document |
| `Sources/Louppe/Views/TextPreviewView.swift` | Read-only serif NSTextView with selection, scrolling, and web/email links |
| `Sources/Louppe/VideoSupport.swift` | Native movie metadata loading, duration formatting |
| `Sources/Louppe/VideoPlaybackController.swift` | One shared AVPlayer for Gallery/Grid playback |
| `Sources/Louppe/MetadataExtractor.swift` | EXIF reading for capture dates + info panel |
| `Sources/Louppe/ExportManager.swift` | Export dialog state machine: destination prompt, copy/move orchestration |
| `Sources/Louppe/ExportWorker.swift` | Background copy/move loops, pair-wide collision planning and rollback |
| `Sources/Louppe/ExportDestinationValidator.swift` | Export preflight: source-tree exclusion, destination permission and capacity |
| `Sources/Louppe/SourceOrganization.swift` | Pure source-folder hierarchy/rename, exact-path collision/XMP-family preflight, and preview planning |
| `Sources/Louppe/SourceOrganizationWorker.swift` | Journaled source-folder moves/renames, exact directory creation, and in-session undo restoration |
| `Sources/Louppe/FileRenaming.swift` | Pure filename recipes, preferred-date/fixed-time rendering, sanitization, sequencing, and source-rename configuration |
| `Sources/Louppe/Models.swift` | Physical `PhotoFile` records, projected `PhotoItem` groups, ratings/filter models, sidecar codables |
| `Sources/Louppe/Views/RootView.swift` | Phase switch (welcome/scanning/session), `Color.appBackground` |
| `Sources/Louppe/Views/WelcomeView.swift` | Start screen + cancellable scanning progress |
| `Sources/Louppe/Views/SessionView.swift` | Toolbar (incl. sort menu), export sheet, shared trailing Info panel, **all single-key hotkeys** (`handleKey`) |
| `Sources/Louppe/Views/FilterView.swift` | Toolbar filter popover: metadata search, date range, subfolder / file-type / camera / lens toggles |
| `Sources/Louppe/Views/GalleryView.swift` | Gallery media layout: Browser / photo |
| `Sources/Louppe/Views/BrowserView.swift` | Optional vertical thumbnail Browser with day separators |
| `Sources/Louppe/Views/GridView.swift` | Grid view, day-grouped rows, click-to-rate, rubber-band selection |
| `Sources/Louppe/Views/MetadataPanel.swift` | Info panel (filename header, photo histogram, camera, exposure row, fields) |
| `Sources/Louppe/Views/HistogramView.swift` | Photo-only histogram, RAW source tag, and Gallery clipping toggle |
| `Sources/Louppe/Views/CameraQualityWarningsView.swift` | Shared cue evidence in Info/tile popovers, accessible tile glyphs, and independent settings |
| `Sources/Louppe/Views/ThumbnailView.swift` | Async thumbnail tile + rating badge |
| `Sources/Louppe/Views/MediaTileAccessibility.swift` | Shared VoiceOver descriptions and open/rate/select actions for Browser/Grid tiles |
| `Sources/Louppe/Views/FullImageView.swift` | Large photo with fit / 100% / phone-size zoom |
| `Sources/Louppe/Views/ActualSizeImageView.swift` | Persistent AppKit scroll view that displays source-pixel tiles and carries pan position across photos |
| `Sources/Louppe/Views/VideoPlayerView.swift` | Native AVPlayerView bridge for Gallery/Grid playback |
| `Sources/Louppe/Views/ExportView.swift` | Export dialog (mode + rating tiles → progress → done) |
| `Sources/Louppe/Views/OrganizeSourceView.swift` | Source-folder scope, draggable folder levels, preview, confirmation, progress, and outcome sheet |
| `Sources/Louppe/Views/RenameFilesView.swift` | Single-family and metadata-batch source rename preview, confirmation, progress, and outcome sheet |
| `Tests/PerformanceChecks/main.swift` | Dependency-free search, ordered persistence, restoration-merge, and export copy/move regression checks |

Read `Docs/PERFORMANCE.md` before changing concurrency, caches, filtering, or Clean Up.

## Apple Photos sources

`PhotosLibraryService` owns PhotoKit off-main. One lazy `PHFetchResult` holds
the chooser selection, and one pinned result retains the active batch's stable
membership while the chooser changes. Only the selected `IndexSet` (50–1,000
assets) becomes Swift objects. Albums and inclusive calendar dates narrow the
query; Last Week and Last 7 Days use the Mac’s calendar/time zone, including
DST boundaries. Batch controls preserve Gallery/Grid and review sorting.

`prepare` now returns a complete stable asset inventory, with resource names,
Photos dates and restored decisions, before requesting any image bytes.
`PhotosReviewBatch.reviewItems` bypasses folder discovery, EXIF enrichment and
file-identity validation in `SessionOpeningWorker`. Its synthetic URLs are
cache/display keys, never evidence that a local original exists. The normal
save-before-switch and publication generation barriers still own transitions.
Legacy fully staged test batches continue through the folder worker.

`PhotosMediaSession` owns the batch's representation requests, a strict 96 MiB
pixel LRU, four image lanes and 64 pending waiters. Gallery requests a
viewport-sized image capped at 2,048 pixels; realized thumbnails request their
rendered size, capped at 1,024 pixels (384 for small tiles). A replaceable neighborhood preheats at most eight local thumbnails.
Requests use `.unadjusted`/`.aspectFit`, exact target sizing and asynchronous
cancellation, including callbacks before request-ID assignment. A local
high-quality attempt precedes authorized network access; a smaller local fast
representation can still work offline. Gallery labels its actual dimensions
and hides preview pixels while original detail is requested. No review preview
is presented as 100% original detail. The image cache and all view state belong
to this batch/revision, not an asset ID alone.

Review-image and original iCloud consent are separate, initially off. Choosing
review downloads does not authorize resource streaming. PhotoKit may itself
fetch source bytes to make an uncached representation: target size bounds
requested pixels, not network-transfer bytes. Per-item loading, cloud/error,
retry and original progress remain visible. Failed/cancelled preparation keeps
the outgoing review; closed batches cancel admitted media work.

Original detail/RAW rendering and original video playback acquire a private
file lease. `PhotosResourceTransfer` streams the primary `.photo`/`.video`
resource, one request at a time, within the unchanged 5 GB aggregate staging
ceiling. Resource requests have separate network consent and real cancellation.
Leases retain files through rendering/Copy and remove them on release. Live
Photos use their still resource; RAW+JPEG assets use Photos' primary original.
Preview review is unadjusted; no edited rendition silently replaces it. Hidden
assets retain PhotoKit's exclusion default. Original-only EXIF/size/quality
checks report unavailable, and exact/similarity analysis cannot sweep the chunk.
Capture grouping can use Photos dates without original I/O.

`PhotosReviewDecisions` persists Yes/No, stars, colors, and their timestamps in
Application Support, keyed by Photos local identifiers. Saves share the existing
coalescing, generations, Retry, Close, and Quit authority; a failed decision
checkpoint blocks discard. A bounded read, cross-process lock, fresh merge, and
durable atomic replacement preserve other batches and refuse corrupt/unknown
schemas. Writer/access sequences reject late older checkpoints. Cache physical
identities and fingerprints do not own Photos decisions.
File hashing for folder-decision recovery is skipped in Photos mode.

One-destination Copy remains available. `PhotosCopyWorker` stages, validates,
passes one leased exact original to the journaled `ExportWorker`, then releases
it before the next asset. Existing names are collision-suffixed, completed
copies survive later failure/cancellation, and progress counts originals with
per-item download progress. Total bytes are unknown upfront; capacity is checked
again for each staged original. Photos routing Copy and XMP generation are
unavailable; representation pixels can never enter an export plan.
The central capabilities and execution gates
refuse Trash, Move, Rename, Organize, and XMP publication for Photos batches.
No Photos library change request is issued. Previously active cache media is
retired only after the outgoing decision barrier; abandoned marked UUID cache
folders are removed at the next preparation. At most the active and preparing
batch are retained during normal operation; failed filesystem cleanup remains
best effort. Permissions require `NSPhotoLibraryUsageDescription` and the Photos entitlement
in every bundle, including the hardened-runtime Developer ID product. Direct
builds use `Louppe.direct.entitlements`; Store builds retain their sandbox and
selected-folder entitlements in `Louppe.entitlements`.

## File operations and recovery

- Export preflight and worker preparation read exclusive-rename capability from
  the bound parent descriptor. Valid unsupported capability refuses Copy/Export
  Move before media or journals exist; unknown capability keeps the checked
  syscall boundary. ExFAT-source → APFS Copy remains supported. Source
  Organize/Rename keep their tested reduced-durability fallback.
- Route drafts retain chosen-folder access through Back and retryable errors.
  Detached preflight and workers hold separate leases until exit. Removal,
  replacement, reset, and dismissal release draft leases. Recent/recovery
  existence checks and bookmark refresh run with access active; failed resolution preserves
  stored evidence, and stale bookmarks refresh when possible.
- Copy, Move, Rename, Organize, Trash, and supported undo activate a
  `FileOperationJournal` before any filesystem change. Recovery verifies physical
  identity, never overwrites or infers ownership from names, and keeps unresolved
  journals retryable. **Keep Files As They Are** atomically sets aside only a
  canonical Louppe journal as `.forgotten`; it preserves contents and media and
  refuses arbitrary `.operation` files.
- Launch Trash recovery commits forward; only explicit in-session Undo restores
  media. macOS owns Trash durability: opening/syncing `.Trash`/`.Trashes` is never
  required for success. Partially checkpointed paired Trash remains nonblocking
  attention. Partial Trash Undo keeps restored originals, rescans, and reports
  failure; never move them back into protected Trash to force pair atomicity.
  Completed Export Move items stay at their destination; incomplete pairs roll back.
- Plan-v3 paths carry exact filesystem bytes through validation, target
  construction, and recovery. Never normalize them through Swift strings; retain
  v1/v2 compatibility. A staged Copy is written, flushed, and source-verified.
  Recovery preserves staged/completed copies without the source volume and
  publishes verified temporaries only by exclusive rename to the planned path.
  Operation-created copy checks use volume/inode/birth/size/mtime, excluding
  provenance-related ctime changes; source checks include ctime. If `copyItem`
  throws, checkpoint a partial's identity before removal. Never delete an
  unrecorded partial by pathname. Before publishing a complete pre-staged
  temporary, revalidate the exact source and compare every byte.
- On the exclusive-POSIX path, Move, Rename, Organize, and undo bind source,
  temporary, and target parents to open descriptors per active file. Generated
  Move XMP uses those bound writes/publication. Parent replacement stops work
  without redirecting files; changes after a rename retain an ambiguous journal.
  ExFAT's Foundation fallback and launch recovery remain path-based with identity
  checks. Reproduce a remaining risk before broadening those paths.
- Clean Up snapshots on `SessionStore`, runs file loops in `CleanUpWorker`, then
  applies once on `SessionStore`; Export uses `ExportWorker`. Keep
  `trashItem`/`moveItem` loops off-main. During `isCleaningUp`, block item-index
  mutations, folder switching, and Quit to preserve rollback and ⌘Z.
- `activeFileOperation` is the sole authority for Clean Up, Copy, Move, Source
  Rename, and Source Organization. It blocks switching, rescan, undo, update
  checks/installation, and Quit until completion or Copy's current-pair rollback.
  It holds the idle-system-sleep assertion; recovery holds it while reconciling.
  Display sleep stays enabled; lid-close sleep cannot be blocked. Copy waits
  boundedly for the same source identity and retries only if its temporary is
  absent. Never retry over or delete an ambiguous partial; recorded partials use
  only the journal's two reserved paths. Add no independent in-flight flag.
- Active recovery excludes new work. An unresolved journal awaiting attention
  blocks only Copy, Move, Rename, Organize, Trash/Clean Up, and Trash undo.
  Review, ratings, navigation, folder open/close/rescan, saving, updates, and Quit
  remain available.
- Journal media and artifacts must be regular files. Identity capture supports
  directories; blocking opens use `O_NONBLOCK` before type checks. Remove started
  generated partials only when their inode was durably recorded. Completed XMP
  retirement recognizes either reserved cleanup path; ambiguity preserves files.
- Organize checks scanner-visible names and hidden/package flags in preview and
  before moving. Sanitize generated hidden/package-like components and refuse
  unsafe explicit containers.

## Session persistence

- Schema 7 adds optional full-byte SHA-256 fingerprints and separately validated
  recovery records. Same-name replacements open unrated; verified decisions
  still restore. Archive meaningful conflicts only after rename matching has
  consumed all exact originals. Empty old decisions require no attention.
- Recovery records survive autosave/reopen and explicit resolution as history,
  separately from the current file at the same path. Older app versions refuse
  schema 7 rather than silently dropping that history. Use disposable copies
  for the combined local review build.
- An unambiguous same-relative-path full-content match can restore an untouched
  current file. Older entries without fingerprints require explicit selected-file
  confirmation and a fresh regular-file/scan-identity check. Current decisions,
  stars, colors and change timestamps prevent either route from overwriting
  newer review work. Copies do not inherit old organization-origin paths.
- Recovery targets and record lists use the physical-file index, rebuilt on
  structural changes. A unique returning physical original can recover history
  under a new name; copied-and-renamed discovery remains separate work. Queue
  only touched files for later fingerprints. Clear All records its explicit
  clear timestamp on affected physical files so recovery cannot undo it. Undo
  to empty current metadata keeps pending older decisions as resolved history;
  the original undo snapshot and its timestamps remain unchanged.
- Fingerprints are included only against the snapshot's exact physical identity.
  New fingerprints are optional checkpoints, not new rating generations; they
  must not make a durable decision look unsaved or add a clean Quit dependency.
  Actual restored decisions advance the existing dirty/save authority.

- Saves use compact sorted JSON, preserving deterministic keys and every schema
  field/history. Exact bytes still own CAS lineage.
- Decoding, CAS revision reads, and encoding share a 512 MiB ceiling.
  `snapshotTooLarge` fails before locking or changing either copy. Retry keeps
  its sequence/generation; dirty Close/Quit remains unsafe.
- A visible rename after sync failure establishes observed CAS lineage only.
  Under the same transaction lock, validate exact bytes/folder before and after
  a full parent-directory sync, or secure a fully synced backup. Otherwise keep
  the live generation dirty, refuse discard, and allow the same save sequence
  to retry. Typed `DurableFileIO` errno failures retain permission, space,
  unavailable-device, and busy remedies in the warning.
- Sidecar failure may use the current Application Support backup. If both fail,
  keep the session open and show Retry Saving. Folder/session transitions and
  Quit await safety asynchronously. Never use silent `try?` persistence or a
  main-thread semaphore.
- Capture `SourceFolderIdentity` before scanning; recheck after scanning/read.
  Every save carries its `AccessContext` and compares exact raw sidecar revision
  immediately before replacement. Stable directory identity keys backups;
  actor-assigned monotonic generations order snapshots. Path and `scannedAt`
  never own current lineage.
- One stable-folder advisory lock spans sidecar/backup revision checks,
  replacement/fallback, and lineage update. Give acquisition a short finite
  deadline: contention is retryable and cannot freeze Close/Quit.
- If a disconnected volume removes the exact opened path, advance only its
  identity-keyed backup under that lock, retaining the last proven sidecar
  revision. Never recreate the path. Preserve every ancestor's exact `lstat`
  identity: replacement folders, symlinks, non-directory ancestors, and permission
  ambiguity return `sourceFolderChanged` without changing either lineage.
- A remounted UUID-owned source may change `st_dev` only after full recapture
  proves the same UUID/folder. Absent or unreadable final folders keep strict
  device checks, preventing another card from appearing to be the missing source.
- After possible sidecar commit immediately before disconnect, adopt only that
  access's exact marked revision on reconnect; an older backup cannot bypass CAS.
  After backup rename/sync failure, Retry may adopt only exact desired bytes.
- Quit awaits active checkpoints and compares live change generation with each
  successful sidecar/backup request's captured generation. A newly opened
  generation-zero session is safe to discard; optional repair failure does not
  block Quit. Clean sessions start no I/O. Backup-only success is safe to quit
  and remains manually retryable for sidecar repair.
- Read obsolete path-keyed backups only when both current copies are absent.
  Schema 1–3 ratings migrate automatically only when every saved filename exists.
  A folder-owned legacy sidecar with a different recorded path requires **Open
  Anyway** for that exact revision, followed by rescan and filename checks.
  Unowned legacy backups or missing entries require confirmation before any
  autosave, close-save, or quit-save. Only **Open Folder and Forget Missing
  Items** discards missing entries. Close/Quit preserve both legacy copies
  byte-for-byte.

## Session state and selection

- Lazy JPEG enrichment verifies scanned identity before/after metadata I/O.
  Replacement preserves projection/decisions and offers Rescan. After completed
  RAW Trash, failed JPEG enrichment keeps old evidence without reading fresh
  bytes, removes the absent RAW, and preserves Undo.
- The bridged scan cancellation flag spans persistence reads and final identity
  validation. Cancelled results cannot return Ready or save a sidecar.
- Opening restores decisions and prepares facets, physical pairs and the initial
  sort index off-main. One generation-checked result becomes authoritative;
  incomplete inventory or metadata never enters the session's save authority.
  A worker-owned folder lease survives cancellation until I/O exits. Opening
  progress coalesces into one latest value, published at most every 100 ms.
  A complete, restored inventory may mount a separate read-only opening state;
  phase stays scanning and authoritative items stay empty until final validation.
  Its physical viewport receipts are consumed after native restoration and expire
  on later Ready navigation, including receipts for a dormant view mode.
- Reset/recompute `visibleIndices` in the same turn as replacing/emptying
  `items` (see `openFolder`). Stale indices previously crashed rescan; retain
  `visibleItems` bounds checks.
- Sort-only changes retain ID, physical-file and recovery maps; finite metadata
  sorts reuse a validated chronological permutation. Item replacement invalidates
  that permutation before another sort can run. Quality coverage counts update
  on structural invalidation and accepted evidence, so its getter is constant-time.
- Quality filtering retains one byte of numeric cue matches per physical item
  index, prepared lazily and borrowed only during synchronous filtering. Cue
  switches reuse it; accepted measurements update their own slots. Both preference
  paths and structural/source invalidation clear it. Numeric classification shares
  the displayed warnings' inclusive rules; empty cue selection stays neutral.
  Private classification consumes already revision-accepted evidence; public UI
  access still checks revisions. No filename-set or per-photo task is created.
- Update rating counts incrementally. Structural item changes rebuild facets
  and sorted indices: call `rebuildDerivedData()` before `applyFilter()`.
- Pairing projects physical `PhotoFile` records. Grouped scans keep hidden JPEGs
  lightweight; the first split loads missing metadata off-main, and later toggles
  reuse it without rescan. Different decisions form Mixed, treated as undecided
  and protected from rating-based Clean Up. Rating a pair updates both files.
  Schema 1 combined entries remain readable; schema 2 adds per-file entries,
  schema 4 physical identity, schema 5 stars/color, and schema 6 original parent
  paths to prevent nested organization layouts. Schema 7 adds content proof and
  recovery history.
- Empty `selectedIndices` means the visible current photo through `effectiveSelection`.
  Asynchronous cue/group completion preserves current identity; if it is hidden,
  Gallery asks for an explicit matching item and rating commands have no target.
  `SelectionState.itemIDs` owns stable selection; `selectedIndices` projects the
  current generation. Structural changes clear both with `setSelectionIndices`
  or snapshot/remap IDs as same-folder rescan does. `applyFilter` removes hidden
  IDs from both. Grid rubber-band hit testing uses `PreferenceKey` frames and
  catches only rendered tiles; keep the grid lazy.
- Review defaults belong to app `UserDefaults`, not sidecars. Apply layout
  defaults only on a new folder or closed session. Same-folder rescan preserves
  view, sort, and dividers. Yes/No advances in pre-decision visible order so
  filters/sorts cannot skip the next undecided item. With advancement off, keep
  visible selection; never retain a filtered-out current photo.
- Hierarchy sort uses exact physical parent identity, natural component order,
  and stable byte tie-breaks. Root files/parents precede descendants in both
  directions; reverse changes sibling order. Full relative paths label groups;
  exact bytes identify them.
- Pair-component Clean Up tests the target's own displayed index against
  All/Filtered/Selected. Together shares one index; Separate never borrows partner
  inclusion. Counts, enablement, and worker snapshots share that predicate.
- Surviving explicit selection determines current after filter/restore. If it
  excludes the previous current, choose its first member in prepared visible
  order; empty selection uses the current-item fallback.

## Media rendering and caches

- `MediaKind.text` files remain standalone during pairing and use per-file review
  metadata/operations. The extension list excludes XMP and hidden sidecars.
  `TextPreviewLoader` reads/parses only the current document on one actor, caps
  reads at 1 MiB, verifies identity before/after I/O, and rejects non-regular
  files, invalid Unicode, and stale results. Native Markdown becomes serif text
  with web/email links; XML stays literal. `contentRevision` owns reader lifetime;
  ratings preserve selection/scrolling. Text never enters image decoding.
- Image requests retire cancelled waiters individually and guard completions by
  operation identity. Running lanes remain occupied until worker exit. Gallery's
  full preview publishes independently of thumbnail stand-in work. Background RAW
  quality requests bypass Info's 700 ms dwell on the same single utility lane.
- Gallery owns one replaceable four-photo prefetch neighborhood. Navigation,
  view/zoom/decoder changes, folder changes and Close cancel its admitted waiters
  as well as its debounce. Grid does not warm full previews; high-resolution
  sources warm only in actual-size Gallery. Executing workers retain their lanes.
  Matching-revision thumbnail pixels survive shared-cache eviction while retained
  by a cell. Optional disk writes coalesce keys and retain at most 8 MiB/32 entries,
  including the active write; saturation drops optional writes without delaying pixels.
- Fitted photo representation distinguishes a thumbnail stand-in from a ready
  full preview. The revision-bound loading state shows a small progress indicator
  within the existing zoom control until detail is ready or decoding fails.
  Warm full-image hits publish ready immediately. Its slot stays fixed and no
  progress view is instantiated at idle; source/tile loading remains separate.
- Quality checks use utility JPEG operations; Info joins/promotes shared numeric
  work. Two scheduler measurements retire before restarting; background native
  cancellation waits for executing histogram work to exit. Low Power/thermal
  backoff paces remaining batches; only pending foreground interest wakes rest.
  Explicit Pause survives threshold edits, file work and replacement until Resume.
  Evidence mutates privately with coherent batch notifications; selection priority
  consumes one frontier. Accepted filter matches flush before adaptive rest.
- `ImagePipeline.decodeImage` tries embedded JPEG previews first, then full
  decode if undersized (~160px). Preserve this fallback to prevent pixelation.
- `PhotoItem.id` survives rescans and cannot identify content. Caches and async
  thumbnail/full/metadata/histogram/100%-tile/video state follow
  `PhotoItem.contentRevision`. Disk v5 binds pixels to scanned physical identity.
  Production items reject v4/v3 bytes; identity-less compatibility still requires
  a cache timestamp at least as recent as the captured source timestamp.
- Uncached image/RAW/histogram/audio reads check `MediaSourceRevision` before/after
  I/O; new tiles check even with a cached lazy recipe. Validated memory hits
  avoid filesystem reads. Cold player preparation uses one bounded `lstat`;
  ready-to-play checks run off-main. Mismatch offers Rescan.
- Histogram/clipping analysis unpremultiplies nonzero alpha before luminance
  checks and repremultiplies warnings with the original alpha.
- Keep `GalleryView`'s `FullImageView` persistent; do not add `.id(item.id)`.
  Its AppKit viewport preserves normalized inspection position across photos.
  `FullImageView.loadedItemID` prevents stale preview display.
- `RawImageRendering` supplies bounded Fit/Phone renders and lazy tiles.
  `RawDisplayMode` changes presentation keys, leaving thumbnails and linear RAW
  analysis unchanged. Labels follow completed visible pixels; fallback requires
  **Use Preview**. `AppleRawDecoder` is independent and defaults to Apple Default.
  RAW 9 requires macOS 27 and filter support, including DNG. Worker resource
  preparation times out after 15 seconds; failures stay visible. The SDK lacks
  availability annotations: match supported `9`/`9.dng` identifiers instead of
  strongly linking new symbols in the macOS 14 executable. Preview, clipping,
  source, and tile keys include the choice; changes advance generations and
  cancel stale loads before publication.
- At 100%, one source pixel maps to one backing pixel. Keep the two-operation
  tile queue, visible ring, and 128 MiB ceiling; never decode a whole 45–100 MP
  bitmap for this view.

## Native UI

- `NativeSearchField` embeds `NSSearchField` for Filter, Command Palette, Help,
  and shortcut Settings. Keep immediate binding updates, native editing and IME
  ownership, one-shot focus requests scoped to the attached key window, and
  palette commands in its field delegate. Do not add a second key monitor.
  Sort uses grouped native Pickers; shortcut Add uses a native Menu and mounts
  its recorder after menu tracking ends. Welcome uses the system `HelpLink`.
  `FloatingControlSurface` shares macOS 26+ glass between photo zoom and floating
  video transport, regular material on older systems, and an opaque bordered
  surface for Reduce Transparency. Inline audio controls keep their reading layout.

- `SheetForm` owns the shared dialog title/subtitle, 24-point side margins,
  regular native controls, scrolling body, and fixed action row. Setup screens
  use `layout: .grouped`, sharing `LouppeSettingsForm` with Settings: one native
  Form owns scrolling, picker values align trailing, and standalone toggles use
  the system presentation. Supply direct rows and Sections, with no nested
  ScrollView/Form or custom card imitation. Reading, confirmation, progress,
  and result bodies retain the default scrolling layout. Photos and
  saved-decision recovery follow the same structure as Export, Rename, and
  Organize, including setup and result states. Keep primary actions at the
  trailing edge and preserve each operation's warnings and confirmation gates.
  Welcome uses matching source buttons and the File menu's Open Folder wording.
  Help and independently presented controls retain the app's purple tint.
  `UIConsistencyVisualTests` provides opt-in, unordered native captures with
  disposable media: set `LOUPPE_UI_SNAPSHOTS` to an output directory. It includes
  populated recovery, completed file tools, and a scrolling Grid beside Info;
  run the test bundle with `-AppleLanguages '(ar)'` for actual Arabic/RTL text.

- Settings uses a native two-page TabView in the Settings scene, with General
  (gear) and Keyboard shortcuts (keyboard) tabs. macOS owns the toolbar tabs and
  selected-page title; the expanded native toolbar centers the title without the
  app name. The packaged LouppeAccent color and NSAccentColorName keep native
  toolbar selection and focus rings consistent with the existing purple tint,
  respecting a user's explicit system accent override.
  Both pages share a 620 × 600-point content area and each owns one
  grouped scrolling form. General contains Review, new-folder defaults, RAW
  display, Quality Cues, Capture bursts, Updates, Louppe Help, and Louppe info in
  that order. Keyboard shortcuts contains the virtual keyboard and shortcut editor.
  RAW display and decoder preferences appear only in Settings; the Gallery zoom
  bar contains Fit, magnification and its loading indicator. All sections share
  margins and regular native control sizing. Never embed separate forms or scroll
  views inside section views. Get started opens
  the existing Help window; its guide lives only in Help. Settings retains the
  quick-start tips preference in its own Louppe Help section, without an inline
  disclosure or grouping under Capture bursts. Filter disclosure
  buttons own the full padded header row between dividers, including its edges;
  expanded controls stay outside that button. Support links
  share equal-width columns aligned leading, center, and trailing.
  Updates shows the running bundle's version/build; direct builds use Sparkle's
  existing file-operation gate and automatic-update preferences, Store builds
  open the App Store, and review builds keep updates disabled. Support reuses
  the Store tip window or direct tip URL and states that Louppe stays free and
  open source. Settings does not start purchases.
  Shortcut subsections start collapsed. Searching or selecting a keyboard key
  reveals matching actions. The shortcut search field does not take focus when
  Settings opens or scrolls; click it to edit. VoiceOver can explicitly focus it.

- Saved-decision recovery uses a nonblocking review banner and native preview
  sheet, joined to the existing keyboard/menu presentation gate. Selection plus
  an explicit same-photo acknowledgment enables manual restoration. Keep Current
  Decisions dismisses attention while retaining history. Recovery completion
  updates physical metadata/tallies and any affected sort/filter without jumping
  the current photo. RAW+JPEG decisions remain independent and can stay Mixed.
  The banner's × hides attention for the current opening without changing records
  or content checks. File → Check Saved Decisions… reopens the sheet/history;
  the next folder opening/rescan resets the temporary dismissal.
  Its full-width row has an opaque Color.appBackground fill so pane backgrounds
  cannot show through the safe-area inset.

- View menu Gallery/Grid choices show Tab / G; Grid Zoom In/Out show ⌘+ / ⌘−.
  File also shows Command Palette ⌘K, Rescan ⌘R, and Export E / ⌘E; Edit shows
  Undo Z / ⌘Z and Clear All Decisions R. Photo sizes show S (100%) and A (Phone).
  Actions without a dedicated shortcut, including Fit and Close Session, have
  no invented hint. Standard macOS commands retain their system equivalents.
  `MenuShortcutColumns` uses AppKit's native key-equivalent column during explicit
  main-menu tracking, with complete saved alias strings and no attributed-title
  spacing. Plain action titles and accessibility labels remain clean. Standard
  native equivalents stay intact; temporary hint strings restore synchronously
  when tracking ends (including parent/nested menus), the app resigns, a menu or
  item detaches/replaces, or presentation tears down. No added equivalents remain
  outside menu tracking; SessionView retains ordinary keyboard ownership.
  Preference and session context changes refresh the hints; full physical-position
  descriptions remain in help. Menu structure notifications refresh synchronously
  so SwiftUI's lazy Edit/View contents are decorated before tracking draws them;
  only notifications from that tree trigger decoration. Background and detached
  menu notifications are ignored. Scheduled state/default refreshes compare the
  localized entries and menu identity before traversing; structural/tracking
  events always bypass that cache. SessionView keeps sole ownership of shortcut
  routing and its existing focus/presentation gates.

- Localization uses `L10n.text` with complete English messages and numbered
  interpolation slots, plus UTF-8 `Localizable.strings` in `Resources/*.lproj`.
  Catalogs cover en/es/zh-Hans/hi/pt/ar. `L10n.label` is only for explicit
  display labels shared with stable English metadata identifiers; never pass
  filenames, user text, XMP values, generated path components, storage keys,
  export grouping IDs, or journal IDs through it. Preformat numbers before
  interpolation; never use a translated string as a printf format.
  Keep each language's keys/slots/technical tokens in sync with English.
  Translate whole sentences rather than inserting English suffixes or verbs.
- macOS preferred languages (including per-app overrides) select the catalog;
  unavailable keys/languages fall back to English. Traditional Chinese does
  not silently select the Simplified catalog. `LocalizedInterfaceModifier`
  applies Arabic RTL to main/Help/Settings. Shortcut glyphs retain LTR order;
  keyboard event and filesystem logic are language-independent. Locale is
  chosen at launch, following macOS's app-language relaunch behavior.
- Resource bundles are packaged into `Contents/Resources` and verified against
  source in both loose and archived apps. Packaging uses SwiftPM's native
  backend because Xcode's default backend attempted to sign resource bundles
  inside this File Provider workspace and failed on reattached Finder metadata.
  Use `--build-system native` for focused `swift build`/`swift test` here.
- The 2026-10-14 audit inspected all 1,600 existing entries per catalog and
  added complete messages for missed controls and operation summaries. Portuguese
  uses pt-BR consistently. Runtime template validation rejects stray braces as
  well as missing/repeated slots before inserting literal user text. Regression
  tests render every catalog value, protect technical tokens, and allow unchanged
  English only for identified brands, units, and shared words.
- `Scripts/localize_services.sh` derives Finder service labels from the same
  catalogs during packaging. It changes only staged display labels, preserving
  the service selector, folder types, port, and keyboard routing.
- Native fixture coverage and remaining linguistic/layout gaps are recorded in
  [the localization audit](Archive/2026-10-14/LOCALIZATION_AUDIT_2026-10-14.md). Alex
  accepted manual release review on 15 October; no separate native-speaker
  certification is recorded. See the current release-preparation record.

- `RootView` shows early-user feedback once per preference domain during 1.10.
  Mark it shown on appearance, including Close/Escape/email, so relaunch or patch
  updates do not repeat it. Wait for scanning, recovery, file work, and session
  presentations. Join the shared command gate to block shortcuts/menus behind
  the sheet. Email opens the system handler for `a@alex-markin.com` and sends
  nothing.
- After its flexible frame, the Gallery pane clips rendering and hit testing
  to its allocated area; fitted pinch cannot overlap Browser or Info.
  Photo zoom floats inside that pane, 16 points above its bottom edge, without
  reducing the image viewport. One regular Liquid Glass capsule on macOS 26+
  is 36 points high to match native toolbar groups and contains native
  Fit, slider and magnification; the loading indicator temporarily shares the
  percentage readout's space, keeping the capsule compact with steady input
  positions and equal outer padding. RAW preferences stay in Settings.
  Older systems use regular material,
  and Reduce Transparency uses the opaque app background with a contrast border.
  A window-bound mouse monitor returns double-clicks anywhere within the visible
  capsule to Fit before native slider tracking starts. Ordinary clicks/drags
  pass through immediately; removal/detachment removes the monitor.
  The session has no bottom strip. Toolbar status retains the save readout and
  opens filter/completion/tips details only when present, using the shared
  command gate. Saving has no explainer or duplicate heading.
  Video transport, full-screen, and Picture-in-Picture stay visible during playback.
- Filter drafts parse only edited endpoints. Open/close never round-trips stored
  precision through display text; editing one bound preserves the other.
- Finder **Open in Louppe** accepts one `public.folder` URL. The app delegate
  registers at launch and holds early requests until the SwiftUI window mounts.
  Route them through `SessionStore.openFolder` for recovery, safe switching, and
  scoped access. Review builds omit the service to prevent duplicate commands
  and port collisions.
- Dock opens and the whole main-window drop target share `FolderOpening`
  validation and visible errors. The delegate buffers early folder events until
  launch and scene configuration are ready, then explicitly shows the main window.
  `public.folder` registration uses Viewer/Alternate, preserving Finder's default
  role. Modal UI and active file operations refuse replacement; `openFolder`
  owns the existing asynchronous save-before-switch and access lifetime.
- Single-key review bindings live in app preferences (`review.shortcuts.v1`).
  Schema 2 retains independent ordered alias arrays for layout characters and
  QWERTY positions; schema-1 custom keys migrate without discarding navigation
  defaults. Each alias has a view/media scope intersected with its action's
  availability. A key can serve two actions only in disjoint concrete contexts;
  the same model validates recording, reset, saved preferences and event routing.
  Settings groups/searches actions, adds/removes aliases, shows each key's When
  scope and identifies conflicts inline. Mode explanations live in tooltips and
  accessibility hints; action context is not repeated beneath each title.
  Recording and errors show their text only when needed. Mode/action resets preserve unrelated
  bindings. Defaults for arrows, Space and Tab use this same authority, preserving
  Gallery seeking, Grid rows and playback without duplicate hardcoded routes.
  The decoded preference cache is bounded to one immutable value behind a lock;
  validation indexes key/context claims, and defaults retain stable row IDs.
  Missing/empty preferences now start in physical-position mode, including older
  installations without a shortcut setup. Both saved schema versions retain
  their explicit mode and custom aliases. Settings includes a compact assignable-
  key map: choosing a key filters actions rather than editing assignments. Layout
  labels use the current macOS input source; physical labels name QWERTY positions.
  Input-source notifications refresh the map, without polling. Key geometry stays
  LTR in all interface languages and native buttons expose assigned actions.
  The compact ANSI Mac silhouette includes the function row, Delete, Caps Lock,
  Return and modifier keys, with equal-height rows, wide Space and split-height
  up/down arrows. The base overview accents every used key across review and
  modified shortcuts; modifier layers narrow it to their matching bindings.
  Highlights and key-filter results follow live adds, edits, removals and resets,
  using each modifier layer's input-source translation. Each scope chooser sits
  beside its binding's remove button.
  Function keys, Caps Lock, Return, Control and Option are decorative and excluded
  from accessibility navigation. Review keys and supported modified keys filter
  actions; Command and Shift keycaps preview layers.
  The traditional editor remains below the keyboard. Review includes Export,
  Clear Decisions and Undo; each disclosure header owns its full-width hit area,
  with editor controls outside it. Add, reset, remove and cancel use equal-sized
  native bordered circular buttons with regular control sizing and named
  accessibility labels. System styling supplies current macOS appearance.
  Command aliases live separately in `app.commandShortcuts.v1`; schema 1 validates
  ordered aliases for Export, Command Palette and Rescan, excluding reserved
  system/text chords. Matching is character-based independently of review mode;
  removing an alias removes its route, and resets cannot steal another action's
  keys. Standard Mac commands and modified navigation remain read-only. Menus,
  palette, Help and tooltips read this same validated authority. Its decoded
  cache is bounded to one immutable value.
  Command/Shift keycaps latch visual layers; held modifiers combine with the
  latch and release restores it. A window-owned, non-consuming flags observer
  detaches cleanly, clears on resignation and respects recording and VoiceOver.
  Modified key labels translate with actual layout flags (including Command)
  rather than assuming QWERTY. Aliases appear with related actions in the list.
  Settings captures keys in focused AppKit controls; the session
  window monitor remains the ordinary review/Command router. Directional keys, Tab
  and Space retain native-control focus ownership even after remapping. Standard Command,
  modified-arrow and Escape shortcuts keep fixed behavior. Help, menus, the palette and
  tooltips read the same bindings; physical hints identify the QWERTY position.
- Fuji film simulation is immutable scan metadata per physical file, projected
  from the primary file when paired. Color FilmMode and monochrome Saturation
  resolve together; Info and Filter reuse the indexed value. A bounded read-only
  MakerNote/container fallback handles fields ImageIO does not expose. Missing
  Saturation in a partial numeric Fuji dictionary consults the full bounded
  container before accepting a color FilmMode, preserving monochrome overrides.
  Complete numeric tags retain precedence; absent container tags retain the
  available numeric evidence, while malformed tags remain Unknown. Missing
  and unknown simulations remain distinct. Filters use the existing exclusion
  facets and selection/current-item policies without rereading files.
- Welcome and Scanning hide the empty native window title so it reserves no
  leading toolbar space; their principal Louppe title stays centered at compact
  and expanded widths. Session restores native title visibility.
- Welcome uses a short top inset and top alignment, without a large branding
  block. Help stays 24 points from bottom/trailing edges outside measured columns;
  overflow scrolling reserves its footer.
- Filter owns Quality cues and Capture bursts; Sort retains ordering and exact/
  similar groups. Any chosen cue intersects the ordinary facets. Browser/Grid
  glyphs open shared cue names/values without selecting; Inspect in Info is explicit.
  Analysis statuses remain internal/filter state; tiles and Info show only matching
  cues, with no checked badge or empty quality-cues section.
  Browser/Grid cues sit inside each square at bottom left, with stars/color at
  top left and Yes/No at top right. All visible badges share a 20-point height
  and 6-point corner inset. Cues and color labels use individual dark circles;
  stars and duration use capsules. Grid retains a 40-point decision hit target
  aligned to the visible circle, and its canvas drag gate defers to controls. High ISO uses
  the dotted `aqi.medium` glyph; it remains a metadata clue, not measured noise.
  Info shows matching cue names/values immediately below the histogram, replacing
  the shadow/highlight percentage row. No status, source, technical disclosure or
  inspection action appears in that block. Cue icons, names and values use the
  primary text color. Tile popovers share the compact rows.
  Settings owns cue rules and the saved, numeric burst interval (0.5–10 seconds).
  Filter only selects cues and toggles burst grouping; all disclosure rows share
  the same title and spacing. Each cue row has a trailing reset icon that
  restores that cue's default threshold and enabled state. Each field owns its
  reset generation so resetting one cue cannot discard another cue's draft.
  There is no explanatory note or global reset button.
  The Quality cues title uses the same regular caption/secondary style as Stars
  and Color label. Histogram RAW/Preview labels appear only for RAW primaries
  after analysis completes; JPEG, TIFF and other rendered formats have no source
  label. TIFF has no separate RAW histogram path in the current implementation.
  Photo Info keeps Captured and Time zone; fallback dates (digitized, TIFF,
  filesystem or unverified) append “estimated” to the formatted date. Date source,
  Recorded date/time and Date precision are not displayed. Source, fractional
  seconds and offsets remain in capture evidence for date and burst logic.
- Cue preferences have independent ISO/shutter/near-white/near-black switches and
  thresholds. Legacy combined clipping values seed both missing new fields once.
  Fixed-width numeric fields commit valid edits; disabling preserves cutoffs.
  App-local changes reclassify retained counts live without ratings or file writes.
- Welcome lists mounted physical external/removable drives read-only. Discovery
  and capacity reads run off-main. Before the picker, identity comes from Disk
  Arbitration volume/media UUIDs and BSD/mount paths; missing identity is omitted.
  No filesystem identity/timestamp reads occur before folder access. Recheck DA
  identity after capacity I/O. Mount changes invalidate pending snapshots;
  revalidate the selected device before opening the folder chooser at its root.
  Show five recents and all drives in aligned columns, adding columns as needed.
  Measured content, banners, and toolbar space determine minimum size. Cap it at
  usable display height and enable native vertical scrolling only on overflow.
  Remeasure on display/toolbar changes. Every Welcome presentation fits that
  minimum, including after Back or native frame restoration. A native edge drag
  retains the user's larger size for that presentation; content still sets its
  minimum. Without a drag, added/removed content refits the window.
  Review performs no device discovery, polling, or whole-volume scanning.
- `SessionView.toolbarContent` uses the owner's arrangement and native fixed
  `ToolbarSpacer`. The owner prefers macOS 26's small `.navigation` separation
  and wider trailing gaps. Do not add custom equal-width spacers.
- Browser/Grid share `ReviewCollection`, a native vertical document with indexed
  section geometry and a bounded set of reusable SwiftUI hosts. Stable entry and
  physical-file identities drive direct follow and viewport restoration.
  `BrowserRow` and `GridCell` observe `SessionStore` directly so badges/current
  frames update without rebuilding the collection projection. Reuse clears old
  roots before assigning new entries. Read-only opening supplies the same native
  bridge from its separate state owner. See `Docs/PERFORMANCE.md`.
- Grid control drags use existing tile frames and fixed Rating/Play regions;
  avoid per-control `GeometryReader`. Every native multi-click Button activation
  cycles rating once. `GridImmediateClickSurface` commits the first mouse-up
  immediately and opens only on the second click; exclusive SwiftUI single/double
  gestures delay selection.
- `PersistentVerticalScroller` keeps the native legacy scroller and gutter.
  Never substitute a hand-drawn subclass. Resolve mounted scroll views
  synchronously and coalesce initial deferred lookup to avoid queued work
  delaying the indicator. Browser constrains its padded thumbnail column to
  the 122-point clip width, excluding the native gutter. Its flexible outer
  document retains the full native pane width for short folders; only an empty
  gutter-width tail extends outside the clip. Align the column at physical X=0
  in both LTR and RTL, and keep the bridge on the column before this wrapper.
  Grid constrains its tile document to the current pane width minus that
  gutter. Both views use the flexible outer wrapper with their bridge attached
  to the actual content before it. Short documents extend one layout point past
  the viewport height. Preserve both this viewport guard and the flexible wrapper:
  a short native viewport can otherwise shrink to the content width, subtract
  the legacy gutter again, and leave 17 points of sideways travel.
  This preserves bounded content and adds at most one layout point of vertical
  range when content fits. Empty/filter messages stay outside the tile scroller.
  Native configuration repairs horizontal-scroller/elasticity drift too. Those
  flags alone do not lock the axis: the mounted bridge observes clip bounds
  synchronously and resets only X to zero, preserving Y and native clip/scroller
  identity. Observation detaches/rebinds with the bridge and cannot restart after
  dismantling. No global event monitor or SwiftUI scroll-state publication is used.
  Column navigation uses the same available width across resizing and thumbnail
  changes. Native regressions include short/long grids, Info, RTL, display scales,
  thumbnail sizes, and horizontal bounds; exclude hidden cached tile frames.
  Run BrowserScrollTests, GridScrollTests and PersistentVerticalScrollerTests
  before every installation; exercise unconstrained offsets and pixel wheel/
  momentum events as well as settled geometry and vertical follow-navigation.
- View → Gallery/Grid uses an inline native picker bound to the focused
  session’s view mode, with the existing presentation gate and no duplicate
  key equivalents. Toolbar, menu, and G/Tab stay synchronized.
- `RootView` owns `WindowContentLayout`: Welcome uses its measured minimum
  and first Ready expands to the usable display frame. Back opens compact
  Welcome while retaining the review frame for the next Ready presentation.
  Replacement-folder scans preserve the chosen review frame.
  Welcome/Scanning use
  `.fullSizeContentView`; Ready restores session minimum and removes full-size
  content so photos stay below the toolbar. Manual session size persists until
  display changes. A real unified `LaunchToolbarTitle` supplies macOS 26's native
  large corners; never fake them with a window mask.
- `RootView` owns one drop target over the whole window; Welcome's dashed chooser
  is visual. Share dropped-item validation/errors across every phase.
- Square thumbnails letterbox (`fit`) to preserve the whole photo and prevent
  portrait overflow.
