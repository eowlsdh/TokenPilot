# Where the screen-switch CPU actually goes, and what the sweep that found it turned up

**Date:** 2026-08-21

Two things happened here. The CPU spike the user reported got measured properly instead of
theorised about — and the answer was not what the stack samples implied. And a parallel sweep across
performance, correctness, UX and accessibility produced 53 candidate findings, of which 40 survived
an adversarial verification pass. This records both, and separates what was measured from what was
only reasoned about.

## Part 1: the CPU spike

### A harness that admits when it failed

The previous harness reported a run at **0 ms per screen switch** and that was not a result, it was a
broken run: the popover toggle had closed the popover instead of opening it, so 75 keystrokes went
nowhere. The rebuilt harness checks state before and after:

```
closed: 1   # a probe over CGWindowListCopyWindowInfo, not a luminance guess
opened: 0   # ...so the click closed it. Toggle until open, then measure.
```

and prints `INVALID (popover closed)` when a run ends with no popover. It caught exactly that case
once during the A/B — a run that would otherwise have been reported as a spectacular improvement.

`System Events` reports **zero windows** for a `MenuBarExtra` popover, so the accessibility tree is
useless for this; `CGWindowListCopyWindowInfo` filtered to the app's PID and a >200pt frame is what
works. PyObjC is not installed, so the probe is a 15-line Swift binary.

### The baseline, and what each screen costs

Three runs of 25 cycles of three screens, on an idle machine: **150, 153, 147 ms per switch.**

Switching between pairs isolates each screen (a switch A→B costs roughly building B):

| Pair | Measured |
|---|---|
| Overview ↔ History | 81 ms |
| Overview ↔ Settings | 170 ms |
| History ↔ Settings | 200 ms |

Solving: **Settings ≈ 289 ms, History ≈ 111 ms, Overview ≈ 51 ms.** Settings costs 5.7× Overview,
which is exactly the screen the report named.

### Liquid Glass is a contributor, not the cause

Forcing `GlassSurface` onto its opaque `reduceTransparency` path and rebuilding:

| Arm | Runs | Per switch |
|---|---|---|
| A — glass | 150, 153, 147 | **150 ms** |
| B — glass off | 125, 124, 124 | **124 ms** |

**Glass costs 26 ms per switch, 17%.** That matches the sampled stack share (`GlassEntryLayout`,
`GlassContainer.Entry`, `GlassEffectContextResolvedData` came to 15-20% of the layout work) — two
independent methods agreeing. It also settles the open question from the previous session: reverting
the Liquid Glass adoption would buy 17% and give up the system effect. Not worth it.

The other 124 ms is elsewhere.

### Three theories tested, two wrong

The stack samples pointed at `LayoutEngineBox.sizeThatFits` and `StackLayout.placeChildren` under a
2 580-line `SettingsScreen` whose nine sections sit in a `LazyVStack`. Three plausible causes, each
built and measured rather than argued about:

| Change | Overview ↔ Settings | Verdict |
|---|---|---|
| baseline | 170 ms | — |
| `DisclosureCard` content held as a closure, not built eagerly | 167 ms | **3 ms. Not it.** |
| sections as a `ForEach` so `LazyVStack` can defer rows | 166 ms | **1 ms. Not it.** |
| `.onAppear` Keychain work removed | 149 ms | **18 ms. This one.** |

The eager-construction theory was the strongest-looking finding of the whole sweep — the verifier
confirmed every code claim about it in detail, and it was still worth only 3 ms. Constructing SwiftUI
view values is cheap; the cost is layout. The `ForEach` experiment was reverted: it added a type-
erasing enum and bought nothing.

The `DisclosureCard`/`CollapsibleSection` closure change was **kept** — it is strictly less work and
the closure form is the correct shape for content behind an `if` — but it is filed as tidying, not as
a fix, because the number says so.

### What the 18 ms was

`SettingsScreen.onAppear` calls `refreshStoredCredentialPresence()`, which ran **six
`SecItemCopyMatching` queries on the main actor** and then published six times — whether or not any
answer had changed. `@Published` fires on every write, not every change, so six unchanged `false`s
cost six full popover rebuilds on the most expensive screen in the app. The same class of defect the
evidence store and the preferences file each had earlier this month.

