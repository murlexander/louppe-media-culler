# Louppe 1.9.0 (11) release record

Published 27 September 2026 (local time):
[GitHub release](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.9.0).

## Provenance

- App source/tag target: `fad11d563a063860d2e8ac1db6fbcdf0d8969ccd`.
- Package built with full Xcode 27.0 and the macOS 27.0 SDK, preserving the
  macOS 14 minimum and Apple silicon architecture.
- Signed with Developer ID Application: SAMO DANNI EOOD (`P6F95J4ZPA`), including
  every embedded Sparkle executable and helper, with hardened runtime.
- Apple notarization request: `2dbc2a5a-6759-4d35-8adc-f1ec6c1602d7` — **Accepted**.
- Ticket stapled to the app; ZIP recreated from that exact stapled bundle.
- Published asset: `Louppe.zip`, 6,096,278 bytes.
- SHA-256: `27fccb1520a50b049535a0e9a72534bdc426b7a7907d24a4ef3cb37053e59361`.
- GitHub's asset digest matches the verified local archive.

The private Developer ID and Sparkle keys stayed in Keychain. Only the normal
signed archive and signed appcast are published. Apple result/log files remain
in ignored `dist/notarization.json` and `dist/notarization-log.json`.

## Verification

- Full GitHub quality run on the exact app commit passed:
  [36277061138](https://github.com/murlexander/louppe-media-culler/actions/runs/36277061138).
  It includes strict compilation, all 415 XCTest cases, deterministic
  filesystem checks, scrollbar/media checks, and release packaging.
- All 34 HotkeyTests also passed locally before installation. Earlier combined
  local checks passed all 74 filesystem/performance tests including real Trash
  and restore, all 10 scrollbar checks, and the five-fixture XMPCore proof.
- Publishing preflight passed: independent loose/archive signatures and complete
  tree comparison, notarization tickets, Gatekeeper, version/build, embedded
  helper signing, and exact archive/feed signatures and lengths.
- Installed signed/notarized app launched on the compact start page. The logo
  is an accessible native website link; clicking it opened `https://louppe.eu/`
  in the default browser, verified through its URL and loaded page.
- A disposable public signed 1.8 app upgraded to the exact 1.9 archive through
  Sparkle 2.9.4’s official CLI/compiler definitions and checksum-verified framework.
  A signed loopback feed enabled testing before publication. Discovery, download,
  signature checks, extraction, and installation passed; the resulting 1.9.0
  deep/strict signature verifies.

Test logs and the disposable app/tool/feed are retained in
`/private/tmp/louppe-1.9-update-test/`; other release logs are
`/private/tmp/louppe-1.9-*.log`. The temporary server is stopped after verification.

## Notes

Both the embedded update notes and GitHub release link to
[the 1.9 introduction](https://louppe.eu/blog/a-proper-hello/).

Direct download; no App Store submission. Bridge/Lightroom/darktable/Capture One
acceptance remained in `BACKLOG.md`. The open Dependabot PR covered CI checkout
only and was separate from this release.
