#!/bin/zsh
# Verifies the exact app/archive/feed inputs used for a Louppe release.
# Use --developer-id before notarization and --publishing after notarization
# and prepare_update_feed.sh. --app-store checks the sandboxed Store variant,
# which deliberately contains no Sparkle updater.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISHING=false
APP_STORE=false
DEVELOPER_ID=false
if [[ "${1:-}" == "--publishing" ]]; then
    PUBLISHING=true
elif [[ "${1:-}" == "--app-store" ]]; then
    APP_STORE=true
elif [[ "${1:-}" == "--developer-id" ]]; then
    DEVELOPER_ID=true
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--publishing|--app-store|--developer-id]" >&2
    exit 2
fi

VERSION_FILE="$PWD/VERSION"
CHANGELOG_FILE="$PWD/CHANGELOG.md"
APP="$PWD/dist/Louppe.app"
ARCHIVE="$PWD/dist/Louppe.zip"
APPCAST="$PWD/appcast.xml"
ACCOUNT="com.alexandermarkin.louppe"
EXPECTED_PUBLIC_KEY="ZT/Kv98/mVd/uo2iUyBb0Gj0ShZqZ+FdfthHBjyH86k="
EXPECTED_FEED_URL="https://raw.githubusercontent.com/murlexander/louppe-media-culler/main/appcast.xml"
EXPECTED_DEVELOPER_TEAM_ID="P6F95J4ZPA"

MARKETING_VERSION="$(awk -F= '$1 == "MARKETING_VERSION" { print $2 }' "$VERSION_FILE")"
BUILD_NUMBER="$(awk -F= '$1 == "BUILD_NUMBER" { print $2 }' "$VERSION_FILE")"
EXPECTED_TAG="v$MARKETING_VERSION"
EXPECTED_DOWNLOAD_URL="https://github.com/murlexander/louppe-media-culler/releases/download/$EXPECTED_TAG/Louppe.zip"

