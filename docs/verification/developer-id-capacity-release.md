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

For each row, record tester/date/pass-fail, redacted evidence, and artifact SHA-256 where applicable.

| Area | Command or action | Expected result |
|---|---|---|
| Package tool build | `swift build --product CapacityForecastBacktest -Xswiftc -warnings-as-errors` | Tool and TokenCore compile without warnings-as-errors failures. |
| Forecast conformance | `swift run CapacityForecastBacktest --fixtures Tests/Fixtures/CapacityForecast --observed .gjc/evidence/forecast/local --output .gjc/evidence/forecast/backtest-$(date -u +%Y%m%dT%H%M%SZ).json` | Synthetic conformance passes; observed metrics are separated; absent/insufficient observed cohort is no-go. |
| Unit tests | `swift test` and `make test` | Unsuppressed tests pass. |
| Strict build | `make build-strict` | Strict SwiftPM build passes. |
| Xcode generation parity | `xcodegen generate` then `git diff --exit-code -- TokenPilot.xcodeproj` | Generated project review is clean or explained before release. |
| Xcode build | `xcodebuild -project TokenPilot.xcodeproj -scheme TokenPilot -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` | Unsigned Debug build succeeds. |
| Full local verification | `make verify` | Build-strict, tests, and bundle pass. |
| Secret scan | `make security-scan` | Gitleaks history/worktree scans pass without broad allowlists. |
| Code signature identity | `codesign -dv --verbose=4 build/TokenPilot.app` | Developer ID identity, Team ID, runtime, and bundle identity match the release record. |
| Entitlements | `codesign -d --entitlements :- build/TokenPilot.app` | Developer ID/local build is unsandboxed with the expected entitlement file; no sandbox claim is made. |
| Gatekeeper assessment | `spctl --assess --type execute --verbose=4 build/TokenPilot.app` | Assessment accepts the signed artifact. |
| Staple validation | `xcrun stapler validate build/TokenPilot.app` | Stapled/notarized artifact validates when notarization is part of the approved release run. |

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
