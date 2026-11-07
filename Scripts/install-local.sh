#!/bin/bash
# Explicit manual installation; never called by an Xcode build phase.
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:-}"
[[ $(id -u) == 0 ]] || { echo 'Run with sudo after reviewing README.' >&2; exit 1; }
[[ "$IDENTITY" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'Usage: sudo Scripts/install-local.sh <identity SHA1> [signed ClairRoute.app]' >&2; exit 1; }
# The one-line installer passes a downloaded release; a source checkout installs its own build.
SOURCE="${2:-$ROOT/.build/Local/Build/Products/Release/ClairRoute.app}"
TARGET='/Applications/ClairRoute.app'
SUPPORT='/Library/Application Support/ClairRoute'
DAEMON='/Library/LaunchDaemons/local.nano.ClairRoute.Helper.plist'
SERVICE='system/local.nano.ClairRoute.Helper'
GUARD_DAEMON='/Library/LaunchDaemons/local.nano.ClairRoute.RecoveryGuard.plist'
GUARD_SERVICE='system/local.nano.ClairRoute.RecoveryGuard'
TRANSACTION="$SUPPORT/.maintenance"
REQ="identifier \"local.nano.ClairRoute\" and certificate leaf = H\"${IDENTITY}\""
[[ -d "$SOURCE" && ! -L "$SOURCE" ]] || { echo 'Build the signed Release app first.' >&2; exit 1; }
codesign --verify --deep --strict -R "=$REQ" "$SOURCE"
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
[[ ! -e "$TRANSACTION" && ! -L "$TRANSACTION" ]] || {
  echo 'An earlier maintenance transaction remains. Its backups were preserved; recover it before reinstalling.' >&2; exit 1;
}
if [[ -e "$TARGET" ]]; then
  codesign --verify --strict -R '=identifier "local.nano.ClairRoute"' "$TARGET"
fi
install -d -o root -g wheel -m 755 "$SUPPORT" "$SUPPORT/bin"
install -d -o root -g wheel -m 700 "$SUPPORT/state" "$SUPPORT/run"
# mkdir is the mutual-exclusion operation shared with uninstall-local.sh.
mkdir -m 700 "$TRANSACTION"
STAGE="$TRANSACTION/stage"
BACKUP="$TRANSACTION/backup"
# Nothing has been changed yet; do not leave a lock that blocks every later install.
mkdir -m 700 "$STAGE" "$BACKUP" || { rm -rf "$TRANSACTION"; exit 1; }
OLD_LOADED=0
OLD_GUARD_LOADED=0
STOPPED_OLD=0
MUTATED=0
COMMITTED=0
TARGETS=("$TARGET" "$SUPPORT/bin/mihomo" "$SUPPORT/CoreManifest.json" "$DAEMON" "$GUARD_DAEMON" "$SUPPORT/state/geosite.dat" "$SUPPORT/GeoManifest.json")
NAMES=('ClairRoute.app' 'mihomo' 'CoreManifest.json' 'daemon.plist' 'guard.plist' 'geosite.dat' 'GeoManifest.json')
EXISTED=(0 0 0 0 0 0 0)

# 0 = loaded, 1 = absent, 2 = inspection failed. Do not hide launchctl failures.
service_loaded() {
  local output service="${1:-$SERVICE}"
  if output=$(launchctl print "$service" 2>&1); then return 0; fi
  if [[ "$output" == *'Could not find service'* ]]; then return 1; fi
  printf '%s\n' "$output" >&2
  return 2
}

stop_daemon() {
  local result service="${1:-$SERVICE}"
  if service_loaded "$service"; then
    launchctl bootout "$service" || return 1
  else
    result=$?
    [[ "$result" == 1 ]] || return 1
    return 0
  fi
  for ((attempt=0; attempt<30; attempt++)); do
    if service_loaded "$service"; then sleep 0.1; else
      result=$?
      [[ "$result" == 1 ]] && return 0
      return 1
    fi
  done
  echo 'The Helper did not stop; preserving installation resources.' >&2
  return 1
}

write_record() {
  /usr/bin/python3 - "$TRANSACTION" "$1" "$OLD_LOADED" "$OLD_GUARD_LOADED" "${EXISTED[@]}" <<'PY'
from pathlib import Path
import json,os,sys
p=Path(sys.argv[1]); temp=p/'record.next'
d={'version':1,'operation':'install','phase':sys.argv[2],'oldDaemonLoaded':sys.argv[3]=='1','oldGuardLoaded':sys.argv[4]=='1',
   'previousPaths':dict(zip(['ClairRoute.app','mihomo','CoreManifest.json','daemon.plist','guard.plist','geosite.dat','GeoManifest.json'],[v=='1' for v in sys.argv[5:]]))}
with temp.open('xb') as f:
    f.write((json.dumps(d,indent=2)+'\n').encode()); f.flush(); os.fsync(f.fileno())
os.replace(temp,p/'record.json')
fd=os.open(p,os.O_RDONLY); os.fsync(fd); os.close(fd)
PY
}

rollback() {
  echo 'Installation failed. Attempting to restore the previous installation.' >&2
  # A GUI may have reopened. Never stop/delete newly active networking blindly.
  /usr/bin/python3 "$ROOT/Scripts/check-inactive.py" || return 1
  stop_daemon || return 1
  stop_daemon "$GUARD_SERVICE" || return 1
  /usr/bin/python3 "$ROOT/Scripts/check-inactive.py" || return 1
  if [[ "$MUTATED" == 1 ]]; then
    for index in "${!TARGETS[@]}"; do
      if [[ "${EXISTED[$index]}" == 1 ]]; then
        [[ -e "$BACKUP/${NAMES[$index]}" ]] || return 1
        if [[ "$index" == 0 ]]; then
          [[ ! -L "$TARGET" ]] || return 1
          if [[ -e "$TARGET" ]]; then mv "$TARGET" "$TRANSACTION/failed-new.app" || return 1; fi
          ditto "$BACKUP/${NAMES[$index]}" "$TARGET" || return 1
        else
          install -o root -g wheel -m "$([[ "$index" == 1 ]] && echo 755 || echo 644)" \
            "$BACKUP/${NAMES[$index]}" "${TARGETS[$index]}" || return 1
        fi
      else
        if [[ "$index" == 0 ]]; then
          [[ ! -L "$TARGET" ]] || return 1
          if [[ -e "$TARGET" ]]; then mv "$TARGET" "$TRANSACTION/failed-new.app" || return 1; fi
        else
          rm -f "${TARGETS[$index]}" || return 1
        fi
      fi
    done
  fi
  if [[ "$OLD_GUARD_LOADED" == 1 && "$STOPPED_OLD" == 1 ]]; then
    launchctl bootstrap system "$GUARD_DAEMON" || return 1
  fi
  if [[ "$OLD_LOADED" == 1 && "$STOPPED_OLD" == 1 ]]; then
    launchctl bootstrap system "$DAEMON" || return 1
  fi
  write_record rolled-back || return 1
  echo 'The previous installation was restored.' >&2
}

finish() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$COMMITTED" == 1 ]]; then
    rm -rf "$TRANSACTION"
  elif [[ "$MUTATED" == 1 || "$STOPPED_OLD" == 1 ]]; then
    if rollback; then
      rm -rf "$TRANSACTION"
    else
      echo "Automatic rollback is incomplete. Preserve $TRANSACTION and its backup directory; do not delete recovery records." >&2
    fi
  else
    rm -rf "$TRANSACTION"
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
write_record staging
ditto "$SOURCE" "$STAGE/ClairRoute.app"
chown -R root:wheel "$STAGE/ClairRoute.app"
chmod -RN "$STAGE/ClairRoute.app"
chmod -R go-w "$STAGE/ClairRoute.app"
codesign --verify --deep --strict -R "=$REQ" "$STAGE/ClairRoute.app"
install -m 755 "$STAGE/ClairRoute.app/Contents/Resources/mihomo" "$STAGE/mihomo"
install -m 644 "$STAGE/ClairRoute.app/Contents/Resources/CoreManifest.json" "$STAGE/CoreManifest.json"
install -m 644 "$STAGE/ClairRoute.app/Contents/Resources/geosite.dat" "$STAGE/geosite.dat"
install -m 644 "$STAGE/ClairRoute.app/Contents/Resources/GeoManifest.json" "$STAGE/GeoManifest.json"
/usr/bin/python3 - "$STAGE" "$TARGET" <<'PY'
from pathlib import Path
import hashlib,json,os,plistlib,subprocess,sys
stage=Path(sys.argv[1]); app=stage/'ClairRoute.app'; target=Path(sys.argv[2])
manifest=json.loads((stage/'CoreManifest.json').read_bytes())
if hashlib.sha256((stage/'mihomo').read_bytes()).hexdigest()!=manifest['binarySHA256']:
    raise SystemExit('The signed core does not match its bundled manifest.')
subprocess.run(['/usr/bin/codesign','--verify','--strict','-R','='+manifest['signingRequirement'],str(stage/'mihomo')],check=True)
geo=json.loads((stage/'GeoManifest.json').read_bytes())
if geo.get('version')!=1 or hashlib.sha256((stage/'geosite.dat').read_bytes()).hexdigest()!=geo.get('geositeSHA256'):
    raise SystemExit('Geosite data does not match the signed Geo manifest.')
d=plistlib.loads((app/'Contents/Library/LaunchDaemons/local.nano.ClairRoute.Helper.plist').read_bytes())
if d.get('Label')!='local.nano.ClairRoute.Helper': raise SystemExit('Unexpected daemon label.')
d.pop('BundleProgram',None)
d['ProgramArguments']=[str(target/'Contents/MacOS/ClairRouteHelper')]
d['StandardOutPath']='/dev/null'; d['StandardErrorPath']='/Library/Application Support/ClairRoute/state/helper.log'
with (stage/'daemon.plist').open('xb') as f:
    f.write(plistlib.dumps(d)); f.flush(); os.fsync(f.fileno())
g=plistlib.loads((app/'Contents/Library/LaunchDaemons/local.nano.ClairRoute.RecoveryGuard.plist').read_bytes())
if g.get('Label')!='local.nano.ClairRoute.RecoveryGuard': raise SystemExit('Unexpected RecoveryGuard label.')
g.pop('BundleProgram',None)
g['ProgramArguments']=[str(target/'Contents/MacOS/ClairRouteRecoveryGuard')]
g['StandardOutPath']='/dev/null'; g['StandardErrorPath']='/Library/Application Support/ClairRoute/state/recovery-guard.log'
with (stage/'guard.plist').open('xb') as f:
    f.write(plistlib.dumps(g)); f.flush(); os.fsync(f.fileno())
PY
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
for index in "${!TARGETS[@]}"; do
  if [[ -e "${TARGETS[$index]}" ]]; then
    EXISTED[$index]=1
    ditto "${TARGETS[$index]}" "$BACKUP/${NAMES[$index]}"
  fi
done
if service_loaded; then
  OLD_LOADED=1
else
  result=$?
  [[ "$result" == 1 ]] || exit 1
fi
if service_loaded "$GUARD_SERVICE"; then
  OLD_GUARD_LOADED=1
else
  result=$?
  [[ "$result" == 1 ]] || exit 1
fi
write_record prepared
# Intent precedes bootout: interruption immediately after stopping still causes recovery.
STOPPED_OLD=1
stop_daemon
stop_daemon "$GUARD_SERVICE"
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
write_record replacing
MUTATED=1
if [[ -e "$TARGET" ]]; then mv "$TARGET" "$TRANSACTION/displaced.app"; fi
mv "$STAGE/ClairRoute.app" "$TARGET"
mv "$STAGE/mihomo" "$SUPPORT/bin/mihomo"
mv "$STAGE/CoreManifest.json" "$SUPPORT/CoreManifest.json"
install -o root -g wheel -m 644 "$STAGE/daemon.plist" "$DAEMON"
install -o root -g wheel -m 644 "$STAGE/guard.plist" "$GUARD_DAEMON"
mv "$STAGE/geosite.dat" "$SUPPORT/state/geosite.dat"
mv "$STAGE/GeoManifest.json" "$SUPPORT/GeoManifest.json"
touch "$SUPPORT/state/helper.log"
chown root:wheel "$SUPPORT/state/helper.log"
chmod 600 "$SUPPORT/state/helper.log"
touch "$SUPPORT/state/recovery-guard.log"
chown root:wheel "$SUPPORT/state/recovery-guard.log"
chmod 600 "$SUPPORT/state/recovery-guard.log"
codesign --verify --deep --strict -R "=$REQ" "$TARGET"
write_record bootstrapping
launchctl bootstrap system "$GUARD_DAEMON"
service_loaded "$GUARD_SERVICE"
launchctl bootstrap system "$DAEMON"
service_loaded
# A loaded launchd job may have crashed or failed initialization. Only commit after
# both fixed root processes publish fresh, process-bound readiness information.
ready=0
for ((attempt=0; attempt<30; attempt++)); do
  if /usr/bin/python3 "$ROOT/Scripts/check-ready.py" >"$TRANSACTION/readiness.log" 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
if [[ "$ready" != 1 ]]; then
  cat "$TRANSACTION/readiness.log" >&2
  echo 'The installed services did not become ready. Rolling back this installation.' >&2
  exit 1
fi
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
write_record committed
COMMITTED=1
echo 'Installed ClairRoute and its local development Helper. No proxy/TUN mode was enabled.'
echo 'Open /Applications/ClairRoute.app and explicitly enable a mode only when ready.'
