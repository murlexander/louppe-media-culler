# Media and native UI implementation — 2026-09-29

Canonical checkout: `/Users/alexander_markin/Documents/code/louppe/app`.
Implemented M1, M2, M3, U1, and U2 locally, preserving the Help corner fix and existing
work. No branches, pushes, original-media changes, install, or docs/changelog edits.
SessionStore, Models, DurableFileIO, FileOperationJournal, and others' files were untouched.

## Final source changes

### M1 — uncached media reads cannot adopt same-path replacements

- `Sources/Louppe/MetadataExtractor.swift:8`: `MediaSourceRevision` captures the already scanned typed `FileOperationJournal.FileIdentity` alongside the source URL, without opening the filesystem. Worker validation uses a single `lstat` per check, rejects non-regular files/symlinks and compares device, inode, size, and nanosecond modification/change/birth timestamps. It does not query volume/resource metadata repeatedly. Optional identity fields retain compatibility with older identities; genuinely identity-less synthetic/legacy items retain their prior behavior.
- `MetadataExtractor.swift:43`: validates immediately before and after the source read, so a read that encountered a replacement cannot return/cache its result. The full photo metadata panel validates the live read and returns Filename plus actionable File changed/rescan copy when invalid. Text/video/audio metadata uses the already captured scan metadata and requires no new source read.
- `Sources/Louppe/ImagePipeline.swift:158,318,338`: thumbnail/full decode captures validation before dispatch, checks source identity before and after uncached ImageIO or first-movie-frame decoding, and only then inserts memory/disk cache results. ImageIO already requests immediate decode. Existing memory-cache hits and trustworthy identity-bound thumbnail cache reads retain the original validated bytes and remain filesystem-free with respect to the source. Prefetch shares these guarded paths.
- `Sources/Louppe/HistogramPipeline.swift:279,306,602,629`: preview and RAW source analysis checks before/after read on existing bounded worker lanes; stale results are not published/cached.
- `Sources/Louppe/HighResolutionImagePipeline.swift:11,138,277,310`: lazy zoom recipes carry their captured revision. Recipe construction validates the read; every newly rendered tile validates before and after actual Core Image rendering, including when the recipe was cached before the pathname replacement. Existing decoded tile hits remain safe cached pixels. The two-operation lane and 128 MiB budget are unchanged.
- `Sources/Louppe/AudioLevelPipeline.swift:279,306`: whole-clip audio read validates before/after the decoder. A changed read returns nil and does not enter the numeric LRU.
- `Sources/Louppe/VideoPlaybackController.swift:151,354,385`: cold synchronous preparation performs the explicitly approved single bounded `lstat`, preserving immediate prepare/play behavior for matching identities. It publishes actionable rescan copy and creates no AVPlayerItem for a mismatch. Ready-to-play rechecks identity on a detached worker and accepts the result only for the same revision and player generation. Existing already prepared matching-player reuse remains immediate. Decode/read loops stay off-main.
- TextPreviewLoader already performs before/open/after source identity checks with a file descriptor; no changes were needed there.

Disposable-file regressions cover inode/symlink/in-place replacement, guarded-read races, stale RAW/audio results, cached lazy-source rendering, cold-cache refusal/fresh-rescan success, and player preparation. Validated memory caches still return original image/numeric data after source removal.

### M2 — transparent photographs retain correct luminance and valid premultiplied pixels

- `Sources/Louppe/HistogramPipeline.swift:105,139,159`: analysis ignores zero alpha and converts nonzero premultiplied color components back to straight color before the unchanged luminance/clipping thresholds. Overlay also ignores zero alpha, blends warning red in straight color and multiplies the output components by the original alpha.
- Opaque behavior and existing thresholds remain unchanged. Transparent whites no longer count as shadows. Every output color component stays at or below alpha; transparent pixels and nonwarning midtones are untouched.
- Added an alpha 0/3/128/255 black/white/gray regression to `Tests/LouppeTests/HistogramTests.swift`. Existing opaque/shared-warning-range tests continue to pass.

### M3 — abandoned whole-clip readers release the single lane promptly and safely

- `Sources/Louppe/AudioLevelPipeline.swift:263`: added a small decoder injection boundary matching the existing RAW pipeline pattern, allowing deterministic real operation/cancellation tests without AV service timing assertions.
- `AudioLevelPipeline.swift:335`: the bridge cancels its detached task at the existing 50 ms polling boundary and retains the operation's serial slot until the task actually exits. It returns no canceled partial analysis.
- `AudioLevelPipeline.swift:446,483`: canceling the final waiter unregisters and cancels an executing operation as well as queued work. `finish` compares the exact pending operation identity; a canceled A completion cannot consume waiters or cache data for a newly requested A with the same revision. A surviving coalesced waiter keeps its reader alive.
- The same exact-operation completion guard was added to preview/RAW histogram completion (`HistogramPipeline.swift:328,647`) because those pipelines already unregister running canceled requests and had the same immediate rerequest race. A focused RAW regression covers the actual canceled-running/rerequest sequence.
- Decoder concurrency, numeric result/envelope cache limits and per-channel analysis remain unchanged.

