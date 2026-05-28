# TokenPilot Autopilot Closeout Report

**Generated:** 2026-05-22 23:06:01 KST  
**Project path:** `/Volumes/OWC_1M2/daejinyoun/Workspace/project/mac_token_c`  
**Profile roles requested:** `dev`, `default`, `main`, `content`, `research`  
**External side effects:** none — no git push, deploy, public publish, live Telegram/Discord send, OAuth/API-key use, purchase, external release, or real Codex account call.

---

## 1. Executive verdict

**Local autopilot completion gate: PASS with release caveats.**

TokenPilot is now a stronger **local MVP / internal daily-use candidate**. This pass completed the Codex app-server limit-hints connector hardening, localization/catalog alignment, automated verification, app bundle smoke, secret scan, and independent lane review requested by the user.

Current source-of-truth shape:

- App display name: `TokenPilot`
- SwiftPM executable target: `TokenMonitor`
- Xcode scheme: `TokenPilot`
- Local app bundle: `build/TokenPilot.app`
- Bundle ID: `com.tokenpilot.macos`
- Menu bar app mode: `LSUIElement=true`
- Menu bar lightweight tick: about 1 second
- Provider data refresh throttle: 5 seconds
- Data stance: local-first, usage metadata only, no browser cookies, no arbitrary Keychain browsing
- Codex stance: app-server limit hints are opt-in beta/default-off and unofficial; local/manual values remain hints, not official quota guarantees

**Not a public release approval:** human visual QA, real Codex-account connector checks, notarization/signing/distribution, sandbox/privacy review, and external notification sends remain approval-gated.

---

## 2. dev result — implementation and hardening applied

| Area | Result |
|---|---|
| Codex app-server connector | `CodexWebUsageAdapter` now defaults to local `codex app-server` JSON-RPC and sends `initialize` before `account/rateLimits/read`. |
| JSON-RPC compatibility | Request payloads now include `jsonrpc: "2.0"` for both initialize and rate-limit read requests. |
| Privacy posture | Default path does not read Codex auth files or direct web endpoints. Legacy direct HTTP/auth-file compatibility is disabled unless explicitly allowed in tests. |
| Error redaction | App-server error details redact bearer/token/secret-like substrings before status messages can surface or be exported. |
| Fallback behavior | App-server auth-required/RPC failure returns low-confidence guidance and does not silently fall back to direct HTTP. |
| Localization | Codex limit-hints keys were added/updated in `Localizable.xcstrings` for ko/en/zh-Hans/ja to reduce fallback drift. |
| Documentation | Codex verification, general verification, README, visual QA, and closeout docs were aligned around app-server/default-off/privacy-safe wording. |
| Regression tests | Added/updated coverage for JSON-RPC payload order, app-server redaction, and direct HTTP disabled-by-default. Current suite: 124 tests. |

Key files touched or verified in this pass:

- `Sources/TokenCore/Services/DataSourceAdapters.swift`
- `Sources/TokenCore/TokenPilotLocalization.swift`
- `Sources/TokenApp/Resources/Localizable.xcstrings`
- `Tests/TokenPilotServicesTests.swift`
- `Tests/TokenMonitorTests.swift`
- `README.md`
- `CODEX_VERIFICATION_REPORT.md`
- `VERIFICATION_REPORT.md`
- `SETTINGS_GUIDE.md`
- `APP_LAUNCH_GUIDE.md`
- `docs/TokenPilot-visual-qa-checklist.md`
- `docs/TokenPilot-autopilot-closeout-report.md`
- `docs/TokenPilot-autopilot-closeout-report.html`

Project caveat: `/Volumes/OWC_1M2/daejinyoun/Workspace/project/mac_token_c` is currently **not a git repository**, so git diff/commit/branch verification was not available and no commit/push was attempted.

---

## 3. default result — automated verification

Latest local verification status after the Codex hardening pass:

| Check | Status | Evidence |
|---|---:|---|
| Build script syntax | PASS | `bash -n build.sh` |
| SwiftPM build | PASS | `swift build` |
| Strict compiler lint substitute | PASS | `swift build -Xswiftc -warnings-as-errors` |
| Swift tests | PASS | `swift test`: 92 tests, 0 failures |
| Xcode project generation | PASS | `xcodegen generate` |
| Xcode Debug build | PASS | `xcodebuild -project TokenPilot.xcodeproj -scheme TokenPilot -configuration Debug CODE_SIGNING_ALLOWED=NO build` |
| App packaging | PASS | `./build.sh` produced `build/TokenPilot.app` and ad-hoc signed it |
| Plist identity smoke | PASS | `CFBundleIdentifier=com.tokenpilot.macos`, display name `TokenPilot`, `LSUIElement=true`, executable `TokenMonitor` |
| Launch smoke | PASS | `build/TokenPilot.app/Contents/MacOS/TokenMonitor` ran for more than 12 seconds under isolated temporary `HOME`/`CODEX_HOME`, then was terminated and cleaned up |
| Process cleanup | PASS | no remaining `TokenMonitor`/`TokenPilot` process after smoke |
| Static secret assignment scan | PASS | 0 real secret candidates; one redacted/test fixture candidate only |

Xcode note: the generated schemes are `TokenCore` and `TokenPilot`. `TokenMonitor` is the executable name, not the Xcode scheme.

---

## 4. Independent lane review

| Lane | Verdict | Notes |
|---|---:|---|
| `dev` | PASS | app-server-first implementation, JSON-RPC request order, no silent HTTP fallback, parser tolerance, and tests are aligned. |
| `default` | PASS | build/test/warnings/Xcode/bundle smoke/secret scan pass. Git traceability remains unavailable because this path is not a git repository. |
| `main` | PASS with WARN | menu-bar utility shape and compact `5h · W` direction are aligned. Full visual QA for clipping, menu-bar jitter, and dense Codex Settings remains manual. |
| `content` | PASS | public-facing copy now frames Codex as opt-in beta limit hints, not official quota. Internal legacy wording is not exposed in Korean privacy copy. |
| `research` | PASS with WARN | internal daily-use value is clear for heavy AI coding-tool users; paid/public launch is still HOLD until real-account QA, privacy review, notarization/signing, and human visual QA. |

Independent review warnings resolved in this pass:

1. App-server error detail now redacts secret-like strings.
2. Legacy direct HTTP/auth-file path is now disabled by default and requires explicit compatibility/test opt-in.
3. JSON-RPC request payloads now include `jsonrpc: "2.0"`.
4. Codex limit-hints localization keys were added to `Localizable.xcstrings`.
5. Verification/closeout docs were updated from 90 to 124 tests and from direct-token wording to app-server-first wording.

---

## 5. Remaining release caveats

The app is acceptable as a **local/internal MVP candidate**, but these remain before public or paid release:

1. Manual visual QA on a real macOS menu bar: clipping, popover density, hover/focus, multi-language layout.
2. Real Codex account QA by the user without exposing tokens in chat/logs.
3. Privacy/security review for sandboxing, security-scoped bookmarks, Keychain handling, and export content.
4. Developer ID signing, notarization, distribution channel, update mechanism.
5. External notification live-send QA only with explicit approval and user-provided safe test targets.
6. Git/release traceability if the project is moved into or attached to an actual repository.

---

## 6. Safety boundary retained

Not performed:

- git commit/push
- deploy/public publish
- real Codex credential/API/OAuth use
- live Telegram/Discord sends
- purchase/subscription/payment
- Developer ID signing/notarization/App Store distribution
- destructive filesystem or database operations

Final local verdict: **PASS for internal/local MVP continuation; HOLD for public/paid release.**
