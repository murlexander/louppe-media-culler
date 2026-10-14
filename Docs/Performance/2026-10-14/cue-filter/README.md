# Cue-filter validation — 14 October 2026

before/ is the untouched-production baseline. after/ is the first mask hypothesis
(repeat switches improve but cold preference reads remain costly). final/ adds
one preference snapshot per classification. confirmation-snapshot/ independently
confirms metadata and measures populated clipping evidence and gated early pairs.
Each contains raw samples; context/source hashes identify exact inputs.

full-tests.log records the early concurrent Grid failure; snapshot-full.log also
records a missing XMP fixture copy. full-final.log is the corrected coherent
snapshot: 754 tests, 36 explicit skips, zero failures. safety.log passes 75/75. Failed compiler
attempts are retained separately and do not count as validation. Shipping release
uses ordinary flags; optimized XCTest keeps the existing DEBUG seams.

installed-review.json, quit.json, release.log and install.log record save-aware
review replacement, signatures, independent archive validation, full Contents
comparison and unchanged existing media/decisions. Other working chats were not
interrupted or messaged; their captured edits are preserved in the snapshot.
The full source snapshot/build cache remains under /private/tmp/louppe-cue-filter-20261014/.
