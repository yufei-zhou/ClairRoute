#!/bin/bash
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $(id -u) == 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || {
  echo 'Run using sudo from the original login account, after restoring and quitting ClairRoute.' >&2; exit 1;
}
SUPPORT='/Library/Application Support/ClairRoute'
TARGET='/Applications/ClairRoute.app'
DAEMON='/Library/LaunchDaemons/local.nano.ClairRoute.Helper.plist'
SERVICE='system/local.nano.ClairRoute.Helper'
GUARD_SERVICE='system/local.nano.ClairRoute.RecoveryGuard'
GUARD_DAEMON='/Library/LaunchDaemons/local.nano.ClairRoute.RecoveryGuard.plist'
TRANSACTION="$SUPPORT/.maintenance"
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
[[ ! -e "$TRANSACTION" && ! -L "$TRANSACTION" ]] || {
  echo 'An unfinished maintenance transaction remains. Preserve its backups and recover it before uninstalling.' >&2; exit 1;
}
if [[ -e "$TARGET" ]]; then
  codesign --verify --strict -R '=identifier "local.nano.ClairRoute"' "$TARGET"
fi

# User configuration and legacy Keychain cleanup belong to the original user.
# Resolve home from passwd, never inherited HOME.
user_profile() {
  sudo -H -u "$SUDO_USER" /usr/bin/python3 - "$SUDO_USER" "$1" <<'PY'
from pathlib import Path
import json,os,pwd,shutil,stat,sys
account=pwd.getpwnam(sys.argv[1])
if account.pw_uid != os.geteuid() or account.pw_uid == 0: raise SystemExit('Incorrect account for user-data cleanup.')
directory=Path(account.pw_dir)/'Library/Application Support/ClairRoute'
for path in [directory.parent.parent,directory.parent,directory]:
    if path.is_symlink(): raise SystemExit('A user configuration directory is a symlink; it was preserved.')
profile=directory/'profile.json'
try: info=profile.lstat()
except FileNotFoundError: info=None
if info:
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != account.pw_uid:
        raise SystemExit('Saved profile has unsafe ownership/type; it was preserved.')
    try:
        if info.st_size > 32 * 1_048_576: raise ValueError('oversized profile')
        document=json.loads(profile.read_bytes())
        if not isinstance(document,dict): raise ValueError('invalid profile')
        version=document.get('version')
        if version is not None and (type(version) is not int or version not in (1,2,3)):
            raise ValueError('unsupported profile version')
        pending=document.get('pendingSecretIDs',[])
        nodes=document.get('nodes',[])
        subscriptions=document.get('subscriptions',[])
        node_secrets=document.get('nodeSecrets',{})
        subscription_secrets=document.get('subscriptionSecrets',{})
        if not isinstance(nodes,list) or not isinstance(subscriptions,list): raise ValueError('invalid library metadata')
        if not isinstance(pending,list): raise ValueError('invalid pending-secret list')
        if not isinstance(node_secrets,dict) or not isinstance(subscription_secrets,dict):
            raise ValueError('invalid saved credentials')
    except Exception:
        raise SystemExit('Cannot inspect saved profile. Recover the configuration and any legacy credentials before uninstalling.')
    if (document.get('node') is not None or nodes or subscriptions or node_secrets or subscription_secrets
            or document.get('legacyProfile') is not None):
        raise SystemExit('Clear all saved nodes/subscriptions and credentials in ClairRoute before quitting and retrying uninstall.')
    if pending:
        raise SystemExit('Legacy Keychain deletion remains pending. Retry legacy credential cleanup in ClairRoute, then quit and retry.')
if sys.argv[2]=='delete' and directory.exists(): shutil.rmtree(directory)
PY
}
user_profile check
install -d -o root -g wheel -m 755 "$SUPPORT"
mkdir -m 700 "$TRANSACTION"
OLD_LOADED=0
OLD_GUARD_LOADED=0
STOPPED_OLD=0
MOVED_APP=0
MOVED_DAEMON=0
MOVED_GUARD=0
COMMITTED=0

service_loaded() {
  local output service="${1:-$SERVICE}"
  if output=$(launchctl print "$service" 2>&1); then return 0; fi
  if [[ "$output" == *'Could not find service'* ]]; then return 1; fi
  printf '%s\n' "$output" >&2
  return 2
}

