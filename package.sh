#!/bin/bash
# package.sh — 打 dmg 安装包
#
# 产出文件命名必须和 App 内 Updater 的约定一致：
#   NearbyPass-<version>.dmg
# 否则自动更新会找不到附件。
set -euo pipefail
cd "$(dirname "$0")"

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      .build/NearbyPass.app/Contents/Info.plist)
OUT="NearbyPass-${VER}.dmg"

if [ ! -d .build/NearbyPass.app ]; then
  echo "先跑 ./build.sh"
  exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R .build/NearbyPass.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "NearbyPass $VER" \
  -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT" >/dev/null

# 挂起来自检一遍：能挂载、App 在、签名有效、版本号对
MNT=$(mktemp -d)
hdiutil attach "$OUT" -nobrowse -readonly -mountpoint "$MNT" -quiet >/dev/null
codesign -v --strict "$MNT/NearbyPass.app"
GOT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      "$MNT/NearbyPass.app/Contents/Info.plist")
hdiutil detach "$MNT" -quiet >/dev/null
rmdir "$MNT" 2>/dev/null || true

if [ "$GOT" != "$VER" ]; then
  echo "包内版本号 $GOT ≠ $VER"
  exit 1
fi

echo "==> $OUT  $(du -h "$OUT" | cut -f1)  版本 $VER 签名通过"
