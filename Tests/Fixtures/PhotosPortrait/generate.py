#!/usr/bin/env python3
"""Regenerate small synthetic portrait/rotated originals; requires ffmpeg."""
from pathlib import Path
import shutil
import subprocess
import tempfile

out = Path(__file__).resolve().parent
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    raise SystemExit("ffmpeg is needed only to regenerate these fixtures")


def run(*args):
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


with tempfile.TemporaryDirectory(prefix="louppe-portrait-") as scratch:
    landscape = str(Path(scratch) / "landscape.mov")
    run("-f", "lavfi", "-i", "testsrc2=size=320x180:rate=10",
        "-vf", "drawbox=x=0:y=0:w=36:h=ih:color=red:t=fill,drawbox=x=iw-36:y=0:w=36:h=ih:color=blue:t=fill",
        "-t", "0.6", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", landscape)
    run("-display_rotation", "90", "-i", landscape, "-c", "copy", str(out / "rotated.mov"))
    run("-f", "lavfi", "-i", "testsrc2=size=180x320:rate=10",
        "-vf", "drawbox=x=0:y=0:w=iw:h=36:color=red:t=fill,drawbox=x=0:y=ih-36:w=iw:h=36:color=blue:t=fill",
        "-t", "0.6", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out / "portrait.mov"))
