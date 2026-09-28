# Provider marks

Each provider's own mark identifies it in the popover and in Settings. The files live in
`Sources/TokenApp/Resources/ProviderMark-<provider>.{svg,png}`, and `ProviderMarkAsset` in
`Sources/TokenApp/Views/Components.swift` decides how each one is drawn:

- a white glyph on the brand-colour tile;
- the provider's own tile, used as published;
- a full-colour mark on a plain tile.

These replaced SF Symbols that only suggested each provider (a brain for Claude, a dollar sign for
DeepSeek).

| Provider | File | Source | Drawn as |
|---|---|---|---|
| Claude Code | `ProviderMark-claude.svg` | Simple Icons `claude` | white on `#D97757` |
| Codex | `ProviderMark-codex.svg` | Simple Icons `openai` | white on black |
| DeepSeek | `ProviderMark-deepseek.svg` | Simple Icons `deepseek` | white on `#5786FE` |
| JetBrains AI Assistant | `ProviderMark-jetbrains.svg` | Simple Icons `jetbrains` | white on black |
| MiniMax | `ProviderMark-minimax.svg` | Simple Icons `minimax` | white on `#E73562` |
| opencode | `ProviderMark-opencode.svg` | Simple Icons `opencode` | white on black |
| OpenRouter | `ProviderMark-openrouter.svg` | Simple Icons `openrouter` | white on `#94A3B8` |
| Kiro | `ProviderMark-kiro.svg` | kiro.dev site icon | own tile |
| Grok / xAI | `ProviderMark-xai.svg` | grok.com favicon | own tile |
| Command Code | `ProviderMark-commandcode.png` | commandcode.ai apple-touch-icon | own tile |
| Z.ai | `ProviderMark-zai.svg` | z.ai site logo | on black |
| Antigravity CLI | `ProviderMark-gemini.png` | antigravity.google logo | on white |

Brand colours are the ones Simple Icons records for each brand. `TokenPilotMark.png` is the app
icon (`Resources/TokenPilot.icns`) at 128 px, for the popover header.

## Licence and trademarks

Simple Icons publishes its SVG files under CC0. The marks themselves remain the trademarks of their
owners, whatever file they came from. They are used here only to identify the service whose usage is
shown, and nothing in TokenPilot implies endorsement.

Some providers publish brand guidelines, which can restrict how a logo is placed, coloured or
altered — JetBrains and X/xAI list theirs. Check them before a public release.

App Store Review Guideline 5.2.1 treats third-party marks as protected intellectual property, and
review can ask for proof of permission. If App Store review objects, the fallback is already in
the code: removing a provider's file brings back the SF Symbol mark. No other change is needed.

## Updating a mark

Replace the file under the same name. It must be a plain SVG with no scripts and no external
references, or a PNG of 128 px or more. Then run `xcodegen generate`, so the Xcode project picks it
up, and `make bundle`.
