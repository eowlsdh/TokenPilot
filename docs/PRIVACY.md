# TokenPilot Privacy

TokenPilot is designed as a local-first macOS utility. It reads supported usage metadata from local files or values you enter manually. It does not read browser cookies, provider authentication files, raw prompts, raw responses, or arbitrary Keychain items.

External notifications are optional and off by default.

## Data TokenPilot May Process Locally

- AI tool usage metadata such as token counts, request counts, limit window percentages, reset hints, timestamps, and model labels.
- User-selected local file or folder paths for supported metadata sources.
- Security-scoped bookmark data for user-selected Claude, Antigravity, or exact Gemini metadata files, so the app can attempt to read those sources again after relaunch.
- App preferences such as enabled providers, language, alert thresholds, and display settings.
- Optional manually entered Codex limit hints.
- Grok Build local context metadata from files named `signals.json` below `~/.grok/sessions/`. Only numeric context fields are parsed.

## Data TokenPilot Should Not Collect

- Provider account passwords.
- OAuth tokens or provider access tokens.
- Browser cookies or browser sessions.
- Raw prompts or raw model responses.
- Arbitrary Keychain items.
- Telegram bot tokens or Discord webhook URLs in exported usage files.
- Chat IDs, webhook URLs, or local file paths in exported usage files.
- Provider credentials, browser cookies, authentication databases, prompts, responses, or other session content in exported usage files, logs, or user-facing errors.

## External Notifications

TokenPilot can optionally send alert messages to Telegram or Discord only after you configure and enable them.

External alert messages should contain usage-alert context only. They should not include credentials, provider auth material, prompts, responses, local file paths, or webhook URLs.

Telegram's Bot API places the bot token in the request URL path. TokenPilot treats those URLs as secret-bearing data: they should never be logged, exported, proxied for debugging, or shown in user-facing errors.

## Storage

TokenPilot stores app preferences locally on the Mac. TokenPilot-owned notification secrets, if configured, are stored in TokenPilot's own Keychain items and hidden after saving. Provider credentials are not read from local provider files or stored by TokenPilot.

## Network Use

The default product promise is local-first. Network use is limited to features that the user explicitly enables, such as optional external notifications or an opt-in local connector. Any external submission, account login, or credential-based provider access must be clearly labeled.

Grok Build ingestion is local-only: TokenPilot considers only files named `signals.json` beneath `~/.grok/sessions/`, rejects symlinks, reads at most 120 files per scan, and rejects files larger than 256 KiB. It parses only numeric context fields. These values describe local context remaining and are not subscription quota, provider quota, or API billing; they must not be compared with or represented as any of those measures.
TokenPilot never reads `~/.grok/auth.json`, OAuth tokens, prompts, responses, or other Grok credential/session content.

Gemini ingestion accepts only the exact `antigravity-statusline.json` and `telemetry.log` filenames. Chat/session JSON is rejected before it is read.

## macOS Sandbox

TokenPilot supports security-scoped bookmarks for user-selected Claude, Antigravity, and legacy Gemini sources. A stricter App Store distribution should use the sandbox-ready entitlement profile in `Resources/TokenPilot-AppStore.entitlements` and re-verify local source access before release. The default local entitlement file remains unsandboxed until that migration is validated, so existing automatic local metadata discovery keeps working.
