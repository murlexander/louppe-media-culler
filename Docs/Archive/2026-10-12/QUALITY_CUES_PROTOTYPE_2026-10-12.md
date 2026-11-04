# Quality Cues prototype — 12 October 2026

Dated evidence; statuses and local paths describe that review. See the
[current backlog](../../../BACKLOG.md) for open work.

Build a local native prototype inside the existing review UI. Quality cues and
Capture bursts belong in Filter; cues appear alongside Browser/Grid image tiles
and explain their evidence in Info. Preserve keyboard-first review, originals,
ratings, and the current Gallery/Grid layout. Early-user feedback informs the
work; identifying correspondence belongs only in private notes.

## First milestone

- Add **Quality cues** and **Capture bursts** sections to Filter. Cue choices
  match any selected cue, then intersect the existing filter facets. Keep sort
  choices in Sort. Reuse one burst/group state owner; no separate review screen,
  top-level Quality destination, or competing analysis path.
- Show compact, accessible cue glyphs alongside Browser/Grid tiles. Reveal the
  finding and measured value on demand, with an Info inspection action. Keep
  rating colors and controls distinct; cue presence never changes decisions.
- Reuse the existing histogram measurements. Quality Cues already consumes
  shadow/highlight percentages; consolidate the rule/presentation layer rather
  than creating another analyzer. Keep the histogram and clipping overlay as
  inspection aids in their current surfaces.
- Split the combined clipping preference into independent shadow/highlight
  enabled flags and area thresholds. Retain configurable ISO/shutter rules.
  Preserve legacy values when splitting the combined rule; threshold changes
  apply live without repeated decoding. Show explicit units and comparisons.
- Make cues available when Info is closed. Distinguish unchecked, checking,
  checked-with-no-match, unavailable/unsupported, and partial coverage. Never
  present missing analysis as a clean result.
- Make capture-burst requests metadata-only (AUD-07). Retain date provenance
  and subsecond/offset evidence (AUD-22), or explicitly label unsupported or
  inferred cases. Measure group work before moving it off-main (AUD-08).

Finish with a launched local review build using disposable media, focused
verification, and a concise evidence record. Do not commit, push, publish,
replace the installed app, or bump the release version just for this prototype.

Implementation is complete as a local review slice; see the
[review and validation record](QUALITY_CUES_REVIEW_2026-10-12.md). The table below
records the starting baseline.

## Accepted presentation corrections

Later review simplified the initial evidence proposal. Info shows matching cue
names/values below the histogram; no empty/checked block, percentage row, repeated
threshold/source explanations or diagnostic disclosure. RAW/Preview histogram
tags appear only for RAW files. Info keeps Captured and Time zone, with estimated
fallback dates. Settings has an individual reset icon per rule and no explanatory
footer. Browser/Grid badges share their height/insets; stars/color sit top left,
decisions top right and circular cues bottom left inside the tile. The recovery
notice has a close button and a solid full-width app background.

## Combined review scope

At Alex's request, the same native prototype now includes nonblocking saved-decision
recovery for copied/moved files. The recovery banner/sheet, full-content verification,
explicit older-session restoration, and preserved recovery history are described
in [the combined review record](SESSION_RECOVERY_REVIEW_2026-10-12.md). This is
session metadata work; quality cues still never decide ratings or change originals.

## Baseline implementation and limits

Baseline inspected: `081b228`, 12 October 2026. Recheck local changes before edits.

| Area | Existing implementation | Relevant limit |
| --- | --- | --- |
| Cue rules | `CameraQualityWarnings.swift`; `Views/CameraQualityWarningsView.swift` | Photo-only ISO, shutter, highlight and shadow cues; one clipping switch/threshold |
| Measurement | `HistogramPipeline.swift`; `Views/MetadataPanel.swift` | Selected-photo/view-owned analysis; no folder cue index |
| Histogram UI | `Views/HistogramView.swift` | Keep numeric measurement/inspection, with source labels |
| Filters/tiles | `Models.swift`; `Views/FilterView.swift`; Browser/Grid/Thumbnail views | No cue filter or tile markers yet |
| Bursts | `DuplicateBurstAnalysis.swift`; `SessionStore.swift`; `Views/SortView.swift` | Current request also hashes/decodes; date-only grouping |
| Capture dates | `MetadataExtractor.swift`; `FolderScanner.swift` | Ordinary EXIF/TIFF strings; creation-date fallback loses provenance |
| Audio | `AudioLevelPipeline.swift` | Bounded per-channel PCM envelopes; raw samples sanitized/clamped; first audio track |

