# TokenPilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014+-lightgrey.svg)](https://github.com)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Localization](https://img.shields.io/badge/Locales-EN%2FKO%2FJA%2FZH-blueviolet.svg)](#localization)

> **A local-first macOS menu bar monitor for AI coding quota and local context usage.**
> TokenPilot keeps Claude Code, Codex, Antigravity CLI with legacy Gemini telemetry, DeepSeek balance, and Grok local-context signals visible without a cloud dashboard, browser tab, or provider-token collector. Grok/xAI reads only numeric local context metadata.
>
> TokenPilot is not affiliated with OpenAI, Anthropic, Google, DeepSeek, or xAI.

[한국어 README](README.ko.md) · [日本語 README](README.ja.md) · [简体中文 README](README.zh-CN.md)

![TokenPilot screenshot showing Antigravity CLI statusLine diagnostics, remaining quota overview, DeepSeek balance, and privacy-first settings](docs/assets/readme-screenshot.png)

---

## Why TokenPilot?

AI coding tools expose signals in different places: Claude statusline JSON, Antigravity `statusLine` JSON, Gemini telemetry, manual `/status` output, official balance APIs, or local context metadata. TokenPilot turns those local signals into one compact macOS menu bar readout:

```text
5h 18% · W 53%
```

The numbers are **remaining quota percentages** where provider quota is available. Grok shows remaining local context, which is not comparable to provider quota.

---

## Current app surfaces

| Surface | What changed / what it shows |
|---|---|
| **Menu bar** | Single-line remaining quota or local-context label: `5h`, weekly, and estimated/manual suffixes when needed. |
| **Overview** | Capacity-first current evidence card, provider capacity rows, refresh/recovery notes, and alert status. No local activity analytics cards. |
| **History** | Capacity evidence timeline plus usage event summary and JSON/CSV export. Local activity seven-day/provider-share summaries are export-only compatibility data, not provider quota or visible dashboard surfaces. |
| **Settings** | Provider Diagnostics, Codex limit hints connector, DeepSeek balance/API key setup, local Grok context diagnostics, manual fallback, notifications, Telegram/Discord, language, setup, and privacy boundaries. |

---

## Features

| Feature | Description |
|---------|-------------|
| 🍎 **Native menu bar utility** | AppKit `NSStatusItem` with an `NSPopover`, compact display, and no Dock icon. |
| 📊 **Multi-provider monitoring + setup** | Claude Code, Codex, Antigravity CLI with legacy Gemini telemetry, DeepSeek balance, and local Grok context metadata in one place. |
| 🧭 **Remaining-first quota UI** | Limit cards prioritize what is left, not what was consumed. |
| 🔒 **Local-first by default** | Reads local usage metadata; optional connectors and notifications are user-enabled. |
| 🏷️ **Honest confidence labels** | Official, local, manual, estimated, experimental, and limit-hint data are visibly distinct. |
| 🔔 **Alerts** | macOS notifications plus optional Telegram/Discord threshold and reset alerts. |
| 💵 **DeepSeek balance** | Optional `/user/balance` integration shows official `topped_up_balance`, native currency, manual fallback, and low-balance alerts. |
| 🧰 **Grok/xAI source** | Reads only numeric local context metadata from `~/.grok/sessions/**/signals.json`; it never reads `auth.json`, OAuth tokens, prompts, or responses. |
| 📈 **History + export** | Capacity evidence history, usage event totals, and JSON/CSV export; local activity seven-day/provider-share summaries are compatibility export fields only. |
| 🌐 **4 languages** | English, 한국어, 日本語, 简体中文. |
| 📦 **No third-party packages** | Pure Swift / SwiftUI / AppKit bridge. |

---

## Quick Start

### Option 1: Download a Release

Download the latest `TokenPilot.zip` from GitHub Releases, unzip it, then open `TokenPilot.app`.

If macOS Gatekeeper asks for confirmation on an unsigned or ad-hoc signed build, right-click the app and choose **Open**.

### Option 2: Build from Source

