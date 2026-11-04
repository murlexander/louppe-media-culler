# Live SSD archive and full Photos library — 25 October 2026

Follow-up to the [archive foundation](ARCHIVES_2026-10-25.md).
Evidence: `/private/tmp/louppe-ssd-20261025`. Main remains at `386e64c`, matching
freshly fetched `origin/main`; existing uncommitted work is preserved. No commit,
push, release or website change. Local version remains 1.13.0 (15); latest
published release is 1.12.0. Full Xcode is selected per command.

## Acceptance

- Identify and profile the connected SSD using real files without changing source
  media or sessions. Distinguish app cache from filesystem cache.
- Pin the actual archive through Welcome; no pin control while reviewing.
- Open the complete authorized Photos library, with no required batch/page UI.
  Preserve complete membership, asset-ID decisions and safe session transitions.
- Keep media on demand, bounded and cancellable. Initial membership must not
  request images, originals, resources or downloads. Alex explicitly approved
  visible/nearby iCloud review images; original network access remains off.
- Run focused/full/required safety and native gates, independently review, package,
  install reversibly and verify the exact candidate. Record gaps as gaps.

## Real sources and baseline

Mac: 10 processors, 16 GiB RAM, macOS 27.0.1 (26A434).
USB SSD `WORK_FAST_A`, ExFAT, volume UUID
`E639F2A1-9378-30D5-9F66-48893D73FC6C`.
Source: `/Volumes/WORK_FAST_A/2023-2026 archive`.
Python inventory: 48,868 nonhidden files in 1,413 directories, including Capture
One support data; the scanner recognizes **16,975 reviewable physical files**.
The archive includes Nikon NEF, Fuji RAF, JXL, TIFF, HEIC, PNG and video.
Its 31 existing nested sidecars were hashed; the archive root has no sidecar.

The existing optimized read-only opening harness used the previously compiled
overnight implementation, one warmup and three measured repetitions, each for
Separate and Together pairing. Filesystem cache was uncontrolled/warmed by
inventory; this is not storage-cold I/O. Warm root metadata cache:

| Stage | Separate median | Together median |
| --- | ---: | ---: |
| Discovery | 3,535.9 ms | 3,481.6 ms |
| Pairing/identity projection | 396.6 ms | 395.8 ms |
| Metadata reuse | 197.4 ms | 196.1 ms |
| Metadata identity validation | 212.8 ms | 207.9 ms |
| Chronological sort | 138.2 ms | 140.6 ms |
| Final identity validation | 207.1 ms | 203.8 ms |
| Derived preparation | 87.4 ms | 87.0 ms |
| Complete worker | 5,100.6 ms | 5,046.5 ms |

Complete-worker tail samples: 10,022.3 / 5,911.2 ms. Discovery dominates warmed
reopening; more metadata caching alone cannot remove that cost.
Exact executable hash, flags, commands and cache caveats are in
`baseline/context.json` and `archive-before/opening-stages.json`.
An initial configuration attempt used one repetition and was rejected by the
harness's required 3–30 range before reading the source. The corrected run passed.

Photos authorization was granted by Alex. Live query returns **80,708** photos
and videos. The installed baseline opened 500 oldest-first items, with 162 batch
pages. The oldest preview initially returned `PHPhotosErrorDomain` 3164;
the selected SDK identifies this as network access required. After consent a
2,046 × 1,436 review image displayed; original detail was not requested.
The idle baseline process used about 101.5 MiB RSS after that preview.

## Implementation and measurement boundaries

Welcome has a compact **Pin Folder…** action even with no pins. It selects and
pins a folder without opening/scanning/saving it. The exact selected URL owns
scope authority; actor-side fresh identity capture and existing checked bookmark/
write barriers prevent same-path replacements inheriting a pin. Review toolbar
pin controls are removed. Existing dim unavailable/Locate/Unpin states remain.

Photos normal UI opens the complete matching library/album/date selection.
Lightweight membership preparation is serial, off-main, cancellable per member,
and reports coalesced progress. A lazy pinned fetch result plus ID/index bindings
replaces eagerly retained PHAssets. No resource lookup is performed per member.
The existing four image lanes, 64 pending image waiters, 96 MiB pixel cache,
eight local preheat items, one original lane/eight pending originals and 5 GB
original staging ceiling remain. Full-selection client results must match the
chosen snapshot completely. Save/cancel/late-result barriers are retained.

Initial labels are ordinal Photo/Video names. Original filename/codec/RAW facets
and filename search are unavailable in preview membership; explicit original
access resolves the safe actual name/type. Copy still uses that name and exact
primary-original bytes. This avoids an 80,708-resource metadata sweep.
Error 3164 now has the existing cloud/review-download remedy instead of a raw
framework error. Other errors remain intact; network consent is never inferred.

