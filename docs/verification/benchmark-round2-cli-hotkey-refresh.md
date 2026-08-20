# Benchmark Round 2: CLI, refresh cadence, copy, and global shortcut

**Date:** 2026-08-07

**Scope:** Second benchmarking pass against popular AI usage trackers and macOS menu bar
utilities, followed by implementation. Extends the gap list from
`docs/verification/benchmark-gap-analysis.md` (ccusage, toktrack, tokencap, Kiro,
claude-status-macos-menu-bar).

## Benchmarked patterns and what we took

| Source | Pattern | TokenPilot outcome |
|--------|---------|--------------------|
| ccusage / toktrack | Non-interactive CLI JSON output | `TokenPilot export [--format json\|csv] [--period ...] [--out ...]` |
| toktrack | Quick receipt-style text output | `TokenPilot summary` + menu bar "Copy summary" |
| tokencap | Configurable polling interval | `AppSettings.refreshIntervalSeconds` (15s–15min, default 60s) |
| iStat Menus / Stats / Bartender | Global hotkey to open the menu bar UI | Opt-in ⌘⇧Space Carbon hotkey |
| Menu bar utility conventions | Right-click context actions | Copy summary in the status item context menu |

Web search was rate-limited during this pass, so the benchmark table above is based on the
in-repo gap analysis plus known public behavior of the listed tools (CLI JSON, 60s polling,
tier colors, hotkeys). Claims about TokenPilot behavior below were verified by building and
running the artifact, not assumed.

## Implemented

1. **CLI export and summary** (`Sources/TokenCore/Services/TokenPilotCLIService.swift`,
   `Sources/TokenApp/TokenMonitorApp.swift` entry dispatch)
   - `TokenPilot export` (JSON/CSV, `today`/`last7Days`/`thisMonth`, stdout or `--out`).
   - `TokenPilot summary` prints aggregates-only text.
   - CLI path never initializes AppKit and never reads provider credentials; export reuses
     `UsageExportService` (same redaction as GUI export).
2. **Configurable auto-refresh** (`AppSettings.refreshIntervalSeconds`,
   `TokenPilotSettingsStore` clamp 15...900, ViewModel timer, Settings picker)
   - Default 60s; the 1s menu bar tick (live countdowns) is unchanged.
3. **Copy summary** (`TokenPilotViewModel.copyUsageSummaryToPasteboard` + context menu item)
   - Same aggregates-only text as the CLI summary, localized to the app language.
4. **Global shortcut** (`AppSettings.menuBarHotkeyEnabled`, Carbon `RegisterEventHotKey`)
   - Opt-in ⌘⇧Space toggles the popover; unregistered on disable/terminate.
5. **Menu bar sparkline** (`MenuBarSparklineService`,
   `MenuBarProviderMetricSegment.sparklineValues`, `ProviderMetricsMenuBarNSView`)
   - Provider-metrics blocks now draw a 3px remaining-percent trend line from the stored
     5-minute limit samples for the same window kind as the displayed value (max 24 points,
     oldest first, empty until two samples exist).
6. **CLI `--capacity`** — `TokenPilot export --capacity` appends the latest stored capacity
   evidence per series (loaded from `CapacityEvidenceStore`, assessed with
   `CapacityAssessmentService`) to the JSON payload's `capacity` section.
7. **Localization**: all new UI/CLI strings added to `Localizable.xcstrings` and the Swift
   supplemental fallback (en/ko/ja/zh-Hans/zh-Hant), plus README/README.ko CLI docs.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean.
- `swift test`: 428 tests, 0 failures (CLI parse/help/summary/export contract incl. `--capacity`,
  capacity line in summary text, sparkline normalization/capping/window mapping, menu bar
  segment sparkline wiring, refresh-interval clamp, legacy settings decode).
- CLI smoke: `summary`, `export --format json|csv` run to exit 0; unknown command exits 2
  with usage on stderr; `help` exits 0.
- `Localizable.xcstrings` parses as valid JSON.

## Remaining candidates (not in this pass)

- Menu bar gauge ring / arc variant of the sparkline (visual QA on real menu bar still pending).
- Kiro-native JSON export (requires Kiro cooperation; out of scope).
- Receipt-sharing backend (violates local-first stance; not selected).