```bash
git clone https://github.com/eowlsdh/TokenPilot.git
cd TokenPilot
make bundle
open build/TokenPilot.app
```

### Option 3: Xcode

```bash
git clone https://github.com/eowlsdh/TokenPilot.git
cd TokenPilot
xcodegen generate
open TokenPilot.xcodeproj
# Press Cmd+R
```

---

## How It Works

TokenPilot reads **usage metadata** from local files and explicitly configured sources. It does not read prompts, responses, browser cookies, or provider auth files.

| Provider | Data Source | Trust Level |
|----------|-------------|-------------|
| **Claude Code** | Statusline JSON + local project JSONL fallback | High when statusline/rate-limit fields are present. |
| **Codex** | Opt-in Codex CLI limit hints, manual `/status` / manual estimates, local activity JSONL | Medium/estimated/unofficial unless Codex exposes stable official quota metadata. |
| **Antigravity CLI** | TokenPilot statusLine JSON bridge at `~/Library/Application Support/TokenPilot/antigravity-statusline.json`; legacy Gemini `~/.gemini/telemetry.log` remains supported | High for Antigravity statusLine and Gemini telemetry metadata. |
| **DeepSeek** | Optional API-key request to official `/user/balance`, plus manual fallback | High for official balance responses; manual values are clearly labeled. |
| **Grok / xAI** | Numeric local context metadata from `~/.grok/sessions/**/signals.json` only | The menu bar shows remaining local context (`100 - contextWindowUsage`), not subscription quota or API billing. |

### Provider diagnostics

First-run setup is centered in **Settings → Provider Diagnostics**:

- Each provider shows status, confidence, last checked time, and next action.
- Diagnostics summarize local metadata availability without showing raw paths, prompts, responses, cookies, tokens, or raw events.
- Codex connector state is explicit: off, manual, local activity, or unofficial limit hints.
- DeepSeek balance setup is explicit: no API key, official balance connected, stale balance, or manual fallback.
- Grok/xAI diagnostics report only local signal availability and remaining local context; TokenPilot has no credentials, account identifiers, OAuth, or provider-quota claims.

### Grok / xAI source

TokenPilot reads only numeric local context metadata from:

```text
~/.grok/sessions/**/signals.json
```

It never reads `auth.json`, OAuth tokens, prompts, responses, or provider billing/subscription data. Grok's menu-bar value is remaining local context (`100 - contextWindowUsage`); it is not provider quota and must not be compared with provider quota or API billing.

### Antigravity CLI setup

The Gemini-facing provider slot now defaults to **Antigravity CLI**:

1. Open **Settings → Setup Guide → Connect Antigravity CLI**.
2. Run the generated bridge script once; it registers Antigravity's `statusLine` command.
3. Restart or re-open Antigravity CLI, run any prompt, then check this file in TokenPilot:

   ```text
   ~/Library/Application Support/TokenPilot/antigravity-statusline.json
   ```

The bridge stores only allowlisted token metadata such as model id/display name, context-window input/output totals, current usage token counts, and percentages. It does **not** store prompt text, response text, email, cwd/workspace path, provider auth material, or arbitrary Keychain data. Existing `~/.gemini/telemetry.log` remains supported as the only legacy Gemini source.

### Menu bar display

```text
5h 18% · W 53%          # remaining 5-hour and weekly quota
5h 8% · W 31% ⚠️        # low remaining quota / warning state
5h 74% · W 80% est.     # estimated/manual Codex values
Co 12.3Ktok             # fallback when only local activity exists
Grok 42% ctx             # remaining local context, not provider quota
DS $12.34                # selected DeepSeek topped-up balance
```

---

## Screenshots

The README screenshot is a release-facing composite of shipped app surfaces:

