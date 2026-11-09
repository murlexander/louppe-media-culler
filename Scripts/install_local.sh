#!/bin/zsh
# The local installer: gates, isolated packaging, rollback, and a background check.
# Usage: Scripts/install_local.sh [--skip-gates "<reason>"] [--quit-running]
#   --quit-running  gracefully quit a Louppe running in the background (only with Alex's OK);
#                   a frontmost Louppe always stops the install.
# Testing only: LOUPPE_INSTALL_DEST=<dir>/Louppe.app, LOUPPE_INSTALL_SKIP_LAUNCH=1.
set -euo pipefail
cd "$(dirname "$0")/.."

step=arguments
reason='unexpected command failure'
staging_root=''
check_root=''
previous_root=''
previous_app=''
new_owned=0
replaced=0
launched_pid=''
control=''
skip_reason=''
quit_running=0
lock_owned=0
install_lock=/private/tmp/louppe-install.lock
destination="${LOUPPE_INSTALL_DEST:-/Applications/Louppe.app}"

fail() {
    reason="$1"
    exit "${2:-1}"
}
finish() {
    local result=$?
    trap - EXIT
    if [[ -n "$launched_pid" ]]; then
        # The launch-check process is this script's own child: ask it to quit, then TERM it.
        if [[ -n "$control" ]] && "$control" quit "$launched_pid" 20 2>/dev/null; then
            launched_pid=''
        else
            kill -TERM "$launched_pid" 2>/dev/null || true
            for _ in {1..50}; do kill -0 "$launched_pid" 2>/dev/null || break; sleep 0.1; done
            if kill -0 "$launched_pid" 2>/dev/null; then
                print -u2 -- "WARN: launch-check pid $launched_pid is still running; no forced kill."
                if (( result == 0 )); then result=3; reason='launch-check process did not quit'; fi
            else
                launched_pid=''
            fi
        fi
    fi
    if (( result != 0 )); then
        # Restore only this invocation's replacement. Never touch another copy.
        if (( replaced )); then
            if [[ -n "$launched_pid" ]]; then
                print -u2 -- "WARN: rollback deferred while launch-check process runs; previous app: ${previous_app:-none}"
            elif mv "$destination" "$staging_root/failed.app"; then
                if [[ -n "$previous_app" && -d "$previous_app" ]]; then
                    mv "$previous_app" "$destination" || print -u2 -- "WARN: restore failed; rollback app: $previous_app"
                fi
            else
                print -u2 -- "WARN: could not move failed replacement; rollback app: ${previous_app:-none}"
            fi
        elif [[ -n "$previous_app" && -d "$previous_app" && ! -e "$destination" ]]; then
            mv "$previous_app" "$destination" || print -u2 -- "WARN: restore failed; rollback app: $previous_app"
        fi
        print -u2 -- "install_local: FAIL $step: $reason"
    fi
    if (( new_owned )) && [[ -e "$destination.new" ]]; then rm -rf -- "$destination.new"; fi
    [[ -z "$check_root" || -n "$launched_pid" ]] || rm -rf -- "$check_root"
    [[ -z "$staging_root" ]] || rm -rf -- "$staging_root"
    if [[ -n "$previous_root" && ! -e "$previous_app" ]]; then rmdir "$previous_root" 2>/dev/null || true; fi
    if (( lock_owned )); then rm -f "$install_lock/pid"; rmdir "$install_lock" 2>/dev/null || true; fi
    exit "$result"
}
trap finish EXIT