Fixed: the six queries run together off the main actor, and `publishIfChanged` makes an unchanged
answer free. Re-measured: **150 ms**, matching the arm with the call removed entirely.

A second Keychain read lived *inside* the view body — `hasSavedAPIKey(_:)` called
`KeychainService().readSecret(...)` on every render — and now reads the presence the ViewModel
already publishes.

### The honest bottom line on CPU

There is no single dominant cause. Settings costs what it costs because it is a very large view, and
the contributors are diffuse: ~26 ms glass, ~18 ms Keychain, ~3 ms eager content, and the rest spread
across ordinary SwiftUI layout of a 2 580-line body.

**The final aggregate could not be measured.** By the end of this session the machine was at load
average 7.9 with two other processes over 60% CPU, and three consecutive samples of the same workload
came back 160 / 197 / 187 ms — a 37 ms spread that swamps every effect above. The per-screen figures
taken while the machine was idle are the ones to trust; the closing numbers are not.

Meaningfully reducing Settings further means making it a smaller view, which is a restructuring job,
not a fix. That is the next thing to decide, not the next thing to measure.

## Part 2: what the sweep found

Seven parallel investigators (performance × 2, correctness × 2, UX × 2, feature gaps) produced 53
findings; each went to an independent verifier instructed to refute it. **40 survived, 13 were
refuted.** The ones acted on:

### Wrong numbers

- **A Codex window at 1% read as 100%.** `used_percent: 1` hit a fraction-normalizing branch written
  `raw > 0 && raw <= 1`, so an integer 1 was treated as the fraction 1.0 and rescaled. A window that
  had *just reset* showed as exhausted in critical red and fired a "limit reached" alert on a window
  99% free. `KiroUsageLimitsAdapter` had it right (`< 1`) and its comment even says "normalize like
  the codex session parser". Fixed at all three sites.
- **Budgets counted re-sent context for Codex.** `workingTokens` returned an overridden total whole,
  on the stated grounds that "an override arrives as an opaque total with no components to subtract
  from". False where it matters: the Codex adapter sets `totalTokensOverride: usage.total` *and*
  `cacheReadTokens: usage.cached` on the same event. One conversation at 220k tokens of which 200k
  were cache reads counted as 220k against a daily budget. Where a source really reports no
  breakdown the subtraction is a no-op, which is the case the old reading was written for.
- **Coverage could exceed 100%.** `UsageCoverageService` counted every stored active day against
  `windowDays`, so `audit` printed "102% of last 45 days" and named an "oldest stored" day outside
  the window it was describing.
- **The last activity block of the day counted down an hour too far.** Blocks restart at local
  midnight, so 20:00 runs four hours, not five. At 23:30 the status line said 1h30m and the total
  reset thirty minutes later. Every evening, on every install.

### Things that silently did not work

- **Daily and weekly digests could never fire.** A once-per-day attempt tracker was written *before*
  the fire window was checked, so the first tick after midnight burned the day's only attempt outside
  every schedule anyone would pick. Weekly was worse: a per-day tracker in front of a per-week
  schedule meant it never sent at all. The gate already dedupes on `lastSentAt`; the tracker was
  removed.
- **⌘⇧Space did nothing in the recommended menu bar layout.** The popover hangs off a status item
  button, and the standard item is *removed* whenever the menu bar draws one item per provider. The
  hotkey found no button and returned, silently. It now falls back through
  `effectiveMenuBarMetricProviders` — the drawing order, so the popover does not jump between items.
- **A half-typed token replaced the saved one for automatic alerts.** The unsaved text field won over
  the Keychain everywhere, not just for the button the user had pressed. Paste half a new bot token,
  switch screens, and every alert for the rest of the session went out with it and failed — visible
  only as a rising failed-delivery count. The field now wins only for Send Test and Find Chat ID, and
  channel availability no longer counts an unsaved field that delivery will not use.
- **The 12-week heatmap and 12-month trend drew mostly empty.** Both carry their own window and were
  *also* handed the History period picker's filtered events. With the period on "Today" the grid drew
  84 cells of which one could ever be non-zero — which reads as "I did no work for three months"
  while the data sits in the store.
