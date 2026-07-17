# TokenPilot 설정 가이드 — 데이터 소스와 보안 경계

TokenPilot이 Claude Code, Antigravity CLI(레거시 Gemini CLI), Codex 사용량을 가져오는 방법과 각 설정의 신뢰도/보안 경계를 설명합니다.

**업데이트**: 2026-07-17 KST

---

## 개요

| Provider | 데이터 소스 | 기본 경로/대상 | 방식 | 기본 네트워크 |
|---|---|---|---|---|
| Claude Code | statusline JSON + local JSONL fallback | `~/Library/Application Support/TokenPilot/claude-statusline.json`, `~/.claude/projects/` | 파일 파싱 | 없음 |
| Antigravity CLI / 레거시 Gemini CLI | Antigravity statusLine JSON + legacy telemetry/session fallback | `~/Library/Application Support/TokenPilot/antigravity-statusline.json`, `~/.gemini/telemetry.log`, `~/.gemini/**` | statusLine/로그/JSON 파싱 | 없음 |
| Codex | manual snapshot + local activity beta | `CODEX_HOME/sessions`, `~/.codex/sessions`, macOS home fallback | 수동 입력 + 실험적 local JSONL 파싱 | 없음 |
| Codex Limit Hints Connector | Codex CLI app-server limit-hints RPC | 로컬 `codex app-server` + JSONL app-server RPC `account/rateLimits/read` | **명시 opt-in 로컬 app-server/RPC 요청** | 사용자가 켠 경우만 |
| Grok / xAI Management | Management API key 존재 상태 + 선택 team ID | TokenPilot Keychain item, 로컬 설정(team ID) | 설정 기반만 준비, **TokenPilot xAI HTTP 없음** | 없음 |
| OpenCode Bar Grok bridge | OpenCode Bar의 Grok usage percentage/reset | 명시적으로 켠 경우의 고정 `opencodebar provider grok --json` subprocess | **명시 opt-in, EXPERIMENTAL / UNOFFICIAL** | OpenCode Bar가 자체 auth/undocumented endpoint를 사용할 수 있음 |

기본값에서는 네트워크 usage 요청이나 OpenCode Bar subprocess 호출이 없습니다. Grok / xAI Management은 disabled/not-configured neutral 상태이며 TokenPilot은 xAI HTTP 요청을 보내지 않습니다. Codex Limit Hints Connector, OpenCode Bar Grok bridge, Telegram/Discord test/alert send는 사용자가 직접 켠 경우에만 동작합니다.

---

## 1. Claude Code

### 상태라인 파일 활성화

Claude Code는 statusline JSON을 만들도록 구성하면 TokenPilot이 한도/토큰 정보를 읽을 수 있습니다.

권장 파일:

```text
~/Library/Application Support/TokenPilot/claude-statusline.json
```

### 파싱 필드

| 필드 경로 | 설명 |
|---|---|
| `rate_limits.five_hour.used_percentage` | 5시간 사용률 (%) |
| `rate_limits.five_hour.resets_at` | 5시간 리셋 시간 |
| `rate_limits.seven_day.used_percentage` | 주간 사용률 (%) |
| `rate_limits.seven_day.resets_at` | 주간 리셋 시간 |
| `context_window.current_usage.*` | input/output/cache 토큰 |
| `cost.total_cost_usd` | 제공되는 경우의 비용 메타데이터 |
| `model.display_name` | 모델 이름 |

### 상태 조건

| 조건 | 신뢰도 | 상태 메시지 예시 |
|---|---:|---|
| 파일 없음 | Low | `Connect Claude statusline` |
| 유효한 최신 데이터 | High | `Connected` |
| 유효하지만 오래됨 | Medium | `STALE · older than 2 minutes` |
| JSON 파싱 실패 | Low | `Invalid JSON` |
| statusline 없음, local JSONL 사용 | Medium | `Local JSONL · rate limits unavailable` |

---

## 2. Antigravity CLI / 레거시 Gemini CLI

### Antigravity statusLine JSON

TokenPilot은 Antigravity CLI가 custom `statusLine` command로 stdin에 전달하는 `context_window` token metadata를 privacy-safe JSON으로 저장한 파일을 기본 소스로 읽습니다.

기본 파일:

