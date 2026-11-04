# Louppe 1.13.0 (15) release — 4 November 2026

Alex authorized publishing 1.13.0 (15) after reviewing the installed build by
hand ("so and publish"); his two UI fixes are in `c86f294`. Version/build stay
1.13.0 (15). Review baseline: published v1.12.0 (`188f48f`, tag object of
`b86dc26`). Release commit and tag: **`v1.13.0` → `fd6b896`**.

## Independent review

Two independent reviewers inspected `v1.12.0..2a410b2`: file operations,
persistence, opening, pins, archive navigation, recovery batching and Undo; and
Photos, keyboard/UI, media, XMP, the Store build and release scripts.

One release blocker was found, pre-existing in 1.12.0: undoing a decision and
then at once undoing a Rename or Organize let the restore's rescan cancel the
pending save and reload the older saved decision. `6b92ec6` makes the reverse
worker await the same safe save as the forward operation and keep the Undo step
if saving fails. A delayed-autosave regression fails without the fix and passes
with it. Non-blocking follow-ups (English-only Photos permission and
namespace-capacity texts; thumbnail eviction failure backoff) are in the backlog.

## CI

Hosted-runner wall-clock budgets failed three attempts on `f999aab`: the
unchanged 10k-folder outline expand measured 3.0–10.0 s against 2 s, and one
retry also tripped warm view switching and the search-field focus drain. Local
timings matched `02b6daa`. `2a410b2` keeps local budgets strict and scales only
those three when `CI` is set; no test was removed.

CI on `fd6b896` passes:
[run 41893453519](https://github.com/murlexander/louppe-media-culler/actions/runs/41893453519)
— 1,346 tests, 66 skips, zero failures; strict Swift 6 build, credential scan,
scrollbar 10/10, media checks and release preflight pass. Its safety runner
passes 72/75 with the 3 real-Trash checks skipped on CI by design.

## Local verification on `fd6b896`

| Check | Result |
| --- | --- |
| Full suite, native backend, window-raising suites excluded | 1,313 tests, 64 skips, 0 failures |
| Window-raising suites (idle gate ≥ 300 s), same source | 33 tests, 1 skip (needs a connected drive), 0 failures |
| Install gates: Hotkey, BrowserScroll, GridScroll, PersistentVerticalScroller | passed within the full suite |
| `Tests/run_performance_checks.sh` | 75/75, including the real Trash round trip |
| Strict Swift 6 build, warnings as errors (`2a410b2`) | passed |
| Scrollbar 10/10, media/video, resource bundles (`2a410b2`) | passed |
| Localization sources | 2,435 literal calls, 0 missing/unsupported |
| Credential scan | `main` history and working edits clean |

The local credential scan's `--all` mode reported 3 generic-API-key matches,
all in another repository's history fetched into this checkout (the
`murlexander` website remote and `t3code/pr-97`). None is reachable from `main`;
CI's checkout does not contain them.

## Direct download

- Developer ID build at `fd6b896`; Apple notarization accepted request
  `5c3adab9-c85f-4fce-b6cf-deb2dfcc6c4b`; stapled and re-archived.
- `Louppe.zip`: 8,825,693 bytes, SHA-256
  `8386a60e6cb9f50b3c33dc4d340a1fbc4374c65b8a5b7ba2c381f3f9c7d726d0`.
- Publishing preflight passes for the loose and archived app independently;
  an extracted archive's complete `Contents/` matches the loose app (symlinks
  compared as links). Gatekeeper: Notarized Developer ID; stapler validates.
- The release binary keeps the existing unconditional `…ForTesting` injection
  parameters (25 in the public 1.12.0 binary); no `LOUPPE_TEST_SEAMS` code ships.

## Publication

- [GitHub v1.13.0](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.13.0)
  is published as Latest. The downloaded public asset matches the ZIP hash and length.
- `5b31e44` publishes the signed feed. The public feed at
  `raw.githubusercontent.com/…/main/appcast.xml` is byte-identical; its feed
  and archive Ed25519 signatures verify. latest-download resolves to v1.13.0.
