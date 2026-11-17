# Louppe 1.14.1 (19) release — 17 November 2026

Alex approved the rebuilt candidate ("all looks fine, start publishing the new version"). Release tag `v1.14.1` is `38e2f4d`: the 14 November candidate (`0f8b861`) plus the issue #5 fix `2e2f061` (a RAW pairs with a same-named HEIC/HEIF or JPEG XL file when there is no JPEG) and release documentation. The issue reply promised the update within 1–3 days of 16 November.

## Verification

- `2e2f061`: install gates 56/56, full suite 1,730 tests with 0 failures, performance checks 75/75. `38e2f4d` (docs only on top): install gates 56/56; [Quality 43814950808](https://github.com/murlexander/louppe-media-culler/actions/runs/43814950808) passed.
- With the desktop handed over (Release Readiness session), `Scripts/test.sh --full --foreground` on `38e2f4d`: 1,730 tests, 71 skipped, 1 failure: `PopoverSurfaceTests.testArrowSharesTheBodySurface` hit ScreenCaptureKit `InvalidTransition` before its pixel comparison and passed alone, the same capture flake as in 1.14.0.

## Direct download

- Built from `38e2f4d` with `Scripts/lib/xcode_env.sh` and `LOUPPE_SCRATCH_PATH=$LOUPPE_RELEASE_SCRATCH_PATH`. Notarization accepted (request `7e238ce6-e363-4e9c-b139-77f807ab8093`) and stapled; `verify_release.sh --publishing` and `--app-store` passed.
- ZIP: 9,233,355 bytes, SHA-256 `d4766fe6272cd72868fe251c128e7d9b5c8a2aa12ef0c9d0bd4aec566acee157`. [GitHub v1.14.1](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.14.1) is public and Latest; the public, latest-download and signed ZIPs are byte-identical.
- Signed feed commit `1ad617f`; the updater URL serves identical bytes; `sign_update --verify` accepts the feed and the ZIP signatures.
- The Homebrew workflow committed `eff4a1d` (cask 1.14.1, exact ZIP hash) without a push race.
- All six louppe.eu language pages serve the latest-download link.

## Installed app and update

`/Applications/Louppe.app` holds the released build since 16 November (Louppe was not running); its files match the candidate, and its signatures, Gatekeeper and stapling pass.

The idle-gated Sparkle check failed twice for harness reasons: with the headless driver ad-hoc signed, Sparkle 2.10.1 refused to start its installer (error 4005; Autoupdate needs a host signed with the same team ID). With the driver linked to the public 1.14.0 archive's Sparkle and signed with the Developer ID identity (team P6F95J4ZPA), the third run (idle 373 s) updated an isolated public 1.14.0 (18) copy (SHA-256 `f1902666…70ad`) to 1.14.1 (19) from the public feed: all 9,233,355 bytes downloaded and installed without launching the app, the updated `Contents/` matches the release, and strict signatures, Gatekeeper and stapling pass. The installed app still matches the release; Alex's preferences are unchanged apart from the app's own thumbnail-prune timestamp. Sign the driver this way in future runs.

## App Store

Package built from `38e2f4d`: `store/Louppe.pkg`, 8,131,821 bytes, SHA-256 `ef853937609d9b44c47411f6c3730179d158d638cb19c7a6bc72f376f11e6d77`. Alex clicked Deliver in Transporter on 17 November; build 19 processed as VALID. Version `a22ed25e-9721-4238-83c8-2625578d86c2` (1.14.1, build 19, export compliance `usesNonExemptEncryption=false`) carries What's New for all 11 locales covering 1.14.0 and 1.14.1 (`store/whats-new-1.14.1.json`), inherited descriptions, promotional text and 8 screenshots, review notes with a 1.14.1 first paragraph, and the unchanged `sample-media.zip` (33,273,155 bytes, re-uploaded; attachments don't carry over to a new version). Submission `276a88bb-8a1e-4fa9-a7e8-161daf9052c7` is **WAITING_FOR_REVIEW**, releasing automatically after approval.

Artifacts, the update driver and logs are retained in ignored `dist/release-preparation/1.14.1-19-2026-11-16/`.
