# PROJECT KNOWLEDGE BASE

**Generated:** 2026-06-04
**Commit:** 8e0de08
**Branch:** main

## OVERVIEW

TokenPilot은 Claude Code, Codex, Gemini CLI 사용량과 한도 힌트를 macOS 메뉴바에서 보여주는 local-first SwiftUI 앱입니다. SwiftPM 패키지 `TokenMonitor`와 XcodeGen 기반 `TokenPilot.xcodeproj`를 함께 유지합니다.

## STRUCTURE

```text
TokenPilot/
├── Package.swift                 # SwiftPM: TokenCore, TokenApp, TokenTests
├── project.yml                   # XcodeGen: TokenCore framework + TokenPilot app
├── build.sh                      # build/TokenPilot.app 번들 생성
├── Sources/
│   ├── TokenCore/                # 모델, 파싱, 집계, 저장, 보안/경로 로직
│   └── TokenApp/                 # SwiftUI 앱, ViewModel, 디자인 시스템, 리소스
├── Tests/                        # TokenCore 중심 XCTest 회귀 테스트
├── Resources/                    # 앱 plist, entitlements, privacy manifest, icon
├── Scripts/                      # 보조 생성 스크립트
└── docs/                         # 배포/검증/상업화 작업 기록
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| 앱 시작/메뉴바 | `Sources/TokenApp/TokenMonitorApp.swift` | `@main`, `MenuBarExtra`, 420x620 popover |
| 화면 전환/상태 | `Sources/TokenApp/ViewModels/TokenPilotViewModel.swift` | refresh, settings debounce, keychain, alerts |
| 주요 UI | `Sources/TokenApp/Views/` | `OverviewScreen`, `HistoryScreen`, `SettingsScreen`, `Components` |
| 디자인 토큰 | `Sources/TokenApp/DesignSystem/TokenPilotDesign.swift` | palette, spacing, glass, status colors |
| 도메인 모델 | `Sources/TokenCore/Models/TokenPilotModels.swift` | provider, event, snapshot, settings |
| provider 파싱 | `Sources/TokenCore/Services/DataSourceAdapters.swift` | Claude/Codex/Gemini ingestion hotspot |
| 서비스 조립 | `Sources/TokenCore/Services/TokenPilotServices.swift` | settings, mock data, usage store, keychain |
| 경로/권한 | `Sources/TokenCore/Services/DefaultPathResolver.swift`, `SecurityScopedBookmarks.swift` | local source detection and scoped access |
| 메뉴바 문구 | `Sources/TokenCore/Services/MenuBarStatusService.swift` | compact status, risk level, accessibility |
| localization | `Sources/TokenCore/TokenPilotLocalization.swift`, `Sources/TokenApp/Resources/Localizable.xcstrings` | runtime fallback + string catalog |
| tests | `Tests/TokenPilotServicesTests.swift`, `Tests/TokenMonitorTests.swift` | parsing/store contracts and menu-bar/UI copy |
| bundle metadata | `Resources/Info.plist`, `Resources/PrivacyInfo.xcprivacy`, `Resources/TokenPilot.entitlements` | Xcode/build.sh shared inputs |

## CODE MAP

| Symbol | Type | Location | Role |
|--------|------|----------|------|
| `TokenMonitorApp` | `App` | `Sources/TokenApp/TokenMonitorApp.swift` | menu-bar app entry |
| `TokenPilotViewModel` | `@MainActor ObservableObject` | `Sources/TokenApp/ViewModels/TokenPilotViewModel.swift` | app orchestration |
| `TokenPilotDesign` | enum namespace | `Sources/TokenApp/DesignSystem/TokenPilotDesign.swift` | app visual language |
| `ProviderSnapshot` / `UsageEvent` / `AppSettings` | models | `Sources/TokenCore/Models/TokenPilotModels.swift` | shared data contracts |
| `UsageStore` | service | `Sources/TokenCore/Services/TokenPilotServices.swift` | adapter refresh and mock fallback |
| `ClaudeStatuslineAdapter` | adapter | `Sources/TokenCore/Services/DataSourceAdapters.swift` | Claude statusline/JSONL parsing |
| `GeminiTelemetryAdapter` | adapter | `Sources/TokenCore/Services/DataSourceAdapters.swift` | Gemini telemetry/session parsing |
| `CodexLocalSessionAdapter` | adapter | `Sources/TokenCore/Services/DataSourceAdapters.swift` | Codex local JSONL parsing |
| `CodexWebUsageAdapter` | adapter | `Sources/TokenCore/Services/DataSourceAdapters.swift` | opt-in Codex limit hints |
| `TokenPilotLocalizer` | localization | `Sources/TokenCore/TokenPilotLocalization.swift` | localized fallback resolver |

## CONVENTIONS

- `TokenApp` may import `TokenCore`; `TokenCore` must stay free of SwiftUI/AppKit UI dependencies.
- SwiftPM product name is `TokenMonitor`; user-facing app/bundle name is `TokenPilot`. Do not “normalize” this split casually.
- The macOS floor is **26.0**, declared once in `project.yml` (`deploymentTarget.macOS`). `Package.swift` states it as `.macOS("26.0")` — the string form, because the `.v26` enum case is not in this toolchain's PackageDescription — and `build.sh` reads it for `LSMinimumSystemVersion`. A test asserts the two agree; do not add a third place.
- Use `Makefile` targets as the local command surface. `build.sh` is part of the product path, not a disposable helper.
- Keep `build/`, `.build/`, `DerivedData/`, and generated app bundles out of source edits.
- For user-visible copy, update both localization surfaces when needed: Swift fallback table and `.xcstrings`.
- New provider/source behavior belongs in `TokenCore` first, then the ViewModel/UI wires it in.

## ANTI-PATTERNS (THIS PROJECT)

- Do not read, print, export, log, or document provider credentials, browser cookies, OAuth tokens, API keys, Telegram bot token values, or Discord webhook values.
- Do not present Codex local JSONL activity as official web quota, billing, or exact remaining quota.
- Do not enable Codex app-server limit hints without explicit user opt-in.
- Do not include raw prompts/responses, local source paths, chat IDs, webhooks, or secret values in export payloads.
- Do not make sample/mock data look like real usage; labels such as `MOCK`, `manual`, `est.`, `EXPERIMENTAL`, and `UNOFFICIAL` matter.

## UNIQUE STYLES

- UI is a compact premium macOS utility, not a marketing dashboard.
- Korean UI should use the workspace design guidance: Pretendard preference, JetBrains Mono for numbers, Korean semantic colors when applicable.
- Current app palette is intentionally dark/neutral with provider accents and risk colors from `TokenPilotDesign`.
- Menu-bar text is tight and monospaced; preserve `monospacedDigit()` and short status labels.

## COMMANDS

```bash
make build
make build-strict
make test
make bundle
make verify
xcodegen generate
xcodebuild -project TokenPilot.xcodeproj -scheme TokenPilot -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## NOTES

- `TokenPilotServicesTests.swift` is the largest safety net; provider parsing changes usually need coverage there.
- `TokenPilotViewModel.swift` is intentionally broad orchestration. Prefer moving pure logic into `TokenCore` when adding behavior.
- `DataSourceAdapters.swift` has process spawning, JSON parsing, dedupe, redaction, and forbidden credential-path checks in one file. Read nearby tests before changing it.
- `.github/workflows/ci.yml` mirrors local strict build, tests, Xcode generation/build, bundle creation, and bundle smoke checks.
