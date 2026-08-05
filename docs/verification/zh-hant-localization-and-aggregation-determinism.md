# zh-Hant Localization Parity and Aggregation Determinism Work Log

**Status:** Working-tree verification artifact (not a release evidence artifact). Documents uncommitted work-in-progress across two sessions: (1) zh-Hant localization parity, (2) time-anchored aggregation determinism.

**Commit baseline:** `272e596` "Remove duplicate assertions" (HEAD at time of writing).

## Scope

All changes below are uncommitted on `main`. They build on prior committed CI-hardening work and add:

1. **zh-Hant (繁體中文) localization parity** — runtime fallback table, string catalog, formatters, and test assertions.
2. **Deterministic aggregation** — injectable `now` so tests do not flake across day/month boundaries.
3. **Runtime-hardening refactors** that removed dead models and precondition failures.

## 1. zh-Hant localization parity

### Language enum (`Sources/TokenCore/Models/TokenPilotModels.swift`)

- Added `case zhHant = "zh-Hant"` to `TokenPilotLanguage` between `zhHans` and `ja`.
- Added `displayName` value `"繁體中文"` and `localeID` value `"zh-Hant"`.

### Formatters (`Sources/TokenCore/Services/TokenPilotServices.swift`)

- Remaining-time formatter: added `case .zhHant` with units `("小時", "分鐘")`.
- `TokenPilotFormatters` locale mapping: added `case .zhHant: return "zh_Hant_TW"`.

### Runtime fallback table (`Sources/TokenCore/TokenPilotLocalization.swift`)

- Added `.zhHant` as a fifth locale across ~349 translation entries (all user-visible strings now carry a Traditional Chinese value in the fallback dictionary, matching the existing ko/ja/zhHans/en coverage).
- Confirmed row parity for the strings exercised by tests (e.g. line 1365 `Codex legacy capacity alerts are unsupported for delivery.`).

### String catalog (`Sources/TokenApp/Resources/Localizable.xcstrings`)

- Added `zh-Hant` string units for 15 keys (catalog locale set, placed after `zh-Hans` to preserve ordering):
  - `Auto-detected sources: %@` → `已自動檢測到來源：%@`
  - `Choose Claude source` → `選擇 Claude 數據源`
  - `Choose Claude statusline JSON or a .claude/projects folder.` → `選擇 Claude statusline JSON 或 .claude/projects 文件夾。`
  - `Connection check complete.` → `連接檢查完成。`
  - `Detected` → `已檢測`
  - `Detected paths` → `檢測到的路徑`
  - `Export Usage` → `導出使用量`
  - `Exported` → `已導出`
  - `Invalid format` → `格式無效`
  - `Run Check Connection to scan local paths.` → `運行檢查連接以掃描本地路徑。`
  - `Settings overview` → `設置概覽`
  - `Privacy and provider truth` → `隱私與數據來源`
  - `Expanded` → `已展開`
  - `Collapsed` → `已折疊`
  - `Codex legacy capacity alerts are unsupported for delivery.` → `Codex 舊版容量提醒不支持投遞。`
- Re-exported with `ensure_ascii=False, indent=2`; all 15 keys verified non-empty via JSON check.

### Tests (`Tests/TokenMonitorTests.swift`)

- `testViewModelFollowUpLocalizationKeysHaveFourLocaleParityAndObsoleteKeysAreAbsent`: added `.zhHant` entries to the 10-key parity list; asserted catalog lookup via `catalogStrings[key]["localizations"]["zh-Hant"]`.
- `testSettingsDisclosurePolishCopyIsLocalized`: added `.zhHant` assertions for `Settings overview`, `Privacy and provider truth`, `Expanded`, `Collapsed`.
- `localizedModes` in the mode-key coverage test: widened tuple to 5 languages and added zhHant values (LIVE→實時, LOCAL→本地, MANUAL→手動, EXPERIMENTAL→實驗性, BRIDGE→橋接, MOCK→模擬, STALE→過期).
- `nonEnglishCopies` for capacity runtime recovery: added `(.zhHant, "需要恢復容量運行時；安全默認值已啓用。")`.
- `expectedCopies` for Codex legacy capacity: added `(.zhHant, "zh-Hant", "Codex 舊版容量提醒不支持投遞。")`.

## 2. Deterministic aggregation (`now` injection)

### `Sources/TokenCore/Services/AggregationService.swift`

- `aggregate(snapshots:period:now: Date = Date())` — `now` threaded through `filterEvents` and `sevenDayBars` instead of calling `Date()` internally. Default parameter keeps existing call sites source-compatible.

### Tests

- `Tests/OpenCodeKiroAdapterTests.swift` (`SevenDayTrendTests`, `DebugFixtureFreshnessTests`): capture a single `now`, pass it to `event(daysAgo:relativeTo:)` and to `aggregate(..., now:)` so bar coverage and "today is trailing bar" assertions are stable regardless of run time.
- `Tests/TokenPilotServicesTests.swift`:
  - Gemini monthly-aggregation test anchors `now` just past the last of 130 events.
  - `testAggregationPeriodsChangeWhenHistoryContainsOlderEvents` uses a fixed calendar date (2026-08-15 12:00) instead of `Date()`.
  - Other period-based tests pass explicit `now` to keep `.today`/`.last7Days`/`.thisMonth` boundaries deterministic.
  - Two menu-bar status tests pin `settings.localization.language = .en` so assertions do not depend on the ambient locale.

## 3. Runtime-hardening refactors

### Removed dead models (`Sources/TokenCore/Models/TokenPilotModels.swift`)

- Removed `ChallengeGoal`, `ChallengeProgress`, `NotificationChannel`, and `XAIProvenancedAssessment` (unused; the experimental provenance capability token remains internal-only).

### `Sources/TokenCore/Services/CapacityPresentationMapper.swift`

- Replaced `preconditionFailure(...)` on invalid capacity payloads with `if let` guards that leave `data` without the missing key. Presentation never crashes the app on malformed capacity observations.

### `Sources/TokenCore/Services/TokenPilotServices.swift`

- Minor addition only: the zhHant formatter cases above.

## Verification

Baseline compile of the test target is blocked on a missing full Xcode when `xcode-select` points at Command Line Tools (`no such module 'XCTest'`), reproduced identically on clean HEAD. Verified successfully with the external Xcode:

```bash
export DEVELOPER_DIR=/Volumes/OWC_1M2/Applications/Xcode.app/Contents/Developer
swift test --filter TokenMonitorTests   # 81 tests, 0 failures
swift test                              # 389 tests, 0 failures
```

Catalog check: 15 keys with `zh-Hant`, all values non-empty (`python3` JSON validation).

## Notes / boundary

- All strings remain local to the app; no provider credentials, browser cookies, OAuth tokens, or API keys are read, printed, logged, or committed by this work.
- Codex local JSONL activity is still never presented as official web quota, billing, or exact remaining quota (menu-bar tests keep `.en` pinning).
- Generated `TokenPilot.xcodeproj` is not regenerated by this work; no `project.yml` changes were made.
