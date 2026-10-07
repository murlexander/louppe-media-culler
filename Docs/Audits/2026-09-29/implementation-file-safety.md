# File safety audit implementation — 2026-09-29

Canonical checkout: `/Users/alexander_markin/Documents/code/louppe/app`. Implemented FS-1, FS-2, FS-3, FS-4, FS-5, and FS-PERF-1 from `Docs/Audits/2026-09-29/file-safety.md`. Existing edits were preserved; no commits, branches, pushes, installation, or compatibility-folder source edits. The coordinator owned SessionStore, Models, docs/changelog, XMP, packaging, and integration.

## Files changed by this subtask

- `Sources/Louppe/ExportWorker.swift`: planner rejection/cancellation and suffix reservation optimization; Copy planning cancellation result.
- `Sources/Louppe/SourceOrganization.swift`: scanner-visible container validation, generated folder sanitization, existing folder flag checks.
- `Sources/Louppe/SourceOrganizationWorker.swift`: folder name and actual hidden/package flag checks during directory preparation, including raced EEXIST directories.
- `Sources/Louppe/FileOperationJournal.swift`: generated-partial rollback, retired-XMP cleanup recovery, journal-specific regular-file checks, nonblocking exact comparison opener.
- `Sources/Louppe/DurableFileIO.swift`: only added `O_NONBLOCK` to `syncFile` opener. This file was then released to root for the standalone XMP BoundDirectory extension. Its other current changes belong to root.
- `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift`: eleven focused XCTest methods with real disposable I/O and explicit recorded/unrecorded/replaced-file variants. No timing assertions.

## Implemented behavior and preserved contracts

### FS-1 — internally conflicting media/XMP family filenames

`ExportWorker.makePlan` rejects internally equivalent normalized family names before probes, journaling, or media I/O: a shared suffix cannot separate them. XMPSidecarResolver still groups the case-sensitive PHOTO.JPG/PHOTO.jpg family; the planner returns an actionable error without splitting or partially exporting it.

Task/closure cancellation is checked while grouping, processing families, and retrying suffixes. Copy passes CancelFlag; canceled planning returns its reason, zero failures, and no journal/recovery failure. Overflow is refused.

Regression methods: `testEquivalentNamesWithinXMPFamilyFailBeforeDestinationProbes`, `testCancellationDuringCollisionSearchStopsCopyBeforeJournalActivation`.

### FS-PERF-1 — repeated basename planning

Suffixes are cached by the complete sorted normalized unsuffixed family set. A JPEG-only family may keep its original name after a RAW-only collision suffixed a RAW+JPEG family. Reservations precede exact URLs/probes; external occupancy, exclusive publication, and bound destination identity checks remain.

Regression methods: `testRepeatedBasenamesNeedOneDestinationProbePerFile` (800 files, exactly 800 entry probes), `testSuffixCachePreservesWholeFamilyAndAlreadySuffixedNames` (RAW-only external collision, differing family composition, existing numeric suffixes, final target uniqueness, existing bytes unchanged).

Only repeated identical families benefit. Large existing suffix sets or overlapping nonidentical families still need cancellable search; no timing guarantee is claimed.

### FS-2 — organized originals excluded by scanner traversal

Containers beginning with `.` or recognized package/bundle extensions are refused. UTType lookup must be directory-constrained: unrestricted `.app` resolves a regular-file type here. Generated camera/lens/origin/etc names retain metadata text with a leading underscore for hidden names or trailing underscore for packages.

Planning rejects hidden/package directories; the worker rechecks names and actual flags before moving originals, including mkdir EEXIST races. Source-root and exact-path semantics remain unchanged.

Regression methods: `testOrganizationRejectsHiddenAndPackageContainers` (.Hidden, Photos.app, .bundle, .photoslibrary, .framework), `testGeneratedOrganizationFoldersRemainScannableAndUndoable` (.Camera, Photos.app, Photos.photoslibrary; actual organize, scan count, undo, original bytes), `testOrganizationRefusesFinderHiddenFolderBeforeAndAfterPreview` (UF_HIDDEN flag in a normally named container).

### FS-3 — owned generated partial blocks Move rollback

Rollback removes a `.started` generated artifact only when stable identity matches its durable inode checkpoint, through two-path quarantine cleanup. The incomplete packet need not match the final digest; `.staged`/`.completed` must. Missing ownership, replacement, multiple candidates, or invalid staged content stay preserved/unresolved.

Recovery restores media before generated cleanup. Successful retries find no active operation; checkpointed quarantine transfers are recoverable. Before any identity checkpoint, ownership cannot be inferred and recovery stays unresolved.

Regression method: `testGeneratedMovePartialRecoveryRemovesOnlyRecordedInode`, with recorded incomplete, recorded complete, cleanup-quarantined, staged complete, malformed staged partial, unrecorded, and replaced inode variants. Original media bytes/location and unrelated replacement bytes are asserted.

### FS-4 — retired XMP cleanup interrupted at quarantine name

Completed-family recovery verifies the single retired packet's identity and original digest at either reserved location, then resumes two-path cleanup. Source-plus-candidate, dual candidates, or replacement stays unresolved; neither candidate means cleanup completed. Media and merged XMP remain intact.

Regression method: `testCompletedXMPRetirementRecoversEveryCleanupLocation`, with target, quarantine, already unlinked, replacement, and dual-candidate variants; successful recovery retry is idempotent.

### FS-5 — FIFO journal/read boundary can block indefinitely

Journal creation/checkpoints and existing plan entries require S_IFREG. FIFO/directory/symlink media cannot reach recovery mutation. Exact comparison and DurableFileIO.syncFile open with O_NONBLOCK before fstat, preventing FIFO waits.

