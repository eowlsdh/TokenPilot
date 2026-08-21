# The test suite was filling the user's preferences folder

**Date:** 2026-08-21

Found while looking for something else: `defaults domains` on this machine took a visible pause, and
the reason was in the output.

## The measurement

```
~/Library/Preferences: 12,157 plist files
  of which TokenPilot test artefacts: 11,641   (96%)
```

Grouped by the suite that made them:

```
4,279  TokenPilotTests-<UUID>
  522  TokenPilotLimitHistoryTests-<UUID>
  428  milestone-notification-test-<UUID>
  415  TokenPilotUsageHistoryStatuslineTests-<UUID>
  ...
```

A full `swift test` added 33 to 61 more. Every run, on every machine that runs the suite, including
CI.

## Two flavours, one cause

33 call sites opened a preferences suite named with a fresh UUID. Twenty-two of them removed the
domain afterwards and still left a **42-byte husk**, because emptying a domain does not delete its
file. The other eleven removed nothing at all, so the test's own data — settings, alert delivery
state, usage events — stayed in the user's preferences.

## What did not work, measured rather than assumed

**Removing the file in teardown.** The suite's file came back: the preferences daemon holds the
domain and writes it out on its own schedule, after the test that removed it.

**Sweeping again when the test bundle finishes.** Still 33 to 61 files a run — the daemon's write
can land after the process that made the suite has gone.

Both were measured, not reasoned about, which is the only reason the second one was caught. On the
first attempt the numbers looked perfect — *zero* new files across two runs — and they were
meaningless: the test target had failed to compile, so nothing ran. `swift build` does not build
`Tests/`, so the strict build was clean and the run had produced no tests at all. The delta was zero
because nothing happened.

## What works

A test is given no preferences suite at all. `InMemoryDefaults` is a `UserDefaults` subclass holding
its values in a dictionary, so there is nothing on disk to clean up.

`object(forKey:)`, `set(_:forKey:)` and `removeObject(forKey:)` are the primitives every other
accessor funnels through, which is why overriding those three carries `data(forKey:)`,
`integer(forKey:)`, `bool(forKey:)` and `string(forKey:)`. That is the documented contract and a
test checks it anyway — if it were wrong, a store would quietly read the real preferences and the
test would pass for the wrong reason.

## Verification

- **837 tests, 0 failures**, twice, each measured 20 seconds after the run so the preferences daemon
  had time to flush: `plists 12,157 -> 12,157`, delta **0**. Before: 33 to 61 per run.
- Guards: no test may open a suite directly (the door stays single), writing preferences adds no file
  to `~/Library/Preferences`, every typed accessor reaches the in-memory storage, and two tests
  cannot see each other's values or the real defaults.

## Left for the owner

The 11,641 files already there are not removed by this change — that is a bulk delete in someone's
home directory and belongs to them. Every one matches a suite name this project's tests mint, with a
UUID:

```sh
find ~/Library/Preferences -maxdepth 1 -name "*.plist" | \
  grep -E '/(TokenPilot|TokenBar|milestone-notification-test|deepseek-alert|budget-alert-test|provider-status-test)[A-Za-z-]*-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist$' | \
  xargs rm
```

Run without `| xargs rm` first to read the list. It matches 11,641 of the 12,157 files and leaves
every real application's preferences alone.
