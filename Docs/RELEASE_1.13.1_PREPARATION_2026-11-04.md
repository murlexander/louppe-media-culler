# Louppe 1.13.1 (16) release — 4–5 November 2026

Alex chose to release 1.13.1 at once instead of holding it for Apple's 1.13
approval. In the App Store, the 1.13.0 (15) submission was withdrawn and its
draft renamed to 1.13.1. Release commit and tag: **`v1.13.1` → `db6e707`**
(published 5 November 2026, about 00:15 CET; the changelog heading keeps the
4 November preparation date).

`db6e707` is Dependabot PR #4 (actions/checkout 6.1.0 → 7.0.1 in the Homebrew
workflow) squash-merged on top of `dae35cb`. The two commits differ only in
`.github/workflows/homebrew.yml`. All release artifacts were built from `db6e707`;
the source gates ran on `dae35cb`, whose app tree is identical.

## Changes

Three follow-ups from the 1.13 release review, each with tests:

- `f210790`: thumbnail-cache maintenance counts files it could not delete, reports
  failed passes, and backs off live retries (1, 2, 4, at most 8 write intervals).
  Deletion-failure fault injection fails without the fix.
- `70926f9`: localized `InfoPlist.strings` for the Photos permission prompt in all six
  languages, in both direct and Store builds; `verify_release.sh` checks every
  language for every usage description.
- `dbe3aa3`: the XMP namespace-capacity error has its own bridge status and localized
  app text; the vendored toolkit is unchanged.

## Verification

| Check | Commit | Result |
| --- | --- | --- |
| Full suite (window-raising suites excluded) | `dae35cb` tree | 1,318 tests, 64 skips, 0 failures |
| Window-raising suites, idle 326 s | `db6e707` | 33 tests, 1 skip (needs a connected drive), 0 failures |
| Install gates: Hotkey, BrowserScroll, GridScroll, PersistentVerticalScroller | `dae35cb` tree | passed |
| `Tests/run_performance_checks.sh` | `dae35cb` tree | 75/75, including the real Trash round trip |
| Strict Swift 6, scrollbar 10/10, video, resource bundles, localization (2,438 calls) | `dae35cb` tree | passed |
| CI [41929356309](https://github.com/murlexander/louppe-media-culler/actions/runs/41929356309) | `db6e707` | 1,351 tests, 66 skips, 0 failures |

## Direct download

- Developer ID build; Apple notarization accepted request
  `c2a3d4d9-5ec8-4783-9d45-c9a3f938e329`; stapled and re-archived.
- `Louppe.zip`: 8,840,986 bytes, SHA-256
  `8584fa839e277cc2668ea61409485dab7e9353b542b3dc7575d450e7ddce75b7`.
- Publishing preflight passes for the loose and archived app; an extracted
  archive's `Contents/` matches the loose app; it carries six `InfoPlist.strings`.
- [GitHub v1.13.1](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.13.1)
  is Latest; the public asset matches the hash and length.
- `941b710` publishes the signed feed; the public feed is byte-identical and both
  Ed25519 signatures verify. latest-download resolves to v1.13.1; all six website
  language pages serve that link.
- Homebrew workflow [41932302628](https://github.com/murlexander/louppe-media-culler/actions/runs/41932302628),
  its first run on checkout 7.0.1, passed on the first attempt and committed
  `e1c4067`: cask 1.13.1 with the exact ZIP hash.

## Update and installed app

Idle-gated (434 s), the retained headless Sparkle driver upgraded an isolated copy
of the public 1.13.0 (15) archive (SHA-256 `8386a60e…26d0`) to 1.13.1 (16) from the
public signed feed: all 8,840,986 bytes downloaded, verified and installed without
launching the app. The updated `Contents/` matches the release; strict signatures,
Gatekeeper and stapling pass.

`/Applications/Louppe.app` (1.13.0) was replaced with the released archive after the
install gates passed; Louppe was not running. Its `Contents/` matches the release;
signatures, Gatekeeper and stapling pass. Previous copy:
`/private/tmp/louppe-1.13.1-install.uPC94T/previous-Louppe.app`. A background launch
(`open -g`) opened disposable media, wrote a format-7 sidecar and logged no faults;
Alex's preferences were snapshotted and are identical afterwards.

## App Store

Built and packaged at `db6e707` in a separate detached checkout;
`verify_release.sh --app-store` and `package_app_store.sh` pass (Apple Distribution
and 3rd Party Mac Developer Installer: SAMO DANNI EOOD, P6F95J4ZPA). `Louppe.pkg`:
7,740,064 bytes, SHA-256
`0488c0e6163c2ea328d748f1df2a79eff629ce52ee7b1f2eb49b8bb002e26245`. The payload is
1.13.1 (16) with six localized `InfoPlist.strings` and no Sparkle. The App Store
session owns delivery (Alex's Transporter click), attaching build 16 and
submission; it records the outcome in [the listing record](APP_STORE_LISTING.md).

Artifacts, validation logs, the driver and check script are retained in ignored
`dist/release-preparation/1.13.1-16-2026-11-04/`.

## Acceptance limits

Apple review of 1.13.1 is pending. The localized Photos prompt was verified in the
bundle, not by triggering the system prompt in each language. The hardware,
assistive-technology, older-macOS and people checks remain in the
[backlog's manual acceptance section](../BACKLOG.md#manual-acceptance-needs-hardware-or-alex).
