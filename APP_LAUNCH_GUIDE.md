# TokenPilot 앱 실행 가이드

**상태**: macOS 메뉴바 유틸리티 앱 번들 `build/TokenPilot.app` 기준 가이드  
**업데이트**: 2026-05-20 KST

---

## 1. 앱 위치

```text
<project-root>/build/TokenPilot.app
```

Swift Package 실행 파일 이름은 `TokenMonitor`이지만, 사용자에게 보이는 앱 이름과 번들 이름은 `TokenPilot`입니다.

---

## 2. 실행 전 빌드

```bash
cd <project-root>
source .toolchain/env.sh
./build.sh
```

---

## 3. 실행 방법

### 방법 1: Finder/open으로 앱 번들 실행

```bash
open build/TokenPilot.app
```

### 방법 2: Xcode에서 실행

```bash
open TokenPilot.xcodeproj
```

Xcode에서 scheme `TokenPilot`을 선택한 뒤 `Cmd+R`로 실행합니다.

### 방법 3: 디버그 실행 파일 직접 실행

앱 번들 UI가 아니라 SwiftPM 디버그 실행을 확인할 때만 사용합니다.

```bash
source .toolchain/env.sh
swift build
.build/debug/TokenMonitor
```

---

## 4. 메뉴바에서 확인할 것

- Dock 아이콘이 없어야 합니다. (`LSUIElement=true`)
- 화면 우측 상단 메뉴바에 TokenPilot 항목이 1개 나타나야 합니다.
- 메뉴바 label은 짧은 5시간/주간 남은 비율을 우선 표시합니다.

예시:

```text
5h 64% · W 56%
5h 12% · W 38%
5h 64% · W 56% 추정
```

`MOCK`, `STALE`, `manual`, `est.` 같은 상태는 데이터 출처가 불확실할 때 보조 맥락으로 표시됩니다.

---

## 5. 팝오버 기본 동작

메뉴바 항목을 클릭하면 팝오버가 열립니다.

주요 탭:

1. **Overview** — 오늘 토큰, 위험도, provider 카드, Daily Challenge, 알림 상태
2. **History** — Today / Last 7 days / This month, 7일 차트, provider share, JSON/CSV export
3. **Settings** — Data Sources, Notifications, Telegram, Discord, Language, Setup Guide, Privacy

---

## 6. 데이터 소스 연결 요약

### Claude Code

- Claude statusline JSON 또는 local JSONL fallback을 사용합니다.
- 권장 statusline 경로: `~/Library/Application Support/TokenPilot/claude-statusline.json`

### Gemini CLI

- `~/.gemini/telemetry.log` 또는 session JSON/JSONL token object를 사용합니다.
- `gemini_cli.api_response` 이벤트만 사용량으로 집계합니다.

### Codex

- 기본은 manual/estimated + local activity beta입니다.
- local JSONL은 official web quota가 아니며 `EXPERIMENTAL`, `not web quota`, `est.` 맥락으로 표시됩니다.
- Codex Limit Hints Connector는 사용자가 명시적으로 켠 경우에만 로컬 `codex app-server`에 `account/rateLimits/read`를 요청합니다. TokenPilot은 Codex access token을 직접 읽거나 저장하지 않습니다.
- token 값은 표시/저장/export/log 하지 않습니다.

---

## 7. 프라이버시 / 네트워크 경계

기본값:

- 외부 네트워크 요청 없음
- browser cookies 읽지 않음
- TokenPilot 외부 Keychain item 읽지 않음
- prompt/response transcript 본문 표시 목적 수집 없음

사용자가 직접 켠 경우에만 발생하는 외부 동작:

- Codex Limit Hints Connector: ChatGPT 비공식 한도 힌트 조회
- Telegram/Discord: 사용자가 저장한 credential로 test/alert message 전송

---

## 8. 문제 해결

### 메뉴바 항목이 보이지 않음

1. 앱이 실행 중인지 확인:
   ```bash
   pgrep -fl 'TokenMonitor|TokenPilot'
   ```
2. 기존 테스트 인스턴스를 종료 후 재실행:
   ```bash
   pkill -f '/TokenPilot.app/Contents/MacOS/TokenMonitor' || true
   open build/TokenPilot.app
   ```

### 앱 번들이 오래된 것 같음

```bash
source .toolchain/env.sh
./build.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' build/TokenPilot.app/Contents/Info.plist
```

기대값:

```text
TokenPilot
true
```

### 데이터가 비어 있음

- Settings → Data Sources에서 `Check Connection` 또는 `Auto-detect sources`를 실행합니다.
- Codex 값은 official quota가 아니라면 manual/estimated/local activity로 표시되는 것이 정상입니다.
- 실제 Telegram/Discord test send는 credential을 저장하고 사용자가 버튼을 눌렀을 때만 수행됩니다.

---

## 9. 수동 QA 체크리스트

앱 실행 후 다음 공개 표면을 직접 확인합니다.

- 메뉴바 label이 `5h`/weekly 남은 숫자를 짧게 표시하는지
- Overview의 hero/provider row가 같은 source 상태를 일관되게 보여주는지
- Settings Privacy 영역이 local-first, opt-in connector, credential handling 경계를 과장 없이 설명하는지

---

## 10. 종료 / 정리

테스트로 앱을 실행했다면 보고 전 종료합니다.

```bash
pkill -f '/TokenPilot.app/Contents/MacOS/TokenMonitor' || true
```

상시 실행 등록, 배포, push, 외부 메시지 발송은 이 가이드의 범위가 아니며 별도 승인이 필요합니다.
