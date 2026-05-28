# TokenPilot 상업화·앱 등록 준비 계획

**상태:** active release-readiness plan  
**마지막 갱신:** 2026-05-25 22:36 KST  
**대상 앱:** TokenPilot macOS menu bar utility  
**목표:** 실제 상업 배포/App Store 등록 후보로 올릴 수 있는 수준까지 로컬 구현·검증·문서·수동 게이트를 분리한다.  
**안전 경계:** 이 문서는 로컬 준비 계획이다. Git push, App Store 업로드, notarization 제출, 외부 메시지 발송, API key/OAuth/credential 입력·저장·사용은 별도 명시 승인 전까지 진행하지 않는다.

---

## 0. 제품 판단 요약

TokenPilot은 “AI 코딩 도구 사용량을 메뉴바에서 빠르게 보는 작은 유틸리티”로 상업화 가능성이 있다. 다만 초기 판매 약속은 **정확한 공식 과금/쿼터 앱**이 아니라 **local-first 사용량 메타데이터·한도 힌트·알림 유틸리티**로 좁혀야 한다.

상업화에 유리한 점:

- 사용자가 매일 보는 메뉴바 문제를 해결한다.
- Claude/Codex/Gemini처럼 여러 AI 코딩 도구를 함께 쓰는 사용자에게 즉시 맥락이 있다.
- 로컬 우선·credential 미열람·추정값 라벨링은 신뢰 포인트가 된다.
- 앱 크기가 작아 1인 개발자가 유지 가능한 범위다.

상업화 리스크:

- Codex/Claude/Gemini의 공식 quota/로그 형식은 변경될 수 있다.
- “공식 사용량”처럼 과장하면 리뷰/환불/신뢰 리스크가 커진다.
- App Store용 sandbox, security-scoped bookmarks, privacy questionnaire, signing/notarization은 아직 수동 게이트다.
- 가격 검증은 아직 실제 유저 파일럿/전환율 데이터가 없다.

권장 첫 포지셔닝:

> “Claude Code, Codex, Gemini CLI 사용량 메타데이터를 로컬에서 읽어 메뉴바에 남은 한도 감각과 알림을 보여주는 privacy-first macOS utility. 공식 청구/쿼터 보증 앱이 아니라 local usage monitor + limit hints 앱.”

---

## 1. 현재 완료된 상업화 P0 보강

이번 패스에서 앱 등록/배포 blocker가 되기 쉬운 릴리스 리소스를 TDD로 고정했다.

| 항목 | 상태 | 근거 파일 |
|---|---:|---|
| App Privacy Manifest | DONE | `Resources/PrivacyInfo.xcprivacy` |
| Tracking 없음 선언 | DONE | `NSPrivacyTracking=false`, tracking domains empty |
| 수집 데이터 없음 선언 | DONE | `NSPrivacyCollectedDataTypes=[]` |
| Required Reason API 기본 선언 | DONE | UserDefaults, FileTimestamp |
| AppIcon asset filenames | DONE | `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` |
| security-scoped bookmark persistence | DONE | `AppSettings` stores Claude/Gemini selected-source bookmarks |
| security-scoped bookmark access wrapper | DONE | `TokenPilotSecurityScopedBookmarks` resolves read-only bookmarks |
| macOS icon PNG 10종 | DONE | `Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png` |
| 앱 번들 icns | DONE | `Resources/TokenPilot.icns` |
| icon 생성 스크립트 | DONE | `Scripts/generate-app-icons.swift` |
| manual app bundle packaging | DONE | `build.sh` copies `PrivacyInfo.xcprivacy` and `TokenPilot.icns` |
| XcodeGen app resources | DONE | `project.yml` includes `Resources/Assets.xcassets`, `PrivacyInfo.xcprivacy`, `TokenPilot.icns` |
| Info.plist icon reference | DONE | `CFBundleIconFile=TokenPilot`, `CFBundleIconName=AppIcon` |
| 회귀 테스트 | DONE | `TokenMonitorTests/testCommercialReleaseResourcesArePresentAndPackaged` |
| menu bar live refresh | DONE | 1s UI tick + 5s data refresh timer in `.common` run loop |
| menu bar visual percent badges | DONE | compact 5h/week remaining-percent badges |
| provider signature marks | DONE | custom animated Claude/Codex/Gemini marks, not official logo copies |
| one-by-one provider setup cards | DONE | Claude/Gemini/Codex setup split into separate cards |
| history limit-signal persistence | DONE | stores limit-window samples when token event rows are unavailable |

