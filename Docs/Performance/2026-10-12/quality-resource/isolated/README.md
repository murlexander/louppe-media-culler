# Quality cue resource experiments — 12 October 2026

Private mutable evidence storage is strongly supported by this isolated test. The opaque-pixel branch should be rejected as a general histogram change: its opaque improvement comes with mixed/partial-alpha regressions. Production code was not modified by this experiment.

## Histogram branch

The baseline is the exact extracted production `HistogramAnalysis` and complete `ClippingWarningProcessor`. The candidate changes only `analyze`: when alpha is 255, it reads RGB directly; otherwise it retains the production unpremultiplication formula. Both variants include the same production CGContext conversion. Four synthetic 1,024 × 1,024 premultiplied sRGB images exercise opaque, mixed, partial and transparent alpha, luminance thresholds and colored pixels.

| Fixture | Baseline wall, ms | Candidate wall, ms | Wall change | Baseline CPU, ms | Candidate CPU, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| opaque | 3.851 | 2.496 | -35.2% | 3.837 | 2.496 |
| mixed | 3.766 | 4.245 | +12.7% | 3.754 | 4.219 |
| partial | 5.003 | 5.495 | +9.8% | 4.994 | 5.478 |
| transparent | 0.688 | 0.692 | +0.5% | 0.688 | 0.691 |

Every full `HistogramAnalysis` matched: all 256 bins, sample/shadow/highlight counts, width and height. Expected alpha coverage also passed. Despite exact results, mixed alpha took 12.7% more wall time and partial alpha 9.8% more. Do not adopt this branch across supported images from these results. A separately established opaque-only route would require its own validation and representative photo fixtures.

## Growing evidence dictionary

All variants insert the same prebuilt entries into an initially empty dictionary, without capacity reservation. Synthetic evidence preserves count/dimension/source fields and approximates revision payload. This is a Combine/storage mechanism experiment, not a measurement of `SessionStore` or SwiftUI rendering. Complete final dictionaries were compared outside measurement.

| Entries | Variant | Wall median, ms | Process CPU median, ms |
| ---: | --- | ---: | ---: |
| 1,000 | published.unobserved | 12.662 | 12.502 |
| 1,000 | published.observed | 13.004 | 12.950 |
| 1,000 | private.publish-every-item | 0.269 | 0.270 |
| 1,000 | private.publish-every-two | 0.213 | 0.214 |
| 2,000 | published.unobserved | 49.197 | 48.811 |
| 2,000 | published.observed | 49.803 | 49.543 |
| 2,000 | private.publish-every-item | 0.534 | 0.534 |
| 2,000 | private.publish-every-two | 0.417 | 0.417 |
| 10,000 | published.unobserved | 1238.531 | 1230.234 |
| 10,000 | published.observed | 1234.711 | 1225.737 |
| 10,000 | private.publish-every-item | 3.011 | 3.003 |
| 10,000 | private.publish-every-two | 2.135 | 2.136 |

At 10,000 entries, observed `@Published` storage took 1,234.711 ms wall / 1,225.737 ms process CPU. Private storage still publishing once per item took 3.011 / 3.003 ms; publishing once per two items took 2.135 / 2.136 ms. Unobserved `@Published` was similarly slow, supporting storage-copy behavior as the dominant mechanism rather than observer work. No allocation profiler counted copies, so the exact copy mechanism remains inferred.

The measured notification counts matched the requested operations: observed `@Published` sent one object and one dictionary event per insertion; private per-item sent one object event per insertion; private batch-of-two sent half as many object events. Private storage alone accounts for most of this isolated gain; batching adds a smaller gain. Integration must preserve invalidation, generation/revision checks, counts, paused state, current item/selection, and visibility refresh behavior.

## Method and reproduction

The executable ran sequentially, with two warmups and seven retained samples per variant. Histogram order alternated per iteration; dictionary order rotated. Fixture construction and equivalence checks were outside timing. There are seven correctness checks and 140 raw samples in [results.json](results.json).

`getrusage(RUSAGE_SELF)` measured process user + system CPU; monotonic uptime measured wall time. CPU includes library worker threads within this process. Neither measurement establishes whole-system energy, GPU use, battery drain, thermal behavior, real UI responsiveness, or RAW decoding cost. Real photographs, ImageIO/CIRAWFilter decoding, file I/O, scheduler pacing and interactive foreground contention were not measured.

Successful build: Swift 6 language mode, `-O`, `-parse-as-library`, full Xcode and an explicit temporary module cache. The explicit `@MainActor ObservableObject` conformance in the private-storage fixture compiles cleanly. Compiler: Apple Swift 6.4; target arm64; macOS 27.0.1 (26A434); SDK 27.0. Detailed hardware `sysctl` queries were sandbox-blocked and are not reported.

The exact successful commands are in [commands.txt](commands.txt). To reproduce the frozen experiment after copying this directory, run `bash run.sh`; it writes `results-rerun.json`, preserving the retained evidence. [summarize.py](summarize.py) derives medians from raw samples. The self-contained [Experiment.swift](Experiment.swift) is sufficient to compile; the generator/template and source snapshots document construction. Regenerate only as a separate source-version experiment.

Source provenance:

- Full HistogramPipeline SHA-256: `e774458040fe5e5d6ee4b41d3c724c9b30f2bc6335dcfca9a6faaab1e7954194`.
- Extracted processor SHA-256: `19cefa98844dc98ef2f492bc0b4edeac795166ce595f1fb82123f6177d6512d5`.
- [provenance.json](provenance.json) records original paths, source/type hashes and extraction lines.
- [execution_metadata.json](execution_metadata.json) binds retained source/result files to hashes and records flags.
- [ProductionSnapshot.swift.txt](ProductionSnapshot.swift.txt), [QualityCueSnapshot.swift.txt](QualityCueSnapshot.swift.txt), and [SessionStoreRelevantSnapshot.swift.txt](SessionStoreRelevantSnapshot.swift.txt) retain the audited source evidence.
