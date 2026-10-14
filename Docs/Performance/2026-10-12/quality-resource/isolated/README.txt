Completed isolated Swift 6 release-mode run. Retained results are in results.json;
README.md summarizes the evidence. Do not run concurrently with app benchmarks.

Generate an exact source snapshot (no build or benchmark):
  python3 /private/tmp/louppe-quality-resource/generate.py /Users/alexander_markin/Documents/code/louppe/app

Compile and execute after the benchmark lane is free:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -swift-version 6 -O -parse-as-library -module-cache-path /private/tmp/louppe-quality-resource/module-cache /private/tmp/louppe-quality-resource/Experiment.swift -o /private/tmp/louppe-quality-resource/quality-resource-experiment
  /private/tmp/louppe-quality-resource/quality-resource-experiment > /private/tmp/louppe-quality-resource/results.json

Default: two warmups and seven raw measurements per variant. Set
LOUPPE_RESOURCE_SAMPLES=3..30 to change measured repetitions. Use Swift 6 and -O consistently.
The output includes source hashes/provenance, full-equivalence checks,
wall time, process user+system CPU time, checksums, and publication counts.
The successful recorded compilation used -swift-version 6 -O with an explicit
temporary module cache. PrivateEvidence declares an @MainActor ObservableObject
conformance, satisfying Swift 6 isolation checking without warnings.

The candidate changes only analyze's alpha==255 RGB conversion. Baseline and
candidate both retain the exact production CGContext buffer conversion,
luminance coefficients, thresholds, bins, and partial-alpha formula.

The dictionary experiment tests a Combine/COW mechanism with synthetic evidence.
It includes private per-item publication to distinguish storage-copy behavior
from notification batching. It does not replicate SessionStore, SwiftUI, or its
real revision payload byte for byte. No RAW decode or whole-system energy claim.

Saved source snapshots bind this experiment to the recorded source versions.
Do not regenerate silently after changing production; save separate results per
source hash. An isolated win is a hypothesis until integration correctness and
the actual app's foreground/background responsiveness are verified.
