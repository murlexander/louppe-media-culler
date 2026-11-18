#!/bin/bash
# Update Casks/louppe.rb on the newest main and push it, retrying when another
# push (usually the appcast.xml feed commit) moved main first. Never forces.
# Each attempt resets to the fetched tip and re-renders the cask, so a retry
# keeps the other commit and never pushes an empty commit.
set -euo pipefail

readonly remote="${CASK_REMOTE:-origin}"
readonly branch="${CASK_BRANCH:-main}"
readonly attempts="${CASK_PUSH_ATTEMPTS:-5}"
readonly backoff="${CASK_PUSH_BACKOFF_SECONDS:-5}"
readonly update_command="${CASK_UPDATE_COMMAND:-python3 Scripts/update_homebrew_cask.py}"
readonly cask="Casks/louppe.rb"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for (( attempt = 1; attempt <= attempts; attempt++ )); do
    git fetch --quiet "$remote" "$branch"
    git reset --quiet --hard FETCH_HEAD
    $update_command

    if git diff --quiet -- "$cask"; then
        echo "The cask on $remote/$branch is already up to date."
        exit 0
    fi
    git add -- "$cask"
    git commit --quiet -m "Update Homebrew cask for latest Louppe release"

    if output="$(git push "$remote" "HEAD:$branch" 2>&1)"; then
        echo "$output"
        echo "Pushed the cask update on attempt $attempt."
        exit 0
    fi
    echo "$output" >&2
    if ! grep -Eq '! \[rejected\]|non-fast-forward|fetch first|cannot lock ref|incorrect old value' <<< "$output"; then
        echo "::error::Cask push failed for a reason other than a moved $branch." >&2
        exit 1
    fi
    if (( attempt < attempts )); then
        delay=$(( backoff * (1 << (attempt - 1)) ))
        echo "$remote/$branch moved during attempt $attempt; retrying in ${delay}s."
        sleep "$delay"
    fi
done

echo "::error::Cask push lost the race with $remote/$branch $attempts times; rerun Update Homebrew package." >&2
exit 1
