#!/bin/zsh
# Read-only diagnostics. Never prompt, activate apps, post events, or fail a job.
set -euo pipefail
export GIT_OPTIONAL_LOCKS=0
trap 'print -u2 -- "WARN: doctor could not complete a probe"; exit 0' ZERR
cd "$(dirname "$0")/.."
source "$PWD/Scripts/lib/xcode_env.sh" || true
export LOUPPE_SCRATCH_PATH="${LOUPPE_SCRATCH_PATH:-/private/tmp/louppe-build-unknown}"

print -- 'Toolchain:'
xcodebuild -version 2>&1 || true
print -- "SDK version: $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || print unknown)"
print -- "SDK path: ${SDKROOT:-unknown}"
print -- "DEVELOPER_DIR: ${DEVELOPER_DIR:-unset}"
xcrun swift --version 2>&1 || true

print -- '\nCheckout:'
print -- "Toplevel: $(git rev-parse --show-toplevel 2>/dev/null || print unknown)"
print -- "HEAD: $(git log -1 --format='%h %s' 2>/dev/null || print unknown)"
if counts="$(git rev-list --left-right --count HEAD...origin/main 2>/dev/null)"; then
    print -- "Ahead/behind origin/main (local refs, no fetch): $counts"
else
    print -- 'Ahead/behind origin/main: unavailable (no local upstream ref)'
fi
# Use NUL-delimited names so whitespace in a dirty path stays intact.
git status --porcelain=v1 -z --untracked-files=all | python3 -c '
import os, sys
records = iter(sys.stdin.buffer.read().split(b"\0")); paths = []
for record in records:
    if not record: continue
    paths.append(os.fsdecode(record[3:]))
    if record[:1] in (b"R", b"C") or record[1:2] in (b"R", b"C"): next(records, None)
print(f"Dirty files: {len(paths)}")
for path in paths[:20]: print("  " + repr(path))
' || true
print -- 'Worktrees:'
git worktree list || true
if configured="$(git config --show-origin --show-scope --get-all core.worktree 2>/dev/null)"; then
    print -- "WARN: core.worktree is set: $configured"
fi
git worktree list --porcelain | python3 -c '
import os, sys
canonical = os.path.realpath(os.path.expanduser("~/Documents/code/louppe/app"))
documents = os.path.expanduser("~/Documents/")
for line in sys.stdin:
    if line.startswith("worktree "):
        path = os.path.realpath(line[9:].strip())
        if path.startswith(documents) and path != canonical:
            print("WARN: noncanonical checkout/worktree under iCloud Documents: " + path)
' || true

print -- '\nBuild:'
print -- "LOUPPE_SCRATCH_PATH: $LOUPPE_SCRATCH_PATH"
lock="$LOUPPE_SCRATCH_PATH.lock"
if [[ -e "$lock" ]]; then
    holders="$(/usr/sbin/lsof -t "$lock" 2>/dev/null || true)"
    # Directory locks carry an owner PID instead of an open-file lock.
    for owner in "$lock/pid" "$lock/owner.pid"; do
        if [[ -f "$owner" ]]; then
            pid="$(head -1 "$owner")"
            if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then holders+=" $pid"; fi
        fi
    done
    if [[ -n "$holders" ]]; then
        print -- "Scratch lock: held by live pid(s) $holders"
    else
        print -- 'Scratch lock: present; no live holder found (may be stale)'
    fi
else
    print -- 'Scratch lock: not held'
fi

print -- '\nDesktop:'
probe_source="$PWD/Scripts/lib/doctor_probe.swift"
probe_dir="/private/tmp/louppe-tools-$(shasum -a 256 "$probe_source" | awk '{print $1}')"
probe="$probe_dir/doctor_probe"
if [[ ! -x "$probe" ]]; then
    mkdir -p "$probe_dir"
    temporary="$(mktemp "$probe_dir/doctor_probe.XXXXXX")"
    if xcrun swiftc "$probe_source" -o "$temporary"; then mv -f "$temporary" "$probe"; else rm -f "$temporary"; fi
fi
if [[ -x "$probe" ]]; then "$probe" || true; else print -- 'WARN: desktop probe unavailable'; fi

print -- '\nInstalled:'
if [[ -f /Applications/Louppe.app/Contents/Info.plist ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Louppe.app/Contents/Info.plist || true
    print -- "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Louppe.app/Contents/Info.plist) ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Louppe.app/Contents/Info.plist))"
else
    print -- '/Applications/Louppe.app: missing'
fi
"$PWD/Scripts/list_louppe_copies.sh" --summary | awk '/^installed:/ {installed=$2} /^Total:/ {print "Other Louppe copies: " $2-installed}' || true

print -- '\nRelease:'
cat VERSION || true
print -- "Latest v* tag: $(git tag --list 'v*' --sort=-version:refname | head -1)"
exit 0
