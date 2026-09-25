# Saying what to do, and reading the half of Kiro that reports tokens

**Date:** 2026-08-20

Closes the three items left open by `provider-discovery-and-kiro-quota.md`.

## 1 & 2. Claude and Antigravity had the same problem, not two

Both providers were connected, readable, and reporting nothing useful — and both said so in a way
that named a limitation without naming the fix.

**Antigravity turned out not to be a bug at all.** Its statusline file exists and parses; every value
in it is zero or null and it has not been touched since June. The bridge was installed and never
written — no Antigravity session has run since. The adapter was right; the message
(`No Antigravity or Gemini token events yet`) just read as a fault to chase.

That state is detectable: a resolved, readable, empty source with no read error is a bridge waiting
for its first session, which is worth saying out loud.

| Provider | Before | After |
|---|---|---|
| Claude, local JSONL | `Local JSONL · rate limits unavailable` | `Local JSONL · connect the statusline for limits` |
| Antigravity, empty bridge | `No Antigravity or Gemini token events yet` | `Statusline connected · waiting for the first session` |
| Antigravity, read failure | `Antigravity/Gemini data could not be read` | unchanged |

Settings' Setup Guide already carries a copy-able bridge snippet for each of them. The problem was
never missing guidance — it was that the status message did not point anyone at it.

**Both new strings are translated across en/ko/ja/zh-Hans/zh-Hant.** Worth recording that the rest of
the adapter status vocabulary is *not*: every other message (`STALE · older than 5 minutes`,
`Connected`, `Manual mode · no data entered`) reaches a Korean or Japanese user in English. These two
were translated because they are the ones a new user has to act on; the rest merely describe state.
Translating the remainder is a known gap, not an oversight.

## 3. Kiro CLI turns

Kiro's IDE transcript meters in credits and reports no tokens, so before this the CLI half of Kiro
contributed no usage at all. `sessions/cli/*.json` carries
`session_state.conversation_metadata.user_turn_metadatas[]`, and each turn holds
`input_token_count`, `output_token_count`, `cache_read_input_token_count`,
`cache_write_input_token_count`, `total_request_count`, `model`, and a timestamp under
`result.Ok.meta.timestamp`. All of it is now read.

Kiro's event count went from 3 to 6 here — `kiro-usage-summary: 3` plus `kiro-cli-turn: 3`. Credit
entries and CLI turns come from different files, so they add rather than compete, and a test pins
that.

**Field names verified, values not.** The shape was read from real session files, but every token
count on this machine is zero, so nothing exercises a non-zero path against live data. The parser is
therefore defensive: a turn with neither tokens nor a request is skipped as bookkeeping, an
undateable turn is dropped rather than stamped with the current time, and a file without
conversation metadata yields nothing. It invents no totals. One real Kiro CLI session with spend
would confirm or correct it.

The cache-read split survives into `todayCacheReadTokens`, so Kiro cannot land back on the inflated
headline that `working-tokens-vs-cache-reads.md` fixed.

### One pass, not two

`readLatestContextPercent` and the new turn parser both wanted every CLI session file, so they were
merged into `readCLISessions`, which reads each file once and returns both signals.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `./build.sh` signed; app relaunched and running.
- `swift test`: **762 tests, 0 failures** (754 before this pass).
- New `Tests/ProviderGuidanceTests.swift` (2 tests): both guidance strings present and the two
  unhelpful ones gone, and both translated in all five locales.
- New `Tests/KiroCLITurnTests` (6 tests): every token field read with the cache split preserved, a
  zero-token turn still counting as a request (the only shape that exists on this machine), a
  bookkeeping turn skipped, timestamp fallback and the undateable turn dropped, missing metadata
  yielding nothing, and CLI turns joining the credit events with the token totals landing on the
  snapshot.
- Updated three existing tests that pinned the two replaced status strings.
- Measured before and after against this machine's real logs with a throwaway probe that read no
  credentials and was deleted.

## Follow-up: the daily goal was removed

Removed rather than retuned, on the user's decision. A goal that rewards spending more tokens runs
against what the app is for — it exists to keep you from running out — and the coherent version of
that feature, budget guardrails, already ships. The default target of 10,000 tokens was also two to
three orders of magnitude below a real day's *working* tokens, so it pinned at 100% regardless.

Taken out end to end: `DailyGoalService`, `AppSettings.challengeTargetTokens` (property, init
parameter, coding key, decode, and the clamp in the settings store), `TokenPilotViewModel.dailyGoal`,
Overview's `DailyGoalCard` with its `showsDailyGoal` condition and its slot in the Activity group's
badge count, the Settings stepper and its explanation, three localization keys in both the Swift
fallback table and the string catalog, and the goal-math test.

Two settings-persistence tests mentioned the target only as incidental payload; they now carry
another scalar so they keep covering what they are actually about. Old stored settings still decode
cleanly — an unknown key is ignored — so nothing has to migrate.

## Still open

- Adapter status messages other than the two above remain English-only.
