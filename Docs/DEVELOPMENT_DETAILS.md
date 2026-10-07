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
| `Sources/Louppe/SessionPersistence.swift` | Folder identity, typed sidecar/backup outcomes, process locks, raw-byte CAS, generations, schema validation, durable actor writes |
| `Sources/Louppe/DurableFileIO.swift` | POSIX write/sync/rename/directory-sync boundary shared by sessions and file-operation journals |
| `Sources/Louppe/FileOperationJournal.swift` | Per-file durable Copy/Move/Rename/Organize/Trash/undo checkpoints, stable file identity, and launch recovery |
| `Sources/Louppe/CleanUpWorker.swift` | Background Trash/restore file loops, progress throttling, pair rollback, O(n+k) restoration merge |
| `Sources/Louppe/FolderScanner.swift` | Recursive scans, deterministic volume-aware RAW+JPEG pairing, lazy JPEG metadata, pairing projection, chronological sort |
| `Sources/Louppe/ImagePipeline.swift` | ImageIO decoding, AVFoundation first frames, thumbnail memory/disk caches, prefetch |
| `Sources/Louppe/HistogramPipeline.swift` | Bounded photo-only luminance analysis plus cached Fit/phone-size clipping-warning previews |
| `Sources/Louppe/CameraQualityWarnings.swift` | Pure app-wide warning preferences and non-blocking photo warning state |
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
| `Sources/Louppe/FileRenaming.swift` | Pure filename recipes, fixed date/time rendering, sanitization, sequencing, and source-rename configuration |
| `Sources/Louppe/Models.swift` | Physical `PhotoFile` records, projected `PhotoItem` groups, ratings/filter models, sidecar codables |
| `Sources/Louppe/Views/RootView.swift` | Phase switch (welcome/scanning/session), `Color.appBackground` |
| `Sources/Louppe/Views/WelcomeView.swift` | Start screen + cancellable scanning progress |
| `Sources/Louppe/Views/SessionView.swift` | Toolbar (incl. sort menu), export sheet, shared trailing Info panel, **all single-key hotkeys** (`handleKey`) |
| `Sources/Louppe/Views/FilterView.swift` | Toolbar filter popover: metadata search, date range, subfolder / file-type / camera / lens toggles |
| `Sources/Louppe/Views/GalleryView.swift` | Gallery media layout: Browser / photo |
| `Sources/Louppe/Views/BrowserView.swift` | Optional vertical thumbnail Browser with day separators |
| `Sources/Louppe/Views/GridView.swift` | Grid view, day-grouped rows, click-to-rate, rubber-band selection |
| `Sources/Louppe/Views/MetadataPanel.swift` | Info panel (filename header, photo histogram, camera, exposure row, fields) |
| `Sources/Louppe/Views/HistogramView.swift` | Photo-only histogram, shadow/highlight percentages, and Gallery clipping toggle |
| `Sources/Louppe/Views/CameraQualityWarningsView.swift` | Text-first Info-panel review warnings and the focused Warnings settings page |
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
- Reset/recompute `visibleIndices` in the same turn as replacing/emptying
  `items` (see `openFolder`). Stale indices previously crashed rescan; retain
  `visibleItems` bounds checks.
- Update rating counts incrementally. Structural item changes rebuild facets
  and sorted indices: call `rebuildDerivedData()` before `applyFilter()`.
- Pairing projects physical `PhotoFile` records. Grouped scans keep hidden JPEGs
  lightweight; the first split loads missing metadata off-main, and later toggles
  reuse it without rescan. Different decisions form Mixed, treated as undecided
  and protected from rating-based Clean Up. Rating a pair updates both files.
  Schema 1 combined entries remain readable; schema 2 adds per-file entries,
  schema 4 physical identity, schema 5 stars/color, and schema 6 original parent
  paths to prevent nested organization layouts.
- Empty `selectedIndices` means the current photo through `effectiveSelection`.
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
- Catalog drafts were generated offline, with core UI and safety wording
  reviewed and corrected. Full native-speaker and visual layout acceptance
  across all five languages remains a release acceptance check.

