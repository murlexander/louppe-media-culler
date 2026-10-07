# Louppe full audit — 29 September 2026

**Status: retired as an active work list — 29 September 2026.** All 17 confirmed
findings were implemented locally; see [implementation and final verification](implementation.md).
App follow-ups are in [the live backlog](../../../BACKLOG.md#audit-follow-ups).
Website consent was unpublished at closeout; it is now published. Remaining
WEB-AUD-01 acceptance is in the [website backlog](../../../../website/BACKLOG.md#browser-acceptance).
The reports preserve pre-fix behavior and 29 September verification.

### Follow-up transfer coverage

| Original follow-up | Active backlog owner |
| --- | --- |
| Session size, lazy JPEG identity, sandbox recents/routing, final scan cancellation | AUD-01–AUD-04 |
| ExFAT path fallback and actual-volume/interruption verification | AUD-05, AUD-18 |
| Main-actor index/sort/save capture, burst evidence/grouping, structural-map reuse | AUD-06–AUD-08 |
| Live thumbnail pruning, abandoned Info reads, RAW fit-source requests | AUD-09–AUD-11 |
| Lazy route rows, duplicate flushes, export preflight, within-file progress/cancel | AUD-12–AUD-15 |
| Compact JSON and byte-budgeted bulk undo | AUD-16, AUD-17 |
| Real RAW/color/GPU corpus and dependency/advisory coverage | AUD-19, AUD-20 |
| Deprecated AV APIs and semaphore-based probing | AUD-21 |
| Capture-date provenance | AUD-22 |
| VoiceOver/keyboard/display/provider/drive acceptance | AUD-23, AUD-24 |
| Website consent publication and real-tab smoke check | WEB-AUD-01 (website) |

M1 regressions cover source replacement. Use current code and backlog acceptance
checks for further work; historical line numbers are review records.

## Result

The audit found **17 actionable issues: four P1, twelve P2, and one P3**, including one measured performance defect. Fifteen used production code, compiled modules, or the website script. Numeric filtering used exact extracted private methods. Playback accessibility was source-proven and still needs native VoiceOver acceptance.

The P1 issues cross Clean Up scope, treat failed durability as safe for Quit, loop indefinitely during export planning, or publish old XMP metadata beside replacement media/folders. No experiment demonstrated permanent original loss. Save durability returned unsafe success under injected I/O failure; power-cut loss was not tested.

Existing checks passed after isolating SwiftPM products from File Provider metadata, but missed these conditions. Each finding records its trigger, effect, correction, evidence, and regression coverage.

## Scope and provenance

- App: `/Users/alexander_markin/Documents/code/louppe/app`, base HEAD `8f8731ffb161212f0ec11dc9081e27435d7f0468`, working version **1.10.0 (12)**.
- Website: `/Users/alexander_markin/Documents/code/louppe/website`, with read-only checks of [the published website](https://louppe.eu/).
- Three subagents reviewed file mutation/recovery, session state/persistence, and media/native UI. The coordinator reviewed XMP publication/bridge/resolution, website behavior/generation/consent, release packaging, build configurations, and cross-cutting validation.
- Reviewed the shared and repository AGENTS instructions and matching engineering references. The app had substantial existing uncommitted work. Another authorized chat completed home-screen/window changes and an installation during this audit; the final complete test run includes those source files.
- A final SHA-256 manifest covers 123 app/test/build/version files, including all 74 application Swift files. These hashes remained unchanged during the final full-suite verification.
- This audit adds documentation and reproduction evidence only. It does not fix application code, modify original media, change version history, create a branch, commit, or push. Disposable files, bounded subprocesses, native-media probes, and build products used `/private/tmp/louppe-audit-2026-09-29`.

P1 covers safety, metadata trust, or bounded completion; P2 covers functional, recovery, accessibility, or performance defects; P3 covers diagnostics. The malformed-journal FIFO defect has lower ordinary-user exposure than the other P2 findings.

## Prioritized findings

| ID | Priority | Finding and concrete effect | Evidence/detail |
| --- | --- | --- | --- |
| S1 | P1 | Separate RAW/JPEG Clean Up includes the hidden or unselected companion when only its other member is in scope | Actual target snapshots/counts; [session audit](session-state.md) |
| S2 | P1 | Failed post-rename directory sync plus unavailable backup returns a discard-safe save | Existing fault boundary + blocked backup; [session audit](session-state.md) |
| FS-1 | P1 | Same-stem case-variant extension names in an XMP family make shared-suffix export planning loop forever | Actual resolver/planner, bounded subprocess; [file audit](file-safety.md) |
| X1 | P1 | Standalone XMP publication accepts replacement media or a replacement source folder and publishes old ratings into it | Actual compiled XMP planner/worker; details below |
| S3 | P2 | Filtering a disjoint selection can display B while rating or applying Selected-scope actions to C | Actual store/filter/rating execution; [session audit](session-state.md) |
| M1 | P2 | Live replacement pixels enter memory/disk caches under the old scanned identity | Actual preview/histogram pipelines; [media audit](media-ui.md) |
| FS-2 | P2 | Organization accepts hidden/package folders that its post-operation scanner skips | Actual planner/worker/rescan; [file audit](file-safety.md) |
| FS-3 | P2 | An identity-checkpointed partial generated XMP cannot be removed by Move rollback recovery | Real durable journal states; [file audit](file-safety.md) |
| FS-4 | P2 | A crash during retired-XMP quarantine cleanup strands an otherwise completed Move journal | Real complete Move family + durable quarantine; [file audit](file-safety.md) |
| FS-5 | P2 | A malformed Copy journal with a FIFO source can block recovery forever before type validation | Actual journal, bounded subprocess; [file audit](file-safety.md) |
| M2 | P2 | Transparent image pixels produce false shadow clipping and invalid premultiplied overlay colors | Actual processor, one valid translucent pixel; [media audit](media-ui.md) |
| M3 | P2 | Abandoned audio analysis keeps decoding to EOF and blocks the newly selected recording | Real hour-long WAV, cancellation, next short WAV; [media audit](media-ui.md) |
| U1 | P2 | Merely opening/closing Filter rounds existing precise interior cutoffs | Exact extracted private methods; [media audit](media-ui.md) |
| U2 | P2 | Hover-only video controls are removed during keyboard/accessibility playback | Source trace; native focus behavior pending; [media audit](media-ui.md) |
| W1 | P2 | Analytics withdrawal in one website tab leaves other open tabs collecting | Actual script in two shared-storage browser models; details below |
| FS-PERF-1 | P2 | Repeated export basenames cause quadratic planning: 800 files took 8.725 seconds in Debug | Actual planner, four measured sizes; [file audit](file-safety.md) |
| S4 | P3 | Typed POSIX save errors become generic warnings instead of permission/space/device remedies | Real read-only sidecar write; [session audit](session-state.md) |

## Coordinator findings

### X1 — P1: Standalone XMP publication does not preserve media/folder identity

**Locations:** [XMPPublication.swift:229](/Users/alexander_markin/Documents/code/louppe/app/Sources/Louppe/XMP/XMPPublication.swift:229), plan-entry definition; [XMPPublication.swift:568](/Users/alexander_markin/Documents/code/louppe/app/Sources/Louppe/XMP/XMPPublication.swift:568), preflight; [XMPPublication.swift:738](/Users/alexander_markin/Documents/code/louppe/app/Sources/Louppe/XMP/XMPPublication.swift:738), publication; [XMPMetadataStore.swift:203](/Users/alexander_markin/Documents/code/louppe/app/Sources/Louppe/XMP/XMPMetadataStore.swift:203), final create validation. Session tokens at [SessionStore.swift:4326](/Users/alexander_markin/Documents/code/louppe/app/Sources/Louppe/SessionStore.swift:4326) check in-memory generation/path, not live physical identity.

**Trigger:** Scan and rate `PHOTO.NEF`, prepare Metadata (XMP), then replace the media before confirmation. Alternatively, rename the opened folder aside and create replacement media at its old path while confirmation stays open.

**Cause:** `XMPStemFamilyMember` captures scanned identity, but publication entries retain only sidecar path, metadata, and packet fingerprint. Preflight/publication validate the packet; create checks absence and a directory parent, without original media/folder authority. Session generation cannot detect external filesystem replacement.

**Actual-module evidence:** `xmp-identity-repro.swift` captures real media identity in `PhotoFile`, calls the real planner, replaces the media or folder, proves identity changed, then calls the real publication worker:

```text
scenario=file-replacement mediaIdentityChanged=true created=1 failed=0 conflicts=0 sidecarDecision=yes
scenario=folder-replacement mediaIdentityChanged=true created=1 failed=0 conflicts=0 sidecarDecision=yes
```

Both scenarios write old five-star/red/Yes metadata to `PHOTO.xmp` beside unrelated replacement media; originals are unchanged. Folder replacement also redirects publication outside the opened folder's identity. Packet CAS protects edited sidecars but cannot identify media when the packet is absent.

**Correction:** Carry exact family-member and stable parent/source-folder identities in the immutable plan. Validate before preflight and final atomic publication, including unselected siblings described by the shared packet. Fail as external modification with **Rescan**. Preserve frozen ratings, three-worker bounds, and packet CAS.

**Regression coverage:** Replace a media inode after scan and before preflight; after preflight and before commit; replace a whole source directory; remove one unselected sibling; introduce a symlink/nonregular media leaf; replace a member during a delayed packet write. Assert no packet creation/update in the replacement directory and no false success. Exercise unchanged metadata and intentional rating changes separately.

### W1 — P2: Consent withdrawal does not reach other open website tabs

**Locations:** [analytics-consent.js:14](/Users/alexander_markin/Documents/code/louppe/website/analytics-consent.js:14), saved consent; [analytics-consent.js:66](/Users/alexander_markin/Documents/code/louppe/website/analytics-consent.js:66), withdrawal; [analytics-consent.js:89](/Users/alexander_markin/Documents/code/louppe/website/analytics-consent.js:89), one-time startup read; [analytics-consent.js:99](/Users/alexander_markin/Documents/code/louppe/website/analytics-consent.js:99), download event handler.

**Trigger:** Open two tabs after accepting website analytics. Withdraw from the privacy panel in tab B; keep tab A open and continue interacting with it.

**Cause:** `choose('rejected')` updates shared localStorage, disables the current window, clears cookies, and reloads only that window. Other loaded windows do not listen for storage changes, recheck consent on visibility/focus, or consult shared choice before download events. Their GA disable flag remains false.

**Actual-script evidence:** The VM probe runs the unmodified production consent script in two window/document contexts with shared storage. Both initialize accepted. After B withdraws, A still queues `louppe_download`:

```json
{"savedChoice":"rejected","tabBDisabled":true,"tabADisabled":false,"tabAQueuedDownloadAfterWithdrawal":true,"storageListener":false,"visibilityListener":false}
```

The probe proves local state behavior; it neither intercepts Google traffic nor establishes legal compliance.

**Correction:** Reconcile the shared choice on consent-key storage events, tab return, and custom events. Disable immediately for rejected, expired, or missing consent. Preserve the host gate and opt-in-only loading; reconciliation itself must not request analytics.

**Regression coverage:** Two tabs accepting then one withdrawing; storage removal/expiry while another tab remains active; blocked storage; withdrawal while the Google script is still loading; reacceptance. Assert no new script request before opt-in and no download event after revocation.

## Verification actually performed

| Check | Result |
| --- | --- |
| Complete SwiftPM XCTest suite, final shared tree | **473 executed, one skipped, zero failures**, 19.720 seconds for the final test run |
| Complete integrated HotkeyTests within that suite | **34 passed**, including live AppKit monitor attachment/detachment paths |
| Strict Swift 6 build, complete concurrency checking, warnings as errors | **Passed** using full Xcode 27 / macOS 27 SDK |
| App Store compile configuration, separate scratch directory, strict flags | **Passed** (28.14 seconds); no Sparkle link in the Store product |
| Repository performance/recovery checks | **75/75 passed**, including disposable real Trash/restore checks |
| Native scrollbar checks | **10/10 passed**, reserved native gutter 17.0 pt |
| Native media/playback checks | **Passed** |
| Exact loose/archived release preflight | **Passed** for 1.10.0 (12), independently verified signed copies and complete Contents comparison |
| Isolated packaged app launch/scan | Process launched; disposable `hello.txt` was scanned and written to a valid version-6 session sidecar |
| Website generation/publication/draft isolation tests | **Passed**, one combined regression test covering multiple scenarios |
| Local website asset/link references | **33 checked, zero missing** across homepage, blog index, and published article |
| Published website browser smoke checks | Gallery/Grid switching, loaded screenshots, enlarged modal open/close, shortcut description updates, demo playback/caption track, pause on leaving Demo, blog navigation |
| Responsive website smoke check | 360 px viewport had **no horizontal overflow**; viewport restored afterward |
| Repository redacted credential scanner | Checksum-pinned Gitleaks history/staged/unstaged scans passed, no leaks reported; untracked files are outside this script's explicit coverage |
| Finding-specific probes | Evidence saved per component; no production source changes |

Finder/resource metadata broke XCTest signing in the File Provider workspace. A fresh `--scratch-path /private/tmp/louppe-audit-2026-09-29/swift-build` resolved the environment failure.

`ConnectedDrivesTests.testHostedDriveRowsExposeCapacityAndNativeChooseAction` was skipped because the XCTest host exposed no SwiftUI AX children. Computer-use inspection failed with ScreenCaptureKit -3811. Process/sidecar evidence proves launch/scan, not window appearance/focus or native VoiceOver behavior.

Preflight verifies the local package, not notarization, publication, feed re-signing, Apple distribution credentials, or the current public download. The redacted credential scan stays local.

## Measured performance and recommended optimization order

Benchmarks passed their contracts but expose large-session main-thread costs. These local Debug/standalone timings are not release-latency promises; native builds/probes also ran during measurement.

| Workload | Observed time |
| --- | ---: |
| Prepared index rebuild, 1,000 items | 17.8 ms |
| Prepared index rebuild, 10,000 items | 180.9 ms |
| Prepared index rebuild, 100,000 items | 2,644.5 ms |
| Default-order reuse, 100,000 items | 135.8 ms |
| Filter/group, 100,000 items | 265.1 ms |
| Metadata filter, 100,000 items | 138.7 ms |
| Metadata sort, 100,000 items | 2,002.8 ms |
| Export selection, 100,000 items | 95.3 ms |
| Rate one of 100,000 items | **0.3 ms** |
| Save capture, 100,000 physical files, main actor | **154.5 ms** |
| Background snapshot construction, 100,000 files | 226.5 ms |
| Same-basename export planning, 100 / 200 / 400 / 800 files | 0.127 / 0.508 / 2.131 / **8.725 s** |
| New short audio request behind abandoned hour-long analysis | **4.013 s** wait |

1. **Correct the safety/identity contracts first:** S1, S2, FS-1, X1, plus S3/M1 so displayed content, selection, and review metadata remain trustworthy. Keep existing journal/CAS/typed-identity ownership.
2. **Fix two measured bottlenecks:** stop abandoned audio readers at a verified cancellation boundary (M3), and make repeated-basename planning close to linear while preserving family suffixes/no-overwrite rules (FS-PERF-1). Test cancellation and complexity rather than a machine-dependent wall-clock threshold.
3. **Repair recovery closure:** FS-3/FS-4 must handle every crash point the live workers themselves create. FS-2 must preserve scan visibility and an undo path. Add adversarial FIFO/nonregular open tests for FS-5.
4. **Measure remaining main-actor work:** 100k metadata sorting/index rebuilds and the 154.5 ms save capture can cause a visible pause. Existing O(1) single-item ratings are already fast; preserve shared per-file metadata and prepared-index reuse. Avoid adding a new persistence architecture before measuring cheaper snapshot/index reductions.
5. **Then test source-supported opportunities:** metadata-only burst results currently wait for hashing/visual analysis; route preview file rows are eager inside lazy route blocks; redundant copy flushes may cost removable storage time; disk thumbnail pruning is launch-only; detached Info reads and RAW fit-source requests can outlive interest. Component reports distinguish these unmeasured opportunities from the two timed defects.

## Remaining verification gaps

- Physically case-sensitive, ExFAT, removable, network, and disconnected/remounted volumes; power-cut/lid-close interleavings.
- Signed and actually sandboxed App Store cold launches/open-panel access, recent-folder bookmark activation, and route Back/retry security-scope lifetime. The App Store compile check cannot prove these runtime permissions.
- Native keyboard/VoiceOver interaction with disappearing video controls, mounted-drive accessibility, small-screen/window reflow, provider drop delays, and very large routing confirmation sheets.
- Camera/RAW/color-profile corpus comparisons and full Core Image/GPU/RSS measurements; replacement behavior in related audio/video/tile/metadata lanes needs dedicated tests beyond the reproduced image/histogram cache boundary.
- The writer does not visibly enforce the reader's 512 MiB session cap. An oversized snapshot reproduction was not run; use an injectable low-cap contract check rather than allocating a huge fixture first.
- Full dependency vulnerability/CVE enumeration and an exhaustive audit of every vendored Adobe/Expat line were not performed. The exact source manifest, strict parser callback, entity guard, parser budgets, pin/checksum/license handling, and hostile XMP tests were reviewed. No claim of zero remaining security vulnerabilities is made.

## Evidence and rerun

`evidence/` retains reproduction logs, probes, the source manifest, and compile helpers. Full baseline logs/binaries stay in the temporary audit directory; summaries omit unrelated macOS diagnostics.

Baseline commands run from the canonical app working directory with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```sh
swift test --disable-keychain --scratch-path /private/tmp/louppe-audit-2026-09-29/swift-build
swift build --disable-keychain --scratch-path /private/tmp/louppe-audit-2026-09-29/swift-build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./Tests/run_performance_checks.sh
./Tests/run_scrollbar_checks.sh
./Tests/run_video_checks.sh
./Scripts/verify_release.sh
./Scripts/check_credentials.sh
```

Website: `npm run test:blog`. Consent: `node evidence/website-consent-repro.mjs` from the saved audit directory. Actual-module helpers need fresh testable objects at their named scratch paths. Component reports record construction and fault boundaries. Keep infinite/FIFO probes in bounded subprocesses.

The three component reports follow: [file mutations/recovery](file-safety.md), [session state/durability](session-state.md), and [media/native UI](media-ui.md).

Manifest digests remain in explicit `sha256` objects so Access/API filenames do not resemble credential assignments during redacted scanning.