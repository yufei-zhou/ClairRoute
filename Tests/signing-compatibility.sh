#!/bin/bash
# No user keychain, trust, service, subscription or network mutations.
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/clairroute-signing-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
DEVELOPER=$(/usr/bin/xcode-select -p)
"$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" \
  -isysroot "$DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
  -Wno-deprecated-declarations "$ROOT/Tests/SigningImportProbe.c" \
  -framework Security -framework CoreFoundation -o "$TEST_DIR/probe"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=ClairRoute Disposable Import Probe' \
  -keyout "$TEST_DIR/key.pem" -out "$TEST_DIR/cert.pem" 2>/dev/null
: > "$TEST_DIR/empty"
/usr/bin/openssl rand -hex 32 | tr -d '\n' > "$TEST_DIR/random"
for password in empty random; do
  pass_source="file:$TEST_DIR/$password"
  if [[ "$password" == empty ]]; then pass_source='pass:'; fi
  /usr/bin/openssl pkcs12 -export -inkey "$TEST_DIR/key.pem" -in "$TEST_DIR/cert.pem" \
    -name 'ClairRoute Disposable Import Probe' -out "$TEST_DIR/identity.p12" \
    -passout "$pass_source"
  for format in inferred explicit; do
    printf '%s password / %s format: ' "$password" "$format"
    if "$TEST_DIR/probe" "$TEST_DIR/identity.p12" "$TEST_DIR/$password" "$format"; then
      result=0
    else
      result=$?
    fi
    if [[ "$password" == random && "$format" == explicit && "$result" != 0 ]]; then
      echo 'Required import combination failed.' >&2; exit 1
    fi
  done
done
echo 'PASS: explicit PKCS12 import with a non-empty password; no keychain writes.'
