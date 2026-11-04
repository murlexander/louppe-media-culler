# Progressive Photos review

Acceptance list for the lazy Photos workflow (23 October 2026):

1. Mount a complete, stable 1,000-asset inventory without reading image bytes.
   Keep the pinned fetch result, asset-ID decisions, capture dates, save barrier,
   recent-date queries and original-resource/Live Photo/RAW+JPEG rules.
2. Request unadjusted aspect-fit PhotoKit representations for realized tiles and
   the Gallery viewport. Bound admitted requests, pending requests, pixel memory,
   and a small local-only preheat window. Cancel departing views and batches.
3. Keep representation consent separate from original consent. Local-first
   requests work offline when Photos has a representation; cloud and failures
   remain per-item, retryable states. Never label a review preview as 100% detail.
4. Stream an original only for explicit original detail, RAW inspection, video
   playback or Copy. Retain the 5 GB staging ceiling and serialize originals;
   Copy stages/copies/releases one asset at a time through the journaled worker.
   Export the exact primary original, never the preview or Photos' edited image.
5. Do not infer missing EXIF, byte size or quality cues. Filters use known
   metadata; opening/scrolling must not trigger whole-chunk analysis/downloads.
6. Test mixed local/cloud/offline representations, request-ID cancellation races,
   large membership, bounded caches, sparse originals, exact-byte export,
   overlapping decisions, failed saves, reopen and switching. Run full keyboard,
   Browser/Grid/scroller gates and performance checks before installation; build
   with full current Xcode and verify the official app launches in background.

## API decisions

Checked Apple's current documentation and the installed macOS 27 SDK headers:
[PHImageManager](https://developer.apple.com/documentation/photos/phimagemanager),
[PHCachingImageManager](https://developer.apple.com/documentation/photos/phcachingimagemanager),
[version](https://developer.apple.com/documentation/photos/phimagerequestoptions/version),
[network access](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed),
and [progress](https://developer.apple.com/documentation/photos/phimagerequestoptions/progresshandler).

Use asynchronous `.unadjusted`/`.aspectFit` requests, exact target sizing and
explicit network options. PhotoKit may callback before returning its request ID;
cancellation may produce no callback. Treat degraded pixels as previews, never
originals. `.original` image requests favor RAW in combined assets but are not
an exact-original file export contract: export continues to use the asset's
primary `.photo`/`.video` resource through PHAssetResourceManager.

PhotoKit owns its private caches and may need source data to render an uncached
representation; target size bounds requested pixels, not iCloud transfer bytes.
Louppe cannot promise that enabling representation downloads downloads only
thumbnail bytes. Review does not issue maximum-size image requests.
The separate, confirmed File → Add to Album command changes only album
membership or creates an album in a chosen folder. It uses bounded metadata-only
PhotoKit transactions, no original/image requests. See DEVELOPMENT_DETAILS.md
for its save, cancellation, verification and partial-result boundaries.

Milestone: stable browsable inventory and mocked large-batch opening first;
then bounded representation/original loading and integrated export/UI validation.

## Focused validation checkpoint

Full Xcode, 23 October 2026:

```sh
LOUPPE_PHOTOS_SNAPSHOTS=/private/tmp/louppe-photos-lazy-snapshots \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --disable-keychain --build-system native \
  --scratch-path /private/tmp/louppe-photos-lazy-build \
  --filter 'PhotosImageRequestTests|PhotosLazyReviewTests|PhotosLibraryRangeTests|PhotosLibraryTests|PhotosResourceTransferTests|LocalizationTests'
python3 Scripts/check_localization_sources.py
```

50 tests passed, none skipped. Source catalog check: 2,208 literal callsites,
none missing. The disposable 1,000-asset mount took 38 ms in the final run,
including the test's polling delay; no representation/original request occurred.
Tests assert four image lanes, the pending bound, 96 MiB pixel-cache ceiling,
eight preheat assets, separate network choices, cancellation/cleanup, stable
ratings/reopen, and exact-byte sparse Copy with collisions and cancellation
preserving an earlier completed copy.

16 unordered, non-key native captures cover light/dark chooser top/bottom,
batch controls, Gallery local/cloud, mixed Grid at 1,512 points with Info, and
Copy setup top/bottom. The capture test permits Alex to switch his own apps;
it asserts the fixture windows remain hidden and XCTest never takes foreground.
Screenshots use generated pixels and mocked cloud states, not personal media.

This checkpoint does not claim live iCloud/permission/device validation. No
Photos permission changes or library writes occurred. The shared UI thread
owns final keyboard/Browser/Grid/scroller gates, release packaging and the
single official installation/launch; do not run those concurrently.

## Integrated installation checkpoint

The shared UI thread completed the official update after the Photos freeze:

- Full native gate run: 97 tests, 95 passed, two existing Settings AX-host skips,
  zero failures. Complete Hotkey/Browser/Grid/PersistentVerticalScroller suites
  were included, along with changed UI interaction checks.
- Mandatory performance: 75/75; standalone video checks passed, including the
  video-only Photos model seam. 32 changed-element English/Arabic light/dark
  captures passed independent review, in addition to the 16 Photos captures.
- `./build_app.sh` produced direct Louppe 1.13.0 (15); loose and archived release
  verification passed. `/Applications/Louppe.app` passed strict deep signature
  validation and matched all 178 verified `Contents/` manifest entries.
- Normal background termination honored the save/quit barrier. Background
  launch with a generated disposable PNG saved a valid session sidecar; a
  subsequent normal relaunch left the updated official app running. No global
  events, activation, force termination, commits or pushes occurred.

Live iCloud/Photos permission flows remain untested against a personal library.
Native control startup failed twice in the shared thread; active glass,
open-menu compositing and VoiceOver were not live-verified. Offscreen fixtures
and background process/sidecar evidence do not replace those remaining checks.

## Full-library follow-up — 25 October 2026

Normal UI now opens the complete library/album/date selection, including the
80,708-item live library used for acceptance. The pinned lazy fetch result and
asset-ID decisions remain; off-main preparation walks only lightweight metadata
with cancellation and coalesced progress. Media/original limits remain unchanged.
Initial ordinal Photo/Video labels avoid a resource sweep; original filename/type
resolve only for explicit detail/playback/Copy. Unknown formats remain unknown,
while original-inspection controls and meaningful format facets remain available.

See [the live SSD/Photos record](SSD_PHOTOS_2026-10-25.md) for final runtime
measurements, real permission/network acceptance, reviews and installation. The
older batch checkpoints above retain their historical scope.
