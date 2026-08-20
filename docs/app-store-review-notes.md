# App Store review notes

Draft text for App Store Connect. Update the version line before each submission.

## Review notes (paste into "Notes" for the reviewer)

TokenPilot is a menu bar utility that shows how much of your AI coding assistant quota is left. It
reads usage metadata that those tools already write on this Mac.

**Why the app asks you to choose folders.** The app is sandboxed, so it can only read folders you
select. On first run, Settings → Source Health lists each assistant with a "Choose Folder" button.
Selecting a folder grants read-only access to it, and nothing outside those folders is ever read. The
app works with zero, one, or several folders granted — each assistant is optional.

**Typical folders a tester would grant** (all created by the assistants themselves, not by us):

| Assistant | Folder |
|---|---|
| Claude Code | `~/.claude/projects` |
| Codex | `~/.codex` |
| opencode | `~/.local/share/opencode` |
| Kiro | `~/.kiro` |
| Command Code | `~/.commandcode/projects` |
| Grok | `~/.grok/sessions` |
| JetBrains AI Assistant | `~/Library/Application Support/JetBrains` |

**To see the app do something without installing an assistant:** Settings → Privacy → "Preview
sample data when no source is connected" fills the UI with clearly labeled MOCK values.

**What is read:** token counts, request counts, timestamps, model names, and the quota percentages
the assistants publish. **What is never read:** prompts, responses, transcripts as text, API keys,
OAuth tokens, cookies, or credential files. Credential files are excluded by name before any file is
opened.

**Network use** is limited to the provider APIs the user explicitly enables with their own API key
(DeepSeek balance, MiniMax, Z.ai, OpenRouter, opencode usage), plus optional Telegram or Discord
alerts the user configures. Nothing is sent anywhere by default, and the app has no account, no
analytics, and no telemetry.

## App Privacy answers

- **Data collection:** None. `PrivacyInfo.xcprivacy` declares no collected data types and no
  tracking; the required-reason API declarations are UserDefaults (CA92.1) and file timestamp
  (C617.1).
- **Third-party analytics/SDKs:** None. The app has no third-party dependencies.

## Description points worth keeping accurate

- Say "usage and limit hints," not "official quota," for providers where TokenPilot infers from local
  activity — the app itself labels those as local activity, and the store text should match.
- The Grok local reading is remaining **context window**, not subscription quota.
- Do not imply affiliation with Anthropic, OpenAI, Google, xAI, DeepSeek, AWS, or JetBrains; the
  README's non-affiliation line should also appear in the store description.

## Pre-submission checklist

- [ ] Build with the sandbox entitlements:
      `TOKENPILOT_ENTITLEMENTS="$PWD/Resources/TokenPilot-AppStore.entitlements" ./build.sh`
- [ ] Grant one folder in the sandboxed build and confirm the provider leaves the
      "Choose the … folder to grant access" state.
- [ ] `make verify` clean; `gitleaks` clean.
- [ ] Screenshots taken from the sandboxed build (menu bar block, Overview, History, Settings).
- [ ] Version and build number bumped in **project.yml** (`MARKETING_VERSION`,
      `CURRENT_PROJECT_VERSION`). `build.sh` reads both from there, so there is one place to
      change and no way for the two bundles to disagree.
- [ ] Listing copy reviewed against `docs/app-store-listing.md`.
