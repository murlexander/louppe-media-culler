# Photos album organization — 25 October 2026

Additive native Photos organization follows Alex’s confirmed preference: add to
an album while keeping existing memberships. Photos folders contain albums.

## Acceptance and scope

- File → Add to Album… opens a native grouped sheet with current/selected,
  filtered or all reviewed items, an existing album or a new album inside an
  existing folder/top level, and separate scope/count/destination confirmation.
- Opaque Photos collection and asset IDs are authoritative. Actual parent
  hierarchies and duplicate-path ID suffixes disambiguate destinations. Titles
  never recover or redirect a missing destination.
- Metadata-only PhotoKit transactions admit at most 200 assets serially. The
  first nonempty transaction creates, places and populates a new album atomically.
  No originals, images, filenames or cloud downloads are requested for this work.
- Additions preserve other memberships and originals. Local Yes/No, stars,
  colors, source membership, selection, grouping and review Undo stay local.
  Removal/moving out of a source album, Favorites/hidden/title changes and
  deleting assets/albums/folders are outside this command.
- SessionStore captures immutable scope and source/snapshot/media identity,
  saves decisions first, and holds shared operation/Quit/sleep authority through
  each noncancellable callback and fresh verification. Cancel stops between
  transactions; prior additions remain. Progress publications are coalesced.
- Results distinguish verified memberships (including existing ones), missing,
  unverified/uncertain and unprocessed items, and unverified destination placement.
  Callback acknowledgment alone cannot produce success. Verification observes
  each batch at that time; later external edits are possible. There is no durable
  crash receipt or automatic replay of uncertain creation, title-based retry,
  fake rollback, or organization Undo.
- Choose Photos… and Photos source/preview context now live in Filter. The
  redundant main-view source bar is removed. The popover dismissal hands off
  once to the chooser; Add to Album remains in File.
- Both iCloud permissions remain independently persistent in General Settings.
  This feature does not change them.

## Architecture and review

`PhotosLibraryOrganization.swift` owns injectable PhotoKit metadata transactions,
exact-ID capability checks, bounded work, cancellation and verification. Pure
presentation DTOs and the bounded progress recorder live in
`PhotosOrganizationPresentation.swift`; `PhotosOrganizationView.swift` renders
cached destination options. SessionStore remains the integration/save authority.

Independent source review round 1 found repeated hierarchy/path preparation on
the main actor. The fix prepares choices once in a cancellable detached worker,
with iterative ancestry memoization and cached arrays/ID lookups. Collection
count is bounded at 50,000; display-path storage at 8 MiB. Invalid ancestry,
cycles and duplicate IDs refuse the hierarchy visibly; reload is explicit.
Native Picker rendering at extreme collection counts is a separate runtime gap.

Task artifacts, exact agent handoffs, logs and review reports:
`/private/tmp/louppe-photos-organization-20261025`.
Parent owns integration, measurements, packaging, installation and native checks.

## Reproduction

