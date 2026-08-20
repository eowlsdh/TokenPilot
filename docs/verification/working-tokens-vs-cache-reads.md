# "Today: 526M tokens" was 98% re-sent context

**Date:** 2026-08-20

**Reported as:** the today-token figure reads as a broken counter.

## What the number actually was

Measured against this machine's real local logs:

| | Claude | opencode |
|---|---|---|
| total shown | 599M | 5.21B |
| cache reads | 587M (**98.0%**) | 5.16B (**99.1%**) |
| input | 5,336 | 38.7M |
| output | 2.35M | 4.67M |
| total minus cache reads | **12.0M** | **47.6M** |

A cache read is context being re-sent — billed at a fraction of a fresh token and utterly dominant
by volume. The headline was 50–250× the work actually done.

## It was not only cosmetic

`UsageEvent.totalTokens` sums cache reads, and it fed more than the display:

- **Budget guardrails.** `BudgetGuardrailService` compared it against the user's daily/weekly/monthly
  token budgets. Any token budget was blown by the first conversation of the day, so the guardrail
  alerted on re-sent context rather than on work — the one thing it exists not to do.
- **Daily goal.** Against the default 10,000-token target the card read 599M / 10K.
- **Milestones.** Every lifetime-token milestone up to 10M was handed out on day one.

## The split, and where each side is used

New `UsageEvent.workingTokens` — everything except cache reads. A cache *write* is new content being
stored, so it stays; only the read is removed. `ProviderSnapshot` gained `todayCacheReadTokens`
(populated by the adapters that sum events) and a derived `todayWorkingTokens`.

| Surface | Number | Why |
|---|---|---|
| Budgets, daily goal, milestones | working | They answer "how much did I do" |
| Menu bar / statusline today figure | working | One number, so it is the meaningful one |
| History totals, model breakdown, cache cards, export | **full total** | Full accounting is what they are for |

A provider that reports no cache split keeps its full total rather than being made to look smaller
than it is: `todayWorkingTokens` falls back to `todayTokens` when `todayCacheReadTokens` is zero. A
source claiming more cache than total is clamped instead of going negative. An event carrying a
`totalTokensOverride` is reported whole, because an opaque total has no components to subtract from.

**Result:** the menu bar's today figure went from `Cl 545Mtok` to **`Cl 9.7Mtok`**.

## Found while verifying: the metric picker was inert in the compact layout

Settings offers **Menu bar metric** (remaining percent / today tokens / today cost) for both the
detailed and compact layouts, but only `detailedTitle` read it. In compact, choosing "Today tokens"
changed nothing — the bar kept showing `Cl Local`. `compactSegment` now consults the same
`primaryMetricSegment`, which returns nil for the default metric or a missing local value, so
remaining-percent behaviour is untouched. Both layouts now render `Cl 9.7Mtok`.

This is the third setting found this week that was offered but had no effect, after menu bar
grouping and the provider enablement flags.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `./build.sh` signed; app relaunched and running.
- `swift test`: **754 tests, 0 failures** (745 before this pass).
- New `Tests/WorkingTokenTests.swift` (9 tests): cache reads dropped and cache writes kept, no
  negative totals, an overridden total reported whole, the snapshot subtracting only what the source
  reported plus clamping and the no-split fallback, encode round trip and legacy payloads decoding,
  a token budget surviving 5M cache reads, milestones not handed out for re-sent context, the menu
  bar metric using working tokens in **both** text layouts, and — guarding the other direction —
  History-style totals still counting every token.
- Before and after were measured against this machine's real logs with a throwaway probe that read
  no credentials and was deleted.

## Worth deciding next

- **The default daily goal is 10,000 tokens.** Real days here are ~12M *working* tokens, so the card
  still pins at 100% every day. The default was set when the number included cache reads and was
  meaningless either way; it now needs a realistic value.
- History's "Total tokens" card sits beside a "Cache tokens" card, so the full figure is already
  qualified there. If the two numbers still read as contradictory next to the goal card, the label
  is the thing to change, not the arithmetic.
