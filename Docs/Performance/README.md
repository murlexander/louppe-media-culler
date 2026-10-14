# Performance evidence

Dated folders retain measurements, failed attempts and validation records.
Source digest manifests with `schema: source-sha256-v1` use a `files` array of
`path`/`sha256` records. The explicit fields preserve every original digest while
avoiding credential-scanner false positives caused by filenames containing
Security or SafeStringAPIs being interpreted as secret-key assignments.
Historical timings and digests are unchanged. Other retained JSON follows the
format recorded by its original runner.
