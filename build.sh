#!/bin/bash
# 编译并打包成 MovieShelf.app（原生 AppKit 版本，不依赖 Xcode）
set -euo pipefail
cd "$(dirname "$0")"
# 固定路径：这样系统设置里的「可移除宗卷」授权只授一次就一直有效。
# （同路径重建后 open 可能报 -600，用 open -n 打开即可）
APP="JAVMovie.app"

echo "==> swift build -c release"
swift build -c release

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MovieShelf "$APP/Contents/MacOS/JAVMovie"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>JAVMovie</string>
  <key>CFBundleDisplayName</key><string>JAVMovie 本地影库</string>
  <key>CFBundleIdentifier</key><string>local.javmovie.native</string>
  <key>CFBundleExecutable</key><string>JAVMovie</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict>
</plist>
PLIST

# 复用已有的图标
ICON="AppIcon.icns"          # 图标已随源码放在 native/ 下
if [ -f "$ICON" ]; then cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"; fi

# 优先用固定证书签名（TCC 授权按签名身份记，证书固定 => 重建不掉权限）
IDENTITY="JAVMovie Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 && echo "==> 已用证书签名: $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "==> 已用 ad-hoc 签名（重建会重置磁盘授权）"
fi

echo "==> 完成: $(pwd)/$APP"

# ./build.sh --install  → 顺手装到 /Applications（日常就用那个，路径固定，权限不会丢）
if [ "${1:-}" = "--install" ]; then
  pkill -f "/Applications/JAVMovie.app" 2>/dev/null || true
  sleep 1
  rm -rf /Applications/JAVMovie.app
  cp -R "$APP" /Applications/JAVMovie.app
  if security find-certificate -c "JAVMovie Dev" >/dev/null 2>&1; then
    codesign --force --deep --sign "JAVMovie Dev" /Applications/JAVMovie.app >/dev/null 2>&1 || true
  else
    codesign --force --deep --sign - /Applications/JAVMovie.app >/dev/null 2>&1 || true
  fi
  echo "==> 已安装: /Applications/JAVMovie.app"
fi
