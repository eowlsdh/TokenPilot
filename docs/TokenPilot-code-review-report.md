# TokenPilot 코드 리뷰 및 개선 보고서

**작성일**: 2026-05-28 KST
**문서 상태**: Wiki — 코드 품질/버그 검토 기록
**검토 범위**: 전체 소스 코드 16개 Swift 파일 + 2개 테스트 파일 + 14개 Markdown 문서

---

## 1. 검토 요약

### 문서 정합성 (이전 세션에서 수정 완료)

| 카테고리 | 발견 건수 | 상태 |
|---|---|---|
| 테스트 수 불일치 (92/86/106/121 → 124) | 13건 | ✅ 수정 완료 |
| Refresh 간격 불일치 (10초/30초 → 1초/5초) | 9건 | ✅ 수정 완료 |
| Swift 파일 수 불일치 (14 → 16) | 3건 | ✅ 수정 완료 |
| Markdown 문서 수 불일치 (9 → 14) | 3건 | ✅ 수정 완료 |
| PLAN.md 내부 모순 | 1건 | ✅ 수정 완료 |

### 소스 코드 이슈 (이번 세션에서 수정)

| 심각도 | 발견 | 수정 | 잔존 |
|---|---|---|---|
| Medium | 6건 | 6건 | 0건 |
| Low | 9건 | 2건 | 7건 |
| **합계** | **15건** | **8건** | **7건** |

---

## 2. 수정된 Medium 이슈 상세

### M1. `try!` force-unwrap 제거 (DataSourceAdapters.swift)

**파일**: `Sources/TokenCore/Services/DataSourceAdapters.swift:104-108`
**심각도**: Medium — 프로덕션 코드에서 JSON 직렬화 실패 시 크래시

**수정 전**:
```swift
return [initialize, read].map { object in
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}
```

**수정 후**:
```swift
return [initialize, read].compactMap { object in
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        return nil
    }
    return str
}
```

**리스크**: Very Low. 입력은 리터럴 딕셔너리로 항상 직렬화 가능하지만, 향후 입력 변경 시 크래시 대신 graceful degradation.

---

### M2. `URL(string:)!` force-unwrap 제거 (DataSourceAdapters.swift)

**파일**: `Sources/TokenCore/Services/DataSourceAdapters.swift:783`
**심각도**: Medium — URL 리터럴 변경 시 크래시

**수정 전**:
```swift
endpointURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
```

**수정 후**:
```swift
endpointURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage") ?? URL(fileURLWithPath: "/dev/null"),
```

**리스크**: Very Low. fallback URL은 도달 불가.

---

### M3. AppleScript 이스케이프 개선 (TokenPilotServices.swift)

**파일**: `Sources/TokenCore/Services/TokenPilotServices.swift:452-457`
**심각도**: Medium — `\r`, `\t` 문자 포함 시 AppleScript 알림 깨짐

**수정 전**:
```swift
var appleScriptEscaped: String {
    replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
}
```

**수정 후**:
```swift
var appleScriptEscaped: String {
    replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
}
```

**리스크**: Very Low. 기존 알림 문자열에 `\r`/`\t`가 없어 현재 동작 변화 없음.

---

### M4. 합성 이벤트 `isEstimated` 플래그 추가 (UsageHistoryStore.swift)

**파일**: `Sources/TokenCore/Services/UsageHistoryStore.swift:34-48`
**심각도**: Medium — 합성 이벤트가 명시 이벤트와 구분되지 않음

**수정 전**:
```swift
return [UsageEvent(
    provider: snapshot.provider,
    model: snapshot.model,
    timestamp: snapshot.updatedAt,
    inputTokens: snapshot.todayTokens,
    outputTokens: 0,
    requestCount: max(snapshot.dailyRequestsUsed ?? 0, 0),
    source: "snapshot-daily-total"
)]
```

**수정 후**:
```swift
// Synthetic fallback: no per-field breakdown available, total placed in inputTokens.
// Mark as estimated to distinguish from explicit adapter events.
return [UsageEvent(
    provider: snapshot.provider,
    model: snapshot.model,
    timestamp: snapshot.updatedAt,
    inputTokens: snapshot.todayTokens,
    outputTokens: 0,
    requestCount: max(snapshot.dailyRequestsUsed ?? 0, 0),
    source: "snapshot-daily-total",
    isEstimated: true
)]
```

**리스크**: Low. `isEstimated`는 이미 존재하는 필드이며, `UsageEvent.init`의 기본값은 `false`.

---

### M5. 스레드 안전성 확보 (LimitHistoryStore.swift, UsageHistoryStore.swift)

**파일**: `Sources/TokenCore/Services/LimitHistoryStore.swift`, `UsageHistoryStore.swift`
**심각도**: Medium — `@unchecked Sendable`이지만 잠금 없음으로 동시 write 시 데이터 손실 가능