```text
~/Library/Application Support/TokenPilot/antigravity-statusline.json
```

레거시 fallback 후보:

```text
~/.gemini/telemetry.log
~/.gemini/tmp
~/.gemini/history
```

### 파싱 필드

| 필드 | 설명 |
|---|---|
| `input_token_count` | 입력 토큰 |
| `output_token_count` | 출력 토큰 |
| `cached_content_token_count` | 캐시 토큰 |
| `thoughts_token_count` | reasoning 토큰 |
| `tool_token_count` | 도구 호출 토큰 |
| `context_window.total_input_tokens` / `total_output_tokens` | Antigravity context window token total |
| `context_window.current_usage.*` | Antigravity current turn input/output/cache token metadata |
| `total_token_count` | 전체 토큰. 있으면 component 합계보다 우선 |
| `model` | 모델 이름 |
| `duration_ms` | 요청 소요 시간 |
| `auth_type` | 인증 타입 메타데이터 |

### 집계 기간

| 기간 | 기준 |
|---|---|
| Today | 해당 날짜 00:00부터 현재까지 |
| Last 7 days | 최근 7일 |
| This month | 월 첫째 날부터 현재까지 |

---

## 3. Codex — Manual / Local Activity Beta

Codex는 Claude statusline이나 Antigravity statusLine/Gemini telemetry처럼 안정적으로 문서화된 공식/로컬 사용량 파일이 없습니다. TokenPilot은 기본적으로 다음 범위만 사용합니다.

1. 사용자가 직접 입력한 `/status` / manual web snapshot
2. 로컬 session JSONL의 `token_count` row 기반 local activity beta

### 자동 경로 탐색 순서

TokenPilot은 local activity 탐색에서 credential 파일을 제외하고 아래 session 후보만 확인합니다.

1. `CODEX_HOME/sessions`
2. `CODEX_HOME/archived_sessions`
3. 현재 프로세스 `HOME`의 `.codex/sessions`
4. 현재 프로세스 `HOME`의 `.codex/archived_sessions`
5. Hermes profile HOME처럼 실제 macOS 사용자 홈과 다른 경우 macOS user-home fallback

### 수동 입력 항목

| 항목 | 설명 |
|---|---|
| Plan Label | 플랜 이름 |
| 5h Usage % | 5시간 사용률 |
| Weekly Usage % | 주간 사용률 |
| Reset Time | 리셋 시간 텍스트 |
| Notes | 메모 |
| Pasted `/status` output | Codex `/status` 출력 텍스트 |

### 신뢰도 정책

| 소스 | 신뢰도 | 표시 원칙 |
|---|---:|---|
| 데이터 없음 | Manual/Low | manual fallback |
| `/status` 또는 manual input | Medium 이하 | `manual`/`est.` 명시 |
| local session JSONL | Medium 이하 | `EXPERIMENTAL · local Codex log · not web quota` |

local JSONL token totals는 ChatGPT/Codex 웹 quota와 직접 비교하지 않습니다. export v2의 chart/provider share는 `localActivity`/`local_activity_not_provider_quota`로 라벨링되며, non-comparable experimental Codex local events는 제외합니다.

---

## 4. Codex Limit Hints Connector — 명시 opt-in

Codex Limit Hints Connector는 Codex local JSONL이 아닌 Codex CLI app-server limit-hints RPC를 조회하는 별도 경로입니다.

### 켜졌을 때만 수행하는 작업

- TokenPilot은 Codex credential file의 token 값을 직접 읽지 않음
- 로컬 `codex app-server`에 `jsonrpc` 필드 없는 JSONL `initialize`, `initialized`, `account/rateLimits/read` 순서로 요청
- 인증 처리는 Codex CLI가 담당하며 TokenPilot UI/export/log에는 Codex access token 값을 남기지 않음
- 응답의 primary/secondary rate limit window와 plan label만 사용량 스냅샷에 반영

### 하지 않는 작업

- token 값 저장, 표시, export, log
- browser cookies 읽기
- unrelated Keychain item 읽기
- OAuth refresh token 또는 credential store 전체 표시
- connector가 OFF일 때 auth file 읽기 또는 HTTP 호출

### 실패 상태

