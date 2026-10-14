#!/usr/bin/env python3
"""Summarize the retained raw observations without running a benchmark."""
import json
from collections import defaultdict
from pathlib import Path
from statistics import median
import sys

source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / 'results.json'
report = json.loads(source.read_text())
groups = defaultdict(list)
for sample in report['samples']:
    groups[(sample['suite'], sample['variant'], sample['count'])].append(sample)

print('| Suite | Variant | Count | Samples | Wall median, ms | Process CPU median, ms |')
print('| --- | --- | ---: | ---: | ---: | ---: |')
for (suite, variant, count), samples in groups.items():
    wall = median(s['wallMilliseconds'] for s in samples)
    cpu = median(s['processCPUMilliseconds'] for s in samples)
    print(f'| {suite} | {variant} | {count:,} | {len(samples)} | {wall:.3f} | {cpu:.3f} |')
print(f'\nCorrectness checks: {len(report["correctnessChecks"])}; retained samples: {len(report["samples"])}.')
