# Provider depth: twelve providers, measured one at a time

**Date:** 2026-08-21

`benchmark-target-and-method.md` scored eleven axes and left exactly one **unknown**: provider
depth. Twelve providers is the app's headline number and no one had ever checked what each of them
actually reports on a real machine. This is that measurement.

## The question

For each provider, on a machine where that tool is installed: does TokenPilot report data, is it
fresh, and is it labelled with the right authority?

Answering it required driving each adapter directly — the settings on this install have ten of the
twelve switched off, so the running app was not exercising them. A temporary harness ran every local
adapter against this machine's real sources, printed one line each, and was deleted afterwards.

## The measurement

```
provider    source     conf    stale   age      tokens       windows   status
claude      localLog   medium  false   0m       577,737,023            Local JSONL · connect the statusline for limits
gemini      unknown    low     false   0m       0                      Statusline connected · waiting for the first session
codex       localLog   medium  FALSE   130m     760,354      5h=100%   Codex rate limits · provider-reported
xai         localLog   low     true    2148m    0                      STALE · LOCAL · Grok Build context window
opencode    localLog   medium  true    2702m    0                      STALE · no opencode activity in 15 minutes
kiro        localLog   medium  true    30969m   0            mo=17%    STALE · no Kiro activity in 15 minutes
```

Five rows are correct and confirmable against the filesystem: Grok and opencode have written nothing
since August, Kiro nothing since the 7th, Gemini nothing since the 19th, and Claude is being used
right now.

One row is not. **Codex reported `stale=false` on a session log 130 minutes old**, and described a
five-hour window at 100% as "provider-reported".

## What it was

Every sibling local-log adapter derives the flag — Claude from its file's modification date, Grok,
opencode and Kiro from their own activity thresholds. `CodexLocalSessionAdapter` alone had it written
in as a literal:

```swift
dataSource: .localLog,
isExperimental: true,
isStale: false,
```

So Codex could never go cold. The flag feeds the Overview card's "Stale" label and its warning
colour, and the provider status the Setup Guide shows — `if snapshot.isStale { status = .stale }
else { status = .connected }`. Codex was permanently "Connected".

The claim underneath is the part that matters: a five-hour window that was full two hours ago may
have reset since, and presenting it as current provider-reported quota is the one thing this app
does not do.

It now derives the flag at 15 minutes, which is the threshold the capacity pipeline already applies
to Codex's own windows (`maximumAge: 15 * 60`) — so the provider row and the capacity card can no
longer disagree about the same reading. A test asserts the two stay equal.

## A false lead, and a real one the guard found

Codex's newest *file* was written eleven minutes before the measurement, which looked at first like
the adapter missing fresh data. It was not: those files are plugins, caches and a SQLite journal.
The newest session `.jsonl` is genuinely 09:10, and the adapter had read it correctly. The adapter
was right about the age and wrong about what to do with it.

The first version of the staleness guard banned the literal outright and flagged nine lines. Eight
were legitimate — a freshly fetched DeepSeek balance, a value the user typed, a statusline file that
parsed but carried nothing — so the guard was wrong as written. It is now scoped to snapshots built
from a local log, which is the only source that ages. Narrowing it did not cost anything: with the
literal put back it still names the exact line, 2151.

## Verification

- `swift test`: **855 tests, 0 failures** across both rounds. Every guard was checked by putting the
  defect back: the Codex behavioural one fails on a 130-minute-old session and the source scan names
  line 2151; the JetBrains set fails six ways including a 21-day gap between the stamped and the real
  reading time; the DeepSeek one fails when its cached fallback is dressed as current.
- Re-measured on this machine after the fix:
  `codex  localLog  medium  stale=true  age=135m  5h=100%  STALE · no Codex activity in 15 minutes`
- The five correct rows were confirmed against file modification times, not taken on trust.
- The existing localization guard caught the two new status strings before they shipped untranslated,
  which is what it is for.

## Round two: the six that could not be exercised here

jetbrains, minimax, zai, openrouter, commandcode and deepseek returned `Disabled` on this machine —
correct, and not evidence that they work. None of them needs the real tool to be measured: JetBrains
reads a file, the other three take an injectable HTTP client and a keychain backend, and commandcode
reads a project tree. Fixtures were built from each one's real format and the adapters driven end to
end.

The existing tests covered every one of these **parsers** and none of the adapters around them.
That distinction is exactly where the Codex defect lived: the parser was right and the adapter
mislabelled what it produced.

### JetBrains: a three-week-old cache reported as a reading taken now

Worse than the Codex defect, for a specific reason:

```swift
updatedAt: now,          // the quota file is a cache the IDE wrote whenever it last synced
confidence: .high,
dataSource: .localLog,
isStale: false,
```

Codex at least carried the true observation time, so the capacity pipeline's 15-minute freshness
policy could still catch it. JetBrains stamps `now`, which makes the pipeline's own check
(`maximumAge: 24 * 60 * 60`) **unreachable** — a quota cache from three weeks ago is assessed as an
observation from this instant, at high confidence, with no stale marker on any surface.

Fixed: the reading is dated when the cache was written, staleness derives from that against the same
24 hours the pipeline uses, and a stale cache drops to medium confidence and says so.

### The other five were already right

| Provider | Shape | Verdict |
|---|---|---|
| minimax, zai, openrouter | live fetch, no cache, `updatedAt: now` | correct — a fetch made this second *is* fresh, and a failure returns no window at all |
| deepseek | live fetch **with** a cached fallback | correct, and the only place in the app that already had this right: the fallback drops to medium confidence and says `stale · last successful value` |
| commandcode | local project tree | already covered end to end, staleness included |

DeepSeek's cached fallback is the pattern Codex and JetBrains were missing, and it had no test. It
has one now, because it is the behaviour the other two were fixed *to*.

### The guard that missed it, and why

`testNoLocalLogSnapshotHardcodesFreshness` was written in round one and passed. It read one file —
the one Codex lives in. JetBrains lives in another. Scanning a single file while looking complete is
the same failure the alert-catalogue scanner had earlier this month, and the fix is the same: walk
the directory, and assert the scan found enough to be believable.

Widening it surfaced two more `updatedAt: now` sites, both false positives: a "quota file not found"
and a "context window unavailable" snapshot, neither of which carries a reading whose age could be
misreported. The guard now requires the snapshot to carry a `LimitWindow` or token total before it
counts. That is the second over-broad source scan this session; both were caught by looking at what
they flagged rather than trusting the count.

## Where depth stands now

| Provider | Measured how | Verdict |
|---|---|---|
| claude, gemini, xai, opencode, kiro | real sources on this machine | correct |
| codex | real sources on this machine | defect found and fixed |
| jetbrains | fixture in the real file format | defect found and fixed |
| minimax, zai, openrouter | fixture responses, injected client and keychain | correct |
| deepseek | fixture responses, cached-fallback path | correct, now pinned |
| commandcode | project-tree fixture | correct, already pinned |

Twelve of twelve are now backed by something other than a count.
