# 1.12 local review — 20 October 2026

Owner-requested response to Aymeric's early-user feedback. Work stays on the
managed `main` checkout; no commit, push or publication is requested.

## Acceptance

- Open one folder from the Dock, including cold launch and replacement of an
  existing session. Bring the main window forward; reject unsupported drops
  visibly and retain current decisions if the safe transition fails.
- Drop a replacement folder directly into the main window. Preserve the chosen
  window frame through replacement, scanning and Back; keep first-launch sizing
  useful, native minimum sizes and full screen intact.
- Persist custom single-key review bindings with layout-character or physical
  position matching. Reject conflicts/reserved input, reset defaults, update
  displayed hints, and preserve text/control/modal/VoiceOver ownership and the
  existing sole session keyboard monitor.
- Show Fuji film simulation in Info and as an indexed multi-choice Filter facet,
  including color and monochrome variants. Preserve per-file/pair metadata,
  current/selection, reset behavior and explicit missing/unknown values.
- Pass affected logic checks, complete HotkeyTests, repository performance/safety
  checks, package verification and an actual launch using disposable media.
- Update the local app for Alex to review. Record remaining native/hardware
  coverage honestly; implementation and automated checks do not imply owner
  acceptance or public-release approval.

## Scope and baseline

Baseline: `429839b2fc347c1580d7f19401cfd66bac44ce68`; published 1.11.0 (13).
The pre-existing uncommitted JPEG XL/AVIF/WebP fixtures, format tests, README and
changelog edits are retained. The unpublished 1.11.1 entry becomes 1.12.0,
retaining build 14 for the same release cycle.

Renaming discovery, temporary preview softness and Maps lookup are deferred in
BACKLOG.md. General arbitrary EXIF filtering remains a follow-up to the focused
Fuji field. This work adds no renaming, image-rendering or map behavior.

## Verification

- Repository performance/safety runner: 75/75 passed, including disposable
  Trash/restore round trips. Full-preview/cache/concurrency policies are unchanged.
- Initial integrated full suite: 782 cases, 36 explicit skips; one new window
  test exposed five origin-drift assertions. The source now restores the prior
  origin after toolbar-style changes, and the complete affected suites pass:
  FolderOpening, FujiFilmSimulation/Filter, Hotkey, Localization,
  MainWindowLayout and ReviewShortcut. Final full run: **782 cases, 36 explicit
  skips, zero failures** (746 passed). Complete HotkeyTests passed before install.
- The window fixtures also cover 13 connected drives and five recents on Back;
  columns reflow within the retained review width instead of widening the window.
- Read-only inspection of an existing X-T5 JPEG confirmed ACROS + Ye encoded in
  Saturation without FilmMode. Generated JPEG/EXIF fixtures cover two color
  simulations plus monochrome, malformed metadata, pairs and replacement files.
- Shortcut review found and fixed false Dvorak conflicts in the inactive mode;
  each mode now keeps its own mappings. The recorder cancels and passes system
  and accessibility chords through. All six language catalogs cover the new UI.

- App Store configuration (`LOUPPE_APP_STORE=1`, `-DAPP_STORE`) compiles with the
  current Xcode SDK. This establishes compile compatibility, not sandbox grants.
- Native capture became unavailable: ScreenCaptureKit repeatedly returned -3811
  audio/video capture failure. The existing app was at Welcome when its state was
  last readable. Do not reset user permissions/preferences or force-close it.
  Package the candidate as the existing separate `louppe - to review` identity.

- Direct packaging passed release preflight for 1.12.0 (14). The separate review
  builder hit the known File Provider Finder-metadata signing race on its loose
  `dist/` copy. Its archive was independently unpacked in `/private/tmp`, verified
  and installed outside File Provider. The archived and installed review apps
  both pass strict deep signature verification; complete `Contents/` trees match.
  The executable UUID and unchanged resources also match the direct candidate;
  review identity/signature and Info.plist changes are intentional.
- Installed `/Applications/louppe - to review.app`, version 1.12.0 (14), identity
  `com.alexandermarkin.louppe.review2`. Automatic updates are disabled. Review ZIP
  SHA-256: `1c68368960ba3915b5cf5c565d464c73e0bcbdd2d7b00aa5cb1a7cc85b5918a1`.
- Actual launch with `-openFolder` opened four copied Fuji JPEGs and saved a
  format-7 session. A native Launch Services folder-open request replaced it
  with a two-JPEG folder and saved that session; a second native request returned
  to the Fuji folder. All six copies match the original source bytes. The process
  remained running and the installed signature still verifies.
