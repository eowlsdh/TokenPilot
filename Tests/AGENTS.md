# Tests Knowledge

## OVERVIEW

`Tests`는 SwiftPM test target `TokenTests`입니다. 현재 초점은 `TokenCore` contract, parsing, persistence, export/privacy, localization/menu-bar copy 회귀 보호입니다.

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| core services/adapters | `TokenPilotServicesTests.swift` | largest suite; parsing, stores, keychain, export |
| model/menu-bar/localization | `TokenMonitorTests.swift` | compact formatter, copy, provider snapshot behavior |
| keychain tests | `TokenPilotServicesTests.swift` | `InMemoryKeychainBackend`; avoid real secrets |
| Codex fixtures | `TokenPilotServicesTests.swift` | JSONL lines, app-server payloads, status text |
| filesystem tests | `TokenPilotServicesTests.swift` | temp dirs/files and bookmark access |

## CONVENTIONS

- Use `@testable import TokenCore`; the test target does not depend on `TokenApp`.
- Prefer deterministic inline fixtures, temp directories, in-memory backends, and explicit timestamps.
- Keep provider/network tests local. Do not require live Claude/Codex/Gemini accounts.
- Preserve privacy assertions: secret redaction, export exclusions, local-path exclusions, and mock/manual/experimental labels.
- When changing model defaults or decode normalization, add regression tests for empty/legacy JSON payloads.
- When changing aggregation, assert both totals and derived chart/provider-share outputs.

## ANTI-PATTERNS

- Do not print real auth files, token values, webhook URLs, chat IDs, or credential payloads in tests or failure messages.
- Do not weaken tests around commercial defaults, mock-data labeling, or Codex quota uncertainty.
- Do not make tests depend on the current user’s real local provider logs.
- Do not replace temp-file isolation with writes into app/user data locations.

## COMMANDS

```bash
make test
swift test
make build-strict
```
