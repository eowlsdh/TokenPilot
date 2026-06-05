# TokenPilot — Codex 비용/한도 표시 한계

**문서 상태**: current note  
**마지막 갱신**: 2026-05-21 KST  
**관련 공개 문서**: [`README.md`](README.md), [`docs/PRIVACY.md`](docs/PRIVACY.md), [`SECURITY.md`](SECURITY.md)

> 이전 문서의 `TokenMonitor`, `CodexParser.swift`, `AITokenTypes.swift`, 5초 타이머 기준 설명은 현재 구조와 맞지 않아 제거했습니다.

---

## 1. 왜 Codex 비용을 정확 비용처럼 표시하지 않나요?

Codex 로컬 session/log에서 안정적으로 얻을 수 있는 값은 공식 청구/한도 API의 전체 근거가 아닙니다. 특히 local JSONL의 token-like row는 **web quota와 1:1 대응되는 공식 지표가 아니며**, 실제 청구 비용/잔여 quota를 확정하기에는 부족합니다.

TokenPilot의 현재 정책:

- Codex 비용은 공식 토큰/단가/청구 출처가 안정적으로 확인될 때까지 정확 비용처럼 표시하지 않습니다.
- local activity는 `EXPERIMENTAL`, `Local log`, `Not web quota`, `est.` 맥락으로만 표시합니다.
- 사용자가 웹 또는 CLI `/status`에서 본 값을 직접 입력하면 `manual`/`medium` confidence로만 다룹니다.
- Codex Limit Hints Connector는 기본 OFF이며, 사용자가 명시적으로 켠 경우에만 비공식 한도 힌트 조회를 시도합니다.

---

## 2. 현재 Codex 데이터 경로

| 경로 | 기본 상태 | 용도 | 신뢰도/표시 |
|---|---:|---|---|
| Manual `/status` paste | 사용 가능 | 사용자가 본 5h/weekly 값 입력 | manual / medium 이하 |
| Manual Limit Snapshot | 사용 가능 | 사용자가 웹에서 본 값 직접 입력 | manual |
| Local Activity JSONL | 사용 가능 | 로컬 세션의 token_count 계열 실험 파싱 | experimental / not web quota |
| Limit Hints Connector | OFF | opt-in 비공식 한도 힌트 조회 | endpoint/auth 변화 시 low confidence |

---

## 3. UI/문서 표현 원칙

TokenPilot은 Codex 화면에서 다음을 지켜야 합니다.

- `est.` 또는 `manual` label 없이 Codex 한도/비용을 확정값처럼 보이지 않게 합니다.
- Codex local activity는 `Not web quota` 맥락을 붙입니다.
- 비용/토큰이 없으면 “없음”이 아니라 “공식 비용으로 계산할 근거 부족”으로 설명합니다.
- Limit Hints Connector는 “unofficial/opt-in/may break”를 함께 표시합니다.
- token/access token 값을 UI, export, log, 문서에 표시하지 않습니다.

---

## 4. 관련 현재 파일

- `Sources/TokenCore/Services/DataSourceAdapters.swift` — Codex manual/local/limit-hints adapter
- `Sources/TokenCore/Models/TokenPilotModels.swift` — `CodexManualSettings`, `ProviderSnapshot`, confidence 모델
- `Sources/TokenCore/Services/UsageExportService.swift` — export sanitization
- `Sources/TokenApp/TokenMonitorApp.swift` — Settings/Overview Codex copy and controls
- `Tests/TokenPilotServicesTests.swift` — Codex parser, local activity, connector failure-state, export sanitization tests
- `README.md` / `README.ko.md` — public positioning and install guidance

---

## 5. 결론

현재 TokenPilot 설계는 “Codex 비용 계산 기능 없음”이 아니라, **불확실한 Codex 비용/한도를 확정값처럼 과장하지 않는 설계**입니다. 사용자가 직접 본 값과 실험적 local activity는 도움 정보로 제공하되, 공식 quota/billing과 혼동되지 않도록 계속 분리해야 합니다.
