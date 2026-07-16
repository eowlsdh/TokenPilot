# Developer ID Capacity Release Verification

**Status:** G005 release/forecast verification artifact. This document is for Developer ID/local release evidence only; it makes no App Store readiness claim.

## Forecast backtest gate

The capacity forecast gate is nonshipping. It must not add or enable production `QuotaForecastService`, forecast settings, forecast UI strings, alerts, or runtime forecast behavior before ADR approval.

Run the deterministic conformance/no-observed smoke without touching repository-local evidence:

```bash
swift build --product CapacityForecastBacktest -Xswiftc -warnings-as-errors
swift run CapacityForecastBacktest --fixtures Tests/Fixtures/CapacityForecast --observed /tmp/tokenpilot-capacity-empty/.gjc/evidence/forecast/local --output /tmp/tokenpilot-capacity-backtest.json
```

Expected smoke result:

- `syntheticConformanceCases` equals the checked-in fixture case count and every case passes.
- `observedFiles`, `observedLabeledCycles`, and `observedProfiles` are `0`.
- `gate.status` is `no-go` with reasons for absent observed cohort, fewer than 30 labeled observed cycles, fewer than 5 profiles, and unavailable threshold metrics.
- `/tmp/tokenpilot-capacity-backtest.json.sha256` exists and contains the SHA-256 of the canonical report.

Run the real ignored-cohort command only when voluntary observed files have been placed locally:

```bash
swift run CapacityForecastBacktest --fixtures Tests/Fixtures/CapacityForecast --observed .gjc/evidence/forecast/local --output .gjc/evidence/forecast/backtest-$(date -u +%Y%m%dT%H%M%SZ).json
```

The harness output is evidence for ADR review, not an automatic go decision. If thresholds pass, the report status is review-required; final forecast go still needs ADR record, aggregate hashes/profile count/confusion/metrics, synthetic conformance, and Architect/Critic approval. No-go retains the harness and fixtures only and creates no production forecast service/settings/strings.

### Observed cohort allowlist

Observed JSON files are allowed only under ignored `.gjc/evidence/forecast/local`. They may contain:

- `schema`, pseudonymous cycle `id`, and pre-hashed `profileHash`.
- `provider: "claude"`, `source: "providerReported"`, `stability: "supported"`, and fixed reset metadata.
- ISO-8601 `resetAt`, feature `observedAt`, `usedPercent`, optional `rateLimitReached`, outcome observations, and `hasNextCycle`.

They must not contain credentials, cookies, OAuth tokens, raw prompts, raw responses, local paths, provider auth files, model/status text, raw provider payloads, webhook URLs, chat IDs, or profile names. Reports may include fixture hashes, observed content hashes, aggregate counts, confusion matrix, metrics, and synthetic conformance only.

Delete local observed files and local backtest reports after ADR signoff. After deletion, audit is intentionally limited to retained aggregate hashes, report sidecar hashes, and redacted notes; do not preserve raw cohort payloads for audit convenience.

## Required release evidence table

For each row, record tester/date/status, redacted evidence, artifact SHA-256 where applicable, and any blocker. Status values are `complete`, `blocked`, or `failed`; blocked rows are not release evidence completion.

