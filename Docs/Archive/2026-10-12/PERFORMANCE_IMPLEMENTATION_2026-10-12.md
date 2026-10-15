# Performance implementation — 12 October 2026

Dated evidence; statuses and local paths describe that review. See the
[current backlog](../../../BACKLOG.md) for open work.

All ten confirmed changes from [the inspection](PERFORMANCE_REVIEW_2026-10-12.md)
are implemented in the same `main` working copy. Existing UI/burst work remains;
no branch, commit, push, publication, installed-app replacement or version change
was made. Three subagents owned media, scanner/index, and analysis/persistence;
one owner integrated `SessionStore` and serialized builds/tests/app interaction.
An independent integrated review found and resolved a pending-mode cache bug and
a rollback coverage-count bug.

## Acceptance

1. **Image cancellation:** individual waiters retire; one live coalesced waiter
   keeps work alive. Last-waiter cancellation prevents queued decode/cache/write.
   Operation identity rejects an abandoned worker's completion after a same-key
   re-request. Executing blocks occupy their lane until exit. Both thumbnail/full
   lanes, fanout, foreground promotion and bounded prefetch remain intact.
2. **Gallery publication:** full pixels publish independently of the thumbnail
   stand-in. Completed full loading retires an unnecessary stand-in waiter.
   Revision/mode/decoder/cancellation guards and failure/fallback behavior remain.
   A mounted native test displays the full surface while a real JPEG thumbnail
   worker is deliberately blocked; statistical mounted backlog checks also pass.
3. **Pairing:** removed the redundant global path sort, retaining exact sorted
   stem keys and within-group paths. Both modes/case policies, ambiguity,
   Unicode bytes, independent media and complete membership pass. Real scanner
   and main-actor physical-pair preparation are covered, with unchanged bytes.
4. **Finite metadata sorting:** decision/star/color buckets traverse a validated
   cached chronological permutation. Structural boundaries validate canonical
   input or sort an exceptional permutation; generic pure-index calls remain
   arbitrary-input safe. Both directions, missing/Mixed states and exact tie
   ordering pass. Candidate equivalence and adversarial canonical-order guards
   remain in the speed suite.
5. **Sort-only maps:** retain ID, physical-file and portable-recovery maps.
   A sort before the usual structural rebuild safely rebuilds once. Tests keep
   selection, pending fingerprint work and actual portable restoration valid
   through camera/decision/star/color changes.
6. **Burst snapshots:** capture-only requests allocate cached metadata without
   exact/visual file arrays. Candidate/group equivalence passes; Analyze-all
   retains full file capabilities. Navigation/Reset/Cancel/interval guards remain.
7. **Off-main membership:** exact/similar and capture regrouping share one
   cancellable detached task owner. Latest generation/mode/sensitivity wins;
   prior completed membership stays visible while work is pending. Gated tests
   reject obsolete completion after mode changes, navigation, exit or replacement.
   Standard-library sorts finish before their next cancellation checkpoint.
8. **Background RAW:** quality batches bypass Info's 700 ms dwell on the existing
   single utility decoder. Info retains dwell; two-item batches, leases and
   revision checks remain. Actual Fuji evidence and simultaneous foreground JPEG
   loading pass; the Info-closed quality scheduler test also passes on that RAW.
9. **Exact coverage:** total/measured counts update at item invalidation and
   accepted evidence, so the getter does no scan. Pause/Quit/Copy retain completed
   evidence. Source-changing operations and recovery invalidate it before workers
   can refresh shared identity during rollback, including cue-filter projection.
   A disposable rename/rollback regression proves remeasurement cannot double-count
   without an `items` replacement. Replacement, pairing, unsupported/nonphoto,
   stale completion and empty-session checks pass.
10. **Compact persistence:** one compact/sorted/ISO8601 encoder serves durable
    saves and production measurements. Complete/legacy field/history roundtrips,
    deterministic backup bytes, exact byte ceilings, whitespace-only CAS conflict,
    generation/sequence and existing durability/recovery tests pass.

## Measured results

Same machine and toolchain as the inspection: macOS 27.0.1, Xcode 27, Swift 6.4,
arm64, 10 logical processors, 16 GiB RAM. One warmup and seven measured samples.
Numbers are stage/workload medians; no total-app speedup is inferred. With seven
samples, nearest-rank p95 is the maximum observation.

`implementation/` contains the complete 15-method optimized pass at
1k/10k/100k, including real RAW. `implementation-confirmation/` independently
repeats five methods at 100k on final source. The full pass preceded only the
final rollback/count invalidation guard; final confirmation covers the affected
SessionStore workloads and the unchanged scanner/frozen-save bodies. Raw JSON,
all samples, runner provenance, comparison tables and validation records are
under [raw measurements](performance).

