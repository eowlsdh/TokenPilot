#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/TokenPilot.app"
ZIP_PATH="$BUILD_DIR/TokenPilot.zip"
INFO_TEMPLATE="$PROJECT_DIR/Resources/Info.plist"
PRIVACY_MANIFEST="$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy"
APP_ICON_FILE="$PROJECT_DIR/Resources/TokenPilot.icns"
RESOURCE_BUNDLE_NAME="TokenMonitor_TokenApp.bundle"

printf '🔨 TokenPilot 앱 빌드 중...\n\n'

# 1. Swift 릴리스 빌드
echo "📦 Step 1: Swift 릴리스 빌드..."
cd "$PROJECT_DIR"
swift build -c release

# 2. 앱 번들 디렉토리 구조 생성
echo "📂 Step 2: 앱 번들 구조 생성..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 3. 실행 파일 복사
echo "📋 Step 3: 실행 파일 복사..."
BUILT_EXECUTABLE="$PROJECT_DIR/.build/release/TokenMonitor"
if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
    echo "❌ 릴리스 실행 파일을 찾지 못했습니다: $BUILT_EXECUTABLE" >&2
    exit 1
fi
cp "$BUILT_EXECUTABLE" "$APP_DIR/Contents/MacOS/TokenMonitor"
chmod +x "$APP_DIR/Contents/MacOS/TokenMonitor"

# 4. SwiftPM 리소스 번들 복사(Localizable.xcstrings 포함)
echo "🧩 Step 4: SwiftPM 리소스 번들 복사..."
RESOURCE_BUNDLE=""
for candidate in \
    "$PROJECT_DIR"/.build/*/release/$RESOURCE_BUNDLE_NAME \
    "$PROJECT_DIR"/.build/release/$RESOURCE_BUNDLE_NAME
 do
    if [[ -d "$candidate" ]]; then
        RESOURCE_BUNDLE="$candidate"
        break
    fi
 done

if [[ -z "$RESOURCE_BUNDLE" ]]; then
    echo "❌ SwiftPM 리소스 번들을 찾지 못했습니다: $RESOURCE_BUNDLE_NAME" >&2
    exit 1
fi

ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME"
if [[ ! -f "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME/Localizable.xcstrings" ]]; then
    echo "❌ Localizable.xcstrings가 앱 번들에 포함되지 않았습니다." >&2
    exit 1
fi

# 5. 상업 배포 리소스 복사(PrivacyInfo.xcprivacy, TokenPilot.icns)
echo "🛡️  Step 5: 상업 배포 리소스 복사..."
if [[ ! -f "$PRIVACY_MANIFEST" ]]; then
    echo "❌ 프라이버시 매니페스트를 찾지 못했습니다: $PRIVACY_MANIFEST" >&2
    exit 1
fi
if [[ ! -f "$APP_ICON_FILE" ]]; then
    echo "❌ 앱 아이콘 icns를 찾지 못했습니다: $APP_ICON_FILE" >&2
    exit 1
fi
cp "$PRIVACY_MANIFEST" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$APP_ICON_FILE" "$APP_DIR/Contents/Resources/TokenPilot.icns"

# 6. Info.plist 생성: Xcode용 Resources/Info.plist를 단일 원본으로 사용
echo "⚙️  Step 6: Info.plist 생성..."
python3 - "$INFO_TEMPLATE" "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

template = Path(sys.argv[1])
destination = Path(sys.argv[2])
with template.open('rb') as handle:
    plist = plistlib.load(handle)

plist.update({
    'CFBundleExecutable': 'TokenMonitor',
    'CFBundleName': 'TokenPilot',
    'CFBundleDisplayName': 'TokenPilot',
    'CFBundleIdentifier': 'com.tokenpilot.macos',
    'CFBundleIconFile': 'TokenPilot',
    'CFBundleIconName': 'AppIcon',
    'CFBundleShortVersionString': '1.0.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': True,
    'NSHumanReadableCopyright': 'Copyright © 2026 TokenPilot. All rights reserved.',
})

destination.parent.mkdir(parents=True, exist_ok=True)
with destination.open('wb') as handle:
    plistlib.dump(plist, handle, sort_keys=False)
PY

# 7. 로컬 실행용 ad-hoc 서명
# SwiftPM 실행 파일은 linker-signed 상태라 앱 번들 안에 넣으면 macOS 정책에서
# 리소스 봉인이 맞지 않는 것으로 볼 수 있습니다. 배포 서명이 아니라 로컬 smoke
# 실행을 위한 ad-hoc 서명만 적용합니다.
echo "🔏 Step 7: 로컬 실행용 ad-hoc 서명..."
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR"
else
    echo "⚠️  codesign을 찾지 못해 서명을 건너뜁니다."
fi

# 8. GitHub Release용 zip 생성
echo "🗜️  Step 8: GitHub Release zip 생성..."
rm -f "$ZIP_PATH"
(
    cd "$BUILD_DIR"
    ditto -c -k --keepParent "TokenPilot.app" "TokenPilot.zip"
)

# 9. 앱 생성 확인
printf '\n✅ 앱 빌드 완료!\n\n'
echo "📍 위치: $APP_DIR"
echo "📦 zip: $ZIP_PATH"
printf '\n🚀 앱 실행:\n'
echo "   open \"$APP_DIR\""
printf '\n또는 메뉴바 아이콘을 찾아보세요! 💻\n'
