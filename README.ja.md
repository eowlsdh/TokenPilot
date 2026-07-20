# TokenPilot — macOS メニューバー AI クォータ / 使用量モニター

**TokenPilot** は AI coding provider の残り割合を macOS メニューバーで最もシンプルに確認する local-first ユーティリティです。上段に provider 名、下段に残りパーセントを表示し、選択した provider を独立したメニューバー項目として並べることも、1つにまとめることもできます。

> TokenPilot は使用量メタデータ中心で動作します。プロンプト / レスポンス本文、ブラウザ Cookie、任意の Keychain 項目は読みません。Provider auth 素材は既定では収集せず、唯一の例外は後述の既定 OFF の EXPERIMENTAL/UNOFFICIAL Grok OAuth 週間機能です。
>
> TokenPilot は OpenAI、Anthropic、Google、DeepSeek、xAI と提携しておらず、公式認証製品でもありません。

![Codex と Grok のメニューバー指標を個別項目として選択する TokenPilot 設定画面](docs/assets/readme-screenshot.png)

[English](README.md) · [한국어](README.ko.md) · [简体中文](README.zh-CN.md)

---

## 表示するもの

| 画面 | 役割 |
|---|---|
| **Menu bar** | 上段に provider 名、下段に残りパーセントを表示します。provider ごとに表示を選択し、**個別項目**または**統合項目**として配置できます。 |
| **Overview** | 現在の残りクォータ、provider rows、DeepSeek topped-up balance、今日のトークン、アラート状態を表示します。 |
| **History** | 保存済みの使用イベント、最新 limit signals、折りたたみ式の最近の制限、JSON/CSV export を提供します。 |
| **Settings** | Provider Diagnostics、Codex Limit Hints Connector、DeepSeek balance/API key setup、Grok ローカル context diagnostics、manual fallback、通知、Telegram/Discord、言語、privacy 境界を設定します。 |

---

## 主な機能

- **シンプルな provider パーセント**: 選択した AI の残り割合を2段の `NSStatusItem` で常時確認し、各項目を個別配置または統合できます。
- **残りクォータ優先 UI**: 使用済みではなく「どれだけ残っているか」を優先表示します。
- **Claude / Codex / Antigravity（従来の Gemini telemetry）/ DeepSeek / Grok/xAI 統合**: 各 provider のローカルメタデータ、任意の balance シグナル、Grok ローカル context メタデータを1つの画面に集約します。
- **DeepSeek balance**: API key を Keychain に保存した場合、公式 `/user/balance` の `topped_up_balance` を native currency で表示します。
- **Grok/xAI source**: ローカル context は `~/.grok/sessions/**/signals.json` の数値メタデータだけを読み、`auth.json` / token / prompt / response は読みません。別途、既定 OFF の EXPERIMENTAL/UNOFFICIAL OAuth 週間機能は、明示的な同意後に限り固定パス `~/.grok/auth.json` から選択した access token と有効期限だけを読み、1 回の billing リクエストに使い、token はメモリのみに保持し、表示・ログ・保存・診断・export しません。手動の週間値が優先されます。
- **手動 fallback と stale 表示**: API key がない、または取得に失敗した場合でも値の信頼度を明示します。
- **低残高アラート**: topped-up balance が $5 以下になった場合に通知できます。
- **Privacy-first export**: JSON/CSV export には secret、API key、webhook、chat ID、raw prompt/response、local file path を含めません。

---

## Provider 対応

### Claude Code

- Statusline JSON と local project JSONL fallback。
- 5時間 / 週間 rate limit、context window、token、model、cost metadata を読みます。

### Codex

1. **Codex Limit Hints Connector**: ユーザーが明示的に ON にした場合のみ、local `codex app-server` へ `jsonrpc` フィールドなしの JSONL `initialize`、`initialized`、`account/rateLimits/read` の順で送信します。Codex access token は直接読みません。
2. **Manual Limit Snapshot / `/status` parse**: ユーザー入力値から 5h / weekly を推定します。
3. **Local Activity Beta**: local session JSONL の token_count 系 row を実験的に読みます。

### Antigravity CLI / 従来の Gemini telemetry

- 既定では `~/Library/Application Support/TokenPilot/antigravity-statusline.json` の Antigravity `statusLine` bridge output を読みます。
- Settings → Setup Guide → **Connect Antigravity CLI** で bridge をインストールし、Antigravity CLI を再起動して任意の prompt を実行すると JSON が更新されます。
- 保存されるのは model、context-window input/output total、current usage token count、percentage などの allowlist metadata だけです。prompt/response、email、cwd/workspace、provider auth material は保存しません。
- 従来の Gemini source としては `~/.gemini/telemetry.log` だけを引き続きサポートします。

### DeepSeek

- Settings で API key を明示的に保存した場合のみ `https://api.deepseek.com/user/balance` を呼びます。
- 表示値は `balance_infos[].topped_up_balance` です。USD 以外の currency も native currency のまま表示します。
- API key は TokenPilot-owned Keychain item に保存され、export されません。
- 接続失敗時は最後に成功した値を stale として表示するか、manual fallback を明示して表示します。

### Grok / xAI source

TokenPilot の **ローカル context** 経路は次のファイルから数値のローカル context メタデータだけを読みます。

```text
~/.grok/sessions/**/signals.json
```

このローカル context 機能は `auth.json`、OAuth token、prompt、response、provider billing/subscription データを読みません。Grok のメニューバーのローカル値は残り context（`100 - contextWindowUsage`）であり、provider quota ではないため、provider quota や API billing と比較できません。

**別途**、既定 OFF の **EXPERIMENTAL / UNOFFICIAL** OAuth 週間機能は、明示的な同意後に限り固定パス `~/.grok/auth.json` から選択した access token と有効期限を読み、固定の週間 billing リクエストを 1 回行い、token はメモリのみに保持し、表示・ログ・保存・診断・export しません。手動の週間値は experimental OAuth 表示より優先されます。

---

## Build / Test

```bash
swift test

make bundle
open build/TokenPilot.app
```

成果物:

```text
build/TokenPilot.app
build/TokenPilot.zip
```
