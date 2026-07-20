# TokenPilot — macOS 菜单栏 AI 额度 / 用量监控

**TokenPilot** 是一款 local-first macOS 工具，用最简洁的方式在菜单栏查看 AI coding provider 的剩余百分比：上方显示 provider 名称，下方显示剩余百分比。选中的 provider 可以注册为独立菜单栏项目，也可以合并为一个项目。

> TokenPilot 只围绕用量元数据工作。它不会读取 prompt/response 正文、浏览器 Cookie 或任意 Keychain 项。Provider 认证材料默认不会被收集；唯一例外是下文所述、默认关闭的 EXPERIMENTAL/UNOFFICIAL Grok OAuth 周用量功能。
>
> TokenPilot 不隶属于 OpenAI、Anthropic、Google、DeepSeek 或 xAI，也不是官方认证产品。

![将 Codex 和 Grok 菜单栏指标设为独立项目的 TokenPilot 设置界面](docs/assets/readme-screenshot.png)

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md)

---

## 显示内容

| 界面 | 作用 |
|---|---|
| **Menu bar** | 上方显示 provider 名称，下方显示剩余百分比；可按 provider 选择显示，并使用**独立项目**或**合并项目**布局。 |
| **Overview** | 显示当前剩余额度、provider rows、DeepSeek topped-up balance、今日 token 和提醒状态。 |
| **History** | 提供已保存的使用事件、最新 limit signals、默认折叠的最近额度信号和 JSON/CSV export。 |
| **Settings** | 配置 Provider Diagnostics、Codex Limit Hints Connector、DeepSeek balance/API key setup、Grok 本地 context diagnostics、manual fallback、通知、Telegram/Discord、语言和 privacy 边界。 |

---

## 主要功能

- **简洁的 provider 百分比**：通过双行 `NSStatusItem` 随时查看所选 AI 的剩余比例，并可独立排列或合并显示。
- **剩余额度优先 UI**：优先显示“还剩多少”，而不是“已经用了多少”。
- **Claude / Codex / Antigravity（旧版 Gemini telemetry）/ DeepSeek / Grok/xAI 集成**：把各 provider 的本地元数据、可选 balance 信号和 Grok 本地 context 元数据汇总到一个界面。
- **DeepSeek balance**：保存 API key 后，使用官方 `/user/balance` 的 `topped_up_balance`，并按 native currency 显示。
- **Grok/xAI source**：本地 context 仅读取 `~/.grok/sessions/**/signals.json` 中的数值元数据，不读取 `auth.json`/token/prompt/response。另有一项默认关闭的 EXPERIMENTAL/UNOFFICIAL OAuth 周用量功能，仅在明确同意后，才从固定路径 `~/.grok/auth.json` 读取所选 access token 与过期时间，用于一次固定 billing 请求；token 仅保留在内存中，从不显示、记录、存储、诊断或 export。手动周用量优先。
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

TokenPilot 的 **本地 context** 路径只从以下文件读取数值本地 context 元数据：

```text
~/.grok/sessions/**/signals.json
```

该本地 context 功能不会读取 `auth.json`、OAuth token、prompt、response 或 provider billing/subscription 数据。Grok 菜单栏本地值为剩余 context（`100 - contextWindowUsage`），不是 provider quota，因此不可与 provider quota 或 API billing 比较。

**另有**一项默认关闭的 **EXPERIMENTAL / UNOFFICIAL** OAuth 周用量功能，仅在明确同意后，才从固定路径 `~/.grok/auth.json` 读取所选 access token 与过期时间，发起一次固定的周 billing 请求，token 仅保留在内存中，从不显示、记录、存储、诊断或 export。手动周用量优先于 experimental OAuth 展示。

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
