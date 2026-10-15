# Combined quality-cues and session-recovery review — 12 October 2026

Dated evidence; statuses and local paths describe that review. See the
[current backlog](../../../BACKLOG.md) for open work.

The native quality-cues prototype now opens folders with changed file identities
without discarding earlier decisions. Verified decisions restore; uncertain files
stay unrated and their previous decisions remain available in a recovery sheet.
Quality cues, Capture bursts, Browser/Grid glyphs and Info evidence remain in the
same app. This is a local prototype, starting from `081b228` and preserving the
pre-existing quality-cues work. No install, commit, push, publication or release
version bump was performed.

## Review build

- Latest running app: `/private/tmp/Louppe-Review-2026-10-12/Louppe Review.app`.
- Latest shareable local archive: `dist/louppe-combined-review-final-2026.10.12.zip`.
- Latest disposable demo: `/private/tmp/Louppe-Review-2026-10-12-Demo` (34 files).
- Latest bundle identity: `com.alexandermarkin.louppe.review8`. Updates are disabled and
  the production Finder service is omitted. The distinct name/identity avoids
  Launch Services routing the dated review name to the older running prototype.
- The ordinary review2 dated app/archive were also built. The previous quality-only
  archive is preserved at `/private/tmp/louppe-session-recovery-work/quality-cues-before-recovery.zip`.

Use copies for additional shoots. This prototype writes session schema 7; the
installed stable app cannot read that newer session format. Production bundle
identity, media, release version and installed preferences remain unchanged.

## Try it

The running demo has three pending recovery records and one automatic restoration:

| File | Previous decision | Expected behavior |
| --- | --- | --- |
| `01-high-iso.jpg` | Yes, four stars, purple | Older entry without content proof; explicit confirmation required |
| `02-near-white.jpg` | No, four stars, purple | Identical copied bytes verified; automatically restored and retained in history |
| `03-near-black.jpg` | Yes, four stars, purple | Stored proof differs; stays unrated and reports changed contents |
| `04-gray.jpg` | Yes, four stars, purple | Older entry; available for explicit confirmation |

Open **Check and Restore…** from the banner. Select individual records or Select
All, review the previous decisions/statuses, acknowledge that the selected files
are the same photos/videos, and choose **Restore Selected Decisions**. Already
reviewed files are protected. **Keep Current Decisions** resolves selected
attention while retaining the old decision in history. Recovery History exposes
resolved records. Pause/Resume controls are available while checks are running.

Use **Filter → Quality cues / Capture bursts** and Browser/Grid/Info to review
the existing quality-cues slice alongside this flow. Cues do not set decisions.
The underlying quality prototype and earlier native limitations are recorded in
[the original quality-cues review](QUALITY_CUES_REVIEW_2026-10-12.md).

## Recovery contract

- Empty old decisions require no warning. Meaningful metadata includes explicit
  decision/star/color changes, including their timestamps.
- Same-name replacements preserve old metadata in separate durable recovery
  records before autosave. Records survive reopen and explicit resolution.
- Unambiguous full-byte SHA-256 matches at the same relative filename restore
  automatically. Exact returning physical originals can also recover. Filename,
  size, timestamps, samples and visual similarity alone never authorize a copy.
- Older entries without fingerprints require explicit confirmation against fresh
  regular-file and scan-identity validation. Manual restoration does not wait for
  reading entire RAW/video contents; portable fingerprints follow afterward.
- Current decisions, stars, colors and change timestamps prevent recovery from
  overwriting review work performed while checks run. RAW+JPEG components remain
  independent, including Mixed decisions. Affected counts/filter/sort refresh
  incrementally without advancing to another photo.
- One serial utility lane reads at most 1 MiB at once and validates the held
  descriptor, regular-file type, byte count, before/after stat and final path
  identity. Symlinks, replacements, cancellation and stale sessions are refused.
  Each worker retains its own folder-access lease. File work, transitions and
  Quit preparation pause checking.