From `/Users/alexander_markin/Documents/code/louppe/app`, full Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-keychain --build-system native -c release -Xswiftc -DDEBUG \
  --filter 'PhotosLibraryOrganizationTests|PhotosOrganizationSessionTests|PhotosOrganizationChoicesTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-keychain --build-system native -c release -Xswiftc -DDEBUG
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Tests/run_performance_checks.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Tests/run_resource_bundle_checks.sh
python3 Scripts/check_localization_sources.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh
```

Before installation, run complete Hotkey, BrowserScroll, GridScroll and
PersistentVerticalScroller suites; full-suite execution includes these gates.
Packaging must verify the loose and independently extracted archived app and
compare the complete Contents trees. Keep a reversible installed-app backup.

## Validation status

Initial backend: 24 injected metadata-only tests passed, no real-library writes.
Integrated compilation required updating removed-header visual fixtures. An
initial selection test expected toggle-selection to omit the current item;
corrected expectations retain the documented current-plus-selected behavior.
Neither issue was hidden or converted to a skip. A subsequent validation
runner inherited the Command Line Tools SDKROOT despite selecting Xcode’s
compiler; that compile failed to locate SwiftUI macros. The runner now sets
both DEVELOPER_DIR and SDKROOT from full Xcode. Wrong-SDK logs remain in the
task artifacts; no older SDK or source workaround was used.

Independent rereview resolved M1 with no new substantive source findings.
All 36 new tests passed in the first full execution: 24 backend, nine session,
and three destination-preparation tests. Synthetic 50,000-album preparation took
116 ms off-main in that run; this is model preparation, not native Picker frame
pacing. The initial full suite found only seven assertions in one localization
test (new punctuation/ID labels). Reused the existing translated label/value
format and translated the ID suffix; localization assertions remain unchanged.

Final full-Xcode execution: **1,096 cases, 48 skips, zero failures**, 147.3 s
runtime (309.4 s including rebuild). All 36 new organization tests passed.
Required pre-install gates: Hotkey 41, BrowserScroll 3, GridScroll 4,
PersistentVerticalScroller 3; all passed. Localization 22 tests and 2,322 literal
source callsites passed; all six catalogs lint clean. Safety/performance harness
**75/75**, 43.0 s including compile. Resource-bundle checks passed. Existing
opt-in hardware/large-fixture/visual-capture skips are not passes; exact skip
messages remain in `full-suite-final.log`.

Exact candidate, installation and native results are appended after execution.
Earlier SSD/80,708
Photos measurements remain in SSD_PHOTOS_2026-10-25.md; they are historical
observations, not fresh benchmarks for this follow-up.

## Installed candidate and native checks

Installed at `/Applications/Louppe.app`: **1.13.0 (15)**, direct local ad-hoc
signature, running PID 91343 when verified. Local follow-ups retain the existing
unreleased version/build per repository rules; latest published is 1.12.0.

- Candidate: `/private/tmp/louppe-photos-organization-20261025/candidate/Louppe.app`
  and `Louppe.zip` in the same directory.
- Executable SHA-256:
  `703eb73b12d5b56bf89bec01db78d07c9c578a4393ece1e5669a8cc38ad3d482`.
- ZIP SHA-256:
  `7d876e5e4546ab9d47621fb25ba1efe4b47815251641d88923df461af84b226a`.
- Packaging release preflight passed. Finder metadata reappeared during the
  loose-app copy; the required `xattr -cr` cleanup restored strict verification
  without re-signing or changing bundle contents. Candidate, independent ZIP
  extraction and installed app all pass strict deep signature checks and match
  all **178 Contents paths/types/bytes/modes/symlink targets**.
- Rollback: `/private/tmp/louppe-photos-organization-20261025/rollback/Louppe.app`,
  executable `f04f13e95594ba2634153fc064366b779abdc180cdb9bab85150eb025173826e`.
  Previous app reached Saved, quit normally and exited before replacement.
- All 652 source/test/build manifest entries still match the validated revision.
  No commit, push, publication, website or original media change occurred.

Native verification on the exact installed candidate:

- Welcome showed the actual archive pin `/Volumes/WORK_FAST_A/2023-2026 archive`
  as Available after relaunch, with its existing Actions menu.
- The first chooser waited in macOS Photos authorization. A bounded process
  sample showed an idle main thread and PhotoKit's access-callback queue waiting
  inside PLPrivacy. No OS permission prompt was visible to app-bound control;
  CoreServicesUIAgent inspection timed out once. Authorization subsequently
  returned without source changes. No permission reset, bypass or daemon kill.
- Opened all **80,708** Photos items. Gallery showed actual matching preview
  pixels for Photo 1 at 2,046 × 1,436, explicitly labeled non-original; Saved,
  zero reviewed decisions, no original-detail/Copy request.
- The old Photos bar is absent. Filter's source/count/Choose Photos/status row
  fits its native popover. Choose Photos dismissed the popover, opened the real
  chooser once, and Cancel retained current item/count/Saved state.
- File → Add to Album opened the real hierarchy. Duplicate complete album paths
  showed opaque-ID suffixes, and nested album paths reflected their real folder.
  New Album enabled name/parent selection; the current-item scope showed one.
- Prepared, but initially did not submit, the exact confirmation for Photo 1 →
  `Photos Library › arts › Louppe Test — 25 Oct 2026`. This is an optional live
  write test requiring Alex's approval because it adds a real-library album.

Remaining runtime gaps: real permission revocation while a PhotoKit transaction
is pending, process death during a live write, multi-batch real-library writes,
extreme native Picker counts, RTL/VoiceOver and macOS 14 execution. Their mock
contracts/source checks do not substitute for those runtime checks. Historical
SSD/RAW/physical-input limitations remain in the earlier acceptance records.

Fresh installed opening observation, after the authorization/chooser wait:
80,708 memberships prepared in 3,348 ms (decisions 271 ms, membership 1,596 ms,
model construction 1,479 ms); worker/publication 683 ms, including 327 ms main
publication. Combined model readiness was about **4.03 s**. This excludes chooser
and OS authorization time and does not measure first compositor pixels. Caches
and host conditions were not controlled; do not claim a causal performance gain
from this sample or compare it as a matched benchmark against earlier visits.

## Short follow-up sequence

1. In the running Photos review, open Filter → Choose Photos…, then Cancel.
   Confirm Photo 1 and 80,708 items remain, with no extra source bar.
2. File → Add to Album…: select Current item / Selected / Filtered and an
   existing album, or New album with a parent folder. Review exact count/path.
   Cancel is a read-only check; Add changes real Photos memberships explicitly.
3. Switch Gallery/Grid, scroll/reverse and jump, then return to Gallery. Source
   originals and local ratings remain intact. Welcome's archive pin points to
   `/Volumes/WORK_FAST_A/2023-2026 archive`; local disposable JPEG fixture remains
   `/private/tmp/louppe-overnight-20261025/morning/jpeg-10000`.

Pre-approval checkpoint: the optional real-library write was left unsubmitted
and its confirmation dismissed. No test album or membership change existed at
that checkpoint. Native write acceptance was pending; the approved test below
supersedes that gap.

The installed Grid mounted the 80,708-item review and jumped to the final items;
actual visible thumbnails reached Photo 80,708. Scroll/reversal and directional
horizontal calls retained vertical-only geometry with Info visible. No physical
diagonal-trackpad/frame-rate claim is made. Returning the Grid scrollbar to zero
hit two native-control stale-element errors despite refreshed AX IDs; recorded
as an automation limitation. The native Tab view shortcut returned to Gallery,
Photo 1/current selection stayed stable, and Browser down/up reversal returned
to its original top with Saved and zero reviewed decisions. Left that clean
Gallery review running; no modal/test confirmation remains open.


## Approved live write — completed

Alex approved the exact one-photo test in chat after the pre-approval checkpoint.
The same installed candidate/PID 91343, executable SHA-256 `703eb73b12d5`,
remained in Gallery on Photo 1 (the cow painting), with 80,708 items and Saved.

- Fresh preflight destination inventory contained no test album. Submitted once:
  Current item, **1**, new album **Louppe Test — 25 Oct 2026**, parent **arts**.
- Native result: **Album Addition Complete**; requested 1, verified in album 1,
  already present 0, unavailable 0, uncertain 0, unprocessed 0. Completion requires
  the actual PhotoKit callback plus fresh asset membership and folder-placement
  verification; this is now a live write pass, not just injected coverage.
- Separate normal Choose Photos query listed the new album and returned exactly
  **1 item**. A fresh organization hierarchy independently displayed
  `Photos Library › arts › Louppe Test — 25 Oct 2026`. No second write/retry.
- Restored the chooser to All Photos and Videos (80,708), cancelled the chooser
  and the read-only hierarchy inspection. Left Gallery/current Photo 1, Saved,
  zero reviewed decisions, with no modal open. No original-detail/Copy request,
  removals, deletion, rating or existing album-membership edit was made.
- The approved test album remains inside arts for Alex to inspect. It was not
  deleted as cleanup. No source code, candidate or installed bundle changed.

Remaining live gaps are multi-batch writes/cancellation, permission revocation
during a transaction, process death, extreme Picker counts and older-system/
accessibility execution. One successful native transaction does not cover them.
