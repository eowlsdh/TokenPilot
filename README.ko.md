# TokenPilot — macOS 메뉴바 AI 한도/사용량 모니터

**TokenPilot**은 Claude Code, Codex, Antigravity CLI(레거시 Gemini telemetry), DeepSeek balance 신호와 Grok의 로컬 context 신호를 local-first 방식으로 모아 macOS 메뉴바에서 남은 한도와 사용 기록을 빠르게 확인하는 유틸리티입니다. Grok/xAI는 숫자로 된 로컬 context 메타데이터만 읽습니다.

- **상태**: GitHub Release 후보 준비, 로컬 빌드/테스트/앱 bundle/zip 검증 경로 유지
- **앱 표시 이름**: `TokenPilot`
- **Swift Package / 실행 타깃 이름**: `TokenMonitor`
- **앱 번들 산출물**: `build/TokenPilot.app`, `build/TokenPilot.zip`

> 핵심 원칙: TokenPilot은 사용량 메타데이터 중심으로 동작합니다. 프롬프트/응답 본문, 브라우저 쿠키, provider auth 파일, 임의 Keychain 항목은 읽지 않습니다.
>
> TokenPilot은 OpenAI, Anthropic, Google, DeepSeek, xAI와 제휴하거나 공식 인증을 받은 제품이 아닙니다.

