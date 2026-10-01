#!/bin/bash
# USER-RUN ONLY. Creates a local code-signing identity and adds code-signing trust.
# Does not alter TLS trust, install the Helper, or change networking.
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C
[[ $(id -u) != 0 ]] || { echo 'Run as your normal login user, without sudo.' >&2; exit 1; }
PRINT_HASH=0
case "${1:-}" in
  '') ;;
  --print-hash) PRINT_HASH=1 ;;
  *) echo 'Usage: Scripts/create-local-identity.sh [--print-hash]' >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo 'Unexpected arguments.' >&2; exit 1; }
NAME='ClairRoute Local Development'
LOGIN_HOME=$(/usr/bin/python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
KEYCHAIN="$LOGIN_HOME/Library/Keychains/login.keychain-db"
# Never create, replace, reset or unlock an existing login Keychain automatically.
# Keychain Access, security and codesign own all authentication prompts.
/usr/bin/python3 - "$KEYCHAIN" <<'PY'
import os,stat,sys
try: info=os.lstat(sys.argv[1])
except FileNotFoundError:
    raise SystemExit('No login Keychain was found. Open Keychain Access and resolve this before running the installer.')
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
    raise SystemExit('The login Keychain path is not a regular file owned by this account; it was left unchanged.')
PY
usable_identity() {
  local identities
  identities=$(security find-identity -v -p codesigning "$KEYCHAIN") || return 1
  CLAIRROUTE_IDENTITIES="$identities" /usr/bin/python3 - "$NAME" <<'PY'
import os,re,sys
pattern=r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"'+re.escape(sys.argv[1])+r'"\s*$'
matches=re.findall(pattern,os.environ['CLAIRROUTE_IDENTITIES'],re.MULTILINE)
if len(matches)!=1: raise SystemExit(1)
print(matches[0])
PY
}
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  if fingerprint=$(usable_identity); then
    echo 'Reusing the existing valid code-signing identity and private key:' >&2
    printf '%s\n' "$fingerprint"
    exit 0
  fi
  echo 'A same-name certificate exists without one unambiguous valid signing identity.' >&2
  echo 'Inspect its private key, code-signing trust and expiry in Keychain Access. Do not rotate/delete an identity used by an installed Helper.' >&2
  exit 1
fi
umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/clairroute-signing.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/certificate.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = signing
prompt = no
[dn]
CN = ClairRoute Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$TMP/certificate.conf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
# macOS rejects LibreSSL PKCS#12 bundles with an empty password (errSecPkcs12VerifyFailure).
# This random password protects only this disposable transport file, not the login Keychain.
# Keep OpenSSL's password out of argv and pin the system tool/PKCS#12 format.
P12_PASSWORD=$(/usr/bin/openssl rand -hex 32)
printf '%s\n' "$P12_PASSWORD" > "$TMP/p12-password"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/identity.p12" -passout "file:$TMP/p12-password"
/usr/bin/openssl pkcs12 -in "$TMP/identity.p12" -noout \
  -passin "file:$TMP/p12-password"
# security's CLI accepts a passphrase only via -P or a GUI prompt. This is a
# one-use generated transport password, never an account or administrator password.
if ! /usr/bin/security import "$TMP/identity.p12" -f pkcs12 -k "$KEYCHAIN" \
    -P "$P12_PASSWORD" -T /usr/bin/codesign >&2; then
  unset P12_PASSWORD
  echo 'The generated signing identity could not be imported. No service installation was attempted; the login password was not changed.' >&2
  exit 1
fi
unset P12_PASSWORD
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >&2
echo 'Created local code-signing identity in the existing login Keychain.' >&2
if [[ "$PRINT_HASH" == 0 ]]; then
  echo 'Save the 40-character identity hash below for build-local.sh:' >&2
fi
if fingerprint=$(usable_identity); then
  printf '%s\n' "$fingerprint"
else
  echo 'The certificate was imported, but a valid signing identity could not be verified. Check its private key and code-signing trust in Keychain Access.' >&2
  exit 1
fi
