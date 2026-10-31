# Local review builds

The current local installation is the single `/Applications/Louppe.app`, a local
ad-hoc 1.13.0 (15) build installed on 30 October at Alex's request. It uses
the official identifier
`com.alexandermarkin.louppe`. Future local installs replace that copy; do not
install a second review app unless requested. The separate packaging workflow
below remains available for an explicitly requested isolated review artifact.

Build a separate review copy with full Xcode and the current SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_review.sh
open "dist/louppe - to review.app" --args -openFolder /path/to/disposable/photos
```

The script creates `dist/louppe - to review.app` and its ZIP, using the version
in `VERSION`. Its identifier is `com.alexandermarkin.louppe.review2`; preferences,
recents, and window state are separate from the stable app. Automatic updates
are disabled, and the review copy does not advertise a duplicate Finder service.
Verification checks a clean local-volume copy of the exact loose output and an
independently unpacked archive, comparing their complete Contents trees. This
avoids File Provider reattaching Finder metadata during signature verification.

Both apps use `.louppe_session.json`. Opening the same folder shares decisions;
use disposable copies of media. 1.11 saves format 7, which 1.10 cannot read.
Keep saved-session copies before evaluating a downgrade.

Run the affected tests and the checks in [AGENTS.md](../AGENTS.md). Record the
source revision, build identity, fixtures, results, explicit skips, and native
acceptance limits. Always launch with `-openFolder`.

## Latest recorded review

30 October instant-opening follow-up: the official 1.13.0 (15) app now
shows cached pinned photos before discovery, using the same toolbar spinner as
review work. Built from the uncommitted `archive-folder-navigation` working tree
based on `965163b`; no commit or push. Full debug XCTest: 1,282 cases, 56 explicit
opt-in skips, zero failures, including all keyboard/scroll gates and six new
instant-opening contracts. An additional opt-in real-drive worker check passed.
Performance/safety checks: 75/75. Release packaging/preflight and strict deep
installed signature pass; all 178 Contents entries, symlinks and file hashes
match the packaged output. Installed executable SHA-256:
`20ecb66d9b75faee98c4f4cb150f5bca46ecac7444e6640d6613b92e315cb731`.

A background `-openFolder` launch opened a disposable text document. Native pin
opens exposed cached browsing in 0.96–0.98 s (including pin resolution and native
view mounting). Accessibility confirmed Checking folder and an `AXBusyIndicator`
inside `AXToolbar`; Ready restored item 16,328 of 16,967, Saved. No foreground
activation or global input was used. Window image capture failed, so visual
pixel inspection remains unavailable. An optional release-mode XCTest attempt
could not compile existing tests that depend on DEBUG-only helpers; the release
application itself builds and launches successfully. The sandboxed Store build
was not tested live.

The existing archive snapshot is 984,935 bytes; the pin document is 2,539 bytes.
Shared thumbnail payloads across all folders total 133,504,725 bytes, occupying
163,504,128 bytes on disk at measurement. Instant opening adds no separate cache
or original copies. The previous installed app was preserved in the Trash.

30 October opening-speed install: replaced the official app with the same
working tree plus fast discovery, compact pinned-safe metadata cache, drive-ID
cache keys, fewer identity passes and pinned-folder preparation (see
PERFORMANCE.md). Two independent GPT-6.1 Sol reviews found nine defects; all were
fixed with regression tests. Final suite: 1,275 cases, 55 opt-in skips, zero
failures, including Hotkey 42, BrowserScroll 3, GridScroll 4 and
PersistentVerticalScroller 3; safety 75/75; video checks passed. Release
preflight passed; strict deep signature passes; all 110 Contents entries match
`dist/`. Executable SHA-256
`c3eafca0ecd77bc29e5f99dd26dfac354e343b0db3c2d695ccca9076f7a73cfe`. The previous
app is in the Trash. On Alex's exFAT (FSKit) archive, 16,967 items, the
`Opening ready` log showed:

| Open | Before | After |
| --- | ---: | ---: |
| Warm, `-openFolder` | 12.9 s (21.4 s first) | 1.7–2.0 s |
| First open (v1→v2 cache, no EXIF reads) | — | 2.3 s |
| Cold, after `diskutil` remount | 43.2 s with a rebuilt cache (earlier today) | 2.6 s |
| Pin click after remount and automatic preparation | — | 1.6 s |

Preparation after the remount took 2.7 s, unchanged, with no writes. The
folder's inode survived the remount. The session restored its remembered item.

30 October consolidation: built the uncommitted archive-folder working tree on
`archive-folder-navigation` (base `965163b`, unchanged since the 05:34 full suite)
with `build_app.sh` and installed it as the official app. Release preflight passed.
The pre-install gates passed with zero failures: Hotkey 42, BrowserScroll 3,
GridScroll 4 and PersistentVerticalScroller 3 (`/tmp/louppe-consolidate-gates.log`).
Executable SHA-256 `85e1296f7c1437b62546032b3883f0788b514e674b2c39ee4b3268a47418a66c`.
The installed copy passes strict deep signature checks. All 110 Contents entries
match `dist/` by bytes, modes and symlink targets. The dated review app
(`com.alexandermarkin.louppe.review.archivefolders`) moved to the Trash.
Its folder-pane choice/width and `ArchiveNavigation.json` were copied into the
official domain through exact-path `defaults` writes. Official shortcuts, grants
and settings were kept. Pre-merge copies are in
`~/Documents/tmp/louppe-consolidation-20261030/`. Security-scoped bookmarks follow the
identity that created them. The review build's recents therefore stayed out,
and the pinned archive needs one Locate in the official app. The Accessibility
tree confirmed one running instance at Welcome.

21 October release: replaced the single official app with the notarized public
archive (SHA-256 `2cd47cf21aaceeb0919b306a9b14093cb9f1ab1283dc932cc29d57eb3396c99e`).
Complete Contents, strict signatures, Gatekeeper and stapling pass. All 41 hotkey
and complete Browser/Grid/scroll bridge gates passed before installation. Native
launch shows Welcome with retained recents; final media/physical scroll inspection
was unavailable because native capture failed. The same source's sandbox media,
rename/Undo and persistence acceptance passed earlier. See the
[release record](RELEASE_1.12_PREPARATION_2026-10-21.md) for CI, public update,
Store submission and explicit limits. Preferences/grants were not reset.

20 October consolidation: installed the verified 1.12 official-identity archive
at `/Applications/Louppe.app` and moved both previous installed copies outside
Applications to `/private/tmp/Louppe-unified-am51990j/previous-apps/`. Preferences
from both domains were backed up in the parent directory; review settings/hotkeys/window frames
were merged into the official domain, recent histories combined, and the
official folder grants retained. Archive SHA-256:
`3ae741aaf92006e355c5e12e6edb075f2a42fd5a945aa248afffd92746417b7e`.
The candidate's machine code matches the reviewed app after removing differing
embedded bundle signatures from temporary comparison copies. Loose output,
archive and installed complete Contents trees match and strict deep signatures
pass. All 38 HotkeyTests passed before this install; no source/version change
or publication occurred.

The initial identifier-based defaults import resolved to the registered Store
container instead of the desktop domain. The native launch exposed the missing
shortcut choice. Restored the container's complete pre-install settings, including
removal of the two keys introduced by the merge. Repeated migration using exact
desktop/review preference-file paths, preserving the desktop grants and combining
14 recent records before launch. Corrected snapshots are in
`/private/tmp/Louppe-unified-am51990j/preference-correction/`. Desktop shortcuts
match the review JSON exactly, including the saved keyboard-layout mode. Final
verification confirms one installed app, one running instance and strict signature
success. The final window capture is unavailable due to ScreenCaptureKit errors;
native media launch was verified before the preference correction and the
relaunched process/settings were verified afterward. Do not use identifier-only
`defaults` imports for this dual desktop/Store setup; target exact file domains.

20 October stability/performance review: final suite passes 817 cases, 781 passed,
36 explicit skips and zero failures. Fixed partial Fuji monochrome metadata and
unnecessary/global menu refreshes, including background callback safety. See the
[quality review](QUALITY_REVIEW_1.12_2026-10-20.md) for evidence and limits.

20 October Mac keyboard follow-up: Settings is 620 points wide with a complete
compact Mac keyboard silhouette. Affected checks: 68 passed, two explicit skips,
zero failures; complete HotkeyTests pass and the Store configuration compiles.

20 October 1.12 keyboard follow-up: 814 XCTest cases, 778 passed, 36 explicit skips,
zero failures; complete HotkeyTests and 75 performance/safety checks pass.
Custom review bindings, folder opening, Fuji simulation Info/filtering, a fitted
detail-loading indicator, renaming Help, dynamic menu hint columns and the visual
Settings keyboard are implemented. New shortcut setups use physical positions;
saved modes and bindings are preserved. See the
[1.12 review record](REVIEW_1.12_2026-10-20.md) for local
installation, launch evidence and remaining native/hardware checks.

15 October preparation: 755 XCTest tests executed, 719 passed, 36 explicit
skips, and zero failures; all 35 HotkeyTests and 75 safety checks pass. A freshly
signed direct candidate opened generated disposable media and saved a decision
without changing its bytes. This did not install or replace the review app.
See [current preparation](RELEASE_1.11_PREPARATION_2026-10-15.md) for package
identity, owner acceptance, and the pending notarization approval.

## 14 October review

The 14 October 1.11 review combined the floating zoom control, Grid/Browser
bounds fixes, localization, Quality Cues, recovery, and performance work.
The full suite executed 754 tests: 718 passed, 36 explicit skips, zero failures.
All 35 HotkeyTests and 75 required performance/file-safety checks passed.
These are dated results, not validation of subsequent changes.

- [Release preparation and remaining acceptance](RELEASE_1.11_READINESS_2026-10-14.md)
- [Current open work](../BACKLOG.md)
- [Dated implementation reviews](DEVELOPMENT.md#historical-records)
- [Complete review history](Archive/2026-10-14/REVIEW_BUILD_HISTORY.md)
- [Installed-review manifest](Archive/2026-10-14/performance/cue-filter/installed-review.json)
