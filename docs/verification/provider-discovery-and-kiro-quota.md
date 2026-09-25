# Why configured providers reported nothing

**Date:** 2026-08-20

**Reported as:** "the providers just need to load properly."

A read-only probe ran the real adapters against this machine's local files and printed what a
fresh install would show. Two providers had sources on disk and reported nothing. The causes were
unrelated.

| Provider | Before | After |
|---|---|---|
| **Codex** | `manual`, 0 events, no window | `localLog`, **`5h 2%` provider-reported** |
| **Kiro** | 3 events, no window | 3 events, **`mo 17%` credit usage** |
| Claude | 2,571 events, no window | 2,592 events, no window (needs the statusline bridge) |
| Antigravity | 0 events | 0 events (separate cause, not addressed here) |

## 1. The file walk never reached the newest files

`candidateFiles` walked until it had `maxFiles * 4` entries, then sorted **those** by modification
date and took the newest. That sorts an arbitrary slice of the tree rather than the tree.

Codex partitions sessions as `sessions/YYYY/MM/DD`. On this machine:

| | |
|---|---|
| session files | 456 (Apr 43 · May 60 · Jun 165 · **Jul 184 · Aug 4**) |
| first 96 in walk order | Apr 43 · Jun 53 — **zero from Jul or Aug** |
| retention cutoff | 45 days → 2026-07-06 |

Every file the walk collected was older than the cutoff, so the adapter discarded all of them,
fell back to manual mode, and reported `Manual mode · no data entered`. The 188 newest files were
never opened. Nothing on screen said why.

`KiroAdapter.collect` had the identical pattern, and Claude and Antigravity used the same helper —
four adapters, one copied mistake. It bit Codex first only because Codex was the one provider whose
tree exceeded the cap.

**Fixed** by `NewestFileScan` (`Sources/TokenCore/Services/NewestFileScan.swift`), now shared by
both call sites: it examines every candidate and keeps only `limit` in memory, inserting into a
bounded newest-first array. Modification dates come from the enumerator's prefetched resource
values, so ranking costs no extra `stat` per file. A 50,000-entry examination ceiling guards against
a pathological tree, and `Result.truncated` reports when it was hit rather than silently
under-reporting.

## 2. Kiro published a quota percentage and the adapter read past it

Kiro's transcript carries `payload.type == "session_metadata"` → `payload.value.usagePercentage`.
On this machine: **66 samples climbing 4.93% → 16.96%** through a session — a cumulative usage
percentage, in the same file the adapter was already reading for credits. The snapshot literally
said `credits metered, no quota window` while the number sat there.

Scanning the whole Kiro tree for usage-shaped fields (keys and numbers only — no transcript text)
mapped what Kiro actually writes:

| Location | Field | Status |
|---|---|---|
| `sessions/**/messages.jsonl` | `promptTurnSummaries[].usage` (credits) | already read — the 3 events |
| `sessions/**/messages.jsonl` | **`session_metadata.usagePercentage`** | **now read** |
| `sessions/cli/*.json` | `rts_model_state.context_usage_percentage` | already read |
| `sessions/cli/*.json` | `user_turn_metadatas[].*_token_count` | **not read — see below** |

**Fixed** by `parseCreditUsagePercent`, which takes the **newest** sample rather than the largest:
the value climbs through a session, so the two usually agree, but after a reset the largest sample
is the stale one and reporting it would overstate usage.

### How it is labelled, and why

The number is the provider's, but the period it covers is not stated anywhere Kiro writes. So it is
carried as a **credit window with no reset time and medium confidence**, labelled `cr` rather than
dressed up as a calendar month. It occupies the monthly slot specifically so Kiro's opt-in usage
API — the authoritative source — keeps the weekly slot to itself; a test pins that separation.

A monthly-only window also used to fall through to "no value" in `MenuBarStatusService.displayWindow`,
so even a correct percentage would not have been drawn. The fallback chain now includes monthly.

## Left undone, deliberately

- **Kiro CLI token counts.** `sessions/cli/*.json` carries per-turn `input_token_count`,
  `output_token_count`, `cache_read_input_token_count`, `cache_write_input_token_count` and
  `total_request_count`. All 3 turns on this machine are **zero**, so a parser could be written but
  not verified against a single real value. Writing an unverifiable parser for undocumented fields
  is how Command Code ended up with a parser that has never seen live data; not repeating it here.
- **`cli/*.jsonl` and `sub-executions/*.jsonl`** are not matched by the adapter. Inspected: they
  carry message structure only (`kind`, `message_id`, `content[]`, `meta.timestamp`) and **no usage
  fields**, so reading them would add nothing.
- **Claude has no quota window** because Claude Code does not write limits to its local JSONL — the
  statusline bridge supplies them. That is a first-run guidance problem, not a parsing bug, and it is
  the next thing worth fixing: the app says `rate limits unavailable` without saying what to do.
- **Antigravity reports 0 events** despite a statusline file being present. Separate cause, not
  investigated yet.
- **Claude's today-token total reads 526M** because cache-read tokens are summed into it. The
  arithmetic is right, but a headline of "526M tokens today" reads as broken; ccusage separates
  cache tokens. Worth a display decision.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `./build.sh` signed; app relaunched and running.
- `swift test`: **745 tests, 0 failures** (732 before this pass).
- New `Tests/ProviderDiscoveryTests.swift` (13 tests): newest files found when walked last (the Codex
  tree shape, 205 files), newest-first ordering, ineligible files never returned, a file as its own
  root, directories and missing roots skipped; Kiro's newest-not-largest sample, rounding and range
  checks, malformed and unrelated lines ignored, timestamp falling back to the file date, the credit
  window's honest labelling, the no-sample message preserved, the usage API keeping the weekly slot,
  and a monthly-only window reaching the menu bar.
- Both fixes were confirmed against this machine's real files before and after, with a throwaway
  probe that read no credentials and was deleted.
