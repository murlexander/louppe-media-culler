#!/usr/bin/env python3
"""Opt-in disk-image detach/remount coordinator for FileVolumeAcceptanceTests.

Usage: python3 Tests/run_file_volume_remount_check.py MOUNT apfs|exfat IMAGE
Only Louppe-named disposable mounts backed by /private/tmp/louppe-readiness
images are accepted. No physical disks are detached or formatted.
"""
import os, pathlib, plistlib, subprocess, sys, time, uuid
mount, fs_name, image = sys.argv[1:]
image = str(pathlib.Path(image).resolve())
assert image.startswith('/private/tmp/louppe-readiness/')
assert mount.startswith('/Volumes/Louppe')
info = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', mount]))
assert info['BusProtocol'] == 'Disk Image' and info['FilesystemType'] == fs_name
images = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))['images']
assert any(str(pathlib.Path(x['image-path']).resolve()) == image and any(y.get('mount-point') == mount for y in x['system-entities']) for x in images)
root = pathlib.Path('/private/tmp/louppe-readiness')
handoff = root / ('remount-' + fs_name + '-' + str(uuid.uuid4()))
handoff.mkdir()
logpath = root / ('remount-' + fs_name + '.log')
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', LOUPPE_FILE_VOLUME_ROOT=mount, LOUPPE_FILE_VOLUME_FS=fs_name, LOUPPE_FILE_VOLUME_HANDOFF=str(handoff))
command = ['swift', 'test', '--disable-keychain', '--scratch-path', '/private/tmp/louppe-readiness-persistence-build', '--skip-build', '--filter', 'FileVolumeAcceptanceTests/testDiskImageRemountKeepsOfflineRatingsAndOriginalBytes']
with logpath.open('w') as log:
    process = subprocess.Popen(command, cwd=str(pathlib.Path(__file__).resolve().parent.parent), env=env, stdout=log, stderr=subprocess.STDOUT)
    detached = False
    def wait_marker(name):
        deadline = time.monotonic() + 30
        while not (handoff / name).exists():
            if process.poll() is not None: raise RuntimeError('test exited before ' + name)
            if time.monotonic() >= deadline: raise RuntimeError('timeout before ' + name)
            time.sleep(.02)
    try:
        wait_marker('ready')
        print('Detaching verified disposable image:', mount, flush=True)
        subprocess.run(['hdiutil', 'detach', mount], stdout=log, stderr=subprocess.STDOUT, check=True)
        detached = True
        (handoff / 'detached').touch()
        wait_marker('offline-saved')
        print('Offline backup confirmed; remounting:', image, flush=True)
        subprocess.run(['hdiutil', 'attach', '-nobrowse', image], stdout=log, stderr=subprocess.STDOUT, check=True)
        detached = False
        (handoff / 'remounted').touch()
        exitcode = process.wait(timeout=30)
    finally:
        if detached:
            subprocess.run(['hdiutil', 'attach', '-nobrowse', image], stdout=log, stderr=subprocess.STDOUT, check=True)
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
print(logpath.read_text())
print('REMOUNT_RESULT:', fs_name, exitcode, 'log:', logpath, flush=True)
sys.exit(exitcode)
