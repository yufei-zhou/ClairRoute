#!/usr/bin/env python3
"""Compile and package the native app without loading Xcode IDE plug-ins.

Does not execute the app, helper or core; never installs a service.
"""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--identity', default='', help='Local codesigning identity SHA1; omit for UI-only preview')
parser.add_argument('--version', default='', help='Release version X.Y.Z written into the app (default: source plist)')
args = parser.parse_args()
if args.version and not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
    parser.error('--version must look like 1.2.3')
identity = args.identity.upper()
if identity and not re.fullmatch(r'[0-9A-F]{40}', identity):
    parser.error('--identity must be the exact 40-character certificate SHA1')
if subprocess.check_output(['/usr/bin/uname', '-m'], text=True).strip() != 'arm64':
    parser.error('Apple Silicon is required')
root = Path(__file__).resolve().parent.parent
developer = Path(subprocess.check_output(['/usr/bin/xcode-select', '-p'], text=True).strip())
compiler = developer/'Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
sdk = developer/'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
if not compiler.is_file() or not sdk.is_dir():
    parser.error('Select a complete Xcode installation with xcode-select first')
if not (root/'Vendor/mihomo').is_file():
    parser.error('First run Scripts/fetch-core.sh to obtain the pinned official core')
subprocess.run(['/usr/bin/python3', str(root/'Scripts/prepare-core.py')] + ([identity] if identity else []), check=True)
build = root/'.build'/('Local' if identity else 'Preview')
products = build/'Build/Products/Release'
products.mkdir(parents=True, exist_ok=True)
app = products/'ClairRoute.app'
staging = products/'ClairRoute.building.app'
if staging.is_symlink() or app.is_symlink():
    parser.error('Refusing a symbolic link at the app output path')
if staging.exists():
    shutil.rmtree(staging)
macos = staging/'Contents/MacOS'
resources = staging/'Contents/Resources'
daemons = staging/'Contents/Library/LaunchDaemons'
for directory in (macos, resources, daemons, build/'ModuleCache'):
    directory.mkdir(parents=True, exist_ok=True)

def process_plist(source, destination, bundle_id, executable):
    values = {
        'PRODUCT_BUNDLE_IDENTIFIER': bundle_id, 'EXECUTABLE_NAME': executable,
        'MACOSX_DEPLOYMENT_TARGET': '26.0', 'CLAIRROUTE_CERT_SHA1': identity,
    }
    content = source.read_text()
    for key, value in values.items():
        content = content.replace('$(' + key + ')', value)
    if '$(' in content:
        raise SystemExit('Unresolved build setting in ' + str(source))
    with destination.open('wb') as stream:
        plistlib.dump(plistlib.loads(content.encode()), stream)

helper_info = build/'Helper-Info.plist'
guard_info = build/'RecoveryGuard-Info.plist'
process_plist(root/'Resources/Helper-Info.plist', helper_info,
              'local.nano.ClairRoute.Helper', 'ClairRouteHelper')
process_plist(root/'Resources/Helper-Info.plist', guard_info,
              'local.nano.ClairRoute.RecoveryGuard', 'ClairRouteRecoveryGuard')
process_plist(root/'Resources/App-Info.plist', staging/'Contents/Info.plist',
              'local.nano.ClairRoute', 'ClairRoute')
if args.version:
    # CFBundleVersion must increase monotonically; derive it from X.Y.Z.
    major, minor, patch = map(int, args.version.split('.'))
    with (staging/'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
    info['CFBundleShortVersionString'] = args.version
    info['CFBundleVersion'] = str(major * 10_000 + minor * 100 + patch)
    with (staging/'Contents/Info.plist').open('wb') as stream: plistlib.dump(info, stream)
common = [str(compiler), '-parse-as-library', '-swift-version', '6', '-Osize',
          '-target', 'arm64-apple-macosx26.0', '-sdk', str(sdk),
          '-module-cache-path', str(build/'ModuleCache')]
shared = [str(p) for p in sorted((root/'Shared').glob('*.swift'))]
helper = macos/'ClairRouteHelper'
print('Compiling Helper (not executing it)…', flush=True)
subprocess.run(common + ['-module-name', 'ClairRouteHelper'] + shared +
               [str(p) for p in sorted((root/'Helper').glob('*.swift'))] +
               ['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
                '-Xlinker', str(helper_info), '-o', str(helper)], check=True)
guard = macos/'ClairRouteRecoveryGuard'
print('Compiling independent RecoveryGuard (not executing it)…', flush=True)
subprocess.run(common + ['-module-name', 'ClairRouteRecoveryGuard', '-D', 'CLAIRROUTE_RECOVERY_GUARD'] + shared +
               [str(p) for p in sorted((root/'Helper').glob('*.swift'))] +
               ['-Xlinker', '-sectcreate', '-Xlinker', '__TEXT', '-Xlinker', '__info_plist',
                '-Xlinker', str(guard_info), '-o', str(guard)], check=True)
print('Compiling SwiftUI App (not launching it)…', flush=True)
subprocess.run(common + ['-module-name', 'ClairRoute'] + shared +
               [str(p) for p in sorted((root/'App').glob('*.swift'))] +
               ['-o', str(macos/'ClairRoute')], check=True)
for name in ('mihomo', 'CoreManifest.json', 'mihomo-LICENSE', 'THIRD-PARTY-NOTICES.txt', 'geosite.dat', 'GeoManifest.json', 'AppIcon.icns'):
    shutil.copy2(root/'Resources'/name, resources/name)
shutil.copy2(root/'Resources/local.nano.ClairRoute.Helper.plist', daemons)
shutil.copy2(root/'Resources/local.nano.ClairRoute.RecoveryGuard.plist', daemons)
shutil.copy2(root/'README.md', resources/'README.md')
(resources/'Scripts').mkdir()
for name in ('check-inactive.py', 'check-ready.py', 'install-local.sh', 'uninstall-local.sh', 'Uninstall ClairRoute.command'):
    shutil.copy2(root/'Scripts'/name, resources/'Scripts'/name)
(staging/'Contents/PkgInfo').write_bytes(b'APPL????')
if identity:
    for path, identifier in ((helper, 'local.nano.ClairRoute.Helper'), (guard, 'local.nano.ClairRoute.RecoveryGuard'), (staging, 'local.nano.ClairRoute')):
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none',
                        '--options', 'runtime', '--identifier', identifier, str(path)], check=True)
        requirement = f'identifier "{identifier}" and certificate leaf = H"{identity}"'
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, str(path)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staging)], check=True)
if app.exists():
    shutil.rmtree(app)
staging.rename(app)
print(f'Built: {app}')
print('Signed local build.' if identity else 'UI-only preview: privileged activation is disabled until locally signed.')
print('No service installed, no app/core executed, no network settings changed.')
