#!/bin/bash
# Publishes a release that install.sh picks up:  Scripts/release.sh 1.2.3 "What changed"
# Run on the Mac that holds the release signing identity, from a clean main that matches origin/main.
# It tags the current commit; it never commits or pushes to main.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'usage: Scripts/release.sh X.Y.Z [notes]' >&2; exit 1; }
# Must match IDENTITY in install.sh: installed Helpers only trust Apps signed by this certificate.
IDENTITY=$(sed -n 's/^IDENTITY="\([0-9A-F]\{40\}\)"$/\1/p' install.sh)
[[ -n "$IDENTITY" ]] || { echo 'IDENTITY not found in install.sh.' >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" ||
  { echo "Signing identity $IDENTITY is not in this Keychain." >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || { echo 'Commit or discard your changes first.' >&2; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
  { echo 'HEAD must equal origin/main (merge and pull first).' >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "Tag v$VERSION already exists." >&2; exit 1; }

[[ -f Vendor/mihomo ]] || Scripts/fetch-core.sh
zsh Tests/run.sh
Scripts/build-local.sh "$IDENTITY" --version "$VERSION"
APP=.build/Local/Build/Products/Release/ClairRoute.app
[[ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)" == "$VERSION" ]] ||
  { echo 'Built app has the wrong version.' >&2; exit 1; }
codesign --verify --deep --strict -R="identifier \"local.nano.ClairRoute\" and certificate leaf = H\"$IDENTITY\"" "$APP"

ZIP=.build/release/ClairRoute.zip
mkdir -p .build/release && rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

git tag "v$VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "ClairRoute $VERSION" --notes "$NOTES"
echo "Released ClairRoute $VERSION."