![TokenPilot 남은 한도 중심 Overview, DeepSeek balance, privacy-first Settings 스크린샷](docs/assets/readme-screenshot.png)
[English](README.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

---

## 지금 무엇을 보여주나요?

| 화면 | 역할 |
|---|---|
| **메뉴바** | `5h 18% · W 53%`처럼 5시간/주간 **남은 한도**를 한 줄로 표시합니다. |
| **개요** | 현재 남은 한도, provider별 수용량 상태, DeepSeek topped-up balance, 오늘 토큰, 알림 상태를 보여주는 capacity-first 화면입니다. |
| **기록** | 저장된 이벤트와 최신 한도 증거 타임라인을 보여주며, 로컬 활동 집계는 quota가 아닌 export-only JSON/CSV 데이터로만 제공합니다. |
| **설정** | Provider Diagnostics, Codex Limit Hints Connector, DeepSeek balance/API key 설정, Grok 로컬 context diagnostics, manual fallback, 알림, Telegram/Discord, 언어, 설정 가이드, privacy 경계를 제공합니다. |

---

## 주요 기능

- **macOS 메뉴바 앱**: Dock 아이콘 없이 AppKit `NSStatusItem`과 `NSPopover`를 사용하는 유틸리티.
- **남은 한도 중심 UI**: 사용한 비율보다 “얼마나 남았는지”를 먼저 보여줍니다.
- **Claude / Codex / Antigravity(레거시 Gemini telemetry) / DeepSeek / Grok/xAI 통합**: 각 provider의 로컬 메타데이터, 선택형 balance 신호, Grok 로컬 context 메타데이터를 한 화면에 정리합니다.
- **정직한 confidence label**: official, local, manual, estimated, experimental, limit hint를 구분합니다.
- **Provider Diagnostics**: 연결 상태, confidence, 마지막 확인 시간, 다음 조치를 표시합니다.
- **History / Export**: 기록 탭은 저장된 이벤트와 최신 한도 증거 타임라인을 보여주고, 로컬 활동 집계는 quota가 아닌 데이터로 JSON/CSV export에만 포함합니다.
- **알림**: macOS local notification + 선택형 Telegram/Discord threshold/reset alert.
- **DeepSeek balance**: 사용자가 API key를 저장한 경우 공식 `/user/balance`의 `topped_up_balance`를 native currency로 표시하고, 수동 fallback과 $5 low-balance alert를 제공합니다.
- **Grok/xAI source**: `~/.grok/sessions/**/signals.json`의 숫자로 된 로컬 context 메타데이터만 읽습니다. `auth.json`, OAuth token, prompt, response는 읽지 않습니다. 메뉴바에는 subscription quota나 API billing이 아니라 남은 로컬 context(`100 - contextWindowUsage`)를 표시합니다.
- **4개 언어**: English, 한국어, 日本語, 简体中文.

---

## 빠른 시작

### 1. Release 다운로드

GitHub Releases에서 `TokenPilot.zip`을 다운로드하고 압축을 푼 뒤 `TokenPilot.app`을 실행합니다.

Gatekeeper 경고가 나오면 앱을 우클릭한 뒤 **Open**을 선택하세요.

### 2. 소스에서 빌드

```bash
git clone https://github.com/eowlsdh/TokenPilot.git
cd TokenPilot
make bundle
open build/TokenPilot.app
```

### 3. Xcode

```bash
git clone https://github.com/eowlsdh/TokenPilot.git
cd TokenPilot
xcodegen generate
open TokenPilot.xcodeproj
# Cmd+R
```

---

## Provider 지원

### Claude Code

- `~/Library/Application Support/TokenPilot/claude-statusline.json`
- `~/.claude/projects/`, `~/.config/claude/projects/`, `CLAUDE_CONFIG_DIR/projects`
- 5시간/주간 rate limit, context window, input/output/cache token, model, 비용 메타데이터를 파싱합니다.

### Codex

지원 방식 우선순위:

1. **Codex Limit Hints Connector**
   사용자가 명시적으로 켠 경우 로컬 `codex app-server`에 `jsonrpc` 필드 없는 JSONL `initialize`, `initialized`, `account/rateLimits/read` 순서로 요청합니다. TokenPilot은 Codex access token을 직접 읽거나 저장하지 않습니다.
2. **Manual Limit Snapshot / `/status` parse**
   사용자가 직접 본 5h/weekly 값을 입력하거나 붙여넣은 `/status`에서 추정합니다.
3. **Local Activity Beta**
   로컬 session JSONL의 `token_count` 계열 row를 실험적으로 파싱합니다.

주의:

- Limit Hints Connector는 Codex CLI app-server의 experimental API에 의존하므로 Codex CLI 변경 시 깨질 수 있습니다.
- connector는 기본 OFF입니다.
- local JSONL은 official quota가 아니므로 `EXPERIMENTAL`, `Local log`, `not web quota`, `est.` 맥락으로만 표시하며 export에서도 provider quota로 포함하지 않습니다.

### Antigravity CLI / 레거시 Gemini telemetry

- 기본 경로는 `~/Library/Application Support/TokenPilot/antigravity-statusline.json`입니다.
- Settings → Setup Guide → **Connect Antigravity CLI**가 설치하는 statusLine bridge를 통해 Antigravity CLI의 context window token usage를 읽습니다.
- 저장되는 값은 model, context-window input/output total, current usage token count, percentage 같은 allowlist metadata뿐입니다. prompt/response, email, cwd/workspace, provider auth material은 저장하지 않습니다.
- 레거시 Gemini source로는 `~/.gemini/telemetry.log`만 계속 지원합니다.

### DeepSeek

- Settings에서 사용자가 API key를 명시적으로 저장한 경우에만 official `/user/balance`를 호출합니다.
- 표시 값은 `balance_infos[].topped_up_balance`이며 USD 외 currency도 native currency 그대로 표시합니다.
- API key가 없거나 호출이 실패하면 저장된 성공 값은 stale로 표시하거나, 사용자가 켠 manual fallback 값을 명확히 구분해서 보여줍니다.
- topped-up balance가 $5 이하이면 low-balance alert를 낼 수 있습니다.

### Grok / xAI source

TokenPilot은 다음 파일에서 숫자로 된 로컬 context 메타데이터만 읽습니다.

```text
~/.grok/sessions/**/signals.json
```

`auth.json`, OAuth token, prompt, response, provider billing/subscription 데이터는 읽지 않습니다. Grok 메뉴바 값은 남은 로컬 context(`100 - contextWindowUsage`)이며 provider quota가 아니므로 provider quota나 API billing과 비교할 수 없습니다.

---

## Privacy / Security 경계

TokenPilot이 읽는 것:

- 사용자가 선택한 Claude statusline JSON
- Claude/Codex/Antigravity의 로컬 사용량 로그 또는 세션 메타데이터
- Antigravity statusLine JSON bridge output / Gemini `telemetry.log`
- 사용자가 입력한 Codex status 텍스트 / manual limit snapshot
- 사용자가 직접 저장한 Telegram bot token / Discord webhook의 존재 여부
- 사용자가 켠 경우 로컬 Codex CLI app-server가 반환하는 한도 힌트
- 사용자가 저장한 DeepSeek API key로 official `/user/balance`가 반환하는 topped-up balance
- `~/.grok/sessions/**/signals.json`의 숫자로 된 Grok 로컬 context 메타데이터

TokenPilot이 읽지 않는 것:

- browser cookies
- 브라우저 세션 저장소
- TokenPilot 외부의 임의 Keychain 항목
- 프롬프트/응답 본문 표시 목적의 transcript 내용
- `auth.json`, OAuth refresh token, provider 계정 전체 credential store
- Codex auth 파일 직접 읽기
- Grok prompt/response
- Grok subscription quota 또는 xAI API billing 데이터

TokenPilot이 외부로 보내는 것:

- 기본값: 없음
- Codex Limit Hints Connector ON: 로컬 `codex app-server`에 JSONL app-server RPC `account/rateLimits/read` 요청
- DeepSeek balance ON + API key 저장: `https://api.deepseek.com/user/balance`에 Bearer 요청
- Grok/xAI: 외부 요청 없음. `~/.grok/sessions/**/signals.json`의 숫자로 된 로컬 context 메타데이터만 읽습니다.
- Telegram/Discord ON + credential 저장: threshold/reset alert 또는 test message

---

## 프로젝트 구조

```text
TokenPilot/
├── Package.swift
├── project.yml
├── build.sh
├── Resources/
├── Sources/
│   ├── TokenApp/      # AppKit app shell, Overview/History/Settings
│   └── TokenCore/     # adapters, aggregation, settings, notifications, export
├── Tests/
└── docs/
```

---

## 빌드 / 테스트

```bash
swift test

swift build -Xswiftc -warnings-as-errors
# warnings-as-errors strict build

make verify
# build + tests + release bundle smoke
```

앱 번들 생성:

```bash
make bundle
open build/TokenPilot.app
```

---

## 현재 검증 상태

이 문서는 특정 머신의 오래된 통과 결과를 고정 기록하지 않습니다. 릴리스 검증은 현재 checkout에서 다시 실행한 명령, 실행자/날짜, 주요 환경, 산출물 hash, 실패/차단 사유를 함께 남길 때만 유효합니다.

현재 문서 변경에서 새로 첨부한 증거:
- 빌드/테스트/번들/verify 실행 결과: 없음. 아래 명령은 재현 절차이며 최신 통과 기록이 아닙니다.
- 앱 bundle/zip 상태: 새로 확인하지 않음. 릴리스 전 `docs/verification/developer-id-capacity-release.md`의 evidence table에 현재 결과를 기록해야 합니다.

재현 명령:

```bash
swift test
swift build -Xswiftc -warnings-as-errors
make bundle
make verify
```

수동/환경 의존 QA:

- 실제 메뉴바 숫자, Overview provider row, Settings privacy 문구는 현재 빌드 앱 실행 상태에서 redacted evidence로 확인합니다.
- 실제 Telegram/Discord 발송, 실제 Codex Limit Hints Connector 동작은 사용자 credential/명시 승인 없이는 수행하지 않습니다.

---

## 알려진 제한

1. **Codex Limit Hints Connector는 opt-in / unofficial**
   - Codex CLI app-server의 응답 형식이 바뀌면 low-confidence 상태로 떨어질 수 있습니다.
2. **Codex local JSONL은 official quota가 아님**
   - 앱 내부 통계/History에는 로컬 activity token을 포함하되 official web quota로 주장하지 않습니다.
3. **브라우저 smoke 대상 없음**
   - TokenPilot은 macOS SwiftUI 메뉴바 앱이므로 앱 launch/plist smoke와 Swift 테스트로 검증합니다.

---

## 개발 메모

- API key/token/webhook 값은 문서에 기록하지 않습니다.
- 공개 README는 release-facing 정보만 유지합니다.
- 기여 전 `make verify`를 실행하세요.
