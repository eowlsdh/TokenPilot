# TokenPilot Store Metadata Draft

**Status:** local draft, not submitted  
**Last updated:** 2026-05-24 23:02 KST  
**Safety boundary:** Do not paste credentials, personal usage logs, support account secrets, or unreleased user data into this document. App Store Connect upload/TestFlight/paid listing requires explicit approval.

---

## 1. Positioning lock

TokenPilot should be listed as a small privacy-first macOS menu bar utility, not as an official billing or quota authority.

**One-line promise**

> Track local AI coding-tool usage metadata from Claude Code, Codex, and Gemini CLI in your macOS menu bar, with clear limit hints and opt-in alerts.

**Korean promise**

> Claude Code, Codex, Gemini CLI의 로컬 사용량 메타데이터와 한도 힌트를 macOS 메뉴바에서 빠르게 확인하는 privacy-first 유틸리티입니다.

**Do not claim**

- Exact official Codex web quota tracking
- Billing-grade cost accuracy
- Official API coverage for every provider
- Automatic credential-free access to provider accounts
- Reading prompts/responses/cookies/auth files

---

## 2. App Store fields draft

### App name

TokenPilot

### Subtitle candidates

1. AI usage in your menu bar
2. Local AI limit hints
3. Privacy-first token monitor

Recommended first subtitle: **AI usage in your menu bar**

### Promotional text draft

> See local Claude Code, Codex, and Gemini CLI usage signals at a glance. TokenPilot keeps provider data local, labels estimates clearly, and helps you avoid surprise limit pressure while you work.

### Description draft

TokenPilot is a compact macOS menu bar utility for people who use multiple AI coding tools during the day.

It reads supported local usage metadata from Claude Code, Codex, and Gemini CLI, then summarizes the current usage picture in a small native popover. Estimated or manual values are labeled clearly, so TokenPilot stays honest about what it can and cannot know.

What TokenPilot helps with:

- See 5-hour, weekly, or daily usage signals where provider data is available.
- Keep a compact menu bar glance such as `5h 64% · W 56%`.
- Review recent local usage history without opening a heavy dashboard.
- Use optional macOS, Telegram, or Discord alerts only after you enable them.
- Keep credentials, browser cookies, auth files, prompts, and responses out of TokenPilot’s normal data path.

Important limitations:

- TokenPilot is not an official provider billing app.
- Codex local/manual values are limit hints, not guaranteed official web quota.
- Provider log formats and CLI behavior may change.
- External alert channels require user configuration and are off by default.

### Keywords draft

AI, token, usage, Claude, Codex, Gemini, menu bar, developer, privacy, monitor

### Category

Developer Tools or Productivity.  
Recommended first category: **Developer Tools**.

---

## 3. Screenshot set plan

Capture these after final visual QA:

1. Menu bar glance showing compact remaining percentages.
2. Overview with provider cards and honest empty/connected labels.
3. History with 7-day chart and provider share.
4. Settings → Data Sources with file picker and source status.
5. Settings → Privacy showing local-first/no credential promise.
6. Empty or manual-estimate state showing estimates clearly labeled.

Rules:

- No real credentials, local paths, chat IDs, webhooks, or private usage logs.
- Prefer sample/preview data explicitly labeled as sample.
- Avoid claims in screenshot captions that exceed the app’s actual behavior.

---

## 4. Pricing/revenue experiment

Recommended first experiment:

- Free local trial or limited preview.
- One-time unlock or low-price utility purchase after 5-user pilot.
- Avoid a large subscription promise until daily retention and trust are proven.

Pilot success signal:

- At least 2 of 5 AI-coding-heavy macOS users keep TokenPilot running during real workdays and say the menu bar glance changes behavior.

Pilot failure signal:

- Users repeatedly say the numbers feel too unofficial or not trustworthy. In that case, narrow the promise to “local usage diary + reminders” rather than quota monitoring.

---

## 5. App Review notes draft

> TokenPilot reads user-selected local usage metadata files/folders for supported developer tools. It does not read browser cookies, provider auth files, prompts, responses, or arbitrary Keychain items. External notifications are optional and disabled by default. Where a provider does not expose official quota data, TokenPilot labels values as manual, estimated, local log, or limit hints.

---

## 6. Release notes template

### Version 1.0.0 candidate

- Initial local-first macOS menu bar monitor for Claude Code, Codex, and Gemini CLI usage metadata.
- Compact menu bar glance for current usage pressure.
- Overview, History, and Settings screens.
- Optional local/macOS and external alert configuration.
- Privacy manifest, app icon, and local bundle packaging prepared.
- User-selected Claude/Gemini source bookmarks prepared for sandbox-readiness.

---

## 7. Approval gates before using this externally

- Apple Developer account login
- App Store Connect metadata entry
- Screenshots created from reviewed app state
- Privacy Policy URL and Support URL confirmed
- Signing, notarization, TestFlight, or App Store upload
