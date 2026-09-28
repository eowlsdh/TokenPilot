# Benchmark parity: where TokenPilot stands, measured

**Date:** 2026-08-21

The goal was to reach the level of the tools TokenPilot was benchmarked against. This records each
axis with the evidence, rather than an impression.

## Method

1. **Start from the record.** The prior benchmark notes were re-read before any new work; most of
   their gaps were closed and the baseline (`272e596`) was stale. One deferred item survived.
2. **Check against code, not documentation.**
3. **One gap at a time**, largest first.
4. **Stop and design when persisted user state is involved.**
5. **Pin what was found with a test**, because documents rot and tests fail.

## Axis by axis

| Axis | Evidence | Standing |
|---|---|---|
| **Alerting** | Rules reached 2 providers; now every watched provider with provider-reported evidence, thresholds any value 1–100, editable in Settings | Closed this pass — was the largest gap |
| **CLI** | 7 commands sharing `--period/--since/--until/--days/--timezone/--project/--provider/--model/--start-of-week/--sections/--instances/--sort`; formats `--json/--csv/--md` plus `--svg` for `report`; `blocks --watch` added | At or beyond |
| **Providers** | 12 in `Provider.allCases`, verified against the enum | Beyond — no benchmarked tool covers this many |
| **Export** | JSON/CSV with prompts, paths, and credentials excluded; capacity evidence optional | At |
| **Statusline** | `statusline` renders model, tightest remaining quota with countdown, today's tokens and cost; reads piped session JSON | At |
| **Menu bar** | Two-row provider blocks, separate or combined items, width budget, trend line or remaining bar | Beyond |
| **History** | Heatmap, seven-day and monthly trends, cache efficiency, model and project breakdowns, five-hour blocks | At or beyond |
| **Honesty model** | authority / comparability / stability / freshness carried per observation; activity never presented as quota | Differentiator — no benchmarked tool does this |

## What closed this pass

**Alerting**, which turned out to be the area the product is named for. Thresholds were four fixed
cases and rules existed for Claude and DeepSeek alone — ten providers showed a remaining percentage
and stayed silent as it ran down. Both are closed and verified on this machine (rules went 3 → 6),
with editing reachable in Settings. Recorded in full in `alert-thresholds-and-coverage.md`.

**`blocks --watch`**, the live view ccusage has and TokenPilot lacked. Bounded at 2–60 seconds
because each tick re-reads every local source, refused alongside stream formats, and clearing the
screen only on a terminal.

## What the measurements caught

Worth recording, because the same lesson recurred:

- **Four guard-caught mistakes of my own** before anything shipped: a source scanner anchored on the
  wrong token that read 16 of 24 series while looking complete; a catalogue entry claiming Gemini's
  request count was alertable when no rule can be built for it; two test fixtures that contradicted
  the series semantics table; and a test that kept passing after the gap it described had closed.
- **Three broken measurement harnesses** on the CLI axis alone — `timeout` does not exist on macOS,
  zsh does not word-split unquoted parameters, and regex-parsing the help text reported flags as
  missing that the commands plainly accept. The CLI looked broken three times and was not.
- **One real defect found only by measuring**: `blocks --watch` produced *zero* lines when piped,
  because `print` block-buffers off a terminal. Writing and flushing took the same seven-second
  capture from 0 lines to 18.

## Two conclusions reversed on inspection

Both were recorded as gaps and both were wrong:

- **Gemini's daily request cap** was listed as needing a count-based alert condition. The
  observation is a bare count with no limit in it, carries bridge stability where rules require
  supported, and the cap is a number the *user types in Settings*. An alert would have read "you are
  at 80% of a limit you invented", dressed as provider quota.
- **"Derive the alert catalogue from the semantics table"** was listed as the next cleanup.
  The table declares which identities are *permitted*, not which the app *emits*: Claude's windows
  are built with no duration while opencode's rolling window carries 300, and a duration is part of a
  series identity. Deriving would have produced a Claude rule that validates, saves, and can never
  fire. A guard now asserts every entry matches an identity the factory really emits — verified by
  deliberately breaking it.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **815 tests, 0 failures** (768 at
  the start of this work).
- Bundle rebuilt and relaunched; no crash report.
- Alert coverage confirmed against this machine's stored rules, not only in tests.

## Open

- **Screenshots and App Store Connect** — need a person; specified in `app-store-listing.md`.
- **Icon Composer** — needs the GUI tool; the legacy icon renders correctly on macOS 26.
- **Liquid Glass** — `GlassCard` hand-rolls it and `glassEffect` would replace it natively, but the
  swap restyles every card and belongs with someone looking at the screen.
