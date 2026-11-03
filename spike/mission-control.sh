#!/bin/bash
# spike/mission-control.swift を、Deskman.app と同じ bundle ID と署名の .app にする。
# VM で Deskman.app に与えたアクセシビリティ権限をそのまま使うため。ホストでは起動しない。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=dist/MissionControlSpike/Deskman.app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
swiftc -O -o "$OUT/Contents/MacOS/deskman" spike/mission-control.swift
cp Resources/Info.plist "$OUT/Contents/Info.plist"
codesign --force --sign "${CODESIGN_IDENTITY:-todayporton}" "$OUT"
echo "$PWD/$OUT"
