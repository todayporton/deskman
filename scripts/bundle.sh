#!/bin/bash
# dist/Deskman.app を作る。インストールはしない。
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/Deskman.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/deskman "$APP/Contents/MacOS/deskman"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# アイコンは scripts/make-icon.swift で作る
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 既定はアドホック署名。権限を再ビルド後も保つには、自分の証明書を CODESIGN_IDENTITY に指定する。
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "署名: $IDENTITY" >&2
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "$PWD/$APP"
