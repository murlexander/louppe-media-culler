# Performance inspection — 12 October 2026

Dated evidence; statuses and local paths describe that review. See the
[current backlog](../../../BACKLOG.md) for open work.

Repeatable speed tests and correctness-checked candidate algorithms are added
locally. Production behavior is unchanged by this inspection. The baseline
includes Alex's existing uncommitted UI and burst-analysis work, starting at
`544f6222a499b316d419797e358c232fd56e410a` on `main`.

Three subagents audited scan/index/selection, media/UI, and persistence/group
analysis. The parent integrated and serialized all builds/tests. A separate
read-only review checked benchmark validity, candidate preconditions and fixture
safety. Original tracked changes were preserved byte-for-byte.

## Evidence and interpretation

macOS 27.0.1, Xcode 27, Swift 6.4, arm64, 10 logical processors, 16 GiB RAM.
Two independent optimized processes used one warmup and seven measured samples.
The first covered 1k/10k/100k items; confirmation repeated 100k plus media/I/O.
Focused final passes verified corrected measurement contracts. See
[the runner guide](../../SPEED_TESTS.md) for flags, warm-cache limits and statistics.

Raw JSON, console logs and source/toolchain provenance are retained under
`Docs/Performance/2026-10-12/`. `baseline` is the initial full pass;
`confirmation` is the independent 100k pass; `final-focused` supersedes their
sort-menu diagnostics and strengthens backup verification; `final-media`
adds structured ready/publication latency and verified readable disk entries.
`real-raw` contains the optional camera-RAW pass on a disposable 84 MiB Fuji RAF.

Numbers below are local medians. Candidate timings describe their isolated
stage, not an already implemented app improvement or total folder-open speedup.

| Work at 100,000 items | Current | Tested candidate / implication |
| --- | ---: | --- |
| Pair 100k distinct stems | 1,351–1,372 ms | 931–936 ms without global path sort; 31–32% less stage time |
| Pair 50k RAW+JPEG families | 1,175–1,178 ms | 708–709 ms; about 40% less stage time |
| Decision metadata sort, both directions | 172–180 ms | Canonical finite buckets 34–46 ms |
| Stars/colors metadata sort, both directions | 242–271 ms | Canonical finite buckets 34–43 ms |
| One rating, default sort | 0.024 ms | Already fast; preserve the existing shared metadata storage |
| One rating, decision sort | 164–171 ms | Full sort plus projection rebuild remains a visible hot path |
| One star edit, star sort | 124–132 ms | Same projection concern after faster sorting |
| Decision filter + groups/maps | 86–89 ms | O(N) derived visibility is material; do not claim buckets alone eliminate stalls |
| Camera sort menu | 934 ms final | Prepared-only lower bound 719 ms; extra delta also includes UI-state/publication work |
| Coverage summary, no measured evidence | 78–81 ms | Getter scans/copies all photos while Filter is realized |
| Change selected quality cue | 112–116 ms | Full matching/projection cost; background 100 ms coalescing cannot remove each stall |
| Similar groups, equal/paired-random/random hashes | 69–139 ms | Synchronous cache-miss membership should leave the UI actor |
| Exact groups, pairs | 22–23 ms | Also synchronous today |
| Burst input allocation | 126 ms | Metadata-only payload 18–19 ms, identical burst results |
| Frozen save capture / detached entry construction | 16 / 14–15 ms | Preserve freezing; no evidence yet for a rating journal |
| JSON pretty/sorted encoding | 1,244–1,253 ms | Compact/sorted 1,179–1,185 ms; bytes 94.0 MB → 64.0 MB |

The camera sort comparison is diagnostic, not an attribution of the complete
delta to structural maps. The final benchmark resets direction outside timing
and compares identical complete order and retained selection.

## Confirmed media findings

- **Cancellation:** every trial admitted all 32 already-cancelled thumbnail
  requests, returned 32 decoded images and wrote 32 cache files. Around 147 ms
  of work continued after all callers were cancelled. Same-revision 32-caller
  fanout correctly shared one image/cache entry and must continue doing so.