- Native capture failed again on the new app with the same -3811 error. Actual
  Dock dragging, custom-key recording and visual Filter/Info interaction remain
  manual acceptance; automated native hotkey/window/recorder tests are recorded
  above. The separate review app is left open on disposable Fuji media in
  `/private/tmp/Louppe-1.12-review/Fuji review`.

A real X-T4 color bracket, sandboxed Store folder grants, visual interaction,
older macOS and multiple-display hardware acceptance remain separate from
automated/local checks. No commit, push, notarization, or public release was made.

## Shortcut follow-up — multiple keys and contexts

Owner requested several keys per action, with reuse only in disjoint view/media
contexts. Settings now groups and searches actions, adds/removes individual keys,
shows a When scope per key, names conflicts and supports action/current-mode
resets. Matching modes retain independent maps and migrate the first local
candidate's single-key preferences.

Bare arrows, Tab and Space share the same alias authority as letters. Removing
one really removes its route; scoped reuse has no hidden priority. Default Left
seeks in playable Gallery video and navigates elsewhere, Up navigates Gallery or
Grid rows, and Space advances media without playback or toggles playable media.
Native-control/text focus, system/VoiceOver chords and fixed Command/Escape/
modified-arrow commands retain their ownership.

Focused Hotkey/ReviewShortcut/Localization suites: **81 passed, zero failures**.
Coverage includes scoped reuse and conflicts, removal, defaults/context matrix,
Dvorak and independent modes, legacy migration, reset conflicts, recorder mount/
cancellation, concurrent preference decoding and copy isolation. One bounded
decoded-value cache and indexed validation avoid repeated per-row/keypress work.
Search and group collapse cancel hidden recording drafts before they can remount.

Final full suite: **796 cases, 36 explicit skips, zero failures** (760 passed),
including complete HotkeyTests. The required performance/safety runner passes
75/75; the App Store configuration compiles. After making the context picker's
selected value explicit, the affected Hotkey/ReviewShortcut/Localization suites
passed again: **81 tests, zero failures**, before the final install.

Native Settings interaction added T alongside F for Mark Yes in Gallery. Adding
T to Mark No with an overlapping scope displayed the named conflict; changing
its scope to Grid saved successfully alongside D. In the session, T marked Yes
in Gallery and No in Grid. Undo restored the disposable decisions, and the two
test bindings were removed individually, retaining F/D. Search and recording
were exercised with real controls. After the final install, a successful native
screenshot confirmed the Review section, search, matching-mode explanation,
add/reset/remove controls and selected context labels at the normal window size.
Capture is intermittent; broader languages/older-system layouts remain owner
acceptance.

The final builder passed direct release preflight, then hit the known File
Provider Finder-metadata signing race on the loose review app. The review ZIP
was independently unpacked in `/private/tmp`; the archived and installed apps
pass strict deep signature verification and their complete `Contents/` trees
match. Installed `/Applications/louppe - to review.app` launched the four copied
Fuji JPEGs, retained the shortcut preferences, showed ACROS + Ye in Info, and
opened the updated Settings editor. No temporary T aliases remain and the saved
disposable session has four undecided entries after Undo.

Final review ZIP SHA-256:
`da072aefb8cc6d800346df68a0971f3f2c7243dccbb0fb1692b636d62f89da7a`.
The prior review copy is recoverable at
`/private/tmp/Louppe-multikey-final-s4f7hriz/previous-review.app`.

Version remains 1.12.0 (14) within the same unpublished release cycle.

## Fuji JPEG and RAW verification

Read-only comparison against ExifTool on 62 real X-T50 files passes: 39 JPEGs
and 23 RAFs from the September shoot and October review media. The corpus has
54 CLASSIC Neg. files (33 JPEG, 21 RAF) and eight ACROS + Ye files (six JPEG,
two RAF). Both the normal ImageIO-assisted scan and direct container fallback
match the independently extracted simulation. Info fields, indexed filtering,
RAW-primary pairing and separate-again projection retain the expected values.

The opt-in corpus test uses `LOUPPE_FUJI_VALIDATION_MANIFEST`, a private JSON
array of absolute `path` and enum `simulation` values; no personal images or
paths were added to fixtures. The generated manifest and ExifTool output are
in `/private/tmp/Louppe-fuji-validation-manifest.json` and
`/private/tmp/Louppe-fuji-source-tags.json`. Additional generated RAF/JPEG
fixtures cover color modes and all four ACROS variants with little/big-endian
EXIF and nonzero RAF preview offsets. All eight focused tests pass with the
corpus enabled; the log is `/private/tmp/Louppe-fuji-corpus-check.log`.

