#!/bin/zsh
# Prepare or verify the SwiftPM resource bundle before app signing.
set -euo pipefail
if [[ $# -ne 2 || ( "$1" != "--prepare" && "$1" != "--verify" ) ]]; then
    echo "Usage: $0 [--prepare|--verify] resource-bundle" >&2
    exit 2
fi
MODE="$1"
RESOURCE_PLIST="$2/Info.plist"
EXPECTED_IDENTIFIER="com.alexandermarkin.louppe.resources"
fail() {
    echo "Resource bundle metadata failed: $1" >&2
    exit 1
}
[[ -f "$RESOURCE_PLIST" && ! -L "$RESOURCE_PLIST" ]] \
    || fail "The resource bundle has no regular Info.plist."
plutil -lint "$RESOURCE_PLIST" >/dev/null \
    || fail "The resource bundle Info.plist is malformed."
if [[ "$MODE" == "--prepare" ]]; then
    # Change only this key; retain SwiftPM's development region and any other
    # localization metadata. The copied catalogs remain byte-for-byte intact.
    plutil -replace CFBundleIdentifier -string "$EXPECTED_IDENTIFIER" "$RESOURCE_PLIST"
fi
IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -expect string "$RESOURCE_PLIST" 2>/dev/null)" \
    || fail "The resource bundle is missing a string CFBundleIdentifier."
[[ "$IDENTIFIER" == "$EXPECTED_IDENTIFIER" ]] \
    || fail "The resource bundle identifier must be $EXPECTED_IDENTIFIER."
