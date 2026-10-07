# Automatic updates

This guide covers direct downloads. The [Store build](APP_STORE.md) has no Sparkle.

Sparkle 2.10.0 checks daily, downloads in the background, and installs on quit.
**Louppe → Check for Updates…** checks manually; **Settings…** controls
automatic checks and downloads.

## Security

- HTTPS serves `appcast.xml` from `main`.
- Sparkle Ed25519 signs the feed and archive; verification precedes extraction.
- Public apps use Developer ID, hardened runtime, and a stapled notarization
  ticket for offline Gatekeeper checks.
- Only the public key is embedded. The private key stays in the release
  owner’s Keychain account `com.alexandermarkin.louppe`.

Public key:

```text
ZT/Kv98/mVd/uo2iUyBb0Gj0ShZqZ+FdfthHBjyH86k=
```

Keep an encrypted private-key backup outside the repository. After a build,
locate and export it (use the path returned by `find`):

```sh
find .build/artifacts -path '*/Sparkle/bin/generate_keys' -print

.build/artifacts/louppe/Sparkle/bin/generate_keys \
  --account com.alexandermarkin.louppe \
  -x /secure/offline/location/louppe-sparkle-private-key
```

Losing the key prevents existing builds from accepting normal signed updates.
Never commit or upload it. Sparkle’s public binary uses its official SHA-256;
builds disable optional Keychain credential lookup and need no GitHub login.

## Release

1. Finalize `VERSION` and the current `CHANGELOG.md` entry. Bump once per release.
2. With a Developer ID Application certificate and `notarytool` profile, build:

   ```sh
   ./build_app.sh --developer-id \
     'Developer ID Application: Your Name (TEAMID)'
   ```

3. Submit, staple, and recreate the ZIP from that exact app:

   ```sh
   ./Scripts/notarize_release.sh --keychain-profile louppe-notary
   ```

   Keep `dist/notarization.json` and `dist/notarization-log.json` as release
   evidence. They record request IDs and results, without credentials.
4. Sign the archive and feed, then verify:

   ```sh
   ./Scripts/prepare_update_feed.sh
   ./Scripts/verify_release.sh --publishing
   ```

5. Publish `v<MARKETING_VERSION>` with the exact `dist/Louppe.zip`. Never
   recompress or replace it after feed generation.
6. Commit and push `appcast.xml`; check its enclosure downloads the release ZIP.
7. Complete a real update from the previous public version before announcing.

The ZIP name stays `Louppe.zip`; the versioned tag makes its URL unique.
The feed includes only the current changelog and no deltas. Publishing checks
version/build, ZIP length/signature, feed signature, URL, minimum macOS,
framework, Developer ID, hardened runtime, notarization, Gatekeeper, and app
signature. Stable releases also update [Homebrew](HOMEBREW.md).

## GitHub release notes

Follow [the 1.9.0 note](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.9.0):
title `Louppe vX.Y.Z`, one benefit sentence, a few **What’s new** bullets,
**Download** instructions with minimum macOS, and a changelog link.
Keep beta limits and safety caveats that affect users; put technical detail in
the changelog. Check signing claims for each version: before 1.8.0, first
launch needed right-click; 1.8.0 onward is signed and notarized.

## Local checks

`build_app.sh` embeds Sparkle with its versioned symlinks, signs the full app,
and creates the release ZIP.

```sh
codesign --verify --deep --strict dist/Louppe.app
otool -L dist/Louppe.app/Contents/MacOS/Louppe
plutil -p dist/Louppe.app/Contents/Info.plist
./Scripts/verify_release.sh

SPARKLE_TOOLS="$(find .build/artifacts -type d -path '*/Sparkle/bin' -print -quit)"
"$SPARKLE_TOOLS/sign_update" \
  --account com.alexandermarkin.louppe \
  --verify appcast.xml
```

Unpublished local builds are absent from the committed signed feed and are
never offered by automatic checks.
