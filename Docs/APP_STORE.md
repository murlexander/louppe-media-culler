# Mac App Store submission

Louppe builds two products:

- `./build_app.sh`: direct download with Sparkle and a release ZIP.
- `./build_app.sh --app-store`: sandboxed Store app with a privacy manifest,
  no Sparkle or update feed. Its ZIP is for local checks, not upload.

Store updates come through Apple; the app cannot add code after review.
The app requests read/write access only to selected folders. Recent folders
use security-scoped bookmarks. Export destinations retain access while a
recovery journal needs it; completing or retiring that record releases access.
It requests no broad Pictures, Movies, Music, Full Disk Access, network,
camera, microphone, contacts, or accessibility permissions.

## Build checks

`./Scripts/verify_release.sh --app-store` checks the loose app and archive
independently: sandbox, selected-folder read/write and bookmark entitlements;
valid `PrivacyInfo.xcprivacy`; no Sparkle framework, link, or feed key;
matching version/build, Photography category, and both third-party notices.

The manifest declares no tracking or collection. Its reasons cover selected
media and cache timestamps, capacity display/write checks, elapsed timers, and
app preferences; all stay on the Mac.

## Before packaging

1. Test the exact Store build on a physical Mac: select a media folder, scan,
   reopen Recent, save ratings, Copy, Move, Trash/Undo, Organize, video/audio
   playback, waveform analysis, and recovery after cancelling Copy. Card
   removal or revoked access must show an actionable error and preserve media.
2. Check **Help → Privacy Policy** and About’s privacy link. Create the
   `com.alexandermarkin.louppe` App Store Connect record with `VERSION`,
   support URL `https://louppe.eu/`, and privacy URL
   `https://louppe.eu/privacy/`. Declare “does not collect data” only while
   true for every linked SDK. Set accurate age/category ratings and use media
   you own or have permission to show.
3. Explain **Choose Media Folder…** and supply sample media in review notes.
   Analysis is local. Only explicit Rename, Move, Organize, or Trash commands
   change original names or locations; XMP writes affect sidecars. Mention optional
   video/audio features and the Command Palette.
4. Install SAMO DANNI EOOD’s (P6F95J4ZPA) Apple Distribution or Mac App
   Distribution application identity and Mac Installer Distribution identity.
   Check `security find-identity -v`; its codesigning filter hides installers.
   Rebuild the Store app immediately before packaging. Current sandbox-only
   entitlements need no provisioning profile; unexpected profiles are refused.

## Sign and upload

After checks pass:

```sh
./Scripts/package_app_store.sh \
  --application-identity 'Apple Distribution: Your Name (TEAMID)' \
  --installer-identity '3rd Party Mac Developer Installer: Your Name (TEAMID)'
```

The script checks certificate classes/team before staging signing in
`/private/tmp`. It verifies app/package signatures and the complete expanded
payload, then publishes `dist/Louppe.pkg`. The checked app/ZIP stay intact;
failures preserve any previous package. It never uploads.

Installer verification requires a successful `pkgutil` signature check, the exact
selected certificate, and Apple's MacDistributionInstaller trust policy
(`1.2.840.113635.100.1.105`) with system trust. The human-readable status can
label a valid submission certificate “Development”; it is diagnostic text,
not the certificate-type gate. No Keychain trust overrides are needed.

Upload that package through App Store Connect and complete metadata, export
compliance, and review notes. Never upload the direct-download ZIP. Legacy
`3rd Party Mac Developer Application:` identities are also accepted; Developer
ID identities are refused. [Apple signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
and [packaging](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
describe these certificate requirements.

## Release gate

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-keychain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Tests/run_performance_checks.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh --app-store
./Scripts/package_app_store.sh --application-identity '…' --installer-identity '…'
```

Packaging requires the correct team’s Store certificates. App Store Connect
requires an authorized account and complete listing/review fields.

See [7 October readiness](APP_STORE_READINESS_2026-10-07.md) for fixes,
validation, review notes, and remaining acceptance gates. Developer ID signing
can test sandbox permissions locally; upload requires Apple Distribution and
installer signatures.
