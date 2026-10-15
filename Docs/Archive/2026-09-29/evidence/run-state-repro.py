import pathlib
import subprocess

repo = pathlib.Path('/Users/developer/Documents/code/louppe/app')
root = pathlib.Path('/private/tmp/louppe-audit-2026-09-29')
script = (repo / 'Tests/run_performance_checks.sh').read_text()
paths = [s.strip(' \\') for s in script.splitlines()
         if s.strip().startswith(('Sources/', 'Tests/PerformanceChecks/'))]
paths.remove('Tests/PerformanceChecks/main.swift')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
command = ['xcrun', 'swiftc', '-sdk', sdk,
           '-module-cache-path', str(root / 'state-module-cache'),
           '-D', 'LOUPPE_TESTING', '-D', 'DEBUG', '-parse-as-library',
           *paths, str(root / 'StateAuditRepro.swift'), '-o', str(root / 'StateAuditRepro')]
build = subprocess.run(command, cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(root / 'state-repro-build.log').write_text(build.stdout)
print('compile exit:', build.returncode)
if build.returncode:
    print(build.stdout)
    raise SystemExit(build.returncode)
run = subprocess.run([str(root / 'StateAuditRepro')], cwd=repo,
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(root / 'state-repro.log').write_text(run.stdout)
print(run.stdout)
print('run exit:', run.returncode)
raise SystemExit(run.returncode)
