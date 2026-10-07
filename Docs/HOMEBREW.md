# Homebrew distribution

This repository is the tap. Its cask installs the signed, notarized release ZIP.

## Install

```sh
brew tap murlexander/louppe https://github.com/murlexander/louppe-media-culler
brew install --cask murlexander/louppe/louppe
```

If prompted, trust only `murlexander/louppe/louppe`. Requires Apple silicon and
macOS 14+. Sparkle remains enabled; `auto_updates true` tells Homebrew that
the app updates itself. To upgrade through Homebrew:

```sh
brew upgrade --cask --greedy murlexander/louppe/louppe
```

Uninstall removes the app, preserving media, ratings, folder access, and preferences.

## Releases

Publish a stable `vX.Y.Z` with the final ZIP using [UPDATES.md](UPDATES.md).
The workflow verifies GitHub hash/size and app identity, version, updater,
minimum macOS, and architecture, then commits only cask version/checksum to
`main`. Prereleases are excluded; it never publishes releases or changes the feed.

Check workflow success and its permission to push. If the ZIP arrived after
publication, rerun **Update Homebrew package**. Architecture or minimum-macOS
changes stop automation pending compatibility review.

Manual check/update:

```sh
python3 Scripts/update_homebrew_cask.py
```

This tap is outside Homebrew’s main catalog; the explicit tap URL is required.
