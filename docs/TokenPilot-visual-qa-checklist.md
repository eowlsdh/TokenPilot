# TokenPilot Visual QA Checklist

Purpose: verify TokenPilot feels like a polished native macOS menu bar utility after the acceptance hardening pass.

Scope:
- Manual visual QA only.
- No new features.
- No private APIs.
- No browser cookies, hidden credentials, or unrelated Keychain items.
- Use mock/local/user-entered data only.

Last verified by build smoke on 2026-05-21 KST:
swift test: 124 tests / 0 failures
- `swift build -Xswiftc -warnings-as-errors`: passed
- `./build.sh`: passed
- `xcodebuild`: passed
- `LSUIElement`: true
- Launch smoke: passed

## 0. Test setup

- [ ] Open the project in Xcode: `open TokenPilot.xcodeproj`
- [ ] Select scheme: `TokenPilot`
- [ ] Run with `Cmd+R`
- [ ] Confirm no Dock icon appears
- [ ] Confirm one menu bar item appears
- [ ] Click the menu bar item and confirm the popover opens
- [ ] Resize is not required; target feel is about `420 x 620`

## 1. Menu bar item

Expected: compact, calm, readable at a glance.

- [ ] Shows one compact status only
- [ ] Does not show long provider names unless selected provider mode requires it
- [ ] Highest risk percentage is clear
- [ ] Token count is compact, not verbose
- [ ] `MOCK` / `STALE` state is visible when relevant
- [ ] Reset countdown appears only when useful/high-risk
- [ ] Reset countdown format is short, e.g. `R 1h 20m`
- [ ] No jittery text length changes during normal refresh

Pass criteria:
- Looks like a menu bar utility, not a dashboard title squeezed into the menu bar.

## 2. Popover shell

Expected: premium dark utility, no broken layout.

- [ ] Popover opens reliably on click
- [ ] Overall width feels near 420 px
- [ ] Overall height feels near 620 px
- [ ] Dark navy / near-black background is consistent
- [ ] Cards have rounded corners and subtle borders
- [ ] Text contrast is high enough
- [ ] Spacing is compact but not cramped
- [ ] No giant shadow/gradient clutter
- [ ] No clipped text in Korean, English, Chinese, or Japanese
- [ ] No accidental horizontal scrolling

Pass criteria:
- The first impression should be calm, compact, and native macOS-like.

## 3. Overview tab

Expected: simple at-a-glance summary.

Overview should contain only:
- Header: TokenPilot, LIVE/STALE/MOCK, Today tokens, Highest risk, nearest reset
- Best tool now card
- Claude Code card
- Codex card
- Gemini CLI card
- Daily Challenge card
- Tiny alerts status row

Checklist:
- [ ] No giant charts on Overview
- [ ] No long tables on Overview
- [ ] No settings controls on Overview except tiny alerts summary
- [ ] Header state label is visible: `LIVE`, `STALE`, or `MOCK`
- [ ] Today tokens are easy to read
- [ ] Highest risk is easy to read
- [ ] Nearest reset is visible only when helpful
- [ ] Best tool card does not overclaim precision
- [ ] Daily Challenge card is compact
- [ ] Tiny alerts row is short and not interactive-heavy

Pass criteria:
- A user should understand current usage/risk within 5 seconds.

## 4. Provider cards

Expected: each card is readable in 4–5 rows max.

Common card checks:
- [ ] Provider name is clear
- [ ] Accent color is subtle, not dominant
- [ ] Progress bars are compact
- [ ] Numbers use monospaced digit styling
- [ ] Badges are subtle and readable
- [ ] Empty/missing data does not look broken
- [ ] `STALE` badge appears for stale sources
- [ ] `MOCK` badge appears for mock data
- [ ] `est.` or `manual` appears for estimated/manual values

Claude Code card:
- [ ] 5h progress is visible
- [ ] Weekly progress is visible
- [ ] Reset countdown is visible when relevant
- [ ] Today tokens are visible
- [ ] Confidence/stale badge is visible

Codex card:
- [ ] 5h value is labeled `est.` or `manual`
- [ ] Weekly value is labeled `est.` or `manual`
- [ ] Today tokens appear only if available
- [ ] Confidence badge is visible
- [ ] Estimated data never looks official

Gemini CLI card:
- [ ] Daily request progress is visible
- [ ] Today tokens are visible
- [ ] Average tokens per request is visible when available
- [ ] Daily request cap is visible

Pass criteria:
- Cards should be understandable without reading every line.

## 5. History tab

Expected: simple history, not analytics overload.