- **"1 min" refreshed every 90 seconds.** A strict `>=` against a 30-second tick pushed every
  interval to the next tick, because a refresh's own duration puts the elapsed time a fraction under
  the deadline. Half a tick of slack restores 30→30 and 60→60. The "15 sec" preset was removed and
  the floor raised to 30, because a 30-second tick cannot deliver it; a stored 15 migrates up.
- **`tokenpilot blocks` was English-only**, and so was every other CLI command: `language: .en` was
  hardcoded four lines below `TokenPilotSettingsStore().load()` in the same expression. `blocksText`
  was also the one human-readable formatter with no `language:` parameter at all.

### Crashes and wrong windows in the CLI

- **`--since` later than `--until` aborted the process** on a `ClosedRange` trap — a swapped pair is
  an ordinary typo. All six parsers reject it now, and an inverted window that only becomes inverted
  at run time (a `--until` before the period's own start) yields an empty report rather than a crash.
- **`--timezone` was ignored when parsing `--since`/`--until`.** Days were parsed during the flag
  loop, before the zone was known, so they anchored to the *system* zone: asking for one day in
  another zone returned a window offset by the difference. The days are resolved after the loop now.

### Translation, UX and accessibility

- **Twenty user-visible strings shipped in English** to Korean, Japanese and Chinese readers: banner
  messages ("Enter an API key first."), provider setup guidance, the whole `stats`/`blocks` CLI
  vocabulary, and the menu bar's "Setup". See below for why every existing guard missed them.
- **Five irreversible Keychain deletions were one unconfirmed click.** Reset Settings — which *keeps*
  the credentials — asked; the four actions that destroy one did not, and Delete sits beside Replace
  with identical metrics. A Discord webhook cannot be shown again after saving.
- **"API key required" was drawn in the reassuring colour.** MiniMax, Z.ai and OpenRouter rendered it
  in `trust` with the `key.slash` "no key needed" glyph — pixel-identical to the providers that say
  "No secret required". Only DeepSeek was ever asked.
- **The Providers card was inaudible.** `.accessibilityElement(children: .combine)` flattened every
  row into one element whose value was just the provider names, discarding each row's own label with
  its percentage, risk and reset. `.contain` keeps them.
- **Activity charts painted volume in the risk palette.** The busiest hour is by definition at ratio
  1.0, so the hourly and 5-hour bars were *always* red — the same red the card above uses for
  critical quota. They use a neutral intensity ramp now; red is reserved for something being wrong.
- **Alert-threshold chips spoke English "On"/"Off"** inside an otherwise Korean card, and the state
  is the only thing distinguishing an armed threshold for a non-sighted user.
- **The banner was silent to VoiceOver.** It is the app's only answer to "did that work?", and it
  appears at the top of the popover — often hundreds of points from the button just pressed, outside
  that screen's ScrollView. It announces now.

## Part 3: the guard that was missing

Every localization guard in the suite starts from a surface that already exists — the catalog, or the
shared table — and checks it is complete. A string in **neither** surface is invisible to all of
them. Twenty had shipped that way.

The new guard starts from the call sites instead: it scans `Sources/` for `t("…")` and
`localized("…")` literals and asserts each is declared for every shipped language. It excludes
English (the development region — the key *is* the English string) and keys with no letters in them
(an em dash placeholder has nothing to translate).

It proved itself twice in one session: it found the original twenty, and then caught the nine
confirmation strings this same work introduced, before they could ship.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **879 tests, 0 failures** (with
  `--skip SecurityPostureTests`, whose two failures come from uncommitted changes to `.gitleaks.toml`
  and the CI workflow that this work did not make and did not touch).
- Every guard checked by reintroducing the defect: the localization one names
  `TokenPilotViewModel.swift:2238`; the Codex one reports 100 where 1 belongs; the timezone one
  reports a 0-second offset where 14 400 belongs; the digest one names `checkDailyDigest`.
- **Measured, not reasoned about:** the glass A/B, the per-screen decomposition, the three CPU
  theories, and the Keychain fix — each rebuilt and re-run against the deterministic workload.
- **Verified on the running app:** rebuilt, relaunched, popover opened and captured on both Overview
  and Settings. Korean copy, glass surfaces and disclosure cards all render correctly after the
  content-closure change.
- `make security-scan`: no leaks, both scans.