| Area | Command or action | Expected result |
|---|---|---|
| Package tool build | `swift build --product CapacityForecastBacktest -Xswiftc -warnings-as-errors` | Tool and TokenCore compile without warnings-as-errors failures. |
| Forecast conformance | `swift run CapacityForecastBacktest --fixtures Tests/Fixtures/CapacityForecast --observed .gjc/evidence/forecast/local --output .gjc/evidence/forecast/backtest-$(date -u +%Y%m%dT%H%M%SZ).json` | Synthetic conformance passes; observed metrics are separated; absent/insufficient observed cohort is no-go. |
| Unit tests | `swift test` and `make test` | Unsuppressed tests complete. |
| Strict build | `make build-strict` | Strict SwiftPM build completes. |
| Xcode generation parity | `xcodegen generate` then `git diff --exit-code -- TokenPilot.xcodeproj` | Generated project review is clean or explained before release. |
| Xcode build | `xcodebuild -project TokenPilot.xcodeproj -scheme TokenPilot -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | Unsigned Debug build succeeds. |
| Full local verification | `make verify` | Build-strict, tests, and bundle complete. |
| Secret scan | `make security-scan` | Gitleaks history/worktree scans complete without broad allowlists. |
| Code signature identity | `codesign -dv --verbose=4 build/TokenPilot.app` | Developer ID identity, Team ID, runtime, and bundle identity match the release record. |
| Entitlements | `codesign -d --entitlements :- build/TokenPilot.app` | Developer ID/local build is unsandboxed with the expected entitlement file; no sandbox claim is made. |
| Gatekeeper assessment | `spctl --assess --type execute --verbose=4 build/TokenPilot.app` | Assessment accepts the signed artifact. |
| Staple validation | `xcrun stapler validate build/TokenPilot.app` | Stapled/notarized artifact validates when notarization is part of the approved release run. |

## Live fixture QA matrix

Use the actual executable product `TokenMonitor` for SwiftPM fixture runs, not stale screenshots or source-only previews. Every DEBUG fixture launch uses exactly these five environment variables before the command, in this order:

```bash
TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=<scenario> TOKENPILOT_DEBUG_SCREEN=<overview|history|settings> TOKENPILOT_DEBUG_LANGUAGE=<en|ko|ja|zh-Hans> TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=<standard|reduceMotion|reduceTransparency|increaseContrast> swift run TokenMonitor
```

The Xcode `TokenPilot` app target alternative uses the same five environment variables under **Edit Scheme → Run → Arguments → Environment Variables**. Unsupported screen/language/profile values fall back to `overview`/`en`/`standard`; unsupported scenarios fall back to `empty`. These controls are DEBUG and UI-testing gated only, apply app-owned optional SwiftUI environment override keys to the real production `TokenPilotRootView`, and must not be used as production data evidence. macOS accessibility settings are never changed by automation: do not open System Settings, run system preference/defaults commands, or persist accessibility preferences for automated QA.

### Evidence manifest

Store local redesign QA evidence under ignored `.gjc/evidence/redesign/`. Do not commit screenshots, transcripts, raw accessibility output, or local manifest files. The manifest schema for `.gjc/evidence/redesign/manifest.json` matches the actual QA artifact:

```json
{
  "schema": "tokenpilot.redesign.qa.manifest.v1",
  "artifactBuildSHA": "3bd3358d152eba2f96462079b4733c2e798ac03a+dirty-8300747ae3cd7724",
  "generatedAt": "2026-07-16T12:22:26.849270+00:00",
  "counts": {
    "baseline": 36,
    "locale": 60,
    "accessibility": 45,
    "rows": 141,
    "uniqueScreenshots": 126
  },
  "rows": [
    {
      "schema": "tokenpilot.redesign.qa.manifest.v1",
      "artifactBuildSHA": "3bd3358d152eba2f96462079b4733c2e798ac03a+dirty-8300747ae3cd7724",
      "productTarget": "TokenMonitor",
      "scenario": "empty",
      "screen": "overview",
      "locale": "en",
      "accessibilityProfile": "standard",
      "matrix": "baseline",
      "windowDimensions": { "width": 420, "height": 620 },
      "screenshotPath": ".gjc/evidence/redesign/screenshots/standard__en__empty__overview.png",
      "screenshotSHA256": "859b09021d06c58efc1859ee0bc55f8e58d130e7719523cb951152eb0b3e1d93",
      "transcriptPath": ".gjc/evidence/redesign/transcripts/standard__en__empty__overview.txt",
      "transcriptSHA256": "17c65978872fbfc0acc669facea2cf5ffe34f991bcf1d54d76ee890d4015ce36",
      "tester": "GJC native automation",
      "capturedAt": "2026-07-16T12:20:40.938199+00:00",
      "status": "pass",
      "blockedReason": null
    }
  ]
}
```

Required top-level fields are `schema`, `artifactBuildSHA`, `generatedAt`, `counts`, and `rows`. Required row fields are `schema`, `artifactBuildSHA`, `productTarget`, `scenario`, `screen`, `locale`, `accessibilityProfile`, `matrix`, `windowDimensions`, `screenshotPath`, `screenshotSHA256`, `transcriptPath`, `transcriptSHA256`, `tester`, `capturedAt`, `status`, and `blockedReason`. Each passing row must attach a current-build popover screenshot and popover transcript hash; blocked rows must set `blockedReason` and never count as passing release evidence.

The release gate requires exact manifest counts (`baseline: 36`, `locale: 60`, `accessibility: 45`, `rows: 141`, `uniqueScreenshots: 126`), 420×620 `windowDimensions` on every row, no placeholder build IDs/hashes/paths, screenshot coverage >=99/100, transcript coverage >=99/100, and evidence scoring >=99/100. Any placeholder value, missing current-build artifact hash, blocked row, failed row, or score/coverage below 99 is a release blocker.

### Baseline scenario/screen matrix — 36 rows

Run all twelve approved scenarios on all three screens (`overview`, `history`, `settings`) in English at the standard app-scoped accessibility profile: 12 scenarios × 3 screens = 36 rows. Use the command shape below, changing `TOKENPILOT_DEBUG_SCREEN` for the two additional screen rows and keeping `TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard`:

| Scenario | Baseline overview command | Required evidence focus |
|---|---|---|
| `empty` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=empty TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Empty-state hierarchy, setup action, no mock/live claims. |
| `claudeOfficialFresh` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=claudeOfficialFresh TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Fresh official Claude capacity, remaining percentage, reset context. |
| `claudeOfficialStale` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=claudeOfficialStale TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Stale source labeling and suppressed alert eligibility. |
| `codexLocalOnly` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=codexLocalOnly TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Local activity is not web quota and has no deliverable alert. |
| `codexConnectorExperimental` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=codexConnectorExperimental TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Experimental transport badge and `100 - used` remaining percentage. |
| `codexManual` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=codexManual TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Manual estimate labeling and alert ineligibility. |
| `deepseekOfficialBalance` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=deepseekOfficialBalance TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Official 3.34 USD balance, 5.00 USD bound threshold, and eligible low-balance rule. |
| `deepseekManualBalance` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=deepseekManualBalance TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Manual balance remains non-official and alert-ineligible. |
| `antigravityBridge` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=antigravityBridge TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Compatibility bridge wording and unsupported alert state. |
| `runtimeRecoveryRequired` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=runtimeRecoveryRequired TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Recovery guidance, write blocking, and fail-closed delivery. |
| `alertsUnsupportedCodexLegacy` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=alertsUnsupportedCodexLegacy TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | Legacy Codex rules render read-only unsupported and never deliver. |
| `alertsPendingDeepSeekCurrency` | `TOKENPILOT_UI_TESTING=1 TOKENPILOT_DEBUG_SCENARIO=alertsPendingDeepSeekCurrency TOKENPILOT_DEBUG_SCREEN=overview TOKENPILOT_DEBUG_LANGUAGE=en TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE=standard swift run TokenMonitor` | DeepSeek alert remains pending until official currency binding. |

### Locale sentinel matrix — 60 rows

Locale review covers the five canonical scenarios `claudeOfficialFresh`, `deepseekOfficialBalance`, `codexManual`, `claudeOfficialStale`, and `runtimeRecoveryRequired` across the three screens and four locales at the `standard` app-scoped accessibility profile: 5 scenarios × 3 screens × 4 locales = 60 manifest rows. The matching 15 baseline EN artifacts may be reused by hash, so unique screenshot count remains 126 rather than 141. Record KO/EN/JA/zh-Hans overflow, truncation, line wrapping, and untranslated sentinel copy.

### Accessibility matrix — 45 captured rows

Accessibility review covers the same five canonical scenarios and three screens with four app-scoped profiles: `standard`, `reduceMotion`, `reduceTransparency`, and `increaseContrast`. That is 60 logical checks; reuse the 15 matching standard-profile rows already captured in the baseline/locale evidence, and capture the remaining 45 non-standard rows with `TOKENPILOT_DEBUG_ACCESSIBILITY_PROFILE` set to the selected profile. The transcript must cover keyboard navigation and VoiceOver order for each profile. Reduced Motion, Reduce Transparency, and High Contrast rows must record the app-owned profile value in `accessibilityProfile`, not any active macOS setting.
The approved scenario set is the twelve rows above. Update this matrix and its documentation guard tests in the same change whenever the DEBUG fixture scenario set changes.

For each scenario and launch path, attach a current-build popover screenshot and popover transcript. The screenshot must exercise the 420×620 popover size and record any clipping/truncation instead of cropping it away. If Screen Recording, Accessibility, notification, network, Keychain, or other macOS permission state prevents the check, record the row as `blocked` with the permission and missing evidence; permission-blocked results must be recorded as blocked—not pass. A blocked row never satisfies the release gate until rerun with evidence.
Automation must not mutate macOS settings to create these rows. The manual final spot-check remains optional and user-controlled; if performed, the tester controls any macOS accessibility setting changes and restores them outside automation.

## Developer ID posture

The Developer ID/local artifact uses the intentionally empty `Resources/TokenPilot.entitlements` posture so local usage-file discovery and local CLI/process integration continue to work. This is unsandboxed. Do not describe the artifact as sandboxed or App Store-ready. A future sandboxed distribution must switch deliberately to `Resources/TokenPilot-AppStore.entitlements` and re-verify source selection, security-scoped bookmarks, notifications, and Codex connector behavior.

Canary release, if approved, is five internal Developer ID users for 14 days with no telemetry. Evidence is voluntary, redacted, and local. Stop rollout for unrecoverable data loss, secret/path/prompt exposure, ineligible alert, entitlement mismatch, P1 defect, or forecast false positive.

## Rollback, runtime disable, and corruption recovery

- Runtime disable: turn off optional external notifications and optional provider connectors before replacing the app; keep forecast code/settings absent unless ADR go has already occurred.
- Rollback: record failing build number and exact gate, keep the failed artifact local unless it was already distributed, install the prior signed Developer ID build, and verify existing usage/export data remains readable.
- Downgrade: preserve named app data; do not delete stores to make downgrade appear clean.
- Corruption recovery: corrupt primary/backup data must fail closed, preserve forensic bytes, and avoid automatic overwrite. Restore only from a known valid backup or the prior signed build after recording the failure.

## Codex process checks

Before Developer ID release, verify the Codex limit-hints process path remains opt-in and redacted:

- Resolve configured absolute executable first, otherwise an absolute `PATH` candidate; accept only canonical symlink or regular executable files.
- Inherit only `HOME`, `PATH`, `LANG`, and `LC_CTYPE`.
- Send JSONL initialize without `jsonrpc`, wait for the matching response, send initialized notification, then read rate-limit hints.
- Enforce 8s timeout, 1MiB stdout/stderr caps, and 256KiB line cap.
- On failure, cancel, cap, malformed output, or timeout: close stdin, send TERM, wait 250ms, then KILL; discard bytes and return a typed redacted error.

## Locale and accessibility checklist

Check EN, KO, JA, and zh-Hans manually with redacted screenshots only:

- Critical trust, manual, stale, privacy, notification, export, and no-source copy match final behavior.
- VoiceOver order is app/status, remaining, reset, authority/stability, freshness, forecast/unavailable, action.
- Keyboard navigation reaches all controls without pointer-only actions.
- Non-color indicators exist for risk/stale/manual states.
- Text contrast is at least 4.5:1 for required content.
- Reduce Motion removes nonessential motion without hiding state changes.
- Screenshots and notes contain no private paths, prompts, payloads, credentials, chat IDs, or webhook URLs.
