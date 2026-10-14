#!/bin/zsh
# Repeated optimized measurements. Ordinary swift test runs skip these tests.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export LOUPPE_SPEED_TESTS=1
export LOUPPE_SPEED_OUTPUT="${LOUPPE_SPEED_OUTPUT:-$(mktemp -d /private/tmp/louppe-speed-results.XXXXXX)}"
mkdir -p "$LOUPPE_SPEED_OUTPUT"
{
    date -u +%Y-%m-%dT%H:%M:%SZ
    git rev-parse HEAD
    git status --short
    git diff --stat
    git diff --binary | shasum -a 256
    shasum -a 256 Tests/LouppeTests/*Speed*.swift
    print "Sizes: ${LOUPPE_SPEED_SIZES:-1000,10000,100000}"
    print "Repetitions: ${LOUPPE_SPEED_REPETITIONS:-7}; warmups: 1"
    print "Filter: ${LOUPPE_SPEED_FILTER:-LouppeSpeed}"
    swift --version
    xcodebuild -version
    uname -m
} > "$LOUPPE_SPEED_OUTPUT/context.txt"
print "Speed results: $LOUPPE_SPEED_OUTPUT"
# The existing XCTest target references DEBUG-only seams unconditionally.
# Keep those seams while using release optimization; report this exact flag.
# No parallel test workers: timings would contend for CPU, disk and UI lanes.
swift test --disable-keychain --build-system native -c release -Xswiftc -DDEBUG \
    --filter "${LOUPPE_SPEED_FILTER:-LouppeSpeed}" 2>&1 | tee "$LOUPPE_SPEED_OUTPUT/console.log"
print "Results saved: $LOUPPE_SPEED_OUTPUT"
