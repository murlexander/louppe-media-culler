#!/usr/bin/env python3
"""Snapshot production pixel work and generate one isolated experiment.

This generator does not compile, launch Louppe, or execute benchmarks.
"""
import hashlib
import json
from pathlib import Path
import sys

repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/Users/developer/Documents/code/louppe/app')
out = Path(__file__).resolve().parent
source_path = repo / 'Sources/Louppe/HistogramPipeline.swift'
source_bytes = source_path.read_bytes()
source = source_bytes.decode('utf-8')

def region(start, end):
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish].rstrip() + '\n', begin, finish

histogram, histogram_start, histogram_end = region('struct HistogramAnalysis:', '/// Deterministic 8-bit sRGB')
processor, processor_start, processor_end = region('enum ClippingWarningProcessor {', '/// Bounded, coalesced histogram work.')
original_branch = '''                let value = luminance(
                    red: straight(bytes[offset], alpha: alpha),
                    green: straight(bytes[offset + 1], alpha: alpha),
                    blue: straight(bytes[offset + 2], alpha: alpha)
                )'''
candidate_branch = '''                let value: UInt8
                if alpha == 255 {
                    value = luminance(
                        red: bytes[offset],
                        green: bytes[offset + 1],
                        blue: bytes[offset + 2]
                    )
                } else {
                    value = luminance(
                        red: straight(bytes[offset], alpha: alpha),
                        green: straight(bytes[offset + 1], alpha: alpha),
                        blue: straight(bytes[offset + 2], alpha: alpha)
                    )
                }'''
if processor.count(original_branch) != 1:
    raise SystemExit('Production analyze shape changed; inspect it before regenerating.')
baseline = processor.replace('enum ClippingWarningProcessor {', 'enum BaselineClippingWarningProcessor {', 1)
candidate = processor.replace('enum ClippingWarningProcessor {', 'enum OpaqueFastClippingWarningProcessor {', 1).replace(original_branch, candidate_branch, 1)

session_path = repo / 'Sources/Louppe/SessionStore.swift'
quality_path = repo / 'Sources/Louppe/QualityCueAnalysis.swift'
session_bytes = session_path.read_bytes()
quality_bytes = quality_path.read_bytes()
provenance = {
    'histogramSourcePath': str(source_path),
    'histogramSourceSHA256': hashlib.sha256(source_bytes).hexdigest(),
    'histogramTypeSHA256': hashlib.sha256(histogram.encode()).hexdigest(),
    'processorSHA256': hashlib.sha256(processor.encode()).hexdigest(),
    'histogramTypeStartLine': str(source[:histogram_start].count('\n') + 1),
    'processorStartLine': str(source[:processor_start].count('\n') + 1),
    'sessionStoreSourceSHA256': hashlib.sha256(session_bytes).hexdigest(),
    'qualityCueSourceSHA256': hashlib.sha256(quality_bytes).hexdigest(),
    'candidateChange': 'Only analyze: alpha == 255 reads RGB directly; every other operation is unchanged.',
    'dictionaryPayload': 'SyntheticEvidence preserves evidence scalar fields; SyntheticRevision approximates the real revision payload. This is a Combine/COW mechanism experiment, not SessionStore.'
}
(out / 'provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
(out / 'ProductionSnapshot.swift.txt').write_text(histogram + '\n' + processor)
(out / 'SessionStoreSnapshot.swift.txt').write_bytes(session_bytes)
(out / 'QualityCueSnapshot.swift.txt').write_bytes(quality_bytes)
swift_provenance = '\n'.join('        ' + json.dumps(key) + ': ' + json.dumps(value) + ',' for key, value in sorted(provenance.items()))
template = (out / 'ExperimentTemplate.swift.txt').read_text()
result = template.replace('__PRODUCTION_HISTOGRAM__', histogram).replace('__BASELINE_PROCESSOR__', baseline).replace('__CANDIDATE_PROCESSOR__', candidate).replace('__PROVENANCE__', swift_provenance)
(out / 'Experiment.swift').write_text(result)
print(str(out / 'Experiment.swift'))
