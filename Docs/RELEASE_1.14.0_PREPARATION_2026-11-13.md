# Louppe 1.14.0 (18) release — 13 November 2026

Alex asked for a bug review before the release, then: "ship sparkle update, then commit and push all". Release tag `v1.14.0` is `89671e7`. The Developer ID app was built from `047176b`; its app inputs (`Sources`, `Package.swift`, `Package.resolved`, `Packaging`, `build_app.sh`, `VERSION`) are identical, and only `Tests/run_performance_checks.sh` differs (a CI fix). No App Store package was built; that remains release step 7.

## Release review

Six review areas (file operations, persistence and folder opening, media and video, Browser/Grid/shortcuts/accessibility, languages and updates, session state) plus follow-ups, each reviewed by a second model. Fixes to behavior that shipped in 1.13.2: undo bound to worker-confirmed files (`375298d`), Undo after a partly failed Rename/Organize (`b75d4aa`), the current photo kept in view after sorting or resizing (`ed98248`, `c8a92d8`), a pending search applied before star and color edits (`c9e2d49`), counts in Louppe's language (`2e32c9b`). Fixes to unreleased 1.14 work: newer folder requests win (`381bdaa`, `4f59040`), rename numbering reserves shortened names and sidecars (`fafdf70`), opening tiles are named for VoiceOver (`459c60d`), opening counts and plural fallbacks (`80ffff0`, `bf5f090`, `902ad6e`). Test reliability: `2aab8bd`, `17910a0`, `615889c`. 34 tests were added; each fix has one that failed before it.

## Verification

- Full suite at `615889c`: 1,509 tests, 0 failures, 73 skipped (window-raising or hardware). Install gates 55/55; performance checks 75/75; resource-bundle (including all six plural catalogs) and video checks pass.
- [Quality 43341395690](https://github.com/murlexander/louppe-media-culler/actions/runs/43341395690) on `89671e7` passed every step, including XCTest with `LOUPPE_FOREGROUND_UI=1`. [Quality 43339284435](https://github.com/murlexander/louppe-media-culler/actions/runs/43339284435) on `047176b` failed only because `run_performance_checks.sh` pinned `/Applications/Xcode.app`, which the runner doesn't select.
- Locally, with the desktop handed over: the five window-raising suites pass except `PopoverSurfaceTests`, which fails with ScreenCaptureKit `InvalidTransition` when run after `ConnectedDrivesTests` and passes alone (2/2). Live captures of the Sort and Filter popovers (arrows zoomed, light and dark), Grid, Gallery, opening, sorted (LTR and RTL), Rename/Organize progress and results, and the Export XMP failure show no seams or regressions. The partial Rename/Organize Undo scenarios fail live with the same error; their real-click test passes.

## Direct download

- Built with Xcode 27.2 through `Scripts/lib/xcode_env.sh` and `LOUPPE_SCRATCH_PATH=$LOUPPE_RELEASE_SCRATCH_PATH`. Without them `build_app.sh` used the Command Line Tools and could not compile SwiftUI macros, and `notarize_release.sh` could not find the Sparkle tools.
- Notarization accepted (request `520ea6f0-7768-49da-8a9b-2ae300d71db2`) and stapled; Gatekeeper accepts the loose and archived apps. One `verify_release.sh --developer-id` run reported Sparkle code without the hardened runtime although every component carries the flag; three reruns passed.
- ZIP: 8,966,165 bytes, SHA-256 `f190266b7c805f7664fd7d0e8c26a872f8cba83b13ce51e0820436670c7770ad`. [GitHub v1.14.0](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.14.0) is public and Latest; the public, latest-download and signed ZIPs are byte-identical.
- Signed feed commit `491c9ab`; the updater URL serves identical bytes; `verify_release.sh --publishing` verified both Sparkle signatures.
- The Homebrew workflow lost the push race with the feed commit; its rerun committed `05b8e4e` (cask 1.14.0, exact ZIP hash).
- All six louppe.eu language pages serve the latest-download link.

## Update and installed app

Idle-gated (302 s), the retained headless Sparkle driver updated an isolated copy of the public 1.13.2 (17) archive (SHA-256 `8e9d55ce…ff40`) to 1.14.0 (18) from the public feed: all 8,966,165 bytes downloaded and installed without launching the app. The updated `Contents/` matches the release; strict signatures, Gatekeeper and stapling pass.

`/Applications/Louppe.app` was replaced with the released app; Louppe was not running. Its `Contents/` matches the release and its signatures, Gatekeeper and stapling pass. Previous copy: `/private/tmp/louppe-1.14.0-install.PstjYZ/previous-Louppe.app`. A background launch on disposable media wrote a format-7 sidecar and logged no faults. Alex's preferences are unchanged apart from the app's own thumbnail-prune timestamp.

Artifacts, the update driver and logs are retained in ignored `dist/release-preparation/1.14.0-18-2026-11-13/`.