### U1 — opening or closing Filter preserves exact stored cutoffs

- `Sources/Louppe/Views/FilterView.swift:6`: `NumericFilterRangeDraft.resolve` parses only endpoints explicitly edited by the reviewer and preserves the exact untouched endpoint. Disabled ranges use the folder's available endpoints.
- `FilterView.swift:606`: the TextField binding marks actual user writes. Initial formatting/reset/reverting invalid text does not mark a field edited.
- `FilterView.swift:908,967`: live validation uses the same exact endpoint resolution as commit, so an edited lower bound of 20.9 cannot incorrectly pass against a displayed 21 whose real stored upper bound is 20.8.
- `FilterView.swift:984–1076`: all five numeric range commits require a marked edit, update only their own range and clear successfully committed edit flags. Existing edge snapping, parsers and enable/full-range semantics remain intact.
- `FilterView.swift:1079,1118,1129`: syncing clears edits; unedited initialization does not even schedule a debounce. Debounced/disappear commits still publish one combined filter assignment if real changes exist. Unrelated exact aperture/shutter/ISO/duration/frame-rate cutoffs are not reparsed.
- Pure regressions cover no-edit/no-parse, one edited endpoint, disabled range fallback, precision-aware invalid range and full-range edge snapping. A real NSHostingView lifecycle test opens Filter, waits beyond debounce and removes the view, preserving all five exact stored cutoffs including duration 10.2...20.8 and frame rate 29.970029...59.940059.

### U2 — native video controls stay visibly available during playback

- `Sources/Louppe/Views/VideoPlayerView.swift:22,53`: Gallery transport/full-screen/Picture-in-Picture controls are always visible and mounted. Removed hover-controlled subtree removal. The existing compact native buttons/sliders/capsule and AVPlayerLayer surface remain; there is no whole-picture hover scrim.
- Initial attempt to retain invisible opacity-zero controls with FocusedValue/VoiceOver visibility was discarded. Native keyboard hosting could not prove that behavior reliably; the final simpler persistent presentation requires no invisible-focus assumption or assistive technology detection.
- `VideoPlayerView.swift:4,89`: a DEBUG-only hosted lifetime probe tracks the actual controls subtree mounting, following existing native-host test probe patterns. It is absent from the release product.
- `Tests/LouppeTests/GalleryVideoAccessibilityTests.swift:8`: real hosted AVPlayer fixture plays a disposable minute WAV on a Gallery surface with pointer/focus elsewhere, verifies the transport remains mounted while playing and after pause. When the host supplies AX objects, it checks Pause/Timeline/Volume/full-screen labels; when Full Keyboard Access is enabled, it also sends a real native Tab. This machine supplies neither condition, so those conditional native checks were not exercised; see limits below.

## Verification

Focused command (full Xcode, own temporary build; runtime outside restricted sandbox for native AV services):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-keychain \
  --scratch-path /private/tmp/louppe-fixes-2026-09-29/media-swift-build \
  --filter 'MediaRevisionTests|AudioCancellationTests|NumericFilterDraftTests|HistogramTests|ImagePipelineCacheTests|AudioSupportTests|VideoPlayerViewTests|GalleryVideoAccessibilityTests'
