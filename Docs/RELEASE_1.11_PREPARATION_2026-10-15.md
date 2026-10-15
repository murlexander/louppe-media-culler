# Louppe 1.11.0 (13) preparation — 15 October 2026

Alex reports manual checking complete, accepts preparation for release, and
requests keeping the existing screenshots. This is owner acceptance, without
independently captured per-case StoreKit, native-language, hardware, or energy
measurements. Longer-term investigations stay in [BACKLOG.md](../BACKLOG.md).

Local preparation is complete: rebuilt Developer ID and signed Store candidates,
fresh validation, exact checksums, and public notes are retained locally.
Notarization/stapling and the final signed feed await explicit approval to upload
the exact direct ZIP to Apple. Automatic approval review rejected that upload
under general release-preparation authorization; the certificates and
`louppe-notary` profile are accessible. VERSION remains 1.11.0 (13).

The public direct release/feed remains 1.10.0. Preparation and commit/push are
authorized; GitHub publication and App Store upload/submission are separate.

Local outputs: `dist/release-preparation/1.11.0-13-2026-10-15/`.
The [14 October record](RELEASE_1.11_READINESS_2026-10-14.md) is historical;
its candidates predate the compact-window title fix and are superseded.

## Verification and artifacts

Application inputs match `a51efcf554ca63d1b709954deeee096932647f1c`, including
the compact-window title fix. All 482 frozen packaging inputs remained unchanged.
The local manifest records the final committed/pushed revision and CI result.

- Full XCTest: 755 executed, 719 passed, 36 explicit skips, zero failures;
  all 35 HotkeyTests pass. Optional fixture/hardware/hosted checks remain skips.
- Required filesystem/performance checks: 75/75, including real Trash/restore.
  Scrollbars: 10/10; standalone media/video checks pass.
- Strict Swift 6 concurrency/warnings-as-errors build passes.
- Redacted credential scans pass. The concurrent privacy review found no
  credentials; personal paths/names were redacted and a personal screenshot
  retained outside Git. Historical public commits were not rewritten.
- The existing public feed signature verifies using the updater Keychain key;
  the new feed remains deferred until the final notarized archive exists.
- Both build scripts verified the complete loose/archive Contents independently.
  The Store installer passed application/installer signatures, Apple distribution
  trust policy, sandbox/bookmark entitlements, and exact expanded-payload checks.
- The fresh direct executable opened a native Gallery with floating zoom and
  Quality Cues, saved a Yes decision in schema 7, and left generated JPEG bytes
  unchanged. It quit after Saved. An initial Launch Services attempt did not
  establish a running process; direct executable launch resolved the check.
- Website tests: 23/23. Active app/site documentation links and whitespace pass.
  XMP fixture moves are covered by the full suite. Archived retained copies and
  retired prototype removal were reviewed before committing.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Developer ID `direct/Louppe.zip` — awaiting notarization | 7,036,754 | `ac6355bf55bd0b9227628f748bb4c91684ab5af8a0779ffd757c26d49913171c` |
| Signed Store `app-store/Louppe.pkg` | 5,937,966 | `2d9897c226a4fdf804b25af39adddab2dbab4a2fd96f271a48bf1439cf9697e9` |

The Store local-check ZIP is ad-hoc and is not an upload artifact. The final
signed feed must be generated only after notarization recreates the direct ZIP;
that step changes its checksum. Public `appcast.xml` remains unchanged on 1.10.
The preparation directory contains `MANIFEST.json`, `SHA256SUMS`, draft GitHub
notes, Store update copy, validation logs, and `RELEASE_HANDOFF.md`.

## Acceptance and media

Alex’s manual sign-off removes the release hold for the reviewed behavior.
No new claim of full native-speaker certification or measured battery performance
is made. The existing 36 Store screenshots and six previews remain unchanged;
they use 1.10 captures. The dark icon remains outside this release.

## Publication handoff

After a separate publication request:

1. Publish `v1.11.0` with the exact verified direct ZIP and prepared public notes.
2. Publish its matching signed `appcast.xml`; never recompress the ZIP afterward.
3. Complete a real update from 1.10, then update Homebrew and website claims/links.
4. Upload the verified Store installer and complete Apple-required listing,
   tip-product, agreement, compliance, and review fields before submission.

App Store Connect redirected the preparation check to sign-in. Product/account
configuration was not independently verified or changed in this run.

1.11 saves session format 7; 1.10 cannot read those saved sessions. Include that
compatibility note in public release notes.
