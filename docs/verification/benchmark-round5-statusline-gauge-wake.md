# Benchmark Round 5: terminal status line, menu bar gauge, wake refresh

**Date:** 2026-08-19

**Scope:** Fifth benchmarking pass against current macOS menu bar usage monitors and CLI
usage trackers, followed by implementation. Extends
`docs/verification/benchmark-gap-analysis.md` (round 1),
`benchmark-round2-cli-hotkey-refresh.md`, and `benchmark-round3-goal-digest.md`.

Round 4 was the usagepal provider expansion (commits `aadc989`, `5598431`: JetBrains AI local
quota cache, MiniMax/Z.ai/OpenRouter APIs, consent-gated Claude/Codex/Grok probes). It shipped
without its own verification note; this document does not restate it.

## 1. Benchmarked this round

| Tool | Format | Patterns taken / rejected |
|------|--------|---------------------------|
| [ccusage](https://ccusage.com/guide/blocks-reports) | CLI | `statusline` replaced the removed `blocks --live` monitor in v18; a status line command is now the primary live surface. **Taken.** |
| ccstatusline | Claude Code status line | Composable status line segments (model, context, reset timer). **Taken as `--components`.** |
| [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) | menu bar | Five icon display styles (battery, progress bar, percentage only, icon+bar, compact); wake-from-sleep auto refresh with debouncing; terminal statusline integration. **Bar style and wake refresh taken**; battery/notch HUD rejected. |
| [ClaudeBar](https://github.com/tddworks/ClaudeBar) | menu bar | Color-coded quota bars, ⌘R/⌘D shortcuts, iTerm2 theme import. Bars taken; shortcuts already existed (⌘R, ⌘1/⌘2/⌘3); theme import rejected as cosmetic. |
| [AgentPeek](https://agentpeek.app/menu-bar/) | menu bar | Live gauges with "resets in" countdowns. Already covered by capacity cards and the new status line countdown. |
| tokencap (round 1) | CLI | Three-tier color thresholds. Reused for the status line's ANSI colors — later re-based on the app's own risk thresholds, see `design-review-followup-thresholds-dates-contrast.md`. |

Rejected again this round, unchanged from rounds 2–3: multi-profile accounts, notch/Dynamic
Island HUD, theme import, and any receipt-sharing backend (violates the local-first stance).

## 2. Verified gaps and what closed them

| # | Gap | Status |
|---|-----|--------|
| 1 | No editor status line surface — the flagship 2026 pattern in this category | Closed: `TokenPilot statusline` |
| 2 | Menu bar gauge/bar variant deferred for visual QA in rounds 2 and 3 | Closed: `MenuBarTrendStyle` (trend line / remaining bar / none) |
| 3 | Sleeping the Mac left pre-sleep percentages and elapsed reset countdowns on screen until the next tick | Closed: wake observer + `WakeRefreshGate` |
| 4 | ⌘R refresh and ⌘1/⌘2/⌘3 navigation | Already implemented; no change |

## 3. Implemented

1. **`TokenPilot statusline`** (`Sources/TokenCore/Services/StatuslineService.swift`,
   `TokenPilotCLIService` parse/help, `TokenMonitorApp` dispatch)
   - Renders one line: `model | quota | today | cost` by default.
   - `--components` picks and orders segments from `model,capacity,today,cost,block,burn,session`;
     `--provider` scopes the capacity segment and local totals; `--timezone` decides which day
     `today` and the 5-hour block belong to; `--no-color` (and `NO_COLOR`) drop ANSI colors.
   - Reads the caller's session JSON from stdin **only when stdin is a pipe** (`isatty` check), so
     a manual terminal run does not block. From that payload it uses the model display name and
     session cost and nothing else — session ids, workspace dirs, and transcript paths are ignored.
   - Capacity honesty: only provider-reported, comparable percent windows can be shown as quota.
     Evidence past its freshness policy is marked `·S` (the menu bar's stale marker) instead of
     being printed as a current number or silently dropped.
   - Composition with the existing Claude bridge: set the command as `statusLine` first, then
     install **Settings → Setup Guide → Connect Claude Code**. The bridge records Claude's limits
     and chains to the previously configured command, so both keep working.
2. **Status line snapshot** (`Sources/TokenCore/Services/StatuslineSnapshotStore.swift`,
   `TokenPilotViewModel.writeStatuslineSnapshot`)
   - A status line runs on every prompt, and decoding the capacity evidence store (3.8 MB on the
     development machine) cost ~0.52 s per call. The app now writes the handful of fields a status
     line needs after each refresh; the CLI reads that and falls back to the full evidence store
     only when the snapshot is missing, unreadable, or from a newer schema.
   - Freshness is re-evaluated at render time from `observedAt` + the window's own freshness policy,
     so a snapshot written before the app quit reports `·S`, not a current value.
   - Payload is provider ids, window ids, percentages, and timestamps; asserted free of paths,
     project labels, and parser revisions.
3. **Menu bar trend style** (`MenuBarTrendStyle`, `AppSettings.menuBarTrendStyle`,
   `MenuBarGaugeService`, `ProviderMetricsMenuBarNSView.drawBar`)
   - Settings → menu bar layout (provider metrics) gains **Trend line / Remaining bar / No trend**.
     Default stays `sparkline`, so existing menu bars are unchanged.
   - The bar reads the percentage back out of the value the block already renders, so non-percent
     readouts (money, credits, `Setup`, `—`) draw no bar and cannot look like a quota gauge.
4. **Wake-from-sleep refresh** (`WakeRefreshGate`, `NSWorkspace.didWakeNotification` observer,
   `RefreshReason.systemWake`)
   - Refreshes immediately on wake unless a refresh finished in the last 30 seconds, which also
     collapses the several wake notifications macOS can post for one wake. The observer is removed
     on terminate.
5. **Localization**: eight new UI strings in both surfaces (`Localizable.xcstrings` and the Swift
   supplemental fallback) across en/ko/ja/zh-Hans/zh-Hant. The catalog was edited by appending
   entries as text — the file contains duplicate JSON keys, so re-serializing it would silently
   drop them.
6. **Docs**: README.md and README.ko.md gained the `statusline` section, the trend/bar feature row,
   and the wake-refresh note.

## 4. Verification

- `swift build -Xswiftc -warnings-as-errors` clean.
- `swift build -c release` clean.
- `swift test`: 656 tests, 0 failures (was 612 before this pass). New coverage: stdin contract
  parsing and degradation, component list parsing, segment rendering and ordering, tightest-window
  selection, stale marking, activity-only rejection, ANSI tiers, redaction assertions,
  countdown/window-label formatting, capacity-window mapping and freshness, snapshot store
  round-trip/schema/redaction, CLI parse and help contract, gauge percentage extraction, wake gate
  boundaries, and settings default/legacy-decode/round-trip.
- CLI smoke: `help`, `summary`, `export --period today`, `stats`, `blocks` all exit 0 unchanged;
  `statusline` renders with and without piped stdin; `statusline --components bogus` exits 2 with
  usage on stderr; `NO_COLOR=1` suppresses escape codes.
- Latency, development machine, same binary and same store: **0.52–0.71 s** falling back to the
  evidence store, **0.04–0.07 s** with the snapshot present.
- `Localizable.xcstrings` parses as valid JSON after the append; the added keys resolve in all five
  locales through both the catalog and the runtime fallback.

### Not run

- `make bundle` / `make verify` were **not** run: TokenPilot is currently running from
  `build/TokenPilot.app` on this machine, and `build.sh` copies the freshly built executable over
  that same path. Run `make bundle` after quitting the running app.
- Visual QA of the remaining-bar style on a real menu bar is still pending. The geometry is
  covered by unit tests and the style is opt-in, so the default rendering is unaffected.

## 5. Follow-up candidates (not in this pass)

- Menu bar gauge **ring/arc** variant (the bar closes most of the gap; a ring still needs visual QA).
- Custom alert thresholds (benchmarks use 75/90/95; TokenPilot has reset/50/80/100). Touches
  persisted alert rules and delivery dedupe state, so it deserves its own pass.
- Status line segment for context window usage, once a provider exposes it in a comparable form.
