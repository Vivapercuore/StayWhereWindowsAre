#!/bin/bash
# Builds a Release copy of StayWhereWindowsAre and optionally installs it into /Applications.
#
#   scripts/build.sh              # build into build/Release
#   scripts/build.sh --install    # build, quit the running copy, install to /Applications
#   scripts/build.sh --install --open
#
# Signing defaults to ad-hoc. To keep the Accessibility permission across rebuilds, sign with a stable identity:
#   SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" DEVELOPMENT_TEAM=XXXXXXXXXX scripts/build.sh --install
set -euo pipefail
cd "$(dirname "$0")/.."

install=0
open_app=0
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --open) open_app=1 ;;
        *) echo "未知参数：$arg" >&2; exit 1 ;;
    esac
done

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --quiet
fi

signing=(CODE_SIGN_IDENTITY="${SIGN_IDENTITY:--}")
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    signing+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

echo "==> 编译 Release…"
log=build/build.log
mkdir -p build
if ! xcodebuild -project StayWhereWindowsAre.xcodeproj -scheme StayWhereWindowsAre -configuration Release \
    -derivedDataPath build/DerivedData "${signing[@]}" build >"$log" 2>&1; then
    grep -E "error:" "$log" | head -20 >&2 || true
    echo "编译失败，完整日志：$log" >&2
    exit 1
fi

product=build/DerivedData/Build/Products/Release/StayWhereWindowsAre.app
rm -rf build/Release
mkdir -p build/Release
cp -R "$product" build/Release/
echo "==> 已生成 build/Release/StayWhereWindowsAre.app"

target=build/Release/StayWhereWindowsAre.app
if [[ $install == 1 ]]; then
    if pgrep -x StayWhereWindowsAre >/dev/null; then
        echo "==> 退出正在运行的 StayWhereWindowsAre"
        osascript -e 'tell application id "com.vivapercuore.StayWhereWindowsAre" to quit' >/dev/null 2>&1 || true
        sleep 1
        pkill -x StayWhereWindowsAre 2>/dev/null || true
    fi
    rm -rf /Applications/StayWhereWindowsAre.app
    cp -R build/Release/StayWhereWindowsAre.app /Applications/
    target=/Applications/StayWhereWindowsAre.app
    echo "==> 已安装到 /Applications"
    echo "    提示：ad-hoc 签名的 App 每次重新安装后需要在“辅助功能”里重新授权（先移除旧条目再打开开关）。"
fi

if [[ $open_app == 1 ]]; then
    open "$target"
fi