The installed review app shows CLASSIC Neg. and ACROS + Ye in Info on real JPEG
and RAF copies. Its Film simulation filter reports two files per simulation;
selecting ACROS + Ye retains its JPEG and RAF and reports Showing 2 of 4.
It is left open on those results in
`/private/tmp/Louppe-1.12-review/Fuji JPEG and RAW`. SHA-256 comparisons confirm
all 62 originals and four review copies are unchanged. No runtime fix was
needed, so the installed app/archive remain the verified candidate above.
Other cameras and simulations have fixture coverage, not a new real-camera
claim from this corpus.

## Shortcut UI simplification

Removed three persistent introductory paragraphs, repeated action-context
subtitles and the draft instruction paragraph. Search uses its placeholder
instead of a duplicate outside label. Each action retains its name, key rows,
context picker and add/reset/remove controls. Matching-mode explanations and
action context remain available through native help and accessibility hints;
controls keep explicit action-specific accessibility labels. Recording prompts,
empty states and conflict errors remain visible when relevant.

Affected Hotkey/ReviewShortcut/Localization suites: **81 passed, zero failures**,
including complete HotkeyTests before install. No shortcut behavior, metadata
reader, or file-operation behavior changed in this UI pass.

Native screenshot review confirms the compact layout and visible search
placeholder. The search field exposes one accessible name; icon controls retain
action-specific labels and the context pickers retain their selected values.
Search, Add, the recording prompt and Escape cancellation were exercised without
changing saved assignments. Native Tab traversal follows the user's existing
macOS keyboard-navigation setting; no system accessibility preferences changed.

Final simplified review app is installed and open in Settings, version 1.12.0
(14). Direct release preflight passed. The loose workspace review copy hit the
same File Provider metadata race; the archive was independently unpacked and
strictly verified, then compared against the installed app's complete Contents
tree. Both signatures pass and the trees match. Review ZIP SHA-256:
`09585cb8d8b75b9bb968b27740192d78e2fd241a952ade826d0126bd61c27b33`.
Prior review copy:
`/private/tmp/Louppe-simple-ui-final-_ms9dhpa/previous-review.app`.

## Backlog finishing pass

The owner requested obvious backlog work for 1.12 while retaining product
decisions. Acceptance for this pass:

- Explain the existing Filter Yes → metadata Rename workflow in Help, with
  the exact preview and Undo path; do not introduce naming recipes or controls.
- Mark a fitted photo's thumbnail stand-in as still loading until its own full
  preview is ready. Keep the indicator within existing zoom controls, revision
  guarded and absent at idle; retain decoder queues, budgets and prefetch policy.
- Make review packaging use the same clean local-volume output verification as
  direct release preflight, retaining independent archive verification and full
  Contents comparison.
- Pass affected tests, the complete suite and performance/safety runner, then
  install and launch the separate review app for native Help/loading checks.

Recommended decisions: defer Maps unless Alex chooses the small explicit
GPS-to-Maps action; defer new naming templates until a concrete desired filename
pattern is supplied. General EXIF filtering, automatic blur detection, ingest,
and broad rendering/performance redesign remain later work. Hardware/Store
grants, other editors and owner acceptance retain their existing backlog checks;
local implementation does not close them or authorize publication.

The first integrated run executed 800 cases with 36 skips and found one native
zoom hit-target regression: a leading indicator slot shifted Fit's existing
click location. The slot is now trailing, preserving Fit/slider input positions.
No native hit-test expectation was relaxed. Focused preview checks already pass
delayed success/failure, warm readiness and stale navigation publication.

After the layout correction, affected GalleryZoomLayout/MediaPerformance/
RawDisplay/Hotkey/Localization suites pass: 79 cases, one explicit optional-RAW
skip, zero failures. Final complete suite with the real Fuji manifest enabled:
**800 cases, 764 passed, 36 explicit skips, zero failures**. The performance/
safety runner passes **75/75**, including disposable Trash/restore. Store
configuration compiles with the current SDK. All 2,066 literal localization
callsites are covered. Logs are `/private/tmp/Louppe-1.12-backlog-*`.

The 1.12 changelog now includes the Henri/Aymeric acknowledgement and feedback
address from the owner's draft. Help describes the existing metadata rename
workflow in all six languages.

Alex chose to defer Maps and finish the current scope. The review package
script now completes successfully with independent loose-output/archive
verification; the former Finder-metadata failure is resolved by clean local-
volume verification, with no signing or content check removed.

