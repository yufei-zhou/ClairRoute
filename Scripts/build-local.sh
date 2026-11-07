#!/bin/bash
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:-}"
[[ "$IDENTITY" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'Usage: Scripts/build-local.sh <40-character signing identity SHA1>' >&2; exit 1; }
[[ $(id -u) != 0 ]] || { echo 'Build as your normal login user, without sudo.' >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || { echo 'This project targets Apple Silicon.' >&2; exit 1; }
LOGIN_HOME=$(/usr/bin/python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
IDENTITIES=$(security find-identity -v -p codesigning "$LOGIN_HOME/Library/Keychains/login.keychain-db")
CLAIRROUTE_IDENTITIES="$IDENTITIES" /usr/bin/python3 - "$IDENTITY" <<'PY'
import os,re,sys
hashes=re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+".*"\s*$',os.environ['CLAIRROUTE_IDENTITIES'],re.MULTILINE)
if sum(item.upper()==sys.argv[1].upper() for item in hashes)!=1:
    raise SystemExit('The specified valid signing identity and private key were not found uniquely in your login Keychain.')
PY
[[ -f "$ROOT/Vendor/mihomo" ]] || "$ROOT/Scripts/fetch-core.sh"
shift
# Extra arguments (e.g. --version X.Y.Z from Scripts/release.sh) go to the native build.
/usr/bin/python3 "$ROOT/Scripts/build-native.py" --identity "$IDENTITY" "$@"
APP="$ROOT/.build/Local/Build/Products/Release/ClairRoute.app"
codesign --verify --deep --strict "$APP"
echo "Built signed application: $APP"
echo 'No Helper was installed and no networking settings were changed.'
