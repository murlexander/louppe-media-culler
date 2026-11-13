#!/bin/zsh
# Exercise the release verifier's real signature checks without signing code.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/release_signatures.sh
CHECK_ROOT="$(mktemp -d /private/tmp/Louppe-signature-tests.XXXXXX)"
trap 'rm -rf "$CHECK_ROOT"' EXIT
bundle="$CHECK_ROOT/Louppe.app"
sparkle="$bundle/Contents/Frameworks/Sparkle.framework"
mkdir -p "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/XPCServices/Downloader.xpc" "$sparkle/Versions/B/Updater.app"
touch "$sparkle/Versions/B/Autoupdate"
fail() { print -r -- "$1" >&2; exit 1; }
codesign() {
    local code="${@: -1}"
    if [[ "$scenario" == command-failure ]]; then return 1; fi
    if [[ "$target" != main && "$code" == "$bundle" ]] || \
       [[ "$target" == main && "$code" != "$bundle" ]]; then
        cat "$CHECK_ROOT/valid" >&2
    else
        cat "$CHECK_ROOT/$scenario" >&2
    fi
}
python3 - "$CHECK_ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
valid = 'Authority=Developer ID Application: Fixture\nTeamIdentifier=P6F95J4ZPA\nCodeDirectory flags=0x10000(runtime)\n'
# Matching lines precede far more than a pipe buffer, reproducing early grep
# exit while the zsh producer is still writing under pipefail.
valid += 'Additional signing detail\n' * 50000
for name, data in {
    'valid': valid,
    'unsigned': valid.replace('Authority=Developer ID Application: Fixture\n', ''),
    'wrong-team': valid.replace('P6F95J4ZPA', 'ABCDEFGHIJ'),
    'invalid-team': valid.replace('P6F95J4ZPA', 'bad'),
    'no-runtime': valid.replace('flags=0x10000(runtime)', 'flags=0x0(none)'),
}.items():
    (root / name).write_text(data)
PY
for target in main nested; do
    scenario=valid
    (verify_developer_id_signatures "$bundle" fixture P6F95J4ZPA)
    print -r -- "Passed: large valid $target signature accepted under pipefail"
    for scenario in unsigned wrong-team invalid-team no-runtime command-failure; do
        if (verify_developer_id_signatures "$bundle" fixture P6F95J4ZPA) > "$CHECK_ROOT/result" 2>&1; then
            fail "Accepted $target $scenario signature"
        fi
        print -r -- "Passed: $target $scenario signature refused"
    done
done
rm "$sparkle/Versions/B/Autoupdate"
scenario=valid
if (verify_developer_id_signatures "$bundle" fixture P6F95J4ZPA) > "$CHECK_ROOT/result" 2>&1; then
    fail 'Accepted missing nested code'
fi
print 'Passed: missing nested code refused'
