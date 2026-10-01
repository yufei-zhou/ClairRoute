#!/bin/zsh
# Explicitly opt-in: unlike run.sh this starts the bundled core in test-only mode.
set -euo pipefail
TASK_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/../../work/clairroute-core-preflight"
mkdir -p "$TASK_BUILD/module-cache" "$TASK_BUILD/runtime"
# Vendor/mihomo is the original official binary, before application-local signing.
/usr/bin/python3 - "$TASK_ROOT" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
checks = [(root / 'Vendor/mihomo', json.loads((root / 'Vendor/Upstream.json').read_text())['originalBinarySHA256']),
          (root / 'Resources/geosite.dat', json.loads((root / 'Resources/GeoManifest.json').read_text())['geositeSHA256'])]
for path, expected in checks:
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('Preflight aborted: bundled asset checksum mismatch')
print('Official core and bundled GEOSITE SHA256 match manifests')
PY
cp "$TASK_ROOT/Resources/geosite.dat" "$TASK_BUILD/runtime/geosite.dat"
xcrun swiftc -swift-version 6 -module-cache-path "$TASK_BUILD/module-cache" \
  "$TASK_ROOT"/Shared/*.swift "$TASK_ROOT/Tests/CorePreflight.swift" -o "$TASK_BUILD/generate-fixture"
# The subprocess runs unprivileged. Drop all CLASH_* and proxy environment overrides.
# stdin contains fake credentials only; config files and provider caches are not written.
"$TASK_BUILD/generate-fixture" | /usr/bin/env -i "$TASK_ROOT/Vendor/mihomo" -t -f - -d "$TASK_BUILD/runtime"