- **Gallery dependency:** with 128 pending real JPEG thumbnails, the final pass
  measured full readiness at 46 ms, thumbnail readiness/publication at 596 ms,
  and 549 ms of extra wait after the full image was ready. Without backlog the
  extra wait was zero. This uses the real pipeline and the view's mirrored
  await order, not a measured screen frame. Two earlier processes reproduced
  approximately 535–557 ms extra wait across their measured samples.
- **RAW dwell:** four instant injected RAW decodes in two-item batches took
  about 1,433 ms with the default dwell versus 0.34 ms without it. This isolates
  scheduling, not camera decoding. `QualityCueEvidence.measure` routes background
  batches through the same 700 ms dwell intended for Info. The artificial floor
  is about 350 ms/photo before actual decoding and interbatch sleeps.
- **Cache health:** 1,000 memory hits took about 2.3 ms total. Sixteen readable
  disk thumbnails took about 11 ms versus roughly 280 ms for source decode plus
  cache drain. Source identities and unchanged bytes were asserted. Enlarging
  caches or decode concurrency is not supported by these results.

The real camera RAW confirmed the dwell cost with the production Apple Default
decoder: one histogram took 886 ms with dwell versus 164 ms without it. Fast
320px preview took 22 ms; RAW previews took 179 ms at 1,024px and 242 ms at
4,096px. Seven post-warmup samples, a fresh histogram pipeline per request,
bounded positive evidence and unchanged SHA-256/source identity all passed.
One camera/file with warm OS resources is not a general RAW throughput claim.

## Implementation acceptance list

Implement these in a separate chat, preserving the current working copy. Keep
candidate research tests and compare actual production rows with these baselines.

1. **Retire abandoned image requests.** In `ImagePipeline.decodeOnce`, remove
   cancelled waiters, cancel queued work only after the last live waiter leaves,
   and reject obsolete completion by operation identity. Keep running lanes
   occupied through worker exit, foreground promotion, revision checks and
   intentional bounded prefetch. Test one cancelled coalesced waiter, all
   cancelled, cancel/re-request of the same key, and thumbnail/full lanes.
2. **Publish the full image independently.** In `FullImageView`, do not await a
   thumbnail before publishing a ready full image. Retain revision/mode/decoder/
   cancellation guards, loading settlement and fallback failure behavior. Add a
   mounted UI check under real thumbnail backlog; require displayed full-image
   latency to follow its own lane rather than the backlog.
3. **Remove pairing's redundant global sort.** In `FolderScanner.pairFiles`,
   retain sorted exact stem keys and exact per-group path ordering. Preserve both
   modes/case policies, ambiguous cross-folder stems, Unicode bytes, independent
   media and complete physical membership. Check scanner and main-actor
   `rawJPEGPairs` preparation, not only the isolated projection.
4. **Use finite metadata sorting without changing ties.** In
   `PreparedSessionIndex`, bucket over a valid chronological permutation.
   Preserve arbitrary-input pure-index behavior, missing dates/values, Mixed,
   stable byte/name ties and both directions. Raw item-order buckets are unsafe:
   `[Z.JPG, A.JPG]` with equal metadata must still sort A before Z. Exceptional
   cleanup/undo fallback can also break raw-array chronology. Cache the canonical
   permutation at a structural boundary rather than re-sorting on every edit.
5. **Keep structural maps on sort-only changes.** Narrow `SessionStore.sort`
   work to sort/projection while retaining required current/selection/filter
   effects. ID, physical-file and recovery maps rebuild on structural changes.
   Verify portable-recovery mappings and pending fingerprint work across sorts.
6. **Prepare only needed burst input.** Capture requests need cached dates and
   evidence, not exact/visual file arrays. The test proved identical candidates
   and groups with empty file arrays. Keep revision/generation validation,
   navigation/Reset/Cancel behavior and Analyze-all capabilities.
7. **Move exact/similar membership off-main.** Extend the existing cancellable
   analysis owner, with latest sensitivity/mode/generation winning. Preserve
   previous completed projection during pending work and reject stale results.
   This completes the measured exact/similar part of the older AUD-08 avenue.
