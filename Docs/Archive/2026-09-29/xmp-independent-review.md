# Independent review of X1 — 2026-09-29

Reviewed the final canonical implementations in:

- `Sources/Louppe/XMP/XMPPublication.swift`
- `Sources/Louppe/XMP/XMPMetadataStore.swift`
- `Sources/Louppe/DurableFileIO.swift`
- `Tests/LouppeTests/XMPPublicationIdentityTests.swift`

Read-only review under app/shared AGENTS and identity/file-operation/performance
rules. No reviewed source/test edits; the coordinator owned integration and launch.

## Outcome

**No confirmed remaining X1 correctness issues after the final temporary-ownership guard.** Independent review reproduced a publication gap; the coordinator fixed it and the reviewer reverified the final helper.

## Confirmed gap found and resolved

`atomicWrite` originally checked temporary ownership only during cleanup. Another
writer could substitute its temporary during final validation; target CAS stayed
valid, yet rename destroyed the original packet before readback detected wrong bytes.

The repro compiles canonical `DurableFileIO.swift` and `XMPExactFileSystemPath.swift`,
with only an exact-path byte-helper stub. Production code opens, writes, flushes,
renames, and cleans. The probe checks old target bytes, substitutes the temporary
inside `validateBeforePublish`, then checks the target.

Before the guard (`temp-ownership-repro.log`, compile/run exit 0):

```text
bound atomicWrite returned success: true
target original preserved: false
target intended bytes: false
target substituted bytes: true
```

After file flush, immutable temporary stat is compared with descriptor-relative
`fstatat(..., AT_SYMLINK_NOFOLLOW)` before rename: regular type, device, inode,
birth time, size, mtime, and ctime must match. This rejects inode substitution and
in-place edits without using obsolete pre-write size/timestamps.

After recompiling against the final helper (`temp-ownership-repro-final.log`, compile/run exit 0):

```text
bound atomicWrite rejected substitution: DestinationChanged()
bound atomicWrite returned success: false
target original preserved: true
target intended bytes: false
target substituted bytes: false
```

`testTemporarySubstitutionAndInPlaceEditCannotReplaceOriginalPacket` exercises both
forms through the XMP store/final-validation hook. It preserves the packet and
foreign temporary, cleaning only the owned in-place-edited inode.

## Reviewed contracts

- **Source authority:** production `SessionStore` supplies scan-time source folder identity. Supplying a folder without its identity fails closed. Preflight freezes each physical member's scan identity, including unselected siblings in the shared stem family. Missing identity, regular-file replacement, deletion, symlink/FIFO/directory replacement, and whole-folder replacement become external-modification conflicts rather than publishing old review metadata.
- **Repeated validation:** source checks surround preflight packet preparation, run again during worker preparation, and run at the final flushed-temporary boundary. The already-current path also validates source identity before claiming success. Source-folder and physical-file checks use stable identity and exact path authority, not mutable folder timestamps or display filenames.
- **Descriptor-bound mutation:** source-validation publication holds the original sidecar parent directory. Temporary creation, final rename, directory flush, and cleanup are relative to that held descriptor. A replaced pathname cannot redirect publication or cleanup into the replacement folder. Parent binding is rechecked before publication and after flushing.
- **Owned cleanup:** descriptor-relative cleanup checks regular type/device/inode before unlinking. An unowned replacement at the temporary name is retained; the original target remains intact on validation failure. The final added guard closes the formerly missing ownership check for the rename source itself.
- **Packet CAS:** updates retain both exact packet bytes and the full XMP revision. Creates remain exclusive and reject a newly appearing destination. Worker preparation must still match the frozen preflight fingerprint. External edits at the final validation hook remain visible conflicts and their bytes are preserved. Committed packets are reread and parsed before success.
- **Legacy API:** the optional validation argument preserves existing direct XMP store callers that do not carry a standalone source-validation plan. Those callers retain their original packet CAS, exclusive create, flush, and readback behavior. The production standalone worker always passes its immutable validation; a publishable plan lacking it fails closed. Other journaled operation paths retain their separate identity ownership.
- **Cancellation/bounds:** worker fan-out remains three long-lived workers, with cancellation before final mutation and the existing 64 MiB regular-file packet read bound. FIFOs are rejected without blocking because packet reads use O_NONBLOCK plus regular-type validation.

## Evidence and limits

- Harness: `/private/tmp/louppe-fixes-2026-09-29/BoundWriteTempRepro.swift`
- Initial failure: `/private/tmp/louppe-fixes-2026-09-29/temp-ownership-repro.log`
- Final verification: `/private/tmp/louppe-fixes-2026-09-29/temp-ownership-repro-final.log`
- Final compiler log: `/private/tmp/louppe-fixes-2026-09-29/temp-ownership-build-final.log`
- `git diff --check` passed for the reviewed files.

This run verifies temporary substitution. The coordinator was running full XMP/integration
coverage, including same-inode edits. No power-cut, removable-volume, or alternate
filesystem test. The check/syscall interval remains; descriptor-relative mutation
prevents redirecting writes into a replacement parent.