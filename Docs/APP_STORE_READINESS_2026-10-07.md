# Louppe readiness — 7 October 2026

**1.10.0 (12): delivered to Apple; review submission pending.**
The first delivery failed Apple validation 90276. The resource bundle now has its
required identifier. Repaired package: **5,565,585 bytes**, SHA-256
`d46953a8bf5d07a1a60fe72c14ccff424f345184c273e8e76bfbc7f67427f7e0`.
Signature/payload checks passed; executable code, catalogs and other resources
match the native-tested candidate. Transporter confirmed Delivered; only the
yellow TestFlight profile warning 90889 remains. No review submission yet.

The app supports English, Spanish, Simplified Chinese, Hindi, Portuguese, and
Arabic. Public download remains **1.9.0 (11)** until the new release is published.
Full proofs and prior artifacts are in the [submission packet](../dist/app-store-submission/README.md).

## Verification

| Check | Result |
| --- | --- |
| Full XCTest | 595 tests, 14 scoped skips, zero failures |
| Store scope/ownership | 19 tests passed; original URLs retained through access, Export, and recovery deferral |
| Performance | 75/75 passed, including all three real Trash checks |
| Store package | Repaired resource identifier, signing, strict verification and exact payload checks passed; delivered to Apple |
| Packaging regressions | Missing/wrong/empty/non-string identifiers and malformed plist refused; locale/catalog preservation and repeat preparation passed |
| Folder access and saved review | Picker/cold Recent restored ratings; repaired app launch/Recent loaded 192 fixtures with Session Saved and no recovery warning |
| Copy and routing | One exact keeper copy; eight routed copies across two folders; Back retained both destinations |
| Move | Explicit warning and one completed move; seven source files plus the moved file match all eight baseline hashes |
| Rename, Trash, Organize | Undo restored names and locations. Initial stale-identity guard blocked safely; rescan/retry passed, then the repeated chain passed without rescan |
| Copy Stop | 192 sources unchanged; 174 exact completed copies, no partial/temp artifacts; clean relaunch reopened all 192 with no recovery warning. Crash recovery untested |
| Media and built Help | Audio Play/Pause/seek/waveform, video Pause/seek, Markdown, About version/links, and built Help passed |
| Store assets | Six interim 2880×1800 JPEGs passed QA and persisted in Apple. Earlier screenshot design and website video requested; replacement pending |
| Direct distribution | Fresh notarization/update verification pending; the earlier 1.9 CLI update check passed |

Read-only hash checks used disposable files. No production originals were changed.
Detailed test, native, package and screenshot evidence is indexed in the packet.
The behavior freeze and metadata-only repair have separate proofs. The rejected
package is preserved as historical evidence; `repaired-store-package.json` is current.

## Website

Live source: **7bb40f8e875ad0577846ca0cca09aa7914fd521c**. Six homepages match
source bytes and include all six language links. The download follows GitHub
latest; the site offers six languages, a separate [privacy policy](https://louppe.eu/privacy/)
and analytics controls. The website chat verified switching at desktop/mobile widths and Arabic
RTL; see [website evidence](../../website/Docs/LOCALIZATION_2026-10-07.md).

## App Store Connect

SAMO DANNI EOOD / P6F95J4ZPA; macOS Louppe, Apple ID **6820131477**.
Version 1.10.0 uses manual release. Seven English text fields, 25 localized version
fields, and all six names/subtitles matched after reload. Selected-folder sandbox
information, review contact and sample ZIP are saved; the private phone stays out
of this packet. Reviewer download of the ZIP is unverified.

Privacy is **Data Not Collected**, published with user approval. Pricing is free
in 175 storefronts, available on app release; no preorder. Age rating is 4+ in
172 regions with regional exceptions. Photo & Video category and content rights
are saved. Source audit found no non-exempt encryption; the build questionnaire,
remaining compliance/EULA answers, build selection and review submission are pending.
Transporter is signed in to SAMO DANNI EOOD; no login is currently needed.

## Remaining verification limits

Physical card/disk disconnect, lid-close, power loss and delayed File Provider
behavior; spoken VoiceOver/Full Keyboard Access, contrast/Reduce Motion; small
screens and older Macs; compressed Fuji/resource failures; Katerina's clean
install; native visual review in every translated language; real-editor XMP handoff.
Safe Copy Stop passed; interrupted journal recovery remains unaccepted. Native UI
showed no pending recovery warning, but macOS prevented independent disk inspection
of the Store journal container. Dependency/parser review remains bounded (AUD-20).

Historical measurements, certificates, dependency pins and earlier failures are
preserved in the [prior detailed report](../dist/app-store-submission/assessment/history/pre-resource-repair/APP_STORE_READINESS_2026-10-07.md).
