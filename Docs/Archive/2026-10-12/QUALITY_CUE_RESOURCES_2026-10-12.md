# Quality cue resource review — 12–13 October 2026

Dated evidence; statuses and local paths describe that review. See the
[current backlog](../../../BACKLOG.md) for open work.

Quality checks now have explicit resource controls, backed by gated worker tests
and repeated CPU measurements. Fast access to current/visible photos takes
priority; remaining-folder work deliberately rests. This extends the
[performance implementation](PERFORMANCE_IMPLEMENTATION_2026-10-12.md) without
changing the cue definitions, sampling resolution or photographer decisions.

## Calculation and retained data

- ISO/shutter cues use scanned metadata and need no additional image reads.
  Turning off both clipping rules stops histogram scheduling; threshold edits
  reuse completed numeric evidence.
- Rendered clipping uses a bounded 1,024-pixel sRGB image, unpremultiplying
  nonzero alpha before the existing luminance calculation. RAW uses one utility
  Apple Default decode, native scaling and a final approximately 1,024-pixel
  extended-linear output. Thresholds/source labels and revision guards are intact.
- The session retains counts, dimensions, source and revision per photo. The
  histogram caches retain 256 rendered/128 RAW numeric results. No folder-sized
  image/bitmap cache or per-photo task queue was added. RAW's final float buffer
  is about 16 MiB at the maximum square size; internal framework/helper allocations
  are not bounded by that number. Rendered analysis can decode separately from
  the 320/4,096-pixel thumbnail/Gallery paths.

## Admission, priority and Pause

The scheduler admits at most two measurements. RAW decoding remains serial;
rendered histogram decoding has two lanes. Cancelled scheduler generations must
exit before Resume admits another pair. Native background histogram cancellation
also retains its awaiting caller through the executing operation's exit, keeping
the scheduler's independent folder lease alive. Cancelled evidence cannot publish
or enter the numeric cache. Queued last-waiter cancellation does no decode;
foreground Info waiters retain prompt individual cancellation.

Background rendered operations use utility QoS/low queue priority. Info requests
join/promote shared rendered work to user-initiated/high priority; they do not
split the revision cache. RAW stays on its existing single utility lane. Background
RAW requests bypass Info's 700 ms presentation dwell, but the folder scheduler
now owns their deliberate pace.

| System state | Rest after a batch |
| --- | --- |
| Normal/fair thermal state | At least 100 ms and the preceding batch's wall duration |
| Low Power Mode or serious thermal state | At least 100 ms and three times the batch duration |
| Critical thermal state | At least 100 ms and seven times the batch duration |

These are admission rules, not CPU/GPU percentage caps. Current, newly selected
or uncovered rendered-tile interest interrupts rest. Covered navigation/selection
does not wake unrelated work; selecting the whole folder does not exempt all
batches. Resources are sampled per batch, without idle polling. Completed work
settles with no new measurements/publications in the controlled observation.

Explicit Pause survives threshold edits, file work, pairing/replacement and
automatic restart requests until Resume. Accepted filter matches flush before
adaptive rest and on ordinary Pause, preserving current/selection. Source changes
still invalidate evidence and coverage. Running native decode may finish after
Pause; it retains its lane/access and is excluded from publication.

## Measured hypotheses

Two warmups and seven interleaved samples of the exact frozen histogram processor
and a Combine storage model are retained under
[quality-resource/isolated](performance/quality-resource/isolated/README.md).
Seven complete result-equivalence checks and 140 raw samples passed under Swift 6
language mode with release optimization.

| Hypothesis | Result and decision |
| --- | --- |
| Skip unpremultiplication for alpha 255 | Opaque wall 3.851 → 2.496 ms; mixed/partial alpha regressed 12.7%/9.8%. Full results match, but the general shortcut is rejected. |
| Replace growing Published evidence with private mutation | At 10k, observed Published storage cost 1,234.7 ms wall / 1,225.7 ms process CPU; private batched storage 2.14 / 2.14 ms. Adopt private storage and coherent pair notifications. |
| Retain selection-priority frontier | Legacy bounded model proves quadratic probes: 2,500,050,000 extrapolated at 100k. Production consumes each selected candidate at most once per selection generation; actual 2k and optimized large-session checks verify this. |

The storage model excludes SessionStore, decoder and UI work. Similar observed/
unobserved Published times support copying as the dominant mechanism; no allocation
profiler counted copies. Most savings come from private mutation, with a smaller
additional benefit from batching. Production sends one admission and one coherent
result notification per pair and skips cue-matching math when no cue filter is active.
Visibility compares the existing any-selected-cue predicate, avoiding a projection
when another cue appears on an already-matching photo.

