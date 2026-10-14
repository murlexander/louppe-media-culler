# Repeatable speed tests

Run from the canonical `louppe/app` repository:

```sh
./Tests/run_speed_tests.sh
python3 Tests/compare_speed_results.py /private/tmp/louppe-speed-results.XXXXXX
```

The runner prints the actual output directory. Set a destination to retain or
compare runs:

```sh
LOUPPE_SPEED_OUTPUT=/private/tmp/louppe-speed-before ./Tests/run_speed_tests.sh
LOUPPE_SPEED_OUTPUT=/private/tmp/louppe-speed-after ./Tests/run_speed_tests.sh
python3 Tests/compare_speed_results.py /private/tmp/louppe-speed-after \
  --baseline /private/tmp/louppe-speed-before
```

Use the same machine, toolchain, power conditions and similar system load.
Run again before treating a small difference as an improvement. The comparison
prints missing workloads and does not count them as passes or zero-duration work.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `LOUPPE_SPEED_SIZES` | `1000,10000,100000` | Comma-separated item counts, 100–100,000 |
| `LOUPPE_SPEED_REPETITIONS` | `7` | Measured repetitions, 3–30, after one warmup |
| `LOUPPE_SPEED_OUTPUT` | Unique `/private/tmp` directory | JSON, console log and provenance |
| `LOUPPE_SPEED_FILTER` | `LouppeSpeed` | XCTest name regular expression |
| `LOUPPE_SPEED_RAW_FILE` | Unset; RAW test skips | Local RAW copied into a disposable directory before decoding |

For a quick run:

```sh
LOUPPE_SPEED_SIZES=1000 LOUPPE_SPEED_REPETITIONS=3 ./Tests/run_speed_tests.sh
```

For a real RAW:

```sh
LOUPPE_SPEED_FILTER=LouppeSpeedRAWTests \
LOUPPE_SPEED_RAW_FILE=/path/to/photo.RAF ./Tests/run_speed_tests.sh
```

RAW runs read the supplied file, decode a disposable copy, then compare SHA-256
and the supplied file's identity. They never write beside the supplied file.
No private media or source filenames enter the JSON reports.

## Measurement contract

- Full Xcode, SwiftPM native backend, release optimization, sequential tests.
  `-Xswiftc -DDEBUG` retains the existing target's required test seams. These
  are optimized measurements with debug conditional code, not an untouched
  shipping executable. The runner records exact toolchain, source checksums,
  Git HEAD and working-copy state.
- One warmup, then independent monotonic-clock samples; JSON retains every
  sample, median, nearest-rank p95, minimum and maximum. With seven samples,
  p95 is the largest observation, not a precise population-tail estimate.
- Model fixture creation and equivalence assertions remain outside measured
  loops. Sort-menu preparation is untimed and both measured variants use the
  same ascending direction. Media workload labels explicitly include pipeline
  initialization/drain; those end-to-end cases also include small assertions
  and disposable cache cleanup.
- Source decode means bypassing Louppe's memory/disk cache. Filesystem and OS
  decoder/resource caches are warm. No global cache flush or cold-storage claim.
  Real scans use 100/1,000 generated JPEGs; 100k cases use synthetic metadata.
- Gallery backlog diagnostics use the real isolated pipeline and mirror the
  view's completion dependency. They do not measure a mounted SwiftUI frame.
  Task-start admission does not guarantee private queue order. JSON latency
  rows exclude warmup; printed `MEDIA_*` arrays include it as their first value.
- Numeric regressions are comparisons, not hard CI limits. Correctness,
  source integrity, complete pairing membership, ordering, persistence and
  cache coalescing remain assertions. Ordinary `swift test` skips speed tests.

## Coverage

| Suite | Measured work |
| --- | --- |
| Scan | Exact ordered pairing, redundant-sort candidate, decision/star/color sorting and finite-bucket candidate |
| Session | Real rating/star mutations, sort changes, filters/groups, quality coverage, navigation |
| Persistence | Frozen capture, detached entry build, complete JSON formatting/round-trip, burst input allocation, exact/similar group distributions |
| I/O | Real JPEG scan, durable sidecar **and verified backup**, saved decision reopen and original-byte checks |
| Media | JPEG source/disk/memory paths, coalesced fanout, cancelled work, Gallery backlog and RAW dwell floor |
| Cue filtering | Cold/warm metadata and populated clipping switches, selection/grouping, controlled accepted-pair projection |
| Quality resource | Actual SessionStore evidence accumulation with Select All; process CPU and wall samples, linear probes and batched publications asserted |
| Optional RAW | Apple Default preview and histogram on a copied camera RAW, with source integrity checks |

Independent candidate implementations remain in tests for equivalence checks.
Production rows now exercise cached finite sorting, physical-pair preparation,
metadata-only burst capture, cancellable membership, compact snapshot encoding,
mounted Gallery publication and background RAW requests. Keep the adversarial
canonical-order guard: arbitrary input cannot be bucketed in raw array order.
The legacy mirrored Gallery rows retain the former await dependency for baseline
comparison; production-mounted rows measure realized surface/loading settlement,
not physical screen frames. New rows without saved baselines are measurements,
not before/after claims.

The first investigation and implementation acceptance list are in
[the performance review](PERFORMANCE_REVIEW_2026-10-12.md). This suite complements
`run_performance_checks.sh`; it does not replace its 75 safety checks or native
UI, volume/provider, cancellation, and memory-budget acceptance tests.

The [implemented results](PERFORMANCE_IMPLEMENTATION_2026-10-12.md) retain actual
production comparisons, final acceptance and remaining limits.

Quality-resource measurements inject immediate evidence and disable rest to isolate
scheduler/bookkeeping cost; they include task admission and the awaiting harness.
They exclude decode, fixture setup, UI rendering and the production duty cycle.
The separate [resource review](QUALITY_CUE_RESOURCES_2026-10-12.md) documents
adaptive-rest tests, rejected pixel shortcuts and retained CPU experiments.

The [14 October cue-filter follow-up](QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md)
retains repeated switch, first-use and controlled arrival results. Clipping arrival
rows include 1 ms polling and the next-admission barrier; they exclude decode/rest.