Installed the verified 1.12.0 (14) review archive; strict deep signatures pass
on the archived and installed apps, and their complete Contents trees match.
ZIP SHA-256:
`7b4d287571846ae9ae2b9845f2f1af4075370b762684c101c43f1e5b938da11f`.
Prior review copy: `/private/tmp/Louppe-1.12-backlog-smf1rkd_/previous-review.app`.
Actual launch opened the four copied JPEG/RAF photos; idle has no detail-loading
accessibility element. Native Help exposes the complete rename instructions.
Help's pixel capture returned blank, so no new Help visual-layout acceptance is
claimed. Controlled mounted-view tests cover slow readiness/failure; real SD-card
timing and older-system/linguistic acceptance remain as recorded in the backlog.

The installed Gallery also passed a native JPEG 100% → Fit interaction: the Fit
control returns the viewport and slider readout to 23%. A successful Gallery
screenshot confirms the compact zoom surface with no idle loading indicator or
extra explanatory label. The app remains open on the disposable JPEG/RAF folder;
no source filenames, decisions or media bytes were changed by these interactions.

## Menu hints and visual keyboard draft

Owner requested separate right-aligned menu hints, live updates after remapping,
and a visual keyboard in Settings. Alex chose physical positions for new setups.
This includes older installs with no saved shortcut setup; explicit saved layout
or physical choices and both alias maps must remain unchanged.

Acceptance:

- Keep menu action titles clean, align hints in their own trailing column,
  refresh keys/mode/context and retain native menu selection and accessibility.
  SessionView remains the sole shortcut router; hints must not register another
  active key equivalent or steal text/other-window input.
- Draft a compact keyboard above the existing Settings editor. Assigned keys
  are outlined, selection filters existing actions, and clicking never remaps.
  Preserve recording, contexts, resets and conflicts. Keep geometry LTR in RTL
  interfaces; layout mode uses macOS input-source labels, while physical mode
  uses documented QWERTY position names. No persistent explanatory paragraphs.
- Check migration/defaults, native menu rendering, key selection/clearing,
  Settings edits updating hints, focus/modal ownership and the installed app.

Focused menu/keyboard/defaults/hotkey/localization checks pass **95/95** after
correcting SDK optional-font/selector names in the new menu tests and adapting
palette expectations to the new physical default. Final complete suite:
**814 cases, 778 passed, 36 explicit skips, zero failures**, with the real Fuji
validation manifest enabled. Saved layout modes and both alias maps round-trip;
legacy modes are preserved. No active menu equivalents were added by the hint
renderer. The additional test covers lazy Edit/View creation and attachment
without yielding the run loop, plus isolation from unrelated Settings menus.

The first final full run hit two assertions in one plain Grid-selection test
while native review-app testing used Command keys. That path samples live
`NSEvent.modifierFlags`. With UI interaction paused, the complete 814-case suite
passed; no production behavior or assertion was changed to accommodate it.
The performance/safety runner passes 75/75, and the visual keyboard draft passed
native selection/filtering for F, arrows, E and an unassigned T. Adding a T alias
updated the keyboard and File menu immediately; the test alias was removed.

Final App Store configuration compiles, all 2,084 literal localization calls
are covered, and release/review package verification passes. Installed archive:
`e9226993654fa2f806d66a8720b52224f4d98d0f2a1a94ffae3928a7bb0befd9`.
The extracted archive and installed review app independently pass strict deep
signature verification and their complete Contents trees match. Recoverable
previous copy: `/private/tmp/Louppe-keyboard-final-zqwkqlvt/previous-review.app`.

The installed candidate launched the four disposable Fuji JPEG/RAF files.
On their first openings, Edit and View expose clean action names with the correct
separate accessibility hints. A native Settings edit adding T to Export changes
File's hint immediately to E / T / ⌘E. T was then removed and confirmed unassigned;
the saved layout-mode choice remains unchanged. All four photos are undecided.
The final native Settings screenshot confirms the compact staggered keyboard,
assigned outlines, selected F, and filtered Mark Yes editor without extra prose.
Settings is left open there for the owner. Menu pixel capture is unavailable in
the computer-use bridge, so final menu-column visual alignment remains an owner
check; measured attributed columns, clean titles, accessibility, lazy creation
and live updates are covered by tests and native interaction. No public release
or commit was made.

## Mac keyboard silhouette follow-up

