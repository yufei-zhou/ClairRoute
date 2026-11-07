#!/usr/bin/env python3
"""Build an isolated, synthetic UI fixture without launching it or any service."""
from pathlib import Path
import plistlib
import subprocess

root = Path(__file__).resolve().parent.parent
build = root / '.build/ui-preview'
app = build / 'ClairRoute UI Preview.app'
macos = app / 'Contents/MacOS'
macos.mkdir(parents=True, exist_ok=True)
(build / 'module-cache').mkdir(exist_ok=True)
sources = sorted((root / 'Shared').glob('*.swift'))
sources += sorted(p for p in (root / 'App').glob('*.swift') if p.name != 'ClairRouteApp.swift')
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                '-target', 'arm64-apple-macosx26.0', '-module-cache-path', str(build / 'module-cache'),
                *map(str, sources), str(root / 'Tests/UIHarness.swift'), '-o', str(macos / 'ClairRouteUIPreview')], check=True)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'local.nano.ClairRoute.UIPreview', 'CFBundleName': 'ClairRoute UI Preview',
                  'CFBundleExecutable': 'ClairRouteUIPreview', 'CFBundlePackageType': 'APPL',
                  'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
                  'LSMinimumSystemVersion': '26.0'}, f)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
