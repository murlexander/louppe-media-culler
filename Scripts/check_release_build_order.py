#!/usr/bin/env python3
"""Check build order against release tags, independently of a regenerated feed."""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def check(feed, version, build):
    if re.fullmatch(r"[1-9][0-9]*", build) is None:
        raise ValueError("VERSION has an invalid build number.")
    current = (version, int(build))
    sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    published = []
    for item in ET.parse(feed).getroot().findall("./channel/item"):
        enclosure = item.find("enclosure")
        number = (enclosure.get(sparkle + "version") if enclosure is not None else None) or item.findtext(sparkle + "version")
        name = (enclosure.get(sparkle + "shortVersionString") if enclosure is not None else None) or item.findtext(sparkle + "shortVersionString")
        if number is None or re.fullmatch(r"[1-9][0-9]*", number) is None:
            raise ValueError("Publishing feed has a missing or invalid build number.")
        published.append((name, int(number)))

    tagged = []
    tags = subprocess.check_output(["git", "tag", "--list", "v*"], text=True).splitlines()
    for tag in tags:
        if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) is None:
            continue
        result = subprocess.run(["git", "show", f"{tag}:VERSION"], text=True, capture_output=True)
        # Early releases predate VERSION; the feed still supplies their history.
        if result.returncode:
            continue
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        number = values.get("BUILD_NUMBER", "")
        name = values.get("MARKETING_VERSION", "")
        if re.fullmatch(r"[1-9][0-9]*", number) is None or f"v{name}" != tag:
            raise ValueError(f"Release tag {tag} has inconsistent VERSION metadata.")
        tagged.append((name, int(number)))

    # Only an immutable tag can authorize re-verification of an existing pair.
    # The candidate feed cannot prove that it was previously published.
    if current in tagged:
        return
    history = tagged + [pair for pair in published if pair != current]
    if not history:
        raise ValueError("No independent release history. Fetch release tags before preparing the feed.")
    highest = max(number for _, number in history)
    if current[1] <= highest:
        raise ValueError(f"Build {current[1]} must exceed the published maximum {highest}.")


if __name__ == "__main__":
    try:
        check(*sys.argv[1:])
    except (ValueError, ET.ParseError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
