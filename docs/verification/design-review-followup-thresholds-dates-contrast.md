# Design review follow-up: risk thresholds, date labels, tertiary contrast

**Date:** 2026-08-19

**Scope:** The first three fixes from the UI design review that followed benchmark round 5
(`docs/verification/benchmark-round5-statusline-gauge-wake.md`). The review read the design
tokens, the four SwiftUI screens, and the menu bar drawing code (9,181 lines) and found 19
issues; this pass closes the three highest-value ones. The remaining findings (type scale,
spacing/radius drift, Overview ordering, History card grouping, Settings numbering and
focus/tooltip coverage, menu bar label size and marker legend, hit targets) are untouched.

## 1. Risk thresholds were split across surfaces

**Found:** the popover and the accessibility status level warned from 70% used and turned
critical at 85% used, while the menu bar drawing and the status line warned from 50% used
(remaining ≤ 50) and turned critical at 80% used (remaining ≤ 20). Between 50% and 70% used,
the same window rendered amber in the menu bar and calm in the popover. "Healthy" also differed
in hue: `systemBlue` in the menu bar, the calm green everywhere else.

**Fixed:** `CapacityRisk.forUsedPercent` / `.forRemainingPercent`
(`Sources/TokenCore/Services/CapacityRiskThresholds.swift`) are now the only place a percentage
becomes a risk level, at the values the majority of the app already used (70 warning, 85
critical). Call sites routed through it:

| Surface | Before | After |
|---|---|---|
| `CapacityAssessmentService` | inline `used >= 85 / >= 70` | `CapacityRisk.forUsedPercent` |
| `MenuBarStatusService.statusLevel` | inline `>= 85 / >= 70` | `CapacityRisk.forUsedPercent` |
| `TokenPilotDesign.riskColor` | inline `>= 85 / >= 70` | `CapacityRisk.forUsedPercent` |
| `ProviderMetricsMenuBarNSView.valueColor` | `<= 20 systemRed / <= 50 systemOrange / systemBlue` | shared thresholds + `TokenPilotDesign.riskNSColor` |
| `StatuslineService.colorize` | `<= 20 red / <= 50 yellow / green` | shared thresholds |

The menu bar also stopped drawing with AppKit system colors: `TokenPilotDesign.riskNSColor`
exposes the app's own danger/warning/calm definitions as a dynamic `NSColor`, so the menu bar
now follows Increase Contrast like every other surface and uses the same hues. The percentage
is read from the rendered value through the existing `MenuBarGaugeService.remainingPercent`,
which the remaining-bar gauge already used, so both parse the block the same way.

**Behavior change to expect:** a window between 50% and 70% used now reads calm (green) in the
menu bar where it used to read amber. The user-configured alert thresholds (50 / 80 / 100) are a
separate, unchanged concern — they decide when a notification fires, not what color a block is.

## 2. History date labels were hard-coded to English

**Found:** three display formatters used `Locale(identifier: "en_US_POSIX")` with fixed patterns,
so the heatmap, the monthly trend, and the 5-hour blocks printed "Aug" and "Aug 19 14:00" in
every language the app ships (ko/ja/zh-Hans/zh-Hant). The `HH` pattern also forced a 24-hour
clock regardless of the user's preference. `en_US_POSIX` is correct for the `yyyy-MM-dd` storage
keys in the same file — it had been copied to the display path.

**Fixed:** `LocalizedDateLabels` (`Sources/TokenCore/Services/LocalizedDateLabels.swift`) builds
patterns with `DateFormatter.dateFormat(fromTemplate:)`, so each locale decides field order and
hour cycle (`j`). Call sites: `HistoryHeatmapCard.monthOfWeek`, `HistoryMonthlyTrendCard.monthName`,
`HistoryFiveHourBlocksCard.blockTimeText`. The locale comes from the app's language setting;
`.system` stays on `Locale.autoupdatingCurrent` so the Mac's region keeps deciding. Formatters are
cached by template + locale + time zone because chart labels re-format on every redraw.

## 3. Tertiary text failed the small-text contrast bar

**Found:** `textTertiary` measured 3.47:1 on cards and 3.01:1 on muted cards in light appearance,
and 4.44:1 / 4.05:1 in dark — below the 4.5:1 WCAG AA bar for the 10–11pt text it carries, in 27
places.

**Fixed:** the default light value moved from `rgb(0.520, 0.540, 0.590)` to
`rgb(0.408, 0.424, 0.464)` and the dark value from `rgb(0.478, 0.478, 0.518)` to
`rgb(0.526, 0.526, 0.570)`. Measured after the change:

| Appearance | card | cardElevated | cardMuted | background |
|---|---|---|---|---|
| light | 5.25 | 5.14 | 4.56 | 4.90 |
| dark | 5.25 | 5.04 | 4.79 | 5.51 |

The high-contrast variants were already well above the bar and are unchanged. The primary →
secondary → tertiary ramp still descends in both appearances, but the secondary/tertiary step is
now smaller (≈4 L\* in light) — that is the cost of holding the lightest step to 4.5:1, and it is
asserted by a test so it cannot silently invert.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean.
- `swift test`: 670 tests, 0 failures (656 before this pass).
- New: `Tests/DesignConsistencyTests.swift` — threshold boundaries and used/remaining symmetry
  across the full 0...100 range, the assessment pipeline and the status line resolving through the
  shared thresholds, localized month and day/time labels for en/ko/ja/zh with a fixed UTC calendar,
  `.system` following the Mac locale, and a contrast guard that reads the token values out of
  `TokenPilotDesign.swift` and asserts 4.5:1 for every text token on every surface in both
  appearances.
- Updated: the status line color-tier test now asserts the shared tiers (85 critical, 75 warning,
  60 calm) instead of the old 20/50 remaining split.

## Not covered

- Visual confirmation on a real menu bar and popover (the running app is built from
  `build/TokenPilot.app`; `make bundle` needs the app quit first).
- The other 16 review findings.
