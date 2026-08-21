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

**2. A daily reset boundary carries sub-second jitter.** `rate-limit`'s reset moved from
`2026-08-24T00:00:00.865Z` to `2026-08-24T00:00:00.705Z` — the same instant, described twice with
different milliseconds, because the provider computes it from request time. Not fixed here:
normalising reset instants changes what `cycleID` is derived from, and that deserves its own pass.

**3. opencode's rolling window has no reset instant to report.** Its `resetsAt` was 5h00m00.596s
after one reading and 5h00m00.429s after the next: the API answers "five hours from now", every
time. A five-hour *rolling* window does not reset, so there is nothing here for a reset field to
hold — but as evidence it is a genuinely different reading every poll, and the app is faithfully
recording what it was told.

## What this changes today, honestly: nothing measurable

Cause 1 is fixed, and on an install without opencode's quota probe it is the whole story. On *this*
machine the probe is on, so cause 3 still makes the envelope differ every poll and the file is still
rewritten every 90 seconds. The fix is a precondition for the saving, not the saving.

The structural fix is to stop rewriting a four-megabyte envelope to append three records — an
append-and-compact journal rather than a whole-file commit. That is a redesign of a store built
around atomic replacement with transaction markers, checksums, and a backup generation, and it is
not something to start without the owner deciding it is worth the risk. Recorded here with the
numbers, rather than half-done.

## Also found

**opencode's weekly quota was labelled `roll`.** `windowLabel` groups `rolling`,
`opencode-go-rolling` and `rate-limit` under `roll`, and opencode gives `rate-limit` to its *weekly*
window — so the statusline read `OC roll 85% 2d` for a window that is the one thing `roll` says it is
not. It now reads `7d` for opencode; elsewhere the id names no period, so it stays `quota` rather
than being given one.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **833 tests**, and the five new
  ones were each checked by reverting the fix and watching the right one fail.
- The saving test fails without the fix with `("5") is not equal to ("1")` — five commits for one
  unchanged quota read five times.
- The sliding-horizon case is pinned by a test that asserts the commit *does* still happen, so the
  limit of the fix is recorded in the suite and not only here.

## Unrelated worktree activity during this pass

Between 09:30 and 09:35 another writer replaced `.gitleaks.toml`, added `.pre-commit-config.yaml`
and `Scripts/check-gitignore.sh`, and added a `secret-scan` job to `.github/workflows/ci.yml`. None
of it is part of this work and none of it was touched or committed here. It does break two
`SecurityPostureTests` assertions, which pin the previous gitleaks config — that failure belongs to
that change, not to this one. Two single-test failures were also seen in that window and did not
reproduce in six consecutive runs afterwards.