Owner requested the compact Mac keyboard shape and a slightly wider Settings
window. Settings is now 620 × 600 points, retaining the single scrolling form.
The keyboard includes a function row, Delete, Caps Lock, Return, both Shift keys,
the modifier row and wide Space. Left/right arrows are full-height; up/down share
one key height, matching the supplied ANSI Mac reference. Every row shares the
same 14½-unit width. Fixed hardware keys are decorative, excluded from
accessibility navigation and do not imply new shortcut support. Assignable keys
retain selection, mapping modes, action filtering and recording behavior.

Affected Settings/keyboard/Hotkey/localization tests: 70 executed, 68 passed,
two explicit existing XCTest-host accessibility skips, zero failures. An earlier
keyboard/shortcut/Hotkey/localization run passed 89/89. The final Store
configuration compiles and all 2,084 literal localization calls remain covered.
Independent source review found no row-width or height mismatch.

Installed and launched the verified review archive, SHA-256
`3cd2607a9d3020c4d3e9d352775b65a22b66c8d014c00880fb70d7cf9221556b`.
Strict deep signatures pass independently for the extracted and installed apps;
their complete Contents trees match. Previous review copy is recoverable at
`/private/tmp/Louppe-keyboard-final-piy7xodj/previous-review.app`.
Native screenshot confirms the wider window, complete Mac silhouette, aligned
rows and legible keycaps without clipping. Native F selection shows Mark Yes;
Left shows Previous item and Seek backward with their existing scopes. Selection
was then cleared; Settings remains open. No bindings or modes were changed.

## Stability and performance review

The [quality review](QUALITY_REVIEW_1.12_2026-10-20.md) records three independent
source reviews, fixes for partial Fuji monochrome metadata and redundant/thread-
unsafe menu notifications, and deterministic Grid-click tests. Final full suite:
817 cases, 781 passed, 36 explicit skips, zero failures. Final safety runner:
75/75. Optimized speed runner: 19/19 tests, 225 workloads across 18 reports,
including 100k items and real RAW source-integrity checks. Large-folder camera
sort/projection remains a measured backlog item. Further UI refinement was paused
during this review; the Mac keyboard and traditional list are preserved.

## Shortcut editor refinement

Review now also contains Export, Clear Decisions and Undo. The separate Actions
group is removed without changing saved action identities or bindings. All
shortcut disclosure headers (including Fixed shortcuts) have a full-width
32-point target; expanded controls are independent. Add, reset, remove and
cancel share equal symbol bounds, native bordered circular buttons and regular
control sizing. Names and explanatory help remain accessible without adding
visible labels. The keyboard and traditional list remain together.

