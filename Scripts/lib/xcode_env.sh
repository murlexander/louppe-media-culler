# Shared toolchain environment for Louppe scripts. Source it; don't run it.
#   source "$(dirname "$0")/lib/xcode_env.sh"   (from Scripts/)
# Works in zsh and bash. Exports:
#   DEVELOPER_DIR    full Xcode (the Command Line Tools lack XCTest and SwiftUI macros)
#   SDKROOT          that Xcode's macOS SDK, so an inherited CLT SDKROOT can't leak in
#   LOUPPE_REPO_ROOT this checkout's top level
#   LOUPPE_SCRATCH_PATH          debug/test build products, outside iCloud, one per checkout
#   LOUPPE_RELEASE_SCRATCH_PATH  release build products for build_app.sh, one per checkout

louppe_env_fail() { echo "xcode_env: $*" >&2; return 1; }

if [[ -z "${DEVELOPER_DIR:-}" || ! -d "${DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR
[[ -d "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]] \
    || louppe_env_fail "full Xcode with XCTest not found at $DEVELOPER_DIR" || return 1

SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" \
    || louppe_env_fail "xcrun could not find the macOS SDK in $DEVELOPER_DIR" || return 1
[[ "$SDKROOT" == "$DEVELOPER_DIR"/* ]] \
    || louppe_env_fail "SDK $SDKROOT is not inside $DEVELOPER_DIR" || return 1
export SDKROOT

LOUPPE_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || louppe_env_fail "not inside a git checkout" || return 1
export LOUPPE_REPO_ROOT

louppe_checkout_key="$(printf %s "$LOUPPE_REPO_ROOT" | shasum | cut -c1-8)"
export LOUPPE_SCRATCH_PATH="${LOUPPE_SCRATCH_PATH:-/private/tmp/louppe-build-$louppe_checkout_key}"
export LOUPPE_RELEASE_SCRATCH_PATH="${LOUPPE_RELEASE_SCRATCH_PATH:-/private/tmp/louppe-build-$louppe_checkout_key-release}"
unset louppe_checkout_key
