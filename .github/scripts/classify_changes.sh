#!/bin/bash
# Decide whether CI must build and test, or the change is documentation only.
# Usage: classify_changes.sh <event> <base-sha> <head-sha>
#   pull_request: base = PR base SHA, head = PR head SHA (merge-base diff)
#   push:         base = the push's `before` SHA, head = the pushed SHA
#   anything else (workflow_dispatch, schedule): always build
# Writes `code=true|false` to $GITHUB_OUTPUT (or stdout). Any doubt builds.
set -uo pipefail

event="${1:-}"
base="${2:-}"
head="${3:-}"

decide() {
    echo "$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "code=$1" >> "$GITHUB_OUTPUT"
    else
        echo "code=$1"
    fi
    exit 0
}

# Files nothing builds, bundles or tests. CHANGELOG.md is bundled and checked
# by build_app.sh; UpdaterConfigurationTests reads Docs/UPDATES.md. Markdown
# elsewhere (Sources, Tests, Packaging, Scripts) counts as code.
is_documentation() {
    case "$1" in
        CHANGELOG.md | Docs/UPDATES.md) return 1 ;;
        Docs/*) return 0 ;;
        */*) return 1 ;;
        *.md | LICENSE) return 0 ;;
        *) return 1 ;;
    esac
}

has_commit() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "$1^{commit}" 2>/dev/null
}

case "$event" in
    pull_request) range_separator="..." ;;
    push) range_separator=".." ;;
    *) decide true "Event '$event' always builds." ;;
esac

if [[ "$base" =~ ^0+$ ]]; then
    decide true "No previous commit (new branch); building."
fi
if ! has_commit "$base" || ! has_commit "$head"; then
    decide true "Base '$base' or head '$head' is unavailable (force push or shallow history); building."
fi

if ! changed="$(git diff --name-only --no-renames -z "$base$range_separator$head" | tr '\0' '\n')"; then
    decide true "git diff failed; building."
fi
if [[ -z "$changed" ]]; then
    decide true "No changed files detected; building."
fi

while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if ! is_documentation "$path"; then
        decide true "Code change: $path"
    fi
done <<< "$changed"

decide false "Documentation-only change; skipping build and tests:
$changed"
