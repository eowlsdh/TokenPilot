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

- `swift test`: **846 tests, 0 failures**. Both new guards were checked by putting the hardcode back:
  the behavioural one fails on a 130-minute-old session, the source one names line 2151.
- Re-measured on this machine after the fix:
  `codex  localLog  medium  stale=true  age=135m  5h=100%  STALE · no Codex activity in 15 minutes`
- The five correct rows were confirmed against file modification times, not taken on trust.

## What this leaves

Six providers could not be measured here because the tool is not installed or needs a key this
machine does not hold: jetbrains, minimax, zai, openrouter, commandcode, deepseek. Their adapters
returned `Disabled`, which is correct but is not evidence that they work. Depth for those six stays
**unknown**, and the honest place to record that is here rather than in a claim of twelve.