`LiveArchivePerformanceTests` bypasses SessionStore opening/save authority and
reads the real archive through SessionOpeningWorker with an isolated metadata
cache and backup directory. It mounts actual Opening/Grid/Browser collections,
checks visible matching-revision thumbnail state, samples RSS/scheduling gaps,
and compares paused/active real quality analysis. SourceFolder/save access is
never installed in its viewing store; source sidecar bytes/absence are checked.
Its timings are harness/input-to-state observations, not physical frame rate.
The opt-in test does not drain quality analysis across the entire real archive.

Aggregate local OSLog notices separate Photos preparation (decisions, membership,
review-item construction) from downstream worker/publication readiness. They
contain counts/times only. Model Ready is not a claim that visible pixels arrived.

## Reproduction

```sh
# Read-only real archive stage profile, using a compiled optimized test bundle.
LOUPPE_SPEED_TESTS=1 LOUPPE_SPEED_REPETITIONS=3 \
LOUPPE_OPENING_FOLDERS='/Volumes/WORK_FAST_A/2023-2026 archive' \
LOUPPE_SPEED_OUTPUT=/private/tmp/louppe-ssd-20261025/archive-before \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --skip-build --disable-keychain --build-system native -c release \
  -Xswiftc -DDEBUG --filter LouppeSpeedOpeningTests

# Explicit opt-in mounted, read-only live archive check.
LOUPPE_LIVE_ARCHIVE_ROOT='/Volumes/WORK_FAST_A/2023-2026 archive' \
LOUPPE_LIVE_ARCHIVE_OUTPUT=/private/tmp/louppe-ssd-20261025/archive-mounted \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --disable-keychain --build-system native -c release -Xswiftc -DDEBUG \
  --filter LiveArchivePerformanceTests

log stream --style compact --level info \
  --predicate 'subsystem == "com.alexandermarkin.louppe" AND (category == "PhotosOpening" OR category == "OpeningReadiness")'
```

Runtime observations and installed identities follow.

## Automated validation and review

Final full suite: **1,055 tests, 48 skips, zero failures**, 159.2 seconds
(`full-suite-final.log`). Complete mandatory gates passed: Hotkey 41, BrowserScroll
3, GridScroll 4, PersistentVerticalScroller 3. Photos full-membership 3,
full-selection 7, and pin persistence 20 tests passed. Focused initial integration:
103 cases, one opt-in skip, zero failures. Review-fix focus: 16/16 passed.
Safety/performance checks: **75/75**. Standalone media and resource-bundle checks
passed. All six catalogs lint; source checker: 2,237 callsites, zero missing keys.

Skips comprise 26 opt-in speed tests, disposable-volume/remount checks, optional
RAW/Fuji fixtures, optional Photos/UI captures, four XCTest-host AX/display cases,
and the explicitly opted-in live archive check. The latter ran separately twice
and passed on the real SSD. Skips are not passes. Existing AppKit Contacts-helper
and SDK deprecation log noise is retained; it caused no test failure.

Two independent source reviews are in `review-round1.md` and `review-round2.md`.
Round 1 found one medium blocker: extensionless Photos labels removed inspection
controls and left an empty format facet. The fix separates photo inspection UI
eligibility from local decode/quality evidence and gives unknown Photos formats a
meaningful media label. Production-style extensionless tests cover photo/video,
unknown local files, exact original-name leases and clipping eligibility. Round 2
found no remaining application blocker. Its minor negative-test omission was
added before the final full suite. No invented extension or quality sweep was added.

## Mounted archive results

`archive-mounted/` and `archive-mounted-v2/` retain raw observations. Both use
release optimization with DEBUG-only pixel markers and actual Opening/Grid/Browser
mounts. The second run adds a supported target near the archive end and waits for
positive real quality progress before the requested-background phase.

| Observation | First run | Second run |
| --- | ---: | ---: |
| Cold isolated-index first matching visible thumbnail | 16.93 s | 12.53 s |
| Cold isolated-index complete worker validation | 35.29 s | 29.08 s |
| Warm complete-worker samples | 9.77 / 4.81 / 4.63 s | 9.83 / 5.06 / 4.93 s |
| Warm first-thumbnail samples | 8.89 / 3.94 / 3.76 s | 8.91 / 4.15 / 4.00 s |
| Peak process RSS, across all openings/navigation | 711 MiB | 855 MiB |

