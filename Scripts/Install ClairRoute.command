#!/bin/bash
# USER-RUN ONLY. Finder opens this file in Terminal; it is never a build phase.
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

finish() {
  local result=$?
  trap - EXIT INT TERM
  if [[ "$result" != 0 ]]; then
    echo >&2
    echo 'Installation stopped. Read the error above; do not delete recovery journals or maintenance backups.' >&2
    echo 'Any already-created signing identity is retained and can be reused on the next attempt.' >&2
  fi
  if [[ -t 0 && -t 1 ]]; then
    printf '\nPress Return to close this installer. '
    IFS= read -r unused || true
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $(id -u) != 0 ]] || { echo 'Double-click this file as your login user. Do not start it with sudo.' >&2; exit 1; }
[[ -t 0 ]] || { echo 'Run this entry point in Terminal so macOS can request administrator authorization interactively.' >&2; exit 1; }
[[ $(uname -m) == arm64 ]] || { echo 'ClairRoute requires Apple Silicon.' >&2; exit 1; }
VERSION=$(sw_vers -productVersion)
[[ ${VERSION%%.*} -ge 26 ]] || { echo 'ClairRoute requires macOS 26 or later.' >&2; exit 1; }
DEVELOPER=$(/usr/bin/xcode-select -p)
[[ -x "$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" &&
   -d "$DEVELOPER/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]] || {
  echo 'Select a complete Xcode installation in Xcode Settings > Locations > Command Line Tools, then retry.' >&2
  exit 1
}
SDK_VERSION=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
[[ ${SDK_VERSION%%.*} -ge 26 ]] || { echo 'Select Xcode with a macOS 26 or newer SDK, then retry.' >&2; exit 1; }
for name in fetch-core.sh create-local-identity.sh build-local.sh install-local.sh check-inactive.py check-ready.py; do
  [[ -f "$ROOT/Scripts/$name" && ! -L "$ROOT/Scripts/$name" ]] || {
    echo 'Installer resources are missing or replaced by symlinks. Use the original source folder.' >&2; exit 1;
  }
done

echo 'ClairRoute local installation — no Apple Developer membership required.'
echo '1. Create or reuse this account’s local signing identity.'
echo '2. Build and verify App, Helper, RecoveryGuard and the pinned official core.'
echo '3. Request administrator authorization in this Terminal and install idle services.'
echo 'The login Keychain will not be reset or replaced. macOS may show Keychain authorization prompts.'
echo 'No proxy, DNS or TUN mode is enabled by installation. No connectivity tests are run.'
echo 'Quit ClairRoute first if another version is open.'
echo
if [[ ! -f "$ROOT/Vendor/mihomo" ]]; then
  echo 'Downloading the pinned official mihomo core (checksum verified, not executed)…'
  "$ROOT/Scripts/fetch-core.sh"
  echo
fi
IDENTITY=$("$ROOT/Scripts/create-local-identity.sh" --print-hash)
[[ "$IDENTITY" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'Could not obtain an unambiguous signing identity.' >&2; exit 1; }
"$ROOT/Scripts/build-local.sh" "$IDENTITY"
echo
echo 'Build verified. Administrator authorization is now needed only for the fixed installation paths.'
echo 'Enter your macOS login password at the sudo prompt; it is not displayed or stored by this script.'
sudo -- "$ROOT/Scripts/install-local.sh" "$IDENTITY"
echo
echo 'Installed. Open /Applications/ClairRoute.app when ready; all network switches start off.'
echo 'Live proxy and recovery acceptance remains a separate, explicit step.'
