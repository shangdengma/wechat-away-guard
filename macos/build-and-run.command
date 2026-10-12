#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo '此脚本只能在 Mac 上运行。'; exit 1
fi
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  echo '需要先安装 Apple Command Line Tools。请在终端运行 xcode-select --install，安装后再打开此脚本。'
  read -r -p '按回车结束。' _; exit 1
fi
mkdir -p build
APP="$PWD/build/WeChatGuard.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp source/Info.plist "$APP/Contents/Info.plist"
cp source/guard-core.js "$APP/Contents/Resources/guard-core.js"
# Build for the current Mac architecture; the same source supports arm64 and x86_64.
/usr/bin/xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
  -mmacosx-version-min=12.0 -framework Cocoa -framework CoreBluetooth \
  -framework ApplicationServices -framework JavaScriptCore \
  source/main.m -o "$APP/Contents/MacOS/WeChatGuard"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
echo "已构建：$APP"
if [[ "${1:-}" != --build-only ]]; then /usr/bin/open "$APP"; fi
