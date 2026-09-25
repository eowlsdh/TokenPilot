# Alerts: any threshold, and every watched provider

**Date:** 2026-08-21

The goal was benchmark parity. Tracing what the benchmarked trackers do that TokenPilot did not
landed on one area, and it turned out to be the area the product is named for.

## Method

Rather than guessing at features, the prior benchmark records in `docs/verification/` were re-read
first — most of their gaps had been closed and their baseline (`272e596`) was stale. What survived
was a single deferred item: *"custom alert thresholds — benchmarks use 75/90/95; TokenPilot has
reset/50/80/100. Touches persisted alert rules and delivery dedupe state, so it deserves its own
pass."* That was the thread.

## 1. Thresholds were four fixed cases

`CapacityAlertPercentThreshold` enumerated reset, 50, 80, 100. A user who wanted a warning at 90%
could not have one — a strange limitation in a tool whose whole job is telling you before you run
out. It now carries a percentage, and any value in 1...100 works.

The delicate part was not the model but the persistence. Delivered-alert state is keyed by the
threshold's raw value, so renaming the three original percentages to `p50`/`p80`/`p100` would have
made every already-delivered alert look undelivered and fire again on the first launch after
updating. They keep their original spellings, and `percent(50)` canonicalises to `.fifty` so a user
who keeps 50% is not re-alerted for having kept it.

The stored format works in both directions: the three booleans are still written so an older build
reads a newer file, and a `percents` array beside them carries the full set. A stored percentage
outside 1...100 fails the decode rather than loading as a rule that silently never fires, and
out-of-range input is rejected rather than clamped — quietly moving a threshold to 100 would hide
that the app cannot keep the promise.

## 2. The bigger find: alerts reached two providers

Tracing where rules come from turned up the real problem. The only source was a migration filtering
on `provider == .claude`, plus a DeepSeek balance rule. On this machine, before the fix:

```
rules: 3
  claude   / five-hour
  claude   / seven-day
  deepseek / balance
```

opencode was enabled, reporting three quota windows, and had no alert rule at all. Ten providers
showed a remaining percentage on screen and stayed silent as it ran down. That is the one failure a
limit monitor cannot have.

### Why reconciliation runs beside the migration, not through it

Two properties of the existing code, both found by reading it rather than assuming:

- `mergeRules` overwrites migrated rules by ID. A rule created through migration would reset
  thresholds a user had changed.
- `settingsDigest` hashes only Claude's rules, so enabling a new provider would never re-run the
  migration at all.

`CapacityAlertReconciler` therefore only ever *adds* a rule whose identity is absent.
`CapacityAlertRule.id` is derived from provider, series, condition kind, authority, and stability,
so a series always maps to the same identity: adding is idempotent, and an existing rule — default
or hand-edited — is never read, replaced, or reordered.

### What did not need writing

A seeding step, which is what I expected to spend most of the effort on. A rule created against a
window already at 85% would seem to fire immediately, and doing that for ten providers at once on
first launch would look broken. Reading the transition engine showed it already handles this: with
no prior state it records the current usage and returns without firing, so alerts begin at the next
crossing. Writing a seeding step would have duplicated that logic and could have contradicted it.

After the fix, on the same machine:

```
rules: 6
  claude   / five-hour            reset + 80% + 100%
  claude   / seven-day            reset + 80% + 100%
  deepseek / balance              (below-threshold)
  opencode / opencode-go-monthly  reset + 80% + 100%
  opencode / opencode-go-rolling  reset + 80% + 100%
  opencode / rate-limit           reset + 80% + 100%
```

Claude's thresholds are unchanged and DeepSeek's rule is untouched.

## The guards found two of my own mistakes

The catalogue of alertable series is pinned against the observation factory's source, and the guard
earned its keep twice before the feature shipped:

- Anchored on `CapacitySeriesID(`, the scan found 16 of 24 series and looked complete. Claude's and
  Codex's windows reach the initialiser through a local helper, so exactly the oldest and most
  important ones were skipped. Re-anchored on `providerWindowID:`, it caught `codex/primary` and
  `codex/secondary` as unclassified — which was true.
