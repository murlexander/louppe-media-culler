#!/bin/zsh
# Usage: Scripts/test.sh (--gates | --full | --filter <regex>) [--skip <regex>] [--foreground]
# Default runs skip focus-taking tests. --gates runs the four required install suites.
set -euo pipefail
usage() { echo 'Usage: Scripts/test.sh (--gates | --full | --filter <regex>) [--skip <regex>] [--foreground]' >&2; exit 2; }
mode=''; filter=''; skip=''; foreground=0
while (( $# )); do
    case "$1" in
        --gates|--full|--filter)
            [[ -z "$mode" ]] || usage
            mode="${1#--}"
            if [[ "$1" == --filter ]]; then
                (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || usage
                filter="$2"; shift
            fi ;;
        --skip)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* && -z "$skip" ]] || usage
            skip="$2"; shift ;;
        --foreground) foreground=1 ;;
        *) usage ;;
    esac
    shift
done
[[ -n "$mode" ]] || usage
# Test the checkout this script belongs to, wherever it is called from.
cd "$(dirname "$0")/.."
source "$PWD/Scripts/lib/xcode_env.sh"
cd "$LOUPPE_REPO_ROOT"
if [[ "$mode" == gates ]]; then
    filter='HotkeyTests|BrowserScrollTests|GridScrollTests|PersistentVerticalScrollerTests'
fi
if (( foreground )); then
    export LOUPPE_FOREGROUND_UI=1
    echo 'Warning: window-raising suites will run; use --foreground only while Alex has handed over the desktop.'
fi

# mkdir is atomic. Serialize stale-lock recovery too, so contenders cannot remove a new owner.
lock="$LOUPPE_SCRATCH_PATH.lock"
mkdir -p "$(dirname "$lock")"
recovering=0; owns_lock=0
cleanup() {
    if (( owns_lock )); then rm -f "$lock/pid"; rmdir "$lock"; fi
    if (( recovering )); then rmdir "$lock.reclaim"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! mkdir "$lock" 2>/dev/null; then
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$owner" == <-> ]] && kill -0 "$owner" 2>/dev/null; then
        echo "test.sh: scratch path is locked by pid $owner: $lock" >&2; exit 3
    fi
    # A missing pid may be an owner between mkdir and writing its pid: never steal it.
    if [[ -z "$owner" ]] || ! mkdir "$lock.reclaim" 2>/dev/null; then
        echo "test.sh: scratch lock is initializing or being recovered: $lock (pid ${owner:-pending})" >&2; exit 3
    fi
    recovering=1
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -z "$owner" ]] || { [[ "$owner" == <-> ]] && kill -0 "$owner" 2>/dev/null; }; then
        echo "test.sh: scratch path is locked by pid ${owner:-pending}: $lock" >&2; exit 3
    fi
    rm -f "$lock/pid"
    rmdir "$lock"
    mkdir "$lock" 2>/dev/null || { echo "test.sh: another process acquired $lock" >&2; exit 3; }
    echo "test.sh: recovered stale scratch lock (pid $owner)"
fi
owns_lock=1
print -r -- "$$" > "$lock/pid"
if (( recovering )); then rmdir "$lock.reclaim"; recovering=0; fi

mkdir -p /private/tmp/louppe-test-logs
zmodload zsh/datetime
log="/private/tmp/louppe-test-logs/$(date -u +%Y%m%dT%H%M%S).${EPOCHREALTIME#*.}Z-$mode.log"
args=(test --disable-keychain --scratch-path "$LOUPPE_SCRATCH_PATH")
[[ -z "$filter" ]] || args+=(--filter "$filter")
[[ -z "$skip" ]] || args+=(--skip "$skip")
echo "test.sh: running $mode; log: $log"
result=0
swift "${args[@]}" > "$log" 2>&1 || result=$?

# XCTest status lines contain each skipped/failed case once; avoid duplicating skip diagnostics.
awk '
    /Executed [0-9]+ tests?, with / { sub(/^[ \t]+/, ""); summary = $0 }
    /^Test Case / && / (failed|skipped) \(/ {
        name = $0
        sub(/^Test Case \047/, "", name); sub(/\047.*$/, "", name)
        gsub(/^-\[|\]$/, "", name)
        sub(/^LouppeTests\./, "", name)
        if ($0 ~ / failed \(/) { failed[++failures] = name; next }
        split(name, parts, /[ .]/); class = parts[1]
        if (!(class in counts)) classes[++classCount] = class
        counts[class]++; skipped++
        cases[class] = cases[class] "\n    " name
    }
    END {
        if (summary != "") print summary; else print "No XCTest summary produced; see the log for build/runtime errors."
        print "Failed test cases: " failures+0
        for (i=1; i<=failures; i++) print "  " failed[i]
        print "Skipped test cases: " skipped+0
        for (i=1; i<=classCount; i++) {
            class = classes[i]; print "  " class " (" counts[class] "):" cases[class]
        }
    }
' "$log"
if (( ! foreground )) && [[ "${LOUPPE_FOREGROUND_UI:-}" != 1 ]]; then
    gated_classes="$(find Tests/LouppeTests -name '*.swift' ! -name ForegroundUI.swift ! -name SourceConventionsTests.swift \
        -exec grep -l 'requireForegroundUI(' {} + | while IFS= read -r file; do
            awk '/class .*: XCTestCase/ { class=$0; sub(/^.*class /, "", class); sub(/[: ].*$/, "", class) }
                 /requireForegroundUI\(/ { print class }' "$file"
        done | sort -u | paste -sd ',' - || true)"
    echo "Foreground UI suites skipped (not run, not passed): $gated_classes"
fi
echo "Log: $log"
last_summary="$(grep -E 'Executed [0-9]+ tests?, with ' "$log" | tail -1 || true)"
if (( result == 0 )) && { [[ "$last_summary" == *"Executed 0 tests"* ]] || grep -q 'No matching test cases were run' "$log"; }; then
    echo 'test.sh: no tests matched; check the filter or suite names.'
    result=4
fi
if (( result == 0 )); then echo 'test.sh: PASS'; else echo "test.sh: FAIL (exit $result)"; fi
exit "$result"
