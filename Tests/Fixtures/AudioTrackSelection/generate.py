#!/usr/bin/env python3
"""Generate two distinguishable, lossless alternate audio tracks (ffmpeg only)."""
from pathlib import Path
import shutil
import subprocess


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is needed only to regenerate the fixture")
    output = Path(__file__).resolve().parent / "alternate-levels.mov"
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "aevalsrc=0.125:s=8000:d=1",
        "-f", "lavfi", "-i", "aevalsrc=0.75|-0.5:s=8000:d=1",
        "-map", "0:a", "-map", "1:a", "-c:a", "pcm_s16le",
        "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fra",
        "-disposition:a:0", "default", "-disposition:a:1", "0",
        "-fflags", "+bitexact", str(output),
    ], check=True)
    print(f"Generated {output.name}: {output.stat().st_size} bytes")


if __name__ == "__main__":
    main()
