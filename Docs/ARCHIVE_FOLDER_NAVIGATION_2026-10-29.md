# Archive folder navigation — 29 October 2026

Implemented on `archive-folder-navigation`, based on clean `main` at `965163b`.
Alex requested a separate branch and review build. No commit, push or public
release was requested. Version remains the open **1.13.0 (15)** cycle.
Open in Maps is deferred to Later in the backlog.

## Behavior

- One leading pane: Gallery's compact native menu chooses Browser or Folders;
  Grid's sidebar button opens Folders in one click. Browser keeps its width;
  Folders uses a 220-point native outline. Info stays trailing.
- All Media is the complete archive. Folder selection includes descendants by
  default; a context/breadcrumb menu offers direct items only. Breadcrumbs return
  to ancestors. Empty-folder and filter-empty states are distinct.
- Counts describe review items before metadata filters. A pair belongs to either
  physical parent but counts once at shared ancestors. Existing pair-wide review
  and operation behavior remains; file sheets explain cross-folder pairs.
- Navigation scopes the prepared inventory before metadata filters. It neither
  rescans nor opens another session. All decisions still save through the one
  original root authority; no nested decision sidecars or media changes.
- All action scopes and Clear All Decisions follow the current folder. Labels
  say Current Folder or Entire Archive; Selected/Filtered narrow that scope.
  Navigate to All Media explicitly for archive-wide work.
- Root/directory volume, inode and birth identity own remembered state. Current
  and independent Browser/Grid anchors require matching physical revisions.
  Replaced/missing directories fall back through verified ancestors. Live opening
  interaction and same-folder rescan selection take precedence over saved positions.
- State is bounded separately from decisions/caches: 32 roots, 128 positions per
  root, 512 expansions, 4 MiB plus one previous copy. Writes coalesce at 500 ms;
  transitions take finite checkpoints. Failed/corrupt storage retains prior bytes
  and reports a retryable warning. Review bundles and test hosts are isolated.

## Implementation and review

Discovery retains directories, including empty ones, in its existing traversal.
Stable directory identity is checked alongside file validation. The opening worker
prepares natural sibling ordering, pair-aware counts and DFS ranges/postings
off-main. Postings scale with physical parent memberships. Folder queries visit
their own postings; cached sort ranks order only the resulting candidates.
Position restoration checks at most three physical IDs through existing maps.

`NSOutlineView` reuses native cells and reloads only for an index generation.
Expansion restores ancestors before children. Collapsing a selected ancestor
selects the visible parent. Native focus owns arrows; no second key monitor.
Viewport/menu callbacks reject retired generations. Native rows explicitly carry
LTR/RTL direction. Root All Media always counts/includes descendants.

Three subagents implemented the index, native outline and persistence separately.
Two read-only reviews covered integration and the final changed blocks. Review
fixed Grid's first-click toggle, eager root allocation in action enablement, and
overlapping save-task ownership. No remaining blocker was found in that review.

Focused checks also caught and fixed:

- A redundant `skipDescendants()` on symlinks/already-skipped packages could
  suppress the next real sibling subtree. Strict enumeration tests retain their
  assertions and now cover sibling links, packages and `folder.JPG` directories.
- Stateful lazy-filter materialization could discard valid saved positions on
  a second traversal. A bounded single-pass loop replaces it.
- Remembered-current restoration could clear explicit same-folder rescan
  selection. Live rescan identity/selection now takes precedence.

Organize/Rename/Undo retain their existing worker-confirmed rescan; new directory
identities are captured before Ready. Disposable integration checks verify
Organize → browse new destination → relaunch, and Rename → Undo, preserving
original file contents and excluding unrelated folders.

## Validation

- Background-safe broad run: **1,131 cases, 48 skips, zero failures**. Explicit
  foreground-window/activation cases were excluded; this is not a full-suite pass.
- Complete Hotkey, BrowserScroll, GridScroll and PersistentVerticalScroller
  gates plus folder/localization checks: **114 cases, zero failures** at that
  checkpoint. Later changed-block/visual checks are recorded below.
- Twelve hidden native captures: Gallery/Grid, 900/1512-point widths, Info,
  light/dark, RTL layout, empty/direct-empty scopes and the original Browser.
  Windows never become visible/key. All 72 generated originals retained their
  exact bytes. RTL captures test layout direction, not an Arabic-language run.
- Synthetic unoptimized 100k-item/1,001-folder sample: tree preparation 555 ms;
  200 folder queries with prepared filtering, 100 items each, 28.6 ms combined.
  These are model timings, not storage-cold opening or physical frame pacing.
