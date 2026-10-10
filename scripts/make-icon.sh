#!/bin/bash
# 앱 아이콘을 다시 만든다: scripts/make-icon.swift로 그린 뒤 Resources/AppIcon.icns 생성
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swiftc -O scripts/make-icon.swift -o "$TMP/draw"
"$TMP/draw" "$TMP/src.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/src.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/src.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
sips -z 256 256 "$TMP/src.png" --out docs/images/icon.png >/dev/null
rm -rf "$TMP"
echo "✅ Resources/AppIcon.icns, docs/images/icon.png"
