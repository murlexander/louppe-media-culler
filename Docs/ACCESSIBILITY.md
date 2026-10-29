# Accessibility audit

Reviewed 29 October 2026 against Apple's current guidance and macOS 27.2 release
notes. Runtime: macOS 27.2 (26B123). Toolchain: Xcode 27.2 RC (27B48), macOS 27.2
SDK, macOS 14 deployment target.
Apple currently lists Xcode 27.2 RC (27B48), released 19 October, as the
toolchain containing the macOS 27.2 SDK; the latest stable Xcode is 27.1.
The official archive's Apple package signature and deep, strict app code
signature passed verification. The RC is installed at `/Applications/Xcode.app`;
its version, SDK and first-launch checks pass. Xcode 27.1 is preserved at
`/Applications/Xcode 27.1 Backup.app` for rollback.

This is an engineering audit, not a claim of complete accessibility or an
App Store accessibility declaration. Apple requires audits of each screen and
task testing with assistive technologies; passing automated checks is insufficient.

## Acceptance

- Browser and Grid expose their mounted cells, decisions, selection and custom
  actions in reading order, including after scrolling, recycling and RTL layout.
  Native accessibility parent/child links remain consistent.
- Starting an assistive technology or changing Increase Contrast refreshes
  separately hosted cells without resetting the browsing position.
- Review, file-operation dialogs, Settings, Help and media controls have named
  controls and keyboard alternatives to gestures. Text editors, native controls,
  modal UI and VoiceOver retain their keyboard chords.
- Custom charts expose their evidence in words. Photo previews identify the
  current filename; playback exposes elapsed time and duration.
- Color labels have a textual alternative under Differentiate Without Color.
  Increase Contrast supplies readable purple text and stronger custom outlines.
- Reduce Motion and Reduce Transparency remain supported. Read-only document
  previews can enlarge text to 200% without losing Markdown or selection.
- Build and launch succeed; keyboard, scrolling, media and localization checks
  pass. Live desktop checks use Alex's explicit handover, disposable media and
  reversible setting changes; original settings are restored afterward.

## Findings and implementation

Live inspection of the pre-audit installed app found a Browser scroll area with
no thumbnail children, an unnamed main photo, and a histogram with no value.
The thumbnails were visible in a background screenshot. This was an actual
accessibility-tree omission, not an empty-folder state.

`ReviewCollectionDocument` now owns a labeled native group and returns the
mounted hosts' unignored SwiftUI elements in projection order, using AppKit's
public helper to preserve parent relationships. Recycling cannot reorder reading
order. Independent hosting views receive explicit app presentation values rather
than the outer host's complete environment, whose private accessibility context
can suppress their trees. Their bounded accessibility subtrees stay available
to Inspector and other clients without requiring VoiceOver to be on.
Only mounted cells are exposed; native scrolling
realizes subsequent content without allocating accessibility objects for an
entire large folder. Changes to accessibility enablement, VoiceOver, contrast
and legibility weight invalidate the hosted environment. Group headers have
heading traits.

Gallery photo and Photos-preview images use literal filenames as their labels.
The fitted photo has an accessible 100% action alongside the existing zoom
controls. The histogram reports its RAW/preview source and measured near-black
and near-white percentages; it does not describe those estimates as lost detail.
The clipping, star, Info decision, filename-cancel, recovery-dismiss and
organization-remove buttons have 36-point custom targets. Native controls
retain their native sizes. Enabled disconnected-folder actions retain readable
contrast instead of dimming an entire actionable row.
The timeline speaks elapsed
time and total duration, and hides duplicate time labels from navigation.

