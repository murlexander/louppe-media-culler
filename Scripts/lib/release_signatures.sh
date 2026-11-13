# Shared by release preflight and disposable signature fixtures (zsh).
verify_developer_id_signatures() {
    local bundle="$1" label="$2" EXPECTED_DEVELOPER_TEAM_ID="$3"
    local signing_details
    local team_identifier
    signing_details="$(codesign -dvvv "$bundle" 2>&1)"
    grep -Fq 'Authority=Developer ID Application:' <<< "$signing_details" \
        || fail "$label is not signed with a Developer ID Application certificate."
    grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<< "$signing_details" \
        || fail "$label has no valid Apple Developer team identifier."
    grep -Eq 'flags=.*\(runtime\)' <<< "$signing_details" \
        || fail "$label does not enable the hardened runtime."

    team_identifier="$(awk -F= '$1 == "TeamIdentifier" { print $2 }' <<< "$signing_details")"
    [[ "$team_identifier" == "$EXPECTED_DEVELOPER_TEAM_ID" ]] \
        || fail "$label is not signed by the SAMO DANNI EOOD Apple Developer team."
    local sparkle_version="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
    local -a nested_code
    nested_code=(
        "$sparkle_version/XPCServices/Installer.xpc"
        "$sparkle_version/XPCServices/Downloader.xpc"
        "$sparkle_version/Autoupdate"
        "$sparkle_version/Updater.app"
        "$bundle/Contents/Frameworks/Sparkle.framework"
    )
    local code nested_details nested_team
    for code in "${nested_code[@]}"; do
        [[ -e "$code" ]] || fail "$label is missing signed Sparkle code at $code."
        nested_details="$(codesign -dvvv "$code" 2>&1)"
        grep -Fq 'Authority=Developer ID Application:' <<< "$nested_details" \
            || fail "$label contains Sparkle code without a Developer ID signature."
        nested_team="$(awk -F= '$1 == "TeamIdentifier" { print $2 }' <<< "$nested_details")"
        [[ "$nested_team" == "$team_identifier" ]] \
            || fail "$label contains Sparkle code signed by another Apple Developer team."
        grep -Eq 'flags=.*\(runtime\)' <<< "$nested_details" \
            || fail "$label contains Sparkle code without the hardened runtime."
    done
}
