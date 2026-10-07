#!/bin/zsh
# Builds Louppe.app from source.
# Run: ./build_app.sh [--app-store|--developer-id 'Developer ID Application: …']
set -euo pipefail
cd "$(dirname "$0")"

APP_STORE=false
DEVELOPER_IDENTITY=""
EXPECTED_DEVELOPER_TEAM_ID="P6F95J4ZPA"
if [[ $# -eq 1 && "$1" == "--app-store" ]]; then
    APP_STORE=true
elif [[ $# -eq 2 && "$1" == "--developer-id" ]]; then
    DEVELOPER_IDENTITY="$2"
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--app-store|--developer-id 'Developer ID Application: …']" >&2
    exit 2
fi

VERSION_FILE="$PWD/VERSION"
CHANGELOG_FILE="$PWD/CHANGELOG.md"
MARKETING_VERSION="$(awk -F= '$1 == "MARKETING_VERSION" { print $2 }' "$VERSION_FILE")"
BUILD_NUMBER="$(awk -F= '$1 == "BUILD_NUMBER" { print $2 }' "$VERSION_FILE")"

if ! print -r -- "$MARKETING_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Invalid MARKETING_VERSION in VERSION: $MARKETING_VERSION" >&2
    exit 1
fi
if ! print -r -- "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
    echo "Invalid BUILD_NUMBER in VERSION: $BUILD_NUMBER" >&2
    exit 1
fi
if ! grep -Fq "## $MARKETING_VERSION ($BUILD_NUMBER) " "$CHANGELOG_FILE"; then
    echo "CHANGELOG.md has no entry for version $MARKETING_VERSION ($BUILD_NUMBER)" >&2
    exit 1
fi

if [[ -n "$DEVELOPER_IDENTITY" ]]; then
    if [[ "$DEVELOPER_IDENTITY" != "Developer ID Application: "* ]]; then
        echo "Developer ID builds require a Developer ID Application identity." >&2
        exit 1
    fi
    if [[ "$DEVELOPER_IDENTITY" != *"($EXPECTED_DEVELOPER_TEAM_ID)" ]]; then
        echo "Developer ID builds must use the SAMO DANNI EOOD team ($EXPECTED_DEVELOPER_TEAM_ID)." >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning | \
        grep -Fq "\"$DEVELOPER_IDENTITY\""; then
        echo "The requested Developer ID Application identity is not available in Keychain." >&2
        exit 1
    fi
fi

if $APP_STORE; then
    echo "Compiling App Store Louppe $MARKETING_VERSION ($BUILD_NUMBER)…"
elif [[ -n "$DEVELOPER_IDENTITY" ]]; then
    echo "Compiling Developer ID Louppe $MARKETING_VERSION ($BUILD_NUMBER)…"
else
    echo "Compiling direct-download Louppe $MARKETING_VERSION ($BUILD_NUMBER)…"
fi
# Sparkle is a public, checksum-pinned binary. Do not ask macOS Keychain for
# unrelated github.com credentials while downloading it.
BUILD_ARGUMENTS=(--disable-keychain --build-system native -c release)
if $APP_STORE; then
    BUILD_ARGUMENTS+=(-Xswiftc -DAPP_STORE)
    LOUPPE_APP_STORE=1 swift build "${BUILD_ARGUMENTS[@]}"
else
    swift build "${BUILD_ARGUMENTS[@]}"
fi

OUTPUT_APP="dist/Louppe.app"
OUTPUT_ARCHIVE="dist/Louppe.zip"
# This repository can live in a File Provider-managed Documents folder, which
# immediately reattaches com.apple.FinderInfo to app bundles and makes strict
# signature verification fail. Assemble and verify on the local temp volume,
# then copy the verified bundle back without extended attributes.
STAGING_ROOT="$(mktemp -d /private/tmp/Louppe-build.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_DIR="$STAGING_ROOT/Louppe.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Frameworks"

cp .build/release/Louppe "$APP_DIR/Contents/MacOS/Louppe"
ditto --noextattr --noqtn .build/release/Louppe_Louppe.bundle \
    "$APP_DIR/Contents/Resources/Louppe_Louppe.bundle"
# SwiftPM writes localization metadata but no resource-bundle identifier.
# Stamp it before signing so App Store validation accepts the nested bundle.
"$PWD/Scripts/resource_bundle_metadata.sh" --prepare \
    "$APP_DIR/Contents/Resources/Louppe_Louppe.bundle"

# Xcode 27's SwiftPM linker can record the deployment target (14.0) as the
# linked SDK even though compilation used the current SDK. macOS then presents
# the app with the older toolbar appearance. Correct that load-command marker
# before signing; keep the deployment target and linker version unchanged.
CURRENT_SDK="$(xcrun --sdk macosx --show-sdk-version)"
BUILD_VERSION="$(vtool -show-build "$APP_DIR/Contents/MacOS/Louppe")"
LINKED_MINIMUM="$(print -r -- "$BUILD_VERSION" | awk '$1 == "minos" { print $2; exit }')"
LINKED_SDK="$(print -r -- "$BUILD_VERSION" | awk '$1 == "sdk" { print $2; exit }')"
LINKER_VERSION="$(print -r -- "$BUILD_VERSION" | awk '$1 == "version" { print $2; exit }')"
if [[ -z "$LINKED_MINIMUM" || -z "$LINKED_SDK" || -z "$LINKER_VERSION" ]]; then
    echo "Could not inspect Louppe's linked macOS SDK." >&2
    exit 1
fi
if [[ "$LINKED_SDK" != "$CURRENT_SDK" ]]; then
    vtool -set-build-version macos "$LINKED_MINIMUM" "$CURRENT_SDK" \
        -tool ld "$LINKER_VERSION" -replace \
        -output "$STAGING_ROOT/Louppe-current-sdk" \
        "$APP_DIR/Contents/MacOS/Louppe"
    mv "$STAGING_ROOT/Louppe-current-sdk" "$APP_DIR/Contents/MacOS/Louppe"
    chmod +x "$APP_DIR/Contents/MacOS/Louppe"
fi
FINAL_LINKED_SDK="$(vtool -show-build "$APP_DIR/Contents/MacOS/Louppe" | \
    awk '$1 == "sdk" { print $2; exit }')"
if [[ "$FINAL_LINKED_SDK" != "$CURRENT_SDK" ]]; then
    echo "Louppe links as SDK $FINAL_LINKED_SDK, expected $CURRENT_SDK." >&2
    exit 1
fi

# Compile the Icon Composer source so macOS 26 can render the native Default,
# Dark, Clear, and Tinted appearances. Shipping only the legacy .icns makes
# Tahoe place the transparent glyph on its generic gray compatibility tile.
ICON_SOURCE="$STAGING_ROOT/AppIcon.icon"
ICON_OUTPUT="$STAGING_ROOT/icon-output"
ACTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/actool"
[[ -x "$ACTOOL" ]] || {
    echo "Xcode's asset compiler is required to build the app icon." >&2
    exit 1
}
ditto --noextattr --noqtn AppIcon/AppIcon.icon "$ICON_SOURCE"
xattr -cr "$ICON_SOURCE"
mkdir -p "$ICON_OUTPUT"
"$ACTOOL" "$ICON_SOURCE" \
    --compile "$ICON_OUTPUT" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --bundle-identifier com.alexandermarkin.louppe \
    --output-format human-readable-text \
    --notices --warnings --errors \
    --output-partial-info-plist "$ICON_OUTPUT/icon.plist"
cp "$ICON_OUTPUT/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ICON_OUTPUT/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
cp CHANGELOG.md "$APP_DIR/Contents/Resources/Version History.md"
cp ThirdPartyLicenses/XMPCore-BSD-3-Clause.txt \
    "$APP_DIR/Contents/Resources/XMPCore License.txt"
cp ThirdPartyLicenses/Expat-MIT.txt \
    "$APP_DIR/Contents/Resources/Expat License.txt"
cp PrivacyInfo.xcprivacy "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"

if ! $APP_STORE; then
    SPARKLE_FRAMEWORK="$(find .build/artifacts -type d \
        -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
        -print -quit)"
    if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
        echo "Sparkle.framework was not found in SwiftPM's build artifacts." >&2
        exit 1
    fi
    # ditto preserves the framework's versioned symlinks and executable bits.
    ditto --noextattr --noqtn "$SPARKLE_FRAMEWORK" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string><string>es</string><string>zh-Hans</string>
        <string>hi</string><string>pt</string><string>ar</string>
    </array>
    <key>CFBundleName</key>
    <string>Louppe</string>
    <key>CFBundleDisplayName</key>
    <string>Louppe</string>
    <key>CFBundleIdentifier</key>
    <string>com.alexandermarkin.louppe</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$MARKETING_VERSION</string>
    <key>CFBundleExecutable</key>
    <string>Louppe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Alex Markin</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Open in Louppe</string>
                <key>es</key><string>Abrir en Louppe</string>
                <key>zh-Hans</key><string>在 Louppe 中打开</string>
                <key>hi</key><string>Louppe में खोलें</string>
                <key>pt</key><string>Abrir no Louppe</string>
                <key>ar</key><string>فتح في Louppe</string>
            </dict>
            <key>NSMessage</key>
            <string>openMediaFolder</string>
            <key>NSPortName</key>
            <string>Louppe</string>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.folder</string>
            </array>
            <key>NSRequiredContext</key>
            <dict>
                <key>NSApplicationIdentifier</key>
                <string>com.apple.finder</string>
            </dict>
        </dict>
    </array>
PLIST

if ! $APP_STORE; then
    cat >> "$APP_DIR/Contents/Info.plist" <<'PLIST'
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/murlexander/louppe-media-culler/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>ZT/Kv98/mVd/uo2iUyBb0Gj0ShZqZ+FdfthHBjyH86k=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <real>86400</real>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
    <true/>
PLIST
fi

cat >> "$APP_DIR/Contents/Info.plist" <<'PLIST'
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR"
if $APP_STORE; then
    codesign --force --sign - --entitlements "$PWD/Louppe.entitlements" "$APP_DIR"
elif [[ -n "$DEVELOPER_IDENTITY" ]]; then
    # Sparkle's distributed helpers are ad-hoc signed. Re-sign each nested code
    # object from the inside out, preserving the Downloader service entitlement,
    # so hardened-runtime library validation and notarization both succeed.
    SPARKLE_VERSION="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_IDENTITY" \
        "$SPARKLE_VERSION/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements \
        --sign "$DEVELOPER_IDENTITY" \
        "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_IDENTITY" "$SPARKLE_VERSION/Autoupdate"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_IDENTITY" "$SPARKLE_VERSION/Updater.app"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_IDENTITY" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_IDENTITY" "$APP_DIR"
else
    codesign --force --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

rm -rf "$OUTPUT_APP"
mkdir -p "$(dirname "$OUTPUT_APP")"
ditto --noextattr --noqtn "$APP_DIR" "$OUTPUT_APP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGING_ROOT/Louppe.zip"
cp "$STAGING_ROOT/Louppe.zip" "$OUTPUT_ARCHIVE"

if $APP_STORE; then
    "$PWD/Scripts/verify_release.sh" --app-store
elif [[ -n "$DEVELOPER_IDENTITY" ]]; then
    "$PWD/Scripts/verify_release.sh" --developer-id
else
    "$PWD/Scripts/verify_release.sh"
fi

echo ""
echo "Done → $PWD/$OUTPUT_APP"
echo "Archive → $PWD/$OUTPUT_ARCHIVE"
