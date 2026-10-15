# Louppe 1.11.0 (13) preparation — 15 October 2026

Alex reports manual checking complete, accepts preparation for release, and
requests keeping the existing screenshots. This is owner acceptance, without
independently captured per-case StoreKit, native-language, hardware, or energy
measurements. Longer-term investigations stay in [BACKLOG.md](../BACKLOG.md).

GitHub [1.11.0 (13)](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.11.0)
is published with the signed, notarized archive. Apple accepted submission
`aee5a86a-5433-4d97-8133-38afdcb76417`; stapling, Gatekeeper, complete
loose/archive Contents, and signed feed/archive verification passed.
The matching signed feed is published with this handoff. No new version bump
was made for publication metadata.

Alex authorized GitHub publication as soon as ready, without waiting for Store
approval. Both channels continue: GitHub uses Sparkle/Revolut tips; Store uses
Apple updates/StoreKit tips. All features remain free in both products.
The signed Store installer is prepared; Store upload/submission and account
checks have not been performed. Existing screenshots remain unchanged.

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
- The final 1.11 feed and archive signatures verify using the updater Keychain
  key. Publishing preflight verifies the version/build, enclosure URL/length,
  notarization, Gatekeeper, and complete loose/archive Contents.
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
| Notarized `direct/Louppe.zip` — published | 7,038,639 | `6b232a6be28245435068c160a71eba6d4539d371e44fceeed67a5f8f7a4af547` |
| Signed Store `app-store/Louppe.pkg` | 5,937,966 | `2d9897c226a4fdf804b25af39adddab2dbab4a2fd96f271a48bf1439cf9697e9` |

The Store local-check ZIP is ad-hoc and is not an upload artifact. The final
signed feed was generated after notarization recreated the direct ZIP; it matches
the published archive exactly. The submitted pre-stapling ZIP is retained only
as local provenance; do not publish or substitute it for the final archive.
The preparation directory contains `MANIFEST.json`, `SHA256SUMS`, draft GitHub
notes, Store update copy, validation logs, and `RELEASE_HANDOFF.md`.

## Acceptance and media

Alex’s manual sign-off removes the release hold for the reviewed behavior.
No new claim of full native-speaker certification or measured battery performance
is made. The existing 36 Store screenshots and six previews remain unchanged;
they use 1.10 captures. The dark icon remains outside this release.

## Publication handoff

The GitHub release and signed feed are published. Public-download identity,
Homebrew automation, and a real Sparkle update from 1.10 are checked after
publication; exact results are retained in the local manifest and validation logs.

Store work remains: upload the verified installer and complete Apple-required
listing, tip-product, agreement, compliance, and review fields before submission.
Keep StoreKit tips and Apple-delivered updates in that build; GitHub retains
Revolut tips and Sparkle updates.

App Store Connect redirected the preparation check to sign-in. Product/account
configuration was not independently verified or changed in this run.

1.11 saves session format 7; 1.10 cannot read those saved sessions. Include that
compatibility note in public release notes.