| Work at 100,000 items | Saved baseline median | Production median, full / confirmation | Largest new p95 |
| --- | ---: | ---: | ---: |
| Pair distinct stems | 1,351 ms | 726 / 719 ms | 766 ms |
| Pair RAW+JPEG families | 1,175 ms | 555 / 563 ms | 586 ms |
| Decision/star/color sort, both directions | 172–255 ms | 37–40 / 37–39 ms | 40.4 ms |
| One default-sort rating | 0.024 ms | 0.029 / 0.025 ms | 0.097 ms |
| One decision-sort rating | 164 ms | 121 / 120 ms | 124 ms |
| One star-sort edit | 124 ms | 117 / 113 ms | 132 ms |
| Camera sort menu | 934 ms | 722 / 706 ms | 742 ms |
| Coverage getter | 81 ms | 0.009 / 0.009 ms | 0.017 ms |
| Capture-burst input | 126 ms | 15.1 ms | 16.5 ms |
| Frozen save capture | 16.4 ms | 21.2 / 17.8 ms | 29.8 ms |
| Detached save entry build | 14.9 ms | 15.1 / 15.4 ms | 17.1 ms |
| Complete JSON encoding | 1,253 ms pretty/sorted | 1,225 ms production compact/sorted | 1,369 ms |

Pairing stage time fell about 46–53%; finite metadata sorting fell about 78–85%.
JSON's reliable gain is bytes: the 100k fixture shrank from **94,029,089** to
**64,028,666** bytes (31.9%). Encoding improvement is modest and sample ranges
overlap. Frozen capture is unchanged code and varies between runs; no gain is
claimed. New physical-pair preparation rows measure 0.90–0.96 seconds at 100k
without a saved before row, so no delta is attributed to that preparation.

| Media workload | Before / reference | Implemented result |
| --- | --- | --- |
| 32 already-cancelled thumbnails | 32 images and cache files; 152 ms | 0 images/files in every trial; 0.65 ms median, 1.25 ms p95 |
| 128-thumbnail Gallery backlog | Legacy mirror: full ready 46 ms, publication 596 ms, extra wait 549 ms | Mounted production: observed full readiness 126 ms, surface/loading settlement 128 ms; thumbnail 605 ms |
| Extra mounted wait after observed full readiness | No mounted before row | Median observed in the same polling turn; maximum 40.1 ms |
| One real Fuji RAW histogram | 886 ms saved Info-dwell baseline; 892 ms current Info reference | 164 ms production background, 180 ms p95 |
| Foreground JPEG while real RAW runs | New concurrent workload | 3.8 ms median, 4.7 ms p95 |

Mounted readiness uses 1 ms polling, native surface realization and loading
settlement. It includes navigation dwell/layout and does not measure physical
screen frames; its total latency is not directly interchangeable with the old
mirror. The blocked-lane regression establishes independence without a timing
threshold. The RAW is one copied 84 MiB Fuji RAF with warm OS resources;
SHA-256/identity assertions pass, and this is not universal RAW throughput.

Exact membership takes 29 ms and similar distributions 70–157 ms of worker CPU
at 100k. Cancellation checkpoints add some CPU cost; moving membership off-main
is the improvement, not faster total grouping. Revision validation and projection
still run on the session owner.

## Validation and remaining limits

| Check | Final result |
| --- | --- |
| Complete XCTest suite | 684 executed, 30 explicit skips, zero failures; complete HotkeyTests included |
| Affected integrated checks | 125 executed, four explicit skips, zero failures before the final rollback regression; final full suite includes that regression |
| Optimized statistical suite | 15/15 methods passed; independent five-method confirmation passed |
| Real RAW, Info-closed cue scheduler | One opt-in test passed separately, zero skips |
| Required performance/file-safety script | 75/75 on final source, including real disposable Trash/restore |
| Shipping release package | `build_app.sh` preflight passed; loose/archive strict verification and complete `Contents/` equality passed |
| Fresh temporary launch | Unique review identity, `-openFolder`, live process; schema 7 contains all 12 unrated disposable files; media/source bytes unchanged |
| Local-work preservation | 68 of 79 starting local files byte-for-byte unchanged; eleven intentionally extended; starting diff/hashes retained; unrelated concurrent BACKLOG edits retained |
| Integrated review / whitespace | Reviewed once stable, both findings fixed and tested; `git diff --check` passed |

Speed runs use `-c release -Xswiftc -DDEBUG` because existing test seams require
DEBUG. They are optimized tests with conditional debug code. The subsequently
packaged shipping release uses ordinary release flags without `-DDEBUG`.

Active quality-filter switching remains a full traversal: **110–140 ms** median
across new runs versus 112–116 ms before, with approximately 199 ms maxima. It
was not optimized or weakened; the observed variability/slower confirmation and
remaining stall require a separately tested incremental solution. Decision/star
projection likewise remains material after faster sorting.

Computer Use's prior two ScreenCaptureKit `-3811` failures remain unresolved;
no unchanged retry or screenshot/perceived-frame claim was made. Mounted native
checks passed. Removable/provider volumes, multi-camera RAW throughput,
thermal/battery behavior, complete native scrolling and VoiceOver acceptance
remain outside this evidence. Deferred cache/queue/prefetch/journal hypotheses
were not promoted.

Validation used the temporary review app
`/private/tmp/louppe-performance-implementation-83x3uszk/Louppe Performance Implementation.app`.
The installed app and production bundle identity are unchanged. Validation
records, final source hashes and the launch fixture path are in
`Performance/2026-10-12/implementation-validation/`.

The temporary app above was retired during the 13 October consolidation.
Use the [current combined review build](../../REVIEW_BUILD.md) at `/Applications/Louppe.app`.

The [14 October cue-filter follow-up](../2026-10-14/QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md)
supersedes the earlier cue-switch timings: compact cached classification improves
repeat and first-use filtering. Visible/group projection and energy acceptance
remain open.