- `RootView` shows early-user feedback once per preference domain during 1.10.
  Mark it shown on appearance, including Close/Escape/email, so relaunch or patch
  updates do not repeat it. Wait for scanning, recovery, file work, and session
  presentations. Join the shared command gate to block shortcuts/menus behind
  the sheet. Email opens the system handler for `a@alex-markin.com` and sends
  nothing.
- After its flexible frame, the Gallery pane clips rendering and hit testing
  to its allocated area; fitted pinch cannot overlap Browser, Info, or footer.
  Video transport, full-screen, and Picture-in-Picture stay visible during playback.
- Filter drafts parse only edited endpoints. Open/close never round-trips stored
  precision through display text; editing one bound preserves the other.
- Finder **Open in Louppe** accepts one `public.folder` URL. The app delegate
  registers at launch and holds early requests until the SwiftUI window mounts.
  Route them through `SessionStore.openFolder` for recovery, safe switching, and
  scoped access. Review builds omit the service to prevent duplicate commands
  and port collisions.
- Welcome uses a short top inset and top alignment, without a large branding
  block. Help stays 24 points from bottom/trailing edges outside measured columns;
  overflow scrolling reserves its footer.
- Quality cues use inline editable thresholds and per-cue checkboxes. Fixed-width
  fields align; hidden labels reserve no space, and units follow fields. App-local
  preferences apply live without changing ratings/files; disabling preserves cutoffs.
- Welcome lists mounted physical external/removable drives read-only. Discovery
  and capacity reads run off-main. Before the picker, identity comes from Disk
  Arbitration volume/media UUIDs and BSD/mount paths; missing identity is omitted.
  No filesystem identity/timestamp reads occur before folder access. Recheck DA
  identity after capacity I/O. Mount changes invalidate pending snapshots;
  revalidate the selected device before opening the folder chooser at its root.
  Show five recents and all drives in aligned columns, adding columns as needed.
  Measured content, banners, and toolbar space determine minimum size. Cap it at
  usable display height and enable native vertical scrolling only on overflow.
  Remeasure on display/toolbar changes. Open/return at that minimum; new content
  grows the window, removed content lowers its minimum without shrinking it.
  Review performs no device discovery, polling, or whole-volume scanning.
- `SessionView.toolbarContent` uses the owner's arrangement and native fixed
  `ToolbarSpacer`. The owner prefers macOS 26's small `.navigation` separation
  and wider trailing gaps. Do not add custom equal-width spacers.
- `BrowserRow` observes `SessionStore` through its own `@ObservedObject` because
  macOS `LazyVStack` can leave realized value rows stale. Preserve `.id(item.id)`
  for follow-scroll and state reset after Clean Up remaps indices. See
  `Docs/PERFORMANCE.md`.
- Grid control drags use existing tile frames and fixed Rating/Play regions;
  avoid per-control `GeometryReader`. Every native multi-click Button activation
  cycles rating once. `GridImmediateClickSurface` commits the first mouse-up
  immediately and opens only on the second click; exclusive SwiftUI single/double
  gestures delay selection.
- `PersistentVerticalScroller` keeps the native legacy scroller and gutter.
  Never substitute a hand-drawn subclass. Resolve mounted scroll views
  synchronously and coalesce initial deferred lookup to avoid queued work
  delaying the indicator.
- `RootView` owns `WindowContentLayout`: Welcome uses measured minimum, Scanning
  compact launch size, and Ready the usable display frame. Welcome/Scanning use
  `.fullSizeContentView`; Ready restores session minimum and removes full-size
  content so photos stay below the toolbar. Manual session size persists until
  display changes. A real unified `LaunchToolbarTitle` supplies macOS 26's native
  large corners; never fake them with a window mask.
- `WelcomeView` owns one drop target over its whole content; the dashed chooser
  is visual. Share dropped-item validation/errors across the window.
- Square thumbnails letterbox (`fit`) to preserve the whole photo and prevent
  portrait overflow.