Cold here means the isolated metadata snapshot was initially absent; filesystem
and shared preview caches were uncontrolled/warmed. These are worker readiness
and mounted-thumbnail measurements, not installed-app end-to-end Ready or FPS.
Cold discovery alone took 16.0 seconds in the first run, and cold metadata 17.3
seconds. Warm metadata stays around 0.2 seconds; discovery remains variable.

Second-run four-target input-to-matching-thumbnail observations:

| Surface and condition | Median | Worst of four |
| --- | ---: | ---: |
| Grid, first travel, analysis paused | 191.5 ms | 354.9 ms |
| Grid, repeated travel, analysis paused | 193.7 ms | 290.4 ms |
| Grid, repeated travel, analysis requested | 100.7 ms | 171.8 ms |
| Browser, repeated travel, analysis paused | 24.7 ms | 35.0 ms |
| Browser, repeated travel, analysis requested | 16.0 ms | 28.9 ms |

The earlier three-target Grid sample reached 1.08 seconds on its first uncached
travel. These small sequential samples are cache/order dependent and establish
no background speedup. The second run completed two real quality results before
navigation; overlap with each jump is not established, and whole-archive work
was not drained. Browser values do not describe the fitted Gallery photo.
Matching-revision image, visibility, selection and zero horizontal-origin checks
passed. Scheduling-gap observations include forced harness layout, not physical
frame timing. `archive-source-audit.json` confirms all 31 saved nested sessions
remain byte-identical and the root sidecar remains absent.

## First measured candidate, before the Settings relocation

Direct local ad-hoc signed **1.13.0 (15)** at `/Applications/Louppe.app`.
Candidate: `/private/tmp/louppe-ssd-20261025/candidate/Louppe.app` and `Louppe.zip`.
Previous bundle retained at `/private/tmp/louppe-ssd-20261025/rollback/Louppe.app`.
Normal application Quit preceded replacement; no force quit or preference reset.

- Executable SHA-256: `1cb5b9947756dd43526668422c1b781c97a73a3c2df8d80c0c959ecbbb7429bc`.
- ZIP SHA-256: `b86fe8f72af3c1f9b424b21b6b115623f135bc4ed95ad63337eb45e10deb8df9`.
- Release preflight and strict deep signatures passed for the staged candidate,
  installed app, and independently extracted ZIP. All **178 Contents entries**
  match by type, bytes, mode and symlink target (`installed-contents-manifest.json`).
- Only the official `/Applications/Louppe.app` was installed. Complete source
  fingerprints are in `source-manifest-final.json`.


## Final iCloud Settings candidate and live acceptance

Alex requested moving iCloud access into Settings after inspecting the first
candidate. Both permissions now live solely in **Settings → General → iCloud
Access**, including removal of Copy's duplicate consent toggle. Chooser, review
bar and failure states use the existing Settings scene instead. Choices persist
independently, default off when absent, update the captured active media actor,
and apply the latest values before a newly prepared review is published.
Settings changes never start or retry an original. Requests already admitted keep
their captured consent until normal completion/cancellation; no new revocation
policy was introduced.

Final full suite: **1,060 cases, 48 skips, zero failures** (144.5 seconds), including
all mandatory Hotkey/Browser/Grid/scroller suites and five new network-preference
contracts. Settings-focused run: 29 cases, one opt-in skip, zero failures.
Independent round 3 Settings review found no substantive finding/blocker.
Safety/performance rerun: **75/75**. Its first compile exposed one missing new
preference source in the standalone source list; that dependency was added and
the unchanged checks passed. No test was weakened. All six catalogs lint, and the
source checker covers 2,238 callsites with zero missing/unsupported keys.

Final official installation remains **Louppe 1.13.0 (15)**:

- Candidate app/ZIP: `/private/tmp/louppe-ssd-20261025/candidate-settings/`.
- Executable SHA-256: `f04f13e95594ba2634153fc064366b779abdc180cdb9bab85150eb025173826e`.
- ZIP SHA-256: `fae5f0d70fbb650e1f6c1897b37a06e083debd1c6576652e246e74aa4621baa5`.
- Strict deep signatures and complete **178-entry Contents equality** passed for
  the candidate, installed app and independently extracted ZIP. Manifest:
  `installed-contents-settings-manifest.json`; source:
  `source-manifest-settings-final.json`.
- First measured candidate retained at `rollback-before-settings/Louppe.app`;
  the pre-task installed app remains in `rollback/Louppe.app`. Both are outside
  Applications. Normal durable Quit preceded each reversible replacement.

Native acceptance on the official app:

