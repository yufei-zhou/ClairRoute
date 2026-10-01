#!/usr/bin/env python3
"""Read-only verification of the signed build. Never executes packaged code."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

if len(sys.argv) != 2 or not re.fullmatch(r'[0-9A-Fa-f]{40}', sys.argv[1]):
    raise SystemExit('Usage: python3 Tests/signature-preflight.py <expected certificate SHA1>')
fingerprint = sys.argv[1].upper()
root = Path(__file__).resolve().parent.parent
app = root / '.build/Local/Build/Products/Release/ClairRoute.app'
resources = app / 'Contents/Resources'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('ClairRouteCertificateSHA1') != fingerprint:
    raise SystemExit('The app does not pin the expected signing identity.')
components = [
    (app, 'local.nano.ClairRoute'),
    (app / 'Contents/MacOS/ClairRouteHelper', 'local.nano.ClairRoute.Helper'),
    (app / 'Contents/MacOS/ClairRouteRecoveryGuard', 'local.nano.ClairRoute.RecoveryGuard'),
    (resources / 'mihomo', 'local.nano.ClairRoute.Core'),
]

def verify(path, requirement):
    return subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R',
                           '=' + requirement, str(path)], capture_output=True, text=True)

wrong_fingerprint = ('0' if fingerprint[0] != '0' else '1') + fingerprint[1:]
for path, identifier in components:
    requirement = f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'
    correct = verify(path, requirement)
    if correct.returncode:
        raise SystemExit(f'{identifier}: expected requirement failed: {correct.stderr.strip()}')
    for wrong in [f'identifier "local.nano.invalid" and certificate leaf = H"{fingerprint}"',
                  f'identifier "{identifier}" and certificate leaf = H"{wrong_fingerprint}"']:
        rejected = verify(path, wrong)
        if rejected.returncode != 3 or 'failed to satisfy specified code requirement' not in rejected.stderr:
            raise SystemExit(f'{identifier}: negative requirement check was not a confirmed mismatch')
    print(f'PASS: {identifier}; correct identity accepted, wrong identifier/certificate rejected')

manifest = json.loads((resources / 'CoreManifest.json').read_text())
if manifest['signingRequirement'].startswith('='):
    raise SystemExit('CLI prefix leaked into the Security API requirement.')
if hashlib.sha256((resources / 'mihomo').read_bytes()).hexdigest() != manifest['binarySHA256']:
    raise SystemExit('Packaged core digest does not match manifest.')
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('PASS: sealed bundle and packaged core digest; no code executed or network changed')