Thumbnail color labels show localized names when Differentiate Without Color is
enabled. Selected thumbnails use dashed borders to distinguish them from the
solid current-item border under that setting. Yes/No already use different
symbols; stars use count/shape. The normal
brand purple is #9853A6 in light appearance and #B980C6 in dark appearance.
The previous dark purple measured 3.27:1 against the native dark background;
the replacement measures 5.53:1. Increase Contrast uses #794087 in light appearance
and #CE99DA in dark appearance, shared by the SwiftUI color and packaged native
accent asset. Selected custom keycaps use contrasting ink in dark appearance
and Increase Contrast. Native filled buttons, segmented choices and filled
glass actions, switches and checkboxes use darker purple to keep their native white text and symbols
readable; foreground accents retain the lighter dark-mode purple. Yes uses a black check on system green, preserving
nontext contrast; No keeps its white X on system red. Floating glass gains a strong outline; its opaque
Reduce Transparency and Reduce Motion paths remain intact.

Keyboard Navigation keeps Tab/Shift-Tab for native focus traversal, including
the first Tab before any control owns focus. G remains a view-switch shortcut.

Info exposes subtitle and alternative-audio choices without preparing another
player or autoplaying. The current item owns manual choices across Gallery/Grid;
a replacement item returns to automatic criteria. On macOS 26.4+, AVKit supplies
its native subtitle and caption-style menu. If that menu omits authored languages,
a Subtitle tracks submenu keeps Automatic, Off and every authored option reachable.
Forced-only alternatives stay under automatic selection rather than duplicating
languages in that supplemental menu; native attachment badges are ignored when
checking whether AVKit already exposes the same language.
Older systems use native subtitle pickers; alternative audio uses a native picker.
Cancelled loads and exact current-item identity guards reject stale choices.
Each supplemental menu action also captures its original item, so a menu left
open during replacement cannot change the new item after its coordinator updates.

General Settings includes Text preview size (100%, 125%, 150%, 200%). The native
text view scales fonts, Markdown headings and paragraph spacing; ordinary rating
updates do not replace text storage. Text loading has a descriptive progress
label. Help, collection groups, audio levels and quality-cue titles expose
headings. New messages are present in all six localization catalogs.
Alex chose to keep native control sizing on 29 October. Document enlargement
does not scale the Info panel, dialogs or toolbars; whole-interface text scaling
is outside this implementation's accepted scope.

## Task and settings matrix

| Surface | Main tasks and required states |
| --- | --- |
| Welcome | Open Folder/Photos; recents, pins and disconnected sources; Help |
| Opening | Progress, cancel, read-only browsing, transition to ready |
| Gallery/Browser/Grid | Navigate, select/range/select all, decide, stars, color, undo; sort/group/filter; empty results; photo zoom/pan |
| Info and quality cues | Read filename/metadata, edit filename, inspect histogram, thresholds and evidence |
| Video/audio/text | Play/pause/seek/mute/volume/rate; unavailable media; captions/alternative audio where present; select/copy/link/enlarge documents |
| Photos | Permission denial, album/date choices, iCloud choices, downloads/cancel/retry; review preview versus original; confirmed album changes |
| File tools | Export Copy/Move/XMP, Rename, Organize, Trash; setup, preview, warnings, confirmation, progress, partial failure and completion |
| Recovery | Nonblocking warnings, saved decisions, interruption recovery, persistence retry |
| Settings/Help/palette | Navigate native tabs/forms, edit/search shortcuts, resolve conflicts, run actions, read guide |

Run these tasks with light/dark appearance, Increase Contrast, Reduce
Transparency, Reduce Motion, Differentiate Without Color, color filters,
keyboard-only navigation, VoiceOver, Voice Control and Switch Control. Check
narrow/wide windows, Arabic RTL, long names, large collections and text size.

## Verification on macOS 27.2

- The final Xcode 27.2 suite passed **1,115 tests, 48 skips, zero failures**.
  It includes complete Hotkey, BrowserScroll, GridScroll and
  PersistentVerticalScroller install gates. Skips remain skips, not passes.
  Native structure tests check reading order after recycling, closed parent
  links, an accessibility-disabled outer host, and text-size updates retaining
  the native text view and selection. Contrast tests cover all four accent
  variants and both decision glyphs in light/dark appearance. The packaged
  accent catalog is checked against all four palette variants.
- The SDK 27.2 safety/performance runner passed **75/75**. Subsequent changes
  affect view presentation and keyboard routing, not its core workers.
  Complete localization/template checks passed for all six catalogs.
