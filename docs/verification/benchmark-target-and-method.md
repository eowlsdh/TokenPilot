# What "benchmark level" means here, where the app stands, and how the work proceeds

**Date:** 2026-08-21

The standing goal is to bring TokenPilot to the level of the tools it was benchmarked against. Until
now that phrase had never been turned into something measurable: `benchmark-gap-analysis.md` named
the tools and wrote "target: 99/100 quality, top-10 store placement", which is a wish, not a
criterion. This file supplies the missing three: **what the target is, where the app stands against
it, and the method used to close the distance.**

## 1. The target, defined

The benchmarked tools are single-purpose:

| Tool | What it is | What it competes on |
|---|---|---|
| [ccusage](https://github.com/ryoppippi/ccusage) | CLI | 5-hour billing blocks, live watch, JSON |
| [toktrack](https://github.com/mag123c/toktrack) | CLI | local cache with retention, receipts |
| [tokencap](https://github.com/helsky-labs/tokencap) | CLI | 60s polling, rolling %, tier colours |
| [claude-status-macos-menu-bar](https://github.com/bcollard/claude-status-macos-menu-bar) | menu bar | at-a-glance status |
| Claude Code `/usage` | built-in | plan bars, weekly credits |

So "benchmark level" cannot mean *match ccusage feature for feature* — TokenPilot is a twelve-
provider menu bar app with a CLI, not a Claude-only CLI. It is defined here as three conditions,
all of which have to hold:

1. **On every axis those tools compete on, be at or beyond them.** Not "have something similar" —
   the equivalent capability, reachable by a user, verified against a real install.
2. **On the axes they do not have, ship at the same standard.** Twelve providers is worth nothing if
   four of them are stale on a real machine; five languages is worth nothing if one is 18% translated.
   Breadth only counts where it is backed.
3. **Behave like a utility someone leaves running.** A menu bar app is judged on what it does while
   nobody is looking: disk, CPU, memory, and what it leaves behind.

Condition 3 is the one no benchmarked CLI has to meet — they run and exit — and it is where this
app was worst.

Out of scope, deliberately: "top-10 placement" is not an engineering criterion and is not tracked
here. What is tracked is everything that would have to be true for it to be possible.

## 2. Where the app stands

Scored against the definition above. Evidence is a measurement or a file, never an impression.

| Axis | Target | Now | Verdict |
|---|---|---|---|
| Provider coverage | more than any benchmarked tool | 12 in `Provider.allCases` | **beyond** |
| Provider depth | every enabled provider reports fresh, correct data | 6 measured on real sources, 5 correct, 1 defect fixed; 6 not installable here | **at, for what can be measured** |
| Truthfulness of measurement | activity never shown as quota | authority / comparability / stability / freshness per observation | **differentiator** |
| CLI | ccusage/toktrack parity | 8 commands, shared flag vocabulary, 4 output formats, `blocks --watch` | **at or beyond** |
| Menu bar | claude-status parity | separate or combined items, width budget, trend or remaining bar | **beyond** |
| History & analysis | toktrack retention | 45-day store, heatmap, blocks, model/project breakdowns | **beyond** |
| Alerting | any threshold, every watched provider | 1–100, editable, reaches every provider-reported series | **at** |
| Localization | complete in every shipped language | 746 keys × 5, single reachable surface | **at** (was 18% for zh-Hant) |
| Resource behaviour | invisible when idle | 0.0% CPU idle; ~2.5 GB/day writes | **partial** — was 8.5 GB/day |
| Test & guard quality | a failing test means a real defect | 846 tests; every fix's guard verified by reintroducing the defect | **at** |
| Release readiness | shippable artifact | signed unsandboxed build; screenshots/ASC outstanding | **blocked on a person** |

One axis is not green. **Resource behaviour is partial**: a four-megabyte envelope is still
re-committed to append three records, and that is a store redesign rather than a fix.

Provider depth was the **unknown** when this table was first written; §4 measured it and it is now
the strongest row backed by evidence rather than by a count — five of six locally installed providers
were correct, the sixth had a real defect, and the six that cannot be exercised on this machine are
recorded as unmeasured rather than counted as working.

## 3. The method

This is the part that was being run without being written down. It is four rules and they exist
because each was learned by getting it wrong.

**Measure the running app, not the source.** Reading code produces plausible theories; the app on
this machine produces facts. Every defect worth finding this week came from watching a file, diffing
two versions of it, or counting what was on disk — not from reading the function that wrote it.

**A fix is not done until the number moves.** After fixing the evidence store, the write rate was
unchanged, and saying so was the only reason the second and third causes were found. After fixing the
694 KB preferences blob, the file was still rewritten on the same schedule, because preferences are
written whole. Re-measure, and report the number that came out — not the one the change should have
produced.

**Every guard is verified by reintroducing the defect.** A guard that has never failed is a guess. Of
the guards written this week, three passed with the bug back in place: one asked about a key no
catalog carries, one re-implemented the teardown instead of calling it, and one compared against a
hardcoded list that had since grown. All three were rewritten.

**Check the harness before believing the result.** Measurements have lied more often than the code
has. `timeout` does not exist on macOS; zsh does not word-split unquoted parameters; a glob over
12,000 files silently returns nothing; and `swift build` does not build `Tests/`, so a run that
compiled cleanly and executed zero tests reported a perfect leak count of zero. When a result is
surprisingly good, suspect the harness first.

**How this shapes prompting.** The useful instruction is not "improve the app" and not "fix X" — it
is *"measure X on the running app, close the largest gap the measurement shows, then prove the number
moved."* A standing goal plus that loop is what has been producing findings; the loop picks the work,
so the prompt does not have to. The rubric in §2 is what tells the loop which axis to point at: the
weakest row with the least evidence, which is why the next section is provider depth.

## 4. What the method says to do next

Provider depth, because it is the only **unknown** in the table and it is what the app is for. The
question to answer with measurement, not with the README: *for each of the twelve providers, on a
machine where that tool is installed, does TokenPilot report data, is it fresh, and is it labelled
with the right authority?*

Done — recorded in `provider-depth-audit.md`. It found one defect: Codex was the only local-log
adapter that could never go stale, so a session log two hours old still read "Connected" and its
five-hour window at 100% was presented as current provider-reported quota.

The loop's next pointer, by the same rule (weakest row, least evidence): **provider depth for the six
that could not be exercised here** — jetbrains, minimax, zai, openrouter, commandcode, deepseek. That
needs either the tool installed or a fixture built from its real file format, and a fixture is the
honest option since it can be checked into the repo.