- Unrated files and older conflicts with no comparable proof add no content
  reads. Fingerprints share the existing save schedule and remain optional
  maintenance; actual restored decisions use normal dirty-generation barriers.

## Validation

Full Xcode 27/macOS 27 SDK, SwiftPM native backend:

| Check | Result |
| --- | --- |
| Full XCTest suite, real disposable Fuji RAW enabled | 633 executed: 620 passed, 13 skipped, zero failures |
| Final byte-exact legacy-name adjustment | 95 affected recovery/persistence/filename/save-guidance tests passed |
| New recovery tests | 12 passed: identical/different copies, older-session manual restore/reopen, existing cached proofs, current-decision races, canceled folder switches, stale manual restore, symlinks/replacements, malformed snapshots, zero reads for unrated files, new-decision fingerprint, and Mixed RAW+JPEG counts |
| Complete HotkeyTests | 35 passed in the full suite; recovery sheet joins the shared presentation gate |
| Quality cues / real RAW / localization | Passed in the full suite; six catalogs retain matching keys/placeholders |
| Required performance and file-safety script | 75/75 passed, including disposable Trash/Undo |
| Release/review packaging | Passed release preflight and review script; final named app and unpacked archive independently pass deep strict signature verification; all 178 Contents entries match |
| Launched combined app | Exact review3 process confirmed; disposable session saved 34 current entries, three pending records and one resolved automatic restoration |
| Originals and stable installation | 34/34 demo media hashes and 97/97 installed app/preferences entries unchanged |
| Whitespace review | `git diff --check` passed |

One full run's video playback fixture failed across a roughly two-hour wall-clock
interruption. Repeating the full suite under an idle-sleep assertion passed. An
earlier copied launch app picked up Finder metadata; stripping that metadata
allowed strict verification before the final launch. The final uniquely named
app/archive were staged and signed outside the File Provider-managed workspace.

The 13 skips require a configured decoder benchmark, mounted-volume/remount
coordination (10), another display, or native accessibility children unavailable
inside XCTest. They are not passes.

## Remaining review limits

ScreenCaptureKit returned `-3811` for both old and combined review-app inspection.
Native screenshots, checkbox/button interaction, keyboard behavior inside the
new sheet, VoiceOver and small-window/translated layout remain unverified. The
actual app launch and persisted demo state were verified independently; automated
logic checks do not substitute for native visual acceptance.

Automatic copied-file recovery currently requires the same relative filename;
copy-and-rename/reorganized-copy discovery and manual remapping are later work.
Ambiguous historical generations at one path require selecting one intended
record. Missing files remain preserved, not guessed. Fingerprint-only checkpoints
are optional at Close/Quit: copying before a proof is saved may still require
confirmation next time. Recovery history is retained rather than pruned.

Existing quality-cue native-layout, real high-speed burst, filesystem/provider
and removable-volume acceptance gaps remain open as documented in the quality
review. No new quality ranking or media modification was introduced.

## Prototype corrections — 12 October

- Browser/Grid cue icons now sit inside the square at bottom left. Stars/color
  move to top left; the Yes/No control stays top right. High ISO uses a dotted
  noise-style symbol instead of an aperture.
- Info/popovers show short values (for example, Near-black area · 25%) and a
  source label. Exact thresholds, sample counts and limitations are in the
  collapsed Measurement details disclosure.
- The banner has an accessible ×. Dismissal hides it for this opening, preserves
  recovery/history and lets checking continue. File → Check Saved Decisions…
  remains available; reopening/rescanning restores notification eligibility.
- Updated app: `/private/tmp/Louppe-Combined-Review-Updated/Louppe Combined Review Updated.app`.
  Bundle ID `com.alexandermarkin.louppe.review4`; automatic updates disabled and
  Finder service omitted. It uses a fresh disposable copy at
  `/private/tmp/Louppe-Combined-Review-Updated-Demo`, leaving the previous running
  review and its decisions intact. Archive:
  `dist/louppe-combined-review-updated-2026.10.12.zip`.
