# Louppe Media Culler

[Louppe](https://louppe.eu) is a free, open-source photo viewer and sorter for
Mac. Browse JPEG and RAW folders, choose keepers with the keyboard, and copy
selected files or send rejects to macOS Trash with a separate command. Review
video, audio, and read-only text alongside your photos.

Photo culling means choosing which photos to keep. Louppe works as a local
image viewer and photo browser without a library import or subscription.
Stars and color labels are optional; JPEG-only shoots need no RAW editor.

Requires Apple silicon and macOS 14 or newer. Intel Macs are unsupported.

![Louppe Gallery with an apple-tree photograph, RAW+JPEG pairing, camera settings and histogram](Docs/Media/2026-09-26/gallery-info.png)

*Gallery in Louppe 1.9.* [Watch the 25-second walkthrough](https://louppe.eu/#review-demo).

## Download

Download **[Louppe.zip](https://github.com/murlexander/louppe-media-culler/releases/latest)**,
unzip it, and drag `Louppe.app` into Applications. The public download is
signed with Developer ID and notarized by Apple; macOS may ask you to confirm
its first launch.

## Quick start

1. Open a folder or memory card.
2. Review media in Gallery or Grid; switch from the toolbar or the View menu.
3. Press **F** for Yes or **D** for No.
4. Filter, sort, select, clean up, organize, or export.

In Finder, select a media folder and choose **Services → Open in Louppe**.
Install Louppe in Applications first to register the service. It opens the
folder in the existing window.

You can also drop one folder onto the Dock icon or anywhere in the main window,
including while reviewing another folder. Louppe saves current decisions before
switching and keeps your chosen review-window size.

![Louppe Grid comparing street scenes, architecture, reflections and still life, with a photo selected in purple](Docs/Media/2026-09-26/grid-overview.png)

*Grid for comparing and selecting frames.*

The toolbar shows review progress and save status. Its dropdown holds active
filter details and review tips. The floating photo control provides Fit and 30–400% zoom.
Double-click anywhere on the zoom control to Fit.
Pinch to zoom; pan with two-finger scrolling or dragging.
**S** returns custom zoom to centered 100%, then toggles Fit; **A** toggles
Phone size. **Help → Louppe Help** has searchable shortcuts. Dismissed review
tips can be restored from Help.

Yes/No, stars, and color labels are independent. **No never trashes files.**
Ratings save automatically; reopen the folder to continue. The toolbar status
popover confirms when every item has a decision.

Export starts with **All selected** when you select items, otherwise with
filtered **Keepers (Yes)**. **4–5 stars** includes either decision. Check the
matching count before choosing a destination. Export copies by default;
Move transfers originals, and Metadata (XMP) writes ratings to sidecars for
other apps. **Clean Up** sends files to macOS Trash. **Organize Source Folder**
builds folders from decisions, dates, ratings, and other metadata.

## Apple Photos

Choose **File → Open Apple Photos…** and grant Photos access. Select your
library or an album, narrow the dates manually or with **Recent Dates → Last
Week / Last 7 Days**, and open a batch of 50, 100, 200, 500, or 1,000 items
in the usual Gallery or Grid. **Previous Batch** and **Next Batch** save decisions
before switching. The chooser remembers the last range and batch; new library
items can shift batch numbers after reopening.

The selection opens without downloading every original. Review images load as
you browse. Enable **Allow iCloud Review Images** when a needed image is not
on the Mac. Photos may download source data to make that image; Louppe cannot
guarantee thumbnail-only network transfers. Cached local representations can
work offline. Cloud/unavailable items have Retry; Gallery shows preview pixel
dimensions and never treats a preview as 100% original detail.

**Open Original Detail**, original video playback and Copy request primary
original files separately. **Allow iCloud Originals** is a separate choice.
Requests show progress and can be canceled. Original staging remains limited
to 5 GB, including any open original detail. Copy downloads, validates and
copies one exact original at a time, then releases its temporary file. Total
export size is unknown until originals load; space is checked for each file.
Temporary files retire when released or when switching/closing the batch.

Yes/No, stars, and colors save locally by Photos asset ID across overlapping
batches. One-destination Copy is available; Photos routing Copy, Rename,
Organize, Move, XMP and Trash are unavailable. Decisions never change Photos
albums, favorites or library contents. EXIF, original byte sizes and original
quality/exact/similarity checks are unavailable during preview review. Capture
groups use known Photos dates without downloading originals.

This uses the System Photo Library. Review previews are unadjusted, excluding
Photos edits; original detail and Copy use the primary original resource.
Live Photos use their still image; RAW+JPEG assets remain one primary-original
review item. Hidden items are excluded. Libraries on unmounted drives and
unavailable originals must be made accessible in Photos first.

## Review and file handling

- Filter and sort by decisions, stars, colors, dates, folders, camera details,
  file types, and media properties.
- Fuji film simulation appears in Info and **Filter → Film simulation**. Include
  any combination of the recorded simulations, including monochrome and ACROS
  variants; hidden photos keep their decisions. **All** restores that facet.
- **Sort → Folder hierarchy** shows root files, then each folder before its
  descendants. Reversing changes sibling order; headers show relative paths.
- **Sort → Review groups → Analyze Folder Locally** finds exact duplicates,
  likely similar photos, and bursts. Analysis stays on your Mac and never
  changes ratings or files automatically.
- **Filter** can group matching RAW+JPEG files as one item while retaining
  separate decisions, stars, and colors.
- **Clean Up** supports All Media, Filtered, and Selected scopes, plus
  RAW-only or JPEG-only Trash for unambiguous pairs. **⌘Z** restores the batch
  before closing the session, while files remain in Trash.
- **Organize Source Folder** previews nested folders before moving files.
  **Rename Files…** supports single names and metadata-based batches. Drag
  filename parts into order; dates follow the Mac’s preferred format with safe
  filename separators. Extensions stay unchanged and recognized RAW+JPEG/XMP
  families follow.
- Export Copy and Move support All Media, Filtered, and Selected scopes.
  **Route copies to multiple folders** previews decision, stars, color,
  file-type, or media-type rules before copying.

**Settings** is one scrolling page for review defaults, RAW display, quality
cues, the getting-started guide, updates, and optional support. Review and
New folders set defaults for advancement,
Gallery/Grid, sort, and dividers in new folders. Rescan keeps the current
layout. Connected drives and cards appear on the start screen with capacity
and a folder chooser.

Ratings save to `.louppe_session.json` in the opened folder. An identity-bound
local backup can protect the session when that folder or card is unavailable.
Changed-file decisions remain in recovery history while you keep reviewing.
**File → Check Saved Decisions…** offers restoration; verified identical copies
and returning originals recover automatically. Older sessions need confirmation.
Sessions saved by 1.11 use a newer format that 1.10 cannot read.

## Media and inspection

Louppe supports common camera RAW, JPEG, TIFF, PNG, HEIC, JPEG XL (.jxl),
WebP, AVIF, video, audio, and text formats. Unsupported files remain available to rate and export.
Gallery has Fit, Phone size, true 100% zoom, playback, metadata, histogram,
clipping information, and optional quality cues. VoiceOver and keyboard review
are supported.

For RAW photos, **Fast** uses previews below 100% and Apple RAW rendering at
100% and above. **Settings → RAW display** can use RAW at all zoom levels.
The Gallery zoom bar stays focused on Fit and magnification; **Use Preview**
remains an explicit fallback after a RAW loading failure.
Apple rendering may differ from your editor or the camera JPEG.

RAW display settings offer **Apple Default** or opt-in **RAW 9**.
RAW 9 requires macOS 27, a supported file, and Apple’s model resources; it
uses more time and memory. Failure offers Retry or **Use Apple Default**;
Louppe never silently switches decoders. Grid and Browser retain fast previews.

For RAW files, the histogram switches from **Preview** to **RAW** after a scaled
linear analysis, independent of photo rendering. Other photo formats have no
source tag. The **X** overlay measures the displayed rendering.

**Filter → Quality cues** finds High ISO, Slow shutter, Near-white and Near-black
areas. Set their switches and thresholds in **Settings → Quality Cues**; cues
appear inside Browser/Grid tiles and below the Info histogram. Checks prioritize
photos you view and pace the remaining folder in the background. Use **Pause checks**
and **Resume checks** in Filter; Pause stays in effect until you resume. Cues never
set decisions.
**Filter → Capture bursts** groups consecutive photo times within the chosen gap;
set the interval in **Settings → Capture bursts**. It can merge separate shutter
presses or cameras. Inferred dates are labeled.

Text previews are read-only and selectable. TXT, TEXT, MD/MARKDOWN, XML,
JSON, CSV, TSV, LOG, YAML, and YML appear alongside media. Markdown supports
headings, lists, bold, italic, and web/email links; other formats show source
text. UTF-8 and BOM-marked UTF-16/32 are supported up to 1 MiB per file.

## Keyboard shortcuts

Shortcuts work while reviewing media. Text fields, dialogs, and native macOS
controls keep their normal shortcuts.

In **Settings → Keyboard shortcuts**, choose **Follow keyboard layout** or
**Physical key positions**. Physical positions keep the same finger movements
when switching layouts, including Dvorak; position names refer to QWERTY keys.
New setups start with physical positions; saved choices are retained.
Choose a key on the keyboard map to see its actions, or search the grouped editor.
Choosing a key only filters the editor. Use **Add shortcut** to record another
key, click an existing binding to replace it, or use its remove button.
Letters, numbers, punctuation, arrows, Tab and Space can be assigned. Each
matching mode keeps its own bindings.

Click Command or Shift on the keyboard to preview modified shortcuts; holding
the keys previews them temporarily. Command shortcuts follow the current Mac
keyboard layout independently of physical review positions. Export, Command
Palette and Rescan accept several Command or Shift-Command letter shortcuts.
Their aliases appear with the corresponding actions in the same editor.
Standard Mac and modified navigation shortcuts remain read-only.

**When** limits a key to a view or media type. A key can serve different actions
only when their contexts do not overlap: Left Arrow navigates outside Gallery
video and seeks within a playable Gallery video. Conflicts name the existing
action and overlapping context. Reset an action with its reset button, or use
**Restore shortcut defaults** to reset the current review mode and Command
shortcuts together. Menus, the Command Palette, Help and tooltips reflect the
saved keys and contexts. Escape retains its native selection/cancel behavior.

The table below lists the defaults.

| Shortcut | Action |
|---|---|
| **F** | Mark Yes; advance if enabled in Review settings |
| **D** | Mark No; advance if enabled in Review settings |
| **0–5** | Clear or assign a 1–5 star rating |
| **← / →** | Previous / next item; in Gallery video, seek 0.5 seconds |
| **↑ / ↓** | Previous / next item in Gallery; previous / next row in Grid |
| **J / L** | Previous / next item |
| **Space / K** | Play or pause video/audio; Space advances on photos |
| **Shift + ← / →** | Seek 5 seconds in Gallery video |
| **S** | Toggle true 100% zoom in Gallery |
| **A** | Toggle phone-sized preview in Gallery |
| **X** | Show or hide the clipping overlay in Gallery |
| **Tab / G** | Switch between Gallery and Grid |
| **Q** | Show or hide the Gallery thumbnail browser |
| **W** | Show or hide the Info panel |
| **⌘+ / ⌘−** | Make Grid thumbnails larger / smaller |
| **E / ⌘E** | Open Export |
| **R** | Clear all Yes/No decisions |
| **Z / ⌘Z** | Undo the latest review or file action |
| **⌘O** | Open another folder |
| **⌘R** | Rescan the current folder |
| **⌘F** | Open Filter and focus Search |
| **⌘K** | Open the Command Palette |
| **⌘A** | Select all visible items |
| **⌘← / ⌘→** | Slower / faster playback; previous / next item for photos |
| **⌘⇧← / ⌘⇧→** | Select from the current item to the first / last |
| **Esc** | Cancel a scan or clear the current selection |
| **⌘⌫** | Trash selected items without a dialog |

## Local review build

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_review.sh`
to create `dist/louppe - to review.app` and its ZIP. Its identity, preferences,
and window state are separate from `Louppe.app`; automatic updates are off.
`VERSION` still supplies its version. Ratings use the compatible
`.louppe_session.json`, so experiment with copies of media. See
[the review record](Docs/REVIEW_BUILD.md).

## Development and release

[Open backlog](BACKLOG.md) · [Build/test rules](AGENTS.md) · [Version history](CHANGELOG.md)

### Contributing

Fork this repository, work on a branch in your fork, and open a pull request
against `main`. This app repository is self-contained: source, tests, fixtures,
build tools, and engineering instructions are included. The parent workspace,
website, marketing assets, and private signing credentials are not needed for
normal development. Read [AGENTS.md](AGENTS.md) before changing code.

Use full Xcode with the current macOS SDK. From the root of your clone:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --disable-keychain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-keychain --build-system native
```

Sparkle is a public, checksum-pinned dependency; the XMP parser sources are vendored.
The guides below cover affected checks and local app packaging. Optional hardware,
RAW-corpus, and release acceptance checks document their separate requirements.

| Guide | Use |
| --- | --- |
| [Development details](Docs/DEVELOPMENT_DETAILS.md) | Ownership, file safety, persistence, media, and native UI |
| [Performance](Docs/PERFORMANCE.md) | Resource policies and subsystem limits |
| [Speed tests](Docs/SPEED_TESTS.md) | Repeatable measurements and comparisons |
| [Review builds](Docs/REVIEW_BUILD.md) | Isolated local builds and launch checks |
| [Automatic updates](Docs/UPDATES.md) | Direct-download feed and signing |
| [App Store](Docs/APP_STORE.md) | Sandboxed packaging and submission |
| [Homebrew](Docs/HOMEBREW.md) | Cask maintenance |
| [XMPCore integration](Docs/XMP_TOOLKIT_INTEGRATION.md) | Parser pins, boundaries, and tests |

[1.12 release preparation](Docs/RELEASE_1.12_PREPARATION_2026-10-21.md) records
the independent review, current verification, acceptance limits, and release handoff.
The [1.11 record](Docs/RELEASE_1.11_PREPARATION_2026-10-15.md) retains its Store submission history.

### Utilities

`build_app.sh` builds/packages the app. `Scripts/` contains release verification,
review packaging, signing/notarization, Store packaging, update-feed preparation,
Homebrew maintenance, and credential/localization checks. Shared resource/service
helpers are used by packaging.

`Tests/run_performance_checks.sh`, `run_scrollbar_checks.sh`, `run_video_checks.sh`,
and `run_resource_bundle_checks.sh` cover native/filesystem contracts.
`Tests/run_file_volume_remount_check.py` uses disposable volume images.
Speed runners and comparisons are described in the speed-test guide above.

### Historical records

[Docs/Archive](Docs/Archive/) holds dated implementation/release records, audit
reports, and benchmark evidence together by date. Completed outcomes remain in
those records and version history; the backlog contains open work and later ideas.
Scratch paths, logs, and source digests describe the original runs.

Free and open source under the [MIT License](LICENSE).
Created by [Alex Markin](https://alex-markin.com). Contact: a@alex-markin.com

### Interface languages

Louppe follows macOS language preferences and per-app language settings, with
English fallback. Spanish, Simplified Chinese, Hindi, Portuguese, and Arabic
are bundled; Arabic uses right-to-left layout. Restart Louppe after changing
its language. Keyboard shortcuts, filenames, and portable XMP values stay the same.