| 조건 | 상태 |
|---|---|
| connector OFF | `Codex Limit Hints connector off` |
| app-server auth required | `Codex app-server auth required · run codex login` |
| app-server/RPC unavailable | `Codex app-server limit hints unavailable` |
| 응답 schema 변경 | `Codex app-server limit hints rate limits unavailable` 또는 parse error |

> 이 app-server RPC는 Codex CLI experimental API에 의존하므로 변경될 수 있습니다. public release UX에서는 opt-in beta로 표시해야 합니다.

---

## 5. Grok / xAI sources

Grok Settings → Usage가 공식 source of truth입니다. TokenPilot에는 기본 OFF인 두 경로가 있으며, Management setup과 OpenCode Bar bridge는 별개입니다.

### Management setup — no-network foundation

Grok / xAI Management(`.xai`)은 현재 설정 기반만 준비합니다. 기본값은 disabled/not-configured neutral 상태이며, 설정을 저장해도 TokenPilot은 production에서 xAI HTTP 요청을 보내지 않습니다.

| 항목 | 저장/표시 정책 |
|---|---|
| xAI Management API Key | TokenPilot 소유 Keychain item에만 저장. 저장 후 숨김 상태만 표시 |
| xAI Team ID | 로컬 설정에만 저장. UI에서는 마스킹된 값만 표시 |
| 저장/삭제 상태 | `saved`, `hidden/masked`, `deleted`, `not configured`처럼 비밀값을 노출하지 않는 상태만 표시 |
| Export/log/error | Management key, team ID, billing identifier, provider credential을 포함하지 않음 |

xAI 공식 Management 인증 문서에서 Management-key transport가 명확해질 때까지 상태는 `Management authentication unconfirmed`로 취급합니다. 이 기간에는 TokenPilot이 xAI endpoint를 호출하지 않습니다. 향후 TokenPilot Management 네트워크 기능을 추가하더라도 사용자가 명시적으로 켠 경우에만 동작해야 하며, 호출 가능한 endpoint allowlist를 코드/문서에 함께 둬야 합니다.

### Optional OpenCode Bar Grok bridge — experimental

OpenCode Bar를 설치하고 해당 문서에 따라 Grok CLI setup을 완료한 뒤에만 TokenPilot에서 이 source를 명시적으로 켭니다. 켜진 경우 TokenPilot은 고정된 `opencodebar provider grok --json` subprocess만 실행하고 percentage/reset만 가져옵니다. source를 끄면 TokenPilot의 subprocess 호출도 중단합니다.

이 bridge는 **EXPERIMENTAL / UNOFFICIAL**입니다. TokenPilot은 OAuth 파일, browser cookie, auth database 또는 OpenCode Bar 자체 Grok CLI auth를 읽지 않습니다. 그러나 OpenCode Bar는 자체 auth를 읽고 undocumented endpoint를 호출할 수 있습니다. 따라서 기존 “xAI HTTP 요청 0건”은 TokenPilot 자체에 대한 설명이며 bridge 결과는 깨질 수 있고 official API billing 또는 Grok web-subscription entitlement를 보장하지 않습니다.

xAI API billing은 Grok web subscription 한도와 별개입니다. TokenPilot은 Grok web subscription limit을 읽거나 표시하지 않으며, live xAI billing 지원을 주장하지 않습니다.

---

## 6. 공통 설정 변경

앱 설정 또는 Settings UI에서 다음을 조정합니다.

| 설정 | 설명 |
|---|---|
| `claudeStatusFilePath` | Claude statusline JSON 경로 |
| `geminiTelemetryLogPath` | Antigravity statusLine JSON 또는 레거시 Gemini telemetry/session 경로 |
| `CODEX_HOME` | Codex root. 설정되면 `CODEX_HOME/sessions`와 archived sessions 후보에 반영 |
| Codex manual fields | plan, 5h/weekly usage, reset, notes, pasted status |
| Codex limit hints connector toggle | 기본 OFF. 켠 경우에만 로컬 Codex CLI app-server RPC 사용 |
| xAI Management API key | TokenPilot Keychain에만 저장. 저장 후 숨김 상태만 표시하고 export/log/error에 포함하지 않음 |
| xAI team ID | 로컬 설정값. 마스킹된 값만 표시하고 export/log/error에 포함하지 않음 |
| xAI billing/prepaid settings | official Management-key transport와 endpoint allowlist가 문서화될 때까지 비활성 설정값으로만 유지 |
| OpenCode Bar Grok bridge toggle | 기본 OFF. OpenCode Bar 설치 및 Grok CLI setup 후에만 명시적으로 켜며, 켠 경우 고정 `opencodebar provider grok --json`으로 percentage/reset만 가져옴 |

