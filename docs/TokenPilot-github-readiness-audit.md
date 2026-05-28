# TokenPilot GitHub 오픈소스 준비성 검토

**작성일**: 2026-05-28 KST
**문서 상태**: Wiki — 퍼블리스 전 검토 기록
**목표**: GitHub 5,000+ 스타

---

## 1. 종합 요약

| 카테고리 | 건수 | 예상 노력 |
|---|---|---|
| 🔴 Critical (퍼블리스 blocker) | 7건 | 2-3일 |
| 🟠 High (아키텍처) | 3건 | 3-5일 |
| 🟡 Medium (바이럴 기능) | 7건 | 2-3주 |
| 🟢 Low (폴리시) | 6건 | 1주 |
| **합계** | **23건** | **약 4-5주** |

---

## 2. 🔴 CRITICAL — 퍼블리스 전 필수

| # | 이슈 | 설명 | 상태 |
|---|---|---|---|
| 1 | LICENSE 없음 | 라이선스 없이는 오픈소스가 아님. MIT 또는 Apache 2.0 필수 | ❌ |
| 2 | .gitignore 없음 | `build/`, `.build/`, `*.xcuserdata` 등이 커밋됨 | ❌ |
| 3 | git 저장소 미초기화 | `git init` 필요 | ❌ |
| 4 | README 한국어 전용 | 5,000 스타 글로벌 타겟이면 영문 필수. 배지, 스크린샷, GIF 데모 없음 | ❌ |
| 5 | GitHub Actions CI 없음 | `.github/workflows/` — 빌드/테스트 자동화 없이는 신뢰도 부족 | ❌ |
| 6 | 개발자 경로 노출 | 문서 9곳에 `/Volumes/OWC_1M2/daejinyoun/...` 하드코딩 | ❌ |
| 7 | Keychain 서비스명 개발자명 노출 | `com.daejinyoun.TokenPilot` → `com.tokenpilot.macos` 변경 필요 | ❌ |

---

## 3. 🟠 HIGH — 아키텍처 개선

| # | 이슈 | 파일 | 설명 |
|---|---|---|---|
| 8 | God Object 2,818줄 | `TokenMonitorApp.swift` | ViewModel(30+ @Published) + 30개 뷰 + 디자인 시스템이 한 파일. 15-20개 파일로 분리 필요 |
| 9 | 중복 헬퍼 함수 | `TokenPilotServices.swift` + `DataSourceAdapters.swift` | `expandTilde()`, `dictionary()`, `intValue()` 등 동일 함수 2곳에 정의 |
| 10 | AppSettings God Struct | `TokenPilotModels.swift` | 20+ 속성 + 200줄 Custom Codable. 분리 필요 |

---

## 4. 🟡 MEDIUM — 5,000 스타를 위한 기능 격차

| # | 기능 | 영향도 | 노력 |
|---|---|---|---|
| 11 | Provider 플러그인 시스템 | 커뮤니티 기여 유인 | 1주 |
| 12 | WidgetKit 지원 | 매일 메뉴바 가시성 = 바이럴 루프 | 3일 |
| 13 | Light Mode / 적응형 테마 | 사용자 베이스 2배 | 3일 |
| 14 | CLI 컴패니언 도구 | 개발자 워크플로우 통합 | 3일 |
| 15 | HTML/Markdown 리포트 내보내기 | 공유 가능한 사용량 리포트 | 2일 |
| 16 | Makefile | 기여자 경험 혁신 | 0.5일 |
| 17 | CONTRIBUTING.md + CODE_OF_CONDUCT.md | 오픈소스 표준 | 0.5일 |

---

## 5. 🟢 LOW — 폴리시/접근성

| # | 이슈 | 설명 |
|---|---|---|
| 18 | Dynamic Type 미지원 | 폰트 하드코딩 (~80곳) |
| 19 | VoiceOver 부분적 | 메뉴바/히어로카드만 지원 |
| 20 | 키보드 네비게이션 없음 | 탭 전환, 새로고침 단축키 없음 |
| 21 | 컨텍스트 메뉴 없음 | 우클릭 시 옵션 없음 |
| 22 | `isWebQuotaComparable` 항상 `true` | 필터 no-op, dead code |
| 23 | 소스 문자열 테스트 패턴 | 리팩토링 시 깨지는 취약 테스트 |

---

## 6. 5,000 스타 전략

1. **영문 README + 스크린샷/GIF** — GitHub 방문자 → 스타 전환율의 90%
2. **Hacker News "Show HN"** — 메뉴바 도구는 HN에서 반응 좋음
3. **Reddit r/macOS, r/SwiftUI, r/ChatGPT** — 타겟 커뮤니티
4. **"I built a local-first AI usage monitor" 블로그 포스트** — 개발자 스토리
5. **Product Hunt 런칭** — 유틸리티 카테고리 성과 좋음

---

## 7. 경쟁 분석

| 도구 | 하는 일 | TokenPilot이 채우는 갭 |
|---|---|---|
| OpenAI Usage Dashboard | 웹 전용 사용량 | 네이티브 macOS, 멀티 프로바이더 |
| Claude Code statusline | CLI 상태 표시 | 멀티 프로바이더 통합 |
| GitHub Copilot metrics | 엔터프라이즈 과금 | 로컬 우선, 개인 개발자 포커스 |
| 다양한 AI 비용 추적기 | 웹 대시보드 | 메뉴바 네이티브, 웹 의존성 없음 |

### TokenPilot의 차별화 포인트
1. **멀티 프로바이더 통합** — Claude + Codex + Gemini 한 눈에 (유니크)
2. **로컬 우선 프라이버시** — 데이터 머신 밖으로 나가지 않음 (신뢰 포인트)
3. **메뉴바 네이티브** — 웹 대시보드가 아닌 네이티브 macOS
4. **정직한 라벨링** — `est.`, `manual` 라벨로 신뢰 구축
5. **무료 + 오픈소스** — 폐쇄 도구를 불신하는 개발자 유인
