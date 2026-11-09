#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$script_dir/.."   # capture the checkout this script belongs to
source "$script_dir/lib/xcode_env.sh"
cd "$LOUPPE_REPO_ROOT"

usage() {
    echo 'Usage: Scripts/capture_ui.sh [--list] [--topic <name>] [--out <dir>] [--appearance light|dark|both] [--pair <A> <B>] [<scenario-or-glob> …]'
}
fail() { echo "capture_ui: $*" >&2; exit 2; }
topic=capture
output=''
appearance=both
pair=''
list=0
typeset -a scenarios
scenarios=()
while (( $# )); do
    case "$1" in
        --list) list=1; shift ;;
        --topic) (( $# >= 2 )) || fail '--topic needs a name'; topic="$2"; shift 2 ;;
        --out) (( $# >= 2 )) || fail '--out needs a directory'; output="$2"; shift 2 ;;
        --appearance) (( $# >= 2 )) || fail '--appearance needs light, dark or both'; appearance="$2"; shift 2 ;;
        --pair) (( $# >= 3 )) || fail '--pair needs two exact scenario names'; pair="$2,$3"; shift 3 ;;
        --help|-h) usage; exit 0 ;;
        --) shift; scenarios+=("$@"); break ;;
        -*) fail "unknown option: $1" ;;
        *) scenarios+=("$1"); shift ;;
    esac
done
if (( list )); then
    sed -nE 's/^[[:space:]]*Scenario\(name: "([^"]+)", description: "([^"]+)".*$/\1 — \2/p' Tests/LouppeTests/CaptureScenariosTests.swift
    exit 0
fi
case "$appearance" in light|dark|both) ;; *) fail '--appearance must be light, dark or both' ;; esac
[[ -n "$topic" && "$topic" != *[^a-zA-Z0-9_-]* ]] || fail '--topic accepts letters, numbers, underscores and hyphens'
[[ -z "$pair" || ${#scenarios} == 0 ]] || fail 'use --pair or scenario selections, not both'
[[ -n "$output" ]] || output="$HOME/Documents/tmp/louppe-shots/$(date +%F)-$topic"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export LOUPPE_CAPTURE_OUTPUT="$output"
export LOUPPE_CAPTURE_APPEARANCE="$appearance"
export LOUPPE_CAPTURE_SCENARIOS="${(j:,:)scenarios}"
[[ -n "$LOUPPE_CAPTURE_SCENARIOS" ]] || export LOUPPE_CAPTURE_SCENARIOS='*'
export LOUPPE_CAPTURE_PAIR="$pair"
unset LOUPPE_CAPTURE_LIST
# Always run with the foreground gate closed, including inherited CI environments.
export LOUPPE_FOREGROUND_UI=0
log="$output/capture.log"
echo "Capturing to $output (log: $log)"
typeset -a command
if [[ -x "$script_dir/test.sh" ]]; then
    command=("$script_dir/test.sh" --filter CaptureScenariosTests)
else
    command=(swift test --disable-keychain --scratch-path "$LOUPPE_SCRATCH_PATH" --filter CaptureScenariosTests)
fi
result=0
"${command[@]}" > "$log" 2>&1 || result=$?
echo "Output: $output"
find "$output" -maxdepth 1 -name '*.png' -type f -print | sort
echo "Index: $output/index.html"
echo 'Reminder: inactive window appearance; layout review only, never Store, website or README images.'
if (( result )); then
    echo "Capture failed (exit $result). Last log lines:" >&2
    tail -n 35 "$log" >&2
fi
exit "$result"
