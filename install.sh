#!/bin/bash
# Installs ClairRoute, or updates it to the latest release:
#   curl -fsSL https://raw.githubusercontent.com/yufei-zhou/ClairRoute/main/install.sh | bash
set -euo pipefail
export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LC_ALL=C

REPO="yufei-zhou/ClairRoute"
ASSET="ClairRoute.zip"
TARGET="/Applications/ClairRoute.app"
# Every release is signed with this one certificate. A download signed any other way is refused;
# the Helper inside the release only accepts an App signed with the same certificate.
IDENTITY="7B929ABDBAE42F2F2A63141DEE5E4B223C127742"
REQUIREMENT="identifier \"local.nano.ClairRoute\" and certificate leaf = H\"$IDENTITY\""

fail() { echo "$1" >&2; exit 1; }
[[ $(id -u) != 0 ]] || fail "请用普通用户运行这行命令，不要加 sudo。"
[[ $(uname -m) == arm64 ]] || fail "ClairRoute 只支持 Apple Silicon Mac。"
os=$(sw_vers -productVersion)
[[ ${os%%.*} -ge 26 ]] || fail "ClairRoute 需要 macOS 26 或更新版本。"

# /releases/latest redirects to the newest release's tag.
latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
tag="${latest_url##*/}"
version="${tag#v}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "找不到可用的版本。"

installed=""
if [[ -d "$TARGET" ]]; then
  installed=$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
fi
if [[ "$installed" == "$version" ]] && codesign --verify --strict -R="$REQUIREMENT" "$TARGET" 2>/dev/null; then
  echo "ClairRoute 已是最新版本（$version）。"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "正在下载 ClairRoute $version…"
curl -fsSL -o "$tmp/$ASSET" "https://github.com/$REPO/releases/download/$tag/$ASSET"
ditto -x -k "$tmp/$ASSET" "$tmp"
APP="$tmp/ClairRoute.app"
codesign --verify --deep --strict -R="$REQUIREMENT" "$APP" 2>/dev/null || fail "签名校验失败，已取消安装。"

# Quitting through the App restores DNS / proxy settings before it exits.
if pgrep -x ClairRoute >/dev/null; then
  echo "正在退出 ClairRoute 并恢复网络…"
  osascript -e 'tell application id "local.nano.ClairRoute" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do pgrep -x ClairRoute >/dev/null || break; sleep 0.5; done
  pgrep -x ClairRoute >/dev/null && fail "ClairRoute 没有退出。请在 App 里点「恢复网络并关闭代理」，按 Cmd+Q 退出后重试。"
fi

echo "接下来安装后台服务，需要输入这台 Mac 的登录密码（输入时不会显示）。"
# The installer runs from inside the verified, sealed bundle rather than from this download.
sudo -- "$APP/Contents/Resources/Scripts/install-local.sh" "$IDENTITY" "$APP"

if [[ -n "$installed" ]]; then
  echo "已从 $installed 更新到 $version。"
else
  echo "已安装 ClairRoute $version。代理默认关闭，在 App 里手动开启。"
fi
if [[ "${NO_LAUNCH:-}" != 1 ]]; then
  open "$TARGET"
fi
