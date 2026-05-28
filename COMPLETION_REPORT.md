# TokenPilot — 로컬 완료 보고서

**문서 상태**: current local completion report  
**마지막 갱신**: 2026-05-21 KST  
**프로젝트 경로**: `/Volumes/OWC_1M2/daejinyoun/Workspace/project/mac_token_c`  
**앱 표시 이름**: `TokenPilot`  
**SwiftPM 실행 타깃**: `TokenMonitor`  
**외부 side effect**: 없음 — git push/deploy/public release/Telegram·Discord 실발송/API key·credential 사용 없음

> 이 문서는 오래된 `TokenMonitor` 5초 타이머/16개 테스트 완료 보고서를 대체합니다.

---

## 1. 결론

TokenPilot은 현재 local MVP completion gate를 통과할 수 있는 상태를 목표로 정리되어 있습니다. 구현 범위는 메뉴바 앱, provider adapters, provider enablement, history/export, local/Telegram/Discord notification plumbing, localization, Codex manual/local/opt-in web connector 경계까지입니다.

핵심 정합성:

- 메뉴바 label은 앱이 떠 있는 동안 1초 간격의 lightweight tick으로 시간 민감 reset label을 갱신합니다.
- 실제 provider data refresh는 5초 throttle로 분리되어 있습니다.
- Settings 변경은 debounce 저장되며 usage-relevant 변경만 refresh를 예약합니다.
- Codex local/manual/connector 값은 confidence와 `est.`/`manual`/`not web quota` 맥락을 분리합니다.
- Export copy는 사용량 합계와 secret token을 혼동하지 않도록 명시했습니다.

---

## 2. 완료된 범위

### App shell / UI

- `MenuBarExtra` 기반 macOS menu bar utility
- Dock icon 없는 `LSUIElement` 앱 구성
- Compact menu bar label: 5h/W remaining percentage, selected provider 또는 highest-risk fallback
- Premium dark utility popover: Overview / History / Settings
- Multi-language fallback: English, Korean, Japanese, Simplified Chinese

### Data / adapters

- Claude statusline JSON + local JSONL fallback
- Gemini telemetry/session JSONL parsing
- Codex manual `/status` parser
- Codex manual web snapshot
- Codex experimental local activity parser
- Codex Limit Hints Connector: off by default, opt-in, failure states tested

### Privacy / safety

- Browser cookies/session store 미사용
- TokenPilot 전용 Keychain item만 사용
- Credential value UI 표시/export/log 금지
- Telegram/Discord 기본 OFF
- Codex connector 기본 OFF
- Raw prompt/response text export 금지

### Build / verification surface

- SwiftPM build/test
- warnings-as-errors compiler gate
- XcodeGen/Xcode debug build
- local app bundle script
- plist/process smoke
- documentation alignment

---

## 3. Current inventory

| Item | Current status |
|---|---:|
| Swift files | 16 |
| Test files | 2 |
| Test methods | verified by latest `swift test` run |
| Markdown docs | 14 |
| Xcode project | `TokenPilot.xcodeproj` |
| XcodeGen config | `project.yml` |
| App bundle target | `build/TokenPilot.app` |

---

## 4. Verification commands

```bash
cd /Volumes/OWC_1M2/daejinyoun/Workspace/project/mac_token_c
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
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' build/TokenPilot.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' build/TokenPilot.app/Contents/Info.plist
test -f build/TokenPilot.app/Contents/Resources/TokenMonitor_TokenApp.bundle/Localizable.xcstrings
```

Expected key artifact:

```text
build/TokenPilot.app
```

---

## 5. Manual QA still required

Automated checks do not replace native visual/runtime QA. Before daily-use release, run:

```text
docs/TokenPilot-visual-qa-checklist.md
```

Minimum checks:

1. Launch `build/TokenPilot.app` or run the `TokenPilot` Xcode scheme.
2. Confirm no Dock icon appears.
3. Confirm one compact menu bar item appears.
4. Open Overview / History / Settings.
5. Toggle providers and verify disabled providers disappear from live calculations.
6. Check missing-source, mock, stale, manual, estimated states.
7. Export JSON/CSV and inspect that secrets/paths/raw prompt text are absent.
8. Only with explicit approval and user-provided credentials: Telegram/Discord test messages.
9. Only with explicit opt-in: Codex Limit Hints Connector state checks.

---

## 6. Not performed / approval-gated

- git commit / git push
- public release / deploy / App Store submission
- Telegram/Discord live message send
- external credential generation or storage outside TokenPilot UI
- paid service signup or API key use
- destructive cleanup or archive moves

---

## 7. Product/business note

TokenPilot is strongest as a **trust-building utility + AI automation case study** rather than a standalone revenue product on day one. Good next content angle: “I built a local-first menu bar tool to stop guessing my AI quota” with clear caveats about unofficial Codex data and opt-in connectors.
