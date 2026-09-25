# Menu bar: one item became several, and the text stopped sprawling

**Date:** 2026-08-20

**Reported as:** "only one shows in the menu bar, and it stretches so far sideways it takes up room."

## What was actually happening

Two separate causes, both of which had to go.

### 1. "Separate items" never applied to the text layouts

`menuBarProviderGrouping` defaults to `.separate`, and Settings offered `Combined item` /
`Separate items` — but the picker was inside a `menuBarDisplayStyle == .providerMetrics` branch, and
so was the behaviour. In the default `Detailed` layout the setting was stored, invisible, and inert:
`updateStatusItem()` fell straight through to a single `NSStatusItem` carrying the whole joined
title. Every provider shared one wide item and the setting that said otherwise could not be seen or
changed.

### 2. The title had no ceiling

`Detailed` renders up to two windows, each with a reset countdown, and `Compact` renders a primary
and a secondary provider. Real strings reach 32 monospaced cells
(`15m 40% EXP·243d · 4h 75% EXP·243d`) — around 230 pt, roughly an eighth of a laptop menu bar, for
one utility. Nothing capped it.

## What changed

**Grouping now governs every layout.** `MenuBarStatusService.titleSegments(…)` returns the title
split into the pieces it was already joined from, each with its own provider and spoken label.
`TokenPilotAppDelegate` draws one status item per segment when grouping is `.separate`, reusing items
by position so the group does not jump to the right edge of the bar on every refresh. Nothing about
what a layout *says* changed — only where the seams are.

`Detailed` without a secondary provider stays one item on purpose: its two pieces are two windows of
the same provider, and splitting those would read as two providers.

**A width budget with a trimming ladder.** New `MenuBarWidthLimit` — `Full` (uncapped), `Standard`
(26 cells, the default), `Narrow` (13 cells). When a title is over budget the renderer drops whole
components, cheapest first:

| Order | Dropped | Why it goes first |
|---|---|---|
| 1 | reset countdowns (`·4h58m`) | The popover shows the same countdown on the provider row |
| 2 | window tags (`7d` after a percentage) | Every provider row in the popover names its window |
| 3 | the second reading | Only after the decoration is already gone |

Honesty markers are not decoration and are never dropped: `EST`, `EXP`, `MOCK`, `STALE`, `Manual`
stay on the number they qualify. Nothing is cut mid-word and no ellipsis is ever drawn — a menu bar
that says `5h 64%…` asks the user to guess, and a truncated percentage would simply be a wrong
number. 26 cells is what two undecorated readings cost in the widest real case, so `Standard` trims
decoration without ever hiding a reading; `Narrow` is what one reading costs, which is its point.

`MenuBarTextWidth` counts CJK and Hangul as two cells, because in the menu bar's monospaced font they
are two cells wide — a character count would have made the budget generous in English and
meaningless in the four other languages TokenPilot ships.

### 3. An idle provider disappeared behind the app's own name

Splitting the title exposed the real reason only one provider was visible. `compactSegments`
resolved the primary slot as `selectedTarget ?? primaryCandidate?.snapshot.provider` — and a provider
that is enabled, read, and simply quiet produces **no candidate**. The slot fell through to `nil`,
which renders as `TP Setup`. Probing the live pipeline showed exactly that:

```text
opencode: localLog, stale, no windows, todayTokens 0
segments -> ["nil: TP Setup", "deepseek: DS Setup"]
```

So the menu bar named neither of the user's two providers. The primary slot now falls back to the
first enabled provider that is not already the secondary, and `compactSegment` distinguishes the two
states that both used to render as `Setup`:

| State | Before | After |
|---|---|---|
| Provider read, nothing to report yet | `TP Setup` | `OC —` |
| …and its snapshot is stale | `TP Setup` | `OC — STALE` |
| No source for this provider at all | `OC Setup` | `OC Setup` (unchanged) |

`—` is the app's existing "no value yet" marker — the provider-metrics blocks and the Settings marker
legend already use it. `Setup` stays reserved for a provider that genuinely has no source, because
telling a configured user to set something up again sends them looking for a problem that isn't there.

## Three more defects found while wiring it

- **A provider switched off lost its menu bar slot for good.** `normalizeMenuBarComposition()`
  intersected `menuBarMetricProviders` with the enabled set and wrote the result back, so switching a
  provider off pruned it permanently; switching it back on left it missing from the menu bar with
  nothing on screen to explain why. The selection is now kept as intent and intersected at read time
  by `effectiveMenuBarMetricProviders`, and enabling a provider adds it back explicitly.
- **Experimental consent expired at every launch.** `experimentalUsage` was in `CodingKeys` and was
  encoded, but `init(from:)` never read it back — so an opt-in the user had given was silently
  withdrawn on the next launch and the probes went quiet with no message. It is now decoded. This
  only persists an explicit opt-in: the default is still no consent, and
  `ExperimentalUsageSettings.init` still discards any version that is not the current one.
- **One unrecognised word could have wiped every setting.** `menuBarTrendStyle` decoded straight into
  its enum, so a value written by a newer build would throw and take the entire `AppSettings` decode
  with it — providers, alert rules, digest schedule, all of it. Both it and the new width limit now
  go through `decodeChoice`, which falls back instead of failing.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `./build.sh` signed; app relaunched and running.
- `swift test`: **732 tests, 0 failures** (711 before this work).
- The idle-provider fix was found with a throwaway probe that ran the real `OpenCodeSessionAdapter`
  against this machine's settings and printed the resulting segments. It read no credentials and was
  deleted afterwards; the behaviour it exposed is now covered by three permanent tests instead.
- New `Tests/MenuBarWidthTests.swift` (20 tests): cell counting for Latin and CJK/Hangul, the three
  budgets, countdowns dropped before a window, narrow keeping one reading, no ellipsis and no
  mid-word cut at any budget, an unfittable title still rendering, width round trip plus an unknown
  value decoding to the default, translations in all five locales, compact titles splitting one
  segment per provider, segments rejoining into the combined title, a spoken label on every segment,
  detailed-without-secondary staying one item, per-item budgets keeping their reading, an idle
  provider keeping its name and stale marker, `Setup` still meaning "no source", an idle primary not
  swallowing the secondary slot, and the experimental-consent round trip with the default still off.
- Updated: the grouping source contract (it now asserts the text-layout split), the legacy menu bar
  provider defaults and the fallback test (both moved onto `effectiveMenuBarMetricProviders`), and
  the Codex rolling-window title test, which now pins both the uncapped string and what the default
  budget renders.
- Localization: 6 new strings in the Swift fallback table and in `Localizable.xcstrings` across
  en/ko/ja/zh-Hans/zh-Hant. The catalog was appended as text — it carries duplicate JSON keys that a
  re-serialization would silently drop.

## Not covered

- Visual confirmation on the real menu bar is the user's to make; this pass is compile-, test-, and
  launch-verified.
- The budget is measured in monospaced cells, which is exact for the menu bar font in use. If the
  title font ever becomes proportional, the ladder still works but the numbers become approximate.
