# Louppe audit: file mutations, export planning, durability and crash recovery

Pre-fix findings from 29 September. Current work: [BACKLOG.md](../../../BACKLOG.md#audit-follow-ups).

Read-only audit of the canonical working tree on 2026-09-29. Disposable experiments used `/private/tmp/louppe-audit-2026-09-29` and linked freshly built testable Louppe/XMPBridge code. The coordinator owns full-suite, performance-script, and package checks.

## Confirmed findings

### FS-1 — P1: One XMP family can make export planning loop forever

Location: `Sources/Louppe/ExportWorker.swift:325-361`, `:432`; supporting comparison at `:2332-2337`.

Trigger: Open media on a case-sensitive filesystem containing the same exact stem with case-variant extensions, e.g. `PHOTO.JPG` and `PHOTO.jpg`. Select both and enable Include XMP sidecars in ordinary Copy/Move or multi-destination Copy. The production sidecar resolver legitimately groups those two distinct physical files into one family: exact stems match, metadata can match, and case-sensitive extension names differ. `XMPExportPreparedPlan.familyByMediaPath` sends both to the same export group.

Bug: `makePlan` applies one common numeric suffix to every family member, but folds every resulting filename case-insensitively and diacritic-insensitively before testing distinctness. Both keys remain identical for *every* suffix. `targetsAreDistinct` is always false; incrementing the shared suffix cannot repair an internal collision. There is no cancellation check in this loop.

Consequence: Preparation spins forever, consuming CPU. Cancel resets the UI and cancels its Task, but the synchronous loop ignores cancellation until process exit. No mutation has begun; valid uncommon folders trigger it without journal corruption.

Evidence: `file-safety-harness collision` first calls the actual `XMPSidecarResolver.resolve(...caseSensitiveNames:true)` and prints `resolver families=1 members=2 disposition=publish`, then calls the actual `ExportWorker.makePlan`. The subprocess failed to return and was killed after 3 seconds. Mathematical termination proof: `PHOTO (k).JPG` and `PHOTO (k).jpg` have equal reservation keys for every k. Fixture URLs model a case-sensitive source; no case-sensitive disk was mounted on this host. See `file-safety-collision.log` and harness source.

Minimal fix: Separate internal duplicate reservation keys from occupied destination collisions. Refuse with a typed actionable error or a per-volume policy representing every member; shared suffixes cannot fix ambiguity. Check cancellation between groups and suffix attempts.

Regression tests: A pure resolver + planner test for same-stem case-variant extensions; a case-sensitive filesystem integration when available; a bounded test showing a canceled preparation actually terminates. Test a case-insensitive destination refusal and a case-sensitive destination policy explicitly.

### FS-2 — P2: Source Organization accepts hierarchies that the scanner deliberately skips

Location: `Sources/Louppe/SourceOrganization.swift:1064-1072` (`isValidContainerName`), `:1137-1154` (`safeFolderComponent`); scanner contract `Sources/Louppe/FolderScanner.swift:254`.

Trigger: In Organize Source Folder, enter `.Hidden` or `Photos.app` as the container name and confirm the valid preview. The same exclusion can arise in a generated metadata level if its sanitized label remains a hidden name or package name.

Bug: Container validation excludes only empty/dot/dot-dot, too-long names, slash, colon and null. It accepts hidden names and macOS package names. Metadata sanitization likewise leaves a leading dot/package suffix intact. The mandatory post-operation scan uses both `.skipsHiddenFiles` and `.skipsPackageDescendants`.

Consequence: Rescan hides the organized file, although it remains intact. An all-hidden result returns to welcome; `SessionStore.swift:2358-2363` adds deferred undo only when `loaded` is nonempty, so in-session undo is unavailable. This follows from source; the UI was not driven, and no rating loss is claimed.

Evidence: Actual `SourceOrganizationPlanner.makePlan` returns `canExecute=true`; actual `SourceOrganizationWorker.organize` moves 1 file and reports `requiresRecovery=false`; actual `FolderScanner.scan` then returns zero items, while the destination file still exists. Reproduced independently for `.Hidden` and `Photos.app`. See `file-safety-hidden.log` and `file-safety-package.log`.

Minimal fix: Validate user and generated components against scanner traversal. Reject or rewrite hidden/package names before confirmation, and retain undo when organization leaves no visible media.

Regression tests: Real-I/O organize + rescan for hidden container, `.app` package container, and metadata-generated hidden/package folder; assert every moved media file remains scannable and the coordinator retains undo.

### FS-3 — P2: Move recovery cannot clear an identity-checkpointed partial generated XMP

Location: `Sources/Louppe/FileOperationJournal.swift:1085-1097` (`rollbackPreparedMoveCopy`). The live worker records this valid failure state in `Sources/Louppe/ExportWorker.swift:1262-1280`.

Trigger: Move with XMP reaches a generated-packet write failure, captures the exact partial inode in a durable `.started` checkpoint, then crashes before live rollback removes it. The journaled family is incomplete and must roll back.

Bug: `rollbackPreparedMoveCopy` demands a matching complete-packet digest and `.staged`/`.completed` state. It never accepts an exact recorded `.started` partial, although the worker explicitly checkpoints that state. `recoverPreparedCopy` already has the corresponding identity-verified partial removal branch at `FileOperationJournal.swift:1149-1164`.

Consequence: Recovery preserves the partial and original media but stays unresolved. The journal blocks Copy, Move, Rename, Organize, and Trash until Keep Files As They Are, leaving the hidden partial. No original loss occurs.

Evidence: Actual journal `.exportMove` family with media and prepared packet, durable `.started` packet identity, then writer destruction to simulate lock release/process death. Recovery returned `unresolvedOperations=1`, `unresolvedFiles=1`, `removedPartialCopies=0`, `partialExists=true`. See `file-safety-recovery.log`.

Minimal fix: Remove `.started` partials only when `resolvedIdentity` matches, using the two reserved paths. Do not require the complete digest; preserve unrecorded or ambiguous artifacts.

Regression tests: Crash after checkpointing a generated partial and before rollback; repeat recovery; verify no original mutation, exact partial removed, replacement inode preserved, journal retired only after consistency.

### FS-4 — P2: A crash during old-XMP retirement cleanup strands a completed Move journal

Location: `Sources/Louppe/FileOperationJournal.swift:1294-1295` and `:1302-1315` (`recoverRetiredXMPSource`). Live cleanup uses the two-path quarantine in `Sources/Louppe/ExportWorker.swift:1603-1617`, `:1757-1797`.

Trigger: All media/generated/application/retirement records in a Move family have completed checkpoints. Cleanup exclusively renames the old retired XMP from its retirement target into the planned `.partial` quarantine, syncs that rename, and crashes before unlinking it.

Bug: Forward retirement recovery explicitly rejects a temporary-only candidate, even if its inode exactly matches the completed retirement checkpoint. This is one of the legitimate crash positions created by the cleanup implementation itself.

Consequence: Media and the merged destination packet remain correctly exported. The old hidden packet and active journal remain unresolved on every retry, blocking future file mutations until Keep Files As They Are. No original loss occurs.

Evidence: Full actual 3-record Move family (ordinary media, prepared merged XMP, retired source XMP), all `.completed`, then retirement-target -> planned temporary rename and durable directory sync. Recovery returned `unresolvedOperations=1`, `unresolvedFiles=1`, `quarantineExists=true`. See `file-safety-retirement.log`.

Minimal fix: Treat either reserved retirement location as a recoverable candidate after verifying its completed identity; safely resume the two-path removal protocol. Keep both-path/replacement ambiguity conservative.

Regression tests: Crash before/after retirement target-to-quarantine rename, before/after unlink, and on directory-sync error; repeat recovery and test unrelated replacement entries.

### FS-5 — P2, malformed-journal robustness: A FIFO can hang recovery indefinitely

Location: `Sources/Louppe/FileOperationJournal.swift:2084-2096` (`fileIdentity`, no regular-entry type check) and `:2523-2543` (`openExactRegularFileForReading`); analogous `DurableFileIO.syncFile` opens before checking regular type at `DurableFileIO.swift:491-507`.

Trigger: A malformed/tampered Copy journal identifies a FIFO as the source and has a `.started` regular temporary. Ordinary `FolderScanner` excludes such entries, so this is a corruption/robustness case, not a normal photographer action. The journal starter/validator currently accepts this shape; it can be reproduced without editing serialized JSON.

Bug: `fileIdentity` accepts the FIFO and validation does not reject its type. Recovery revalidates its inode successfully and reaches `contentsEqual`. Its private open uses blocking `O_RDONLY` before it can `fstat` and reject the FIFO, so it waits forever for a writer. The newer `DurableFileIO.readRegularFile` already uses `O_NONBLOCK` correctly.

Consequence: Recovery holds the global lock indefinitely, blocking launch recovery, conflicting work, and gated Quit. No media changes; exposure is lower than FS-1 through FS-4.

Evidence: Actual `.exportCopy` journal with `mkfifo` source, `.started` checkpoint, and regular temporary. Harness printed `journal accepted FIFO source; beginning recovery` and hung until subprocess kill after 3 seconds. See `file-safety-fifo.log`.

Minimal fix: Reject nonregular media/packet identities at activation and recovery. Use `O_NONBLOCK` before fstat in readers/sync opens so malformed entries or replacement races cannot block type checks; return unresolved recovery.

Regression tests: FIFO source/candidate, socket, directory and leaf symlink; assert bounded recovery and no file mutation. Ordinary scans should continue skipping these entries.

## Confirmed optimization finding

### FS-PERF-1 — P2: Repeated basenames make the collision planner quadratic

Location: `Sources/Louppe/ExportWorker.swift:325-361`, `:432`.

Trigger: Export many photos from separate source subfolders with repeated names such as `PHOTO.JPG`, a valid ordinary Copy shape. No XMP is needed.

Cause: Every next group restarts its collision suffix at zero. It reconstructs all already-used target URLs, normalizes them and calls `lstat` before testing the in-memory reservation set. n repeated names require n(n+1)/2 candidate attempts. Neither ordinary planning nor this loop observes cancellation.

Measured with actual freshly built Debug testable module and empty destination:

| Files | Seconds |
| --- | ---: |
| 100 | 0.127 |
| 200 | 0.508 |
| 400 | 2.131 |
| 800 | 8.725 |

Each doubling took about 4x longer, consistent with O(n²). Release constants were not measured. See `file-safety-scaling.log`.

Fix direction: Cache the next suffix per original family/filename set and test reservations before URLs or filesystem probes. Preserve shared RAW+JPEG/XMP suffixes, collisions with pre-suffixed originals, and external occupancy checks. Add cancellation; assert scaling/probe counts instead of absolute time.

## Other optimization opportunities, not defects proved by measurement

- Production descriptor Copy fully syncs its target inside `DurableFileIO.BoundDirectory.copy`, then the worker reopens and fully syncs the same file. `BoundDirectory.publish` fully syncs the held parent and the worker then syncs that same parent again through `syncRenameDirectories`. Removing demonstrated redundant flushes may improve batches of small files/removable destinations; preserve the journal's write-sync-stage/publish boundaries and the fault-injected copier path. No measured speedup is claimed.
- `ExportManager.promptDestinationAndExport` calls `ExportDestinationValidator.validateBound` on the main actor. Move validation performs one volume resource query per physical source before work starts. This may freeze UI for large/remote folders; benchmark and move preflight off-main with its immutable input/binding boundary.
- Byte progress advances after an entire file is staged/published, and `fcopyfile` is one synchronous operation. Large single-video copies can appear unchanged for long periods and confirmed cancellation waits for the current file. Chunk/callback-based feedback is an opportunity; no correctness violation is claimed.

## Additional suspicion / follow-up requiring a sandboxed GUI test

`ExportManager.backFromMultiDestinationConfirmation` and canceled/failed preparation release route scopes while `ExportView` retains destination URLs. Retry reuses URLs; only a new chooser calls `retainRoutingDestinationAccess`. This was unconfirmed on 29 September: no signed sandboxed NSOpenPanel test. Reproduce external destinations → Review → Back → Review → Start Copy, and canceled/failed preparation. Retain scopes until route removal or reacquire for preparation/work. Current acceptance is tracked in [AUD-03](../../../BACKLOG.md#audit-follow-ups).

## Covered files and contracts

Read canonical/shared AGENTS, DEVELOPMENT_DETAILS File Operations, and PERFORMANCE Clean Up/Journal/Export/Organization/Renaming contracts.

Detailed review covered:

- `Sources/Louppe/ExportWorker.swift`: item/family name reservation, Copy and Move activation, source verification, descriptor-bound destinations, partial identity handling, cancellation/remount retry, pair rollback, result counts, source identity refresh, source-packet retirement.
- `Sources/Louppe/ExportManager.swift`: ordinary/XMP/multi-destination preparation and confirmation, detached work, operation callbacks, cancellation authority, late progress guards, destination-scope lifetimes.
- `Sources/Louppe/FileOperationJournal.swift`: plans v1-v4, plan/step/commit validation, alias/hardlink guards, exact paths, root advisory lock, all recovery kinds, committed retirement, explicit forgotten escape, bounded reads, identity/digest rules.
- `Sources/Louppe/DurableFileIO.swift`: file/directory descriptor binding, POSIX exclusive moves, durable writes and checkpoint order, lock timeout/type protections, exclusive create, Foundation ExFAT fallback, bounded regular-file reads and nonrecursive removal.
- `Sources/Louppe/CleanUpWorker.swift`: scan preflight, Trash system-boundary behavior, unknown returned destination, partial-pair rollback, source identity refresh, explicit undo and conservative partial restore, merge order.
- `Sources/Louppe/SourceOrganization.swift`, `SourceOrganizationWorker.swift`, `SourceOrganizationStorageSafety.swift`, `FileRenaming.swift`: immutable hierarchy/name plans, pair/family grouping, no-overwrite reservations, false-pair detection, recognized XMP moves, ACR blocks, ExFAT probe/policy, reverse journal plans, directory creation, metadata/name safety.
- `Sources/Louppe/ExportDestinationValidator.swift`, `MultiDestinationExport.swift`: resolved source-descendant exclusion, directory identity, same-volume-only Move, capacity arithmetic and per-volume aggregation, duplicate routed destinations, route membership/overlap/unmatched contracts, XMP split-family refusal.
- Supporting inspected paths: `XMPSidecarResolver.swift`, `XMPExportPlanner.swift`, `XMPExactFileSystemPath.swift`, `SecurityScopedAccess.swift`, `FolderScanner.swift`, `Models.swift`, and the applicable Export/Organization view and SessionStore coordinator sections.
- Existing safety tests inspected: ExportWorkerSafetyTests, FileOperationJournalTests, SourceOrganizationTests, CleanUpWorkerSafetyTests test inventory and implementation where relevant; root ran the suites.

## Areas without additional actionable findings

- Ordinary exclusive Copy publication never replaces occupied targets; ordinary Move rejects unknown/cross-volume identities rather than silently copying/deleting originals.
- Descriptor-bound production Copy destinations and per-file Move parents stop detected path replacement; the existing bound-path tests cover the introduced boundary.
- Stage/completed Copy recovery deliberately accepts operation-created ctime changes while exact source checks retain ctime; copies can survive source-volume unavailability after staging.
- Copy live rollback uses exact identity, a reserved quarantine path, repeated source proof/byte comparison and nonrecursive unlink; no ordinary original deletion found.
- Trash recovery commits the explicit Trash intent forward and does not search protected Trash. Explicit partial Trash undo preserves successfully restored originals and retains ambiguous evidence.
- Source Rename preserves exact extension bytes, jointly journals RAW+JPEG/recognized XMP families, rejects ACR companions/collisions/false pairing, and supports reverse operations through the same Move authority.
- Multi-destination plans are Copy-only, explicit routes have no implicit fallback, overlaps/empty routes/duplicate resolved folders block, and capacity sum uses saturating arithmetic.
- Active journal namespace retirement and Keep Files As They Are restrict canonical operation names; Keep renames bookkeeping aside without deleting media.

These are inspected contracts and existing checks, not exhaustive concurrency/power-failure proof.

## Verification limitations and artifacts

- No ExFAT hardware, real power-loss, remount/lid-close, network-volume latency or sandboxed open-panel interactions were performed by this subagent.
- No case-sensitive disk was mounted; FS-1 uses actual pure resolver with the explicitly supported case-sensitive policy and actual planner on that valid abstract input. The invariant duplicate-key proof is independent of source disk availability.
- Recovery experiments use durable real filesystem checkpoints and writer destruction to release the same OS advisory lock that process death would release. They do not assert physical power-loss simulation.
- Infinite-loop/FIFO harnesses were launched as subprocesses and killed after three seconds; they cannot strand the main test runner. Their fixture files remain only in the disposable audit directory.
- No build installation, commit, push, or source change was performed.

Artifacts:

- `file-safety-harness.swift`: actual-module repro modes `collision`, `recovery`, `retirement`, `fifo`, `hidden [container]`, `scaling`.
- `compile-file-safety.py`: exact actual-module/XMPBridge object linker command; no copied app implementation.
- Logs: `file-safety-collision.log`, `file-safety-recovery.log`, `file-safety-retirement.log`, `file-safety-fifo.log`, `file-safety-hidden.log`, `file-safety-package.log`, `file-safety-scaling.log`.
