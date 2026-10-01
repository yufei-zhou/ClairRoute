#!/usr/bin/env python3
"""Stage core resources. Never executes mihomo. Pass a certificate SHA1 to sign it."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
fingerprint = sys.argv[1] if len(sys.argv) > 1 else ''
if fingerprint and not re.fullmatch(r'[0-9a-fA-F]{40}', fingerprint):
    raise SystemExit('Expected an exact local code-signing certificate SHA1.')
upstream = json.loads((root/'Vendor/Upstream.json').read_text())
source = root/'Vendor/mihomo'
if hashlib.sha256(source.read_bytes()).hexdigest() != upstream['originalBinarySHA256']:
    raise SystemExit('Original core changed; fetch it again from the pinned official release.')
destination = root/'Resources/mihomo'
shutil.copyfile(source, destination)
destination.chmod(0o755)
requirement = ''
if fingerprint:
    requirement = f'identifier "local.nano.ClairRoute.Core" and certificate leaf = H"{fingerprint.upper()}"'
    subprocess.run(['/usr/bin/codesign','--force','--sign',fingerprint,'--timestamp=none',
                    '--options','runtime','--identifier','local.nano.ClairRoute.Core',str(destination)], check=True)
    # codesign CLI requires '=' for inline source; stored/API requirements stay bare.
    subprocess.run(['/usr/bin/codesign','--verify','--strict','-R','='+requirement,str(destination)], check=True)
manifest = dict(upstream)
manifest['binarySHA256'] = hashlib.sha256(destination.read_bytes()).hexdigest()
manifest['signingRequirement'] = requirement
(root/'Resources/CoreManifest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
print('Staged signed core.' if fingerprint else 'Staged core for unsigned UI-only build; Helper will refuse activation.')
