# Benchmark Round 3: daily goal and weekly digest

**Date:** 2026-08-07

**Scope:** Third benchmarking pass. Patterns taken from habit/usage trackers (Streaks-style
daily goals) and weekly report conventions in usage dashboards (Apple Screen Time, weekly
receipt emails from CLI trackers).

## Implemented

1. **Daily goal progress** (`Sources/TokenCore/Services/DailyGoalService.swift`,
   `Sources/TokenApp/Views/OverviewScreen.swift`)
   - Wires the previously dormant `AppSettings.challengeTargetTokens` (default 10,000) into a
     new Overview card: today's local tokens vs target with a progress bar and honest
     "Local activity, not provider quota" caption. Settings > General gained a Stepper for the
     target; the store clamps it to >= 1.
2. **Weekly digest notification** (`Sources/TokenCore/Services/WeeklyDigestService.swift`,
   `Sources/TokenApp/ViewModels/TokenPilotViewModel.swift`)
   - New opt-in setting `weeklyDigestEnabled` (default off, gated on Global + macOS
     notifications). Every Monday 09:00–10:00 local time, while the app is running, it sends a
     week-to-date summary (total tokens, requests, estimated cost, top provider) through the
     existing `LocalNotificationService`. `WeeklyDigestGate` computes the Monday window
     explicitly from the weekday (independent of the calendar's firstWeekday), and
     `WeeklyDigestStore` persists the last-sent timestamp so it fires once per week.
   - The digest body is aggregates-only (no raw sources, model names, or project labels) and
     localized through `TokenPilotLocalizer`.

## Verification

- `swift test`: 434 tests, 0 failures (new: goal percent math, digest fire-window boundaries,
  week-to-date aggregation + redaction, Korean digest labels, store roundtrip, settings
  default/decode/clamp).
- `swift build -Xswiftc -warnings-as-errors` clean.
- `Localizable.xcstrings` parses as valid JSON; all new strings added to both catalog and
  Swift fallback (en/ko/ja/zh-Hans/zh-Hant).

## Not selected (unchanged from round 2)

- Menu bar gauge ring variant (needs visual QA).
- Kiro-native JSON export (requires Kiro cooperation).
- Receipt-sharing backend (violates local-first stance).
