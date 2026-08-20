# App Store listing copy

Draft text for App Store Connect. Every claim here is checked against what the app actually does —
if the app changes, this changes with it. Pair with `docs/app-store-review-notes.md`, which holds the
reviewer notes and the App Privacy answers.

## Name and subtitle

- **Name:** TokenPilot
- **Subtitle (30 char max):** `AI coding usage in your menu bar` — 32 characters, so trim to
  `AI coding usage, menu bar` (25).

## Promotional text (170 char max, editable without review)

> See how much of your AI coding assistant quota is left without opening a dashboard. Reads what the
> tools already write on your Mac. No account, no telemetry.

## Description

> **Know how much you have left before you run out.**
>
> TokenPilot puts your AI coding assistants' remaining usage in the macOS menu bar. It reads the
> usage metadata those tools already write on your own Mac — nothing is uploaded, and there is no
> account to create.
>
> **One glance, several assistants**
> Claude Code, Codex, opencode, Kiro, Command Code, Antigravity, Grok, JetBrains AI Assistant,
> DeepSeek, MiniMax, Z.ai, and OpenRouter. Show them as one combined menu bar item or as separate
> items, at the width you choose.
>
> **It tells you what it actually knows**
> Some assistants publish a real remaining percentage. Others publish nothing, and all TokenPilot can
> see is local activity. It never turns the second kind into the first: activity is labelled as
> activity, estimates as estimates, stale readings as stale. If a number is a guess, it says so —
> the point of a limit monitor is that you can trust it.
>
> **Warnings before the wall, not after**
> Set thresholds per provider and window. Alerts can go to macOS notifications, and optionally to
> Telegram or Discord if you set those up yourself.
>
> **History that answers questions**
> Daily and weekly trends, an activity heatmap, cost and cache efficiency, and a breakdown by model
> and by project. Export to JSON or CSV, with prompts, file paths, and credentials excluded.
>
> **In your terminal too**
> One TokenPilot line for your CLI status line — model, remaining quota, today's tokens and cost.
>
> **Private by construction**
> No account. No analytics. No telemetry. Prompts, responses, API keys, OAuth tokens, and cookies
> are never read — credential files are excluded by name before any file is opened. Network access
> only happens for provider APIs you enable with your own key, and for alerts you configure.
>
> Available in English, Korean, Japanese, Simplified Chinese, and Traditional Chinese.
>
> TokenPilot is an independent utility and is not affiliated with, endorsed by, or sponsored by
> Anthropic, OpenAI, Google, xAI, DeepSeek, Amazon, JetBrains, MiniMax, Z.ai, or OpenRouter.

## Keywords (100 char max, comma separated, no spaces)

```
ai,usage,quota,tokens,claude,codex,menubar,limit,monitor,developer,cost,statusline
```

82 characters. Deliberately excludes trademarks used as the primary hook and any competitor name.

## What's New (first release)

> First release. Menu bar readouts for twelve AI coding assistants, threshold alerts, usage history
> with cost and cache breakdowns, JSON/CSV export, and a CLI status line — all reading local files,
> with no account and no telemetry.

## Screenshots — what to capture

Cannot be produced from here: the popover has to be opened by hand, and screen capture needs
permission this environment does not have. Five shots, from the **sandboxed** build
(`TOKENPILOT_ENTITLEMENTS="$PWD/Resources/TokenPilot-AppStore.entitlements" ./build.sh`), 2560×1600:

1. **Menu bar close-up** — the provider blocks in the bar, cropped to the bar itself. This is the
   product; it should be shot first and used as screenshot 1.
2. **Overview** — capacity rows with at least one provider-reported percentage and one local-activity
   row, so the honesty distinction is visible.
3. **History** — the trends group expanded, showing the heatmap and the cost/cache cards.
4. **Settings → Source Health** — the provider list with grant buttons, which is what a reviewer
   will want to see.
5. **Setup Guide** — the Claude bridge card with its copy button.

Crop out the desktop, other menu bar items, usernames, local paths, and any unrelated app content.
If no real data is available, Settings → Privacy → "Preview sample data when no source is connected"
fills the UI with values clearly labelled `MOCK`; that labelling must stay visible in the shot.

## Claims deliberately not made

- No "official quota" language for providers where TokenPilot infers from local activity.
- Grok's local reading is remaining **context window**, not subscription quota, so it is not
  described as a limit.
- No "track your spending" claim beyond what the assistants themselves record.
- No affiliation, endorsement, or partnership implied with any provider.