- The catalogue listed `gemini/daily-requests` as alertable. It is a request *count*, and
  `CapacityAlertRule` rejects a percent-threshold rule whose series is not a percentage, so the
  entry produced a valid series identity and an unbuildable rule. The catalogue's own test only
  checked that the series resolved; it now builds a real rule for every alertable entry. Ten of
  eleven entries were right, and finding the eleventh is the argument for the guard.

A third category exists because of the first find: Codex sets its own window durations, so there is
no fixed series identity to write down. Filing it under "not alertable" would have been false.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **794 tests, 0 failures** (768 at
  the start of this pass).
- New: 12 threshold tests (canonicalisation, both directions of the stored format, sort order,
  rejection paths), 6 catalogue guards, 8 reconciler tests — including that a hand-edited rule comes
  back byte-identical, that a second run changes nothing, and that toggling a provider off and on
  does not duplicate.
- Verified end to end on this machine: rules went from 3 to 6, opencode's three windows gained
  alerts, and nothing already stored changed.

## Closed since: editing, and the series the app cannot name

**Thresholds are editable.** The model accepted any percentage and Settings had no control for it,
which made it a capability nobody could use — the same shape as the three inert settings found
earlier this week, from the other direction. Each percent rule now carries chips for reset and
50/75/80/90/95/100, covering what the benchmarked trackers default to. Any percentage already stored
appears alongside them, so editing one threshold cannot silently drop another. Two states are
refused rather than explained afterwards: the last threshold cannot be removed, because a rule with
nothing switched on still looks configured while watching nothing, and edits are declined while the
rule store is recovering rather than writing into a file that could not be fully read.

**Codex is covered.** A static catalogue cannot name every alertable series — Codex sets its own
window durations, and a duration is part of a series identity. Reconciliation now also reads the
refresh's assessments and creates a rule for any provider-reported, supported series the pipeline
marks `alertEligibility == .percent`. Using the pipeline's own answer rather than re-deriving it
matters: a second opinion could disagree with the engine that delivers.

`CapacitySeriesID` validates against a declared semantics table, and that table — not the
observation factory's source — is the real authority on which series exist. It caught two wrong test
fixtures immediately: Codex windows are `.rolling` with a required duration, and an invented window
ID is not a series at all. A third assertion passed for the wrong reason, testing the observed path
with a series the catalogue creates anyway.

## Correction: Gemini's request cap is not a missing feature

The previous version of this note listed Gemini's daily request cap as the last provider whose
limit was visible but unwatchable, needing only a count-based condition. Reading the observation
showed that was wrong on three counts:

- The value is a bare count with **no limit in it**, so there is nothing to threshold against.
- It carries `compatibilityBridge` stability and `incomparable` comparability; `CapacityAlertRule`
  requires `supported`, so no rule of any kind can be built for it.
- The cap it would be measured against is `geminiDailyRequestCap` — a number the **user types in
  Settings** (default 1000, range 1–20,000), not something Antigravity reports.

An alert here would read "you are at 80% of a limit you invented", presented identically to alerts
backed by provider-reported quota. That is the one thing this app refuses to do. It is recorded as
not alertable at the evidence level, with the reason, rather than left as a feature someone will
eventually build on a false premise.

## Where this leaves alerting

Every series the app measures with provider-reported, supported evidence now gets an alert rule for
the providers the user watches — including the ones whose identity is only known at runtime. What
remains unwatched is unwatched because the evidence does not support a truthful warning, and each
case says which.

## Correction: the catalogue is not a duplicate of the semantics table

The previous version of this note listed "derive the catalogue from `CapacitySeriesID`'s semantics
table" as the next change. Attempting it showed it would have been a regression.

The table declares which identities are **permitted**. It does not say which the app **emits**.
`optionalExact(300)` means a duration of 300 or none is acceptable — and the factory builds Claude's
windows with `durationMinutes: nil` while opencode's rolling window carries 300. A duration is part
of a series identity, so deriving from the table would have produced a Claude rule identified by a
duration no observation carries: a rule that looks correct, validates, saves, and can never fire.

They are two different facts, and the second is not derivable from the first.

What replaced the derivation is a guard for the property that actually matters: every alertable
entry must name an identity the factory really emits, duration included. It was verified by
deliberately giving Claude's five-hour window a duration of 300, which failed with
`claude/five-hour duration=Optional(300) is not an identity the factory emits` — the exact breakage
the derivation would have shipped silently.
