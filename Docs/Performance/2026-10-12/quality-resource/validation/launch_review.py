from pathlib import Path
import datetime, hashlib, json, os, plistlib, shutil, subprocess, tempfile, time, uuid

repo = Path('/Users/alexander_markin/Documents/code/louppe/app')
output = Path('/private/tmp/louppe-quality-resource')
root = Path(tempfile.mkdtemp(prefix='louppe-quality-resource-review-', dir='/private/tmp'))
app = root / 'Louppe Quality Review.app'
subprocess.run(['ditto', '--noextattr', '--noqtn', str(repo/'dist/Louppe.app'), str(app)], check=True)
plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
identifier = 'com.alexandermarkin.louppe.qualityResourceReview20261013.r' + uuid.uuid4().hex[:8]
info.update(CFBundleIdentifier=identifier, CFBundleDisplayName='Louppe Quality Review',
            CFBundleName='Louppe Quality Review', LouppeReviewBuild=True)
plist.write_bytes(plistlib.dumps(info))
subprocess.run(['xattr', '-cr', str(app)], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

fixture = root / 'launch-photos'
fixture.mkdir()
sources = sorted(Path('/private/tmp/louppe-performance-implementation-83x3uszk/launch-photos').glob('*.png'))
sources += [Path('/private/tmp/Louppe-Review-2026-10-12-Demo/31-camera-pair.RAF')]
assert len(sources) == 13
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()
source_hashes = {str(p): digest(p) for p in sources}
for p in sources:
    shutil.copyfile(p, fixture/p.name)
fixture_hashes = {p.name: digest(fixture/p.name) for p in sources}
assert all(fixture_hashes[p.name] == source_hashes[str(p)] for p in sources)

subprocess.run(['open', '-n', str(app), '--args', '-openFolder', str(fixture)], check=True)
sidecar = fixture / '.louppe_session.json'
deadline = time.monotonic() + 30
while not sidecar.exists() and time.monotonic() < deadline:
    time.sleep(.1)
assert sidecar.exists(), 'Fresh launch did not produce its disposable session'
data = json.loads(sidecar.read_text())
assert data['version'] == 7 and len(data['entries']) == 13
assert all(e['rating'] == 'undecided' for e in data['entries'])
assert all(digest(Path(p)) == value for p, value in source_hashes.items())
assert all(digest(fixture/name) == value for name, value in fixture_hashes.items())
exe = str(app/'Contents/MacOS/Louppe')
processes = subprocess.check_output(['ps','-axo','pid=,command='],text=True)
pids = [int(line.strip().split(None,1)[0]) for line in processes.splitlines()
        if len(line.strip().split(None,1)) == 2 and line.strip().split(None,1)[1].startswith(exe)]
assert pids, 'Fresh review process exited'
for pid in pids: os.kill(pid,0)
result = dict(generatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    app=str(app), fixture=str(fixture), bundleIdentifier=identifier, pids=pids,
    schema=data['version'], entries=len(data['entries']), allUnrated=True,
    fixtureAndSourceBytesUnchanged=True, strictTemporarySignatureVerified=True,
    containsDisposableRAW=True, updatesDisabled=True)
(output/'launch.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
