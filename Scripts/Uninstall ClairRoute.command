#!/bin/bash
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin'
ROOT="$(cd "$(dirname "$0")" && pwd)"
echo 'ClairRoute will remove its installed app and system components after network recovery.'
echo 'The signing certificate will be retained. Administrator authorization follows.'
for ((attempt=0; attempt<60; attempt++)); do
  if ! pgrep -x ClairRoute >/dev/null; then break; fi
  sleep 1
done
sudo "$ROOT/uninstall-local.sh"
echo 'Uninstall finished. You may close this terminal window.'
