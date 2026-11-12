#!/bin/zsh
# Disposable regression for the exact SwiftPM metadata rejected by Transporter.
set -euo pipefail
cd "$(dirname "$0")/.."
HELPER="$PWD/Scripts/resource_bundle_metadata.sh"
CHECK_ROOT="$(mktemp -d /private/tmp/Louppe-resource-bundle-tests.XXXXXX)"
trap 'rm -rf "$CHECK_ROOT"' EXIT
RESOURCE_BUNDLE="$CHECK_ROOT/Louppe_Louppe.bundle"
mkdir -p "$RESOURCE_BUNDLE/en.lproj"
RESOURCE_PLIST="$RESOURCE_BUNDLE/Info.plist"
cat > "$RESOURCE_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
</dict></plist>
PLIST
print -r -- '"Choose Media Folder…" = "Choose Media Folder…";' \
    > "$RESOURCE_BUNDLE/en.lproj/Localizable.strings"
cp "$RESOURCE_BUNDLE/en.lproj/Localizable.strings" "$CHECK_ROOT/original.strings"
expect_rejection() {
    local label="$1" expected="$2"
    if "$HELPER" --verify "$RESOURCE_BUNDLE" > "$CHECK_ROOT/rejection.log" 2>&1; then
        echo "Unexpectedly accepted $label." >&2
        exit 1
    fi
    grep -Fq "$expected" "$CHECK_ROOT/rejection.log" || {
        cat "$CHECK_ROOT/rejection.log" >&2
        exit 1
    }
    echo "Passed: $label refused"
}
expect_rejection 'SwiftPM bundle without identifier' 'missing a string CFBundleIdentifier'
for locale in en es pt hi ar zh-Hans; do
    directory="${locale:l}.lproj"
    mkdir -p "$RESOURCE_BUNDLE/$directory"
    cp "Sources/Louppe/Resources/$locale.lproj/Localizable.stringsdict" \
        "$RESOURCE_BUNDLE/$directory/Localizable.stringsdict"
done
"$HELPER" --prepare "$RESOURCE_BUNDLE"
"$HELPER" --verify "$RESOURCE_BUNDLE"
[[ "$(plutil -extract CFBundleDevelopmentRegion raw "$RESOURCE_PLIST")" == "en" ]]
[[ "$(plutil -extract CFBundleLocalizations.0 raw "$RESOURCE_PLIST")" == "en" ]]
[[ "$(plutil -extract CFBundleLocalizations.1 raw "$RESOURCE_PLIST")" == "es" ]]
cmp -s "$CHECK_ROOT/original.strings" "$RESOURCE_BUNDLE/en.lproj/Localizable.strings"
cp "$RESOURCE_PLIST" "$CHECK_ROOT/prepared.plist"
"$HELPER" --prepare "$RESOURCE_BUNDLE"
cmp -s "$CHECK_ROOT/prepared.plist" "$RESOURCE_PLIST"
echo 'Passed: identifier prepared; region, locales and catalog preserved; repeat is stable'
plutil -replace CFBundleIdentifier -string 'com.example.wrong' "$RESOURCE_PLIST"
expect_rejection 'wrong resource identifier' 'identifier must be'
plutil -replace CFBundleIdentifier -string '' "$RESOURCE_PLIST"
expect_rejection 'empty resource identifier' 'identifier must be'
plutil -replace CFBundleIdentifier -integer 12 "$RESOURCE_PLIST"
expect_rejection 'non-string resource identifier' 'missing a string CFBundleIdentifier'
print -r -- 'not a plist' > "$RESOURCE_PLIST"
expect_rejection 'malformed resource metadata' 'Info.plist is malformed'
# The release verifier calls this same --verify path for both packaged apps.
cp "$CHECK_ROOT/prepared.plist" "$RESOURCE_PLIST"
"$HELPER" --verify "$RESOURCE_BUNDLE"
rm "$RESOURCE_BUNDLE/es.lproj/Localizable.stringsdict"
expect_rejection 'missing Spanish plural catalog' 'es plural catalog is missing'
cp Sources/Louppe/Resources/es.lproj/Localizable.stringsdict "$RESOURCE_BUNDLE/es.lproj/Localizable.stringsdict"
print -r -- 'not a plist' > "$RESOURCE_BUNDLE/ar.lproj/Localizable.stringsdict"
expect_rejection 'malformed Arabic plural catalog' 'ar plural catalog is malformed'
cp Sources/Louppe/Resources/ar.lproj/Localizable.stringsdict "$RESOURCE_BUNDLE/ar.lproj/Localizable.stringsdict"
cat > "$RESOURCE_BUNDLE/pt.lproj/Localizable.stringsdict" <<'PLURAL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict/></plist>
PLURAL
expect_rejection 'valid Portuguese plist without plural keys' 'pt plural catalog differs from source'
cp Sources/Louppe/Resources/pt.lproj/Localizable.stringsdict "$RESOURCE_BUNDLE/pt.lproj/Localizable.stringsdict"
"$HELPER" --verify "$RESOURCE_BUNDLE"
echo 'Passed: all six plural catalogs match source, including their keys and rules'
echo 'All resource-bundle checks passed.'
