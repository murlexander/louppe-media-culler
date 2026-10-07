# Performance architecture

Ownership and resource limits for scanning, filtering, decoding, persistence,
and Clean Up. Read the relevant sections before editing.

## Disposable verification fixtures

Performance fixtures use `/private/tmp`. On 7 October 2026, a Documents control
acquired external `UF_TRACKED`/`UF_HIDDEN` flags without Louppe running. ctime
and scan visibility changed; bytes, inode, size, and mtime did not. Temporary
controls and twenty pairing repetitions stayed stable. Retain failure
checkpoints/identities and original-byte assertions; production replacement
checks and five-second waits remain unchanged. Actual volume/provider acceptance
uses separately selected disposable mounts.

## Main-actor rule

`SessionStore` is `@MainActor`: it owns UI state, freezes mutable file metadata,
and applies results. Entry construction, encoding, and filesystem loops run
off-main. Snapshot reads, revision checks, and writes share a 512 MiB ceiling;
encoded excess fails before locks/writes without consuming Retry's sequence.
Lazy JPEG metadata verifies identity before/after I/O; scan cancellation covers
persistence reads and final identity checks.

- `SessionPersistence` serializes encoding, schema validation, newest-valid
  reads, typed sidecar/backup outcomes, and durable writes on one actor.
  `DurableFileIO` writes → flushes → atomically replaces → flushes the parent.
  Each session carries source-folder volume/inode/birth identity and SHA-256 of
  the exact sidecar bytes. Recheck both before replacement. Stable folder
  identity keys backups and the cross-process advisory lock; that lock spans
  sidecar/backup revision checks, replacement/fallback, and lineage update.
  Actor-assigned generations order copies; sequence numbers reject late older
  saves. Switching, rescan, and Close Session await a safe result before discard.
- A disconnected source saves only to its stable-identity backup under the same
  lock. Never recreate missing paths or accept replacements/ambiguous failures.
  Rename followed by sync failure establishes observed CAS lineage, but becomes
  durable only after a recovery directory flush under that lock or a fully
  synced backup. Otherwise retain dirty state and the retryable save sequence.
  Reconnect may adopt only the possible interrupted-commit revision marked by
  that access, never an older backup rollback.
- `SessionStore` compares live change generation with each successful request's
  captured generation. The opened scan is a safe generation-zero baseline.
  Quit awaits checkpoints, starts no I/O for durable state, and saves once if
  ratings are newer. Optional generation-zero repair failure does not block
  Quit; unsecured new changes do. Pairing reprojects files without discarding
  them. AppKit's asynchronous terminate-later reply allows retry/refusal, and
  the termination barrier rejects mutations after the final snapshot boundary.
- Saves use a 500 ms trailing delay and five-second maximum dirty age. While a
  write is slow, checkpoints coalesce into one replaceable newest request.
  Main-actor capture freezes metadata/identity; a detached task builds entries
  and reconciles missing files before actor encoding/writing. On 2026-09-28,
  100,000 files took 105 ms to capture and 123 ms to construct in background.
  Measure capture cost before considering a rating write-ahead log.
- `CleanUpWorker` takes immutable snapshots and a fresh `FileManager` in its
  detached task. It handles RAW+JPEG partial-failure rollback and reports rollback
  failures; `SessionStore` applies one batch.
- `XMPMetadataStore` alone owns XMPCore parsing and XMP read/merge/CAS/publication
  off-main. Standalone Metadata (XMP) preflight and publication each use exactly
  three long-lived tasks, one serial store each. Never create tasks per photo or
  retain complete packet batches. Plans retain exact paths, metadata snapshots,
  revisions, and SHA-256 fingerprints. Publication also carries selected and
  unselected stem-family scan identities, parent binding, and opened-folder
  authority. Revalidate them in preflight and immediately before commit.
  One held parent descriptor owns temporary creation, rename, cleanup, and
  flush; check the flushed temporary's identity before its same-directory rename. Reads reject
  leaf symlinks/non-regular files, stop at 64 MiB, and retain raw bytes plus
  device/inode/time revision. Reparse one packet immediately before commit; post-confirmation
  changes become conflicts. Creates rename exclusively; updates compare live
  bytes/identity. Reparse committed bytes before success. Exact filesystem bytes
  own plans; packet-byte/revision CAS remains mandatory.
- XMP publication has one `SessionStore` generation/cancellation flag, separate
  from `activeFileOperation`. Ratings/navigation continue; other file mutations
  wait. Open/Close Folder, Rescan, and Quit cancel and await a between-file or
  completed atomic boundary. Apply late results only to the same scan/folder token.
- Welcome drive discovery uses one serial actor. Physical eligibility and Disk
  Arbitration UUID/path identity precede fresh capacity reads; a second DA lookup
  discards replacements during I/O. No filesystem identity reads, recursive scans,
  or per-volume tasks run before the folder picker. Discovery stops during review.
- `ImagePipeline` has separate bounded `OperationQueue`s: two full decodes
  (4096 px bound) and `min(4, cores/2)` thumbnail decodes (320 px). Same URL/size
  requests coalesce across foreground/prefetch; foreground joins promote utility
  work. Thumbnail backlog cannot delay the full-image lane.