- Six source catalogs and literal localization coverage checked; Help and the
  user/development/performance guides describe the same scope behavior.
- Final changed-block, native capture and localization run: **51 cases, zero
  failures**. It includes the new live-rescan selection regression.
- Safety/performance runner: **75/75**, including real disposable Trash/restore.
  Initial failures caught the rescan selection regression and retained the root
  Clear All tally contract; both were fixed without weakening assertions.
- Standalone scrollbar **10/10**, native video/audio and resource-bundle checks
  passed. Strict Swift 6 build with warnings as errors passed.
- All **2,384** literal localization callsites are supported in six catalogs.
- Release packaging and loose/archive preflight passed. The dated review copy
  passes strict deep signatures independently from its extracted ZIP; all 110
  files/symlinks, file modes and bytes match. File Provider attached Finder
  metadata to the loose app after packaging; cleaning only that artifact's xattrs
  restored strict verification without re-signing. The ZIP remained unchanged.
- The packaged review app launched with `LOUPPE_BACKGROUND_LAUNCH=1` and
  `open -g -j` on 36 disposable WEBPs. App-bound AX confirmed Gallery/Grid,
  **0/36 reviewed, Saved**, and the first Grid sidebar click opening the native
  tree with All Media 36, 2025 12, 2026 24 and an empty folder. All 36 originals
  retained exact bytes. An inactive-window row click produced no selection
  change; actual packaged row-click acceptance remains a foreground/physical
  check, not a pass inferred from the hidden-window contracts.

Logs: `/tmp/louppe-archive-nav-background-suite.log`,
`/tmp/louppe-archive-nav-final-gates.log`,
`/tmp/louppe-archive-nav-final-focus.log` and
`/tmp/louppe-archive-nav-safety-final.log`.
Captures: `dist/archive-navigation-review/`.
Failed runner logs and disposable fixtures remain retained separately; none are
counted as passes.

## Review build

- App: `dist/louppe-2026.10.29.app`
- ZIP: `dist/louppe-2026.10.29.zip`
- Bundle: `com.alexandermarkin.louppe.review2`; **1.13.0 (15)**.
- Automatic update checks/downloads are disabled. The installed
  `/Applications/Louppe.app` was not replaced.
- ZIP SHA-256: `8656b65ceeaf442279f6d320e3e2a20cd4b89e4436b5ad72d6904ec7ff4f5fb2`.
- Disposable launch fixture: `dist/archive-navigation-fixture/`.
- Package log: `/tmp/louppe-archive-nav-package.log`.

## Remaining acceptance

- No external archive/SD/ExFAT volume is connected on this run. Verify real
  archive navigation, remount/replacement and revoked sandbox grants separately.
- Physical trackpad/diagonal/momentum/touch input, actual VoiceOver tasks,
  older macOS and two-display transitions remain open. Foreground-only existing
  tests were intentionally excluded while Alex works.
- Hidden screenshots omit composited glass and cannot establish physical frame
  pacing. Existing RAW stress reliability work remains a separate open backlog.
- The separate review build is local/ad-hoc, with updates disabled; it is not a
  signed/notarized public release or Store submission.

## 30 October review and UI correction

Claude Opus 5.5 reviewed the integrated uncommitted branch read-only at Alex's
request. It found no file-operation/persistence safety defect, but withheld
release approval for incomplete final checks, unwanted flat-folder controls and
an unsettled dropdown. Its observations are code review, not physical acceptance.

Applied corrections:

- Shared minimum header space aligns sidebar/breadcrumb dividers in Gallery,
  Grid and empty states. Warnings sit below the header. The Folders/Browser
  selector is a leading-aligned native borderless value menu, matching Info's
  color-label control; breadcrumb labels share callout sizing. New menus use
  `.menuStyle(.button)` and `.buttonStyle(.borderless)`, as the current SDK
  migration guidance recommends. The SDK marks the older styles with a future
  deprecation version, rather than a current deployment-target warning.
- A real hierarchy (more than the root node) enables folder controls. Flat
  shoots retain their original Browser/Grid layout, even if the last archive
  used Folders. Archive indexes remain available for identity and memory.
- Progress, mixed counts, completion, toolbar/menu/palette Clear availability
  and scoped Clear help follow the current folder, before metadata filtering.
  Scope counts build once per scope/structural change, then update only changed
  indexed items. RAW+JPEG physical IDs deduplicate through the existing map.
