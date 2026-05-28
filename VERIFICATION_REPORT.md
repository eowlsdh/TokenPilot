# TokenPilot Verification Report

**Date:** 2026-05-21 KST  
**Project path:** `/Volumes/OWC_1M2/daejinyoun/Workspace/project/mac_token_c`  
**Scope:** completion-gate audit, menu bar live refresh/currentness fix, Settings→Overview transition stabilization, Claude statusline path sync, Codex/Web/manual estimate labeling, current documentation sync, local automated build/test/smoke/security verification  
**External side effects:** none — no git, no push, no deploy, no public publish, no API key/OAuth/credential use, no Telegram/Discord live message

---

## Executive Summary

TokenPilot now has the MVP menu bar app, provider adapters, provider enablement filtering, history aggregation/export, local/Telegram/Discord notification plumbing, localization, manual Codex snapshot, experimental Codex local activity, and opt-in Codex Limit Hints Connector boundaries documented and tested.

This pass also keeps the menu bar label alive outside the popover lifecycle and ticks every 1 second for time-sensitive reset labels, while heavier provider refresh remains throttled to 5 seconds. Settings changes are saved with a short debounce and only usage-relevant changes schedule a data refresh, preventing the Settings→Overview switch from queueing redundant refresh loops. The Claude statusline default/script/helper copy now uses one path, fallback token units are localized, and estimated/manual cost/quota surfaces stay explicitly labeled.

Current gate status:

- **Automated SwiftPM test gate:** PASS — `swift test`: 92 tests / 0 failures
- **Regression coverage:** PASS — refresh policy tests cover display-only vs usage-relevant Settings changes
- **Strict compiler lint substitute:** PASS — `swift build -Xswiftc -warnings-as-errors`
- **Xcode/app smoke gate:** PASS — `xcodegen generate`, unsigned macOS Debug `xcodebuild`, `./build.sh`, plist/process smoke
- **Browser smoke:** APP N/A — this repo has no web app/server; static documentation sanity check passed instead
- **Secret-like scan:** PASS — 0 actual secret-like findings
- **Codex Limit Hints failure-state coverage:** PASS — off-by-default, JSON-RPC 2.0 payload order, app-server auth-required no-fallback, direct HTTP disabled-by-default, redacted app-server errors, legacy explicit-compatibility auth/malformed/non-leakage tests
- **Documentation alignment:** README, plan, completion report, verification report, Settings guide, launch guide, visual QA checklist, Codex limitation/verification notes updated through 2026-05-21
- **Manual visual/runtime QA:** app launch/plist smoke is automated; full human visual QA checklist remains manual
- **Production/external release:** not performed

Important constraint note:

- Git inspection/commit/push was intentionally not used because the requested constraints explicitly prohibit git use in this pass.

---

## Verification Commands

Run from project root after scoping the local toolchain:

```bash
cd /Volumes/OWC_1M2/daejinyoun/Workspace/project/mac_token_c
source .toolchain/env.sh
```

Commands for the completion gate:

```bash
swift build
swift test
xcodegen generate
xcodebuild \
  -project TokenPilot.xcodeproj \
  -scheme TokenPilot \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
./build.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' build/TokenPilot.app/Contents/Info.plist
```

Expected key artifact:

```text
build/TokenPilot.app
```

---

## Automated Results

| Check | Status | Notes |
|---|---:|---|
| Toolchain scope | PASS | `.toolchain/env.sh` exists, changes cwd to project root, performs no install/credential read |
| Swift Package build | PASS | `swift build` completed successfully |
| Strict compiler lint substitute | PASS | `swift build -Xswiftc -warnings-as-errors` completed successfully; `swiftlint` and `swift-format` are not installed in this environment |
| Unit/integration tests | PASS | final `swift test`: 124 tests, 0 failures |
| Targeted refresh policy tests | PASS | display-only Settings changes do not require provider refresh; usage-relevant Settings changes do |
| Targeted Codex Limit Hints tests | PASS | 6 filtered tests, 0 failures |
| XcodeGen | PASS | `xcodegen generate` created/refreshed `TokenPilot.xcodeproj` |
| Xcode Debug macOS build | PASS | `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` succeeded |
| App bundle script | PASS | `./build.sh` produced ad-hoc signed `build/TokenPilot.app` for local smoke execution |
| App plist identity | PASS | `com.tokenpilot.macos`, `TokenPilot`, `LSUIElement=true`, executable present |
| App process smoke | PASS | launched bundle executable with isolated temp HOME, observed running `TokenMonitor`, then stopped it |
| Browser smoke | APP N/A | repo has no HTML/JS/web server app surface; static docs sanity check passed for `APP_LAUNCH_GUIDE.md`, `SETTINGS_GUIDE.md`, and visual QA checklist |
| Secret-like scan | PASS | high-confidence literal credential scan found 0 actual secret-like findings |
| Test server/process cleanup | PASS | no long-lived server was started; launched TokenPilot smoke process was killed and verified absent |

