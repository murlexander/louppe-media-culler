| Workload | Count | Median ms | p95 ms | Change vs baseline |
|---|---:|---:|---:|---:|
| full_memory_hit_1000 | 1,000 | 2.342 | 2.460 | — |
| jpeg_source_decode_320px_os_cache_warm | 1 | 17.639 | 45.096 | — |
| jpeg_source_decode_4096px_os_cache_warm | 1 | 52.103 | 57.447 | — |
| thumbnail_disk_hit_16_including_pipeline_init | 16 | 10.510 | 12.412 | — |
| thumbnail_memory_hit_1000 | 1,000 | 2.430 | 2.956 | — |
| thumbnail_source_16_including_pipeline_init_and_disk_drain | 16 | 283.995 | 318.175 | — |
| already_cancelled_32_unique_thumbnails_including_disk_drain | 32 | 152.434 | 168.347 | — |
| same_revision_32_thumbnail_waiters_including_disk_drain | 32 | 19.178 | 19.382 | — |
| gallery.delay-after-full.backlog-0 | 1 | 0.000 | 0.000 | — |
| gallery.delay-after-full.backlog-128 | 129 | 549.453 | 565.942 | — |
| gallery.full-ready.backlog-0 | 1 | 42.228 | 52.047 | — |
| gallery.full-ready.backlog-128 | 129 | 46.376 | 54.220 | — |
| gallery.mirrored-publication.backlog-0 | 1 | 42.228 | 52.047 | — |
| gallery.mirrored-publication.backlog-128 | 129 | 595.830 | 617.393 | — |
| gallery.thumbnail-ready.backlog-0 | 1 | 18.157 | 19.001 | — |
| gallery.thumbnail-ready.backlog-128 | 129 | 595.830 | 617.393 | — |
| mirrored_gallery_backlog_0_with_init_drain_cleanup | 1 | 43.080 | 53.554 | — |
| mirrored_gallery_backlog_128_with_init_drain_cleanup | 129 | 606.488 | 629.299 | — |
| synthetic_raw_4_in_2_item_batches_dwell_0ms | 4 | 0.343 | 0.485 | — |
| synthetic_raw_4_in_2_item_batches_dwell_700ms | 4 | 1432.813 | 1459.025 | — |
