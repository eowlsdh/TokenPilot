# TokenCore Knowledge

## OVERVIEW

`TokenCore`는 TokenPilot의 UI 없는 도메인 레이어입니다: 모델, provider 파싱, 집계, 저장, 경로 탐색, security-scoped bookmark, export, menu-bar status 계산을 소유합니다.

## STRUCTURE

```text
TokenCore/
├── Models/                       # Codable/Sendable domain contracts
├── Services/                     # adapters, stores, path/security/export/status services
└── TokenPilotLocalization.swift  # runtime localization fallback
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| provider/settings 모델 | `Models/TokenPilotModels.swift` | `Provider`, `UsageEvent`, `ProviderSnapshot`, `AppSettings` |
| provider 선택 | `Models/ProviderSelectionModels.swift`, `Models/AppSettings+Providers.swift` | enablement and selection helpers |
| Claude/Codex/Gemini parsing | `Services/DataSourceAdapters.swift` | largest/highest-risk file |
| Codex pasted status | `Services/CodexStatusParser.swift` | manual status parsing |
| aggregation | `Services/AggregationService.swift` | usage metrics and chart inputs |
| history stores | `Services/UsageHistoryStore.swift`, `Services/LimitHistoryStore.swift` | persisted local history |
| connection checks | `Services/DataSourceConnectionService.swift`, `Services/DefaultPathResolver.swift` | default paths and source status |
| bookmark access | `Services/SecurityScopedBookmarks.swift` | read-only scoped resources |
| export | `Services/UsageExportService.swift` | privacy-sensitive payload generation |
| status string | `Services/MenuBarStatusService.swift` | menu bar title/accessibility |
| core services | `Services/TokenPilotServices.swift` | settings store, usage store, alerts, keychain |

## CONVENTIONS

- Keep this target independent from `TokenApp`; no SwiftUI view logic here.
- Public model/service types should stay `Sendable` where current call sites rely on concurrency safety.
- Services that use `UserDefaults`, keychain, or mutable state use explicit locking or actor-safe boundaries; follow the existing pattern.
- Provider adapters return `ProviderSnapshot` with confidence/source labels that make uncertainty visible.
- Normalize decoded settings and legacy payloads at the boundary instead of forcing UI callers to patch missing fields.
- Prefer shared JSON helpers in `JSONValueExtractors.swift` for loose provider payloads.

## ANTI-PATTERNS

- Do not add credential-file scanning unless `isForbiddenCredentialPath` and the privacy docs allow it.
- Do not surface raw Codex app-server errors without redaction.
- Do not include local paths, credentials, webhook/chat IDs, prompt text, or response text in export payloads.
- Do not make manual/local/estimated Codex values web-quota comparable.
- Do not bypass `SecurityScopedBookmarks` for user-selected files or directories that need sandbox-safe access.

## TEST EXPECTATIONS

- Add or update `Tests/TokenPilotServicesTests.swift` for adapter, parser, persistence, export, keychain, and settings changes.
- Use fixture strings/temp directories/in-memory services; avoid live provider calls and real credentials.
- Preserve edge-case tests for stale data, duplicate Codex events, secret redaction, and official total overrides.
