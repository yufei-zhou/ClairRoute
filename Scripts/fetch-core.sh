#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=1.19.31
EXPECTED=d131f44b3deb2a8356f7ac75048ad67a10d53243323951c4f3cda7b672922963
URL="https://github.com/MetaCubeX/mihomo/releases/download/v${VERSION}/mihomo-darwin-arm64-v${VERSION}.gz"
mkdir -p "$ROOT/Vendor"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/clairroute-core.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 "$URL" -o "$TMP/core.gz"
ACTUAL="$(shasum -a 256 "$TMP/core.gz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Official archive digest mismatch; refusing core.' >&2; exit 1; }
gzip -dc "$TMP/core.gz" > "$TMP/mihomo"
chmod 755 "$TMP/mihomo"
mv "$TMP/mihomo" "$ROOT/Vendor/mihomo"
/usr/bin/python3 - "$ROOT" "$VERSION" "$EXPECTED" <<'PY'
from pathlib import Path
import hashlib, json, sys
p=Path(sys.argv[1]); core=p/'Vendor/mihomo'
d={'version':sys.argv[2], 'archiveSHA256':sys.argv[3],
   'originalBinarySHA256':hashlib.sha256(core.read_bytes()).hexdigest(),
   'source':'https://github.com/MetaCubeX/mihomo/tree/v'+sys.argv[2]}
(p/'Vendor/Upstream.json').write_text(json.dumps(d,indent=2)+'\n')
print('Verified upstream archive. Core downloaded; NOT executed.')
PY
