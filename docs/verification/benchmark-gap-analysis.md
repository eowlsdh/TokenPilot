# Token Usage Tracker Benchmark and Gap Analysis Work Log

**Status:** Working-tree verification artifact (not a release evidence artifact). Documents the benchmark of popular AI token/capacity tracking tools against TokenPilot's current surfaces, with code-graph-verified gaps and candidate improvements for the sales-readiness roadmap (target: 99/100 quality, top-10 store placement).

**Commit baseline:** `272e596` "Remove duplicate assertions" (HEAD at time of writing).

## Scope

This document answers one question: *which capabilities of popular token pilots does TokenPilot already own, and which gaps are worth closing before release?* Benchmarks were performed via official documentation and public repos. Claims about current TokenPilot behavior were verified against the code graph (symbol presence), not assumed from the README.

Verdict prefix convention:

- ✅ **보유** — TokenPilot already implements an equivalent capability.
- ⚠️ **부분** — implemented but weaker than the benchmarked tool in a meaningful way.
- ❌ **갭** — not implemented; a candidate improvement.

---

## 1. Benchmarked tools

| Tool | Format | Key mechanisms |
|------|--------|----------------|
| [ccusage](https://github.com/ryoppippi/ccusage) | CLI | `blocks` = Claude Code 5-hour billing window; JSON/table report of API-token usage per session block. |
| [toktrack](https://github.com/mag123c/toktrack) | CLI | Persistent local cache with 30-day retention, JSON output, receipt sharing. |
| [tokencap](https://github.com/helsky-labs/tokencap) | CLI | 60-second polling, 5-hour rolling percentage, tier colors (green < 50%, yellow 50–80%, red > 80%). |
| [claude-status-macos-menu-bar](https://github.com/bcollard/claude-status-macos-menu-bar) | menu bar | macOS status bar display, reuses Keychain-stored OAuth for official usage. |
| **Kiro** | IDE | Non-interactive usage JSON is *not* exposed to third parties — a differentiation opportunity for TokenPilot. |
| **Claude Code official** | `/usage` | Session *blocks* priced on API tokens; plan usage bars; `/usage-credits` weekly credits. |

Cursor/Copilot trackers were intentionally out of scope (metrics tied to closed telemetry, low value for a local-first menu bar app).

## 2. Gap verification (codegraph)

| Capability | Benchmark baseline | TokenPilot status | Evidence |
|---|---|---|---|
| 5-hour `blocks` window display | ccusage / tokencap (5h rolling %) | ⚠️ **부분** — remaining-% capacity UI exists; explicit 5-hour billing-window display does not | `CapacityPresentationMapper`, `MenuBarStatusService` |
| Rolling percentage tier colors | tokencap | ✅ **보유** — risk/status colors | `TokenPilotDesign.statusColor`, `MenuBarStatusLevel` |
| Auto refresh | (implied by all trackers) | ✅ **보유** — timer-driven refresh | `UsageRefreshIntent.automaticTimer` (TokenPilotModels.swift:2649), `RefreshReason.automaticTimer` (TokenPilotViewModel.swift:23) |
| Configurable refresh/polling interval | tokencap 60s | ❌ **갭** — no `refreshInterval` setting symbol | verified absent in codegraph |
| Persisted usage history (retention) | toktrack 30-day cache | ✅ **보유** — 45-day limit-history store | `LimitHistoryStore` (LimitHistoryStore.swift:71, key `tokenPilot.limitSamples.v1`) |
| JSON/CSV export | toktrack receipts | ✅ **보유** | `UsageExportService.export` (UsageExportService.swift:36), `TokenPilotViewModel.exportHistory` (:1460) |
| Non-interactive CLI JSON output | ccusage/toktrack JSON | ❌ **갭** — no `CommandLine`/CLI entrypoint | verified absent in codegraph |
| Plan usage bars (consumed vs limit) | Claude Code plan bars | ⚠️ **부분** — capacity cards show remaining %; explicit consumed-vs-limit bar visualization is not present | `CapacityPresentationMapper` |

---

## 3. Owned-now, keep (no action)

- **Export**: `UsageExportService.export` + `exportHistory` already cover toktrack's receipt-sharing story.
- **Persistent cache**: `LimitHistoryStore` already exceeds toktrack's 30-day retention (45 days, 2,000 samples, 300-second buckets) for limit samples.
- **Status colors**: tokencap's three-tier color logic is equivalent to the existing status-level colors.
- **Trust labels**: TokenPilot's official/local/manual/est/experimental labels remain a differentiator (both tabular and menu-bar surfaces).

---

## 4. Verified gaps (candidate improvements)

Ranked by effort × user value × sales-readiness impact:

| # | Improvement | Where (expected) | Notes |
|---|---|---|---|
| 1 | **Non-interactive CLI JSON export** (`TokenPilot export --json`) | new `CommandLine`-gated entry in TokenApp | Matches ccusage/toktrack UX; low risk; local-only. |
| 2 | **5-hour billing-window display** for Claude blocks | `TokenPilotModels`/aggregation | Mirrors `/usage` + tokencap 5h rolling %; user-facing and demonstrable. |
| 3 | **Plan usage bars** (consumed vs limit on card) | Settings/Overview capacity cards | Claude Code plan bars equivalent. |
| 4 | **Configurable refresh interval** | Settings debounce UI + ViewModel timer | tokencap proves users expect this (60s↔5m). |
| 5 | **Menu-bar gauge (arc/bar) layout** | `TokenMonitorApp` status item rendering | Differentiates menu bar from CLI-only tools. |

Not selected for this pass: Cursor/Copilot trackers (closed telemetry), Kiro-native JSON export (would require Kiro cooperation — out of our control), receipt-sharing backend (violates local-first stance).

---

## 5. Security guardrails applied to any implementation

- CLI export must respect the same redaction rules as GUI export: no prompts/responses, local source paths, chat IDs, webhooks, secret values, or provider credentials (SECURITY.md).
- Refresh-interval setting is a UserDefaults-backed `Int` with clamped bounds; no new permissions.
- Any new gRPC/CLI surface must not read provider credential files; Grok local context remains numeric-metadata-only unless the default-off consent-gated OAuth path is explicitly enabled.

---

## 6. Next actionable step

Implement #1 (CLI JSON export) and #2 (5-hour billing-window display) in `TokenCore` first, wire them through the ViewModel, then run `make verify` + `make security-scan` before committing. The remaining candidates (#3–#5) are follow-up polish, not release blockers.