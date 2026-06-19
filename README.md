# TokenPilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014+-lightgrey.svg)](https://github.com)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Tests](https://img.shields.io/badge/Tests-184%20passing-brightgreen.svg)](#testing)
[![Localization](https://img.shields.io/badge/Locales-EN%2FKO%2FJA%2FZH-blueviolet.svg)](#localization)

> **A local-first macOS menu bar monitor for AI coding quota and usage.**
> TokenPilot keeps Claude Code, Codex, Antigravity CLI (legacy Gemini CLI), and DeepSeek balance signals visible without a cloud dashboard, browser tab, or provider-token collector.
>
> TokenPilot is not affiliated with OpenAI, Anthropic, Google, or DeepSeek.

[한국어 README](README.ko.md) · [日本語 README](README.ja.md) · [简体中文 README](README.zh-CN.md)

![TokenPilot screenshot showing remaining quota overview, DeepSeek balance, and privacy-first settings](docs/assets/readme-screenshot.png)

---

## Why TokenPilot?

AI coding tools expose usage signals in different places: statusline JSON, local session logs, telemetry logs, manual `/status` output, or unofficial limit-hint APIs. TokenPilot turns those scattered local signals into one compact macOS menu bar readout:

```text
5h 18% · W 53%
```

The numbers are **remaining quota percentages**. When confidence is estimated or unofficial, TokenPilot says so.

---

## Current app surfaces

| Surface | What changed / what it shows |
|---|---|
| **Menu bar** | Single-line remaining quota label: `5h`, weekly, and estimated/manual suffixes when needed. |
| **Overview** | Current remaining quota, provider rows, daily challenge, and alert status. The duplicate 7-day usage chart and provider-share blocks are intentionally removed from Overview. |
| **History** | Today / Last 7 days / This month token history, latest limit signals, 7-day chart, provider share, and JSON/CSV export. |
| **Settings** | Provider Diagnostics, Codex limit hints connector, DeepSeek balance/API key setup, manual fallback, notifications, Telegram/Discord, language, setup, and privacy boundaries. |

---

## Features

| Feature | Description |
|---------|-------------|
| 🍎 **Native menu bar utility** | `MenuBarExtra` app with compact quota display and no Dock icon. |
| 📊 **Multi-provider monitoring** | Claude Code, Codex, Antigravity CLI (legacy Gemini CLI), and DeepSeek balance in one place. |
| 🧭 **Remaining-first quota UI** | Limit cards prioritize what is left, not what was consumed. |
| 🔒 **Local-first by default** | Reads local usage metadata; optional connectors and notifications are user-enabled. |
| 🏷️ **Honest confidence labels** | Official, local, manual, estimated, experimental, and limit-hint data are visibly distinct. |
| 🔔 **Alerts** | macOS notifications plus optional Telegram/Discord threshold and reset alerts. |
| 💵 **DeepSeek balance** | Optional `/user/balance` integration shows topped-up balance, native currency, manual fallback, and low-balance alerts. |
| 📈 **History + export** | Period-based token history, 7-day chart in History only, provider share, JSON/CSV export. |
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
| **Antigravity CLI / legacy Gemini CLI** | TokenPilot Antigravity statusLine JSON bridge, plus legacy Gemini telemetry log + session JSON fallback | High for statusLine/telemetry metadata; local session JSON remains local/metadata-only. |
| **DeepSeek** | Optional API-key request to official `/user/balance`, plus manual fallback | High for official balance responses; manual values are clearly labeled. |

### Provider diagnostics

First-run setup is centered in **Settings → Provider Diagnostics**:

- Each provider shows status, confidence, last checked time, and next action.
- Diagnostics summarize local metadata availability without showing raw paths, prompts, responses, cookies, tokens, or raw events.
- Codex connector state is explicit: off, manual, local activity, or unofficial limit hints.
- DeepSeek balance setup is explicit: no API key, official balance connected, stale balance, or manual fallback.

### Menu bar display

```text
5h 18% · W 53%          # remaining 5-hour and weekly quota
5h 8% · W 31% ⚠️        # low remaining quota / warning state
5h 74% · W 80% est.     # estimated/manual Codex values
Co 12.3Ktok             # fallback when only local activity exists
DS $12.34                # selected DeepSeek topped-up balance
```

---

## Screenshots

The README screenshot is a release-facing composite of the current app surfaces:

- Menu bar: compact remaining quota plus selected DeepSeek balance (`DS $12.34`).
- Overview: remaining-first quota and provider rows including DeepSeek topped-up balance; no duplicate 7-day chart/provider-share block.
- Settings: provider diagnostics, DeepSeek Keychain setup, topped-up balance, low-balance alert, and privacy boundaries.

The 7-day chart and provider share are intentionally kept in **History**, not Overview.

---

## GitHub Release positioning

TokenPilot is positioned as a **local-first AI coding usage meter for the macOS menu bar**:

- **No cloud dashboard**: usage stays on-device.
- **No account required**: no TokenPilot account or provider login flow.
- **No provider token collection**: Codex/Telegram/Discord/DeepSeek secrets are stored only when explicitly configured, never shown or exported.
- **Honest confidence labels**: official, local, manual, estimated, experimental, and limit-hint sources are visibly distinct.
- **Release artifacts**: `make bundle` produces `build/TokenPilot.app` and `build/TokenPilot.zip`.

Release copy must stay evidence-bound: do not claim notarization, App Store availability, provider account validation, or exact provider billing/quota authority unless those checks were actually performed.

---

## Privacy

TokenPilot is designed as a **local-first** utility:

| ✅ Reads | ❌ Never reads |
|----------|---------------|
| Claude statusline JSON | Browser cookies |
| Antigravity statusLine JSON / legacy Gemini telemetry log | Provider auth files |
| User-entered Codex values | Raw prompts/responses |
| User-saved DeepSeek API key in TokenPilot Keychain item | Exported secrets |
| Local session JSONL metadata | Arbitrary Keychain items |
| TokenPilot-owned notification credentials | Other apps' Keychain items |

External notifications (Telegram/Discord) are **off by default** and require explicit user configuration. Codex Limit Hints Connector is also off by default and talks to the local Codex CLI app-server rather than reading Codex auth files directly. DeepSeek balance is opt-in and uses a TokenPilot-owned Keychain item for the API key; exports omit secrets.

See [Privacy](docs/PRIVACY.md) and [Security](SECURITY.md) for details.

---

## Architecture

```text
Sources/
├── TokenApp/                         # SwiftUI app shell, views, ViewModel
│   ├── TokenMonitorApp.swift          # App entry and MenuBarExtra
│   ├── Views/                         # Overview, History, Settings, components
│   └── Resources/Localizable.xcstrings
└── TokenCore/                         # Business logic, adapters, models
    ├── Models/                        # Provider snapshots, settings, usage models
    ├── Services/
    │   ├── DataSourceAdapters.swift    # Claude/Codex/Antigravity-Gemini/DeepSeek adapters
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
# Executed 171 tests, with 0 failures

swift build -Xswiftc -warnings-as-errors
# Build complete — zero warnings

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