Actual SessionStore measurements use immediate injected evidence, Select All,
no production rest, and a single final-batch completion signal. Fixture setup and
assertions are untimed. One warmup and seven samples; process CPU includes all
process threads and the small subscriber/completion harness.

| Photos | Wall median / p95, ms | Process CPU median / p95, ms |
| ---: | ---: | ---: |
| 1,000 | 75.8 / 80.8 | 108.3 / 115.1 |
| 10,000 | 776.1 / 786.8 | 1,096.7 / 1,108.9 |
| 100,000 | 7,670.8 / 7,679.6 | 10,757.0 / 10,820.3 |

CPU/bookkeeping scales approximately linearly. This is not a whole-folder decode
time: native I/O, image computation, UI rendering and deliberate background rests
are excluded. Total CPU can exceed wall time because workers run concurrently.
Exact revision/count/coverage, at-most-N selection probes, and at-most-one admission
plus one result notification per pair pass at all three scales.

An earlier busy-yield waiting harness added CPU and contended with the scheduler.
Its raw run and frozen benchmark source are retained as a diagnostic; the table
uses event-based completion. No before/after app-speed delta is inferred from the
storage model. The affected review run keeps ordinary 100k rating at 0.024 ms and
coverage at 0.009 ms. Metadata-cue switching measured 78.6 ms median / 183 ms p95
in this process; traversal remains material and varies between runs.

Real-media confirmation: one copied 84 MiB Fuji RAF measured 158.5 ms background
histogram versus 907.9 ms Info-dwell reference. Foreground JPEG full loading during
RAW took 3.67 ms median / 3.85 ms p95. SHA-256 and source identity checks passed.
These are warm-resource, one-camera measurements. All six affected optimized media
methods passed; no universal RAW throughput or screen-frame claim is made.

Raw production, harness diagnostic, media samples and toolchain/source context are
retained under [quality-resource](performance/quality-resource).

## Validation and remaining limits

| Check | Final result |
| --- | --- |
| Controlled quality/media/integration checks | 54 executed, one explicit optional-RAW skip, zero failures |
| Full XCTest suite | 714 executed, 31 explicit skips, zero failures; complete HotkeyTests included |
| Optimized resource suite | 1k/10k/100k, one warmup + seven samples, all invariants pass |
| Affected optimized review/media suite | Seven methods pass; real RAW/source-byte checks included |
| Real RAW, Info-closed session scheduler | One opt-in test passed separately, zero skips |
| Required performance/file-safety script | 75/75 including real disposable Trash/restore |
| Shipping configuration/package | Release preflight passes; strict loose/archive verification and complete Contents equality |
| Fresh temporary app launch | Separate review identity, updates disabled, -openFolder; live process, schema 7, 13 unrated PNG/RAW entries; original/fixture bytes unchanged |
| Independent integrated review | Covered-interest and delayed-visibility findings fixed and regression-tested; retirement review has no further findings |
| Existing source preservation | 153 of 157 prior source files byte-identical; four intentionally extended, plus the new resource policy |

Validation used `/private/tmp/louppe-quality-resource-review-pn_o55n1/Louppe Quality Review.app`.
That temporary copy was retired during the 13 October consolidation. The current
combined review app is [Louppe](/Applications/Louppe.app); see the
[review guide](../../REVIEW_BUILD.md).
[Validation records](performance/quality-resource/validation) retain
build/safety logs, launch metadata, source hashes and the concise XCTest summary.
The shipping build uses ordinary release flags; statistical XCTest uses release
optimization with required DEBUG seams. Native screen capture remains unavailable
from the earlier two ScreenCaptureKit -3811 attempts. Mounted native UI tests pass;
this does not establish physical frames or a complete photographer workflow.

The first new contract run reproduced eight assertions across three failing tests:
automatic Pause loss and overlap of four injected measurements during generation
restart. This was scheduler admission overlap; native JPEG/RAW queues already
limited their own decoder concurrency. Tests now cover the actual exit boundary,
queued cancellation, coalesced survivors/promotion, revision replacement, power/
thermal rest calculations, interest wakeups, exact coverage, source invalidation,
accepted-filter visibility and reusable evidence. The reproduced baseline failure and interrupted optimized build are retained;
neither counts as a pass.

Active quality-filter projection still traverses a large session. The earlier
100k measurements of 110–140 ms remain a material UI limitation; batching or
priority is not a substitute for a separately tested incremental projection.
This review does not establish whole-system energy, GPU/helper peak memory,
battery life, App Nap behavior, multi-camera RAW costs or physical frame latency.
Those remain AUD-06/AUD-19/AUD-28/AUD-29 in [the backlog](../../../BACKLOG.md).

The [14 October cue-filter follow-up](../2026-10-14/QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md)
supersedes the earlier cue-switch timings: compact cached classification improves
repeat and first-use filtering. Visible/group projection and energy acceptance
remain open.
