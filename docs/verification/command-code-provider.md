# Provider addition: Command Code

**Date:** 2026-08-20

**Scope:** Adds Command Code (`cmd`, commandcode.ai) as a local-first provider, and fixes a
settings-persistence bug the wiring exposed.

## What Command Code exposes, and what TokenPilot takes

| Signal | Where it lives | Taken? |
|---|---|---|
| Per-turn tokens and cost | `~/.commandcode/projects/<project-slug>/<session-id>.jsonl` | **Yes** — the values Command Code records itself |
| Rolling dollar limits ($3/$6 Go, $14/$35 GOAT, $16/$40 Pro, $45/$90 Max 10×, $90/$180 Max 20× over 5 hours / 7 days) | `/usage` in the CLI and the Studio usage page, server-side | **No** — not published locally |
| API key | `~/.commandcode/auth.json` | **Never read** |
| Taste data, prompts, checkpoints | project directory, `<id>.prompts.jsonl`, `<id>.checkpoints.jsonl` | **No** |

Because the plan meters are dollar-denominated and only available behind the API key, this
provider is deliberately **activity-only**: local spend is shown as spend, never converted into a
remaining-quota percentage. A dollar figure derived from local transcripts is not a subscription
window, and labeling it as one would be a guess wearing the provider's name.

## Implementation

- `Sources/TokenCore/Services/CommandCodeAdapter.swift` — reads transcripts under the project
  roots, newest first, capped at 200 files. Skips the sidecar files (`.meta.json`,
  `.prompts.jsonl`, `.checkpoints.jsonl`, `.share.json`) and refuses any candidate whose name
  looks like a credential store. Entries with neither tokens nor cost (header, prompts, model
  switches, compaction summaries) are skipped rather than counted as empty turns.
- Project labels keep the **trailing folder name only** (`-Users-me-dev-myapp` → `myapp`), so the
  working directory a slug encodes cannot reach an event, an export, or the History breakdown.
- Capacity: a `session-cost` currency series and a `context` token series, both
  `localDerived` + `incomparable`, so they render as activity and stay alert-ineligible. No percent
  observation is ever produced.
- Registered in `UsageStore.defaultAdapters`, `DefaultPathResolver` (`root`, `projects`),
  `DataSourceConnectionService`, menu bar label (`CMD`), Settings (setup disclosure, setup-guide
  card, provider order), and the palette (rose-plum accent, measured 6.37:1 on card and 5.54:1 on
  muted card in light appearance, 7.23:1 on the dark card).
- Localization: 9 strings across en/ko/ja/zh-Hans/zh-Hant in the Swift supplemental table, matching
  how the other provider strings are carried.

### Field names are inferred

The transcript schema is not published, and no Command Code sessions exist on the development
machine (only `~/.commandcode/settings.json` and `skills/`), so the parser accepts several
spellings per field — `input_tokens`/`inputTokens`/`prompt_tokens`, `cost_usd`/`cost.total_usd`/
`cost`, `timestamp`/`ts`/`createdAt`, `model`/`model.id`/`model_id` — and drops entries it cannot
read rather than guessing values. **One real session file would confirm or correct this**; until
then the parser is defensive, not verified against live data.

## Bug found while wiring: providers turned themselves off on relaunch

`AppSettings.init(from:)` never decoded `jetbrainsEnabled`, `minimaxEnabled`, `zaiEnabled`, or
`openrouterEnabled`. Those flags therefore came back as `false` on every load, and because
`enabledProviders` intersects the legacy flags with the monitored set, a provider the user had
switched on disappeared at the next launch with no message. All five flags (the four plus
`commandcodeEnabled`) are now decoded, and a regression test asserts that **every** provider
survives a settings round trip, so the next provider cannot repeat it.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean.
- `swift test`: 699 tests, 0 failures (670 before this pass).
- New `Tests/CommandCodeAdapterTests.swift` (29 tests): snake_case/camelCase/nested-cost parsing,
  bookkeeping and timestamp-less entries skipped, malformed lines tolerated, transcript text and
  paths never reaching events, slug→folder-name labels with a length cap, sidecar and
  credential-named files excluded from discovery, file cap, today totals and balance, honest
  staleness, retention window, no quota window ever produced, disabled provider short-circuit,
  end-to-end read from a temporary project tree, activity-only capacity observations,
  alert-ineligible assessments, and localization coverage for all five locales.
- Updated: the two existing provider-coverage tests that pin the provider list and menu bar labels.

## Not covered

- No live data on this machine: the adapter has not been run against a real Command Code session.
- `/usage` and Studio meters are not read; there is no plan/limit display for this provider.
- No manual entry for the 5-hour/7-day dollar caps yet — that is the obvious follow-up if the
  windows should appear in the menu bar.