---

## Current Code Inventory

| Item | Count / Status |
|---|---:|
| Swift files | 16 |
| Test files | 2 |
| Test methods | 124 |
| Markdown docs | 14 |
| Xcode project | present: `TokenPilot.xcodeproj` |
| XcodeGen config | present: `project.yml` |
| App bundle target | `build/TokenPilot.app` |

Core files checked:

- `Package.swift`
- `project.yml`
- `build.sh`
- `Resources/Info.plist`
- `Resources/TokenPilot.entitlements`
- `Sources/TokenApp/TokenMonitorApp.swift`
- `Sources/TokenApp/Resources/Localizable.xcstrings`
- `Sources/TokenCore/Models/TokenPilotModels.swift`
- `Sources/TokenCore/Models/ProviderSelectionModels.swift`
- `Sources/TokenCore/Services/*.swift`
- `Tests/TokenMonitorTests.swift`
- `Tests/TokenPilotServicesTests.swift`

---

## Feature Verification Matrix

### App Shell / UI

| Check | Status | Notes |
|---|---:|---|
| macOS menu bar utility | PASS | `MenuBarExtra` app shell implemented |
| Dockless app configuration | PASS | `LSUIElement` expected true in bundle plist |
| Menu bar remaining percentages | PASS | tests cover `5h 12% · W 38%` and selected-provider behavior |
| Overview screen | PASS BY CODE/TEST | header, summary metrics, provider cards, challenge, alerts status implemented |
| History screen | PASS BY CODE/TEST | periods, aggregation metrics, 7-day chart, provider share, export controls implemented |
| Settings screen | PASS BY CODE REVIEW | data sources, notifications, Telegram, Discord, language, setup guide, privacy sections implemented |
| Premium visual QA | MANUAL REQUIRED | checklist exists at `docs/TokenPilot-visual-qa-checklist.md`; human click-through still recommended |

### Provider Data Sources

| Check | Status | Notes |
|---|---:|---|
| Claude statusline JSON | PASS | `ClaudeStatuslineAdapter` parses statusline JSON |
| Claude local JSONL fallback | PASS | fallback rows implemented and tested |
| Gemini telemetry/session | PASS | telemetry/session token parsing implemented and tested |
| Codex manual `/status` parsing | PASS | parser avoids generic session/context percent false positives |
| Codex manual web snapshot | PASS | user-entered web quota snapshot round-trips through settings |
| Codex local session JSONL | PASS / EXPERIMENTAL | local activity only; not web quota |
| Codex Limit Hints Connector | PASS / OPT-IN | off by default; fake HTTP/auth tests cover parse and failure states |
| Default path resolver | PASS | `CODEX_HOME`, process HOME, archived sessions, macOS home fallback covered |
| Connection check UI | PASS BY CODE REVIEW | per-provider and all-provider connection checks implemented |

### Notifications

| Check | Status | Notes |
|---|---:|---|
| macOS local notification service | PASS | permission/status/test flow implemented |
| Threshold alert rules | PASS | 80%, 100%, reset and deduplication tested |
| Telegram settings UI | PASS | optional, off by default, token hidden after save |
| Discord settings UI | PASS | optional, off by default, webhook hidden after save |
| Telegram/Discord credential storage | PASS | TokenPilot-owned Keychain items only |
| External test send | NOT RUN | intentionally not executed without user credential/explicit intent |

### History / Export

| Check | Status | Notes |
|---|---:|---|
| Daily history snapshots | PASS | `UsageHistoryStore` implemented and tested |
| Period aggregation | PASS | Today / 7 days / month tests exist |
| Provider share | PASS | aggregation tests cover provider share |
| JSON/CSV export | PASS | export service implemented |
| Export content privacy | PASS | test covers Codex local-log snapshot token sanitization; docs state credentials/paths excluded |