8. **Separate background RAW requests from Info dwell.** Background quality
   batches can bypass the presentation dwell while retaining one utility RAW
   decoder, two-item scheduling, cancellation, leases and revision checks. Keep
   Info's dwell. Verify actual RAW evidence and JPEG foreground latency together.
9. **Cache quality coverage counts at mutation boundaries.** Maintain exact
   total/measured counts on evidence publication and structural invalidation;
   avoid a full scan in the coverage getter. Test replacement, rescan, pairing,
   pause/cancel, stale completion, unsupported media and empty sessions. Active
   quality-filter projection needs a separately measured incremental solution;
   do not silently weaken filtering semantics to reach a frame budget.
10. **Prefer compact, sorted persistence JSON.** It saves about 32% of bytes with
    a modest encoding improvement while preserving deterministic field order.
    Reopen every schema field/history, preserve snapshot ceilings, exact-byte
    CAS/lineage, sequence/generation checks and durable sidecar/backup writes.
    Removing sorted keys has a smaller additional CPU benefit and is deferred.

## Deferred hypotheses

- Visible actual-size tiles and their margin enter an unordered equal-priority
  set. Test visible-first/distance scheduling before changing it.
- Mixed RAW/JPEG batches wait for their slowest result; publishing completed
  evidence sooner may help, but is not an established throughput improvement.
- Exact/similar mode-specific analysis could avoid unrelated hashes/decodes.
  Measure real mixed media and preserve explicit Analyze-all capabilities.
- Recovery under active metadata sort may rebuild per restored file. Establish
  a complete batch fixture before claiming quadratic user-visible behavior.
- Mode-aware RAW neighbor prefetch and content-verifier task/publication batching
  need representative measurements. Do not enlarge queues/caches, weaken file
  validation, add a rating journal or change originals on speculation.

## Validation record

| Check | Result |
| --- | --- |
| Existing baseline XCTest suite | 643 executed, 15 skipped, zero failures |
| Final complete XCTest suite | 658 executed, 30 skipped, zero failures; 15 speed tests skip by default |
| Optimized speed suite | 13 original methods passed in both independent processes; finalized affected checks, canonical-order guard and optional real-RAW method passed separately; all 15 methods exercised |
| Required performance/file-safety checks | 75/75, including disposable Trash/restore |
| Swift/source/toolchain consistency | Original tracked diff SHA-256 remained `bf770ab39092f873b7624ac600d80cb4a23a65be7f3d867e930ce9438a1898b7` before documentation additions; no original local change was edited |
| Runner/comparison tool | zsh syntax check, Python compile and actual before/confirmation comparison passed |
| Release package | Production release preflight passed; temporary loose and unpacked review apps strictly verified and complete `Contents/` trees matched |
| Launch | Unique temporary review process survived launch with `-openFolder`; disposable schema-7 sidecar contains all 12 unrated files |
| Native visual inspection | Blocked: Computer Use twice returned ScreenCaptureKit `-3811`; no visual/perceived-frame claim |

Packaging the review copy in Documents encountered the already documented
Finder-metadata signature problem. Removing attributes from its temporary copy
restored strict verification; the verified archive and loose copy matched in
full. The launched temporary copy uses a distinct review-only identity
`com.alexandermarkin.louppe.performanceReview20261012` to avoid selecting the
older running review app. No installed app, production bundle identity, release
version, commit, push or publication changed.

Validation logs are retained beside the raw reports. The thirty default-suite
skips include the fifteen opt-in speed tests and fifteen pre-existing external
fixture/volume/display/accessibility checks; skips are not passes.
This inspection does not establish removable/provider-volume performance,
thermal/battery behavior, multi-camera RAW throughput, or complete native
scrolling/VoiceOver acceptance.

The subsequent [implementation and measured results](PERFORMANCE_IMPLEMENTATION_2026-10-12.md)
complete the ten confirmed items; this document retains the inspection baseline.