finish() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$COMMITTED" != 1 ]]; then
    local safe=1
    /usr/bin/python3 "$ROOT/Scripts/check-inactive.py" || safe=0
    if [[ "$safe" == 1 ]]; then
      if [[ "$MOVED_APP" == 1 ]]; then
        if [[ -e "$TRANSACTION/removed.app" ]]; then
          [[ ! -e "$TARGET" && ! -L "$TARGET" ]] && mv "$TRANSACTION/removed.app" "$TARGET" || safe=0
        elif [[ ! -e "$TARGET" ]]; then safe=0; fi
      fi
      if [[ "$MOVED_DAEMON" == 1 ]]; then
        if [[ -e "$TRANSACTION/removed.plist" ]]; then
          [[ ! -e "$DAEMON" && ! -L "$DAEMON" ]] && mv "$TRANSACTION/removed.plist" "$DAEMON" || safe=0
        elif [[ ! -e "$DAEMON" ]]; then safe=0; fi
      fi
      if [[ "$MOVED_GUARD" == 1 ]]; then
        if [[ -e "$TRANSACTION/removed-guard.plist" ]]; then
          [[ ! -e "$GUARD_DAEMON" && ! -L "$GUARD_DAEMON" ]] && mv "$TRANSACTION/removed-guard.plist" "$GUARD_DAEMON" || safe=0
        elif [[ ! -e "$GUARD_DAEMON" ]]; then safe=0; fi
      fi
      if [[ "$safe" == 1 && "$OLD_GUARD_LOADED" == 1 && "$STOPPED_OLD" == 1 ]]; then
        if service_loaded "$GUARD_SERVICE"; then :; else
          local result=$?
          if [[ "$result" == 1 ]]; then launchctl bootstrap system "$GUARD_DAEMON" || safe=0; else safe=0; fi
        fi
      fi
      if [[ "$safe" == 1 && "$OLD_LOADED" == 1 && "$STOPPED_OLD" == 1 ]]; then
        if service_loaded; then :; else
          local result=$?
          if [[ "$result" == 1 ]]; then launchctl bootstrap system "$DAEMON" || safe=0; else safe=0; fi
        fi
      fi
    fi
    if [[ "$safe" == 1 ]]; then
      rm -rf "$TRANSACTION"
    else
      echo "Uninstall did not finish. Preserve $TRANSACTION and its recovery materials." >&2
    fi
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/python3 - "$TRANSACTION/record.json" <<'PY'
import json,os,sys
with open(sys.argv[1],'x') as f:
    json.dump({'version':1,'operation':'uninstall','phase':'preparing'},f)
    f.flush(); os.fsync(f.fileno())
PY
STOPPED_OLD=1
# The Helper restores first; stop its independent guard only after the Helper exits.
for service in "$SERVICE" "$GUARD_SERVICE"; do
  if service_loaded "$service"; then
    if [[ "$service" == "$SERVICE" ]]; then OLD_LOADED=1; else OLD_GUARD_LOADED=1; fi
    launchctl bootout "$service"
  else
    result=$?
    [[ "$result" == 1 ]] || exit 1
  fi
  stopped=0
  for ((attempt=0; attempt<30; attempt++)); do
    if service_loaded "$service"; then sleep 0.1; else
      result=$?
      [[ "$result" == 1 ]] || exit 1
      stopped=1
      break
    fi
  done
  [[ "$stopped" == 1 ]] || { echo 'A daemon did not stop; resources were preserved.' >&2; exit 1; }
done
# A failed shutdown may leave a journal even when launchctl reports the daemon absent.
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
user_profile delete
/usr/bin/python3 "$ROOT/Scripts/check-inactive.py"
if [[ -e "$TARGET" ]]; then
  MOVED_APP=1
  mv "$TARGET" "$TRANSACTION/removed.app"
fi
if [[ -e "$DAEMON" ]]; then
  MOVED_DAEMON=1
  mv "$DAEMON" "$TRANSACTION/removed.plist"
fi
if [[ -e "$GUARD_DAEMON" ]]; then
  MOVED_GUARD=1
  mv "$GUARD_DAEMON" "$TRANSACTION/removed-guard.plist"
fi
# Both daemons are stopped and all recovery journals are clean/absent. Only our fixed tree is removed.
rm -rf "$SUPPORT"
COMMITTED=1
echo 'Removed ClairRoute app, local LaunchDaemon, Helper/core and application data.'
echo 'The reusable local signing certificate is retained in Keychain intentionally.'
