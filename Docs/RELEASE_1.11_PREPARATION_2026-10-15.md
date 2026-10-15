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
The signed Store installer was uploaded through Transporter. Apple shows
1.11.0 (13) as Validated, and that build is selected and saved on the 1.11 draft.
Alex authorized submission, which remains pending. All six Store update-note
translations are saved without Revolut or GitHub references. Existing screenshots
and previews remain unchanged.

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

The GitHub release and signed feed are published. CI passed for the released
source (`51225b9`) and the [signed-feed commit](https://github.com/murlexander/louppe-media-culler/actions/runs/38767922085)
(`b915215`). Post-publication checks pass:

- The public latest-release ZIP matches the exact notarized archive checksum.
- The public feed matches the locally verified signed feed byte-for-byte.
- Homebrew automation passed and pinned 1.11.0 to that exact checksum.
- All six live website homepages retain the correct latest-release download link.
- An isolated public 1.10 app upgraded through Sparkle’s documented updater API,
  downloading and installing the public 1.11 archive. All 111 file/symlink entries
  and executable bits match the published app; signature and Gatekeeper pass.
  The updated app launched and migrated a disposable session from format 6 to 7,
  preserving the generated photo’s bytes. The installed user app was not replaced.

Desktop capture failed twice, so the standard update-dialog UI was not checked.
The API integration initially failed installer authentication with an unsigned
runner; signing that temporary runner with the matching existing Developer ID
resolved it. These limits and exact results are retained in local validation logs.

## App Store preparation status

Signed-in App Store Connect confirms 1.11.0 remains Prepare for Submission;
1.10.0 remains Ready for Distribution. Apple reports build 13 uploaded on
15 October at 1:02 PM and Validated, with arm64, macOS 14, and the expected
sandbox/bookmark entitlements. Build 13 is selected and survives draft reload.
The encryption declaration is saved as none of the listed algorithms; source
inspection found Apple CryptoKit SHA-256 hashes, not app-implemented encryption.

- English, Arabic, Simplified Chinese, Hindi, Brazilian Portuguese, and Spanish
  update notes are saved and checked by switching locales. None mentions Revolut
  or GitHub. The format-7 compatibility warning appears in every translation.
- `sample-media.zip` is attached and survives reload. Review notes explain the
  disposable sample workflow and optional, repeatable StoreKit tips; no features
  or content are unlocked. Existing review contacts and sandbox usage are retained.
- Automatic release after approval and immediate availability to all users remain
  selected. Existing 36 screenshots and six previews are retained.
- Paid Apps, banking, tax forms, DSA, and DAC7 show Active. The Free Apps agreement
  is Active with a new agreement available. No legal agreement was accepted.

Three consumable tip products were created with all 175 territories and future
territories enabled, Ireland (EUR) as base, and Apple-adjusted comparable prices
elsewhere. Each has six localized names/descriptions and review notes explaining
that tipping is optional and unlocks nothing. Tax category matches the parent app.

| Tip | Product ID | Apple ID | Base price |
| --- | --- | --- | ---: |
| Small | `com.alexandermarkin.louppe.tip.small` | 6823267142 | €3.00 |
| Medium | `com.alexandermarkin.louppe.tip.medium` | 6823268884 | €7.00 |
| Large | `com.alexandermarkin.louppe.tip.large` | 6823269537 | €18.00 |

Remaining blockers and work:

1. Apple explicitly requires the Account Holder to review and accept the updated
   Developer Program License Agreement at <https://developer.apple.com/account>
   before updates can be submitted. Alex was asked to handle this legal action.
2. App Review screenshots for all three tip products are still absent. These are
   private review evidence, separate from the unchanged public Store screenshots.
   The ad-hoc Store local-check app could not be launched through native controls;
   a direct diagnostic launch exited 134. No replacement image was fabricated.
3. After those prerequisites, add the app version and all three tips to the same
   draft submission and Submit for Review. These are the first consumables, so
   Apple requires submission with an app version. No review submission exists yet.

Automatic approval review rejected adding Large Tip for review while the updated
agreement remains unaccepted. That action was not retried through another route.
Native Helium/Transporter controls failed repeatedly; the signed-in Codex browser
resolved metadata access. Its actual file-input chooser successfully uploaded the
review sample after the associated-button chooser attempt timed out. Native
control of the Codex app itself was denied and was not bypassed.

Keep StoreKit tips and Apple-delivered updates in the Store build; GitHub retains
Revolut tips and Sparkle updates. Do not describe this as waiting for App Review
until a successful submission is verified.

1.11 saves session format 7; 1.10 cannot read those saved sessions. Include that
compatibility note in public release notes.
