#!/bin/zsh
# Prepare metadata or verify metadata and plural catalogs before app signing.
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

if [[ "$MODE" == "--verify" ]]; then
    SOURCE_RESOURCES="$(cd "$(dirname "$0")/../Sources/Louppe/Resources" && pwd)"
    for locale in en es pt hi ar zh-Hans; do
        catalog="$2/${locale:l}.lproj/Localizable.stringsdict"
        [[ -f "$catalog" && ! -L "$catalog" ]] \
            || fail "$locale plural catalog is missing."
        plutil -lint "$catalog" >/dev/null \
            || fail "$locale plural catalog is malformed."
        # Full equality also requires every source key, plural rule and form.
        cmp -s "$SOURCE_RESOURCES/$locale.lproj/Localizable.stringsdict" "$catalog" \
            || fail "$locale plural catalog differs from source."
    done
fi