- Final focused validation: 109 tests passed, no skips or failures, covering
  quality cues with real RAW, compact values/native ISO glyph, localization,
  Grid gesture gates, selection, recovery preservation/dismissal and hotkeys.
- Native visual inspection remains blocked: Computer Use's ScreenCaptureKit
  stream failed with error -3811. No preference/window reset was attempted.
- Required performance/Trash/undo checks passed (75/75). Release preflight and
  independent strict signatures passed for the updated loose and archived apps;
  complete Contents trees matched. Launch was confirmed by process and app
  inventory. Demo sidecar has four retained records, one resolved automatically;
  all 34 media byte hashes match the pre-launch manifest. `git diff --check` passed.

## Info-panel simplification — 12 October

Matching quality cues now sit directly below the histogram, replacing its
shadow/highlight percentage row. Only the cue name and value appear (for example,
Slow shutter · 1/8s). No matches means no quality-cues block. Checked/status text,
measurement source, threshold repetitions, technical disclosure and the extra
Inspect clipping action were removed from Info/popovers. Tile glyphs also appear
only for actual cues, without empty/checkmark status indicators. Analysis statuses
and measurements remain intact internally for filtering and scheduling.

Settings has one short note explaining that ISO/shutter use camera settings,
while near-white/near-black areas use scaled RAW/preview estimates. No analysis,
threshold, persistence or media behavior changed. The native histogram's clipping
control and RAW/Preview label remain available.

The latest isolated app uses review5 and a fresh disposable demo; previous running
review copies and their decisions are preserved. Focused validation passed 91/91
without skips, including real RAW cues, histogram, localization, native gesture
and complete hotkey checks. Native visual inspection remains unavailable because
of the previously observed ScreenCaptureKit -3811 capture failure.

Final Info review validation: required performance checks passed 75/75; release
preflight passed; loose/archive strict signatures passed independently and their
complete Contents trees matched. The launched review5 process opened/saved the
fresh demo with all 34 media byte hashes intact and recovery history preserved.
`git diff --check` passed. No commit, install or release version change was made.

## Histogram label and heading corrections — 12 October

The histogram source tag now appears only for RAW primaries after analysis
completes: RAW for the completed sensor decode, Preview for the rendered fallback.
JPEG, TIFF, PNG and HEIC have no source tag. TIFF currently uses the ordinary
rendered histogram path, with no separate RAW decode. The Quality cues heading
now matches Stars and Color label exactly: regular caption font, secondary color.

Focused checks passed 89/89 without skips, including the RAW/JPEG/TIFF/PNG/HEIC
label regression, pending RAW state, real RAW cues, histogram, localization and
complete hotkey checks. Earlier running review copies and decisions are preserved.
Native visual verification remains blocked by the recorded ScreenCaptureKit
-3811 capture failure. Production installation and release version are unchanged.

## Individual cue resets — 12 October

Settings now has a trailing arrow.counterclockwise button per cue row. It restores
only that cue's enabled state and threshold (ISO 6400, shutter 1/30s, near-white
10%, near-black 10%). Other rows and the overall Show quality cues switch are
unchanged. Separate draft-reset generations prevent an old focus-loss commit
from undoing a reset or another row's draft from being discarded. The explanatory
paragraph, clipping explanation tooltip and global Restore Quality Cue Defaults
button were removed. Reset buttons have localized tooltips and accessibility names.

The latest review7 combines these settings with the RAW-only histogram labels and
regular caption Quality cues heading. Focused checks passed 89/89 with no skips.
Earlier prototype apps and their decisions remain intact. Native visual and reset
interaction verification remain limited by the recorded screen-capture failure.