### Localization

| Check | Status | Notes |
|---|---:|---|
| English | PASS | fallback supported |
| Korean | PASS | Korean label tests exist |
| Japanese | PASS | fallback supported |
| Simplified Chinese | PASS | fallback supported |
| Full visual localization QA | MANUAL REQUIRED | screenshot/click-through not performed in automated pass |

---

## Privacy / Safety Checks

| Check | Status | Notes |
|---|---:|---|
| Browser cookies | PASS | no browser-cookie access path intended or documented |
| Unrelated Keychain items | PASS | TokenPilot-specific Keychain service only |
| Codex auth file | PASS | default connector path uses local Codex CLI app-server; TokenPilot does not read Codex auth files by default, and legacy direct HTTP/auth-file compatibility is disabled unless explicitly allowed in tests |
| Token/webhook display | PASS | credential values are hidden and not exported/logged by design |
| Prompt/response transcript display | PASS BY CODE REVIEW | adapters extract usage metadata, not UI transcript content |
| Telegram/Discord off by default | PASS | defaults keep external alert channels off |
| No deploy/push/public publish | PASS | local-only verification pass |

---

## Manual QA Still Required

Before daily-use release, run:

```text
docs/TokenPilot-visual-qa-checklist.md
```

Minimum manual checks:

1. Launch `build/TokenPilot.app` or run the `TokenPilot` Xcode scheme.
2. Confirm no Dock icon appears.
3. Confirm one menu bar item appears and shows compact 5h/W remaining percentages.
4. Open the popover and inspect Overview / History / Settings.
5. Toggle providers and confirm disabled providers disappear from live calculations.
6. Check missing-source and stale-source empty states.
7. Select Claude statusline JSON and Gemini telemetry source with the picker.
8. Paste Codex `/status` output and confirm `manual/est.` labeling.
9. If explicitly enabled by the user, verify Codex Limit Hints Connector states without printing token values.
10. Export JSON/CSV from History and inspect payload shape.
11. Only if desired and configured by the user: send Telegram/Discord test messages.

---

## Known Limitations / Follow-up

1. **Browser smoke is not applicable to app functionality.**
   - This repo has no HTML/JS app or local web server. App launch/plist/process smoke is the correct substitute for the macOS SwiftUI target.

2. **Codex Limit Hints Connector is unofficial/internal.**
   - It is opt-in, default OFF, and may break if the endpoint or auth schema changes.

3. **Codex local JSONL remains local activity only.**
   - It is not official web quota and is excluded from web-comparable totals/history/export.

4. **Security-scoped bookmark flow is not implemented.**
   - If sandboxed/distributed later, file/folder picker and bookmark persistence need separate implementation and verification.

5. **Full visual QA remains manual.**
   - Automated gates cannot fully judge menu bar placement, popover visual polish, or multi-language clipping.

---

## Multi-profile Autopilot Closeout

Generated closeout artifacts:

- `docs/TokenPilot-autopilot-closeout-report.md`
- `docs/TokenPilot-autopilot-closeout-report.html`

Role-specific verdicts:

| Role | Status | Summary |
|---|---:|---|
| dev | PASS | Code/text/docs/localization/build packaging changes applied. |
| default | PASS | Swift tests, warnings-as-errors build, Xcode build, package smoke, resource/plist smoke, and secret-like scan passed. |
| main | PASS BY CODE / MANUAL VISUAL QA LEFT | Menu bar, popover, Settings structure, and privacy/credential copy align with checklist; actual clipping/jitter/density requires human screen QA. |
| content | PASS | Positioning stays local-first/metadata-only/experimental where appropriate; no official quota or revenue overclaiming. |
| research | PASS WITH VALIDATION-FIRST CAUTION | Product is a promising niche utility, but paid/public monetization should follow daily-use reliability and onboarding validation. |

Approval boundary remains unchanged: no git push, public release, deployment, real Telegram/Discord send, real Codex connector/auth use, or signing/notarization work was performed.

---

## Verdict

**Current status:** final local completion gate passed within the stated approval boundaries. TokenPilot satisfies the requested local completion criteria, with full human visual QA remaining as an explicit manual follow-up and no git/push/deploy/public publish performed.
