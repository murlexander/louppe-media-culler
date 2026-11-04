# Large-folder comparisons — 22 October 2026

One warmup + three measured samples, release optimization with DEBUG test seams. Medians in milliseconds. Warm local storage; visible matching-revision pixel publication, not physical frames.

## Mounted navigation (10,000 generated JPEGs)

| Surface / destination | Original median | Current median | Original p95 | Current p95 |
| --- | ---: | ---: | ---: | ---: |
| grid / middle | 451.142 | 74.597 | 508.831 | 80.219 |
| grid / tail | 961.420 | 55.991 | 969.991 | 57.056 |
| grid / reverse | 764.949 | 71.952 | 834.810 | 73.084 |
| grid / head | 853.370 | 48.021 | 890.973 | 52.502 |
| browser / middle | 266.748 | 11.013 | 275.645 | 12.547 |
| browser / tail | 611.240 | 11.786 | 626.003 | 13.222 |
| browser / reverse | 465.524 | 12.658 | 490.657 | 12.792 |
| browser / head | 572.761 | 9.660 | 700.161 | 12.777 |

Fresh-process runs use matching view modes and the same harness except native-only host metrics. Sampling starts explicitly and excludes the synchronous wheel correctness gate. Main-actor gaps can still include contiguous synchronous benchmark cycles; they are not per-input frame latency.

## Opening through RootView

| Fixture / barrier | Original median | Current median |
| --- | ---: | ---: |
| jpeg-generated, 1000 displayed items / first-useful-pixels | 356.141 | 229.031 |
| jpeg-generated, 1000 displayed items / fully-ready-state | 356.146 | 490.670 |
| jpeg-generated, 10000 displayed items / first-useful-pixels | 1535.515 | 1309.845 |
| jpeg-generated, 10000 displayed items / fully-ready-state | 1535.523 | 2023.297 |
| raw-jpeg-clones, 2000 displayed items / first-useful-pixels | 908.399 | 413.925 |
| raw-jpeg-clones, 2000 displayed items / fully-ready-state | 908.410 | 1040.473 |
| raw-jpeg-clones, 20000 displayed items / first-useful-pixels | 6729.332 | 2967.319 |
| raw-jpeg-clones, 20000 displayed items / fully-ready-state | 6729.340 | 8173.880 |

Separate is the fresh-session default: 10,000 RAW+JPEG pairs are 20,000 displayed physical files. RAWs are APFS clones of one disposable camera RAF. Originals were digest/identity checked. These are not independent captures or SD-card results. The completed original opening baseline predates the added RSS/poll probes; its instrumented rerun stalled in RawCamera and yields no resource baseline. Candidate first-use samples include those probes. Full readiness is slower despite earlier pixels; no blanket scan-speedup claim.

## Resource limits and unresolved evidence

Fresh-process 10k mounted peak process RSS: original Grid526.6MiB / Browser589.9MiB; current Grid340.8MiB / Browser342.7MiB. After surface teardown and disk drain:521.7→333.6MiB. Current realized/retained hosts: Grid20/35, Browser8/9. RSS includes caches, runtime and image ownership; it is not an isolated cache-budget measurement.

Maximum sampled navigation scheduling gaps remained952→916ms in Grid and693→399ms in Browser under contiguous harness cycles. Candidate opening poll gaps reached median maxima304ms at10kJPEG and384ms at20kRAW+JPEG. Native window/layout work and the harness are included; these do not establish smooth physical frames.

The combined runner completed ten tests before signal11 in RawCamera during additional RAW stage profiling. The six-test isolated JPEG/opening/scan/session rerun passed. The completed original mounted rerun passed. The separate original RAW resource rerun stalled. Do not count either failed runner as a pass. See each directory status/context and the sanitized crash stack.
