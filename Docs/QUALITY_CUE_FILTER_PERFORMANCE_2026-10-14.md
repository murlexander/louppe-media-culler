# Quality-cue filter performance — 14 October 2026

Quality-cue switches now reuse a compact numeric match index instead of rebuilding
warning arrays and matching filenames. Fresh optimized tests at 100k photos
confirm a substantial reduction in model-side filtering work.

| Work at 100k photos | Before median | Final / independent confirmation |
| --- | ---: | ---: |
| High ISO, half match | 148.3 ms | 37.6 / 39.2 ms |
| Slow shutter, one fifth match | 127.8 ms | 16.1 / 18.1 ms |
| Either metadata cue | 158.7 ms | 42.9 / 44.4 ms |
| First high-ISO use after invalidation | 152.5 ms | 53.1 / 53.4 ms |
| High ISO with surviving selection | 153.0 ms | 37.1 / 38.9 ms |
| High ISO, grouping disabled | 121.3 ms | 6.5 / 8.2 ms |

At 10k, repeat metadata switches take about 1–4 ms. Populated numeric clipping
evidence also passes: near-white/near-black switches take 39.3/39.9 ms at 100k
with half the photos matching; their union exposes every photo and takes 70.6 ms.
First clipping use after threshold invalidation takes 66.1 ms. Those clipping
rows have no legacy whole-filter baseline, so no before/after delta is claimed.

Controlled first-pair arrival tests take about 2.1 ms at all three scales.
Each accepted pair updates exactly two classification slots without a full
rebuild. This includes gate dispatch, projection, next admission and up to 1 ms
polling; it covers the first eight accepted pairs with few visible matches and
injected evidence, excluding native decoding and the production rest policy.

## Implementation and correctness

- One UInt8 mask per item-array index, allocated lazily: approximately 100 KB
  of payload at 100k items. Sorting/ratings retain it; accepted evidence updates
  only its own slots. The prepared index borrows it without retaining a copy.
- Filtering and displayed warnings share inclusive rules, MediaNumeric validation,
  primary-only RAW+JPEG semantics and the photo guard. Selected cues use OR and
  intersect ordinary facets; no selected cue is neutral.
- Both preference paths and structural/source gates invalidate classification.
  Private matching consumes already revision-accepted evidence, while the public
  UI getter and asynchronous acceptance retain revision checks. All production
  shared-identity refresh paths were independently audited.
- Existing visible order, groups, current/selection and destructive-action flush
  stay authoritative. Matching adds no decodes, per-photo tasks or file writes.

The initial mask version improved repeat switches but retained a 148 ms cold
path. Reading observable preferences once outside the loop reduced first use to
53 ms. Both hypotheses and their raw runs are retained.

## Validation and provenance

Full Xcode/macOS 27 SDK, SwiftPM native backend, release optimization with existing
DEBUG test seams. One warmup and seven samples at 1k/10k/100k; fixture creation and
reference assertions are untimed. These are model-stage timings, not screen frames
or total folder-open speedups. Shipping packaging uses ordinary release flags.

- Full suite: 754 executed, 718 passed, 36 explicit skips, zero failures;
  all 35 HotkeyTests included. Required performance/file-safety checks: 75/75.
- Eight new contract tests cover all 16 cue subsets, unsupported-photo metadata,
  independent physical ratings, thresholds/enabled rules without remeasurement,
  arriving/stale evidence, same-ID replacement, sorting/facets/search, selection,
  partial burst groups, cache reuse and exactly two slot updates per accepted pair.
- Three opt-in speed methods pass, including populated clipping evidence and
  controlled arrivals. Two independent code/identity reviews found no remaining
  cue-cache findings.
- Concurrent UI/localization edits changed a compiler input during confirmation.
  A coherent temporary snapshot preserves that working state for reproducibility.
  The final snapshot includes the separately completed Grid fix. An initial
  snapshot omitted six XMP fixtures; that setup error was corrected before the
  final passing full suite. Failed attempts are retained, not counted as passes.

[Raw measurements and validation](Performance/2026-10-14/cue-filter/) include
source hashes, context, logs and every sample. The installed-build manifest records
signature, complete staged/archive/installed Contents equality, retained decisions,
media integrity and the running review app.

## Remaining limits

Visible/group/navigation projection still scales with matches. Clearing the last
cue exposes all 100k photos and took 68–94 ms across these processes; no improvement
is claimed there. Sustained dense-match arrivals, large surviving selections,
retained memory and physical interaction still need broader profiling. This does
not establish battery life, GPU/helper peak memory or universal RAW throughput.
AUD-06/AUD-28/AUD-29 retain that work in [the backlog](../BACKLOG.md).