- Actual `/Volumes/WORK_FAST_A/2023-2026 archive` pin shows **Available** and
  survived multiple full process quit/relaunches. Its persisted volume UUID
  matches the real SSD. Welcome exposes Pin Folder… plus Open/Locate/Unpin;
  reviewing has no pin control. Pinning created no archive sidecar.
- General Settings displayed both controls off on first use. Review-image consent
  was explicitly enabled under Alex's approval; **review on / originals off**
  survived a full normal quit and process relaunch. Unrelated review/RAW/update
  preferences were retained. Native accessibility actions verified the controls
  and scrolling; some coordinate/scroll helper calls could not bind the Settings
  window, so the supported native accessibility action was used.
- The exact final build opens **all 80,708** items, with no batch/page/iCloud
  controls in the chooser/review bar. The final build displayed its first preview at
  2,046 × 1,436 pixels. The first candidate also displayed the tail preview at
  943 × 2,048 pixels; both remain explicitly labeled review previews. No original detail/playback/Copy was requested.
- The first measured candidate reached the end-of-library Grid and current item
  80,708, retained it through Gallery/Grid switching, native window zoom/restore
  and Info shortcut round trips, and handled rapid Browser scroll/reversal.
  A temporary one-star change reached Saved, then Undo reached Saved and restored
  zero star decisions. The 80,708-entry decision file was 5,730,336 bytes.
  These interaction paths were unchanged by the Settings relocation; the final
  candidate was separately reopened and checked for complete membership, preview,
  Saved state, inspection controls, a Grid/Gallery round trip and removal of the old menus.

Live opening notices, selected library → model Ready:

| Candidate/sample | Decisions | Membership | Review-item construction | Full preparation | Worker + publication | Main publication |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| First candidate, initial whole library | 5 ms | 2,263 ms | 1,396 ms | 3,671 ms | 719 ms | 364 ms |
| Final Settings candidate, after relaunch | 265 ms | 8,052 ms | 1,520 ms | 9,845 ms | 2,391 ms | 2,077 ms |
| Final Settings candidate, immediate repeat | 1,105 ms | 8,156 ms | 1,993 ms | 11,258 ms | 604 ms | 353 ms |

Report the final candidate as **11.9–12.2 seconds combined preparation/worker**,
not the earlier 4.4-second sample. This excludes opening/authorizing/loading the
chooser and does not measure first compositor pixels. The host and PhotoKit
private caches were not isolated; the saved-decision dataset also grew from a
small batch to all 80,708 records. These are observations, not a controlled
causal claim that relocating Settings changed performance. Membership metadata
and publication remain useful next profiling targets; more image cache alone
will not address them.

The first live process was sampled every ~100 ms for ten minutes, covering the
initial whole-library opening and early native browsing: **613.3 MiB peak RSS**.
The final candidate's spot checks were roughly 441–529 MiB RSS, not a measured
peak. RSS is not heap/physical-footprint accounting. Physical display FPS and
trackpad latency were not measured. Some Browser fractional-AX-scrollbar jumps
failed with stale-element errors; the successful Grid tail jump and Browser
wheel/reversal are the native navigation evidence, not those failed calls.

Initial full-path native-control timeouts were resolved after Alex foregrounded
the app and the running instance was rebound by name. Read-only process samples
showed a normal idle event loop; no preferences were reset or OS boundary bypassed.
The Settings window needed fresh bindings and an AX scroll action; these tool
limits are retained separately from application passes.

Final source audit: all **31 nested sidecars remain byte-identical**, archive-root
sidecar remains absent, no source mutation API was called. Real SSD detach/remount,
physical SD-card input, older macOS runtime and physical frame pacing remain
unverified. The prior disposable APFS detach/remount test is not physical ExFAT
hardware acceptance. Original filenames/formats in Photos remain deferred until
explicit original access; ordinal labels do not imply codec/RAW knowledge.

The final app is left running with the whole Photos selection open, Gallery
preview visible, Saved status, review downloads enabled and originals disabled.
No commit, push, release or website change.

## Quick continuation

1. In the running app, browse the complete Photos library, switch Grid/Gallery
   and toggle Info. **⌘, → General → iCloud Access** holds both remembered choices.
2. Click the current-source button to return to Welcome; the real SSD archive
   remains pinned. Opening it later uses normal folder/session behavior, which
   may create a root sidecar; the profiling above intentionally did not.
3. Use `/private/tmp/louppe-overnight-20261025/morning/jpeg-10000` or
   `.../varied-raw-16` for disposable rating/file-operation experiments. Keep the
   real archive's existing projects/media intact. Existing nested shoot decisions
   are not silently merged into a new parent-folder session.