- Four native media tests passed with a generated MOV containing authored SDH,
  French subtitles, ordinary audio and described-audio tags. They verify
  automatic selection, manual French/off/automatic changes, Gallery/Grid
  attachment, new-item reset, and the native menu's authored language choices.
  They preserve system caption preferences. macOS can add generated transcript
  options; checks validate authored choices without assuming a fixed group size.
  A separate AVFoundation legible-output check decodes its authored `[Silence]`
  cue. The fixture explicitly uses `tx3g`: ffmpeg's legacy QuickTime `text`
  entry exposed selectable tracks but produced no decoded cue. An inactive
  AppKit/XCTest process deferred captions; the standalone check avoids that
  foreground dependency. The audio tracks are silent stubs: this proves
  selection, not narration quality.
- Fresh English and Arabic/RTL capture runs passed with **70 PNGs each**.
  Representative light/dark rating targets, Info, organization, Settings,
  keycaps and 200% text were reviewed. Offscreen captures omit composited glass;
  a live Gallery check confirmed the zoom value uses readable native ink over
  its composited material. Read-only system environments are not simulated as
  global-setting tests by injecting high-contrast appearances.
- The final SDK 27.2 release package built, signed and passed loose/archive
  preflight as **1.13.0 (15)**. Its executable records **SDK 27.2** and
  **minimum macOS 14.0**; a separate archive extraction passed strict signature
  verification. The final package installed and launched successfully; all
  **110** installed file/symlink entries matched the archive and strict signature
  verification passed again after native checks.
- Live AX checks on disposable media confirmed Browser/Grid children, filename
  labels, decisions, selection/current values, actions and histogram evidence.
  Decide Yes/Undo restored the saved decision; native scrolling, Make Current
  and Open in Gallery reached later items. These are accessibility client
  actions, not a substitute for a VoiceOver user test.
- All **44** native-test originals retained their SHA-256 hashes (43 initial
  files plus the separate corrected caption fixture); all temporary
  decisions and color labels were undone. Validation itself did not stage,
  commit or push source changes.
- Final installed-app AX confirmed the previous `Touch-check-05.png` review in
  Gallery with Browser and Info visible, at **0/40 reviewed, Saved**. The final
  native Settings switch had readable white ink on darker purple, exposed one
  correctly named switch, responded to both changes and returned to its original
  On value. The temporary folder entries were removed from the actual direct-app
  preference domain; other review preferences were retained without a reset.

### Live system-setting checks

Alex authorized desktop takeover for these checks. The initial SDK 27.2 package
was used to discover the final keyboard, contrast and media-control fixes.

| Setting | Observed result | Restored baseline |
| --- | --- | --- |
| Increase Contrast | Stronger purple and custom outlines appeared | Off |
| Differentiate Without Color | Localized Purple badge and dashed noncurrent-selection border appeared; spoken state updated | Off; temporary label undone |
| Reduce Transparency | Opaque transport retained named controls | Off |
| Reduce Motion | Gallery/Grid transition preserved the current item and paused player | Off |
| Color Filters | Yes/No labels and distinct check/X remained available with protanopia, deuteranopia and tritanopia selected | Off; Grayscale; intensity 1 |
| Keyboard Navigation | First Tab entered native focus navigation and retained Gallery; Shift-Tab also retained Gallery; real-event/context tests cover routing | Off |
| VoiceOver | System engine started and tutorial opened; navigation output could not be observed through the native connection | Off |
| Captions | Native track menus and described-audio selection worked; English SDH `[Silence]` rendered in the foreground with the corrected fixture | Native captions Off; Prefer SDH Off; Transparent Background |

System color-filter switches were verified, but screen captures did not show the
physical display's color transform. That check proves semantic/symbol support,
not visual simulation of a person's color perception. Other caption preferences
(language mismatch, muted playback, skip-back and apply-across-apps) were retained.

