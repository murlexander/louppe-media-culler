#!/bin/bash
set -euo pipefail
experiment_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
    -swift-version 6 -O -parse-as-library \
    -module-cache-path "$experiment_dir/module-cache" \
    "$experiment_dir/Experiment.swift" \
    -o "$experiment_dir/quality-resource-experiment"
"$experiment_dir/quality-resource-experiment" > "$experiment_dir/results-rerun.json"
python3 "$experiment_dir/summarize.py" "$experiment_dir/results-rerun.json"
