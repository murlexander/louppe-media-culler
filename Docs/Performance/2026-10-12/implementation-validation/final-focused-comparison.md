| Workload | Count | Median ms | p95 ms | Change vs baseline |
|---|---:|---:|---:|---:|
| snapshot.detached-entry-build.unpaired | 100,000 | 15.380 | 17.109 | — |
| snapshot.main-capture.unpaired | 100,000 | 17.808 | 18.942 | — |
| metadata.colorLabel.ascending.production | 100,000 | 38.593 | 39.784 | — |
| metadata.colorLabel.ascending.stable-buckets | 100,000 | 37.010 | 38.726 | — |
| metadata.colorLabel.descending.production | 100,000 | 39.055 | 39.961 | — |
| metadata.colorLabel.descending.stable-buckets | 100,000 | 37.258 | 39.806 | — |
| metadata.decision.ascending.production | 100,000 | 37.690 | 38.151 | — |
| metadata.decision.ascending.stable-buckets | 100,000 | 37.420 | 38.821 | — |
| metadata.decision.descending.production | 100,000 | 38.426 | 39.135 | — |
| metadata.decision.descending.stable-buckets | 100,000 | 36.243 | 37.417 | — |
| metadata.starRating.ascending.production | 100,000 | 37.306 | 38.247 | — |
| metadata.starRating.ascending.stable-buckets | 100,000 | 38.602 | 39.975 | — |
| metadata.starRating.descending.production | 100,000 | 38.107 | 39.090 | — |
| metadata.starRating.descending.stable-buckets | 100,000 | 36.967 | 38.807 | — |
| pairing.distinct-stems.no-global-sort | 100,000 | 934.984 | 981.879 | — |
| pairing.distinct-stems.physical-pair-preparation.production | 100,000 | 940.774 | 949.452 | — |
| pairing.distinct-stems.production | 100,000 | 718.506 | 741.504 | — |
| pairing.raw-jpeg.no-global-sort | 100,000 | 714.370 | 795.659 | — |
| pairing.raw-jpeg.physical-pair-preparation.production | 100,000 | 960.282 | 1252.070 | — |
| pairing.raw-jpeg.production | 100,000 | 563.237 | 586.316 | — |
| filter.decision.projection-and-groups | 100,000 | 85.511 | 85.869 | -0.4% |
| filter.quality.switch-metadata-cue | 100,000 | 140.212 | 199.072 | +25.1% |
| navigation.100-steps | 100,000 | 4.172 | 4.305 | +7.1% |
| quality.coverage.unmeasured-read | 100,000 | 0.009 | 0.012 | -100.0% |
| review.rating.decision-sort | 100,000 | 119.837 | 121.736 | -26.7% |
| review.rating.default-sort | 100,000 | 0.025 | 0.041 | +3.8% |
| review.stars.star-sort | 100,000 | 113.113 | 131.829 | -8.6% |
| sort-menu.camera.full-store | 100,000 | 705.699 | 737.322 | -24.4% |
| sort-menu.camera.prepared-only-hypothesis | 100,000 | 715.892 | 785.329 | -0.5% |

Missing 24 baseline workloads; these were not compared.

Compare runs from the same machine/toolchain with similar system load. Small deltas need repeated runs.