- `HistogramPipeline` runs two 1,024-pixel photo decodes, coalesces requests,
  and retains 256 numeric results. Cancellation removes its waiter and cancels
  queued work when no waiter remains; finishing decodes cannot publish to removed
  requests. Videos, audio, unsupported files, and multi-selection skip analysis.
  `RawHistogramPipeline` handles RAW primaries after 700 ms: one utility
  `CIRAWFilter` decode, native scaling, and a final lazy bound keeping each
  extended-linear RGBA-float dimension near 1,024 pixels. Its 128-entry LRU
  retains numbers, never pixels. Same revisions coalesce; cancellation removes
  stale waiters/queued work. Unsupported/unknown decoders leave rendered analysis
  in place. `ClippingPreviewPipeline` shares the coalesced full preview and runs
  two transforms.
- `AudioLevelPipeline` runs only for the selected playable video/audio after
  Info dwell or a Gallery waveform request. One utility `AVAssetReader` PCM
  task runs at a time; same revisions coalesce. Last-waiter cancellation stops
  the reader at a checked boundary, and its lane stays occupied until exit.
  Completion checks operation identity so abandoned work cannot consume/cache a
  renewed request; histogram lanes share this guard. The 64-entry LRU stores
  independent channel min/max/RMS envelopes and sample peaks, never samples or
  disk output. Use 20 bins/second, clamped to 256...6,000 per recording: stereo
  payload is about 144 KiB. The 768,000-envelope budget (roughly 9 MiB of
  three-float payload) evicts multichannel results sooner. Never mix channels
  for meters/waveforms.
- `HighResolutionImagePipeline` retains four lazy oriented Core Image recipes
  and runs two 1,024-source-pixel tile renders. Identical requests coalesce;
  stale generations cannot display. Request visible tiles plus one tile margin.
- Video first frames share thumbnail queues, caches, and coalescing.
  `AVAssetImageGenerator` runs asynchronously in background with exact zero-time
  tolerances; never generate frames from SwiftUI bodies or the main actor.
- `FolderScanner` uses `DispatchQueue.concurrentPerform` with up to 8 metadata
  chunks. Lock-protected `ChunkResults` concatenates chunks in index order;
  chronological sorting matches serial output, verified by order-hash benchmark.
  Workers poll the `@Sendable` `isCancelled` closure. `{ Task.isCancelled }` reads false on
  GCD threads, so `SessionStore.openFolder` bridges task cancellation through
  `FolderScanner.CancelFlag` and `withTaskCancellationHandler`.

Unreadable subfolders fail visibly; incomplete traversal cannot become a saved
session. Final identity checks iterate physical files without a flattened copy,
poll cancellation between files and before an empty pass, and check again after
sorting. Keep filesystem loops and JSON encoding off `SessionStore`.

## Shared review-metadata storage

Copying `@Published [PhotoItem]` for F/D cost 20.5 ms at 100,000 items.
Each physical `PhotoFile` now shares one small locked store for decisions,
stars, colors, and change dates. Complete snapshots keep projection, filtering,
persistence, and Export from mixing fields read at different moments.
`SessionStore` sends one `objectWillChange`, mutates touched files/pairs, and
updates tallies without replacing `items`; the same check takes about 0.2 ms.

Value copies intentionally share physical-file metadata, preserving independent
RAW/JPEG decisions and coherent detached reads. Keep mutable fields out of the
large value array. Clear All mutates small records once and publishes once:
O(N), while single-photo culling is O(1). Rating, clear-all, batch, pairing,
persistence, and undo checks cover this boundary.

`SessionStore` caches the multi-selection scan-metadata summary. Every `items`
or `selectedIndices` assignment invalidates it, including same-index replacement;
ratings, stars, colors, playback, and unrelated publications do not. Live review
aggregates read once per body, walk without sorting/state-array allocation, and
stop at the first mixed value. Never cache them as immutable scan summaries.

## Lazy thumbnail invalidation

On macOS 26, realized `LazyVStack` rows retained stale badges/current frames
until recreation (e.g. Grid and back). `BrowserRow` therefore observes the
store directly through `@ObservedObject`; do not restore a plain `ForEach`
subtree. Keep `.id(item.id)` for follow-scroll and `ThumbnailView` `@State`
reset when Clean Up/undo changes the photo at an index.

Each realized `GridCell` likewise observes `SessionStore` and reads current
`PhotoItem` in `body`; the outer grid keeps `.id(item.id)`. Pointer, keyboard,
Clear All, and undo must redraw controls without replacing `items`. Photo/rating
clicks suppress the next follow-scroll because the tile is already under the
pointer; keyboard and structural changes still follow stable media IDs.

Only realized cells subscribe. Their bodies use bounds checks/cache hits;
multiple same-turn publications coalesce.

## Text previews

