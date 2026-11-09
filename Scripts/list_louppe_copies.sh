#!/bin/zsh
# Read-only inventory; Spotlight plus explicitly bounded, local search roots.
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# > 1 )) || [[ $# == 1 && "$1" != --summary ]]; then
    print -u2 -- "Usage: $0 [--summary]"
    exit 2
fi
python3 - "$PWD" "${1:-}" <<'PY'
import collections, datetime, glob, os, plistlib, subprocess, sys, zipfile
repo, summary = os.path.realpath(sys.argv[1]), sys.argv[2] == '--summary'
home = os.path.expanduser('~')
print('Only `disposable` copies this session created may be removed without asking; list the rest for Alex.')
paths = set()
try:
    result = subprocess.run(['/usr/bin/mdfind', '-0', "kMDItemCFBundleIdentifier == 'com.alexandermarkin.louppe*'"], capture_output=True, timeout=2)
    paths.update(os.fsdecode(p) for p in result.stdout.split(b'\0') if p)
except (OSError, subprocess.TimeoutExpired):
    print('WARN: Spotlight unavailable; bounded filesystem search still used.', file=sys.stderr)
roots = ['/Applications', home + '/Applications', repo + '/dist', home + '/Documents/code/Codex', home + '/Documents/tmp']
roots += glob.glob(home + '/.t3/worktrees/*/dist') + glob.glob(home + '/.t3/worktrees/*/*/dist')
roots += glob.glob('/private/tmp/louppe-*')
for root in roots:
    if not os.path.isdir(root):
        continue
    # Prune every app bundle, so nested Sparkle helpers never become copies.
    result = subprocess.run(['/usr/bin/find', root, '-maxdepth', '6', '(', '-type', 'd', '(', '-name', '*.app', '-o', '-name', '*.app.previous', ')', '-prune', '-print0', ')', '-o', '(', '-type', 'f', '(', '-iname', '*loupp*.zip', '-o', '-iname', '*loupp*.pkg', ')', '-print0', ')'], capture_output=True)
    paths.update(os.fsdecode(p) for p in result.stdout.split(b'\0') if p)

def under(path, root):
    return path == root or path.startswith(root + '/')

def classification(path, bundle_id):
    if path == '/Applications/Louppe.app': return 'installed'
    parts = path.split('/')
    if any(parts[i] == 'dist' and (parts[i+1] == 'release-preparation' or parts[i+1].startswith('app-store')) for i in range(len(parts)-1)):
        return 'release-record'
    if under(path, home + '/Documents/code/louppe/media-library'): return 'media-library'
    if under(path, home + '/.t3/worktrees') or under(path, home + '/Documents/code/Codex'): return 'other-checkout'
    parent = os.path.dirname(path)
    while parent != '/':
        if os.path.exists(parent + '/.git'):
            if os.path.realpath(parent) != repo: return 'other-checkout'
            break
        parent = os.path.dirname(parent)
    if path.endswith('.app.previous') or path.startswith('/private/tmp/louppe-previous-'): return 'rollback'
    if '.review' in bundle_id: return 'review-build'
    if os.path.dirname(path) == repo + '/dist' and path.endswith(('.zip', '.pkg')): return 'release-candidate'
    if (os.path.dirname(path) == repo + '/dist' and path.endswith('.app')) or path.startswith('/private/tmp/louppe-'):
        return 'disposable'
    return 'unknown'

counts = collections.Counter()
for path in sorted({os.path.realpath(p) for p in paths if os.path.exists(p)}):
    info = {}
    try:
        if path.endswith(('.app', '.app.previous')):
            with open(path + '/Contents/Info.plist', 'rb') as f: info = plistlib.load(f)
        elif path.endswith('.zip') and not summary:
            with zipfile.ZipFile(path) as archive:
                candidates = [p for p in archive.infolist() if p.filename.endswith('.app/Contents/Info.plist') and p.filename.count('.app/') == 1 and p.file_size < 1024*1024]
                if candidates: info = plistlib.loads(archive.read(candidates[0]))
    except (OSError, ValueError, zipfile.BadZipFile): pass
    bundle_id = info.get('CFBundleIdentifier', '')
    if not bundle_id.startswith('com.alexandermarkin.louppe') and 'loupp' not in os.path.basename(path).lower(): continue
    category = classification(path, bundle_id)
    counts[category] += 1
    if not summary:
        size = subprocess.run(['/usr/bin/du', '-sh', path], capture_output=True, text=True).stdout.split('\t', 1)[0].strip() or '?'
        modified = datetime.datetime.fromtimestamp(os.stat(path).st_mtime).astimezone().isoformat(timespec='seconds')
        print(f"{category}\t{bundle_id or '?'}\t{info.get('CFBundleShortVersionString', '?')} ({info.get('CFBundleVersion', '?')})\t{size}\t{modified}\t{path}")
if summary:
    for category in ('installed', 'release-record', 'release-candidate', 'review-build', 'rollback', 'media-library', 'other-checkout', 'disposable', 'unknown'):
        print(f'{category}: {counts[category]}')
    print(f'Total: {sum(counts.values())}')
PY
