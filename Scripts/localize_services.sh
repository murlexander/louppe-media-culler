#!/bin/zsh
# Keep Finder's service label identical to the app catalog. This only edits
# the staged plist; it never registers a service or changes keyboard routing.
set -euo pipefail
PLIST_PATH="$1"
CATALOG_ROOT="${2:-$(dirname "$0")/../Sources/Louppe/Resources}"
for language in en es zh-Hans hi pt ar; do
    translation="$(plutil -extract 'Open in Louppe' raw -o - "$CATALOG_ROOT/$language.lproj/Localizable.strings")"
    [[ -n "$translation" ]] || { echo "Missing $language Finder service translation" >&2; exit 1; }
    menu_key="$language"
    [[ "$language" == en ]] && menu_key=default
    plutil -replace "NSServices.0.NSMenuItem.$menu_key" -string "$translation" "$PLIST_PATH"
done
