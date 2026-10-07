# Louppe media and native UI audit — 2026-09-29

Pre-fix findings from 29 September. Current work: [BACKLOG.md](../../../BACKLOG.md#audit-follow-ups).

Canonical source: `/Users/alexander_markin/Documents/code/louppe/app`. Read-only working-tree audit, including uncommitted changes. No source/tests, Git state, originals, preferences, installation, or releases changed. Artifacts: `/private/tmp/louppe-audit-2026-09-29/media-repro/`.

Read `app/AGENTS.md`, shared `../AGENTS.md`, the Media and Native UI references in `Docs/DEVELOPMENT_DETAILS.md`, and the relevant ownership/resource/caching/concurrency rules in `Docs/PERFORMANCE.md`.

## Findings

Five P2 issues: four reproduced with executable production logic; one established by SwiftUI visibility. No destructive-file defect found in this scope.

| ID | Finding | Evidence |
| --- | --- | --- |
| M1 | Post-scan file replacement can seed old-identity caches with replacement pixels | Executed actual ImagePipeline + HistogramPipeline with actual Models/Journal |
| M2 | Clipping analysis/overlay mishandles partially transparent pixels | Executed actual ClippingWarningProcessor on a valid premultiplied RGBA pixel |
| M3 | Cancelled whole-clip audio analysis monopolizes the single queue until EOF | Executed actual AudioLevelPipeline with a one-hour sparse WAV, then a one-second WAV |
| U1 | Opening/closing Filter can silently round an existing precise numeric cutoff | Executed exact FilterView draft sync/commit/format/parse/snap methods with an isolated store stub |
| U2 | Gallery video controls disappear during keyboard/accessibility playback | Direct SwiftUI control-visibility trace; native VoiceOver interaction not executed |

### M1 — P2: Validate source identity at actual read/cache-publication boundaries

**Primary locations:** `Sources/Louppe/ImagePipeline.swift:317–330` and `335–339`; related `Sources/Louppe/HistogramPipeline.swift:301–325`.

**Trigger:** Scan a photo, retain the resulting `PhotoItem`, and replace the source at the same pathname before its first thumbnail/full/histogram decode. Navigation keeps using the scan snapshot until a rescan.

**Observed behavior:** The v5 cache key includes scan identity, but decode reads the current URL without verification and publishes replacement pixels into old-identity memory/disk caches. Task guards miss it because the retained `PhotoItem` did not change.

**Executable evidence** (`media-repro/main.swift`, actual production source files; `media-repro/result-unsandboxed.txt`):

```
LIVE_IDENTITY_DIFFERS=true
OLD_REVISION_THUMB_PIXEL=[255, 255, 255, 255]
OLD_REVISION_FULL_PIXEL=[255, 255, 255, 255]
OLD_REVISION_HIST_HIGHLIGHTS=1, SHADOWS=0
OLD_REVISION_CACHED_AFTER_BLACK_REWRITE=[255, 255, 255, 255]
```

A white PNG replaced the scanned black PNG with a different inode. The retained item's thumbnail/full/histogram used white; rewriting black still returned the contaminated thumbnail. `FileOperationJournal.captureIdentity` proved the mismatch; the key used production `PhotoItem` identity.

**Consequence:** Replacement pixels appear beside old metadata/identity, misleading review. Separate file-operation identity guards remain; no replacement deletion/overwrite is claimed.

**Related source traces:** `HighResolutionImagePipeline.swift:135–158,275–303` builds lazy sources from `item.primaryURL` without verification. `AudioLevelPipeline.swift:270–301,337–346`, `VideoPlaybackController.swift:169–172`, and `MetadataExtractor.swift:76–83` likewise omit the read boundary. These lanes were not separately reproduced and are not five extra findings. `TextPreviewLoader` already checks before/open/after.

**Minimal correction:** Keep body-time cache lookup filesystem-free. Pass scan identity into uncached I/O; verify before/after and reject mismatched publication/cache with a changed-file/rescan result. Lazy Core Image must hold verified bytes/handle or recheck tile rendering; URL-recipe validation alone is insufficient. Test replacement after item creation, including same-path/same-mtime and delayed reads. Existing reconstructed-item key tests miss this boundary.

### M2 — P2: Preserve the premultiplied-alpha contract in clipping work

**Locations:** `Sources/Louppe/HistogramPipeline.swift:105–112,139–150,171–184,204–212`.

**Trigger:** Preview a PNG/TIFF with partially transparent pixels and inspect its histogram or enable the clipping overlay.

**Root cause:** The processing bitmap is declared `premultipliedLast`, but analysis thresholds raw RGB bytes as if they were straight, fully opaque color. The overlay blends with full-intensity red without multiplying the warning by the retained alpha. It also transforms alpha-zero pixels instead of skipping them, creating invalid RGB values in nominally fully transparent output.

**Executable evidence:** A valid one-pixel image containing straight white at alpha 3/255 has premultiplied bytes `[3,3,3,3]`. Actual production processor output:

```
TRANSLUCENT_WHITE_HIST_SHADOW=1, HIGHLIGHT=0, BIN3=1
TRANSLUCENT_WHITE_OVERLAY_PREMULTIPLIED_PIXEL=[184, 1, 1, 3]
```

White is reported as shadow. Red 184 exceeds alpha 3, violating premultiplied output and risking bright halos. Opaque tests pass at alpha 255; the existing transparency test covers only alpha-zero histogram exclusion.

**Minimal correction:** Define whether clipping measures straight source RGB or the visible composited color, and implement it consistently. For straight source RGB, ignore alpha zero, unpremultiply nonzero-alpha RGB before calculating luminance, then blend in straight color and re-premultiply the result by the original alpha. If clipping is intended to represent composited appearance, composite onto the actual backdrop first; still never write RGB greater than alpha into a premultiplied output. Add alpha 0, 3, 128, 255 tests for white, black, and midtone colors, ensuring overlays preserve valid alpha representation.

### M3 — P2: Cancel abandoned running audio readers at a safe boundary

**Locations:** `Sources/Louppe/AudioLevelPipeline.swift:244–247` (one-operation queue), `317–334` (bridge cancellation), `468–487` (final-waiter policy).

**Trigger:** Open a long recording, leave it after its waveform/meter reader has started, then select another recording. Canceling the Gallery/Info tasks removes their waiters but does not cancel an executing reader.

**Observed behavior:** `cancelWaiter` cancels only when `!pending.operation.isExecuting`. A running operation with zero waiters continues through the entire source and is retained for cache warming. Its `isCancelled` closure never becomes true, so the decoder's cancellation checks do not stop it. Every subsequent recording shares the single queue and waits for this abandoned decode.

**Executable evidence:** Release-optimized standalone harness linking actual production `AudioLevelPipeline` and actual `PhotoItem`. A one-hour stereo 48 kHz silent WAV was a sparse disposable file (691,200,044 logical bytes); cancel occurred 100 ms after starting its analysis. A fresh one-second WAV requested immediately afterward:

```
AUDIO_CANCEL_RETURNED_NIL=true AFTER=2.5987625122070312e-05s
NEXT_ONE_SECOND_AUDIO_ANALYSIS=true WAIT=4.01311194896698s TOTAL=4.119922995567322s
ABANDONED_LONG_ANALYSIS_CACHE_HIT=3.898143768310547e-05s
```

Caller cancellation returned promptly, but the hour decoded into cache and delayed the one-second clip about four seconds. Compressed/high-channel/slow-storage formats were not timed; no delay extrapolation is claimed.

The sandboxed WAV read returned nil through AVFoundation services; `result.txt` preserves that limit. Timing uses `result-unsandboxed.txt` with escalated native-media access. No user files/preferences changed.

**Minimal correction:** Cancel executing decode when its last waiter leaves. Hold the serial slot until AVAssetReader exits; `operation.cancel()` alone is insufficient because the bridge returns immediately after `task.cancel()`. Preserve coalescing during shutdown and reconcile by operation identity/generation. A deterministic slow-reader test must prove no overlap and B starts after A cancels without EOF.

### U1 — P2: Preserve exact numeric filter values unless a user edits them

**Locations:** `Sources/Louppe/Views/FilterView.swift:131–140,936–945,968–999,1016–1027,1152–1184`.

**Trigger:** Apply a precise interior numeric range, reopen Filter, then close it without editing. For example, folder durations span 5…30 seconds and the active cutoff is 10.2…20.8 seconds.

**Observed behavior:** Appearance formats drafts to whole-second duration, two-decimal aperture, three-decimal fps, or rounded decimal/reciprocal shutter. Disappearance commits all drafts, edited or not. Snapping protects folder extrema only, so interior display rounding becomes authoritative. Editing one field also commits the others.

**Executable evidence:** `media-repro/filter.swift` contains exact extracted FilterView range/commit/parse/format/snap methods, executed unchanged against a minimal store stub and production `PhotoFilter`/formatters. This reproduces the pure operations invoked by appearance/disappearance; it is not a hosted popover interaction test.

```
BEFORE_POPUP: 10.2...20.8
SYNCED_DRAFTS: 0:10...0:21
AFTER_NO_EDIT_CLOSE: 10.0...21.0
```

**Consequence:** Merely inspecting Filter can change visible media, widening or narrowing a cutoff. The same concern applies to non-extreme aperture/shutter/fps cutoffs. Neutral full-folder edges already have protection and should retain it.

**Minimal correction:** Track edits or original exact values/display strings. Commit only modified fields; initialization/reformatting is not editing. Add hosted open/close and per-range exact-value regressions, including changing one range without altering others.

### U2 — P2: Keep playback controls reachable when focus is keyboard/accessibility-owned

**Locations:** `Sources/Louppe/Views/VideoPlayerView.swift:37–73,76–79,94–95`; Play/Pause is in `214–220`.

**Trigger:** Start a Gallery video with keyboard or VoiceOver, with the pointer outside the movie pane, or move the pointer out while a playback control retains focus.

**Source-proven behavior:** All transport, timeline, volume, PiP, and fullscreen controls are conditional children of `if showsControls`. That condition is only `isHovering || !playback.isPlaying || isScrubbing`. Once the video is playing without hover or scrub, the entire subtree is removed, regardless of keyboard focus, VoiceOver state, or accessibility focus. The fitted `AVPlayerLayer` surface contributes no native transport alternative.

**Consequence:** Activating Play can remove its focused control and AX subtree. K may still pause through the session monitor, but timeline/volume/PiP controls vanish. Native VoiceOver focus relocation is untested; subtree removal is source-proven.

**Minimal correction:** Keep controls visible while keyboard or accessibility focus is within them, and while VoiceOver requires a transport surface. Alternatively keep a stable accessible transport surface while fading pointer-only decoration. Avoid removing the active focused element. Verify actual keyboard tab traversal and VoiceOver start/pause/seek/volume/fullscreen interaction with the pointer outside the pane.

## Optimization opportunities (not additional reproduced crashes)

1. **Routing-copy confirmation is lazy only by route, not by file.** `ExportView.swift:916–930` wraps up to twelve route blocks in a LazyVStack, but each block is an eager VStack containing `ForEach(route.files)`. The unmatched-file block at `933–945` is eager too. A route containing tens of thousands of files becomes one enormous realized lazy child, so per-route laziness does not bound text/selectable-row creation. Flatten headers/files/dividers into one lazy list or use real lazy sections whose *file rows* are individual lazy elements. Preserve exact preview access; do not silently truncate safety-critical paths. No large hosted-sheet timing was run, so classify as structurally supported optimization, not a measured hang.
2. **Disk thumbnail budget is only pruned once on eligible launch.** `ImagePipeline.swift:110–128` schedules one delayed maintenance pass only at singleton initialization. Thumbnail writes at `326–330` do not trigger another budget check, and the pass does not reschedule. A long-running process can add arbitrary cache bytes after that pass, exceeding the documented 512 MiB/90-day budget indefinitely until a later launch. A same-day launch may skip pruning as well. Use utility-queue accounting and a coalesced threshold/periodic maintenance trigger while preserving the launch delay; avoid directory walks on every thumbnail. The 512 MiB condition is best described as a prune target in the current implementation, not a strict live ceiling.
3. **Fit-size measurement eagerly enters the RAW source lane.** `FullImageView.swift:417–423` immediately requests `HighResolutionImagePipeline.source` for each realized fitted image, even though the full-preview decode is guarded by a 40 ms dwell and neighbor prefetch by 60 ms. Source continuations are not individually canceled. Source creation retains lazy recipes rather than full decoded bitmaps, but CIRAWFilter creation/header I/O can be meaningful on RAW/slow media. Benchmark rapid navigation with cold RAWs before changing it; consider scan-cached oriented dimensions or the same short dwell for an uncached scale measurement.
4. **Secondary metadata detail is detached but unbounded across abandoned requests.** `MetadataPanel.swift:245–248` launches `Task.detached { MetadataExtractor.fields(...) }` and only drops the result after it finishes. The 80 ms dwell protects fast navigation, but once started, a slow file may keep running alongside later metadata reads; no queue/coalescer or worker cancellation is provided. Measure cold removable/network storage rather than assuming this is costly locally. If material, share a bounded/coalesced lane keyed by revision and perform source identity verification there.
5. **macOS 27 migration debt.** The selected SDK warns that AVAssetReader `add`, `startReading`, and `copyNextSampleBuffer` plus old AVPlayer notification aliases are deprecated. These are currently functional compatibility APIs, not audit failures. Migrate to current provider/async reader APIs as part of the audio-cancellation correction if that simplifies waiting for the actual stopped-reader boundary; retain support for the project's deployment target.

## Coverage and positive checks

### Media pipelines

- **ImagePipeline:** Reviewed public guards, separate full/thumbnail lanes, request coalescing and foreground promotion, memory cost limits, embedded-thumbnail fallback, first-frame background generation/timeouts, v5/legacy compatibility boundaries, disk promotion/healing, FNV disk key hashing, maintenance scheduling. M1 identified at uncached source reads; old cache-key separation itself is correct. No cache-key collision claim is made.
- **HighResolutionImagePipeline:** Reviewed lazy oriented source creation, queue bounds, source LRU, tile region mapping, clipping variants, tile LRU cost accounting, request retention/cancellation, normal/software contexts. Canceled queued waiters are resumed rather than stranded. Completion by key can consume a replacement request for the same immutable tile key; absent source-byte changes the result is equivalent, so this is not reported as a separate functional bug. Actual Core Image internal/GPU allocation is outside the explicit CGImage tile-cache accounting and was not measured.
- **HistogramPipeline/RawHistogramPipeline/ClippingPreviewPipeline:** Reviewed photo-only eligibility, bounded preview size, integer thresholds, transparent exclusion, bounded RAW linear buffer, delayed one-operation RAW lane, numeric LRUs, waiter cancellation/coalescing, clipping cache sizes. M2 concerns semi-transparent pixels, not normal opaque JPEG/RAW inputs. No true raw-photosite or inter-channel clipping claim is made; source labels correctly distinguish rendered and demosaiced RAW estimates.
- **AudioLevelPipeline/AudioLevelView:** Reviewed per-channel aggregation, signed envelopes/RMS/peaks, sample sanitization, temporal bin/cache budgets, PCM format/channel bounds, queue/cancellation, playback-following meter and downsampled Canvas waveform. Channels are not mixed down; whole-clip numeric payload is bounded. M3 identifies cancellation behavior rather than numeric-bin growth.
- **MetadataExtractor/VideoSupport:** Reviewed numeric sanitization, per-scan EXIF metadata, video/audio codec/header extraction, 15-second scanner bridges, bounded background worker assumptions, full Info fields, date/size formatting. Metadata work stays out of the SwiftUI body. Live read identity is included in M1's related lanes.
- **TextPreviewLoader/TextPreviewView:** Reviewed 1 MiB read cap, BOM Unicode decoding, NUL rejection, nonregular/leaf-symlink rejection, descriptor device/inode checks, scan identity before/after reading, cancellation checks, actor serialization, Markdown semantics, safe link-scheme filtering, retained native selection/scroll lifetime. No additional confirmed defect found. Complex Markdown layout and worst-case 1 MiB document layout were not visually stress-tested.
- **VideoPlaybackController:** Reviewed player ownership, remembered-position LRU, revision identity, status/end/failure callback generation guards, periodic observer/token teardown, rate/seek clamping, mutual exclusivity. Tested a real ready AVPlayer: seek to 20 seconds, seek to 60, immediately navigate away; actual currentTime and remembered position both stayed at 60. The suspected asynchronous nonzero-seek resume overwrite did **not** reproduce and is not a finding (`media-repro/seek.swift`, `seek-result.txt`).

### Native UI

- **Gallery/FullImage/Thumbnail:** Checked initial memory-cache seed, revision-qualified displayed state, task cancellation guards, view persistence, normal/clipping dwell, failure/retry paths, photo/media-specific branches. Gallery guards fitted-pinch completion against current store revision, preventing an old item closure from zooming a new photo.
- **ActualSizeImageView/ZoomViewport/PhotoZoomControl:** Checked persistent AppKit source generation, explicit placement requests, backing scale mapping, finite zoom clamps, fit/phone click geometry, slider/pinch handoff, native live-magnification terminal deduplication, drag panning, ten-frame reset/Reduce Motion, source-tile switch at 100%, visible ring retention, departure source retirement and balanced activity reporting. No new confirmed zoom/lifetime defect found. Actual high-resolution-source failure currently falls back to preview without a dedicated actual-size error/retry surface; this is a recovery/UX test gap rather than a demonstrated decode failure.
- **Browser/Grid/MediaTileAccessibility/PersistentVerticalScroller:** Reviewed directly observed lazy rows/cells, stable scroll IDs, bounds checks after structural mutation, immediate native single-click/double-click handling, rating-target isolation, rubber-band geometry/rendered-tile limitation, follow-scroll suppression/cancellation, native scroller configuration, accessibility actions/decision/stars/colors. Grid Play/Pause pointer action does not use the same follow-scroll suppression as photo/rating clicks; possible under-pointer movement is a low-priority UI consistency candidate, not a reproduced regression.
- **SessionView:** Reviewed modal confirmations/progress, shared Info-panel ownership, operation disabling, key-monitor AppKit window attach/detach lifecycle, exact-window/focus/modal gates, modifier normalization, review vs navigation shortcuts, text/VoiceOver chord preservation, shortcut/menu authority. Existing full HotkeyTests are the required integrated verification; root executed the complete Swift suite and should report its final results.
- **MetadataPanel/MetadataEditingControls/CameraQualityWarnings:** Reviewed revision guards, multi-selection eligibility, three histogram/audio tasks, filename planning cancellation and stale draft ownership, per-file metadata aggregates, cue preference/reset input commit paths, accessibility labels/actions. Source identity and unbounded secondary metadata readers are covered above. Stars/current-value accessibility ergonomics were not a standalone focus-order test.
- **Root/Welcome/Scanning/WindowContentLayout:** Reviewed phase-aware native window minimum/layout, usable-screen cap/vertical fallback, warning banners, display/backing changes, observation lifecycle, deferred state reports, folder drop decoding/validation, recents, drive chooser lifetime, cancel scan controls. No new confirmed phase/window defect found. Native display changes on a physically small display and delayed provider drops were not manually exercised.
- **Filter/Sort/ActionPalette:** Reviewed in-memory field bindings, checkbox/range validation, numeric debounce/commit, reset, dynamic action enablement, search/selection/keyboard actions and deferred sheet dismissal. U1 is the concrete numeric round-trip defect. No change to rating decision logic was made.
- **Export/Rename/Organize/SheetForm:** Reviewed selection/mode transitions, source inspection lifetime/cancellation, scope captures, planning cancellation flags, stale-result guards, preview/action separation, scrollable sheet content. Detailed filesystem mutation/recovery authority is owned by the other audit worker; this worker does not duplicate those conclusions. Copy-routing preview realization is the optimization above.

## Reproduction artifacts

- `media-repro/main.swift`: actual image replacement, alpha processor, and audio cancellation harness.
- `media-repro/repro`: release-optimized executable linked directly from canonical source files; module cache also stays in the disposable directory.
- `media-repro/result.txt`: sandboxed image/alpha evidence plus unavailable native audio result; not used for audio conclusion.
- `media-repro/result-unsandboxed.txt`: successful real AVFoundation run, including four-second abandoned-reader queue delay.
- `media-repro/filter.swift`, `filter`, `filter-result.txt`: exact extracted FilterView pure methods and reproduced precise-range drift (store boundary stub only).
- `media-repro/seek.swift`, `seek`, `seek-result.txt`: real AVPlayer ready-state seek/navigation check that rejected a suspected issue.
- `media-repro/fixtures`: only disposable PNG/cache/sparse WAV test inputs.

## Verification limits

The coordinator owns full test/build/launch checks; this worker did not install. Reproductions used unchanged canonical source, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, and a temporary module cache. Escalated native AVFoundation succeeded. No screen capture, VoiceOver, removable-drive/large-route benchmark, RAW/color corpus, or RSS/GPU trace was run; none is counted as passed.