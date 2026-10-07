# Louppe readiness — 7 October 2026

**GitHub 1.10.0 (12) is public; App Store 1.10.0 (12) is Waiting for Review.**
App Store submission uses SAMO DANNI EOOD.
Submitted at **23:23 GMT+2**, submission `8dc18587-519a-4361-9314-f12b67d2405a`.
[Apple review record](https://appstoreconnect.apple.com/apps/6820131477/distribution/reviewsubmissions/details/8dc18587-519a-4361-9314-f12b67d2405a).
Manual release remains selected; release requires a separate action after approval.
No login or other user action is needed now. App Store availability is not yet live.

The [public 1.10 release](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.10.0)
and signed update feed are live. English, Spanish, Simplified Chinese, Hindi,
Portuguese and Arabic are included. Full proofs are in the
[submission packet](../dist/app-store-submission/README.md).

## Verification

| Check | Result |
| --- | --- |
| XCTest | 595 total, including 14 skipped; 581 passed, zero failures |
| Store scope/ownership | 19 passed; original URLs retained through access, Export and recovery deferral |
| Performance | 75/75 passed, including all three real Trash checks |
| Store package | Resource identifier repaired; signatures, strict verification and exact payload passed; delivered, processed, selected and submitted |
| Packaging regressions | Invalid/missing identifiers and malformed plist refused; locale/catalog preservation and repeat preparation passed |
| Folder access/saved review | Picker/cold Recent restored ratings; repaired app Recent loaded 192 fixtures, Session Saved, no recovery warning |
| Copy/routing | Exact keeper copy; eight routed copies across two folders; Back retained both destinations |
| Move | Explicit warning and one completed move; seven sources plus moved file match all eight baseline hashes |
| Rename/Trash/Organize | Undo restored names/locations; safe stale-identity guard, retry and repeated chain passed |
| Copy Stop | 192 sources intact; 174 exact completed copies, no partial/temp artifacts; clean relaunch passed. Native crash recovery untested |
| Media/Help | Audio Play/Pause/seek/waveform, video Pause/seek, Markdown, About and built Help passed |
| Translation safety | 688 safety messages in each of five translated languages plus Portuguese fixes reviewed; all six 1492-entry catalogs and signed hashes match |
| Store assets | Six branded 2880×1800 JPEGs saved/reloaded; actual-window 28-second 1920×1080 preview uploaded; submission accepted. Preview processing completion unverified |
| Direct distribution | Notarization/stapling/Gatekeeper and guarded 1.9→1.10 CLI update passed; full Contents/execution bits match. GUI update interaction unverified |
| Public quality | [Complete CI passed](https://github.com/murlexander/louppe-media-culler/actions/runs/37685902573), including release preflight |

Checks used disposable files; no production originals were changed. The behavior
freeze and metadata-only repair have separate proofs. Earlier failures and
measurements remain in the packet's historical assessments.
Store package: **5,565,585 bytes**, SHA-256
`d46953a8bf5d07a1a60fe72c14ccff424f345184c273e8e76bfbc7f67427f7e0`.
Delivery succeeded; warning 90889 concerns TestFlight profiles.

## Website

Published source: **99ffc53eeeb8743d089bad0026642bb9d2cb1f66**. Six live homepages
match source and offer all six languages. The latest download resolves to the exact
notarized 1.10 ZIP. Privacy/analytics controls remain available; historical blog
posts retain their dates. Desktop/mobile switching and Arabic RTL checks are in
[website evidence](../../website/Docs/LOCALIZATION_2026-10-07.md).

## App Store Connect

SAMO DANNI EOOD / P6F95J4ZPA; macOS Louppe, Apple ID **6820131477**.
Build 12 is selected. “None of the algorithms mentioned above” export compliance
was user-approved, saved and reload-verified; Missing Compliance is gone.
Seven English fields, 25 localized fields and six names/subtitles matched after
reload. Sandbox information, review contact and sample ZIP are saved; private
phone is omitted. Reviewer ZIP download remains unverified.
Privacy is Data Not Collected; free in 175 storefronts on release, no preorder.
Photo & Video, standard Apple EULA and trader status are confirmed. Age rating
4+ in 172 regions has regional exceptions. Add for Review and Submit for Review
accepted the final assets/build without validation errors.

## Verification limits

Physical disconnect/lid-close/power loss/delayed File Provider behavior; spoken
VoiceOver/Full Keyboard Access, contrast/Reduce Motion; small displays/older Macs;
compressed Fuji/resource failures; Katerina's clean install; every translated
language's native visuals/native-speaker approval; real-editor XMP handoff.
Safe Stop passed; native interrupted/crash recovery is untested. Native UI showed
no recovery warning; macOS blocked Store journal disk inspection. Dependency/parser
review is bounded (AUD-20). Prior details remain in the
[historical report](../dist/app-store-submission/assessment/history/pre-resource-repair/APP_STORE_READINESS_2026-10-07.md).