`TextPreviewLoader` serializes reads/Markdown parsing off-main. Only the current
Gallery document loads, after 40 ms dwell; Browser/Grid show a glyph without
reading. Cap reads at 1 MiB, reject non-regular files, and check scan identity
before/after I/O. Decode UTF-8 or BOM-marked UTF-16/32 explicitly. Cancellation
and content revision reject late results. Keep only the current bounded native
text layout; no text cache or remote fetch.

## Image cache budgets

| Cache | Limit |
|---|---|
| Thumbnails | 1,200 objects; 256 MiB decoded |
| Full previews | 8 objects; 384 MiB decoded |
| Clipping previews | 2 objects; 128 MiB decoded |
| Histograms | 256 numeric results; temporary 1,024-pixel previews |
| RAW histograms | 128 numeric results; temporary extended-linear RGBA-float bitmap near 1,024 pixels on longest side |
| Actual-size tiles | 128 MiB total; 1,024 × 1,024 source-pixel tiles, normal and clipping variants; lazy recipes retain no whole bitmap |
| Disk thumbnails | 512 MiB; 90-day age; utility maintenance at most daily after launch delay |

Decoded cost is `bytesPerRow × height`. Return thumbnails before JPEG
encoding/writing. Preserve the undersized embedded-preview fallback in
`ImagePipeline.decodeImage` to avoid pixelation. Production scan identities
reject identity-less v4/v3 pixels; timestamps cannot prove inode ownership.
Cold v5 migration runs on bounded decode queues without blocking Grid's first
frame. Identity-less legacy/synthetic items may read byte-exact v4, or v3 for
unambiguous ASCII paths, only when cache time is at least the captured source
time. Atomically promote validated results. Replace corrupt v5 entries after
fresh source decode; replacements never inherit old pixels, even for slow RAW.

| Deferred work | Dwell |
|---|---|
| Neighbour prefetch | 60 ms debounce |
| Full/clipping view decode | 40 ms; memory hits remain immediate |
| Secondary Info EXIF/histogram | 80 ms |
| RAW histogram | 700 ms; separate utility lane; rendered histogram is immediate |

At 100%, document points equal source pixels/backing scale, giving one physical
pixel per source pixel on standard/Retina displays. `ActualSizeViewport` holds
normalized center position without publishing scroll traffic. The persistent
AppKit view clamps each aspect ratio and preserves an unscrollable axis for the
next larger image. S and folder close/change reset to center.

The Gallery slider spans 30–400%; Fit/pinch geometry spans 5–400%. Both use
native `NSScrollView` magnification. Below 100%, show the bounded full preview;
RAW uses `RawImageRendering` with tiles' Apple defaults. At 100%+, request
visible tiles plus their one-tile ring on the two-operation/128 MiB lane.
Native pinch owns transforms until completion; occasional footer publications
avoid full-session redraw. S returns custom zoom to centered 100%, then Fit;
A toggles phone-size/Fit.

Retire a departing actual-size source before reporting tiles idle. Late
layout/scroll callbacks cannot restart it and strand the toolbar load count.
Explicit configuration may restart, including the same photo.

Fitted previews finish/cancel pinch with `NSMagnificationGestureRecognizer`;
native scroll views use live-magnification notifications and `NSEvent.phase`,
never obsolete `beginGesture`/`endGesture`. Completion is idempotent: fitted
preview hands off once, native magnification releases ownership for slider
changes. Drag panning converts window deltas through magnification, clamps edges,
and shares non-published viewport state with two-finger scrolling.
S reset interpolates scale/position over ten frames without store publications.
Reduce Motion skips it; scroll, drag, pinch, or slider interrupts it. Capture
visible position/scale on interruption before SwiftUI layout.

Fit/phone double-click maps the letterboxed image point to normalized source
position before entering 100%. Center that point, clamped at edges. Double-click
at 100% returns to Fit; background clicks do nothing, and S stays centered.

X overlay matches rendered Info histogram's 8-bit sRGB thresholds: 0–5 shadows,
250–255 highlights. Fit/phone use a 4,096-pixel warning preview. Exclude fully
transparent pixels from totals. At 100%, apply thresholds in the existing tile
lane with warning-mode keys, never a full source bitmap. Photo/mode changes
advance generations before old tiles display.

`review.rawDisplayMode` is shared by Settings/Gallery and applies immediately;
Grid/Browser retain fast thumbnails. Fitted RAW uses the two-operation full
queue, 4,096-pixel bound, and existing memory budget. Presentation mode separates
full/clipping keys; revision owns source identity. Camera-preview fallback
requires per-photo **Use Preview**. Labels reflect completed visible tiles:
show Preview while preview regions remain; a RAW-fitted stand-in counts as RAW.
Missing offscreen margin tiles do not delay labels. Apple RAW can differ from
camera JPEGs/editors; histogram analysis stays independent.

`review.appleRawDecoder` is shared by Settings/Gallery and defaults to Apple
Default. RAW 9 is opt-in on macOS 27 and requires each filter's supported
version. Prepare on-demand Core Image resources off-main with a 15-second timeout
and bounded 16-second wait. Failure stays unavailable; never substitute another
decoder or retry RAW 9 on CPU. Preview/clipping/lazy-source/tile caches distinguish
decoders; Fast and non-RAW keep shared keys. Source changes retire tiles/reject old
generations. Fitted/clipping publication compares decoder, mode, revision, and
cancellation.

