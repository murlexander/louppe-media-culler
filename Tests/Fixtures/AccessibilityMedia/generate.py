#!/usr/bin/env python3
"""Regenerate the synthetic AVFoundation media-selection fixture (needs ffmpeg)."""
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def atoms(blob):
    offset = 0
    while offset < len(blob):
        size, kind = struct.unpack_from(">I4s", blob, offset)
        assert 8 <= size <= len(blob) - offset
        yield kind, blob[offset + 8:offset + size]
        offset += size
    assert offset == len(blob)


def atom(kind, payload):
    return struct.pack(">I4s", len(payload) + 8, kind) + payload


def tag_tracks(output):
    top = list(atoms(output.read_bytes()))
    kinds = [kind for kind, _ in top]
    # ffmpeg writes mdat before moov. Adding track metadata in moov therefore
    # leaves all media chunk offsets unchanged. This is not a general MOV editor.
    assert kinds.index(b"mdat") < kinds.index(b"moov")
    rebuilt = []
    track = 0
    for kind, payload in top:
        if kind == b"moov":
            movie = []
            for child_kind, child_payload in atoms(payload):
                if child_kind == b"trak":
                    track += 1
                    tags = {
                        3: [b"public.accessibility.describes-video"],
                        4: [b"public.accessibility.transcribes-spoken-dialog",
                            b"public.accessibility.describes-music-and-sound"],
                    }.get(track, [])
                    if tags:
                        children = list(atoms(child_payload))
                        existing = next((v for k, v in children if k == b"udta"), b"")
                        additions = b"".join(atom(b"tagc", t) for t in tags if t not in existing)
                        child_payload = b"".join(atom(k, v + additions if k == b"udta" else v)
                                                 for k, v in children)
                        if not any(k == b"udta" for k, _ in children):
                            child_payload += atom(b"udta", additions)
                movie.append(atom(child_kind, child_payload))
            payload = b"".join(movie)
        rebuilt.append(atom(kind, payload))
    assert track == 5
    output.write_bytes(b"".join(rebuilt))


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required only to regenerate this fixture")
    output = Path(__file__).resolve().parent / "captioned-described.mov"
    with tempfile.TemporaryDirectory(prefix="louppe-accessibility-fixture-") as directory:
        scratch = Path(directory)
        english = scratch / "english.srt"
        french = scratch / "french.srt"
        english.write_text("1\n00:00:00,000 --> 00:00:08,000\n[Silence]\n")
        french.write_text("1\n00:00:00,000 --> 00:00:08,000\n[Silence]\n")
        subprocess.run([
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=10:d=8",
            "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono",
            "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono",
            "-i", str(english), "-i", str(french),
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map", "4:s",
            "-t", "8", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-c:s", "mov_text", "-tag:s", "tx3g",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=eng",
            "-disposition:a:0", "default", "-disposition:a:1", "visual_impaired",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=fra",
            "-disposition:s:0", "hearing_impaired", "-disposition:s:1", "0", str(output),
        ], check=True)
    tag_tracks(output)
    print(f"Generated {output.name}: {output.stat().st_size} bytes")


if __name__ == "__main__":
    main()
