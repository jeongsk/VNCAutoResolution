#!/bin/bash
# 빌드 스크립트 — 실행하면 build/VNCAutoResolution.app (universal, ad-hoc 서명) 이 만들어집니다.
# 필요: Xcode 또는 Command Line Tools
set -e
cd "$(dirname "$0")"

NAME="VNCAutoResolution"
APP="build/$NAME.app"

# 서명 인증서: 고정 인증서로 서명해야 다시 빌드해도 Keychain·로컬 네트워크 권한을 다시 묻지 않는다.
# SIGN_IDENTITY로 지정하거나, 없으면 키체인의 첫 "Apple Development" 인증서, 그것도 없으면 ad-hoc(-).
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

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
mkdir -p "$APP/Contents/Resources"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# 입력 소스 전환 도우미 (#12)
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/VNCInputSourceHelper" "$APP/Contents/Helpers/VNCInputSourceHelper"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/VNCInputSourceHelper"

# 서명 (로그인 항목 등록·로컬 네트워크 권한·Keychain 접근 허용이 서명에 묶인다)
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo ""
echo "✅ 완료: $(pwd)/$APP"
echo "   아키텍처: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
echo "   서명: $SIGN_IDENTITY"
