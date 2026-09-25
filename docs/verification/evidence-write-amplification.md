# The evidence store rewrites four megabytes every ninety seconds

**Date:** 2026-08-21

Measuring runtime cost — the axis the benchmark pass had not covered — found the app idling at 0.0%
CPU and reclaiming memory properly, and writing about **7.7 GB a day** to disk.

## The measurement

`capacity-evidence-v2.json` is 3.98 MB, with a same-size `.backup`. Watching both on a real install:

```
write at 09:32:22
write at 09:33:52
write at 09:35:22
write at 09:36:52
```

Every 90 seconds, exactly. 8 MB per cycle, 40 cycles an hour.

Diffing two consecutive versions says what the rewrite bought:

```
generation 158322 -> 158323; records 7216 -> 7216
added 3, removed 3, identical 7213
```

Three records, and the three are the same three series carrying the same three values:

```
balance               changed: observedAt
opencode-go-rolling   changed: observedAt, resetAt, cycleID
rate-limit            changed: observedAt, resetAt
```

## The store already tries to prevent this

```swift
// Re-committing the whole envelope (encode + SHA256 + backup copy + fsync) costs hundreds of ms
// at realistic record counts, and bucket compaction makes most refreshes produce the same records,
// so skip the write when nothing changed.
```

The check is correct. Its stated premise — that compaction makes most refreshes produce the same
records — is false, and generation `158322` says it has been false for a long time.

## Three separate causes, only one of them a bug in this app

**1. The bucket re-picked its representative every poll.** Raw records are bucketed into five-minute
windows, and the bucket kept whichever reading had the latest `observedAt`. So every refresh
displaced the bucket's record with a newer one carrying the same value — new digest, new content,
full re-commit. A bucket that re-chooses on every poll is not a bucket. **Fixed:** a bucket keeps the
reading it has until the reading itself changes. Sameness is decided by comparing the whole record
with the timestamp set aside, so a field added later is covered without anyone remembering to list
it — a different value, authority, or reset instant still wins.

**2. A daily reset boundary carried sub-second jitter.** `rate-limit`'s reset moved from
`2026-08-24T00:00:00.865Z` to `2026-08-24T00:00:00.705Z` — one instant described twice, because the
provider recomputes it per request. The `cycleID` derived from that same value already truncates to
the second, so the stored instant disagreed with its own cycle identity. **Fixed:** a reset instant
is held to the second, matching the identity that was always derived from it.

**3. opencode's rolling window had no reset instant to report.** Its `resetsAt` sat 5h00m00.536s
after the observation — the window's own length — and did again on the next poll: the API answers
"five hours from now", every time. That is a horizon, not a reset. A countdown built on it reads
`5h 0m` forever, which is the app showing a number it cannot stand behind. **Fixed:** a window whose
reset sits its own length ahead of the moment it was asked is recorded with no reset instant. The
same API reports a real instant once a window has usage in it, which is what the monthly window does
at 99%, and those are untouched.

## What it changed, measured

Same install, same probes, before and after:

| | write interval | per day |
|---|---|---|
| Before | 90 seconds | ~7.7 GB |
| After | ~6 minutes | ~1.9 GB |

Roughly a quarter of the disk traffic, and the residue is now the bucket boundary itself — one
sample per series per five minutes, which is what the retention design says it wants. Read back from
the live store afterwards:

```
opencode-go-rolling  used=0   resetAt=None
rate-limit           used=15  resetAt=2026-08-24T00:00:00.000Z
```

The remaining structural question — an append-and-compact journal instead of re-committing a
four-megabyte envelope — is no longer urgent at this cadence, and it is a redesign of a store built
around atomic replacement with transaction markers, checksums and a backup generation. Left alone
deliberately.

## The same shape again, in a second store

Checking whether "today: 0 tokens" was a defect (it was not — Claude is switched off on this
install) turned up the app's preferences file doing the same thing: **786 KB rewritten every ninety
seconds**. Diffing two consecutive versions by key:

```
  same   tokenPilot.appSettings.v1              3,518 B
CHANGED  tokenPilot.limitSamples.v1           107,757 B
  same   tokenPilot.milestoneNotifications.v1     166 B
  same   tokenPilot.usageEvents.v3            694,663 B
```

Two causes, and the second only became visible after fixing the first:

**Saving unconditionally.** Both paths through `UsageHistoryStore.record` save, including the one
taken when a refresh brought nothing new — which is every refresh for anyone whose enabled providers
report no token events. 694 KB written to store the bytes already there. `setIfChanged` now guards
every encoded blob in the app, and a test asserts no store writes one directly.

**The same bucket defect as the evidence store.** `LimitHistoryStore` buckets samples into five
minutes and kept the newest, so re-reading an unchanged quota replaced the bucket's sample with one
carrying a later timestamp. Fixed the same way: a bucket keeps its reading until the reading changes.

That ordering matters as a lesson: fixing only the 694 KB blob would have looked like a 87% saving
and delivered nothing, because the preferences file is written **whole** when any key in it changes.
Measuring after the first fix is what showed the file still being rewritten on the same schedule.

## Both stores, measured together on the finished build

Ten minutes, one watch:

```
evidence write 1 at 11:10:49      prefs write 1 at 11:10:58
evidence write 2 at 11:15:19      prefs write 2 at 11:15:28
```

Each store now writes once per five-minute bucket instead of once per refresh.

| | before | after |
|---|---|---|
| capacity evidence | 8 MB / 90 s → ~7.7 GB/day | 8 MB / ~5 min → ~2.3 GB/day |
| app preferences | 786 KB / 90 s → ~0.75 GB/day | 786 KB / ~5 min → ~0.22 GB/day |
| **total** | **~8.5 GB/day** | **~2.5 GB/day** |

## Also found

**opencode's weekly quota was labelled `roll`.** `windowLabel` groups `rolling`,
`opencode-go-rolling` and `rate-limit` under `roll`, and opencode gives `rate-limit` to its *weekly*
window — so the statusline read `OC roll 85% 2d` for a window that is the one thing `roll` says it is
not. It now reads `7d` for opencode; elsewhere the id names no period, so it stays `quota` rather
than being given one.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **833 tests, 0 failures**, and each
  new guard was checked by reverting its fix and watching the right one fail.
- The saving test fails without the fix with `("5") is not equal to ("1")` — five commits for one
  unchanged quota read five times.
- The store cannot tell a sliding horizon from a moving reset, and a test asserts it still commits
  for one, which is why the third fix sits in the adapter that knows its own API rather than in the
  store.
- Live cadence re-measured on the rebuilt app: two writes in ten minutes, against forty an hour
  before.

## Unrelated worktree activity during this pass

Between 09:30 and 09:35 another writer replaced `.gitleaks.toml`, added `.pre-commit-config.yaml`
and `Scripts/check-gitignore.sh`, and added a `secret-scan` job to `.github/workflows/ci.yml`. None
of it is part of this work and none of it was touched or committed here. It does break two
`SecurityPostureTests` assertions, which pin the previous gitleaks config — that failure belongs to
that change, not to this one. Two single-test failures were also seen in that window and did not
reproduce in six consecutive runs afterwards.