usage='Usage: Scripts/install_local.sh [--skip-gates "<non-empty reason>"] [--quit-running]'
while (( $# )); do
    case "$1" in
        --skip-gates)
            (( $# >= 2 )) && [[ -n "${2//[[:space:]]/}" && -z "$skip_reason" ]] || fail "$usage" 2
            skip_reason="$2"; shift ;;
        --quit-running) quit_running=1 ;;
        *) fail "$usage" 2 ;;
    esac
    shift
done
[[ "$destination" == /*/Louppe.app ]] || fail 'destination must be an absolute path ending in /Louppe.app' 2
[[ ! -L "$destination" && ! -e "$destination.new" && ! -L "$destination.new" ]] \
    || fail 'destination is a symlink or destination.new already exists' 2
source "$PWD/Scripts/lib/xcode_env.sh"
# One install at a time: installs share dist/Louppe.app and destination.new.
if mkdir "$install_lock" 2>/dev/null; then
    lock_owned=1; print -- $$ > "$install_lock/pid"
else
    owner="$(cat "$install_lock/pid" 2>/dev/null || true)"
    if [[ "$owner" == <-> ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -f "$install_lock/pid"; rmdir "$install_lock" 2>/dev/null || true
        mkdir "$install_lock" 2>/dev/null || fail "another install holds $install_lock" 3
        lock_owned=1; print -- $$ > "$install_lock/pid"
    else
        fail "another install is running (pid ${owner:-unknown}; lock $install_lock)" 3
    fi
fi
if [[ "$destination" != /Applications/Louppe.app ]]; then
    print -- "WARN: non-standard destination for testing only: $destination"
fi
for other in /Applications/*[oO][uU][pP][pP]*(N); do
    [[ "$other" == /Applications/Louppe.app ]] || print -- "WARN: other Applications copy (left untouched): $other"
done

step=gates
if [[ -n "$skip_reason" ]]; then
    print -- "gates: skipped ($skip_reason)"
else
    ./Scripts/test.sh --gates || fail 'regression gates failed'
fi
step=build
LOUPPE_SCRATCH_PATH="$LOUPPE_RELEASE_SCRATCH_PATH" ./build_app.sh || fail 'build_app.sh failed'

step=stage
staging_root="$(mktemp -d /private/tmp/louppe-install-$(date +%Y%m%d-%H%M%S).XXXXXX)"
staged_app="$staging_root/Louppe.app"
ditto --norsrc --noextattr dist/Louppe.app "$staged_app" || fail 'could not stage dist/Louppe.app'
xattr -cr "$staged_app" || fail 'could not clear staged extended attributes'
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$staged_app/Contents/Info.plist"; }
[[ "$(plist_value CFBundleIdentifier)" == com.alexandermarkin.louppe ]] || fail 'refusing non-official bundle identifier'
codesign --verify --deep --strict "$staged_app" || fail 'staged signature verification failed'
version="$(plist_value CFBundleShortVersionString)"
build="$(plist_value CFBundleVersion)"
executable="$(plist_value CFBundleExecutable)"
[[ "$executable" == Louppe ]] || fail 'unexpected bundle executable'

step=app-control
control_source="$PWD/Scripts/lib/app_control.swift"
control_dir="/private/tmp/louppe-tools-$(shasum -a 256 "$control_source" | awk '{print $1}')"
control="$control_dir/app_control"
if [[ ! -x "$control" ]]; then
    mkdir -p "$control_dir"
    temporary="$(mktemp "$control_dir/app_control.XXXXXX")"
    if xcrun swiftc "$control_source" -o "$temporary"; then
        mv -f "$temporary" "$control"
    else
        rm -f "$temporary"
        fail 'could not compile app_control'
    fi
fi

step=running-app
running="$("$control" pids "$destination")" || fail 'could not inspect destination processes'
frontmost="$("$control" frontmost)" || fail 'could not determine frontmost app'
frontmost_pid="${frontmost##*$'\t'}"
for pid in ${(f)running}; do
    [[ "$pid" != "$frontmost_pid" ]] || fail 'Louppe is in use; ask Alex before replacing it' 2
done
if [[ -n "$running" ]] && (( ! quit_running )); then
    fail 'Louppe is running in the background; rerun with --quit-running once Alex agrees to quit it' 2
fi
for pid in ${(f)running}; do
    "$control" quit "$pid" 20 || fail "background Louppe pid $pid did not quit within 20 seconds" 3
done
[[ -z "$("$control" pids "$destination")" ]] || fail 'a destination instance is still running' 3
if [[ "${LOUPPE_INSTALL_SKIP_LAUNCH:-0}" != 1 ]]; then
    # Check before replacing anything: the launch check needs no other Louppe running.
    ./Scripts/doctor.sh > "$staging_root/doctor-before.log"
    grep -Fqx 'Running Louppe-family processes: 0' "$staging_root/doctor-before.log" \
        || fail 'another Louppe-family process is running (see Scripts/doctor.sh); quit it or rerun with LOUPPE_INSTALL_SKIP_LAUNCH=1' 2
fi

step=replace
mkdir -p "${destination:h}" || fail 'could not create destination parent'
new_owned=1
ditto --norsrc --noextattr "$staged_app" "$destination.new" || fail 'could not copy replacement'
xattr -cr "$destination.new" || fail 'could not clear replacement extended attributes'
codesign --verify --deep --strict "$destination.new" || fail 'replacement signature verification failed'
# Recheck immediately before moving the old app in case it was opened meanwhile.
[[ -z "$("$control" pids "$destination")" ]] || fail 'Louppe started during installation; retry after it quits' 2
if [[ -e "$destination" ]]; then
    previous_root="$(mktemp -d /private/tmp/louppe-previous-$(date +%Y%m%d-%H%M%S).XXXXXX)"
    # Not named .app, so Launch Services never opens the rollback copy.
    previous_app="$previous_root/Louppe.app.previous"
    mv "$destination" "$previous_app" || fail 'could not preserve the previous app'
    print -- "Rollback path: $previous_app"
fi
mv "$destination.new" "$destination" || fail 'could not move replacement into place'
new_owned=0
replaced=1
codesign --verify --deep --strict "$destination" || fail 'installed signature verification failed'

step=launch-check
if [[ "${LOUPPE_INSTALL_SKIP_LAUNCH:-0}" == 1 ]]; then
    print -- 'launch check skipped (LOUPPE_INSTALL_SKIP_LAUNCH=1)'
else
    # Recheck immediately before the smoke launch.
    ./Scripts/doctor.sh > "$staging_root/doctor.log"
    grep -Fqx 'Running Louppe-family processes: 0' "$staging_root/doctor.log" \
        || { cat "$staging_root/doctor.log"; fail 'another Louppe-family process started; rerun with LOUPPE_INSTALL_SKIP_LAUNCH=1'; }
    check_root="$(mktemp -d /private/tmp/louppe-install-check-$(date +%Y%m%d-%H%M%S).XXXXXX)"
    for image in square.webp square.avif; do
        cp "Tests/Fixtures/ModernImages/$image" "$check_root/$image" || fail 'could not copy disposable launch fixtures'
    done
    before="$("$control" frontmost)" || fail 'could not record foreground application'
    LOUPPE_BACKGROUND_LAUNCH=1 "$destination/Contents/MacOS/$executable" -openFolder "$check_root" >"$check_root/launch.log" 2>&1 &
    launched_pid=$!
    deadline=$(( SECONDS + 30 ))
    exec_deadline=$(( SECONDS + 5 ))
    verified_pid=0
    launched_path="$destination/Contents/MacOS/$executable"
    resolved_path="$(cd "$destination/Contents/MacOS" && pwd -P)/$executable"
    while (( SECONDS < deadline )); do
        kill -0 "$launched_pid" 2>/dev/null || fail 'launched process exited before saving its session'
        actual="$(ps -ww -p "$launched_pid" -o comm=)" || fail 'could not read launched executable path'
        if [[ "$actual" != "$launched_path" && "$actual" != "$resolved_path" ]]; then
            # Right after the fork the child is still the shell; allow it a moment to exec.
            (( SECONDS < exec_deadline )) || fail "wrong launched executable for pid $launched_pid: $actual"
            sleep 0.2; continue
        fi
        instances="$("$control" pids "$destination")"
        if [[ $'\n'"$instances"$'\n' == *$'\n'"$launched_pid"$'\n'* ]]; then verified_pid=1; fi
        if (( verified_pid )) && [[ -f "$check_root/.louppe_session.json" ]]; then break; fi
        sleep 0.2
    done
    (( verified_pid )) && [[ -f "$check_root/.louppe_session.json" ]] || fail 'no session sidecar from the verified installed process within 30 seconds'
    "$control" quit "$launched_pid" 20 || fail 'launch-check process did not quit within 20 seconds' 3
    launched_pid=''
    after="$("$control" frontmost)" || fail 'could not inspect foreground application after launch'
    [[ "$before" == "$after" ]] || print -- "WARN: frontmost app changed during launch check: $before -> $after"
fi
summary="install_local: PASS $version ($build) at $destination"
[[ -z "$skip_reason" ]] || summary+="; gates: skipped ($skip_reason)"
[[ "${LOUPPE_INSTALL_SKIP_LAUNCH:-0}" != 1 ]] || summary+='; launch check skipped'
print -r -- "$summary"
