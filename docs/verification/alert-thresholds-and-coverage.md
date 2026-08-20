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

## Still open

- **Codex, JetBrains, MiniMax, Z.ai, OpenRouter, Kiro** gain rules the moment they are enabled and
  observed; Codex's need to come from observed series rather than the catalogue, since its window
  durations are provider-set.
- **Gemini's daily request cap** needs a count-based alert condition, which does not exist.
- **Threshold editing UI.** The model accepts any percentage; Settings has no control for it yet, so
  today the defaults (reset, 80%, 100%) are what everyone gets.