`FileOperationJournal.captureIdentity`, generic capture, `SessionPersistence.SourceFolderIdentity.capture`, and bound-directory callers retain directory support. Only journal media/recovery entries require regular files.

Regression methods: `testJournalRejectsNonregularMediaWithoutChangingFolderIdentityCapture` (directory API remains valid; FIFO/directory/symlink starts rejected; comparison false and sync throws promptly), `testMalformedFIFOJournalReturnsUnresolvedWithoutReadingTheFIFO` (forged durable plan with FIFO source; generated copy preserved, destination unpublished).

## Original audit probes rerun against updated actual Debug module

Linker script: `/private/tmp/louppe-fixes-2026-09-29/compile-file-safety.py`.
Probe source: `/private/tmp/louppe-fixes-2026-09-29/file-safety-harness.swift`, adapted from the original audit harness only to catch newly expected errors, clean disposable fixtures, and count real lstat destination probes. Each process is bounded with a 30-second subprocess timeout.

- Collision: one two-member `publish` XMP family; planner returns equivalent-destination-name error promptly instead of looping.
- Generated partial: unresolved operations/files 0; removed partial copies 1; owned partial absent.
- Retired packet quarantine: unresolved operations/files 0; quarantine absent.
- FIFO: rejected before operation starts; no hang.
- Hidden `.Hidden` and package `Photos.app`: rejected before organization.
- Scaling: successful complete plans at every count below, with exactly one destination probe per file.

| Files | Original Debug seconds | Updated Debug seconds | Updated filesystem probes |
| ---: | ---: | ---: | ---: |
| 100 | 0.127 | 0.004662 | 100 |
| 200 | 0.508 | 0.008400 | 200 |
| 400 | 2.131 | 0.017405 | 400 |
| 800 | 8.725 | 0.035293 | 800 |

These are local diagnostic measurements, not test thresholds. The original empty-destination one-file family algorithm performs n(n+1)/2 probes by code inspection (320,400 at n=800); the updated n count was instrumented and measured. The 800-file time improved approximately 247× on this run.

Evidence: `/private/tmp/louppe-fixes-2026-09-29/file-safety-probe-collision.log`, `file-safety-probe-recovery.log`, `file-safety-probe-retirement.log`, `file-safety-probe-fifo.log`, `file-safety-probe-hidden-.Hidden.log`, `file-safety-probe-hidden-Photos.app.log`, `file-safety-probe-scaling.log`.

## Test execution status

Passed using full Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) and the unique isolated scratch `/private/tmp/louppe-fixes-2026-09-29/file-safety-build`:

1. `swift test --disable-keychain --scratch-path /private/tmp/louppe-fixes-2026-09-29/file-safety-build --filter FileSafetyAuditRegressionTests`: **11 tests, 0 failures**, 1.077 seconds. Log: `/private/tmp/louppe-fixes-2026-09-29/file-safety-focused-tests.log`.
2. `swift test --disable-keychain --scratch-path /private/tmp/louppe-fixes-2026-09-29/file-safety-build --filter 'ExportWorkerSafetyTests|FileOperationJournalTests|SourceOrganizationTests|XMPPhase7Tests|DurableFileIOTests|MultiDestinationExportTests|CleanUpWorkerSafetyTests|RecoveryGatingTests|FolderScannerFilenamePolicyTests'`: **141 tests, 0 failures**, 4.070 seconds. Log: `/private/tmp/louppe-fixes-2026-09-29/file-safety-adjacent-tests.log`.
3. Relinked original probes after both passing test runs, then reran all modes against that final current app module. Every process exited 0 promptly and behaved as recorded above; compile log `/private/tmp/louppe-fixes-2026-09-29/file-safety-probe-compile.log`.
4. `git diff --check` passed for this subtask's source/test files.

Total focused validation: **152 passing tests** plus the original seven probe executions. No machine-sensitive latency threshold was added to tests.

## Review entry points

One-based lines as of 29 September in the canonical app checkout:

| Finding | Source entry point | Focused regression entry |
| --- | --- | --- |
| FS-1 | `Sources/Louppe/ExportWorker.swift:274` (PlanningError), `:292` (planner), `:533` (Copy cancellation result) | `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift:8`, `:90` |
| FS-PERF-1 | `Sources/Louppe/ExportWorker.swift:310` (whole-family next suffix), `:387` (cache start), `:399` (reserved-name shortcut) | `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift:48`, `:67` |
| FS-2 | `Sources/Louppe/SourceOrganization.swift:1080` (visibility), `:1168` (generated names), `:1250` (existing folder flags); `Sources/Louppe/SourceOrganizationWorker.swift:207`, `:247` | `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift:125`, `:143`, `:184` |
| FS-3 | `Sources/Louppe/FileOperationJournal.swift:1047` (rollback) | `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift:213` |
| FS-4 | `Sources/Louppe/FileOperationJournal.swift:1302` (owned retirement candidate) | `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift:266` |
| FS-5 | `Sources/Louppe/FileOperationJournal.swift:329`, `:533`, `:2132`, `:2549`, `:2765`; `Sources/Louppe/DurableFileIO.swift:532` | `Tests/LouppeTests/FileSafetyAuditRegressionTests.swift:325`, `:349` |

## Remaining verification limits

The coordinator owns strict concurrency, full-suite, package, and launch checks. This subtask used no GUI/install, live-process crash, or real disk-full fault. Recovery tests use authentic durable checkpoints. Uncheckpointed generated files stay preserved/unresolved; names/partial bytes cannot prove ownership, and tests cover refusal. Preview package recognition uses macOS type registration; workers recheck actual flags before moves. Source identity and exact-path contracts are unchanged.