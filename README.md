# Louppe Media Culler

[Louppe](https://louppe.eu) is a fast, keyboard-first, open-source media culler
for macOS. Review photos, video, audio, and text; organize files; clean up
unwanted media; and export keepers.

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
2. Review media in Gallery or Grid.
3. Press **F** for Yes or **D** for No.
4. Filter, sort, select, clean up, organize, or export.

In Finder, select a media folder and choose **Services → Open in Louppe**.
Install Louppe in Applications first to register the service. It opens the
folder in the existing window.

![Louppe Grid comparing street scenes, architecture, reflections and still life, with a photo selected in purple](Docs/Media/2026-09-26/grid-overview.png)

*Grid for comparing and selecting frames.*

The bottom panel shows filters, review progress, and save status. Zoom
30–400% with the slider or a pinch; pan with two-finger scrolling or dragging.
**S** returns custom zoom to centered 100%, then toggles Fit; **A** toggles
Phone size. **Help → Louppe Help** has searchable shortcuts. Dismissed review
tips can be restored from Help.

Yes/No, stars, and color labels are independent. **No never trashes files.**
Ratings save automatically; reopen the folder to continue. The bottom panel
confirms when every item has a decision.

Export starts with **All selected** when you select items, otherwise with
filtered **Keepers (Yes)**. **4–5 stars** includes either decision. Check the
matching count before choosing a destination. Export copies by default;
Move transfers originals, and Metadata (XMP) writes ratings to sidecars for
other apps. **Clean Up** sends files to macOS Trash. **Organize Source Folder**
builds folders from decisions, dates, ratings, and other metadata.

## Review and file handling

- Filter and sort by decisions, stars, colors, dates, folders, camera details,
  file types, and media properties.
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
  **Rename Files…** supports single names and metadata-based batches;
  extensions stay unchanged and recognized RAW+JPEG/XMP families follow.
- Export Copy and Move support All Media, Filtered, and Selected scopes.
  **Route copies to multiple folders** previews decision, stars, color,
  file-type, or media-type rules before copying.

**Settings → Review** sets defaults for advancement,
Gallery/Grid, sort, and dividers in new folders. Rescan keeps the current
layout. Connected drives and cards appear on the start screen with capacity
and a folder chooser.

Ratings save to `.louppe_session.json` in the opened folder. An identity-bound
local backup can protect the session when that folder or card is unavailable.

## Media and inspection

Louppe supports common camera RAW, JPEG, TIFF, PNG, HEIC, WebP, AVIF, video,
audio, and text formats. Unsupported files remain available to rate and export.
Gallery has Fit, Phone size, true 100% zoom, playback, metadata, histogram,
clipping information, and optional quality cues. VoiceOver and keyboard review
are supported.

For RAW photos, **Fast** uses previews below 100% and Apple RAW rendering at
100% and above. **RAW** beside zoom or in **Settings → Review** uses RAW at
all zoom levels. **Preview**, **RAW**, and **RAW…** identify the source and
loading state; **Use Preview** is an explicit fallback after failure.
Apple rendering may differ from your editor or the camera JPEG.

The RAW menu and Review settings offer **Apple Default** or opt-in **RAW 9**.
RAW 9 requires macOS 27, a supported file, and Apple’s model resources; it
uses more time and memory. Failure offers Retry or **Use Apple Default**;
Louppe never silently switches decoders. Grid and Browser retain fast previews.

The histogram switches from **Preview** to **RAW** after a scaled linear RAW
analysis, independent of photo rendering. The **X** overlay measures the
displayed rendering.

Text previews are read-only and selectable. TXT, TEXT, MD/MARKDOWN, XML,
JSON, CSV, TSV, LOG, YAML, and YML appear alongside media. Markdown supports
headings, lists, bold, italic, and web/email links; other formats show source
text. UTF-8 and BOM-marked UTF-16/32 are supported up to 1 MiB per file.

## Keyboard shortcuts

Shortcuts work while reviewing media. Text fields, dialogs, and native macOS
controls keep their normal shortcuts.

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
| **⌘⌫** | Send the selection to the macOS Trash without a dialog |

## Local review build

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_review.sh`
to create `dist/louppe - to review.app` and its ZIP. Its identity, preferences,
and window state are separate from `Louppe.app`; automatic updates are off.
`VERSION` still supplies its version. Ratings use the compatible
`.louppe_session.json`, so experiment with copies of media. See
[the review record](Docs/REVIEW_BUILD.md).

See [BACKLOG.md](BACKLOG.md) for planned work; [AGENTS.md](AGENTS.md),
[PERFORMANCE.md](Docs/PERFORMANCE.md), [UPDATES.md](Docs/UPDATES.md), and
[APP_STORE.md](Docs/APP_STORE.md) for development and release guidance.

Free and open source under the [MIT License](LICENSE).
Created by [Alex Markin](https://alex-markin.com). Contact: a@alex-markin.com

### Interface languages

Louppe follows macOS language preferences and per-app language settings, with
English fallback. Spanish, Simplified Chinese, Hindi, Portuguese, and Arabic
are bundled; Arabic uses right-to-left layout. Restart Louppe after changing
its language. Keyboard shortcuts, filenames, and portable XMP values stay the same.
