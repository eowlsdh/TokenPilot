# TokenPilot — 현재 구현 계획 / 운영 기준

**문서 상태**: current source-of-truth  
**마지막 갱신**: 2026-05-24 KST  
**앱 표시 이름**: `TokenPilot`  
**SwiftPM 실행 타깃**: `TokenMonitor`  
**번들 산출물**: `build/TokenPilot.app`

> 이전 `TokenMonitor` 5초 갱신 계획서는 현재 구현과 맞지 않아 이 문서로 대체합니다. 현재 기준은 **메뉴바 label 약 1초 tick + provider data refresh 5초 throttle**입니다.

---

## 1. 제품 목표

TokenPilot은 Claude Code, Codex, Gemini CLI의 **사용량 메타데이터**를 local-first 방식으로 모아 macOS 메뉴바에서 현재 위험도와 남은 한도 감각을 빠르게 확인하는 작은 유틸리티입니다.

핵심 방향:

1. **로컬 우선**: 기본 동작은 로컬 파일/사용자 입력 기반입니다.
2. **사용량 메타데이터만 표시**: 프롬프트/응답 본문, 브라우저 쿠키, 임의 Keychain 항목을 읽지 않습니다.
3. **추정값은 추정값으로 표시**: Codex local activity/manual 값은 `est.`, `manual`, `Local log`, `Not web quota` 맥락을 붙입니다.
4. **외부 발송은 opt-in**: Telegram/Discord 알림, Codex Limit Hints Connector는 기본 OFF입니다.
5. **작고 믿을 수 있는 메뉴바 앱**: 대시보드 과잉보다 compact/native utility 경험을 우선합니다.

---

## 2. 현재 구현 범위

### App shell / UI

- SwiftUI `MenuBarExtra` 기반 dockless menu bar app
- 팝오버 크기 목표: 약 `420 x 620`
- 화면:
  - Overview: 오늘 토큰, 최고 위험도, 가장 가까운 reset, provider cards, daily challenge, alert summary
  - Overview recommendation card labels the lowest observed current usage, not a definitive “best tool” recommendation
  - History: Today / Last 7 days / This month, 7-day chart, provider share, JSON/CSV export
  - Settings: data sources, notifications, Telegram, Discord, language, setup guide, privacy

### Refresh policy

- 메뉴바 label tick: 1초 간격의 lightweight clock/update
- provider data refresh: 5초 이상 간격으로 throttle
- Settings 저장: 짧은 debounce
- usage-relevant settings만 provider refresh 예약
- display-only settings는 refresh loop를 만들지 않음

### Data sources

- Claude Code
  - statusline JSON
  - local JSONL fallback
  - context window / 5h / weekly / token / cost metadata
- Codex
  - manual `/status` / manual web snapshot
  - experimental local activity JSONL
  - opt-in Limit Hints Connector
- Gemini CLI
  - telemetry log
  - session JSON/JSONL token object fallback
  - daily request cap/usage

### Notifications

- macOS local notification
- Telegram alert: optional, off by default, TokenPilot-owned Keychain item
- Discord webhook alert: optional, off by default, TokenPilot-owned Keychain item
- threshold/reset deduplication by provider/window/cycle

### Export

- JSON/CSV history export
- Usage totals/events may be included
- Credentials, secret tokens, chat IDs, webhooks, local file paths, raw prompt/response text are excluded

### Commercial registration resources

- App privacy manifest: `Resources/PrivacyInfo.xcprivacy`
- Sample data preview is optional and OFF by default for commercial honesty
- User-selected Claude/Gemini sources store read-only security-scoped bookmarks for sandbox readiness
- Menu bar now refreshes without waiting for popover open: 1s display tick + 5s data refresh
- Menu bar now uses compact visual remaining-percent badges for 5h/week windows
- Claude/Codex/Gemini use custom animated provider signature marks, not official logo copies
- Data source setup is split into provider-by-provider cards instead of one long block
- History now records limit-signal samples even when token event rows are unavailable, with a clearer empty state
- App icon asset catalog: `Resources/Assets.xcassets/AppIcon.appiconset`
- Manual bundle icon: `Resources/TokenPilot.icns`
- Icon generation script: `Scripts/generate-app-icons.swift`
- Detailed registration plan: `docs/TokenPilot-commercialization-registration-plan.md`
- Store metadata draft: `docs/TokenPilot-store-metadata-draft.md`
- Privacy policy draft: `docs/TokenPilot-privacy-policy-draft.md`
- Release notes template: `docs/TokenPilot-release-notes-template.md`

---

## 3. Verification gates

Run from project root:

```bash
source .toolchain/env.sh
swift build
swift test
swift build -Xswiftc -warnings-as-errors
xcodegen generate
xcodebuild \
  -project TokenPilot.xcodeproj \
  -scheme TokenPilot \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
./build.sh
```

Smoke checks:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' build/TokenPilot.app/Contents/Info.plist
test -f build/TokenPilot.app/Contents/Resources/TokenMonitor_TokenApp.bundle/Localizable.xcstrings
test -f build/TokenPilot.app/Contents/Resources/PrivacyInfo.xcprivacy
test -f build/TokenPilot.app/Contents/Resources/TokenPilot.icns
```

Manual QA remains separate:

- `docs/TokenPilot-visual-qa-checklist.md`
- actual Telegram/Discord test sends only with explicit user credential/approval
- actual Codex Limit Hints Connector call only with explicit opt-in/approval

---

## 4. Current known limitations

1. **Full visual QA is manual**: automated launch/plist smoke cannot fully inspect native popover polish.
2. **Codex local logs are experimental**: they are not official web quota and must not be marketed as exact billing or official quota.
3. **Codex Limit Hints Connector is unofficial/opt-in**: endpoint/auth/response shape may change.
4. **Distribution hardening is in progress**: privacy manifest, AppIcon/ICNS, local bundle packaging, and user-selected source bookmarks are now present; actual App Sandbox entitlement/signing/notarization/App Store metadata still require dedicated passes.
5. **No git/push/deploy in this pass**: local files are updated only; publication/release requires approval.

---

## 5. Next safe-local work queue

Priority order:

1. Run screenshot-level visual QA using the final reviewed UI state.
2. Decide final Support URL / Marketing URL / Privacy Policy URL and paste reviewed copy into the selected hosting surface.
3. If preparing external distribution, run actual sandbox entitlement/signing/notarization/privacy-label planning as a separate approval-gated task.