- Corrupt browsing memory offers an explicit Reset Folder Navigation action.
  This deliberately preserves the existing refusal to overwrite invalid bytes
  automatically. Reset moves primary and previous leaves intact into a unique
  sibling recovery directory, then permits fresh UI memory. Oversized files and
  leaf symlinks are preserved without reading/changing symlink targets. Decisions
  and source media are outside this reset. Failed moves remain visible/retryable.
- Ordinary current/viewport input only schedules the coalesced memory capture;
  it no longer rebuilds bounded memory per callback. Folder transitions and
  flush still capture before changing authority. Outline presentation gates and
  pending-filter flushing match folder selection.

The interrupted header-check log has no completed-run result and is not counted
as a pass. The first review-fix run completed 139 cases with one visual-fixture
failure: FileManager copying the tracked workspace WEBP threw an external
`InvalidTransition (idle → failed(deinit))`. No app assertion was weakened.
The flat capture now generates PNG media in temporary storage, as the archive
capture already did; both visual cases then passed. All 138 other cases passed,
including complete Hotkey/BrowserScroll/GridScroll/PersistentVerticalScroller
and localization gates. A subsequent 13-case scope/palette run passed, including
mixed cross-folder pair counts, Clear enablement and Undo. Final capture output:
`dist/archive-navigation-review-v3/` (16 native content-area images).

### Product direction from the review

Retain one opened folder, one culling session and one decision sidecar. Folders
narrows that session; Grid is already the thumbnail browser, while Gallery can
choose Browser or Folders. Scope should govern every progress/action number.
Keep simple flat shoots free of archive controls.

After this scope ships, evaluate quiet folder completion, Next/Previous Folder
commands, then Show in Finder. These are recommendations, not added release scope.
Before any nested-session import, decide how to handle a subfolder previously
opened independently: today's parent session reads only its own sidecar and does
not merge child sidecars. Keep on-demand rescanning until live watching has a
measured need. Folder management, drag-to-move, albums/smart folders and parallel
nested save authorities remain outside this navigation design.

Final follow-up gates: **142 cases, zero failures** in 87.4 seconds, including
all archive suites, mixed-pair scope/Undo, native captures, review guidance and
preferences, palette, localization, Hotkey, BrowserScroll, GridScroll and
PersistentVerticalScroller. The foreground localization fixture is excluded as
before. Standalone safety passed **75/75**. A Swift 6 warnings-as-errors build
passed (SwiftPM itself notes the explicitly overridden language mode).
Logs: `/tmp/louppe-archive-review-final-gates.log`,
`/tmp/louppe-archive-review-safety-final.log`,
`/tmp/louppe-archive-review-strict-final.log`. Earlier failed/incomplete attempts
remain separate and are not reported as passes.

### Updated separate review build

- App: `dist/louppe-2026.10.30.app`; ZIP: `dist/louppe-2026.10.30.zip`.
- Version remains **1.13.0 (15)**; update checks/downloads remain off.
- Identity: `com.alexandermarkin.louppe.review.archivefolders`. The standard
  review packager first created review2, then a local staging copy received this
  distinct identity and was ad-hoc re-signed/repackaged. Alex's older review copy
  has a personal folder open, so neither it nor the stable installed app was
  closed, replaced or navigated. The dated build can run beside that copy.
- ZIP SHA-256: `dea6ce120e576c2b3268cfe4153d18588b04c1ab064ef7c4e37a71f598019223`.
- Loose and independently extracted ZIP signatures passed; complete `Contents/`
  trees match. Logs: `/tmp/louppe-archive-review-package-final.log` and
  `/tmp/louppe-archive-review-isolated-package.log`.
- Launched the exact new dated app with `open -n -g -j` and
  `LOUPPE_BACKGROUND_LAUNCH=1`, using 12 disposable WEBPs under
  `/private/tmp/Louppe-archive-launch-306kw_tc/Photo archive`.
  App-bound AX confirmed Gallery/Grid, **0/12 reviewed, Saved**, native menu-button
  Navigation, first-click Folders, correct 12/4/8/0 tree counts and native Expand
  revealing Autumn/Summer (4 each). All 12 originals retain exact bytes; only the
  root decision sidecar exists. The new app remains hidden on this test fixture.
  No Raise, activation or global mouse/keyboard action was used. Physical row
  selection and composited foreground appearance remain open as before.

## 30 October breadcrumb simplification

Alex removed the duplicate media header from the design. Breadcrumbs now appear
only inside a selected subfolder when the native folder tree is hidden or the
leading pane shows Browser. All Media has no breadcrumb in any layout. With
Folders visible, Gallery/Grid reclaim the entire former header row; no spacer
replaces it. Navigation persistence warnings retain their independent row.

