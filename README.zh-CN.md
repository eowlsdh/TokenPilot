# TokenPilot — macOS 菜单栏 AI 额度 / 用量监控

**TokenPilot** 以 local-first 方式汇总 Claude Code、Codex、Gemini CLI 和 DeepSeek balance 信号，让你在 macOS 菜单栏中查看剩余额度和使用历史。

> TokenPilot 只围绕用量元数据工作。它不会读取 prompt/response 正文、浏览器 Cookie、provider auth 文件或任意 Keychain 项。
>
> TokenPilot 不隶属于 OpenAI、Anthropic、Google 或 DeepSeek，也不是官方认证产品。

![TokenPilot screenshot showing remaining quota overview, DeepSeek balance, and privacy-first settings](docs/assets/readme-screenshot.png)

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md)

---

## 显示内容

| 界面 | 作用 |
|---|---|
| **Menu bar** | 以 `5h 18% · W 53% · DS $12.34` 这样的单行形式显示剩余额度和选中的 DeepSeek 余额。 |
| **Overview** | 显示当前剩余额度、provider rows、DeepSeek topped-up balance、今日 token 和提醒状态。重复的 7-day chart 与 provider share 已从 Overview 移除。 |
| **History** | 提供 Today / Last 7 days / This month、最新 limit signals、默认折叠的最近额度信号、7-day chart、provider share 和 JSON/CSV export。 |
| **Settings** | 配置 Provider Diagnostics、Codex Limit Hints Connector、DeepSeek balance/API key setup、manual fallback、通知、Telegram/Discord、语言和 privacy 边界。 |

---

## 主要功能

- **macOS 菜单栏应用**：无 Dock 图标的 `MenuBarExtra` 工具。
- **剩余额度优先 UI**：优先显示“还剩多少”，而不是“已经用了多少”。
- **Claude / Codex / Gemini / DeepSeek 集成**：把各 provider 的本地元数据和可选 balance 信号汇总到一个界面。
- **DeepSeek balance**：保存 API key 后，使用官方 `/user/balance` 的 `topped_up_balance`，并按 native currency 显示。
- **Manual fallback 与 stale 标记**：没有 API key 或请求失败时，也会清楚标出数据可信度。
- **低余额提醒**：当 topped-up balance 不高于 $5 时可以触发提醒。
- **Privacy-first export**：JSON/CSV export 不包含 secret、API key、webhook、chat ID、raw prompt/response 或 local file path。

---

## Provider 支持

### Claude Code

- Statusline JSON 与 local project JSONL fallback。
- 解析 5 小时 / 每周 rate limit、context window、token、model 和 cost metadata。

### Codex

1. **Codex Limit Hints Connector**：只有用户明确开启时，才向本地 `codex app-server` 发送 JSON-RPC `initialize` + `account/rateLimits/read`。TokenPilot 不直接读取 Codex access token。
2. **Manual Limit Snapshot / `/status` parse**：根据用户输入推算 5h / weekly 值。
3. **Local Activity Beta**：实验性读取 local session JSONL 中的 token_count 类 row。

### Gemini CLI

- 读取 `~/.gemini` telemetry log 与 session JSON/JSONL token object。
- 支持 input/output/cache/reasoning/tool token、model、auth type、duration 和 daily request cap。

### DeepSeek

- 只有在 Settings 中明确保存 API key 后，才请求 `https://api.deepseek.com/user/balance`。
- 显示值为 `balance_infos[].topped_up_balance`。非 USD currency 会按原 currency 显示。
- API key 保存在 TokenPilot-owned Keychain item 中，不会被 export。
- 请求失败时显示最后一次成功值的 stale 状态，或显示用户启用的 manual fallback。

---

## Build / Test

```bash
swift test
# Executed 171 tests, with 0 failures

make bundle
open build/TokenPilot.app
```

产物：

```text
build/TokenPilot.app
build/TokenPilot.zip
```
