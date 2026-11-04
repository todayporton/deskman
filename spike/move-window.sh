#!/bin/bash
# spike/move-window.swift を DeskmanCore と一緒にコンパイルし、Deskman.app と同じ bundle ID と署名の .app にする。
# VM で Deskman.app に与えたアクセシビリティ権限をそのまま使うため。ホストでは起動しない。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=dist/MoveWindowSpike/Deskman.app
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$BUILD/core"
swiftc -O -parse-as-library -module-name DeskmanCore -emit-module -emit-module-path "$BUILD/core/DeskmanCore.swiftmodule" \
  -emit-library -static -o "$BUILD/core/libDeskmanCore.a" Sources/DeskmanCore/*.swift
swiftc -O -I "$BUILD/core" -L "$BUILD/core" -lDeskmanCore \
  -F /System/Library/PrivateFrameworks -framework SkyLight \
  -o "$OUT/Contents/MacOS/deskman" spike/move-window.swift
cp Resources/Info.plist "$OUT/Contents/Info.plist"
codesign --force --sign "${CODESIGN_IDENTITY:-todayporton}" "$OUT"
echo "$PWD/$OUT"
