#!/bin/bash
# Phase 0 探针构建
#   ./probe/build.sh            编译 probe/ 下全部 .swift
#   ./probe/build.sh lockkey    只编译一个
# 产物在 .build/probe/<name>

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/probe" || exit 1

CACHE="$ROOT/.cache"
BIN="$ROOT/.build/probe"
mkdir -p "$CACHE" "$BIN"

export SWIFT_MODULE_CACHE_PATH="$CACHE"
export CLANG_MODULE_CACHE_PATH="$CACHE"

build_one() {
  local name="$1"
  local src="$name.swift"
  [ -f "$src" ] || return 0
  swiftc -O -whole-module-optimization \
    -target arm64-apple-macos14.0 \
    -framework CoreBluetooth -framework LocalAuthentication -framework AppKit -framework ApplicationServices \
    -framework Security -framework Foundation -framework CoreGraphics \
    -framework IOKit \
    -o "$BIN/$name" "$src" 2>"$BIN/$name.err"
  local rc=$?
  grep -v 'sandbox-exec: sandbox_apply' "$BIN/$name.err" || true
  if [ $rc -ne 0 ]; then
    echo "!! $name 编译失败 (exit $rc)"
    return $rc
  fi
  echo "ok  $BIN/$name"
}

if [ $# -gt 0 ]; then
  build_one "$1"
else
  for f in *.swift; do
    [ -e "$f" ] || continue
    build_one "${f%.swift}"
  done
fi