fail() {
    echo "Release preflight failed: $1" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

verify_app_bundle() {
    local bundle="$1"
    local label="$2"

    codesign --verify --deep --strict "$bundle"
    [[ "$(plist_value "$bundle" CFBundleIdentifier)" == "com.alexandermarkin.louppe" ]] \
        || fail "$label bundle identifier changed."
    [[ "$(plist_value "$bundle" CFBundleShortVersionString)" == "$MARKETING_VERSION" ]] \
        || fail "$label marketing version does not match VERSION."
    [[ "$(plist_value "$bundle" CFBundleVersion)" == "$BUILD_NUMBER" ]] \
        || fail "$label build number does not match VERSION."
    [[ "$(plist_value "$bundle" CFBundleIconFile)" == "AppIcon" ]] \
        || fail "$label legacy icon name is wrong."
    [[ "$(plist_value "$bundle" CFBundleIconName)" == "AppIcon" ]] \
        || fail "$label native icon name is wrong."
    [[ -f "$bundle/Contents/Resources/AppIcon.icns" ]] \
        || fail "$label has no legacy app-icon fallback."
    [[ -f "$bundle/Contents/Resources/Assets.car" ]] \
        || fail "$label has no native appearance-aware app icon."
    [[ "$(plist_value "$bundle" LSMultipleInstancesProhibited)" == "true" ]] \
        || fail "$label must prohibit a second app instance during file operations."
    cmp -s ThirdPartyLicenses/XMPCore-BSD-3-Clause.txt \
        "$bundle/Contents/Resources/XMPCore License.txt" \
        || fail "$label does not contain the reviewed XMPCore license."
    cmp -s ThirdPartyLicenses/Expat-MIT.txt \
        "$bundle/Contents/Resources/Expat License.txt" \
        || fail "$label does not contain the reviewed Expat license."
    "$PWD/Scripts/resource_bundle_metadata.sh" --verify \
        "$bundle/Contents/Resources/Louppe_Louppe.bundle" \
        || fail "$label resource bundle metadata is invalid."
    local locale
    for locale in en es zh-Hans hi pt ar; do
        local source_strings="Sources/Louppe/Resources/$locale.lproj/Localizable.strings"
        local locale_directory="${locale:l}"
        local bundled_strings="$bundle/Contents/Resources/Louppe_Louppe.bundle/$locale_directory.lproj/Localizable.strings"
        [[ -f "$bundled_strings" ]] || fail "$label $locale localization is missing."
        plutil -lint "$bundled_strings" >/dev/null || fail "$label $locale localization is malformed."
        cmp -s "$source_strings" "$bundled_strings" || fail "$label $locale localization differs from source."
    done
    cmp -s PrivacyInfo.xcprivacy "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" \
        || fail "$label does not contain the reviewed privacy manifest."
    plutil -lint "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null \
        || fail "$label privacy manifest is invalid."

    local declaration category reason
    for declaration in \
        'NSPrivacyAccessedAPICategoryFileTimestamp|3B52.1' \
        'NSPrivacyAccessedAPICategoryFileTimestamp|C617.1' \
        'NSPrivacyAccessedAPICategoryDiskSpace|E174.1' \
        'NSPrivacyAccessedAPICategoryDiskSpace|85F4.1' \
        'NSPrivacyAccessedAPICategorySystemBootTime|35F9.1' \
        'NSPrivacyAccessedAPICategoryUserDefaults|CA92.1'; do
        category="${declaration%%|*}"
        reason="${declaration##*|}"
        [[ "$(xmllint --xpath "count(/plist/dict/array/dict[string=\"$category\"]/array/string[.=\"$reason\"])" \
            "$bundle/Contents/Resources/PrivacyInfo.xcprivacy")" == "1" ]] \
            || fail "$label privacy manifest lacks $category reason $reason."
    done

    if $DEVELOPER_ID || $PUBLISHING; then
        local signing_details
        local team_identifier
        signing_details="$(codesign -dvvv "$bundle" 2>&1)"
        print -r -- "$signing_details" | grep -Fq \
            'Authority=Developer ID Application:' \
            || fail "$label is not signed with a Developer ID Application certificate."
        print -r -- "$signing_details" | grep -Eq \
            '^TeamIdentifier=[A-Z0-9]{10}$' \
            || fail "$label has no valid Apple Developer team identifier."
        print -r -- "$signing_details" | grep -Eq \
            'flags=.*\(runtime\)' \
            || fail "$label does not enable the hardened runtime."

        team_identifier="$(print -r -- "$signing_details" | \
            awk -F= '$1 == "TeamIdentifier" { print $2 }')"
        [[ "$team_identifier" == "$EXPECTED_DEVELOPER_TEAM_ID" ]] \
            || fail "$label is not signed by the SAMO DANNI EOOD Apple Developer team."
        local sparkle_version="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
        local -a nested_code
        nested_code=(
            "$sparkle_version/XPCServices/Installer.xpc"
            "$sparkle_version/XPCServices/Downloader.xpc"
            "$sparkle_version/Autoupdate"
            "$sparkle_version/Updater.app"
            "$bundle/Contents/Frameworks/Sparkle.framework"
        )
        local code nested_details nested_team
        for code in "${nested_code[@]}"; do
            [[ -e "$code" ]] || fail "$label is missing signed Sparkle code at $code."
            nested_details="$(codesign -dvvv "$code" 2>&1)"
            print -r -- "$nested_details" | grep -Fq \
                'Authority=Developer ID Application:' \
                || fail "$label contains Sparkle code without a Developer ID signature."
            nested_team="$(print -r -- "$nested_details" | \
                awk -F= '$1 == "TeamIdentifier" { print $2 }')"
            [[ "$nested_team" == "$team_identifier" ]] \
                || fail "$label contains Sparkle code signed by another Apple Developer team."
            print -r -- "$nested_details" | grep -Eq \
                'flags=.*\(runtime\)' \
                || fail "$label contains Sparkle code without the hardened runtime."
        done
    fi

    if $PUBLISHING; then
        xcrun stapler validate "$bundle" >/dev/null \
            || fail "$label has no valid stapled notarization ticket."
        spctl --assess --type execute --verbose=4 "$bundle" \
            || fail "$label is not accepted by Gatekeeper."
    fi

    if $APP_STORE; then
        [[ "$(plist_value "$bundle" LSApplicationCategoryType)" == "public.app-category.photography" ]] \
            || fail "$label App Store category must be Photography."
        local entitlements
        entitlements="$(mktemp "$CHECK_DIR/Louppe-entitlements.XXXXXX")"
        codesign -d --entitlements :- "$bundle" 2>/dev/null > "$entitlements"
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")" == "true" ]] \
            || fail "$label is not sandboxed."
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$entitlements")" == "true" ]] \
            || fail "$label cannot write only to folders the person selected."
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "$entitlements")" == "true" ]] \
            || fail "$label cannot retain selected-folder access safely."
        if /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
            fail "$label includes a prohibited standalone update feed."
        fi
        [[ ! -e "$bundle/Contents/Frameworks/Sparkle.framework" ]] \
            || fail "$label embeds a prohibited standalone updater."
        if otool -L "$bundle/Contents/MacOS/Louppe" | grep -Fq "@rpath/Sparkle.framework"; then
            fail "$label executable links a prohibited standalone updater."
        fi
    else
        [[ "$(plist_value "$bundle" SUFeedURL)" == "$EXPECTED_FEED_URL" ]] \
            || fail "$label embedded update feed URL is wrong."
        [[ "$(plist_value "$bundle" SUPublicEDKey)" == "$EXPECTED_PUBLIC_KEY" ]] \
            || fail "$label embedded Sparkle public key is wrong."
        [[ "$(plist_value "$bundle" SURequireSignedFeed)" == "true" ]] \
            || fail "$label does not require signed feeds."
        [[ "$(plist_value "$bundle" SUVerifyUpdateBeforeExtraction)" == "true" ]] \
            || fail "$label does not verify updates before extraction."
        [[ -d "$bundle/Contents/Frameworks/Sparkle.framework" ]] \
            || fail "$label does not embed Sparkle.framework."
        otool -L "$bundle/Contents/MacOS/Louppe" | grep -Fq "@rpath/Sparkle.framework" \
            || fail "$label executable is not linked to embedded Sparkle."
    fi
}