Decoder benchmark: 2026-09-29, macOS 27/Xcode 27 SDK, three read-only uncompressed
X-T50 RAFs (XT508475, XT508539, XT508553), separate debug XCTest processes,
one pass per file/size. All supported 7/8/9, default 8. Timings include filter
creation/resource preparation.

| Render | Apple Default (8) | RAW 9 |
| --- | --- | --- |
| 1,024-pixel preview | 0.408–0.678 s | 0.777–0.821 s after first warm-up |
| First 1,024-pixel preview | 0.554 s | 6.213 s |
| 4,096-pixel preview | 0.255–0.655 s | 1.825–2.008 s |
| Central 1,024-pixel source tile | 0.032–0.122 s | 0.139–0.210 s |
| Test-process peak RSS | 459 MiB | 469 MiB |

RSS excludes Core ML/graphics helper memory. This single pass included concurrent
repository activity; it is not a device-wide guarantee. Repeat with
`LOUPPE_RAW_BENCHMARK_FOLDER` pointing to samples,
`LOUPPE_RAW_BENCHMARK_DECODER=appleDefault` or `raw9`, and
`swift test --disable-keychain --filter AppleRawDecoderTests/testFujiDecoderBenchmark`.
The selected SDK's CIRAWFilter.h and [Apple's RAW 9 session](https://developer.apple.com/videos/play/wwdc2026/305/)
verify the API/resource contract.

Supported RAW primaries replace the rendered estimate with delayed Core Image
RAW histogram/clipping Quality cues. Disable presentation tone curves; render
extended-linear sRGB with luminance thresholds 0.002/0.995. This is demosaiced,
white-balanced sensor-derived RGB, not a camera-maker per-photosite histogram.
It cannot supply X overlay because that mask would not align with the rendered
preview.

`PhotoItem.contentRevision` keys include byte-exact absolute path, media kind,
size, scanned physical identity, and captured timestamps. Async thumbnail,
full-preview, metadata, histogram, 100% tile, and playback follow that revision:
rescans preserve item IDs even when bytes change. Keep filesystem lookups out of
`ImagePipeline.cacheKey`; lazy-cell recreation must not `stat` on the UI thread.
Reappearing cells seed from memory to avoid placeholders. FolderScanner captures
movie/audio duration, playability, codec, dimensions, and frame rate once on
bounded workers; filters/sorts/Info reuse them instead of reopening `AVAsset`.

Fresh sessions review RAW/JPEG separately and load both on bounded workers.
On 2026-08-07, 250 synthetic pairs took 0.061 seconds separate versus 0.051
seconds grouped. Grouped scans keep hidden JPEG enumeration facts lightweight.
The first split loads only missing metadata while Ready stays visible; subsequent
projections reuse enriched records without folder walks or metadata reads.

## Duplicate + burst grouped review

Analysis starts only on explicit request, never from opening/filtering/sorting/
navigation. `SessionStore` snapshots displayed IDs/revisions, runs one cancellable
utility task off-main, and accepts results only for the unchanged map. Rescan,
pairing, Close Folder, and file operations cancel/invalidate it. Results live
only in open-session memory; no disk cache, sidecar, network, or automatic
metadata/file action.

Exact matching buckets files by size, streams SHA-256 with one 1 MiB buffer,
and checks identity before/after reads. Changed files yield no suggestion.
Visual matching handles supported photo projections with ≤160-pixel ImageIO
thumbnails reduced immediately to 9 × 8 grayscale signatures. Skip buckets over
256 distinct signatures; cap near-hash comparisons at 50,000. Label all visual
groups **Likely Similar**. Bursts use cached still-photo dates and consecutive
0.5–10-second gaps; changing the gap is O(N) without I/O.

Join equal hashes first, then one representative per existing component for
near matches. Never form Cartesian products: a 4,000-item/two-hash debug fixture
dropped from 5.95 seconds to about 0.024 seconds. Cache membership by mode and
sensitivity; filter/sort/rating project it. New analysis or structural change
clears membership. Headers count visible members. Initial grouping/sensitivity
changes still run synchronously; cancellable background work for large sessions
remains an improvement.

Same-name XMP conflict preflight retains typed stable IDs, scan identities,
metadata snapshots, and exact paths. Apply resolution as one small main-actor
metadata transaction; parsing/family resolution/publication stay in bounded
workers. Applied batches invalidate the old plan and rerun selection/full preflight.

## Grid scrolling

`SessionView` owns one trailing `MetadataPanel` outside Gallery/Grid switching,
so toggles preserve debounced EXIF/histogram tasks. Keep secondary inspection
outside the media canvases.

`ViewSwitchTests` mounts the real UI with 106 image files, multiple days, and
current at Grid's distant tail. Await its scroll view and tail thumbnail, then
run five warm Gallery/Grid cycles. Preserve render barriers; enum-write timing
cannot verify visible transitions.

Use day sections in one `LazyVGrid`. Nested day grids in `LazyVStack` estimate
offscreen heights, then jump on upward scroll or resize. `gridColumnCount` is
unpublished navigation state; publishing triggers a second full redraw.

`GridImmediateClickSurface` commits first mouse-up synchronously; only the second
click has `clickCount == 2`. Exclusive single/double SwiftUI `TapGesture` delays
selection. Forward exact modifiers, reject drags beyond eight points, and return
keyboard navigation ownership to the session.

Browser/Grid share `PersistentVerticalScroller`: native `.legacy`, autohide off,
with a real gutter. Subtract `PersistentVerticalScroller.gutterWidth` from Grid
column calculations. Keep native `NSScroller`; the former hand-drawn thumb stepped
under lazy-cell load. Resolve mounted scroll views synchronously; queue/coalesce
only the initial unresolved lookup. `configure` returns early once configured,
avoiding redundant `tile()` on every keystroke/drag.

## Filtering and derived data

Hierarchy sort computes directory component order once, then uses cached integer
ranks and chronological tie-breaks without I/O. Exact encoded parent bytes keep
Unicode-equivalent display paths separate. Filter-only changes reuse that order.

Welcome drive discovery has one serial actor/coalesced refreshes. While visible,
refresh on topology/activation and every 30 seconds; stop polling on departure.
No per-volume tasks or recursive media scans.

Cache locale-folded `PhotoItem.searchableText`, capture day, aperture, shutter,
ISO, video resolution, frame rate, and codec at scan. Filters/sorts never reopen
files. Compare `captureDay` directly in `sameGroup`; avoid per-pair
`Calendar.current`. One `PreparedPhotoFilter` prepares query, whole-day bounds,
and ranges before traversal. Decision/star/color exclusions use one mutable
snapshot, never immutable `searchableText`. Metadata sort captures snapshots before
O(N log N) comparisons, avoiding repeated locks. Search/camera-setting drafts
use 150 ms debounce and one valid filter assignment per commit.

Date/exposure controls stay visible. Folder-wide full ranges are neutral and
keep unknowns visible; set internal flags only when narrowed. Rescan retains
narrowed bounds and expands untouched ranges. Parse only edited endpoints:
formatting cannot change stored precision, and real edits share one assignment.

Multi-selection Info uses cached metadata/byte counts for camera, lens, date,
size, and type summaries. Clean Up flushes filter debounce before confirmation
and target resolution so both use visible text. Scope uses cached folder/visible/
effective-selection indices without rescan.

Toolbar/Escape cancels scans. Advance `scanGeneration` before Welcome so late
progress, reads, or partial results cannot re-enter Ready.

`SessionStore` maintains:

- incremental Yes/No/undecided, Unrated/1–5/Mixed, and None/five-color/Mixed totals;
- cached type/camera/lens labels/counts, calendar-day counts, and exposure ranges;
- sort indices reused on filtering; Browser id/index entries per visible generation;
- visible day groups/day starts and one location map (global/group/local positions)
  for navigation, ranges, prefetch, and status; never scan `visibleIndices` or
  `visibleGroups` on every key;
- one `PhotoItem.id` → current-index map for stable selection/undo after rebuild;
  same-folder rescans snapshot IDs before clearing, then remap visible survivors;
- one physical-file ID → displayed-index map, including hidden JPEG IDs, so
  pairing cannot lose independent metadata/undo.

`FolderScanner.pairFiles` sorts exact paths/group keys, independent of enumeration
or Dictionary order. Pair only exactly one RAW/JPEG per stem across the entire
folder tree. Unique matches may cross subfolders; ambiguous/repeated names stay
separate. Fold ASCII case only on explicitly case-insensitive volumes; unknown
behavior uses exact bytes. Accents, composed/decomposed Unicode, and non-ASCII
case cannot collapse pairs.

Physical IDs are ASCII percent-encoded relative filesystem paths through
projection, selection, sidecars, and caches. Schema 3 requires
`percentEncodedFileSystemPath`, canonical ASCII encoding of valid paths, and
unique primary/hidden IDs in both readers/writers. Schema 1/2 migration uses raw
UTF-8 indexing to preserve distinct Unicode spellings; the marker prevents legacy
aliases colliding with literal-percent filenames.

Schema 4 adds volume UUID (conservative mount/device fallback), inode, size,
birth, and nanosecond mtime. Replacements cannot inherit ratings or auto-overwrite
saved sessions. Verified renames keep ratings; missing files keep dormant entries,
and returning exact files recover decisions. Persistence matching excludes
ctime for Louppe-owned rename/rollback; live plans refresh/enforce it. Capture
source directory before walking; recheck after metadata, session read, and before
apply. Preserve each ancestor's exact `lstat` identity to reject replacement
folders/dangling symlinks instead of treating them as ejected volumes. Devices
stay strict outside the source volume. Recaptured matching UUID sources may
change device on remount; absent/unreadable final folders retain strict checks.
Re-stat every physical file after metadata and again after persistence I/O.

Schema 1–3 sessions in their recorded folder migrate only with all saved names
present. A valid sidecar with another recorded path requires **Open Anyway**,
bound to its SHA-256 and recorded path; changes require fresh acknowledgement.
Rescan/read, match exact filenames, and write current-folder physical identities
only if all entries exist. Zero matches fails. **Open Folder and Forget Missing
Items** excludes only unmatched ratings; Close/Quit preserve both legacy copies.
Read obsolete path backups only when sidecar and identity-keyed backup are absent.
They have no Open Anyway, require confirmation as unowned legacy data, and
schema-4 entries still need physical identity matches.
Schema 5 adds independent stars/colors. Schema 6 stores exact original parent
bytes before first Source Organization so later priority changes rebuild without
nesting old layouts. Traversal has no depth cutoff; skip symlink directories and
package descendants to avoid loops while preserving deep archives.

Structural `items` changes call `rebuildDerivedData()` then `applyFilter()`.
Rating changes use `transitionRatingCount` or deliberately replace batch tallies.

## Clean Up lifecycle

Pair-component scope tests its own displayed index. Separate never borrows
partner inclusion; Together shares the pair index. Counts/enablement use the
worker snapshot predicate.

1. Main actor resolves indices and snapshots values.
2. `CleanUpWorker` runs Trash/restore, throttling progress to about 100 ms/50 files.
3. Main actor applies once, rebuilds derived data, and snapshots a save.

Each move/restore gets a generation token; delayed progress cannot overwrite
subsequent Undo. During `isCleaningUp`, block ratings, navigation, selection,
undo, rescan, switching, export, and Quit. Scrolling, Info, panel visibility,
and mode switching remain available. Use a non-interactive overlay. Refuse Quit until the
worker finishes so partial RAW+JPEG rollback can finish.

`mergeRestoredItems` restores in O(n+k), preserves survivor order, and omits only
photos whose Trash files could not be restored.

## Process-crash file-operation journal

`FileOperationJournal` records Copy, Move, Source Rename/Organization/undo, and
Trash/undo as immutable plans in `~/Library/Application Support/Louppe/Operations/` before mutation. Activate
by atomic rename. Each file advances its own `steps/` checkpoint: file 9,000
rewrites one small record, giving O(1) per step and O(n) per batch.

One exclusive Operations-root advisory lock spans worker/recovery lifetime.
Other processes cannot inspect/start transactions until release or OS process
exit. The bundle's single-instance declaration is secondary to this lock.
Under it, refuse new work until older active journals are reconciled.

Plan v3 records exact source/destination/temporary/resolved Trash bytes.
Reconstruct without Swift normalization; malformed, relative, noncanonical, or
mismatched paths retain retryable journals. v1/v2 stay readable. XMP Copy/Move's
version-4 extension identifies media, unchanged application packets, generated
packets, and fully selected families' retired sources, sealing source/prepared
SHA-256 digests. Preserve v1/v2/v3 recovery semantics.

Trash recovery commits forward without searching/restoring protected Trash;
only explicit session Undo restores. Export resolves symlinks through raw POSIX
and carries that selected directory unchanged into workers. Target construction
cannot use Foundation standardization. Decode plans only when:

- every path is absolute/canonical and globally disjoint by bytes/resolved aliases;
- destinations/temporaries do not alias sources or other owned inodes;
- manipulated paths cannot enter journal storage;
- destination/temporary roles match operation kind; reserved names identify
  the recorded operation/step.

Copy may read distinct hard links. Move/Clean Up/Trash undo reject them before
mutation; even one source with link count >1 is unsafe because rename alters
shared metadata and pre-checkpoint Trash cannot identify a unique entry.
Operation-owned inode aliases are always refused. Commit records repeat operation
ID and SHA-256 of raw immutable `plan.json`. Preserve exact legacy v1 markers,
including authentic empty committed plans. Inspection/listing errors mean
unresolved recovery, never an empty root.

Plans/checkpoints capture volume/device/inode, size, birth, mtime, and ctime.
Verify identity before moving/removing; never overwrite. Disconnected, replaced,
or rewritten sources leave retryable journals. Volume UUID supersedes changing
mount/device numbers. Source checks include ctime; created-copy checks exclude it
because asynchronous provenance may change ctime without changing bytes or
volume/inode/birth/size/mtime.

Export stages through `.louppe-<operation>-<index>.partial`: before rename the
journal owns the temporary; afterward its staged identity owns the destination.
Trash writes `.started` before `trashItem`; if no returned URL was recorded,
recovery preserves the Trash decision without inspecting protected directories.
A paired Trash interruption remains nonblocking attention until Retry or **Keep
Files As They Are**, which retires metadata only.

Generated XMP uses the planned temporary and sealed digest instead of Copy's
source-byte comparison. Publish a complete started packet only with an exact
digest; remove incomplete packets only after inode checkpoint. Move recovery
removes generated packets for rollback and keeps completed families; restore
incomplete source retirement, finish fully checkpointed retirement forward.
Retire canonical sources only after all family media/generated/application
records complete.

Move accepts the same known volume, checks source before mutation, and uses
`renamex_np(..., RENAME_EXCL)` for both transitions. It preserves inode or fails,
including `EEXIST`/`EXDEV`, never implicit copy/delete. Use Copy across drives.
Cross-volume Move requires an explicit copy/flush/verify/checkpoint/delete
transaction and recovery tests before enabling.

`DurableFileIO` orders power-loss protection: sync plan before activation;
sync created copies and affected rename/removal directories before checkpoints;
fully sync commit before retirement. Cross-directory rename flushes destination
before source, preferring two recoverable names to none. macOS owns
`FileManager.trashItem`; `.Trash`/`.Trashes` open/fsync is not required.
Retire by exclusive `.retired` rename and full root sync before bounded recursive
cleanup. Checkpoints recapture exact worker-proven identity. Duplicate cleanup
moves a candidate between the two owned paths, repeats byte comparison with
fresh ctime checks, then unlinks nonrecursively. Sidecars/backups follow write
-> sync -> atomic replace -> directory-sync. Post-side-effect flush failure
retains journals and requires recovery rather than success.

`SessionStore` recovers off-main. Active reconciliation blocks conflicting work;
unresolved attention blocks only new Copy/Move/Source Rename/Organization,
Clean Up/Trash, and Trash undo. Review, ratings, navigation, open/close/rescan,
saves, updates, and Quit continue; requested launch folders still open. Suggest
reconnect only for reported unavailable volumes. Rescan only the exact current
source folder affected by recovered moves. Keep staged/completed copies and
publish verified temporaries durably without the source mounted. Completed Move
items stay at destination; incomplete items/pairs restore source.
**Keep Files As They Are** accepts only canonical UUID journals, atomically
renames to `.forgotten`, and preserves contents/media; refuse arbitrary
`.operation` files. Only `LouppeApp` enables launch recovery. Test stores default
to none and inject disposable journals, never live photographer operations.

Persistence has its separate stable-identity lock for the whole sidecar/backup
CAS. Acquisition is nonblocking with a short deadline; contention is retryable
and cannot freeze Close, switching, or Quit.

## Export lifecycle

Main actor evaluates one pure decision + stars + color AND predicate and snapshots
items/exact file counts. `ExportWorker` runs Copy/Move off-main with
`ThrottledProgress`; apply one result. `ExportWorker.makePlan` reserves names
with one suffix per photo/XMP family, preserving RAW+JPEG/canonical XMP/application
basenames. Reject normalization-equivalent internal names before searching.
Cancellable search checks reservations before I/O and caches next suffixes by
complete normalized family, avoiding quadratic repeated-name planning.

`XMPExportPlanner` resolves complete live stem families and prepares merged bytes
before journal activation. Version-4 plans bind every media/XMP source,
temporary, destination, identity, role, and digest before mutation. Failed/cancelled
pairs roll back; earlier completed photos remain. Staged/flushed copies survive
source disconnect. Move retains rollback. Transfer fully selected canonical XMP
only after durable merged destination; packets shared with unselected members
stay at source and are copied.

`MultiDestinationExportPlanner` is Copy-only. Pure membership assigns each item
to one explicit typed route, unmatched, or blocking overlap. Validate/freeze
folders, reject duplicate resolved destinations/empty routes, and sum capacity
by volume. Combine per-route `ExportWorker.Plan`s before one journal activation.
No fallback includes unmatched files. XMP stem families must stay in one route;
refuse splits that would generate competing sidecars.

`SessionStore.activeFileOperation` alone owns Clean Up, Copy, Move, Rename, and
Organization. Block switching, rescan, rating/selection, undo, Clear All Ratings,
conflicting work, updater installation, and Quit. Keep one `ProcessInfo`
`idleSystemSleepDisabled` activity through the transaction/recovery. Display
sleep remains enabled; lid-close sleep cannot be overridden.
After wake, transient source-device/I/O errors allow up to 60 awake seconds for
exact journal-bound identity, then one retry only if no temporary exists.
If `copyItem` leaves a partial, checkpoint identity before rollback; remove only that inode through the
two reserved paths. A complete pre-staged Copy requires source revalidation and
byte equality before publication. Unrecorded legacy partials remain untouched.
`finishExport` clears state; Move removes completed IDs, clears stale undo,
rebuilds/filter/saves. The modal sheet blocks rating/navigation keys.

`ExportDestinationValidator` resolves symlinks, refuses source/descendants,
checks write permission and Copy capacity. Same-volume Move needs no full-size
free space. Preflight and workers probe exclusive-rename capability on bound
parents: known unsupported Copy/Export Move destinations fail before media or
journals exist; unknown capability keeps syscall validation. ExFAT-source → APFS
Copy remains supported; Source Organization/Renaming retain their scoped fallback. Workers receive that resolved path plus device/inode/birth binding,
so retargeting chooser aliases cannot redirect writes. Copy opens matching
parents before journal activation for ordinary/XMP/multi-route plans, creates
media/generated temporaries with `openat`, preserves metadata through Apple's
`fcopyfile`, and publishes with `renameatx_np` in the same held directory.
Pre-start replacement returns a retryable error without journal; later change
retains evidence and **Keep Files As They Are**. Move also checks parent identity
before starting and retains journaled renames. Cross-check ambiguous zero from
important-usage capacity with `statfs` to avoid false full-volume reports from
File Provider.

## Source Organization lifecycle

`SourceOrganizationPlanner` takes immutable All/Filtered/Selected snapshots and
all session sidecar-family members. Build hierarchy from checked level order;
reserve exact destinations. Existing targets, converging sources, split shared
XMP, or unsafe components block the entire plan; no collision suffixes.
Preview runs off-main and polls cancellation throughout, so scope/order changes
retire stale work.

`AppDateFormat` uses the Mac's effective short date for **Full date**, including
custom formats. **Year and month** and **Year** inherit its field order, widths,
and separator. Existing
folder uses schema-6 original parent bytes at top-level/full depth. Unchecking
flattens into chosen levels; retain old folders even when empty.

`SourceOrganizationWorker` activates `.organizeSource` before directory creation
or moves. Revalidate opened-folder identity, create only normal descendants via
exact POSIX paths, then execute confirmed `ExportWorker.Plan` with exclusive
renames. RAW+JPEG/eligible XMP shares one rollback group. Leave `.acr`, unsupported,
hidden, and unrelated files untouched. Success rescans that folder and pushes
`.restoreOrganization` to session undo; ⌘Z journals the reverse move and rescans.
Neither direction removes directories. Recovery keeps completed groups at
destination and restores incomplete groups, as Export Move does.

Record source filesystem type. ExFAT lacks `RENAME_EXCL` and may return `EINVAL`,
`ENOTSUP`, or `ENOTTY` for directory sync. Warn before enabling reduced durability.
After journaling but before media moves, two random owned probes verify
Foundation refuses an occupied target, then preserves inode/bytes on a free-target
move. Remove probes afterward. Only ExFAT Organization/Renaming, rollback, undo,
and recovery use this Foundation path. Recheck devices before every move and
identity afterward; tolerate only unsupported directory-sync errors. APFS
requires exclusive rename and directory sync.

## Source Renaming lifecycle

Source Renaming has its own Info/batch UI and reuses Organization's
snapshot → plan → background move → rescan boundary. Recipes use fixed
`yyyy-MM-dd`/`HH-mm-ss`, sanitized camera/lens/original components, and sequence
ordered by capture time/stable ID. Default Date + Time + Sequence is sortable
and independent of visible sort.

Keep source directory/extension and reserve filenames plus directory+stem
families so unrelated RAW/JPEG cannot become paired on rescan. Existing targets,
duplicate output, case aliases, ambiguous/shared partial XMP, or Lightroom
`.acr` companions block the whole plan. Canonical/extension-qualified XMP follows
complete families without packet rewrites.

Journal `.renameSource` before mutation and `.restoreRename` for ⌘Z.
RAW+JPEG/XMP is one journal item even when reviewed separately: retain complete
families or roll back incomplete ones as a unit. Rename/undo rescan instead of
mutating immutable `PhotoFile` paths. Physical identity preserves ratings while
ordinary scan remaps current, selection, stars/colors, and original parent metadata.

## Prepared session index

`PreparedSessionIndex` owns pure item-ID, sort, filter, group, header, and
visible-position maps. `SessionStore` publishes arrays; logic tests need no
window/observable object. Instruments signposts are **Rebuild Item Index**,
**Sort Session**, **Filter Session**, and **Build Visible Groups**; inspect them
before algorithm changes or another map.

Synthetic 1k/10k/100k fixtures on 2026-07-26, conservative unoptimized build:

| Items | ID map + camera sort | JPEG filter + 25 groups/locations |
|---:|---:|---:|
| 1,000 | 13 ms | 1 ms |
| 10,000 | 117 ms | 8 ms |
| 100,000 | 1,607 ms | 104 ms |

Comparison baselines, not fixed pass/fail limits; CI varies. Assert structural
counts/all locations. Grid groups use metadata-derived stable IDs so removing
first members does not recreate surviving sections.

`FolderScanner.sortItems` uses `PhotoSort()`. Prepared indexing reuses physical
order for default sort, avoiding duplicate O(N log N) localized-name sorting
on open/default-sort return. Other keys rebuild their own order.

## Selection state

`SelectionState` owns explicit indices/stable IDs, range, edge, command-toggle,
rubber-band, filter intersection, and rescan remapping. `SessionStore` publishes
projection and owns current/playback/prefetch side effects.

Empty explicit selection means current visible item; zero filter matches means
empty effective selection. Logic/app XCTest cases prevent rating hidden media
or remapping stale numeric positions. After filter/restore, surviving explicit
selection determines current in prepared visible order, keeping Gallery,
keyboard ratings, and highlighted selection aligned.

## Verification

Follow [AGENTS.md](../AGENTS.md) for build, test, and real launch. Performance
changes also run `./Tests/run_performance_checks.sh` on disposable media with
macOS Trash access for round trips. Never test Clean Up on irreplaceable originals.
