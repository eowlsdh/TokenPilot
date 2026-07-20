# Security Policy

TokenPilot is a local-first macOS utility for AI tool usage metadata. Security reports are welcome.

## Reporting a Vulnerability

Please use GitHub Security Advisories for private reports when available. If advisories are unavailable, contact the repository maintainer through their GitHub profile and avoid posting exploit details in public issues.

Do not include real API keys, OAuth tokens, browser cookies, session files, private prompts, or provider credential files in a report. Redacted logs, reproduction steps, and affected versions are enough.

## Credential Handling Policy

TokenPilot should not read browser cookies, store raw prompts or raw model responses, access arbitrary Keychain items, or display provider access tokens or API keys. Explicitly configured TokenPilot-owned secrets must stay in their own Keychain items and remain hidden after save. Provider credential files are not read by default. The only intentional exception is the separate default-off EXPERIMENTAL/UNOFFICIAL Grok OAuth weekly feature: after explicit consent it may read only the selected access token and expiry from the fixed path `~/.grok/auth.json` for one fixed weekly billing request, keep that token memory-only, and never display, log, store, diagnose, or export it.

Optional Telegram and Discord notification secrets are stored only in TokenPilot-owned Keychain items. They are off by default and are used only when the user explicitly enables those notification channels.

Telegram Bot API endpoints include the bot token in the URL path by design. TokenPilot must not log, export, persist, proxy-debug, or surface full Telegram request URLs. Error messages should stay generic and should not include request URLs or token values.
Grok Build local context metadata is limited to remaining-context information in files named `signals.json` below `~/.grok/sessions/`. TokenPilot rejects symlinks, reads no more than 120 files per scan, and rejects any file larger than 256 KiB. It parses only numeric context fields; it does not ingest prompts, responses, credentials, or other session content. This local context metadata is not provider quota, subscription quota, or API billing data and must not be presented as comparable to those values. The local-context feature never reads `~/.grok/auth.json` or other Grok credential files.
A separate default-off EXPERIMENTAL/UNOFFICIAL OAuth weekly feature may, only after explicit consent, read the selected access token and expiry from fixed `~/.grok/auth.json`, perform one fixed weekly billing request, keep the token memory-only, and never display, log, store, diagnose, or export it. Manual weekly truth has precedence over experimental OAuth presentation.

Gemini ingestion accepts only the exact filenames `antigravity-statusline.json` and `telemetry.log`; chat/session JSON is rejected before reading. The same credential, export, and error-reporting boundaries apply to all provider metadata.

Codex values are intentionally conservative:

- Local Codex activity is experimental local activity, not official web quota; exports label eligible local activity separately and exclude local experimental/non-comparable Codex events.
- Codex Limit Hints Connector is opt-in and asks the local Codex CLI app-server for limit hints.
- Manual Codex values are user-entered estimates.

Capacity forecast backtest evidence is a nonshipping release gate. Observed cohort files are allowed only in ignored local evidence storage (`.gjc/evidence/forecast/local`) and must contain only the documented allowlist: hashed profile identifiers, pseudonymous cycle identifiers, Claude fixed-reset timestamps, used-percent observations, rate-limit booleans, source/stability/reset metadata, and next-cycle labels. Do not include credentials, browser cookies, OAuth tokens, raw prompts, raw responses, model text, status payloads, local source paths, webhook URLs, or provider auth files.

Backtest reports may record fixture hashes, observed cohort content hashes, aggregate counts, confusion matrices, threshold metrics, and synthetic conformance results. They must not serialize observed raw payloads or profile names. Delete local observed cohort files and local backtest evidence after ADR signoff; after deletion, auditability is intentionally limited to retained aggregate hashes, sidecar hashes, and redacted review notes.

## Secret Scanning

Run gitleaks with the repository configuration before public release or CI enforcement:

```bash
make security-scan
```

The target runs the same repository configuration as:

```bash
gitleaks detect --source . --redact --no-banner
gitleaks dir . --redact --no-banner
```

The checked-in `.gitleaks.toml` keeps the default gitleaks rules and allowlists one historical false positive in `COMPLETION_REPORT.md`. Do not use broad regex allowlists for new findings; inspect and fix real secrets first.

## macOS Sandbox Posture

The Developer ID/local build uses `Resources/TokenPilot.entitlements`, which is intentionally empty today because TokenPilot still depends on local usage-file discovery and local CLI/process integration. This is an unsandboxed Developer ID posture, not an App Store readiness claim. Enabling App Sandbox on that path without a migration can break existing source detection.

For any future sandboxed distribution, start from `Resources/TokenPilot-AppStore.entitlements`: App Sandbox on, read-only user-selected file access, and outbound network client access for explicitly enabled integrations. Validate source selection, security-scoped bookmarks, notifications, and Codex connector behavior before switching `CODE_SIGN_ENTITLEMENTS` to that file.

## Supported Versions

Public releases will document supported versions in GitHub Releases. Until the first tagged release, security fixes apply to the default branch only.