The change is one presentation condition in SessionView. Native captures cover
root/subfolder with Folders, hidden tree in Gallery/Grid, Browser, empty states,
light/dark, RTL and narrow/wide layouts with Info. All **54** affected capture,
Hotkey, BrowserScroll, GridScroll and PersistentVerticalScroller cases passed
in 78.8 seconds. Capture output: `dist/archive-navigation-review-v4/` (19 images).
Log: `/tmp/louppe-breadcrumb-final-checks.log`. No decision, scanner, scope or
persistence code changed, so prior safety evidence remains applicable.

Updated the same dated review identity/version and replaced the prior copy via
Trash after its native Quit/save barrier. The workspace loose app repeatedly
acquired Finder metadata immediately after xattr cleanup, so its strict signature
check failed twice; no failed check is counted as passing. Installed the verified
stage outside File Provider at **`/Applications/louppe-2026.10.30.app`**, retaining
`com.alexandermarkin.louppe.review.archivefolders` and updates disabled. Its strict
deep signature and complete Contents comparison with the independently extracted
ZIP passed. The Documents app and generic build products moved to Trash, leaving
one current app. The updated ZIP remains `dist/louppe-2026.10.30.zip`, SHA-256
`3004ac2627a25ee922f69c76c6f95af44d9c4e46eefe8661d2fd029da5e1707a`.

Background launch returned to the same disposable archive. App-bound actions
restored Grid/Folders; AX confirms the selected All Media row, 0/12 reviewed,
Saved, and **no separate text All Media header**. All 12 originals match their
recorded hashes. No Raise/activation/global input was used. Logs:
`/tmp/louppe-breadcrumb-build.log`, `/tmp/louppe-breadcrumb-package.log`,
`/tmp/louppe-breadcrumb-replace.log` (failed workspace verification), and
`/tmp/louppe-breadcrumb-install.log` (successful installed verification).

## 30 October night: folder view moved forward

Alex asked to move the draft toward a deliverable folder view: Obsidian-style
Expand/Collapse All, a one-click Browser/Folders switch, shortcut integration,
edge cases and visual checks. Two Codex (gpt-6.1-sol, xhigh) agents worked in
parallel: a read-only edge-case audit and a shortcut patch built in a private
copy. A third reviewed the integrated result.

### Added

- **One-click switch.** A native two-segment picker (Browser / Folders icons)
  replaces the value menu. In Grid, Browser returns to Gallery. The choice is
  remembered per Mac (`archive.leadingPane`); flat folders still show Browser.
- **Expand All / Collapse All.** One toggle, as in Obsidian: Collapse All while
  any folder is visibly open, otherwise Expand All (`chevron.up.chevron.down`;
  SF Symbols has no inward pair, so collapse composes two native chevrons).
  Collapse All keeps the current folder's path open and never changes scope.
  Also in View and the Command Palette.
- **Shortcuts.** T shows/hides Folders (Gallery and Grid); Q switches Folders
  to Browser in one press; `[` / `]` previous/next folder with direct media;
  ⌘↑ enclosing folder. View menu: sidebar picker, Show/Hide Sidebar, Expand/
  Collapse All, Enclosing/Previous/Next/Next Unfinished Folder, Show Current
  Item’s Folder, All Media. The palette lists these plus each folder path
  (≤ 2,000 folders). New default keys yield to existing custom bindings.
- **Completion checkmarks.** A quiet checkmark beside a folder's count when every
  item has Yes or No (mixed pairs still need a decision). Pair-aware counts are
  built once per index generation and updated per changed decision in
  O(folder depth); only visible rows refresh.
- **Show in Finder** in the row context menu (read-only). Empty folders dim.
- **Resizable pane.** Drag the Folders edge (180–420 pt, remembered); double-
  click restores 220 pt. Long and deep names no longer need to truncate.
- **Click focus.** The tree declines keyboard focus for pointer clicks (Finder
  sidebar behavior), so arrows and Space keep moving through media after
  choosing a folder. Tab/Full Keyboard Access and VoiceOver can still focus it.
  Type-select is off so unassigned letters cannot jump folders.

### Audit findings fixed

- Live expansion was truncated to an arbitrary 512-folder subset, collapsing
  visible rows (10k test: 20,005 rows → 1). Live state is now unbounded; only
  persisted memory keeps 512, shallowest first.