- Menu bar: compact remaining quota plus selected DeepSeek balance (`DS $12.34`).
- Overview: capacity-first evidence card, provider capacity rows, refresh/recovery notes, and alert status.
- History: capacity evidence timeline and usage-event export controls; local activity seven-day/provider-share summaries are export-only compatibility data, not provider quota, and not visible dashboard surfaces.
- Settings: provider diagnostics, Antigravity statusLine bridge, Codex limit hints, DeepSeek Keychain setup, Grok local-context diagnostics, and privacy boundaries.

---

## GitHub Release positioning

TokenPilot is positioned as a **local-first AI coding usage meter for the macOS menu bar**:

- **No cloud dashboard**: usage stays on-device.
- **No account required**: no TokenPilot account or provider login flow.
- **No provider token collection**: Codex/Telegram/Discord/DeepSeek secrets are stored only when explicitly configured, never shown or exported; Grok auth material is never read.
- **Honest confidence labels**: official, local, manual, estimated, experimental, and limit-hint sources are visibly distinct.
- **Release artifacts**: `make bundle` produces `build/TokenPilot.app` and `build/TokenPilot.zip`.

Release copy must stay evidence-bound: do not claim notarization, App Store availability, provider account validation, or exact provider billing/quota authority unless those checks were actually performed.

---

## Privacy

TokenPilot is designed as a **local-first** utility:

| ✅ Reads | ❌ Never reads |
|----------|---------------|
| Claude statusline JSON | Browser cookies |
| Antigravity statusLine JSON bridge / Gemini `telemetry.log` | Provider auth files |
| User-entered Codex values | Raw prompts/responses |
| User-saved DeepSeek API key in TokenPilot Keychain item | Exported secrets |
| Grok numeric local context metadata from `~/.grok/sessions/**/signals.json` | `auth.json` and OAuth tokens |
| Local session JSONL metadata (where supported) | Grok prompts/responses |
| TokenPilot-owned notification credentials | Other apps' Keychain items |

External notifications (Telegram/Discord) are **off by default** and require explicit user configuration. Codex Limit Hints Connector is also off by default and talks to the local Codex CLI app-server rather than reading Codex auth files directly. DeepSeek balance is opt-in and uses a TokenPilot-owned Keychain item for the API key; exports omit secrets. Grok/xAI reads only numeric local context metadata from `~/.grok/sessions/**/signals.json`; it does not read `auth.json`, OAuth tokens, prompts, responses, subscription quota, or API billing.

See [Privacy](docs/PRIVACY.md) and [Security](SECURITY.md) for details.

---

## Architecture

```text
Sources/
├── TokenApp/                         # AppKit app shell, views, ViewModel
│   ├── TokenMonitorApp.swift          # App entry, NSStatusItem, and NSPopover
│   ├── Views/                         # Overview, History, Settings, components
│   └── Resources/Localizable.xcstrings
└── TokenCore/                         # Business logic, adapters, models
    ├── Models/                        # Provider snapshots, settings, usage models
    ├── Services/
    │   ├── DataSourceAdapters.swift    # Claude/Codex/Antigravity/legacy-Gemini/DeepSeek adapters
    │   ├── AggregationService.swift    # Usage aggregation
    │   ├── MenuBarStatusService.swift  # Menu bar label formatting
    │   ├── UsageHistoryStore.swift     # Historical usage persistence
    │   └── TokenPilotServices.swift    # Notifications, Keychain, export
    └── TokenPilotLocalization.swift
Tests/
├── TokenMonitorTests.swift
└── TokenPilotServicesTests.swift
```

---

## Testing

```bash
swift test

swift build -Xswiftc -warnings-as-errors
# strict build with warnings as errors

make verify
# build + tests + release bundle smoke
```

---

## Localization

| Language | Status |
|----------|--------|
| English | ✅ Full |
| 한국어 | ✅ Full |
| 日本語 | ✅ Fallback supported |
| 简体中文 | ✅ Fallback supported |

---

## Contributing

Contributions are welcome. Please see [CONTRIBUTING.md](CONTRIBUTING.md) and run:

```bash
make verify
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Acknowledgments

Built with SwiftUI, AppKit, and a lot of `@MainActor`.  
Inspired by the need to stop guessing AI quota limits.
