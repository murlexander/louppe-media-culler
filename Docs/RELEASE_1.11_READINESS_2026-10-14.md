# Louppe 1.11.0 (13) release preparation

One-time readiness check started 14 October 2026 at 12:44 America/Toronto.
All four coding chats completed; source stability was reconfirmed after native QA.

Status: implementation and final automated validation are complete. Signed direct
and Store candidates are prepared locally. Direct notarization/stapling is blocked:
the documented `louppe-notary` Keychain profile is missing. No release or Store
submission has been published. The exact source commit, artifact checksums,
verification and post-push CI state are recorded in the local release manifest.

Local artifacts: `dist/release-preparation/1.11.0-13-2026-10-14/`.
The direct ZIP is a signed candidate, not a notarized distributable. The Store
installer is signed and verified but still requires the acceptance below.

## Coding chats

| Chat | Latest observed state |
| --- | --- |
| Profile Louppe performance | Completed: optimization, full suite, safety checks and review-app installation verified |
| Audit and improve all Louppe localizations | Completed: six catalogs, source copy, service labels, layout and regressions |
| Redesign zoom bar as glass overlay | Completed: floating zoom, menu hints, Browser/Grid bounds, including short Grid |
| Create dark Louppe App Store media | Completed staging: listing draft still needs a final binary and refreshed affected captures |

The app remains on main; the checked upstream baseline was
544f6222a499b316d419797e358c232fd56e410a. VERSION remains 1.11.0 (13).
The final local manifest records the pushed source commit without a release tag.

## Final verification

Fresh checks against unchanged production sources:

- Full XCTest: 754 executed, 718 passed, 36 explicit skips, zero failures;
  all 35 HotkeyTests included. The skips include optional speed/RAW fixtures,
  mounted volumes/remount, another display and hosted accessibility.
- Required performance/file-safety checks: 75/75. Scrollbars: 10/10.
  Standalone media/video checks and strict Swift 6 warnings-as-errors build pass.
- Source localization audit: 1,972 literal callsites, no missing keys.
- Three optimized cue-filter methods pass at 1k/10k/100k, with one warmup and
  seven samples. The final 100k first-use high-ISO median was 47.1 ms; these are
  model timings, not physical frames.
- Twelve cue-session tests pass with real disposable Fuji RAW enabled, including
  the Info-closed bounded-source evidence test.
- Isolated production-code QA copy launched, exposed floating zoom and Quality
  Cues, and saved five undecided entries in schema 7; all five generated photos
  remained byte-identical. This check did not replace the installed review app.
- Credential scans pass. Seven historical digest maps were reshaped into explicit
  path/sha256 records to remove proven generic-key false positives; every original
  path/digest pair remains intact. Whitespace checks pass.
- Direct loose/archive strict signatures and all 110 file/symlink entries match.
  Store loose/archive strict signatures and all 16 entries match; the signed
  installer payload has the correct team, three sandbox/bookmark entitlements,
  privacy/licenses and no Sparkle/feed. Apple MacDistributionInstaller policy
  validation and exact signed/payload comparison pass in the packaging script.

Supporting implementation records:

- [Final cue-filter work](QUALITY_CUE_FILTER_PERFORMANCE_2026-10-14.md): 754 tests,
  718 passed, 36 explicit skips, no failures; all 35 HotkeyTests and 75/75 required
  performance/file-safety checks. Optimized runs independently confirm retained
  cue matches and bounded per-result classification updates.
- [Localization audit](LOCALIZATION_AUDIT_2026-10-14.md): 97 affected tests, 22
  localization tests per language, 42 inspected native snapshots, isolated launch.
  Native-speaker review and full modal/layout acceptance remain open.
- [UI review record](REVIEW_BUILD.md): final short-Grid bounds fix and focused
  keyboard/layout coverage; live pointer acceptance remains limited.

## Draft public release notes

- Review photos with a floating zoom control, more image space, and clearer
  Gallery/Grid menu shortcuts. Browser and Grid no longer scroll sideways.
- Find high ISO, slow shutter, near-white and near-black photos with Quality
  Cues; adjust independent rules and review timestamp-based capture bursts.
- Retain earlier decisions when files change. Verified copies recover decisions;
  older entries offer explicit restoration and retain recovery history.
- Review large folders with faster pairing, sorting and cue filters, independent
  Gallery loading, smaller saved sessions, and paced background checking.
- Use consolidated Settings and improved English, Spanish, Simplified Chinese,
  Hindi, Brazilian Portuguese and Arabic text and controls.
- Support Louppe with optional tips. All features remain free and open source.

Compatibility: 1.11 saves session format 7. Louppe 1.10 cannot read sessions saved
by 1.11. Preserve a copy of saved sessions before evaluating a downgrade.

## Remaining integration and publication handoff

1. Confirm all coding and shared validation have stopped. Review intended tracked
   and untracked changes, including performance evidence, for private/generated
   content. Do not stage unrelated files, private photos, secrets or raw local
   machine data merely because they are untracked.
2. Establish upstream, review the integrated diff, and run final full XCTest,
   complete HotkeyTests, localization and affected cue/performance checks, plus
   Tests/run_performance_checks.sh. Use full Xcode/current SDK and the documented
   working backend. Record every skip separately; prove launch/save/recovery and
   media integrity on disposable fixtures without replacing the installed app.
3. Commit intended completed app work on main and push normally, as authorized.
   Verify the remote commit and CI. Tie final artifact manifests to that exact
   source commit; no force-push or release tags.
4. Restore the documented notarization profile. Submit and staple the
   Developer ID app, recreate its ZIP, and reverify Gatekeeper/checksums/Contents.
   Only then prepare the signed Sparkle feed from the final archive. The current
   candidate has passed signing/Contents checks but has no notarization ticket.
5. Retain the prepared Store installer and exact checksums. Complete signed Store
   workflow and purchase acceptance before upload/submission. The local-check ZIP
   is an ad-hoc test package, not an upload artifact.

## Remaining release acceptance

- Signed Store folder/Recent/routing/recovery behavior and real sandbox tip
  checkout: success, cancellation, errors, pending approval across relaunch,
  unavailable products and repeat tips. Mock tests do not establish checkout.
- Native accessibility settings, older-macOS glass fallback, long/expanded/modal
  layouts and native-speaker review; Arabic plural agreement remains limited.
- Representative high-speed Fuji/separate-press/mixed-camera bursts and sustained
  RAW CPU/GPU, memory, battery/AC responsiveness, Pause/Close and true idle.
- Refresh affected Store screenshots/video for final 1.11 UI and corrected
  translations. The staged 36 screenshots/six previews use 1.10 captures; final
  poster processing and the proposed dark icon require separate acceptance.
  See ../../media-library/2026-10-13/dark-store/STORE-UPDATE.md.

Publishing, release tags, signed appcast publication, website deployment and App
Store upload/submission remain outside this preparation step. Do not claim that
manual/hardware acceptance has been completed without new evidence.
