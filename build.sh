#!/bin/bash
# NearbyPass 构建脚本
#   ./build.sh            编译 + 组装 .app
#   ./build.sh --install  编译 + 安装到 /Applications
#   ./build.sh --run      编译 + 安装 + 启动
#
# 背景：本机 SwiftPM 不可用（sandbox-exec: sandbox_apply: Operation not permitted），
#       因此用 swiftc 直接编译、手工组装 bundle、ad-hoc 签名。

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1

APP="NearbyPass"
BID="com.lcg.nearbypass"
VER="1.0.2"
BUILD="$ROOT/.build"
CACHE="$ROOT/.cache"
OUT="$BUILD/$APP.app"
MIN_OS="14.0"
ARCH="arm64"

mkdir -p "$BUILD" "$CACHE"

export SWIFT_MODULE_CACHE_PATH="$CACHE"
export CLANG_MODULE_CACHE_PATH="$CACHE"

SRC=()
for f in Sources/*.swift; do [ -e "$f" ] && SRC+=("$f"); done
if [ ${#SRC[@]} -eq 0 ]; then
  echo "错误: Sources/ 下没有 .swift 文件" >&2
  exit 1
fi

# ---------- 1. 编译 ----------
echo "==> 编译 ${#SRC[@]} 个源文件 (${ARCH}-apple-macos${MIN_OS})"
ERR="$BUILD/swiftc.err"
swiftc -O -whole-module-optimization \
  -target "${ARCH}-apple-macos${MIN_OS}" -swift-version 5 \
  -framework CoreBluetooth -framework AppKit -framework ApplicationServices \
  -framework Security -framework Foundation -framework CoreGraphics \
  -framework IOKit -framework ServiceManagement \
  -o "$BUILD/$APP.bin" \
  "${SRC[@]}" 2>"$ERR"
RC=$?
# swiftc 每次都会打印两行沙盒警告，不属于真实错误
grep -v 'sandbox-exec: sandbox_apply' "$ERR" >&2 || true
if [ $RC -ne 0 ]; then
  echo "!! 编译失败 (exit $RC)" >&2
  exit $RC
fi

# ---------- 2. 组装 bundle ----------
echo "==> 组装 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BUILD/$APP.bin" "$OUT/Contents/MacOS/$APP"
chmod +x "$OUT/Contents/MacOS/$APP"

# 应用图标
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
else
  echo "警告: 缺少 Resources/AppIcon.icns（图标不会显示）"
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP}</string>
  <key>CFBundleDisplayName</key><string>${APP}</string>
  <key>CFBundleIdentifier</key><string>${BID}</string>
  <key>CFBundleExecutable</key><string>${APP}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>NearbyPass 需要蓝牙来检测你的手机或手环是否在附近，以决定何时自动解锁或锁屏。</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>NearbyPass 需要蓝牙来检测你的手机或手环是否在附近。</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>NearbyPass 使用系统事件执行锁屏操作。</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$OUT/Contents/PkgInfo"

# ---------- 3. 签名 ----------
# 关键：用固定的自签名证书签名时，designated requirement 是
#   identifier "com.lcg.nearbypass" and certificate leaf = H"..."
# 它和二进制内容（cdhash）无关，所以重新编译后 TCC 的辅助功能授权依然有效。
# 若退回 ad-hoc 签名，requirement 变成 cdhash，每次编译都要重新授权。
KEYCHAIN="$ROOT/.signing/np.keychain"
SIGN_ID="NearbyPass Dev"
KC_PASS="npdev"

if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "==> 签名（固定身份：${SIGN_ID}）"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1
  codesign --force --deep --keychain "$KEYCHAIN" --sign "$SIGN_ID" --identifier "$BID" "$OUT" 2>&1 | sed 's/^/    /'
else
  echo "==> ad-hoc 签名（缺 .signing/np.keychain → 每次编译后都要重新授权辅助功能）"
  codesign --force --deep --sign - --identifier "$BID" "$OUT" 2>&1 | sed 's/^/    /'
fi

# ---------- 4. 报告签名身份 ----------
echo "==> Authority: $(codesign -dv "$OUT" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
echo "    requirement: $(codesign -d -r- "$OUT" 2>&1 | awk '/designated =>/{sub(/^.*designated => /,"");print}')"

# ---------- 5. 可选安装/启动 ----------
if [ "${1:-}" = "--install" ] || [ "${1:-}" = "--run" ]; then
  echo "==> 安装到 /Applications/$APP.app"
  rm -rf "/Applications/$APP.app" 2>/dev/null
  if ditto "$OUT" "/Applications/$APP.app" 2>/dev/null; then
    echo "    已安装"
  else
    echo "    ⚠️  自动安装被拦截，请手动把下面这个拖到「应用程序」文件夹："
    echo "       $OUT"
    exit 3
  fi
fi

if [ "${1:-}" = "--run" ]; then
  echo "==> 启动"
  open -a "/Applications/$APP.app"
fi

echo "==> 完成: $OUT"
