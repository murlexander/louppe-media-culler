#!/usr/bin/env python3
"""Print statistical speed results, optionally against another local run."""
import argparse
import json
from pathlib import Path


def read_rows(directory):
    rows = {}
    for file in sorted(directory.glob("*.json")):
        document = json.loads(file.read_text())
        if not isinstance(document, dict) or document.get("schemaVersion") != 1 or "rows" not in document:
            continue
        for row in document["rows"]:
            key = (document["suite"], row["name"], row["count"])
            if key in rows:
                raise ValueError(f"Duplicate result: {key}")
            rows[key] = row
    if not rows:
        raise ValueError(f"No speed reports found in {directory}")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    current = read_rows(args.results)
    baseline = read_rows(args.baseline) if args.baseline else {}
    print("| Workload | Count | Median ms | p95 ms | Change vs baseline |")
    print("|---|---:|---:|---:|---:|")
    for key, row in sorted(current.items()):
        old = baseline.get(key)
        change = f"{(row['medianMS'] / old['medianMS'] - 1) * 100:+.1f}%" if old and old["medianMS"] > 0 else "—"
        print(f"| {key[1]} | {key[2]:,} | {row['medianMS']:.3f} | {row['p95MS']:.3f} | {change} |")
    if baseline:
        missing = set(baseline) - set(current)
        if missing:
            print(f"\nMissing {len(missing)} baseline workloads; these were not compared.")
        print("\nCompare runs from the same machine/toolchain with similar system load. Small deltas need repeated runs.")


if __name__ == "__main__":
    main()
