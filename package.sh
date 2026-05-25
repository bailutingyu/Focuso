#!/bin/bash
# 打包 Focuso.app 为 zip，供 GitHub Release 上传
set -euo pipefail
cd "$(dirname "$0")"

./build.sh >/dev/null

VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0")
OUT="Focuso-${VER}.zip"
rm -f "$OUT"
# ditto 保留 macOS 资源/签名，比普通 zip 更适合分发 .app
ditto -c -k --keepParent Focuso.app "$OUT"

echo "✅ 打包完成: $(pwd)/$OUT"
echo "   把它作为 asset 上传到 GitHub Release 即可。"
echo "   注意：本 app 是 ad-hoc 签名（未公证），下载者首次打开需「右键 → 打开」绕过 Gatekeeper。"
