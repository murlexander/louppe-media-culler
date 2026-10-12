# Quality Cues local review — 12 October 2026

The combined quality-cues + saved-decision recovery build is documented in
[the combined review record](SESSION_RECOVERY_REVIEW_2026-10-12.md). The record
below preserves validation of the earlier quality-cues slice.

The first native slice is implemented locally on `main`, starting at `081b228`.
It adds Quality cues and Capture bursts to Filter, compact Browser/Grid glyphs,
and shared exact evidence in Info/popovers. The existing Gallery/Grid review,
ratings, histogram and clipping overlay remain the inspection surfaces.

Verified launch copy: `/private/tmp/Louppe-Quality-Cues-Review-App/louppe-2026.10.12.app`.
The retained archive is `dist/louppe-2026.10.12.zip`; the packaging script also
writes an app in `dist`. The review
identity is `com.alexandermarkin.louppe.review2`; automatic updates are disabled
and the production Finder service is omitted. No install, commit, push, release
version change or publication was performed. Pre-existing backlog/scope work was
preserved. Private correspondence and supplied screenshots are not included.

## Behavior and ownership

- Four independent inclusive rules: ISO ≥ 6400, shutter ≥ 1/30 s, near-white
  area ≥ 10%, near-black area ≥ 10% by default. Legacy combined clipping values
  seed each missing new preference once, preserving disabled flags and precision.
  Disabling rules retains their cutoffs; edits reclassify cached counts.
- Any selected cue intersects all existing filter facets. Cues do not set
  decisions. Mixed RAW+JPEG keeps separate physical decisions and uses the
  displayed primary's evidence. Capture groups retain partially filtered members
  with visible/total counts; regular sort orders groups and members.
- One SessionStore scheduler requests at most two items per batch through the
  existing two-preview/one-RAW lanes. It retains numeric counts, dimensions,
  source and revision, never folder-wide bins/bitmaps. Tile interest is capped
  at 64 IDs. File work, replacement, pairing, Close and Pause cancel pending work.
- Unchecked, checking, checked, partial, unavailable and disabled are distinct.
  Missing metadata and RAW preview fallback are partial coverage. Exact values,
  cutoffs, source, image dimensions, sample counts and pixel zones are exposed.
  Camera metadata is a clue, not a noise/blur measurement or quality verdict.
- RAW evidence uses a bounded Apple Default linear decode independently of the
  presentation decoder. Preview zones remain sRGB 0–5 / 250–255; RAW uses
  linear ≤ 0.002 / ≥ 0.995. Both are scaled estimates; the preview clipping
  overlay remains a separate inspection aid with its own alignment.
- Metadata-only capture requests return before identity/hash/preview access.
  EXIF original/digitized/TIFF source, subseconds and UTC offset or assumed
  timezone are retained. Creation dates are explicitly inferred. Missing dates
  are excluded. Consecutive gaps are inclusive, not a maximum group duration;
  cameras or separate shutter presses can merge. No maker-note burst ID is read.
- Capture membership reuses the single cancellable group-analysis owner off-main.
  Latest interval/generation wins; Cancel retains the last completed interval.
  Navigation or Reset during initial work cannot enter the mode later. Async cue
  completion preserves current identity; a hidden current has no rating target
  and Gallery asks for an explicit matching item.

## Validation

Selected toolchain: full Xcode 27, macOS 27 SDK, SwiftPM native build backend.

| Check | Result |
| --- | --- |
| Full XCTest suite with a disposable X-T50 RAF enabled | 621 executed: 608 passed, 13 skipped, zero failures |
| Complete HotkeyTests within that suite | 35 passed; real AppKit events and monitor lifecycle included |
| Focused initial cue/date/burst/histogram/localization suite | 107 passed before the final notification regression was added |
| Real RAW cue evidence with Info closed | Apple Default RAW source, positive sample counts and dimensions bounded to 1,025 pixels; passed in final full suite |
| Real RAW preview and 100% rendering | Passed in final full suite |
| Metadata-only sentinel | Zero identity/hash/decode callbacks for capture requests; all-mode calls its evidence workers |
| Selection, facets and pairing | Any-cue intersection, partial burst membership, Mixed physical decisions, stale replacement and latest interval/Cancel/Reset/navigation tests passed |
| Real PNG cues with Info closed | White/black filters work; media bytes and undecided ratings unchanged; no analysis sidecar written |
| Six localization catalogs | Key/placeholder/technical-token validation passed |
| Required performance/file-safety script after final source change | 75/75 passed, including disposable Trash/Undo |
| Standalone media checks | Passed |
| Review packaging | Release preflight passed; loose app and unpacked archive independently verified, all 110 Contents entries identical |
| Originals and stable app | 34/34 disposable media hashes and 104/104 installed app/preferences entries unchanged |
| Saved review session after native checks | 34 undecided files, no stars or colors |

