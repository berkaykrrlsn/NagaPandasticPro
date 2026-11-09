#!/bin/bash
# NagaPandasticPro.app paketini derler ve imzalar.
# Kullanım:  ./build-app.sh            (ad-hoc imza)
#            CODESIGN_IDENTITY="Apple Development: Ad Soyad (XXXX)" ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NagaPandasticPro"
OUT="build/NagaPandasticPro.app"

echo "▸ Derleniyor (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Uygulama paketi oluşturuluyor…"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$OUT/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:--}"
echo "▸ İmzalanıyor (${IDENTITY})…"
codesign --force --deep --sign "$IDENTITY" "$OUT"

echo "✓ Hazır: $OUT"
echo "  Kurmak için:  cp -R \"$OUT\" /Applications/ && open /Applications/${APP_NAME}.app"
