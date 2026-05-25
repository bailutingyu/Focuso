#!/bin/bash
# 构建 Focuso.app —— 录屏 + 出镜摄像头 + 自动剪辑
set -euo pipefail
cd "$(dirname "$0")"

APP="Focuso"
BUNDLE="$APP.app"
CONTENTS="$BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

echo "→ 清理旧产物"
rm -rf "$BUNDLE"
mkdir -p "$MACOS" "$RES"

echo "→ 编译 Swift"
swiftc -O \
  -framework Cocoa \
  -framework AVFoundation \
  -framework AVKit \
  -framework CoreMedia \
  -framework CoreImage \
  -framework QuartzCore \
  -framework ScreenCaptureKit \
  -o "$MACOS/$APP" \
  main.swift MouseTracker.swift ZoomProject.swift ZoomCompositor.swift EditorWindow.swift RegionSelector.swift

echo "→ 写入 Info.plist"
cp Info.plist "$CONTENTS/Info.plist"

echo "→ 生成 App 图标"
if [ -f assets/appicon-1024.png ]; then
  ICONSET="AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s assets/appicon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d assets/appicon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "  (跳过：未找到 assets/appicon-1024.png)"
fi

echo "→ ad-hoc 代码签名（不带 hardened runtime，避免摄像头 TCC 被拦）"
codesign --force --deep --sign - "$BUNDLE"

echo ""
echo "✅ 完成: $(pwd)/$BUNDLE"
echo ""
echo "使用方式:"
echo "  双击运行:   open \"$BUNDLE\""
echo "  命令行运行: \"$MACOS/$APP\""
echo ""
echo "首次运行会请求摄像头权限。允许后即可看到右下角的圆形浮窗。"
echo "操作: 拖动 = 鼠标左键拖；缩放 = 滚轮；切设备/退出 = 右键。"
