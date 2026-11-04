#!/bin/zsh
# Kills a real Copy (or Organize) process before each file/directory flush,
# and Copy during its data write, then runs launch recovery in a fresh process
# and checks originals, no-overwrite, leftovers and retry. Journals stay in
# /private/tmp as in production. Not a power-loss test.
#
# Usage: Tests/run_copy_crash_boundary_check.sh [FIXTURE_PARENT] [copy|organize]
# FIXTURE_PARENT defaults to /private/tmp; pass a disposable Louppe-named
# image mount (/Volumes/Louppe...): APFS for Copy, APFS or ExFAT for Organize.
set -euo pipefail
cd "$(dirname "$0")/.."

parent="${1:-/private/tmp}"
operation="${2:-copy}"
case "$operation" in
  copy) suffix="" ;;
  organize) suffix="-organize" ;;
  *) echo "unknown operation: $operation" >&2; exit 2 ;;
esac
case "$parent" in
  /private/tmp|/private/tmp/*|/Volumes/Louppe*) ;;
  *) echo "refusing non-disposable fixture parent: $parent" >&2; exit 2 ;;
esac
build="${LOUPPE_CRASH_CHECK_BUILD:-/private/tmp/louppe-crash-boundary-checks}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$build/module-cache"

sources=()
for f in $(grep -oE '(Sources/Louppe/[A-Za-z0-9_+/]+\.swift|Tests/PerformanceChecks/XMPPublicationStubs\.swift)' Tests/run_performance_checks.sh); do
  sources+=("$f")
done
swiftc -sdk "$SDK" -module-cache-path "$build/module-cache" \
  -D LOUPPE_TEST_SEAMS -D LOUPPE_TESTING -parse-as-library \
  "${sources[@]}" Tests/CrashBoundaryChecks/main.swift \
  -o "$build/LouppeCrashBoundaryChecks" > "$build/compile.log" 2>&1 \
  || { grep -E ': error:' "$build/compile.log" >&2; exit 1; }
binary="$build/LouppeCrashBoundaryChecks"

failures=0
run_boundary() {
  local boundary="$1"
  local root="$parent/LouppeCrashBoundary-$boundary-$$"
  rm -rf "$root"
  "$binary" "prepare$suffix" "$root"
  local output rc
  set +e
  output="$("$binary" "crash$suffix" "$root" "$boundary" 2>&1)"
  rc=$?
  set -e
  local recovery
  if ! recovery="$("$binary" "recover$suffix" "$root" 2>&1)"; then failures=$((failures + 1)); fi
  echo "boundary=$boundary exit=$rc ${output:+$output }$recovery" | tr '\n' ' '
  echo
  rm -rf "$root" "/private/tmp/${root:t}-journals"
  [[ "$output" == COMPLETED* ]]
}

[[ "$operation" == copy ]] && { run_boundary data || true; }
boundary=1
while ! run_boundary "$boundary"; do
  boundary=$((boundary + 1))
  if (( boundary > 200 )); then echo "no completing run" >&2; exit 1; fi
done
echo "CRASH_BOUNDARY_RESULT operation=$operation boundaries=$boundary failures=$failures parent=$parent"
(( failures == 0 ))
