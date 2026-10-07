#!/bin/zsh
# Builds a verified Mac App Store installer without uploading or changing the
# checked app/ZIP. Signing and package expansion use the local temporary volume.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 4 || "$1" != "--application-identity" || "$3" != "--installer-identity" ]]; then
    echo "Usage: $0 --application-identity 'Apple Distribution: …' --installer-identity '3rd Party Mac Developer Installer: …'" >&2
    exit 2
fi

APPLICATION_IDENTITY="$2"
INSTALLER_IDENTITY="$4"
EXPECTED_TEAM="P6F95J4ZPA"
APP="$PWD/dist/Louppe.app"
PACKAGE="$PWD/dist/Louppe.pkg"
STAGING_ROOT=""
PUBLISHING_PACKAGE=""

fail() {
    echo "App Store packaging failed: $1" >&2
    exit 1
}

case "$APPLICATION_IDENTITY" in
    'Apple Distribution: '*|'3rd Party Mac Developer Application: '*) ;;
    *) fail "Use an Apple Distribution or Mac App Distribution application identity." ;;
esac
[[ "$INSTALLER_IDENTITY" == '3rd Party Mac Developer Installer: '* ]] \
    || fail "Use a Mac Installer Distribution identity, not Developer ID Installer."
[[ "$APPLICATION_IDENTITY" == *"($EXPECTED_TEAM)" \
   && "$INSTALLER_IDENTITY" == *"($EXPECTED_TEAM)" ]] \
    || fail "Both identities must belong to SAMO DANNI EOOD ($EXPECTED_TEAM)."

identity_hash() {
    local identity="$1"
    local kind="$2"
    local inventory hashes
    local -a arguments=(-v)
    [[ "$kind" == "application" ]] && arguments+=(-p codesigning)
    inventory="$(security find-identity "${arguments[@]}")" \
        || fail "Could not check the installed $kind identity."
    hashes="$(print -r -- "$inventory" | \
        awk -F'"' -v wanted="$identity" '$2 == wanted { split($1, fields, /[[:space:]]+/); for (i in fields) if (fields[i] ~ /^[[:xdigit:]]+$/ && length(fields[i]) == 40) print fields[i] }')"
    [[ "$hashes" =~ '^[[:xdigit:]]{40}$' ]] \
        || fail "The requested $kind identity is missing, invalid, or ambiguous."
    print -r -- "$hashes"
}

APPLICATION_HASH="$(identity_hash "$APPLICATION_IDENTITY" application)"
# Installer identities disappear when security uses the codesigning policy.
INSTALLER_HASH="$(identity_hash "$INSTALLER_IDENTITY" installer)"
[[ -d "$APP" ]] || fail "dist/Louppe.app is missing. Run ./build_app.sh --app-store first."
[[ ! -e "$PACKAGE" || -f "$PACKAGE" && ! -L "$PACKAGE" ]] \
    || fail "dist/Louppe.pkg must be a regular output file."
"$PWD/Scripts/verify_release.sh" --app-store

cleanup() {
    [[ -z "$PUBLISHING_PACKAGE" ]] || rm -f "$PUBLISHING_PACKAGE"
    [[ -z "$STAGING_ROOT" ]] || rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT
STAGING_ROOT="$(mktemp -d /private/tmp/Louppe-app-store.XXXXXX)"
SIGNED_APP="$STAGING_ROOT/Louppe.app"
SIGNED_PACKAGE="$STAGING_ROOT/Louppe.pkg"
PACKAGE_VERIFIER="$STAGING_ROOT/verify-app-store-installer"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
    -module-cache-path "$STAGING_ROOT/ModuleCache" \
    "$PWD/Scripts/verify_app_store_installer.swift" -o "$PACKAGE_VERIFIER"
ditto --noextattr --noqtn "$APP" "$SIGNED_APP"
xattr -cr "$SIGNED_APP"
codesign --verify --deep --strict "$SIGNED_APP"
[[ ! -e "$SIGNED_APP/Contents/embedded.provisionprofile" ]] \
    || fail "The current sandbox-only product needs no provisioning profile. Rebuild without the unexpected profile."
codesign --force --options runtime --timestamp --sign "$APPLICATION_HASH" \
    --entitlements "$PWD/Louppe.entitlements" "$SIGNED_APP"

verify_signed_app() {
    local bundle="$1"
    local details entitlements key
    codesign --verify --deep --strict "$bundle"
    details="$(codesign -dvvv "$bundle" 2>&1)"
    print -r -- "$details" | grep -Fxq "Authority=$APPLICATION_IDENTITY" \
        || fail "The signed app has the wrong application certificate."
    print -r -- "$details" | grep -Fxq "TeamIdentifier=$EXPECTED_TEAM" \
        || fail "The signed app has the wrong Apple Developer team."
    print -r -- "$details" | grep -Eq 'flags=.*\(runtime\)' \
        || fail "The signed app has no hardened runtime."
    entitlements="$STAGING_ROOT/signed-entitlements.plist"
    codesign -d --entitlements - --xml "$bundle" 2>/dev/null > "$entitlements"
    plutil -lint "$entitlements" >/dev/null
    [[ "$(xmllint --xpath 'count(/plist/dict/key)' "$entitlements")" == "3" ]] \
        || fail "The signed app has unexpected entitlements."
    for key in com.apple.security.app-sandbox \
        com.apple.security.files.user-selected.read-write \
        com.apple.security.files.bookmarks.app-scope; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements")" == "true" ]] \
            || fail "The signed app is missing $key."
    done
}