```

**Final result: 51 tests, 0 failures, 0 skips**, 1.458 seconds of test execution. Log: `/private/tmp/louppe-fixes-2026-09-29/media-focused-test.log`.

Breakdown: AudioCancellation 2; AudioSupport 5; GalleryVideoAccessibility 1; Histogram 12; ImagePipelineCache 8; MediaRevision 6; NumericFilterDraft 4; VideoPlayerView 13. Existing native player generation, seek, resume, rate, audio failure and file-operation stop regressions pass. Cache compatibility migration/coalescing cases pass.

Two actual-queue tests use controlled decoders: cancellation reaches running work;
B cannot start before canceled A exits; same-revision rerequest receives 0.9 instead
of abandoned 0.1; concurrency stays at one; only final results cache; one canceled
coalesced waiter leaves the other alive. No decode-speed threshold.

The optimized audit probe was rebuilt from final production sources with selected
Xcode Swift, `-O -parse-as-library`, and temporary cache/fixtures. Source:
`/private/tmp/louppe-fixes-2026-09-29/media-stage/media-probe.swift`; binary:
`media-probe` in that directory. Build/runtime logs:
`/private/tmp/louppe-fixes-2026-09-29/media-probe-build.log` and
`/private/tmp/louppe-fixes-2026-09-29/media-probe-result.log`.

### Actual-media before/after evidence

| Probe | Original audit | Fixed production code |
| --- | --- | --- |
| Scanned black photo replaced by white at same path | old revision thumbnail/full/histogram adopted white; cache retained white after black rewrite | old thumbnail/full/histogram rejected; no contaminated old-revision cache after rewrite |
| Premultiplied white `[3,3,3,3]` | shadow 1, highlight 0, bin3 1 | shadow 0, highlight 1, bin3 0 |
| Warning overlay for same alpha3 white | invalid `[184,1,1,3]` | valid `[3,1,1,3]` |
| One-second stereo WAV selected after canceling one-hour 48 kHz stereo WAV at 100 ms | waited 4.0131119 s behind abandoned full reader | waited 0.2570311 s, about 94% less in this run |
| Re-request abandoned long WAV | 0.0000390 s cache hit, proving abandoned whole clip reached EOF/cache | 4.5741349 s fresh analysis, confirming canceled partial/full work did not populate cache |
| Canceled waiter's nil result | 0.0000260 s | 0.0034181 s |

Timings are local observations, not thresholds. Short-request time includes asset
startup/decoding; deterministic tests separately prove serial-reader exit.
Preexisting AVAssetReader `copyNextSampleBuffer` macOS27 deprecation remains;
no new deprecated API was added.

`git diff --check` passed for owned source/existing tests. The coordinator owns
full-suite, strict-concurrency/performance, release, launch, and install checks;
no second SwiftPM build uses this scratch path.

## Files changed by this agent

Source (8): `MetadataExtractor.swift`, `ImagePipeline.swift`, `HighResolutionImagePipeline.swift`, `HistogramPipeline.swift`, `AudioLevelPipeline.swift`, `VideoPlaybackController.swift`, `Views/FilterView.swift`, `Views/VideoPlayerView.swift`.

Existing tests (1): `Tests/LouppeTests/HistogramTests.swift`.

New focused tests (4): `Tests/LouppeTests/MediaRevisionTests.swift`, `AudioCancellationTests.swift`, `NumericFilterDraftTests.swift`, `GalleryVideoAccessibilityTests.swift`.

## Limits and remaining verification

- Host-native diagnostic failed equally for paused/visible and playing/faded controls: `NSHostingView.acceptsFirstResponder == false`, AX tree empty, `NSApp.isFullKeyboardAccessEnabled == false`; Tab stayed on the external native button. Diagnostic log `/private/tmp/louppe-fixes-2026-09-29/video-focus-diagnostic.log`. The test does not alter the user's global keyboard or VoiceOver preferences. Consequently actual Tab control-by-control traversal and live VoiceOver announcement/action remain unverified here. The final implementation avoids hover concealment altogether, and the hosted structural regression confirms playback no longer removes the control targets.
- No screen capture/visual inspection is available because this host lacks Screen Recording permission. Root is responsible for final app launch and sidecar inspection; manual visual/VoiceOver review remains useful for the persistent controls' appearance.
- Validation is a scan-identity before/after read contract, not continuous monitoring of externally edited originals. Already validated original cache pixels remain usable until rescan; lazy new source reads reject a changed path. Player guard runs on cold preparation and asynchronous ready-to-play, rather than introducing filesystem polling during playback.
- No real RAW camera fixture was available for a hardware decoder regression. RAW eligibility, delay/coalescing/cancellation/operation identity and stale entry are tested; real PNG ImageIO, real lazy Core Image source, real WAV reader/playback are exercised.

## Integration follow-up — native playback synchronization

`GalleryVideoAccessibilityTests` observed `isPlaying` false 100 ms after its initial assertion.
`for ... where !isPlaying` skipped the wait because `toggle()` publishes intent
before native playback. Readiness/buffering/KVO invalidates that timing assumption;
external-button focus did not pause the player.

Only the test changed. With focus outside the video, it awaits AVPlayerItem readiness,
`.playing`, controller observation, and time beyond 0.05 seconds before inspecting
transport. A bounded 5-second timeout retains real readiness/playback failures;
production source stayed frozen.

Integration group (`GalleryVideoAccessibilityTests|AudioSupportTests|AudioCancellationTests|GridControlGestureTests|FolderHierarchyTests|HotkeyTests|VideoPlayerViewTests`):
**69 tests, zero failures**, 4.940 seconds, with native playback and external focus.
Gallery startup took 0.821 seconds, exceeding the old 100 ms assumption. Log:
`/private/tmp/louppe-fixes-2026-09-29/gallery-integration-test.log`.
The coordinator was rerunning the full suite with this test correction.