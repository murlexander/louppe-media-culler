# Audit implementation — 2026-09-29

All **17 confirmed findings** from the [full audit](README.md) were fixed in the
canonical repositories. Three agents owned file safety, session state, and media/UI;
the coordinator owned XMP, consent, integration, docs, and packaging. Independent
XMP/consent reviews found further boundary cases, fixed and regression-tested.

As of 29 September, changes were local on `main`, with existing work preserved.
No commits, pushes, release, deployment, or original user-media operations occurred.
Version remained **1.10.0 (12)** after public **v1.9.0 (11)**. The Help button stayed
24 points from the bottom/trailing window edges, with reserved overflow footer.

The audit is retired. App follow-ups are in [BACKLOG.md](../../../BACKLOG.md#audit-follow-ups)
(AUD-01–AUD-24). Website consent was unpublished at closeout and is now published;
WEB-AUD-01 acceptance remains in the [website backlog](../../../../website/BACKLOG.md#browser-acceptance).
Reports, tests, and evidence preserve the 29 September record.

## Finding-to-fix map

| Finding | Implemented behavior | Regression authority |
| --- | --- | --- |
| S1 — P1 | Component Clean Up requires the physical target's own index in Selected/Filtered scope; Together retains shared pair scope | PairComponentCleanUpScopeTests, existing real CleanUp safety checks |
| S2 — P1 | Observed renamed bytes update CAS lineage only; durable completion requires a validated real directory full sync or durable backup; dirty Close/Quit stays blocked otherwise | SessionDurabilityTests: visible-but-unsynced sidecar/backup, same-sequence Retry, disconnect/reconnect, external replacement, real termination preparation |
| FS-1 — P1 | Internally normalization-equivalent family names fail promptly; collision search is cancellable and suffix overflow guarded | FileSafetyAuditRegressionTests: no probes/journal activation before refusal; bounded original collision probe |
| X1 — P1 | Immutable XMP plans retain every family member's scanned identity, original parent, and source-folder authority; revalidate preflight/final publication using a held parent descriptor | XMPPublicationIdentityTests: pre/post-preflight and final-flush replacement, sibling removal, nonregular media, parent replacement, packet CAS, already-current, absent authority, temp substitution/in-place edit |
| S3 — P2 | Surviving explicit selection owns displayed current in prepared visible order after filter/restore | SelectionStateTests, real SessionStore filtered-selection cases |
| M1 — P2 | Uncached image, RAW, metadata, histogram, audio and new zoom-tile reads reject source identity changes; cold/player-ready guards reject replaced playback sources | MediaRevisionTests: real ImageIO/Core Image fixtures, RAW/audio injection, symlink/edit/replacement, trustworthy cache reuse, native player preparation |
| FS-2 — P2 | Explicit hidden/package containers refused; generated names sanitized; actual folder flags rechecked before original moves | FileSafetyAuditRegressionTests: hidden/package/UF_HIDDEN, actual organize → scan → undo |
| FS-3 — P2 | Move rollback removes an incomplete generated packet only with a durable owned-inode checkpoint; staged/complete packets still require sealed digest | FileSafetyAuditRegressionTests: started/staged/complete, quarantine, unrecorded/replaced variants |
| FS-4 — P2 | Completed XMP retirement recognizes either reserved cleanup path, checks identity/digest, and finishes forward idempotently | FileSafetyAuditRegressionTests: retirement/quarantine/unlinked/replacement/ambiguity |
| FS-5 — P2 | Journal media/checkpoints/recovery require regular files; blocking read/sync boundaries use O_NONBLOCK before fstat | FileSafetyAuditRegressionTests: FIFO/directory/symlink, malformed journal; directory identity API remains valid |
| M2 — P2 | Nonzero-alpha pixels are unpremultiplied for analysis and warning overlays repremultiplied with unchanged alpha | HistogramTests: alpha 0/3/128/255 and unchanged opaque behavior |
| M3 — P2 | Last waiter stops the running audio task; serial slot remains held until reader exits; exact-operation completion cannot claim renewed requests | AudioCancellationTests, RAW immediate-rerequest regression, actual hour-long WAV cancellation probe |
| U1 — P2 | Numeric Filter commits only explicitly edited endpoints and preserves untouched exact values across all five ranges | NumericFilterDraftTests, real hosted Filter open/wait/close lifecycle |
| U2 — P2 | Gallery transport/full-screen/Picture-in-Picture controls remain visibly mounted during playback | GalleryVideoAccessibilityTests: actual hosted native player; native AX/Tab assertions conditional on available host settings |
| W1 — P2 | Consent reconciles storage/focus/visibility/expiry and before custom events; rejects missing/invalid/expired choice; local unpersistable refusal survives delayed events | 11 production-script VM tests plus independent cross-tab/quota/reload/stale-timer probes; existing blog regression |
| FS-PERF-1 — P2 | Whole-family suffix cache and reservation-first lookup avoid repeated-basename quadratic filesystem probes | 800-file exact n-probe assertion, family-composition/existing-suffix tests, original scaling probe |
| S4 — P3 | Typed DurableFileIO errno preserves permission, space, unavailable-device, and busy saving remedies | SessionDurabilityTests: typed injected failures and real read-only folder |

## Critical publication and recovery boundaries

Standalone XMP freezes metadata at confirmation, with three long-lived workers,
serial parsing per worker, and one packet in memory at a time. Authority includes
unselected same-stem siblings. Identity failure reports external modification with
**Rescan**, including “Already current.” Updates still require raw-byte/revision CAS.

A held original-parent descriptor covers temporary creation/write/full sync,
validation, rename, owned cleanup, and directory flush, preventing pathname
replacement from redirecting mutation. Final rename checks immutable post-flush
stat: regular type, device/inode, birth, size, mtime, and ctime. Independent review
reproduced temporary substitution; the final helper throws DestinationChanged and
preserves the sidecar and foreign temporary. Same-inode edits have separate tests;
only an owned inode may be cleaned.

Observed desired bytes advance CAS lineage/generation, not the successful save
sequence. Recovery validates bytes and authority before/after full directory sync
under the stable folder lock; a fully synced backup is also discard-safe. If both
fail, ratings stay dirty, Retry keeps its sequence, and Quit is refused.
Disconnect/reconnect may adopt only this access's marked interrupted commit,
never arbitrary older-backup equality.

Generated Move partial cleanup requires checkpointed inode ownership; `.started`
bytes need not match the final digest, but staged/completed packets must.
Retirement checks both reserved names and refuses dual/replaced candidates.
Unrecorded or ambiguous artifacts stay unresolved. Generic identity capture still
supports directories; media/journal mutation requires regular files. Names alone
never establish ownership.

Withdrawal disables GA before custom events, reconciles tabs, and removes stale
acceptance if rejection writes fail. Unpersistable refusal neither auto-reloads nor
accepts delayed earlier acceptance. If writes and removal both fail, refusal lasts
only for that visit. VM tests prove no Google-traffic/compliance result. Website
fixes were unpublished on 29 September.

## Measured optimizations

| Reproduced workload | Audit baseline | Fixed | Independent correctness check |
| --- | ---: | ---: | --- |
| Empty-destination same-basename plan, 800 one-file families, Debug | 8.725 s | 0.035293 s, approximately 247× faster | Exactly 800 destination entry probes; no family split/overwrite |
| Same plan, 100 / 200 / 400 | 0.127 / 0.508 / 2.131 s | 0.004662 / 0.008400 / 0.017405 s | Exactly one probe per file at every size |
| Next short WAV after canceling abandoned one-hour stereo reader | 4.013112 s | 0.257031 s, about 94% less | Serial lane held until cancellation exits; renewed request has fresh result |
| Re-request canceled long WAV | 0.000039 s stale abandoned cache hit | 4.574135 s fresh complete read | Canceled partial analysis is not cached |

Timings are local diagnostics, not latency promises or hardware-dependent test
thresholds. Externally occupied suffixes and overlapping nonidentical families
still need cancellable search. Untimed index/main-thread opportunities did not
justify architectural changes.

## Integrated verification

Final checks completed against the frozen production sources:

| Check | Final result |
| --- | --- |
| Complete app XCTest suite | **524 executed, 1 skipped, zero failures**, 22.718 s; **51 added regressions** versus the baseline audit |
| Required complete HotkeyTests | **34 passed**, integrated native monitor/window attach/detach cases |
| New XMP identity/publication suite | **11 passed**, including temporary substitution and same-inode edit |
| Help/window layout suite | Passed with the requested 24-point window-corner anchor retained |
| Swift 6 strict-concurrency, warnings as errors | Passed, full Xcode/macOS 27 SDK |
| Separate App Store strict compilation | Passed; Store executable has no Sparkle link |
| Repository performance/recovery checks | **75/75 passed**, including actual disposable Trash/restore |
| Native scrollbar checks | **10/10 passed**, native 17.0-point gutter |
| Native media/playback checks | Passed |
| Website tests | **12 passed**: 11 consent-script tests plus existing blog publication/draft regression |
| Independent XMP and consent probes | Passed after the additional reproduced boundary fixes |
| Release/package preflight | Passed for **1.10.0 (12)**; independently verified signed loose/archive app and complete Contents comparison |
| Installed app signature | `codesign --verify --deep --strict` passed after archive extraction and install |
| Installed-binary isolated launch/scan | Three real disposable PNG/WAV/text entries; schema 6, captured file identities, original bytes unchanged |
| Stable app relaunch and preferences | Process running; before/after preferences exactly equal |
| Source freeze/diff validation | Production build inputs unchanged through final checks/package; only two test synchronization files changed; both repositories' `git diff --check` clean |

The drive-row skip is the baseline host limit: no SwiftUI AX children. Gallery's
optional AX/Tab checks were also unavailable; native playback and mounted-control
regressions passed.

The first full run exposed two **test observation races**: Gallery read optimistic
`toggle()` state before native startup; Quit read status/Retry before the completion
observer cleared the count. Tests now await ready/playing/advancing time and
persistence idle. Save outcomes and disk bytes remain asserted. Durability passed
five isolated repeats; 69 media/native/Hotkey cases passed. Final full run: zero failures.

The installed executable SHA-256 is
`487290060dd74a37031aeb27dfde5da49783345b49c9d4f94d5e49c2ed63faef`.
The previous installed app and before/after preference snapshots are retained in
`/private/tmp/louppe-fixes-2026-09-29/install/`. The isolated launch used a copy
of that exact installed executable with a temporary bundle identity and updates
and Finder service registration disabled; the stable identity/preferences were
not used for its fixture session. The stable app was relaunched afterward.

Full Xcode and temporary SwiftPM paths avoid File Provider FinderInfo signing
failures. Synchronization waits for native playback and save completion, not
optimistic flags or arbitrary sleep.

## Detailed reports and evidence

- [File-safety implementation, 11 dedicated regressions and 141 adjacent cases](implementation-file-safety.md)
- [Session-state/durability implementation, 14 added regressions](implementation-session-state.md)
- [Media/UI implementation and native-host limits](implementation-media-ui.md)
- [Independent XMP boundary review](xmp-independent-review.md)
- [Independent consent review, including two additional reproduced/fixed cases](website-consent-independent-review.md)
- [Curated reproduction evidence](implementation-evidence/) retains the bounded
  file-safety and actual-media logs plus source fingerprints. Full compilation
  and runtime logs remain under `/private/tmp/louppe-fixes-2026-09-29/`; routine
  macOS service diagnostics are omitted from tracked evidence.

Rerun from the canonical app directory with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```sh
swift test --disable-keychain --scratch-path /private/tmp/louppe-audit-2026-09-29/swift-build
swift build --disable-keychain --scratch-path /private/tmp/louppe-audit-2026-09-29/swift-build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
./Tests/run_performance_checks.sh
./Tests/run_scrollbar_checks.sh
./Tests/run_video_checks.sh
./build_app.sh
```

Website: `npm test` runs all 12 regressions; `npm run test:consent` runs the 11 consent cases.
App Store compilation additionally uses `LOUPPE_APP_STORE=1`, `-DAPP_STORE`, a
separate scratch directory, and the same strict Swift flags. No distribution
certificate, notarization, App Store submission, or feed publication is implied.

## Remaining verification limits

- No physically case-sensitive/ExFAT/network/remounted-volume or power-cut
  testing. Safety fixtures use disposable local media and authentic durable
  journal states, not destructive tests on the user's photographs.
- App Store compile success cannot prove signed sandbox/security-scope behavior.
- Live control-by-control Tab and VoiceOver actions remain unavailable: this
  host exposes no SwiftUI AX children and Full Keyboard Access is off. The
  final video controls avoid hover concealment; structural playback coverage
  passes without changing the user's global settings. Screen capture permission
  is unavailable; launch/sidecar evidence does not prove every visual detail.
- Before/after media-read validation is not continuous original-file monitoring;
  validated original cache pixels remain usable until rescan. No real camera
  RAW corpus, GPU/RSS, Google-beacon capture, disk-full hardware fault, or actual
  power-loss campaign was run.
- The baseline audit's unconfirmed opportunities and dependency-enumeration
  limits remain recorded there. Implementing all confirmed findings does not
  establish that software has no remaining defects.
