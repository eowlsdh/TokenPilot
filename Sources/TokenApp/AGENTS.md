# TokenApp Knowledge

## OVERVIEW

`TokenApp`는 macOS 메뉴바 앱의 SwiftUI 레이어입니다. App lifecycle, popover 화면, ViewModel orchestration, 디자인 시스템, localization catalog를 소유하고 `TokenCore`를 조립합니다.

## STRUCTURE

```text
TokenApp/
├── TokenMonitorApp.swift         # @main, accessory app, MenuBarExtra
├── ViewModels/                   # TokenPilotViewModel
├── Views/                        # overview/history/settings/components
├── DesignSystem/                 # app-local visual tokens and glass components
└── Resources/                    # Localizable.xcstrings
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| app startup | `TokenMonitorApp.swift` | `NSApplication` accessory mode and menu-bar label |
| state/orchestration | `ViewModels/TokenPilotViewModel.swift` | refresh, settings, alerts, keychain commands |
| main screen | `Views/OverviewScreen.swift` | root view, picker screen switch, dashboard cards |
| history | `Views/HistoryScreen.swift` | charts, export copy, empty states |
| settings | `Views/SettingsScreen.swift` | provider setup, notification settings, privacy copy |
| reusable UI | `Views/Components.swift` | cards, status badges, charts, provider marks |
| styling | `DesignSystem/TokenPilotDesign.swift` | color, spacing, material, localization helper |
| strings | `Resources/Localizable.xcstrings` | UI string catalog |

## CONVENTIONS

- Keep `TokenMonitorApp.swift` thin; app behavior belongs in `TokenPilotViewModel` or `TokenCore`.
- `TokenPilotRootView` switches screens through `TokenPilotViewModel.Screen`; there is no route/router layer.
- UI code should use `TokenPilotDesign` colors/spacing/components instead of ad hoc styling.
- Numeric/menu-bar status text should stay compact and monospaced where already designed.
- `TokenPilotViewModel` can coordinate services, but pure parsing, persistence, and formatting logic should move to `TokenCore`.
- File-picker and source-selection flows must preserve bookmark handling through `TokenCore`.
- For visible text changes, update both `.xcstrings` and core fallback localization when applicable.

## ANTI-PATTERNS

- Do not expose saved Telegram/Discord secrets; SecureField placeholders and status labels should reveal presence only.
- Do not trigger provider refresh loops for settings changes unrelated to usage data.
- Do not show sample/mock usage as connected data.
- Do not turn menu-bar UI into a full dashboard surface; keep the popover compact and scan-friendly.
- Do not duplicate provider parsing or quota math in views.

## TEST EXPECTATIONS

- Add `Tests/TokenMonitorTests.swift` coverage for menu-bar title, localized copy, risk labels, UI-facing formatter behavior, and app-level regressions.
- For behavior rooted in `TokenPilotViewModel` but expressible as pure logic, prefer testing the `TokenCore` service extracted for it.