Burst detection sorts dated photo items and groups consecutive gaps at or below
the chosen interval; default 2 s, current UI 0.5–10 s, minimum two items. It is
not a maximum total group duration. Equal dates sort by item ID. There is no
Fuji burst identifier, shutter-press boundary, or camera-identity partition.
High-speed Fuji sequences should usually group when timestamps are exposed,
but same-second ordering and real-camera fixtures need validation. Separate
presses, mixed cameras, and creation/import dates can create misleading groups.

Existing rule defaults: ISO 6400, shutter 1/30 s, clipping area 10%; comparisons
are inclusive. ISO and shutter are camera clues, not measured noise/blur. The
preview histogram uses luminance zones 0–5 and 250–255; RAW uses its own linear
thresholds. Editable area percentages and pixel cutoffs are different features.
Advanced cutoff editing is later work and must preserve source/overlay meaning.
RAW analysis is a scaled demosaiced estimate, not per-photosite proof of loss.

## Ownership and state

SessionStore owns result/status projections; I/O stays in bounded workers/actors.
Keep numeric measurements separate from rule preferences. Cache by content
revision, analyzer version, actual resolution, orientation, and decoder/color
configuration. Carry evidence source, region/time range, and coverage. Use
existing selection, pairing, generation, and cancellation authorities.

Threshold edits reclassify cached evidence. Background completion must not steal
selection, jump the reviewed item, or publish stale results after replacement,
rescan, navigation, or decoder changes. Prioritize selected/nearby files; retain
documented memory/queue limits. Do not change session persistence for speculative
cue-dismissal state; a dismissed cue is distinct from a rejected file.

## Followups after the first slice

- **Local softness:** relative within-burst multi-scale edge/detail measurements
  on equivalent crops; uncertainty for low texture/unclear subject. Use 100%
  inspection. Preview processing, bokeh, panning and grain confound global scores.
- **Inline comparison:** matched crops/synchronized zoom within existing
  Gallery/Info. No new screen or user-facing review mode by default.
- **Subject inspection:** an optional scrollable Info section with manually
  selected normalized ROI and later local face/subject crops. Preserve revision,
  orientation and true-pixel mapping; do not silently track a different subject.
- **Audio/video timed evidence:** markers seek to intervals in current Gallery.
  Video samples carry actual timestamps/coverage and refine suspicious regions;
  audio extends the existing PCM pass, collecting overload/silence/imbalance
  evidence before sanitization. Picture and sound findings remain independent.
- **ML/AI:** research backlog only. Do not add models, cloud/API calls, uploads,
  keys, telemetry, or automatic aesthetic/keeper ranking to this prototype.

## Acceptance and verification

Use repository-required guidance, selected Xcode, and disposable files. Check:

- Cue filters/icons work with Info closed; independent toggles/thresholds and
  exact boundaries update consistently without repeated reads.
- RAW+JPEG projection, source labels, Mixed decisions, other filter facets,
  partially filtered burst membership/counts, and selection remain correct.
- A metadata-only burst request performs zero hashing/preview decoding; test
  same-second captures, interval boundaries, separate presses, mixed cameras,
  missing capture dates, and import-date provenance. A real Fuji fixture is a
  separate validation item if unavailable.
- Pending/failure/unsupported/partial states are honest; canceled or replaced
  work cannot publish stale icons. No ratings or originals change via analysis.
- Browser/Grid scrolling, small windows, Info controls, keyboard focus and
  VoiceOver labels retain the native review workflow. Do not add shortcut owners.
- Run focused affected tests and required checks; launch the actual prototype.
  Run complete HotkeyTests before any separately authorized install. Record
  unavailable checks as unavailable, never passed.

Detailed dated research remains in private project notes. Public files, tests,
issues, release notes and fixtures must not include feedback sender identities,
addresses, email subjects, correspondence or supplied screenshots.
