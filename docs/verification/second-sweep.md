# Second sweep: what the first one left, and three areas it never read

**Date:** 2026-09-24

The first sweep (`cpu-and-correctness-sweep.md`) confirmed 40 findings and fixed about half. This
pass fixed the verified remainder, then sent three fresh read-only investigations into areas the
first never covered — the other provider adapters, the stores and alert engine, and the
menu bar/CLI/export paths. Every finding below was re-read in the code before it was touched, and
every guard was checked by putting the defect back.

## Figures that were wrong

| Defect | Effect |
|---|---|
| Weekly and monthly budgets, streak and lifetime milestones read `overviewUsage` — the **Today** aggregate | 200k a day against a 1M week read 20% on Friday; weekly/monthly budget alerts could not fire. Found independently by two investigators |
| Weekly budget cycle named `year + weekOfYear` under a Sunday-first calendar, window Monday-first | The same weekly alert fired twice at Sunday midnight; Dec 27-31 reused January's `W01` and never fired |
| Scheduled weekly digest summarised week-to-date at 09:00 on the first day of the week | Nine hours of data labelled "this week"; the finished week was never reported. It now sends "Last week" |
| `compactNumber` chose its unit before rounding | 999 950 read "1000K"; totals past a billion read "1234.5M" (now "1.2B") |
| CLI day span = elapsed seconds / 86 400, rounded | Any run before noon divided a seven-day average by six (~17% high) |
| CLI totals included disabled providers; the CSV variants ignored the enabled list | A report's daily rows did not add up to its own total |
| `busiestHour` read `Calendar.current`, ties resolved in hash order | `--timezone UTC` on a Seoul machine was nine hours off; the same data could name different hours |
| `export --since/--until/--days` re-filtered by the named period | An explicit month exported only its last seven days |
| JetBrains picked between installs by file name — which is identical for every IDE version | A stale old-IDE cache could hide the fresh one |
| MiniMax took the reset from the first model, not the one whose percentage is shown | A countdown for a different window |
| Claude statusline windows survived their own reset | Someone who stopped at 92% saw a red 92% for hours after it refilled |
| opencode's weekly window skipped the horizon filter the other two used | An empty week counted down "7d" forever |

## Things that silently did not work

- **Alert engine.** A failed *reset* alert recorded the new cycle before delivery, so it was never
  retried, and the old cycle's high `lastUsed` blocked the new cycle's thresholds meanwhile.
- **Alert migration.** One stale DeepSeek refresh flipped the migration digest, unbound the
  low-balance rule (a different rule ID) and deleted its delivery state, so the next good refresh
  sent the same low-balance alert again. Any global channel toggle re-ran the migration and
  overwrote user-edited Claude thresholds with the legacy defaults.
- **opencode SQLite** was opened `immutable=1`, which ignores the WAL. opencode's database is in
  WAL mode (confirmed on this machine), so everything since the last checkpoint was invisible.
- **OpenRouter** read `total_credits` at the top level; the published response nests it under
  `data` (verified against the official spec), so every real response parsed as nil. Z.ai's
  endpoint is undocumented; its parser now also accepts the enveloped shape and a numeric reset.
- **Credential path guard** matched fragments across the whole path. Claude names each project's
  folder after its path, so a project at `…/oauth-proxy` lost every session, and "auth" matched
  "author". File names are still matched by fragment; folders only by whole credential names.
- **Global hotkey** registration failure was silent — and retried on every model change, about
  twenty times per refresh. It now turns the setting off and says why.
- **Launch at login** registered into `requiresApproval` read as "off" on the next launch; the user
  is now sent to Login Items, and turning it off while pending actually unregisters.
- **Quit** waited a fixed 250 ms (the wait only ended on cancellation), with the refresh timer still
  live inside the nested run loop; a settings change within 350 ms of Quit was lost.
- **Delivery errors** reported a revoked bot token, a deleted webhook and being offline as the same
  "request failed". A pasted Discord *channel* link now says what a webhook URL looks like.

## CPU

- **Claude session files were read through a 4 MB tail — on every refresh.** On this machine 4 of
  9 recent sessions exceed 4 MB (largest 117 MB). A new incremental reader streams each file once
  and then reads only appended bytes, resetting on truncation or a new inode. Measured side by side
  on the same files at the same moment: **1.6 s per refresh → 0.1 s**, identical "today" total, and
  135 older events recovered. First read after launch is ~4.9 s, once.
- Status bar rebuilt once per `@Published` write (~20 per refresh) → once per run-loop turn.
- History recomputed nine event-scanning properties 3-4 times per body pass → once.
- Heatmap built 84 `DateFormatter`s per pass; seven-day bars rescanned every event 7×; the evidence
  sort rebuilt series-ID strings per comparison (232 ms → 15 ms for 7 200 records, debug).
- Settings built all twelve provider diagnostics ~150 times per pass to choose which card opens.
- Provider icons replayed a 0.7 s staggered spring on every screen switch.

**Idle, popover closed, over two refresh cycles: 0.5% of one core.**

## UX and accessibility

Overview's "Next action" is a working button, as it already was in History. Settings cards keep
their open state across screen switches. "Show all models/projects" is keyboard-reachable, has a
real hit target and respects Reduce Motion. History says when stored history begins after the
selected period starts, instead of letting charts imply there was no earlier activity.

## Test hygiene found along the way

- `testCLIExportNoCostBlanksCostFields` failed about once in a hundred runs: CSV timestamps carry
  milliseconds, and `contains("0.5")` matched ":10.512Z". It now checks the cost column.
- Four tests hard-coded reset instants that would have passed on **2027-01-15**, failing CI from
  that day. Found by running the suite with the Codex adapter's clock 200 days ahead; they now use
  a fixed clock. Two Claude statusline fixtures had already expired and only passed because nothing
  checked for elapsed windows.

## Not fixed, and why

- **History keeps 2 000 events** — on this machine that was 2.5 days of a 45-day retention. Raising
  the cap grows a UserDefaults blob rewritten on every change (705 KB → ~13 MB); rolling old events
  up double-counts, because adapters re-emit 31 days each refresh and dedupe keys on raw events.
  This needs the append-and-compact store redesign. History now at least says where it begins.
- **Claude events split across two refreshes may count twice.** A real fix needs a stable
  per-message ID; switching keys would double-count every already-stored Claude event for up to
  45 days during migration — a certain regression to fix an uncertain one.
- **Z.ai window kind** (`TOKENS_LIMIT` may be the 5-hour window, not weekly) — the endpoint is
  undocumented and could not be verified.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean. `swift test --skip SecurityPostureTests`:
  **905 tests, 0 failures, three consecutive runs**. `SecurityPostureTests`' two failures come from
  the uncommitted `.gitleaks.toml` change this work did not make.
- Suite also passed with the Codex adapter clock 200 days ahead.
- Rebuilt, relaunched; the History popover rendered correctly. Idle CPU as above.
- `gitleaks dir`: no leaks.