Native interaction tests click every header corner in left-to-right and
right-to-left layouts, expand and collapse, activate a child separately and
confirm equal button bounds and working actions. Focused suite: 74 cases,
72 passed, two existing accessibility-host skips, zero failures; includes all
38 HotkeyTests. Localization: 2,089 literal calls, zero missing/unsupported.
Button choices follow standard SwiftUI control styling, as described in
[Apple's control guidance](https://developer.apple.com/videos/play/wwdc2025/323/?time=865)
and [equal-size button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons).

Built and installed the official 1.12.0 (14) archive, SHA-256
`46b3bd14fba9366b0cdf5dd49c8c857e5f4f45f62d3aeea4792dd4754fc3e823`.
Strict deep signatures and complete Contents trees (including framework
symlinks) match. Only `/Applications/Louppe.app` is installed; the prior copy is
recoverable at `/private/tmp/Louppe-shortcut-settings-n8xx8ixn/previous-Louppe.app`.
No preferences were migrated or edited. Launched with disposable Fuji media,
opened Settings, and confirmed the merged Review entries through accessibility.
Native screenshot confirms matching circular add/reset/remove controls, legible
labels, and the retained keyboard/list arrangement. A subsequent coordinate
edge-click check was unavailable because ScreenCaptureKit returned -3812 twice;
the mounted native event tests cover header edges and child independence.

## Command shortcuts — acceptance for the next local build

- Keep the existing review matching modes and aliases intact. Standard Mac
  shortcuts retain their actions; Export, Command Palette and Rescan gain
  editable Command / Shift-Command aliases with reserved-key conflict checks.
- Show Command and Shift layers on the Mac keyboard. Clicking modifier keycaps
  latches a preview; holding modifiers temporarily previews their layer.
  Selection filters the corresponding action without executing it. Command
  positions reflect the active input source independently of review matching.
- Keep one traditional action row per action, with related standard/custom
  aliases together, clear accessible names and compact native controls.
- Use the saved command bindings for routing, menu/palette/Help hints and
  tooltips. Removed defaults stop working; new aliases respect the existing
  text, focus, modal, media-context and file-operation gates.
- Align menu hints with the OS shortcut column. Preserve native menu behavior
  and accessibility; display hints must not introduce a second keyboard route.
- Verify migration/defaults/conflicts and real event ownership, full HotkeyTests,
  affected UI checks, localization, Store compilation and exact release package.
  Update only `/Applications/Louppe.app` and verify an actual launch.

### Implementation and regression results

Separate schema-1 Command preferences preserve both existing review maps. Export,
Command Palette and Rescan accept multiple Command / Shift-Command letter aliases;
reserved system/text chords, duplicate claims and unsafe stored data are rejected.
Settings integrates aliases into related action rows, retains read-only standard
keys, and offers latched/held Command and Shift keyboard previews. Shift-only
review letters remain visible where they actually work. Command translations use
the input source's modifier flags independently of physical review matching.

Menu hints use the native AppKit key-equivalent column only during explicit menu
tracking. Standard equivalents remain untouched; restoration covers nested/parent
tracking end, removed/replaced rows/menus, app resignation and teardown. The
ordinary SessionView monitor and its text, focus, modal and file-operation gates
remain authoritative outside menu navigation. Palette, footer, Help and toolbar
hints use the same saved values.

Focused integration suite: 126 cases, 124 passed, two existing accessibility-host
skips, zero failures. Full suite: 842 cases, 805 passed, 37 explicit environment/
hardware skips, zero failures, including all 40 HotkeyTests. The real Fuji corpus
manifest test was skipped in this environment-free run; its earlier independent
JPEG/RAF manifest acceptance remains recorded in the quality review. Store
configuration compiles. Localization checks 2,129 literal calls with no missing
or unsupported keys. An independent review identified the Shift-letter preview
gap (fixed) and found no further input-ownership or teardown issues.

Native installed-app acceptance changed Export from ⌘E to ⇧⌘T using its Settings
recorder. The old key stopped matching; Command-Shift/T highlighted Export,
⇧⌘T opened the Export sheet, the File menu Help and toolbar changed immediately,
and the palette screenshot showed `E position / ⇧⌘T`. Cancelled the sheet without
exporting and restored ⌘E. Refinement from this check: a keyboard-filtered editor
now follows a newly recorded key/layer instead of hiding behind its old key;
palette accessibility descriptions also include the displayed shortcut.
Affected 126-case suite passed again (124 passed, two existing host skips).
The native Settings screenshot confirms retained Mac proportions and compact
controls. File-menu screenshots are unavailable through the native capture tool;
menu values are verified through accessibility and the native-column implementation,
with exact pixel placement left for owner review.

The selected-key follow-up was verified natively in both directions (⌘E → ⇧⌘T
and back), keeping the Export editor visible and selecting the new layer/key.
Native capture then exposed MenuStyle's gray, unbordered Export Add control;
it now reuses the exact `ShortcutAccessoryButton` with a compact two-choice
popover. Recording starts after dismissal so its focus remains in Settings.
The affected 126-case suite passed again (124 passed, two existing host skips).

Final package installed at `/Applications/Louppe.app`, version 1.12.0 (14),
archive SHA-256 `b59bd265735e692770d7f5d197ea9b1f5dd311a19b8ef29383548fb16fb82dce`.
Strict deep signatures and full Contents trees match; this is the only Louppe
copy in Applications. Previous app is recoverable at
`/private/tmp/Louppe-shortcut-settings-7pyk71uo/previous-Louppe.app`.
A transient SwiftPM build-database I/O error recovered after its integrity check
and a clean retry; the failed build was not installed. The final Store
configuration compiles successfully too.

Final native chooser acceptance passed: Export Add exposes exactly Single key
and Command shortcut; choosing Command shortcut returns recording focus and
captures ⇧⌘T as an additional alias. The keyboard selects that layer/key and
retains the editor. Removed only the temporary alias, confirmed E position and
⌘E remain, and left Settings on the Command/E preview. Original review choices
remain intact. Native capture required reconnecting after ScreenCaptureKit
errors; final chooser/action values were confirmed through accessibility.

## Gallery preview preference removal

Removed the RAW display/decoder selector from the Gallery zoom bar. Both
preferences remain in Settings; existing selections and explicit RAW error
recovery actions are preserved. The RAW 9 failure message now points to Settings,
with matching translations and documentation.

Focused checks: 65 cases, 61 passed, four explicit skips, zero failures,
including all 40 HotkeyTests. After the copy update, RAW/localization checks:
27 cases, 26 passed, one explicit skip, zero failures. Localization validates
2,122 literal calls without missing or unsupported keys; diff whitespace is clean.

Installed version 1.12.0 (14) at `/Applications/Louppe.app`; archive SHA-256
`74b5643bd2ea660bc69c964b6be5aac977286dd496fa9b2d8b10e32473a8e065`.
Strict deep signatures and complete extracted/installed Contents trees match.
Previous app is recoverable at
`/private/tmp/Louppe-shortcut-settings-1b7pl3ls/previous-Louppe.app`.
The installed app launched with the disposable Fuji folder; native accessibility
showed Fit and Photo zoom in its zoom bar on the selected JPEG. Final RAW-specific
native verification was blocked by repeated ScreenCaptureKit -3811 errors, even
after foregrounding the app. Source verification confirms the two preference
pickers exist only in Settings; exact RAW-state visual acceptance remains open.
No preferences were changed during this check.

## Browser/Grid horizontal-scroll regression

Acceptance: keep the complete Browser column and Grid tiles inside their clip;
prevent horizontal movement during wheel/trackpad input, momentum, resizing and
follow-navigation; retain vertical movement and native scrollers; verify lifecycle
cleanup and the installed build. Make the regression suites installation gates.

Baseline: all five existing Browser/Grid tests passed. A new short-folder Browser
test failed with one and four items: native pane width 122 instead of 139 points,
document width 122, clip width 105. The missing gutter width was real overflow.
The previous test covered only 30 items, and manual scroll probes pre-constrained
their inputs. Hiding horizontal scrollers and disabling elasticity cannot prohibit
movement inside an overflowing document.

Both views now retain a flexible outer document with actual content aligned at
native X=0, including RTL; Browser's padded column stays 122 points. The bridge
sits on the content so tests measure it rather than empty document tail. Both retain
a one-point minimum-height guard. Their shared bridge synchronously pins only X,
preserving Y, lazy rendering and native clip/scroller identity. Observation is
local, rebinds with the clip, and stops on removal/dismantling.

Final focused gate: 57 passed, zero skipped, zero failures, including all 40
HotkeyTests, BrowserScrollTests, GridScrollTests, PersistentVerticalScrollerTests,
GalleryZoomLayoutTests and ViewSwitchTests. Covers 1/4/30-item Browser, Info,
resize, repeated Gallery/Grid transitions, Grid thumbnail sizes, LTR/RTL and both
display scales, unconstrained X changes, validated pixel wheel phases/diagonal
input/momentum, real line-wheel vertical movement, distant follow-navigation,
native scroller identity, reparenting, clip replacement and dismantling. An
independent review found no remaining production correctness/performance issue;
its event-phase test correction is included in the final passing run.
`AGENTS.md` now requires all three scrolling suites before every local install,
even for unrelated UI edits, and installed-app gesture checks when available.

Installed-app follow-up exposed slight clipping of Grid's last column at the
owner's 1512-point window with Info visible. Grid now uses the same flexible
wrapper as Browser; its coordinate space, gestures and rubber-band overlay stay
inside that wrapper. Added 1512-point layouts to the LTR/RTL, both-scale, short/
long Grid matrix. Independent review confirmed the wrapper preserves hit testing
and drag coordinates without additional view invalidations.

The expanded final gate passed all 57 cases again, with zero skips/failures
(`Louppe-horizontal-wide-verified-tests.log`). Native checks of the first
installed fix used four Fuji JPEG/RAF files and a disposable 48-PNG folder:
Browser and Grid ignored horizontal gestures in both directions, and vertical
scroll values advanced to 0.4102 in Browser and 1.0 in Grid. The large-window
Grid clipping finding above was corrected after that check.

Final package: official `/Applications/Louppe.app`, 1.12.0 (14), archive SHA-256
`9a03a7da51462b283a40224f458678df6edeb426496592b7a6a40c4e7a479d86`.
Release preflight, strict deep signatures and independent extracted/installed
Contents comparison pass. Prior app is recoverable at
`/private/tmp/Louppe-shortcut-settings-osp3zblk/previous-Louppe.app`.
Final installed-app checks confirm complete Grid columns at the owner's wide
window with Info, unchanged horizontal positions after gestures in both
directions, Browser vertical value 0.2021 and Grid value 1.0. Before/after native
screenshots confirm the last Grid column is no longer clipped. Quit through
the normal save flow and returned to the disposable Fuji folder for review.

## Zoom-pill readout spacing

Removed the empty trailing loading-indicator column. A loading spinner now
temporarily shares the percentage readout's space; its hidden text retains
measurement so loading/ready transitions keep the pill and input positions steady.
The readout is centered within its existing minimum width for balanced outer
spacing. Native glass, height, slider and Fit behavior remain unchanged.
All 65 affected checks pass without skips/failures, including loading-state
size stability in light/dark and LTR/RTL, native zoom hit targets, preview
readiness, all 40 HotkeyTests and the mandatory Browser/Grid/scroll-bridge gates.
Release build and independent package preflight pass.

Installed at `/Applications/Louppe.app`, 1.12.0 (14), archive SHA-256
`c776bb2a17aa248ba6b0ac9dbc711f86813d842b3fff4e4b8dfafc982911e692`.
Strict deep signatures and complete extracted/installed Contents trees match.
Previous copy: `/private/tmp/Louppe-shortcut-settings-ut8ojob2/previous-Louppe.app`.
Waited for Alex to close his active Rename dialog before normal Quit/install.
The installed full-size Gallery screenshot confirms balanced spacing at 23%.
Browser/Grid horizontal gesture checks retain their positions after switching;
left the app in Gallery/Fit on the disposable Fuji folder. Initial captures
showed a Stage Manager thumbnail; foregrounding recovered the full-size capture.

### Rename scheme interaction and preferred dates

Renaming parts now drag as complete rows, including unchecked parts, with a
visible drop target. Transfers are scoped to the current sheet. Reordering
preserves enabled flags and keeps checkbox clicks independent. Context-menu
and VoiceOver actions retain earlier/later movement without visible arrow
buttons. Removed setup subtitles, instruction paragraphs, repeated family
copy, and visible planning narration. Kept preview/counts, conflict and ACR
warnings, final confirmation, ExFAT warning, journaled execution and undo.

Date parts use `AppDateFormat.day`, matching the Mac’s short/custom date format.
The existing filename sanitizer replaces unsafe separators and invisible
control marks; capture-time formatting and extension bytes are unchanged.
Dates therefore no longer promise ISO chronological filename sorting.

Validation: all 86 relevant cases pass across the initial run and focused
rerun: 6 FileRenaming, 30 SourceOrganization, 40 Hotkey, 3 BrowserScroll,
4 GridScroll, and 3 PersistentVerticalScroller. The initial run exposed an
incorrect new Arabic test expectation (retained directional controls); corrected
it to match existing safe sanitizing and reran all 6 FileRenaming cases, passing.
No skipped cases. Logs: `/private/tmp/Louppe-rename-interface-tests.log` and
`/private/tmp/Louppe-rename-date-tests.log`. Independent integrated review found
no blocking issue. Installed native interaction verification follows below.

Native first-install check confirmed the compact sheet, date `2026.09.26`
matching Info, independent checkbox toggling, and context-menu reordering with
updated RAW/JPEG previews. No file mutation was submitted. Custom AX reorder
actions on the row container were not exposed, so moved those actions and IDs
directly onto the checkbox; the complete 86-case suite then passed in one run
with zero failures/skips (`/private/tmp/Louppe-rename-final-tests.log`).

CUA drag calls fail before input with `noWindowsAvailable` for this sheet,
including after foregrounding/rebinding and checking coordinate scale. AX
clicks, menus and screenshots work. Thus physical drag/drop remains a manual
acceptance gap; model reordering and the non-drag native route are verified.

Final installed build: official `/Applications/Louppe.app`, 1.12.0 (14),
archive SHA-256 `6e4ef1894569dcc5c5e0bdd267e11da47b7244504ca010c72dbc40742b5e531c`.
Strict deep signatures and complete extracted/installed Contents match; only
one Louppe app remains in Applications. Previous app retained at
`/private/tmp/Louppe-shortcut-settings-5apxv1aj/previous-Louppe.app`.
Final packaging log: `/private/tmp/Louppe-rename-final-build.log`.

The final installed app launched on the disposable Fuji folder. Each checkbox
now exposes both earlier/later AX actions. Invoked Sequence earlier through
unchecked rows and ahead of capture date; preview changed to
`001_2026.09.26_14-08-49.JPG` and matching RAF. Final confirmation retains the
exact preview and contents/extensions/no-overwrite/undo notice. Canceled it
without executing, then reopened a fresh default rename sheet for Alex’s
review. Physical drag gesture remains unverified due to CUA’s sheet window
lookup failure, as recorded above.
