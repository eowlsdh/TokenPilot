# TokenPilot — macOS 菜单栏 AI 额度 / 用量监控

**TokenPilot** 以 local-first 方式汇总 Claude Code、Codex、Antigravity CLI（旧版 Gemini telemetry）、DeepSeek balance 信号和 Grok 的本地 context 信号，让你在 macOS 菜单栏中查看剩余额度和使用历史。Grok/xAI 只读取数值本地 context 元数据。

> TokenPilot 只围绕用量元数据工作。它不会读取 prompt/response 正文、浏览器 Cookie、provider auth 文件或任意 Keychain 项。
>
> TokenPilot 不隶属于 OpenAI、Anthropic、Google、DeepSeek 或 xAI，也不是官方认证产品。

![将 Codex 和 Grok 菜单栏指标设为独立项目的 TokenPilot 设置界面](docs/assets/readme-screenshot.png)

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md)

---

## 显示内容

| 界面 | 作用 |
|---|---|
| **Menu bar** | 以 `5h 18% · W 53% · DS $12.34` 这样的单行形式显示剩余额度和选中的 DeepSeek 余额。 |
| **Overview** | 显示当前剩余额度、provider rows、DeepSeek topped-up balance、今日 token 和提醒状态。 |
| **History** | 提供已保存的使用事件、最新 limit signals、默认折叠的最近额度信号和 JSON/CSV export。 |
| **Settings** | 配置 Provider Diagnostics、Codex Limit Hints Connector、DeepSeek balance/API key setup、Grok 本地 context diagnostics、manual fallback、通知、Telegram/Discord、语言和 privacy 边界。 |

---

## 主要功能

- **macOS 菜单栏应用**：使用 AppKit `NSStatusItem` 和 `NSPopover`、无 Dock 图标的工具。
- **剩余额度优先 UI**：优先显示“还剩多少”，而不是“已经用了多少”。
- **Claude / Codex / Antigravity（旧版 Gemini telemetry）/ DeepSeek / Grok/xAI 集成**：把各 provider 的本地元数据、可选 balance 信号和 Grok 本地 context 元数据汇总到一个界面。
- **DeepSeek balance**：保存 API key 后，使用官方 `/user/balance` 的 `topped_up_balance`，并按 native currency 显示。
- **Grok/xAI source**：只读取 `~/.grok/sessions/**/signals.json` 中的数值本地 context 元数据；不会读取 `auth.json`、OAuth token、prompt 或 response。菜单栏显示剩余本地 context（`100 - contextWindowUsage`），不是 subscription quota 或 API billing。
- **Manual fallback 与 stale 标记**：没有 API key 或请求失败时，也会清楚标出数据可信度。
- **低余额提醒**：当 topped-up balance 不高于 $5 时可以触发提醒。
- **Privacy-first export**：JSON/CSV export 不包含 secret、API key、webhook、chat ID、raw prompt/response 或 local file path。

---

## Provider 支持

### Claude Code

- Statusline JSON 与 local project JSONL fallback。
- 解析 5 小时 / 每周 rate limit、context window、token、model 和 cost metadata。

### Codex

1. **Codex Limit Hints Connector**：只有用户明确开启时，才按顺序向本地 `codex app-server` 发送不含 `jsonrpc` 字段的 JSONL `initialize`、`initialized`、`account/rateLimits/read`。TokenPilot 不直接读取 Codex access token。
2. **Manual Limit Snapshot / `/status` parse**：根据用户输入推算 5h / weekly 值。
3. **Local Activity Beta**：实验性读取 local session JSONL 中的 token_count 类 row。

### Antigravity CLI / 旧版 Gemini telemetry

- 默认读取 `~/Library/Application Support/TokenPilot/antigravity-statusline.json` 中的 Antigravity `statusLine` bridge output。
- 在 Settings → Setup Guide → **Connect Antigravity CLI** 安装 bridge，重启或重新打开 Antigravity CLI 后运行任意 prompt，JSON 就会更新。
- 保存的只有 model、context-window input/output total、current usage token count、percentage 等 allowlist metadata。不会保存 prompt/response、email、cwd/workspace 或 provider auth material。
- 旧版 Gemini source 只继续支持 `~/.gemini/telemetry.log`。

### DeepSeek

- 只有在 Settings 中明确保存 API key 后，才请求 `https://api.deepseek.com/user/balance`。
- 显示值为 `balance_infos[].topped_up_balance`。非 USD currency 会按原 currency 显示。
- API key 保存在 TokenPilot-owned Keychain item 中，不会被 export。
- 请求失败时显示最后一次成功值的 stale 状态，或显示用户启用的 manual fallback。

### Grok / xAI source

TokenPilot 只从以下文件读取数值本地 context 元数据：

```text
~/.grok/sessions/**/signals.json
```

不会读取 `auth.json`、OAuth token、prompt、response 或 provider billing/subscription 数据。Grok 菜单栏值为剩余本地 context（`100 - contextWindowUsage`），不是 provider quota，因此不可与 provider quota 或 API billing 比较。

---

## Build / Test

```bash
swift test

make bundle
open build/TokenPilot.app
```

产物：

```text
build/TokenPilot.app
build/TokenPilot.zip
```