주의: privacy reason code는 배포 전 Apple 최신 문서와 App Store Connect/Transporter 검증으로 재확인해야 한다. 현재 선언은 앱의 설정 저장(UserDefaults)과 로컬 파일 stale/modified date 확인(FileTimestamp) 목적에 맞춘 초기 후보다.

---

## 2. TDD / 검증 게이트 현황

### 이번 패스에서 확인한 명령

```bash
source .toolchain/env.sh
swift test --filter TokenMonitorTests/testCommercialReleaseResourcesArePresentAndPackaged
swift test
swift build
xcodegen generate
xcodebuild \
  -project TokenPilot.xcodeproj \
  -scheme TokenPilot \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
bash build.sh
```

### 현재 결과

| Gate | 상태 | 결과 |
|---|---:|---|
| Baseline before change | PASS | 124 tests / 0 failures |
| RED | PASS | 신규 commercial resource test가 `PrivacyInfo.xcprivacy` 누락으로 실패 확인 |
| GREEN targeted | PASS | 1 test / 0 failures |
| Full SwiftPM tests | PASS | 124 tests / 0 failures |
| SwiftPM build | PASS | `swift build` succeeded |
| XcodeGen/Xcode Debug build | PASS | `xcodegen generate` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` succeeded; Xcode app bundle contains `PrivacyInfo.xcprivacy`, `TokenPilot.icns`, and `Assets.car` |
| Launch smoke | PASS | `build/TokenPilot.app/Contents/MacOS/TokenMonitor` launched with isolated temporary HOME, process observed, then terminated and temp HOME cleaned |
| Local app bundle build | PASS | `build/TokenPilot.app` 생성, privacy manifest/icon/localization 포함 확인 |

### 다음부터 상업화 작업마다 유지할 최소 게이트

```bash
source .toolchain/env.sh
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
bash build.sh
python3 - <<'PY'
from pathlib import Path
app = Path('build/TokenPilot.app')
required = [
    app/'Contents/MacOS/TokenMonitor',
    app/'Contents/Resources/PrivacyInfo.xcprivacy',
    app/'Contents/Resources/TokenPilot.icns',
    app/'Contents/Resources/TokenMonitor_TokenApp.bundle/Localizable.xcstrings',
]
missing = [str(p) for p in required if not p.exists()]
print('missing:', missing)
raise SystemExit(1 if missing else 0)
PY
```

---

## 3. 등록 전 Phase 계획

### Phase A — 제품 약속 동결

목표: 리뷰/환불 리스크를 줄이기 위해 앱이 실제로 보장할 수 있는 문구만 남긴다.

- [x] Codex는 “exact web quota”가 아니라 “Limit Hints / manual / local activity estimate”로 표기
- [x] TokenPilot은 Codex access token을 읽거나 저장/표시/내보내지 않는다는 경계 유지
- [x] README/앱 내 onboarding/Store description의 약속을 동일하게 정렬 — local draft: `docs/TokenPilot-store-metadata-draft.md`
- [x] “공식 청구/과금 보증 아님” 문구를 스토어 설명·앱 내 Privacy/Setup에 반영할 초안 작성
- [x] first-run 상태에서 mock/manual/estimated 값을 오해하지 않게 UX 문구 확인
- [x] 스토어/앱 UI에서 공식 로고 오해를 피하는 자체 provider signature mark 적용
- [x] 메뉴바 자동 갱신: 1초 표시 tick + 5초 데이터 refresh로 “눌러야 갱신” 체감 개선
- [x] Settings data source setup을 provider별 개별 카드로 분리

### Phase B — App Store / 직접 배포 리소스

- [x] `PrivacyInfo.xcprivacy` 추가
- [x] AppIcon PNG/ICNS 추가
- [x] `build.sh`에 privacy/icon packaging 추가
- [x] XcodeGen/Xcode build에 AppIcon asset catalog, privacy manifest, icns 포함
- [ ] 앱 버전·빌드번호 release policy 결정 (`1.0.0`, build `1`부터 시작)
- [x] release notes 템플릿 작성 — `docs/TokenPilot-release-notes-template.md`
- [x] Support URL / Marketing URL / Privacy Policy URL 초안 정리 — privacy draft: `docs/TokenPilot-privacy-policy-draft.md`; 실제 URL 확정은 배포 전 승인 필요
- [ ] 스크린샷 6장 후보 캡처: 메뉴바, Overview, History, Settings, Privacy, empty/manual states
- [ ] 다국어 스토어 메타데이터 범위 결정: 초기 ko/en만 권장

### Phase C — Sandbox / 파일 접근

App Store 목표라면 이 단계가 핵심 blocker다.

- [ ] App Sandbox ON 여부 결정
- [x] 사용자 선택 파일/폴더 접근용 read-only security-scoped bookmark 저장/resolve 레이어 추가
- [x] Claude/Gemini file picker 선택값에 bookmark 저장 및 재읽기 경로 연결
- [ ] Claude/Gemini/Codex 기본 경로 자동 스캔이 sandbox에서 동작 가능한지 검증
- [ ] sandbox 불가 기능은 “직접 배포 build only”로 분리
- [x] file picker 권한 실패 시 친절한 onboarding/error copy 추가

판단 기준:

- App Store를 우선하면 sandbox/bookmark UX를 먼저 고쳐야 한다.
- 빠른 유료 검증을 우선하면 notarized direct distribution을 먼저 고려할 수 있다.

### Phase D — Signing / Notarization / Store 제출

승인 없이 진행 금지.

- [ ] Apple Developer Program 상태 확인
- [ ] Bundle ID 확정: `com.tokenpilot.macos`
- [ ] Team ID / signing identity 선택
- [ ] hardened runtime 설정
- [ ] Developer ID 직접 배포 notarization dry-run
- [ ] App Store archive/export/Transporter 검증
- [ ] App Store privacy questionnaire 작성
- [ ] TestFlight 또는 내부 테스터 배포

### Phase E — Human QA

- [ ] `docs/TokenPilot-visual-qa-checklist.md` 전체 수행
- [ ] 메뉴바 라벨 `5h xx% · W yy%` 실제 표시 확인
- [ ] popover clipping/scroll/다국어 깨짐 확인
- [ ] mock/empty/stale/manual/estimated 상태가 오해 없이 보이는지 확인
- [ ] export JSON/CSV에 credential, token, chat ID, webhook, local path가 없는지 샘플 확인
- [ ] Telegram/Discord test send는 사용자가 직접 credential을 입력하고 별도 승인한 경우만 수행

### Phase F — 판매 실험

출시 전부터 “큰 SaaS”로 키우지 말고, 작게 검증한다.

- [ ] 5명 내외 macOS AI coding-tool heavy user에게 무료/쿠폰 파일럿
- [ ] 핵심 질문: 매일 메뉴바에서 봤는가, 과장이라고 느꼈는가, 가격을 낼 이유가 있었는가
- [ ] 가격 후보: one-time utility / low monthly / free trial + paid unlock 중 하나로 시작
- [ ] 전환 기준: 5명 중 2명 이상이 실제 작업일에 계속 열어두면 다음 단계
- [ ] 실패 기준: “정확도가 못 믿겠다”가 반복되면 공식 quota가 아니라 “local usage diary/alert”로 더 좁힘

---

## 4. 5개 lane 검토 기준

### dev — 실제 코딩/기술 구현

현재 verdict: **PASS with next P0: signed/sandbox entitlement validation**

- PASS: core tests 124개 통과
- PASS: commercial release resources test 추가
- PASS: first-run sample preview OFF by default, honest copy added
- PASS: Claude/Gemini user-selected sources now persist read-only security-scoped bookmarks
- PASS: local bundle에 privacy manifest/icon/localization 포함
- PASS: launch smoke with isolated temporary HOME completed and cleaned
- PASS: Xcode Debug bundle에 privacy manifest, compiled asset catalog, icns 포함
- PASS: History 탭이 token event row가 없어도 한도 신호 기록을 표시
- PASS: 메뉴바에 남은 퍼센트를 compact badge로 시각화
- WARN: actual App Sandbox entitlement/signing/notarized build는 아직 미검증
- HOLD: signing/notarization/App Store upload는 승인 필요

다음 dev 우선순위:

1. visual QA + screenshot capture
2. actual sandbox entitlement + signing strategy 확정 — 서명/계정 사용은 승인 게이트
3. App Store archive/export 검증은 signing 승인 후

### default — 코드 검증

현재 verdict: **PASS for local/Xcode unsigned build-test, WARN for signed App Store pipeline**

- PASS: `swift build`
- PASS: `swift build -Xswiftc -warnings-as-errors`
- PASS: `swift test` 121/121
- PASS: `xcodegen generate` + unsigned `xcodebuild` succeeded
- PASS: `bash build.sh` bundle resource smoke
- WARN: App Store Connect/Transporter validation은 credential/approval 필요

### main — 디자인/UI/UX

현재 verdict: **PASS for current polish pass, MANUAL REQUIRED for screenshot-level QA**

- PASS: AppIcon은 near-black utility tone + blue accent + token meter motif로 제품 성격과 맞음
- PASS: 과한 purple gradient/shadow 중심의 AI slop은 피함
- PASS: Claude/Codex/Gemini provider mark를 공식 로고 복제 대신 자체 signature mark로 정리
- PASS: provider mark에 restrained startup animation 적용
- PASS: Settings의 Data Sources를 하나의 긴 덩어리에서 provider별 개별 카드로 분리
- PASS: 메뉴바 label은 popover open 없이 1초 tick/5초 refresh로 갱신
- PASS: 메뉴바 숫자는 5h/week 남은 퍼센트 badge로 더 즉시 읽히게 개선
- PASS: History 탭은 token event가 없을 때도 limit signal card와 설명형 empty state를 표시
- WARN: 실제 메뉴바 크기에서 16px/32px icon 가독성은 눈으로 확인 필요
- WARN: 스토어 스크린샷은 아직 없음

다음 main 우선순위:

1. real app launch visual QA
2. screenshot set 제작
3. App Store preview copy와 UI terminology 일치

### content — 방향성/문구 검증

현재 verdict: **PASS if promise remains conservative**

허용 문구:

- “local-first usage monitor”
- “limit hints”
- “manual/estimated where provider data is unofficial”
- “does not read browser cookies or Codex auth files”

금지/위험 문구:

- “정확한 공식 Codex web quota 자동 추적”
- “모든 AI 비용/한도 완벽 추적”
- “billing-grade accuracy”
- “credentials-free official API”처럼 오해를 부르는 표현

다음 content 우선순위:

1. FAQ: “정확도”, “어떤 파일을 읽나요”, “Codex는 왜 estimate인가요”를 README 또는 support page에 반영
2. 한국어/영어 store subtitle 최종 1개 선택
3. 스크린샷 caption이 store metadata draft의 보수적 약속을 넘지 않는지 검수

### research — 수익성 피드백

현재 verdict: **GO for small paid utility validation, NO-GO for large subscription promise**

수익화 가설:

- 가장 현실적인 1차 고객은 Claude/Codex/Gemini를 매일 쓰는 macOS 개발자다.
- “작고 신뢰 가능한 메뉴바 유틸”로는 one-time 또는 저가 구독 실험이 맞다.
- 높은 월 구독을 정당화하려면 공식 provider API/팀 기능/리포팅이 필요하지만, 이는 현재 scope를 벗어난다.

초기 판매 실험 권장:

- Free trial 또는 무료 베타 → paid unlock
- 가격은 사용자 인터뷰/파일럿 이후 결정
- 1차 KPI: 설치 수보다 “매일 메뉴바에 남겨두는지”, “추정값 라벨이 신뢰를 해치지 않는지”
- 유지보수 비용 KPI: provider 로그 포맷 변경 1건당 대응 시간

수익성 blocker:

- official quota와 local estimate의 차이를 사용자가 불편하게 느끼면 paid conversion이 낮아질 수 있음
- App Store sandbox 때문에 핵심 local paths 접근 UX가 나빠지면 이탈 위험
- provider 포맷 변화 대응이 느리면 환불/평점 리스크

---

## 5. 출시 전 승인 게이트

아래는 자동 진행 금지다.

| Gate | 이유 | 필요한 사용자 승인 |
|---|---|---|
| Git push / 공개 repo publish | 외부 공개/배포 트리거 가능 | exact branch/remote 승인 |
| Apple Developer login/use | 계정/credential 영역 | 로그인 방식/범위 승인 |
| Signing certificate use | identity/credential 사용 | Team ID/cert 범위 승인 |
| Notarization submit | Apple 외부 제출 | bundle/version 승인 |
| App Store/TestFlight upload | 공개/테스터 배포 가능 | metadata/build 승인 |
| Telegram/Discord live test | 외부 메시지 발송 | 채널/내용/credential 승인 |
| API key/OAuth/token 입력·저장 | secret handling | secret-safe 입력 방식 승인 |
| DB/히스토리 destructive reset | 데이터 삭제 | 대상/백업/rollback 승인 |

---

## 6. 다음 오토파일럿 순서

승인 경계 안에서 다음 순서로 진행한다.

1. visual QA + screenshot capture: 메뉴바/Overview/History/Settings/Privacy/empty state
2. FAQ/support page copy 반영 및 URL 확정 — 실제 게시/업로드는 승인 필요
3. actual sandbox entitlement/signing/notarization/privacy-label planning — Apple 계정/서명/제출은 승인 게이트
4. 모든 자동 검증 통과 후 남은 것은 Apple 계정/signing/upload 승인 게이트로 보고
