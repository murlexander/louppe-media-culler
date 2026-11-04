# Media accessibility fixture

`captioned-described.mov` is generated test data: eight seconds of blue H.264
video, two silent AAC tracks, English SDH text, and French subtitle text.
Subtitles use `tx3g`, not ffmpeg's default legacy QuickTime `text` sample entry.
The latter exposed selectable tracks but produced no decoded caption cues on
macOS 27.2. A standalone legible-output check requires the actual `[Silence]` text.
The second audio track has Apple's described-video characteristic; the English
subtitle track has its spoken-dialog and music/sound accessibility tags.
The silent described-audio stub tests metadata and selection, not narration.
There is no recorded speech, third-party media, or personal metadata.

Tests read the committed file; ffmpeg is needed only to regenerate it:

```sh
python3 Tests/Fixtures/AccessibilityMedia/generate.py
```

Verify decoding without creating an inactive AppKit application (which can
defer caption presentation until it owns the foreground):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library Tests/Fixtures/AccessibilityMedia/verify.swift \
  -o /private/tmp/louppe-verify-caption
/private/tmp/louppe-verify-caption Tests/Fixtures/AccessibilityMedia/captioned-described.mov
```

The generator adds documented QuickTime `tagc` atoms because ffmpeg's disposition
flags alone do not produce AVFoundation's Apple accessibility characteristics.
It requires `mdat` before `moov` so appending track metadata cannot alter media
chunk offsets. It is intentionally limited to this generated five-track file.

`MediaAccessibilityTests` verifies real AVFoundation selection on this asset,
automatic criteria, manual selection and restoration, Gallery/Grid player
attachment, the native subtitle menu's authored-language choices, and replacement
by another item. Menu tests invoke only local track actions, preserving global
caption preferences. They do not verify caption pixels,
the global system preferences, or the quality of an audio description.
macOS may add generated transcript choices; checks validate the authored options
and use macOS 27's selectability API without assuming a fixed group size.

References: [Apple media characteristics](https://developer.apple.com/documentation/avfoundation/avmediacharacteristic),
[QuickTime media characteristic tags](https://developer.apple.com/documentation/quicktime-file-format/user_data_atoms),
[AVFoundation media selection](https://developer.apple.com/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks).
