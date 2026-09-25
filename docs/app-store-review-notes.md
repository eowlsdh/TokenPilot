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

Verified 2026-08-21 against the current build. Split by what a machine can settle and what
needs a person in front of the screen.

**Settled and re-checkable by running the commands:**

- [x] Sandbox configuration builds at the current floor:
      `TOKENPILOT_ENTITLEMENTS="$PWD/Resources/TokenPilot-AppStore.entitlements" ./build.sh`
      — app-sandbox, user-selected read-only, and network client all present in the signed bundle.
- [x] `swift build -Xswiftc -warnings-as-errors` clean; `swift test` 768 passing; `gitleaks` clean
      on history, worktree, and staged diff.
- [x] Bundle metadata: version 1.0.0 (1), `LSMinimumSystemVersion` 26.0, `LSUIElement`,
      `com.tokenpilot.macos`, privacy manifest, icon, and string catalog all present, signed with a
      real Team ID.
- [x] Version and OS floor each have exactly one source (`project.yml`); tests pin that `build.sh`
      reads rather than restates them, and that SwiftPM and Xcode agree.
- [x] Listing copy drafted and length-checked in `docs/app-store-listing.md`; every claim checked
      against the code (twelve providers, five languages).
- [x] All four READMEs state the macOS 26 requirement.

**Needs a person — cannot be done headlessly:**

- [ ] **Screenshots.** Five shots specified in `docs/app-store-listing.md`. The popover has to be
      opened by hand and screen capture needs permission this environment does not have.
- [ ] **Grant one folder in the sandboxed build** and confirm the provider leaves the
      "Choose the … folder to grant access" state. Needs the open panel.
- [ ] **Icon Composer.** The icon is still a legacy `.appiconset` / `.icns`. It renders correctly on
      macOS 26 but does not get the layered treatment, and producing a `.icon` needs the GUI tool.
      Cosmetic, not blocking.
- [ ] App Store Connect: create the record, upload the build, answer App Privacy from the section
      above.