Final combined validation: 75/75 required performance checks passed. Release
preflight passed; loose and archived apps passed independent strict signatures
and complete Contents trees matched. Review7's running process opened/saved the
demo; all 34 media byte hashes and recovery history were preserved. Automatic
updates remain disabled. `git diff --check` passed; no install, commit or release
version change was performed. Individual reset interaction still needs native
visual review because Computer Use capture remains unavailable.

## Simplified photo date metadata — 12 October

Photo Info keeps Captured and Time zone. Date source, Recorded date/time and Date
precision were removed. Dates from digitized/TIFF metadata, file creation or an
unverified source are marked “estimated” beside Captured. Original capture time
is unmarked. The Mac's date formatting remains unchanged; internal capture-date
source, fractional seconds and timezone evidence remain intact for burst logic.
Video/audio date presentation is unchanged.

The latest review8 includes every accepted cue placement, icon, copy, settings
reset, histogram source-label, heading and recovery-banner correction. Focused
checks passed 108/108 without skips, including real JPEG original/digitized/TIFF/
creation fallbacks and byte preservation, real RAW cues, source-label eligibility,
localization, recovery and complete hotkey checks. Previous review apps and their
session decisions are preserved; production remains untouched. Native visual
inspection remains blocked by the previously recorded ScreenCaptureKit failure.

Final metadata review validation: 75/75 required performance checks passed.
Release preflight and independent loose/archive signatures passed; their complete
Contents trees matched. The review8 process opened/saved the disposable demo with
all 34 media byte hashes intact and four recovery records retained (one resolved
automatically). `git diff --check` passed. No install, commit, push or release
version change was performed. Native screenshot inspection remains unavailable.

## Consistent tile badges and build cleanup — 12 October

Info and cue popovers use primary text color for cue icons, names and values;
Quality cues remains a regular secondary caption. Browser and Grid share 20-point
visible badge heights and 6-point corner insets. Stars/color align at top left,
decisions at top right, and individual circular cues at bottom left. Duration
capsules share the same height/inset. Grid keeps a 40-point native decision target
aligned behind the visible circle; drag exclusions cover that target and all four
cue circles without adding per-control geometry readers.

Focused checks passed 129/129 without skips, including native rating multi-clicks,
the invisible part of the enlarged decision target, drag ownership, complete
hotkey checks, real RAW cues, histogram, localization and recovery. Required
performance checks passed 75/75. Release preflight and independent loose/archive
strict signatures passed, and complete Contents trees matched.

The existing review8 app was replaced at the same path and launched with the
same demo folder. All 34 media byte hashes, 34 saved entries and four recovery
records remain unchanged. ScreenCaptureKit still returns -3811, so native visual
verification remains unavailable. Source checks passed; no install, commit, push
or release version change was performed.

All older/extra review app bundles and archives found in the review temp folders
and dist were moved to macOS Trash, including temporary verification/packaging
copies. Only the updated Louppe Review is running. The installed stable app,
latest combined review archive, demo folders, preferences and saved decisions are
preserved. Recovery manifests are in /private/tmp/louppe-review-cleanup/.

## Solid saved-decision banner background — 12 October

The banner row now explicitly fills its full width with Color.appBackground.
It previously inherited the safe-area inset's transparent background, revealing
separate pane shades beneath the message, spacer and controls. Its copy, controls,
checking state and dismissal behavior are unchanged.

Focused recovery/complete hotkey checks passed 47/47, and mandatory performance
checks passed 75/75. Release preflight and loose/archive strict signatures passed;
the complete Contents trees matched. After Alex quit the previous review, the
updated review8 replaced it at the existing path and reopened the same demo.
All 34 media files, 34 saved entries and four recovery records were preserved.
Older and temporary packaging app copies were moved to Trash. Native capture
remains unavailable (-3811).

## Precommit review — 12 October 2026

Reviewed the complete uncommitted app change against `081b228`, with `main`
matching `origin/main` at the start. No commit, push, installation or publication
was performed. Prepared the next unreleased version, 1.11.0 (13), as required by
the repository's release-cycle rule.