verify_package_signature() {
    LC_ALL=C "$PACKAGE_VERIFIER" "$1" "$INSTALLER_HASH" "$INSTALLER_IDENTITY" \
        || fail "The installer signature or Mac Installer Distribution certificate is invalid."
}

verify_signed_app "$SIGNED_APP"
productbuild --component "$SIGNED_APP" /Applications \
    --sign "$INSTALLER_HASH" "$SIGNED_PACKAGE"
verify_package_signature "$SIGNED_PACKAGE"
EXPANDED="$STAGING_ROOT/Expanded"
pkgutil --expand-full "$SIGNED_PACKAGE" "$EXPANDED"
PAYLOAD_DIRECTORIES=("$EXPANDED"/**/Payload(N/))
COMPONENT_INFOS=("$EXPANDED"/**/PackageInfo(N.))
[[ ${#PAYLOAD_DIRECTORIES[@]} -eq 1 && ${#COMPONENT_INFOS[@]} -eq 1 ]] \
    || fail "The package must contain exactly one component and one payload."
PAYLOAD_APPS=("${PAYLOAD_DIRECTORIES[1]}"/Louppe.app(N/))
[[ ${#PAYLOAD_APPS[@]} -eq 1 ]] || fail "The package must contain exactly one Louppe app payload."
PAYLOAD_APP="${PAYLOAD_APPS[1]}"
PAYLOAD_ENTRIES=("${PAYLOAD_APP:h}"/*(DN))
[[ ${#PAYLOAD_ENTRIES[@]} -eq 1 ]] || fail "The package contains files outside Louppe.app."
COMPONENT_INFO="${PAYLOAD_APP:h:h}/PackageInfo"
[[ "$COMPONENT_INFO" == "${COMPONENT_INFOS[1]}" ]] \
    || fail "The app payload and component metadata do not match."
[[ "$(xmllint --xpath 'string(/pkg-info/@install-location)' "$COMPONENT_INFO")" == "/Applications" ]] \
    || fail "The package has the wrong install location."
[[ "$(xmllint --xpath 'string(/pkg-info/@identifier)' "$COMPONENT_INFO")" == "com.alexandermarkin.louppe" ]] \
    || fail "The package has the wrong component identifier."
verify_signed_app "$PAYLOAD_APP"
DIFFERENCES="$(rsync -rcln --delete --itemize-changes \
    "$SIGNED_APP/Contents/" "$PAYLOAD_APP/Contents/")"
[[ -z "$DIFFERENCES" ]] || fail "The expanded package differs from the verified signed app."

# Keep any previous package until all signatures and payload checks pass.
PUBLISHING_PACKAGE="$(mktemp "$PWD/dist/.Louppe-upload.XXXXXX")"
cp "$SIGNED_PACKAGE" "$PUBLISHING_PACKAGE"
cmp -s "$SIGNED_PACKAGE" "$PUBLISHING_PACKAGE" \
    || fail "The output package changed while copying."
verify_package_signature "$PUBLISHING_PACKAGE"
mv -f "$PUBLISHING_PACKAGE" "$PACKAGE"
PUBLISHING_PACKAGE=""
echo "Prepared Mac App Store upload package → $PACKAGE"