---

## 7. 문제 해결

### `Connect Claude statusline`이 계속 표시

1. statusline JSON 파일이 실제로 생성되는지 확인
2. TokenPilot 설정 경로와 파일 위치가 일치하는지 확인
3. JSON 형식이 유효한지 확인

### `Select Antigravity statusline JSON or legacy Gemini source`가 계속 표시

1. Settings의 Setup Guide에서 Antigravity statusLine bridge를 설치했는지 확인
2. `~/Library/Application Support/TokenPilot/antigravity-statusline.json`가 생성되는지 확인
3. 레거시 fallback을 쓰는 경우 `~/.gemini/telemetry.log`, `~/.gemini/tmp`, `~/.gemini/history` 중 사용량 이벤트가 있는지 확인
4. 다른 경로라면 Settings에서 파일 또는 폴더를 선택

### Codex local session 파일을 못 찾는 경우

1. `CODEX_HOME`을 쓰고 있다면 `CODEX_HOME/sessions`가 실제 root인지 확인
2. Hermes/agent 환경에서는 process `HOME`과 실제 macOS home이 다를 수 있음
3. Data Sources scan에서 macOS user-home fallback 후보가 보이는지 확인
4. local JSONL이 있어도 official quota가 아니므로 manual snapshot 또는 Limit Hints Connector opt-in과 구분

### Codex Limit Hints Connector가 low confidence인 경우

1. connector가 켜져 있는지 확인
2. Codex CLI login 상태를 사용자가 직접 확인
3. auth expired 메시지면 Codex login 갱신 후 재시도
4. Codex CLI app-server API 변경 가능성을 감안

### Grok / xAI가 `not configured` 또는 `Management authentication unconfirmed`인 경우

1. 기본 상태입니다. xAI Management provider는 production에서 TokenPilot xAI HTTP 요청을 보내지 않습니다.
2. Management API key는 저장해도 TokenPilot Keychain item에만 보관되고 화면에는 숨김 상태만 표시됩니다.
3. Team ID는 선택 로컬 값이며 마스킹된 상태만 표시됩니다. 문서나 issue에 실제 team ID를 넣지 마세요.
4. 공식 xAI Management 인증 문서가 Management-key transport를 명확히 할 때까지 TokenPilot endpoint 호출은 비활성입니다.
5. xAI API billing과 Grok web subscription limit은 별개이며, TokenPilot은 Grok web subscription limit이나 live xAI billing을 표시하지 않습니다.

### OpenCode Bar Grok bridge가 unavailable인 경우

1. 기본값은 OFF입니다. OpenCode Bar를 설치하고 그 문서에 따라 Grok CLI setup을 완료한 뒤에만 이 source를 켭니다.
2. TokenPilot은 켜진 경우에만 `opencodebar provider grok --json`을 실행하고 percentage/reset만 가져옵니다. OFF로 바꾸면 subprocess 호출이 중단됩니다.
3. TokenPilot은 OAuth 파일, browser cookie, auth database 또는 OpenCode Bar auth를 읽지 않습니다. OpenCode Bar의 자체 auth/network 동작은 제3자 동작이며 undocumented endpoint를 사용할 수 있습니다.
4. 결과는 EXPERIMENTAL / UNOFFICIAL이며 깨질 수 있습니다. 공식 확인은 Grok Settings → Usage를 사용하고, bridge 결과를 official API billing 또는 web-subscription entitlement로 해석하지 마세요.

### 값이 0 또는 empty로 보이는 경우

- Claude: statusline `context_window.current_usage` 또는 local JSONL usage row 확인
- Antigravity/Gemini: Antigravity `context_window` token metadata 또는 레거시 `gemini_cli.api_response` 이벤트 존재 여부 확인
- Codex: manual snapshot 입력 또는 Limit Hints Connector opt-in 상태 확인
