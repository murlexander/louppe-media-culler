#!/bin/zsh
# Scan HEAD history and local edits; --all-refs explicitly audits every ref.
# Never send the source to a scanning service.
set -euo pipefail
cd "$(dirname "$0")/.."

log_opts="HEAD"
case "$#:${1:-}" in
    0:) ;;
    1:--all-refs) log_opts="--all" ;;
    *) echo "Usage: Scripts/check_credentials.sh [--all-refs]" >&2; exit 2 ;;
esac

readonly version="8.30.1"
case "$(uname -m)" in
    arm64)
        readonly architecture="arm64"
        readonly checksum="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
        ;;
    x86_64)
        readonly architecture="x64"
        readonly checksum="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
        ;;
    *)
        echo "Credential checks require a supported macOS architecture." >&2
        exit 1
        ;;
esac
readonly scan_directory="$(mktemp -d /private/tmp/louppe-credential-check.XXXXXX)"
trap 'rm -rf "$scan_directory"' EXIT
readonly archive="$scan_directory/gitleaks.tar.gz"
curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_darwin_${architecture}.tar.gz" \
    --output "$archive"
print -r -- "$checksum  $archive" | shasum -a 256 --check --status
tar -xzf "$archive" -C "$scan_directory" gitleaks
result=0
echo "Credential scan: history ($log_opts)"
"$scan_directory/gitleaks" git --redact --no-banner --log-opts="$log_opts" . || result=$?
# Always check staged and unstaged tracked edits, even if history contains a hit.
echo "Credential scan: staged changes"
"$scan_directory/gitleaks" git --pre-commit --staged --redact --no-banner . || result=$?
echo "Credential scan: working-tree changes"
"$scan_directory/gitleaks" git --pre-commit --redact --no-banner . || result=$?
exit "$result"
