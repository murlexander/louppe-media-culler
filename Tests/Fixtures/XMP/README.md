# Synthetic XMP packets

Non-copyrighted packets shaped for Universal XMP, Lightroom Classic, Adobe Bridge,
Capture One, and darktable, plus malformed XML. Moved byte-for-byte from the
retired standalone bridge prototype.

`XMPPhase5Tests`, `XMPPhase6Tests`, and `XMPPhase7Tests` read these files directly
to exercise the shipping bridge, preservation of foreign edits, conflicts,
and safe export. Keep the directory in source snapshots used for those tests.
These packets do not establish acceptance in the actual external editors.