- Recursive disclosure published once per folder (10k: 10,001 publications,
  12.9 s). Native recursive calls now report one final set; bulk store changes
  use one recursive native call (10k: expand ≈ 0.6 s, collapse ≈ 0.25 s,
  unoptimized hidden-window test; unchanged updates ≈ 0.1 ms).
- Recursive collapse changed scope level by level; it now moves selection once
  to the nearest visible ancestor (native outline rule).
- A remembered folder late in the tree mounted off-screen; first mount reveals it.
- Depth 20 produced negative cell widths and Auto Layout conflicts; trailing pins
  now yield, and the pane can widen.
- An empty folder with active filters showed “No items match the filter”; the
  folder-empty state now wins when the folder scope itself is empty.

### Found in the live review build

Driving the packaged review build through Accessibility on a disposable
92-photo archive found two defects that hidden-window tests missed:

- A folder-row click left the tree focused, so ↓ stayed in the tree. The
  post-click hand-back ran too early in AppKit's real event flow; refusing
  pointer-initiated focus fixed it (re-verified live: ↓/→/Space/F act on media).
- Entering a never-visited folder landed on its *last* item (filter snap), so
  ↓/→/Space did nothing. Entry now keeps a current item that belongs to the
  folder, otherwise starts at the first undecided item, as opening does.
- Dragging the pane edge did nothing: a SwiftUI gesture overlay cannot receive
  clicks above the native outline. An AppKit splitter view above the whole row
  now owns the drag, the system column-resize cursor, double-click reset and
  VoiceOver increment/decrement (“Folders width”).

Live results on the final build (each step read back through Accessibility):
one-press Browser/Folders switch; Expand All (17 rows) and Collapse All keeping
the current path (8–9 rows, scope unchanged); Option-click expanding one branch
(9 → 13 rows); `]`, `[`, ⌘↑, T, Q in Gallery and Grid; Browser from Grid
returning to Gallery; a real row click keeping focus on the window so ↓/→/Space/F
act on media; a fresh folder starting at “Item 1 of 12”; ⌘K “Northwind” → Go to
Folder; Next Unfinished Folder from the View menu; pane drag 220 → 330 pt,
remembered, and back; relaunch restoring Folders, the folder and item; the
completion checkmark after culling a folder with F. All 92 disposable originals
kept their SHA-1 hashes; only the root `.louppe_session.json` was added.

### Review and verification

A third Codex reviewer found no blocker or major defect and no decision path
that bypasses completion counts, preference leak or new original-file
authority. Its two minor performance findings were fixed: progress walks one
ancestor chain without a visited list for single-folder items (200-level test
well under 1 s, previously 2.48 s), and next/previous/unfinished targets are
cached per index, selection and progress revision (100 enablement passes over
20,000 folders < 50 ms, previously 637 ms).

Three keyboard/settings tests assumed T was unassigned; they now use Y.
The standalone safety runner compiles the two new sources.

Final verification on the finished code, with the screen free so foreground
cases ran: full suite **1,198 cases, 51 opt-in skips, zero failures**; safety
runner **75/75** (including real Trash/restore); video/audio checks passed;
strict Swift 6 warnings-as-errors build passed; **2,426** literal localization
callsites covered in six catalogs. Logs: `/tmp/louppe-night-full-suite-3.log`,
`/tmp/louppe-night-safety-3.log`, `/tmp/louppe-night-video-3.log`,
`/tmp/louppe-night-strict-3.log`, `/tmp/louppe-night-l10n.log`. An earlier full
run's 12 failures (the T-key test assumption) and the safety runner's missing
source are recorded there as fixed, not counted as passes.

### Review build

`/Applications/louppe-2026.10.30.app`, identity
`com.alexandermarkin.louppe.review.archivefolders`, 1.13.0 (15), updates off;
the previous copy is in the Trash. The stable app was not touched. It is left
open on the disposable archive `/private/tmp/louppe-live-archive-050130/`.
Screen recording is not granted to the agent session, so composited
appearance was checked with hidden-window captures
(`dist/archive-navigation-review-v5/`), not screenshots of the running app.

Superseded on 30 October at 14:20: at Alex's request this working tree was
installed as the official `/Applications/Louppe.app` and the dated review copy
went to the Trash. See the consolidation entry in `Docs/REVIEW_BUILD.md`.
Archive-opening performance work and instant pinned opening were subsequently
completed and checked on the connected exFAT archive, including remounts. See
[the final installed-build verification](REVIEW_BUILD.md#latest-recorded-review).

### Still open

Physical trackpad/touch, VoiceOver task walkthroughs, older macOS, live Store
sandbox behavior and composited (glass) appearance remain unverified, as in the
backlog.