Evidence: `/tmp/louppe-a11y-sdk272-final-all-tests.log`,
`/tmp/louppe-a11y-sdk272-performance.log`,
`/tmp/louppe-a11y-sdk272-release-final.log`,
`/tmp/louppe-a11y-sdk272-verified-ui-en.log`,
`/tmp/louppe-a11y-sdk272-verified-ui-ar.log`,
`/private/tmp/louppe-accessibility-sdk272-verified-ui-en-20261029/`,
`/private/tmp/louppe-accessibility-sdk272-verified-ui-ar-20261029/`, and
`/private/tmp/louppe-accessibility-native-20261029/`.

Public system-state reads after the final native session confirmed VoiceOver,
Increase Contrast, Reduce Transparency, Reduce Motion and Differentiate Without
Color were Off. Caption display was Automatic (not Always On), retaining the
original language-mismatch behavior. These configuration reads are not assistive
technology task tests.

## Remaining acceptance work

- After final native switch validation, closing Settings hit
  `Computer Use server error -10005: timeoutReached`. One connection reset and
  exact `/Applications/Louppe.app` rebind returned the same error. CUA input was
  stopped as agreed. The app process remained alive and idle in its normal
  AppKit event loop; that does not prove subsequent window behavior. The restored
  review state was confirmed before this last Settings-close attempt. Further
  native checks, including a fresh VoiceOver attempt, are unverified.
- Accessibility Inspector selected the native Louppe process and exposed all
  six audit options, but Run Audit produced no numbered result, issue list or
  report. Restarting Inspector, reselecting Louppe and a foreground attempt did
  not resolve it. Its target-menu dialog later blocked another app's native
  tests; it was dismissed and Inspector was quit. No Inspector process remained.
  No empty result is counted as a pass. A complete exported Inspector report
  for each matrix state remains required.
- Actual VoiceOver navigation, rotor use, offscreen selection, focus after
  sheets, Voice Control and Switch Control need observable interaction on a
  physical Mac. The VoiceOver output/rotor connection timed out; enabling its
  system switch alone is not successful user-task validation. VoiceOver's
  AppleScript control permission was not enabled as a workaround.
- Verify every workflow in the task matrix with assistive technologies,
  including Photos permissions/cloud failures and file-operation failure/recovery
  states. Native structure tests and staged screenshots cover their stated
  contracts, not every real user task.
- Verify actual narrated audio descriptions, caption appearance and composited
  media controls with representative real media. Generated captions are
  framework/content dependent; no arbitrary-media transcript claim is made.
  Apple's AVPlayer path supplies system flashing-light dimming; a physical
  playback check remains outstanding and no flashing test content was shown.
- macOS 14 runtime and physical touch input remain separate compatibility checks.

## Sources

- [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple HIG: VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)
- [VoiceOver caption panel](https://support.apple.com/guide/voiceover/use-the-braille-and-caption-panel-unac078/10/mac/27)
- [VoiceOver rotor](https://support.apple.com/guide/voiceover/voiceover-rotor-mchlp2719/mac)
- [Apple HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
- [Performing accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
- [Performing accessibility testing](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)
- [SwiftUI accessibilityEnabled](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityenabled)
- [SwiftUI Dynamic Type on macOS](https://developer.apple.com/documentation/swiftui/environmentvalues/dynamictypesize)
- [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)
- [AppKit high-contrast appearance](https://developer.apple.com/documentation/appkit/nsappearance/name-swift.struct/accessibilityhighcontrastdarkaqua)
- [AVFoundation media selection](https://developer.apple.com/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks)
- [Native AVKit subtitle menu](https://developer.apple.com/documentation/avkit/avlegiblemediaoptionsmenucontroller)
- [WWDC26: Generated subtitles and subtitle styles](https://developer.apple.com/videos/play/wwdc2026/256/)
- [Flashing-light setting and native playback](https://developer.apple.com/documentation/mediaaccessibility/responding-to-changes-in-the-flashing-lights-setting)
- [macOS 27.2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27_2-release-notes)
- [Xcode SDKs and system requirements](https://developer.apple.com/xcode/system-requirements)
- [Xcode 27.2 RC release](https://developer.apple.com/news/releases/?id=10192026g)