- Homebrew workflow [41896622796](https://github.com/murlexander/louppe-media-culler/actions/runs/41896622796)
  first lost a push race with the feed commit (it checked out `main` just before
  `5b31e44`). Its rerun passed and committed `36d9080`: cask 1.13.0 with the
  exact ZIP hash.
- All six website language pages (en, es, pt, hi, ar, zh) serve the
  latest-download link; no page hard-codes a version.

## Update and installed app

A real Sparkle 2.10.1 installer upgraded an isolated copy of the exact public
1.12.0 (14) archive (SHA-256 matches the 1.12 record) to 1.13.0 (15). A headless
driver linked to Sparkle's framework, with no UI, read the public signed feed,
downloaded all 8,825,693 bytes, verified, extracted and installed without
launching the app. The updated `Contents/` matches the release; strict
signatures, Gatekeeper and stapling pass. It ran at idle ≥ 300 s; Alex's
Louppe preferences were snapshotted and are identical afterwards. Sparkle 2.10.1
no longer ships `sparkle-cli`; the driver and script are retained with the
artifacts (`headless-update.swift`, `run-idle-checks.sh`, `idle-checks.log`).

The single `/Applications/Louppe.app` (previously a pre-release 1.13.0 (15)
build) was replaced with the released archive after the four install gates
passed; Louppe was not running. Its complete `Contents/` matches the release;
strict signatures, Gatekeeper (Notarized Developer ID) and stapling pass.
Previous copy: `/private/tmp/louppe-1.13-install.t90C8h/previous-Louppe.app`.
A background launch (`open -g`, no focus change) opened a disposable folder,
wrote a format-7 sidecar with all three items and logged no faults; the test
instance was stopped by PID and preferences were restored exactly.

## App Store

The Store app was built and packaged at `fd6b896` in a separate detached checkout.
`verify_release.sh --app-store` and `package_app_store.sh` pass, signed with
Apple Distribution and 3rd Party Mac Developer Installer: SAMO DANNI EOOD
(P6F95J4ZPA). `Louppe.pkg`: 7,731,235 bytes, SHA-256
`7a48daa7110ea3528bd092fad81fe077e9290ea1e3ffa43bb995ba65bd219f66`. The
expanded payload is 1.13.0 (15), has no Sparkle, and carries only the sandbox,
user-selected read-write, app-scope bookmark and Photos entitlements. The App
Store session owned upload, attaching it to the 1.13 draft and submission.

Alex delivered the package through Transporter on 4 November 2026 at 20:33. A
second delivery at 20:34 failed processing as a duplicate of build 15; App Store
Connect has exactly one valid build 15. Export compliance was answered as Apple
system cryptography only. The version was submitted and shows **Waiting for
Review** after reload, releasing automatically after approval. The 1.10-era
preview videos were removed from the 1.13 draft. See [the listing record](APP_STORE_LISTING.md).

Apple's emails for the two deliveries explain the Transporter "1 issue" warnings:

- **ITMS-90189: Redundant Binary Upload** is the duplicate 20:34 delivery, which
  Apple rejected because build 15 already existed. No action.
- **ITMS-90889: Cannot be used with TestFlight because the bundle … is missing a
  provisioning profile.** Non-blocking for App Store review and present since
  1.10; 1.10–1.12 reached sale with it. TestFlight stays out of scope (Alex,
  4 November 2026); the [backlog](../BACKLOG.md#distribution) records what a
  provisioning profile would take.

Artifacts are retained in ignored `dist/release-preparation/1.13.0-15-2026-11-04/`.

## Acceptance limits

Apple review is pending (Waiting for Review). Physical SD/exFAT reconnect, unplug and
power loss, network volumes, VoiceOver task walkthroughs, physical
touch/trackpad and Dock dragging, ISO/JIS/IME input, older macOS, the signed
Store sandbox runtime (stale/revoked grants), battery energy and the multi-camera
RAW corpus remain unverified. They are carried forward, with owners, to the
[backlog's manual acceptance section](../BACKLOG.md#manual-acceptance-needs-hardware-or-alex); see also the
[1.13 backlog record](BACKLOG_1.13_2026-11-04.md).
