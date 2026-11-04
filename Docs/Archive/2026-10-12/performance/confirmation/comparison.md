| Workload | Count | Median ms | p95 ms | Change vs baseline |
|---|---:|---:|---:|---:|
| burst.input.full-production-shape | 100,000 | 126.175 | 140.419 | +0.5% |
| burst.input.metadata-only-hypothesis | 100,000 | 17.794 | 19.345 | -4.0% |
| groups.exact.pairs | 100,000 | 22.462 | 24.101 | -2.7% |
| groups.similar.equal | 100,000 | 70.169 | 72.917 | +1.4% |
| groups.similar.paired-random | 100,000 | 136.666 | 137.757 | -1.9% |
| groups.similar.random | 100,000 | 106.126 | 109.436 | +0.5% |
| reopen.durable-session | 1,000 | 21.706 | 23.629 | +4.8% |
| save.durable-sidecar-and-backup | 1,000 | 25.772 | 27.390 | +7.4% |
| scan.jpeg.warm-filesystem | 1,000 | 89.848 | 92.840 | +4.0% |
| full_memory_hit_1000 | 1,000 | 2.293 | 2.347 | -0.9% |
| jpeg_source_decode_320px_os_cache_warm | 1 | 17.049 | 17.580 | -0.1% |
| jpeg_source_decode_4096px_os_cache_warm | 1 | 41.898 | 62.802 | +3.2% |
| thumbnail_disk_hit_16_including_pipeline_init | 16 | 11.025 | 12.104 | -1.6% |
| thumbnail_memory_hit_1000 | 1,000 | 2.304 | 2.910 | +0.3% |
| thumbnail_source_16_including_pipeline_init_and_disk_drain | 16 | 277.345 | 278.651 | -0.3% |
| already_cancelled_32_unique_thumbnails_including_disk_drain | 32 | 148.112 | 159.268 | +1.0% |
| same_revision_32_thumbnail_waiters_including_disk_drain | 32 | 18.879 | 20.546 | +2.0% |
| mirrored_gallery_backlog_0_with_init_drain_cleanup | 1 | 57.287 | 84.726 | +59.7% |
| mirrored_gallery_backlog_128_with_init_drain_cleanup | 129 | 592.369 | 615.296 | -0.0% |
| synthetic_raw_4_in_2_item_batches_dwell_0ms | 4 | 0.302 | 0.328 | +5.0% |
| synthetic_raw_4_in_2_item_batches_dwell_700ms | 4 | 1430.490 | 1453.459 | -0.1% |
| json.encode.compact | 100,000 | 1110.869 | 1188.079 | +3.1% |
| json.encode.compact-sorted | 100,000 | 1185.423 | 1216.854 | +0.5% |
| json.encode.pretty-sorted | 100,000 | 1243.967 | 1281.988 | -0.7% |
| snapshot.detached-entry-build.unpaired | 100,000 | 13.871 | 14.307 | -6.7% |
| snapshot.main-capture.unpaired | 100,000 | 16.105 | 18.283 | -1.9% |
| metadata.colorLabel.ascending.production | 100,000 | 259.043 | 261.944 | +1.7% |
| metadata.colorLabel.ascending.stable-buckets | 100,000 | 41.794 | 44.514 | +18.5% |
| metadata.colorLabel.descending.production | 100,000 | 270.585 | 407.717 | +6.0% |
| metadata.colorLabel.descending.stable-buckets | 100,000 | 43.147 | 47.187 | +23.0% |
| metadata.decision.ascending.production | 100,000 | 180.277 | 183.004 | +1.3% |
| metadata.decision.ascending.stable-buckets | 100,000 | 45.773 | 66.122 | +23.3% |
| metadata.decision.descending.production | 100,000 | 178.139 | 181.802 | +3.6% |
| metadata.decision.descending.stable-buckets | 100,000 | 40.929 | 46.731 | +19.0% |
| metadata.starRating.ascending.production | 100,000 | 247.623 | 252.627 | +1.7% |
| metadata.starRating.ascending.stable-buckets | 100,000 | 41.836 | 42.403 | +21.9% |
| metadata.starRating.descending.production | 100,000 | 247.587 | 251.285 | +2.1% |
| metadata.starRating.descending.stable-buckets | 100,000 | 42.528 | 43.195 | +21.5% |
| pairing.distinct-stems.no-global-sort | 100,000 | 931.113 | 955.078 | -0.5% |
| pairing.distinct-stems.production | 100,000 | 1372.235 | 1493.706 | +1.6% |
| pairing.raw-jpeg.no-global-sort | 100,000 | 707.774 | 730.822 | -0.2% |
| pairing.raw-jpeg.production | 100,000 | 1178.404 | 1196.359 | +0.3% |
| filter.decision.projection-and-groups | 100,000 | 88.831 | 108.591 | +3.9% |
| filter.quality.switch-metadata-cue | 100,000 | 116.278 | 199.821 | +1.8% |
| navigation.100-steps | 100,000 | 3.838 | 4.449 | +3.6% |
| quality.coverage.unmeasured-read | 100,000 | 78.220 | 81.703 | -0.9% |
| review.rating.decision-sort | 100,000 | 170.945 | 171.468 | +1.0% |
| review.rating.default-sort | 100,000 | 0.024 | 0.029 | +0.9% |
| review.stars.star-sort | 100,000 | 132.006 | 147.345 | +2.4% |
| sort-menu.camera.full-store | 100,000 | 980.650 | 989.146 | +1.0% |
| sort-menu.camera.prepared-only-hypothesis | 100,000 | 710.606 | 780.152 | +0.0% |

Missing 75 baseline workloads; these were not compared.

Compare runs from the same machine/toolchain with similar system load. Small deltas need repeated runs.
