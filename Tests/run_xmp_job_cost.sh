#!/bin/zsh
# Real optimized production XMP jobs, one build and one measurement at a time.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$PWD/Scripts/lib/xcode_env.sh"
lock="$HOME/.louppe-perf/measure.lock"
mkdir -p "$(dirname "$lock")"
# Share test.sh's per-checkout lock, including during compilation.
build_lock="$LOUPPE_SCRATCH_PATH.lock"
if ! mkdir "$build_lock" 2>/dev/null; then
    echo "XMP runner: checkout build lock is held: $build_lock" >&2
    exit 3
fi
print -r -- "$$" > "$build_lock/pid"
owns_measurement=0
cleanup() {
    if (( owns_measurement )); then rmdir "$lock"; fi
    rm "$build_lock/pid"
    rmdir "$build_lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Compilation is outside the measurement lock and timed regions.
swift build --build-system native --disable-keychain --scratch-path "$LOUPPE_SCRATCH_PATH" -c release --build-tests -Xswiftc -DLOUPPE_TEST_SEAMS -Xswiftc -enable-testing
if [[ -e "$lock" ]]; then echo "Waiting for XMP measurement lock: $lock"; fi
until mkdir "$lock" 2>/dev/null; do sleep 1; done
owns_measurement=1
export LOUPPE_XMP_JOB_COST=1
for count in ${=LOUPPE_XMP_SIZES:-1000 2000 4000}; do
    for layout in flat dispersed; do
        for operation in publication move; do
            export LOUPPE_XMP_FAMILIES="$count" LOUPPE_XMP_LAYOUT="$layout" LOUPPE_XMP_OPERATION="$operation"
            swift test --build-system native --disable-keychain --scratch-path "$LOUPPE_SCRATCH_PATH" -c release --skip-build --filter XMPJobCostTests/testOptimizedWholeJob
        done
    done
done