Three reproduced recovery bugs are fixed:

- A content check could restore an old rejection after Clear All Decisions.
  Explicit clears now retain their timestamp on only the affected physical files;
  already-undecided pair components retain their own metadata.
- Undo back to an undecided file could also be reversed by a pending recovery.
  Undo preserves its exact metadata snapshot and keeps the older decision as
  resolved history. Both cases are tested through save and reopen.
- A uniquely identified physical original returning under a new filename could
  remain stranded in recovery history. The shared identity index now finds it,
  validates it afresh and restores without a preliminary full-content read.
  Copied-and-renamed content discovery remains deferred.

Recovery target/record lookups are indexed once per structural generation;
ordinary decisions queue touched files for fingerprints instead of scanning
the full folder. The updated 100k Ready-session rating benchmark measured
0.2–0.3 ms. Cue generations retain independent folder-access leases and retire
during transitions, file operations, launch recovery and Quit. A new test proves
late cues cannot publish during Quit and that canceling Quit resumes checking.
Active cue-filter refreshes skip unchanged matches and coalesce to 100 ms,
flushing the final results at completion. Large-folder coverage/filter profiling
remains AUD-06.

Final validation, Xcode 27/macOS 27 SDK:

| Check | Result |
| --- | --- |
| Complete XCTest suite with disposable Fuji RAW | 640 executed: 627 passed, 13 skipped, zero failures |
| Complete HotkeyTests | 35 passed within the full suite |
| Required performance/file-safety checks after final code change | 75/75 passed, including disposable Trash/Undo |
| Direct-download release package | Release preflight passed for 1.11.0 (13); independent loose/archive signatures and complete Contents comparison passed |
| App Store Release configuration | Compiled in a separate scratch cache; product has no Sparkle linkage |
| Final isolated app launch | Exact process opened 34 files and saved schema 7 with five retained history records, three pending |
| Disposable originals | 34/34 media hashes unchanged after launch |
| Whitespace | `git diff --check` passed |

The default Xcode SwiftPM test backend failed on Finder metadata attached to its
XCTest bundle. The existing native backend used by packaging passed; AGENTS.md
now records the working test command. Native is deprecated by SwiftPM, so future
toolchain/backend acceptance remains a maintenance item rather than a test pass.

Native inspection of the final isolated build failed with ScreenCaptureKit
`-3811`; text-only followup had no app binding after that failure. Launch and
disk evidence above were checked independently. New-sheet interaction, settings
resets, small/translated layouts and spoken VoiceOver remain unverified. The
temporary verification process/bundle were removed; its media/evidence remain
in `/private/tmp/Louppe-Precommit-2026-10-12`. The existing review app and stable
installation were not replaced.

The 13 skips require a configured RAW decoder benchmark, ten coordinated mounted
volume/remount cases, another display, or accessibility children unavailable in
the XCTest host. They are not passes. Real high-speed Fuji/shutter-press cases,
AUD-03/05/18/23/24, older/unsupported RAW 9 configurations and external editor
acceptance remain recorded in BACKLOG.md.

Checked the unarchived chats “Develop quality cues across media”, “Prototype
Louppe quality cues”, and “Investigate and automate issue”, including every later
UI correction. The accepted photo/recovery slice is implemented: Filter sections,
independent rules, per-rule reset icons, compact matching-only Info values,
RAW-only histogram source labels, Captured/Time zone with estimated fallbacks,
aligned tile badges and the dismissible solid-background notice. Older-build
cleanup was completed in the earlier chat; this review left no extra running
verification app. Public app source/docs/tests contain no identifying feedback
sender reference.

The backlog now distinguishes implementation from acceptance and explicitly
retains blur/softness, inline comparison, subject/detail crops, timed audio/video
cues, ML/AI and portable remapping/history retention as followups. No deferred
feature is claimed complete. No reproduced code defect remains open from this
review; the native/hardware acceptance gaps above still limit release confidence.
