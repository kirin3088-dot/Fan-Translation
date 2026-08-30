#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
SDK="$(/usr/bin/xcrun --show-sdk-path)"
APP="$DIR/SnapTranslate.app"

CERT_NAME="SnapTranslate Dev"
CERTS_DIR="$DIR/certs"
P12="$CERTS_DIR/cert.p12"
P12_PASS="snaptranslate-dev"

# 1. 编译（Apple 芯片，兼容 macOS 13 及以上）
echo "正在编译（Apple 芯片，兼容 macOS 13 及以上）..."
swiftc -O \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -Xlinker -weak_framework -Xlinker Translation \
  -lsqlite3 \
  "$DIR/main.swift" \
  -o "$DIR/SnapTranslate"

# 2. 打包成 App
echo "正在打包..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/SnapTranslate" "$APP/Contents/MacOS/SnapTranslate"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/SnapTranslate"

# 2.5 生成 App 图标
echo "正在生成图标..."
if [ ! -x "$DIR/render_icon" ]; then
  swiftc -O -sdk "$SDK" -target arm64-apple-macosx13.0 "$DIR/render_icon.swift" -o "$DIR/render_icon"
fi
"$DIR/render_icon" "$DIR/icon_1024.png" 2>/dev/null
if [ ! -f "$DIR/icon.icns" ] || [ "$DIR/render_icon.swift" -nt "$DIR/icon.icns" ]; then
  rm -rf "$DIR/icon.iconset" && mkdir "$DIR/icon.iconset"
  for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
    sips -z $(echo $pair | cut -d' ' -f1) $(echo $pair | cut -d' ' -f1) "$DIR/icon_1024.png" --out "$DIR/icon.iconset/icon_$(echo $pair | cut -d' ' -f2).png" >/dev/null
  done
  iconutil -c icns "$DIR/icon.iconset" -o "$DIR/icon.icns" 2>/dev/null
fi
cp "$DIR/icon.icns" "$APP/Contents/Resources/icon.icns"

# 2.6 内置本地英汉词典数据库
if [ -f "$DIR/dict.db" ]; then
  cp "$DIR/dict.db" "$APP/Contents/Resources/dict.db"
  echo "已内置词典：$(du -h "$DIR/dict.db" | cut -f1)"
fi

# 3. 用固定证书签名（保证每次重装后录屏权限不失效）
echo "正在用固定证书签名..."
if ! security find-certificate -c "$CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASS" -T /usr/bin/codesign 2>/dev/null || true
fi
codesign --force -s "$CERT_NAME" "$APP" 2>/dev/null || codesign --force --deep -s - "$APP"

echo "完成：$APP"
