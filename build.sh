#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/TokenPilot.app"
ZIP_PATH="$BUILD_DIR/TokenPilot.zip"
INFO_TEMPLATE="$PROJECT_DIR/Resources/Info.plist"
PROJECT_SPEC="$PROJECT_DIR/project.yml"
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
python3 - "$INFO_TEMPLATE" "$APP_DIR/Contents/Info.plist" "$PROJECT_SPEC" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

template = Path(sys.argv[1])
destination = Path(sys.argv[2])
spec = Path(sys.argv[3])
with template.open('rb') as handle:
    plist = plistlib.load(handle)


def spec_setting(name):
    """Read a build setting from project.yml.

    The version used to be written out here as a literal as well as in project.yml, so the
    bundle this script produces and the one Xcode produces could disagree about what they
    were — and an App Store build number that silently goes backwards is rejected. Failing
    loudly beats a default: a quiet fallback would just recreate the drift.
    """
    match = re.search(rf'^\s*{name}:\s*"?([^"\s#]+)"?\s*$', spec.read_text(encoding='utf-8'), re.M)
    if not match:
        raise SystemExit(f'{name} not found in {spec}; build.sh and project.yml must agree on the version')
    return match.group(1)


marketing_version = spec_setting('MARKETING_VERSION')
bundle_version = spec_setting('CURRENT_PROJECT_VERSION')

plist.update({
    'CFBundleExecutable': 'TokenMonitor',
    'CFBundleName': 'TokenPilot',
    'CFBundleDisplayName': 'TokenPilot',
    'CFBundleIdentifier': 'com.tokenpilot.macos',
    'CFBundleIconFile': 'TokenPilot',
    'CFBundleIconName': 'AppIcon',
    'CFBundleShortVersionString': marketing_version,
    'CFBundleVersion': bundle_version,
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': True,
    'NSHumanReadableCopyright': 'Copyright © 2026 TokenPilot. All rights reserved.',
})

destination.parent.mkdir(parents=True, exist_ok=True)
with destination.open('wb') as handle:
    plistlib.dump(plist, handle, sort_keys=False)
PY

# 7. 코드 서명
# SwiftPM 실행 파일은 linker-signed 상태라 앱 번들 안에 넣으면 macOS 정책에서
# 리소스 봉인이 맞지 않는 것으로 볼 수 있어 재서명이 필요합니다.
#
# ad-hoc 서명(--sign -)에는 서명 주체(Authority)와 Team ID가 없습니다. macOS Keychain은
# 이 둘로 앱을 식별하므로, ad-hoc 앱은 빌드가 바뀔 때마다 신뢰 대상으로 인정받지 못하고
# 저장된 비밀에 접근할 때마다 사용자에게 다시 인증을 요구합니다. 서명 신원이 있으면
# Team ID가 고정되어 "항상 허용"이 유지됩니다.
#
# TOKENPILOT_SIGN_IDENTITY로 명시 지정할 수 있고, 지정하지 않으면 사용 가능한 신원을
# 자동 탐색합니다. 신원이 없는 환경(CI 등)에서는 ad-hoc으로 폴백해 빌드를 깨지 않습니다.
echo "🔏 Step 7: 코드 서명..."
if ! command -v codesign >/dev/null 2>&1; then
    echo "⚠️  codesign을 찾지 못해 서명을 건너뜁니다."
else
    SIGN_IDENTITY="${TOKENPILOT_SIGN_IDENTITY:-}"

    if [ -z "$SIGN_IDENTITY" ] && command -v security >/dev/null 2>&1; then
        AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
        # Developer ID를 우선 사용하고(배포 가능), 없으면 Apple Development를 사용합니다.
        # grep은 매치 실패 시 exit 1이므로 `set -o pipefail` 아래에서 스크립트를 중단시킵니다.
        # `|| true`로 실패를 흡수해야 첫 패턴이 없을 때도 다음 패턴을 계속 탐색합니다.
        for pattern in "Developer ID Application" "Apple Development"; do
            candidate="$(printf '%s\n' "$AVAILABLE_IDENTITIES" \
                | grep "$pattern" \
                | head -1 \
                | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*([0-9A-F]{40}).*/\1/' || true)"
            if [ -n "$candidate" ]; then
                SIGN_IDENTITY="$candidate"
                break
            fi
        done
    fi

    # Entitlements are selectable so the sandboxed App Store configuration can be built and tested
    # locally: TOKENPILOT_ENTITLEMENTS=Resources/TokenPilot-AppStore.entitlements ./build.sh
    ENTITLEMENTS_FILE="${TOKENPILOT_ENTITLEMENTS:-$PROJECT_DIR/Resources/TokenPilot.entitlements}"
    ENTITLEMENTS_ARGS=()
    if [ -f "$ENTITLEMENTS_FILE" ]; then
        ENTITLEMENTS_ARGS=(--entitlements "$ENTITLEMENTS_FILE")
        echo "   entitlements: $(basename "$ENTITLEMENTS_FILE")"
    fi

    if [ -n "$SIGN_IDENTITY" ] && codesign --force --deep --options runtime --timestamp=none \
        "${ENTITLEMENTS_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
        SIGN_AUTHORITY="$(codesign -dvvv "$APP_DIR" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
        SIGN_TEAM="$(codesign -dvvv "$APP_DIR" 2>&1 | grep '^TeamIdentifier=' | head -1 | cut -d= -f2-)"
        echo "   서명 신원: ${SIGN_AUTHORITY:-unknown}"
        echo "   Team ID: ${SIGN_TEAM:-not set} (고정되므로 Keychain 재인증이 반복되지 않습니다)"
    else
        if [ -n "$SIGN_IDENTITY" ]; then
            echo "⚠️  서명 신원으로 서명하지 못해 ad-hoc으로 대체합니다."
        else
            echo "ℹ️  사용 가능한 서명 신원이 없어 ad-hoc으로 서명합니다."
        fi
        echo "   ad-hoc 앱은 실행할 때마다 Keychain 인증을 다시 요구할 수 있습니다."
        codesign --force --deep --sign - "$APP_DIR"
    fi
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