[[ "$MARKETING_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
    || fail "VERSION has an invalid marketing version."
[[ "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] \
    || fail "VERSION has an invalid build number."
grep -Fq "## $MARKETING_VERSION ($BUILD_NUMBER) " "$CHANGELOG_FILE" \
    || fail "CHANGELOG.md has no matching top-level release entry."
[[ -d "$APP" ]] || fail "dist/Louppe.app is missing; run ./build_app.sh."
[[ -f "$ARCHIVE" ]] || fail "dist/Louppe.zip is missing; run ./build_app.sh."
if ! $APP_STORE; then
    [[ -f "$APPCAST" ]] || fail "appcast.xml is missing."
fi

CHECK_DIR="$(mktemp -d /private/tmp/Louppe-preflight.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
# File Provider metadata can immediately reappear on dist/. Verify a clean
# local-volume copy instead; the packaged archive is extracted and checked
# independently below without altering the zip.
VERIFIED_APP="$CHECK_DIR/LooseApp.app"
ditto --noextattr --noqtn "$APP" "$VERIFIED_APP"
xattr -cr "$VERIFIED_APP"
verify_app_bundle "$VERIFIED_APP" "the loose app's"

if ! $APP_STORE; then
    SPARKLE_TOOLS="$(find .build/artifacts -type d -path '*/Sparkle/bin' -print -quit)"
    [[ -n "$SPARKLE_TOOLS" && -x "$SPARKLE_TOOLS/sign_update" ]] \
        || fail "Sparkle's verification tool is missing."
    if $PUBLISHING; then
        # Sparkle's verifier intentionally reads the matching private key from the
        # release owner's Keychain. This is the authoritative cryptographic check.
        "$SPARKLE_TOOLS/sign_update" --account "$ACCOUNT" --verify "$APPCAST"
    else
        # Routine local builds must not trigger a Keychain prompt. Structural
        # checks catch a missing/malformed signature block; --publishing detects
        # edits with the real key-backed verification immediately before upload.
        grep -Fq '<!-- sparkle-signatures:' "$APPCAST" \
            || fail "the appcast has no embedded Sparkle signature block."
        grep -Eq '^edSignature: [A-Za-z0-9+/]+={0,2}$' "$APPCAST" \
            || fail "the appcast signature block is malformed."
    fi
fi

EXTRACT_DIR="$CHECK_DIR/Archive"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/Louppe.app"
[[ -d "$EXTRACTED_APP" ]] || fail "the archive does not contain Louppe.app."
verify_app_bundle "$EXTRACTED_APP" "the archived app's"
ARCHIVE_DIFFERENCES="$(rsync -rcln --delete --itemize-changes \
    "$VERIFIED_APP/Contents/" "$EXTRACTED_APP/Contents/")"
if [[ -n "$ARCHIVE_DIFFERENCES" ]]; then
    echo "$ARCHIVE_DIFFERENCES" >&2
    fail "the archive contents differ from the verified loose app."
fi

if ! $APP_STORE; then
ITEM_COUNT="$(xmllint --xpath \
    'count(//*[local-name()="channel"]/*[local-name()="item"])' \
    "$APPCAST" 2>/dev/null)"
if [[ "$ITEM_COUNT" == "0" ]]; then
    $PUBLISHING && fail "the publishing feed has no release enclosure."
    echo "Signed feed is intentionally empty; no unpublished local build will be offered."
elif ! $PUBLISHING; then
    # A normal source build creates a fresh ZIP whose container timestamps are
    # not expected to match an immutable archive from an already-published
    # feed. The loose and archived apps were verified independently above;
    # exact feed/archive matching remains mandatory in --publishing mode.
    echo "Signed feed contains published updates; routine build leaves it unchanged."
else
    FEED_BUILD="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@*[local-name()="version"])[1])' \
        "$APPCAST" 2>/dev/null)"
    if [[ -z "$FEED_BUILD" ]]; then
        FEED_BUILD="$(xmllint --xpath \
            'string((//*[local-name()="item"]/*[local-name()="version"])[1])' \
            "$APPCAST" 2>/dev/null)"
    fi
    FEED_MARKETING="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@*[local-name()="shortVersionString"])[1])' \
        "$APPCAST" 2>/dev/null)"
    if [[ -z "$FEED_MARKETING" ]]; then
        FEED_MARKETING="$(xmllint --xpath \
            'string((//*[local-name()="item"]/*[local-name()="shortVersionString"])[1])' \
            "$APPCAST" 2>/dev/null)"
    fi
    FEED_URL="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@url)[1])' \
        "$APPCAST" 2>/dev/null)"
    FEED_LENGTH="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@length)[1])' \
        "$APPCAST" 2>/dev/null)"
    FEED_SIGNATURE="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@*[local-name()="edSignature"])[1])' \
        "$APPCAST" 2>/dev/null)"
    MINIMUM_SYSTEM="$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="minimumSystemVersion"])[1])' \
        "$APPCAST" 2>/dev/null)"
    ARCHIVE_LENGTH="$(stat -f%z "$ARCHIVE")"

    [[ "$FEED_BUILD" == "$BUILD_NUMBER" ]] \
        || fail "the feed build number does not match VERSION."
    [[ "$FEED_MARKETING" == "$MARKETING_VERSION" ]] \
        || fail "the feed marketing version does not match VERSION."
    [[ "$FEED_URL" == "$EXPECTED_DOWNLOAD_URL" ]] \
        || fail "the feed enclosure URL does not match the release tag."
    [[ "$FEED_LENGTH" == "$ARCHIVE_LENGTH" ]] \
        || fail "dist/Louppe.zip changed after the feed was generated."
    [[ -n "$FEED_SIGNATURE" ]] || fail "the release archive has no EdDSA signature."
    [[ "$MINIMUM_SYSTEM" == "$(plist_value "$EXTRACTED_APP" LSMinimumSystemVersion)" ]] \
        || fail "the feed minimum macOS version does not match the app."
    "$SPARKLE_TOOLS/sign_update" \
        --account "$ACCOUNT" \
        --verify "$ARCHIVE" "$FEED_SIGNATURE"
fi
fi

echo "Release preflight passed for Louppe $MARKETING_VERSION ($BUILD_NUMBER)."
