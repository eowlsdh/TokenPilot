# TokenPilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014+-lightgrey.svg)](https://github.com)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Tests](https://img.shields.io/badge/Tests-run%20locally-informational.svg)](#testing)
[![Localization](https://img.shields.io/badge/Locales-EN%2FKO%2FJA%2FZH-blueviolet.svg)](#localization)

> **Track your AI coding costs at a glance.**  
> See Claude Code, Codex, and Gemini CLI usage in your macOS menu bar — local-first, privacy-first.
>
> TokenPilot is not affiliated with OpenAI, Anthropic, or Google.

[한국어 README](README.ko.md) · [Japanese](#) · [中文](#)

![TokenPilot menu bar, Overview, and Settings privacy preview](docs/assets/readme-preview.svg)

---

## Why TokenPilot?

You use Claude Code, Codex, and Gemini CLI every day. But you never know **how much you've actually used** until you hit a rate limit.

TokenPilot sits in your menu bar and shows you:

```
5h 64% · W 56%
```

That's it. No dashboards. No browser tabs. No cloud.

---

## Features

| Feature | Description |
|---------|-------------|
| 🍎 **Menu bar native** | Compact glance without leaving your editor |
| 📊 **Multi-provider** | Claude Code + Codex + Gemini CLI in one place |
| 🔒 **Local-first by default** | Reads local metadata; optional notifications/connectors run only after explicit setup |
| 🏷️ **Honest labels** | `est.`, `manual`, `EXPERIMENTAL` — we don't pretend |
| 🔔 **Smart alerts** | macOS notifications + optional Telegram/Discord |
| 📈 **Usage history** | Today / 7 days / This month with charts |
| 🌐 **4 languages** | English, 한국어, 日本語, 简体中文 |
| 📦 **Zero dependencies** | Pure Swift, no third-party packages |

---

## Quick Start

### Option 1: Download a Release

Download the latest `.zip` or `.app` bundle from GitHub Releases, unzip it, then open `TokenPilot.app`.

If macOS Gatekeeper asks for confirmation on an unsigned or ad-hoc signed build, right-click the app and choose **Open**.

### Option 2: Build from Source

```bash
git clone https://github.com/<owner-or-org>/TokenPilot.git
cd TokenPilot
make bundle
open build/TokenPilot.app
```

### Option 3: Xcode

```bash
git clone https://github.com/<owner-or-org>/TokenPilot.git
cd TokenPilot
xcodegen generate
open TokenPilot.xcodeproj
# Press Cmd+R
```

---

## How It Works

TokenPilot reads **usage metadata** from local files — never prompts, responses, or credentials.

| Provider | Data Source | Trust Level |
|----------|------------|-------------|
| **Claude Code** | Statusline JSON + local JSONL | High (official format) |
| **Codex** | Manual input / local activity / opt-in limit hints | Medium (manual, estimated, or unofficial) |
| **Gemini CLI** | Telemetry log + session JSON | High (official format) |

### Menu Bar Display

```
5h 64% · W 56%          ← 5-hour and weekly remaining %
5h 12% · W 38% ⚠️       ← Warning state
5h 64% · W 56% est.     ← Estimated (Codex local activity)
MOCK 5h 64% · W 56%     ← First-run sample data
```

---

## Screenshots

The preview above shows the three surfaces that matter most on first run:

- Menu bar numbers: compact `5h` and weekly remaining percentages.
- Overview: provider rows with honest source labels such as `manual`, `est.`, and `limit hint`.
- Settings privacy: local-first data boundaries and opt-in notifications/connectors.

---

## Privacy

TokenPilot is designed as a **local-first** utility:

| ✅ Reads | ❌ Never reads |
|----------|---------------|
| Claude statusline JSON | Browser cookies |
| Gemini telemetry log | Provider auth files |
| User-entered Codex values | Raw prompts/responses |
| Local session JSONL | Arbitrary Keychain items |

External notifications (Telegram/Discord) are **off by default** and require explicit user configuration.

See [Privacy](docs/PRIVACY.md) and [Security](SECURITY.md) for details.

---

## Architecture

```
Sources/
├── TokenApp/           # SwiftUI app shell, views, ViewModel
│   ├── TokenMonitorApp.swift      # App entry and MenuBarExtra
│   └── Resources/Localizable.xcstrings
└── TokenCore/          # Business logic, adapters, models
    ├── Models/
    │   ├── TokenPilotModels.swift       # Data models, AppSettings
    │   └── ProviderSelectionModels.swift
    ├── Services/
    │   ├── DataSourceAdapters.swift     # Claude/Codex/Gemini adapters
    │   ├── AggregationService.swift     # Usage aggregation
    │   ├── MenuBarStatusService.swift   # Menu bar label formatting
    │   ├── TokenPilotServices.swift     # Notifications, Keychain, export
    │   └── ... (12 service files)
    └── TokenPilotLocalization.swift
Tests/
├── TokenMonitorTests.swift
└── TokenPilotServicesTests.swift
```

---

## Testing

```bash
swift test
# Executed 149 tests, with 0 failures

swift build -Xswiftc -warnings-as-errors
# Build complete — zero warnings
```

---

## Localization

TokenPilot supports 4 languages out of the box:

| Language | Status |
|----------|--------|
| English | ✅ Full |
| 한국어 | ✅ Full |
| 日本語 | ✅ Fallback supported |
| 简体中文 | ✅ Fallback supported |

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Before opening a PR, run:

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
