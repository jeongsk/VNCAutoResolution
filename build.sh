#!/bin/bash
# 빌드 스크립트 — 실행하면 build/VNCAutoResolution.app (universal, ad-hoc 서명) 이 만들어집니다.
# 필요: Xcode 또는 Command Line Tools
set -e
cd "$(dirname "$0")"

NAME="VNCAutoResolution"
APP="build/$NAME.app"

echo "▸ 빌드 중 (arm64 + x86_64)..."
if swift build -c release --arch arm64 --arch x86_64; then
    BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
    echo "⚠️  universal 빌드 실패 — 현재 아키텍처로만 빌드합니다."
    swift build -c release
    BIN_DIR=$(swift build -c release --show-bin-path)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 입력 소스 전환 도우미 (#12)
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/VNCInputSourceHelper" "$APP/Contents/Helpers/VNCInputSourceHelper"
codesign --force --sign - "$APP/Contents/Helpers/VNCInputSourceHelper"

# ad-hoc 서명 (로그인 항목 등록·로컬 네트워크 권한에 필요)
codesign --force --sign - "$APP"

echo ""
echo "✅ 완료: $(pwd)/$APP"
echo "   아키텍처: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
