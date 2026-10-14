# Localization audit — 2026-10-14

English, Spanish, Simplified Chinese, Hindi, Portuguese, and Arabic each contain
1,623 unique keys. All 1,600 preexisting entries in each catalog were inspected;
23 complete messages were added per catalog. Portuguese consistently targets
Brazilian usage. This is an engineering and language-model review, not a
native-speaker certification.

## Implemented

- Corrected Arabic counters and other stray-brace templates, misleading Fit,
  camera, focal-length, file-size, playback, selection, and search labels.
- Corrected photographic exposure, shutter, burst, highlight, and filename-stem
  terminology; kept Adobe Bridge, Capture One, RAW/JPEG/XMP, units, formats,
  shortcut glyphs, numeric limits, and time-format tokens intact. Chinese
  clipping terminology follows [Adobe’s Chinese Lightroom documentation](https://helpx.adobe.com/cn/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html).
- Corrected English singular grammar and ambiguous Undecided/copy-failure copy
  while retaining catalog key identities. Copy failures no longer assert that
  rollback succeeded when a separate warning may report otherwise.
- Localized missed Export mode/quick picks/results/star summaries, filter range
  separators and summaries, palette footer, zoom accessibility fallback,
  selection labels, and Rename/Organize/Undo file-count messages. Missing-date
  messages no longer append an English plural suffix to a translated noun.
- Let Export menu controls use their intrinsic label width above the existing
  minimum. Arabic fixed numeric ranges and zoom percentages retain LTR order;
  the rest of the interface retains Arabic RTL layout.
- Generate Finder’s Open in Louppe labels from the app catalogs during packaging.
  The service route, file type, port, keyboard routing, stored identifiers,
  generated paths, and file identities remain unchanged.
- Reject empty/damaged translated templates before interpolation, including
  extra braces and unrepresentable slot numbers. Inserted filenames/error text
  remain literal, even when they contain braces or direction controls.

## Validation

Full Xcode 27 / macOS 27 SDK, native SwiftPM backend, isolated source/build root
`/private/tmp/louppe-localization-verification/source`; shared `.build` and `dist`
were not used. VERSION remains 1.11.0 (13).

- All six catalogs: plist syntax, unique/equal keys, exact slot multiplicity,
  technical tokens, unchanged-English allowlist, and complete rendered messages
  without template debris.
- Source literal audit: 1,972 `L10n.text`/literal `L10n.label` calls have English
  catalog entries; this caught missing Contact Alex and Select All labels.
  Numeric-limit/time-format regressions protect the shutter/ISO/preview/XMP limits.
- 97 passing affected XCTest tests in these suites: Localization, Hotkey, Accessibility, Gallery video
  accessibility, RAWJPEGPalette, SourceOrganization, and ReviewGuidance.
- Per-process macOS language overrides (22 tests per language): all six languages, including persistent
  file identity, backup/lock naming, XMP families, and Rename/Undo contracts.
- Seven production-view fixtures per language: Export, Filter, Info with generated
  JPEG/EXIF, Settings, palette, Help, and zoom. Inspected 42 snapshots. Arabic
  glyph joining/RTL, Hindi text, Portuguese menu widths, translated quick picks,
  and literal filename braces were checked. Scrollable content continues below
  the viewport; the snapshots cover the initial visible state.
- Finder service test generates a disposable plist, compares every service label
  with the catalog, and verifies the selector/port/types/context are unchanged.
- A separately signed debug QA app, with a unique bundle ID and isolated home,
  launched in Arabic, scanned disposable media, and saved a valid format-7 session.
  Its backup/journal directory was isolated; only its exact PID was stopped.
  Computer Use's live screen capture failed with ScreenCaptureKit error -3811,
  so native view snapshots supply the visual evidence; live app interaction was
  not accepted as verified.
- Shell syntax and whitespace checks pass.

Set `LOUPPE_LOCALIZATION_SNAPSHOTS` when running
`LocalizationTests.testLocalizedPresentationFixtures` to save native images.
Run the test bundle separately with `-AppleLanguages '(ar)'` (or the other locale)
and `LOUPPE_TEST_LANGUAGE=ar`; the language-preference assertion guards against
accidentally testing English text under an RTL-only environment.

## Remaining acceptance gaps

- OS-provided errors and low-level diagnostic operation names can retain their
  system/technical language; they remain literal values inside translated errors.
- Native-speaker review in all five translated languages, including photographic
  vocabulary and long safety/recovery instructions.
- Arabic plural categories and count agreement beyond the existing singular/plural
  message branches. Structural rendering tests prove valid templates and intact
  arguments, not grammatical agreement for every number.
- Every modal, expanded filter, lower Settings section, menu-open state, large
  filename/count, accessibility traversal, and window/display configuration.
  Fixture snapshots are targeted layout checks, not full visual acceptance.
- Actual Finder service registration and installed direct/Store package behavior.
  The service generator was exercised on disposable plists without registering
  a second service. No running/review app was replaced or installed over.

No commit, push, release, upload, or App Store media/listing change was made.