**수정 내용**:
1. `import os` 추가
2. `OSAllocatedUnfairLock` 멤버 추가
3. `loadSamplesUnlocked()` / `saveUnlocked()` / `loadEventsUnlocked()` / `saveUnlocked()` — 잠금 없는 내부 메서드 분리
4. Public 메서드에서 `lock.withLock { ... }` 적용

**⚠️ 데드락 발견 및 해결**: 구현 중 `record()` 안에서 `loadSamples()`를 호출하는데, 둘 다 같은 lock을 acquire하려 해 교착 상태 발생. `OSAllocatedUnfairLock`은 비재entrant이므로, 잠금 없는 내부 메서드를 분리하여 해결.

**리스크**: Low. 현재 모든 호출자가 `@MainActor` 컨텍스트에서 접근하지만, 향후 백그라운드 refresh 시 데이터 레이스 방어.

---

### M6. `challengeTargetTokens` doc comment (TokenMonitorApp.swift)

**파일**: `Sources/TokenApp/TokenMonitorApp.swift:84`
**심각도**: Low

**수정**:
```swift
/// Daily token challenge target for the ChallengeCard gamification UI.
/// Not tied to any provider's actual quota limit; resets on app restart.
@Published var challengeTargetTokens = 10_000
```

---

### M7. `zh-Hant` future-proofing (TokenPilotLocalization.swift)

**파일**: `Sources/TokenCore/TokenPilotLocalization.swift:127`
**심각도**: Low

**수정**:
```swift
// TODO: Add zh-Hant support when Traditional Chinese translations are available
if preferred.hasPrefix("zh") { return .zhHans }
```

---

## 3. 잔존 Low 이슈 (향후 개선 대상)

| # | 파일 | 라인 | 이슈 | 우선순위 |
|---|---|---|---|---|
| L1 | DataSourceAdapters.swift | 1351 | `hashValue` 기반 dedup key — 재시작 시 불안정 | 낮음 |
| L2 | DataSourceAdapters.swift | 1329 | 모델 이름 하드코딩 `"gpt-5"` fallback | 낮음 |
| L3 | TokenPilotModels.swift | 687 | `webSummary` 항상 `"No webhook"` — placeholder | 낮음 |
| L4 | TokenPilotModels.swift | 217-219 | `isWebQuotaComparable` 항상 `true` — 필터 no-op | 낮음 |
| L5 | UsageExportService.swift | 10-16 | `DateFormatter` 매번 생성 — static/lazy 권장 | 낮음 |
| L6 | ProviderSelectionService.swift | 35-37 | `deselectAll()` 빈 메서드 | 낮음 |
| L7 | SecurityScopedBookmarks.swift | 61 | 북마크 실패 시 조용히 fallback | 낮음 |
| L8 | CodexStatusParser.swift | 13-16 | 정규식이 창당 1개 퍼센트만 캡처 | 낮음 |
| L9 | DataSourceAdapters.swift | 783 | URL 리터럴 수정 완료 (M2) | ✅ |

---

## 4. 빌드 검증 결과

| 게이트 | 결과 |
|---|---|
| `swift build` | ✅ PASS |
| `swift build -Xswiftc -warnings-as-errors` | ✅ PASS |
| `swift test` | ✅ 124 tests / 0 failures |

---

## 5. 변경된 파일 목록

| 파일 | 변경 유형 |
|---|---|
| `Sources/TokenCore/Services/DataSourceAdapters.swift` | `try!` → `try?`, URL force-unwrap 제거 |
| `Sources/TokenCore/Services/TokenPilotServices.swift` | AppleScript 이스케이프 개선 |
| `Sources/TokenCore/Services/LimitHistoryStore.swift` | 스레드 안전성 (lock + 내부 메서드 분리) |
| `Sources/TokenCore/Services/UsageHistoryStore.swift` | 스레드 안전성 + `isEstimated` 플래그 |
| `Sources/TokenApp/TokenMonitorApp.swift` | `challengeTargetTokens` doc comment |
| `Sources/TokenCore/TokenPilotLocalization.swift` | `zh-Hant` TODO |

---

## 6. 교훈 / 패턴

1. **`@unchecked Sendable` + OSAllocatedUnfairLock 사용 시**: public 메서드가 lock 안에서 또 다른 lock된 메서드를 호출하면 **데드락**. 반드시 잠금 없는 내부 메서드(`*Unlocked`)를 분리할 것.

2. **`try!`는 테스트에서만 허용**: 프로덕션 코드에서는 반드시 `try`/`try?` 사용. JSON 직렬화 같은 "절대 실패하지 않을 것 같은" 작업도 defensive coding 권장.

3. **문서-코드 동기화**: 코드 변경 시 관련 문서의 수치(테스트 수, 파일 수, 간격 등)도 함께 갱신 필요.
