# TokenPilot — Codex 사용량/비용 검증 메모

**업데이트**: 2026-05-20 KST  
**상태**: 기존 `TokenMonitor`/`AI 56 CX:45%` 기준 문서를 현재 TokenPilot 정책으로 갱신

---

## 결론

Codex는 TokenPilot에서 세 가지 경로로 분리해 다룹니다.

1. **Manual Limit Snapshot** — 사용자가 웹/`/status`에서 본 5h/weekly 값을 직접 입력
2. **Local Activity Beta** — 로컬 session JSONL의 `token_count` row를 실험적으로 파싱
3. **Codex Limit Hints Connector** — 사용자가 명시적으로 켠 경우에만 Codex CLI app-server limit-hints RPC 조회

Codex 비용은 정확한 토큰 단가/청구 출처가 안정적으로 제공되지 않는 한 공식 비용처럼 표시하지 않습니다. local JSONL은 web quota와 1:1 대응되지 않으므로 `EXPERIMENTAL`, `not web quota`, `est.` 맥락으로만 표시합니다.

---

## Codex source policy

| 소스 | 기본값 | 신뢰도 | UI 표기 |
|---|---:|---:|---|
| Manual `/status` / web snapshot | 사용자가 입력 시 | Medium 이하 또는 user-entered snapshot | `manual`, `est.` 또는 user-entered web snapshot |
| Local session JSONL | 자동 후보 탐색 | Medium 이하 | `EXPERIMENTAL · local Codex log · not web quota` |
| Limit Hints Connector | OFF | success 시 High, 실패 시 Low | `UNOFFICIAL · Codex app-server limit hints · token handled by Codex CLI` |

---

## Limit Hints Connector 보안 경계

Connector가 OFF이면 auth file을 읽거나 HTTP 호출하지 않습니다.

Connector가 ON이면 기본 경로에서는 다음만 수행합니다.

- 로컬 `codex app-server` 프로세스에 JSON-RPC `initialize` 후 `account/rateLimits/read`만 요청
- 인증과 token refresh는 Codex CLI가 담당
- TokenPilot은 `~/.codex/auth.json` 또는 `CODEX_HOME/auth.json`의 token 값을 직접 읽지 않음
- 응답의 5h/weekly rate-limit window와 plan label만 파싱
- legacy direct HTTP/auth-file 경로는 기본 비활성화이며, 명시적 compatibility/test flag 없이는 실행되지 않음

하지 않는 것:

- token 값 저장, 표시, export, log
- browser cookies 읽기
- unrelated Keychain item 읽기
- credential file 전체 표시
- connector OFF 상태에서 auth/network 사용

---

## 테스트 커버리지

현재 테스트에는 다음 Codex 관련 회귀가 포함됩니다.

- connector OFF면 HTTP client가 호출되지 않음
- fixture app-server JSON-RPC 응답으로 primary/secondary rate limit 힌트를 파싱
- status message/metadata에 fake token 값이 누출되지 않음
- app-server auth required 오류는 HTTP fallback 없이 low confidence
- JSON-RPC 요청은 표준 `jsonrpc: "2.0"`와 `initialize` → `account/rateLimits/read` 순서를 유지
- app-server error detail의 secret-like 문자열은 `[REDACTED]` 처리
- legacy direct HTTP/auth-file 경로는 기본 비활성화이며 명시적으로 허용한 compatibility/test path에서만 동작
- 401/403 auth expired 상태에서 credential material 누출 없음
- malformed rate-limit payload는 low confidence
- connector ON이면 local JSONL보다 app-server limit hints snapshot 우선
- local JSONL token totals는 web-comparable history/export totals에서 제외

실제 Codex credential, OAuth, browser session, API key는 테스트에서 사용하지 않습니다.

---

## 메뉴바 기대값

현재 메뉴바는 5시간/주간 **남은 비율**을 짧게 보여주는 형식입니다.

```text
5h 64% · W 56%
5h 12% · W 38%
5h 64% · W 56% 추정
```

예전 `AI … CX:…` 형식은 legacy 문서 예시이며 현재 기준이 아닙니다.

---

## 남은 주의사항

- Limit Hints Connector는 비공식/internal endpoint에 의존하므로 변경될 수 있습니다.
- public release에서는 opt-in beta로 표시하고, 정확한 청구/비용 기능처럼 마케팅하지 않습니다.
- 실제 connector live 요청은 사용자 credential/명시 승인 없이는 수행하지 않습니다.