- [ ] Period selector has Today / Last 7 days / This month
- [ ] Simple 7-day chart is visible
- [ ] Provider share row is visible
- [ ] No dense long table
- [ ] Metrics are compact and aligned
- [ ] Missing history shows an intentional empty state
- [ ] Mock history is not presented as real data

Pass criteria:
- History answers “what happened recently?” without becoming an enterprise dashboard.

## 6. Settings tab

Expected: simple sections, short helper text, compact controls.

Required sections:
- [ ] Data Sources
- [ ] Notifications
- [ ] Telegram
- [ ] Discord
- [ ] Language
- [ ] Setup Guide
- [ ] Privacy

General checks:
- [ ] Each section uses a card or clear visual grouping
- [ ] No single section feels overwhelming
- [ ] Helper text is short and useful
- [ ] Destructive actions are clearly labeled
- [ ] Settings changes persist after relaunch where applicable

Pass criteria:
- A first-time user should know where to connect data, enable alerts, and check privacy.

## 7. Notifications settings

Expected defaults:
- Reset: ON
- 50%: OFF
- 80%: ON
- 100%: ON

Checklist:
- [ ] Defaults match the expected values
- [ ] Provider/window toggles are compact
- [ ] The user can understand which provider/window/threshold is enabled
- [ ] No repeated spam notification occurs at same threshold/cycle
- [ ] Reset alert only fires after real reset/recovery, not merely resetAt text changes
- [ ] Denied notification permission shows friendly guidance

Pass criteria:
- Alert controls feel safe and predictable.

## 8. Telegram settings

Expected: optional, secure, off by default.

- [ ] Telegram is OFF by default
- [ ] Bot Token input uses `SecureField`
- [ ] Saved token is not displayed in plain text
- [ ] Chat ID is not treated as a secret token, but still not overexposed
- [ ] Send Test Message button exists
- [ ] Delete Token exists
- [ ] Replace Token flow exists
- [ ] Connection status is clear
- [ ] Failed test shows a friendly error
- [ ] No other Keychain items are read

Pass criteria:
- The app only stores TokenPilot’s own user-entered Telegram token.

## 9. Privacy copy

Expected: explicit and reassuring.

- [ ] Privacy note is visible in Settings
- [ ] States local files/user-selected/user-pasted/official outputs only
- [ ] States no browser cookies
- [ ] States no unrelated Keychain items or hidden credential-store browsing
- [ ] States Codex Limit Hints Connector is opt-in, default OFF, and uses Codex auth only in memory when enabled
- [ ] States the Codex endpoint is unofficial/internal and may break
- [ ] States no unrelated Keychain access
- [ ] Telegram token storage behavior is clear

Pass criteria:
- A technical user can trust the app’s data boundaries.

## 10. Localization visual smoke

Languages:
- System Default
- 한국어
- English
- 简体中文
- 日本語

For each language:
- [ ] App launches
- [ ] Overview labels fit
- [ ] Provider cards fit
- [ ] History labels fit
- [ ] Settings section titles fit
- [ ] Setup Guide cards fit
- [ ] No obvious English fallback in core screens unless acceptable product name/technical term
- [ ] Restart-required note is understandable if language change is not live in v1

Pass criteria:
- No major clipped text or mixed-language core UI.

## 11. Empty/error/stale states

Test with no real data sources connected:
- [ ] App still renders polished mock/empty state
- [ ] No fake data is presented as real
- [ ] Invalid file path shows friendly state
- [ ] Invalid JSON/log line does not crash the app
- [ ] Stale data is labeled `STALE`
- [ ] Manual/estimated values are labeled `manual` / `est.`

Pass criteria:
- Missing data should feel intentional, not broken.

## 12. First-launch quality verdict

Use this final score after manual inspection:

- Visual polish: ___ / 10
- Native macOS feel: ___ / 10
- Overview clarity: ___ / 10
- Settings clarity: ___ / 10
- Privacy trust: ___ / 10
- Overall MVP readiness: ___ / 10

Ship recommendation:
- [ ] Ready for internal daily use
- [ ] Needs minor visual polish
- [ ] Needs settings cleanup
- [ ] Needs data-source reliability work
- [ ] Not ready

## 13. If screenshots are captured

Privacy rule:
- Capture only the TokenPilot popover/app area.
- Do not capture unrelated desktop, browser, chat, mail, files, or credentials.
- Redact token/chat/webhook values before sharing.

Recommended screenshot set:
- [ ] Menu bar closed state
- [ ] Overview mock state
- [ ] Overview stale state
- [ ] History tab
- [ ] Settings top
- [ ] Telegram section with no token displayed
- [ ] Language dropdown
- [ ] Privacy section
