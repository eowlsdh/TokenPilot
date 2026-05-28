# TokenPilot Privacy Policy Draft

**Status:** local draft for review, not legal advice  
**Last updated:** 2026-05-24 23:02 KST  
**Before publication:** Review with the actual release build, privacy manifest, App Store privacy questionnaire, and official policy requirements.

---

## Short version

TokenPilot is designed as a local-first macOS utility. It reads supported usage metadata from local files or values you enter manually. It does not read browser cookies, provider authentication files, raw prompts, raw responses, or arbitrary Keychain items.

External notifications are optional and off by default.

---

## Data TokenPilot may process locally

Depending on what you enable, TokenPilot may process:

- AI tool usage metadata such as token counts, request counts, limit window percentages, reset hints, timestamps, and model labels.
- User-selected local file or folder paths for supported metadata sources.
- Security-scoped bookmark data for user-selected Claude/Gemini source files or folders, so the app can attempt to read those sources again after relaunch.
- App preferences such as enabled providers, language, alert thresholds, and display settings.
- Optional manually entered limit hints for Codex.

---

## Data TokenPilot should not collect

TokenPilot should not collect or export:

- Provider account passwords
- OAuth tokens or provider access tokens
- Browser cookies or browser sessions
- Raw prompts or raw model responses
- Arbitrary Keychain items
- Telegram bot tokens or Discord webhook URLs in exported usage files
- Chat IDs, webhook URLs, or local file paths in exported usage files

---

## External notifications

TokenPilot can optionally send alert messages to external services such as Telegram or Discord only after you configure and enable them.

External alert messages should contain usage-alert context only. They should not include credentials, provider auth material, prompts, responses, local file paths, or webhook URLs.

---

## Storage

TokenPilot stores app preferences locally on the Mac. TokenPilot-owned notification secrets, if configured, should be stored in TokenPilot’s own Keychain items and hidden after saving.

---

## Network use

The default product promise is local-first. Network use is limited to features that the user explicitly enables, such as optional external notifications or an opt-in local connector. Any external submission, account login, or credential-based provider access is outside the default local monitoring path and must be clearly labeled.

---

## App Store privacy questionnaire working notes

Initial expected answers, to verify before submission:

- Tracking: No
- Data linked to user: None expected by default
- Data used to track: No
- Collected data: None expected by default
- Required reason APIs: verify UserDefaults and file timestamp reasons against current Apple documentation before upload

---

## User support draft

For support, users should be able to ask:

- What local files does TokenPilot read?
- Why are some Codex values marked estimated or manual?
- How do I remove a selected data source?
- How do I delete external notification settings?
- How do I export usage history without secrets?

---

## Publication checklist

- [ ] Confirm final app behavior matches this policy.
- [ ] Confirm privacy manifest matches this policy.
- [ ] Confirm export files exclude credentials, tokens, chat IDs, webhooks, local file paths, and prompt/response text.
- [ ] Confirm App Store privacy answers match this policy.
- [ ] Publish only after explicit approval and final review.