The 13 skips require a configured three-file decoder benchmark, mounted-volume/
remount coordination (10), a second display, or accessibility children unavailable
inside the XCTest host. They are not passes. An optimized XCTest build could not
compile existing DEBUG-only test helpers; optimized grouping was measured in a
standalone harness using the same production source instead.

The real RAW run exposed a Swift 6 isolation trap: ImageIO registers defaults on
its metadata worker, delivering a UserDefaults notification to a main-isolated
Combine sink. LLDB identified that boundary. Notification delivery now moves to
the main queue before entering the owner; a background-notification regression
and the ordered full suite with real RAW both pass.

Optimized grouping measurement (seconds, local machine):

| Photos | Metadata-only collection | Initial membership | Interval change |
| --- | ---: | ---: | ---: |
| 1,000 | 0.000338 | 0.011236 | 0.002440 |
| 10,000 | 0.001663 | 0.018106 | 0.015901 |
| 100,000 | 0.011615 | 0.141364 | 0.141750 |

The first membership run includes cold localization. The 100k result justified
moving capture membership off-main; exact/similar membership remains AUD-08 work.
Session index/filter/sort capture still has existing large-session main-thread
costs; these measurements are not a complete 100k interactive review benchmark.

## Native review and remaining acceptance

Disposable review folder: `/private/tmp/Louppe-Quality-Cues-Review-2026-10-12`.
It contains generated ISO/shutter/white/black/gray/missing/corrupt/text and scroll
fixtures plus two byte-preserving X-T50 RAW+JPEG copies. These camera copies are
not a validated high-speed burst or separate-shutter-press corpus.

The fixed app was launched with `-openFolder` and reached Ready with 34 items,
0 reviewed and Session: Saved. Native accessibility inspection confirmed:

- Gallery's Browser exposes High ISO, Near-white, Near-black and Slow shutter
  glyphs, plus checked-with-no-match labels for neutral photos.
- Info shows ISO 12800 ≥ 6400, camera metadata source, 640 × 480 measurement,
  exact sample counts, preview cutoffs and EXIF original/subsecond/UTC evidence.
- W hides Info; G switches to Grid while cues remain available with Info closed.
- Command-F opens Filter with Quality cues and Capture bursts. Selecting High
  ISO plus Near-white shows 2 of 34, matching either selected cue. Coverage reads
  32 of 33 photos (the corrupt JPEG is not a clean result); decisions stay at 0.

ScreenCaptureKit failed with -3811/-3812 during screenshot and text-field
operations. Keyboard/checkbox accessibility checks above succeeded, but the
failure later prevented further native interaction even after a driver reset.
Pixel-level appearance, scrolling, resizing, cue popovers, threshold fields,
capture controls, native Mixed/pairing, and translated layout remain unverified.
The review app was relaunched to clear test-only filters. These partial checks
are not full native visual acceptance.

Finder metadata reappeared on the generated app inside the File Provider-managed
Documents folder, failing strict verification even after stripping it there.
The launch copy was copied without attributes to `/private/tmp`, strictly
verified, and compared against the independently verified archive's entire
Contents tree (110 entries). The installed production app was not touched.

Still required before release: the native gaps above, spoken VoiceOver/Full
Keyboard Access, and real high-speed Fuji/separate-press/mixed-camera acceptance.
AUD-23/24 and provider/removable-volume cases remain open. No automatic
keeper/aesthetic ranking, softness model, subject tracking or audio/video cue
analyzer was added.
