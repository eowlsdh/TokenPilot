# Security Policy

TokenPilot is a local-first macOS utility for AI tool usage metadata. Security reports are welcome.

## Reporting a Vulnerability

Please use GitHub Security Advisories for private reports when available. If advisories are unavailable, contact the repository maintainer through their GitHub profile and avoid posting exploit details in public issues.

Do not include real API keys, OAuth tokens, browser cookies, session files, private prompts, or provider credential files in a report. Redacted logs, reproduction steps, and affected versions are enough.

## Credential Handling Policy

TokenPilot should not read, display, log, export, or store provider access tokens, browser cookies, raw prompts, raw model responses, or arbitrary Keychain items.

Optional Telegram and Discord notification secrets are stored only in TokenPilot-owned Keychain items. They are off by default and are used only when the user explicitly enables those notification channels.

Codex values are intentionally conservative:

- Local Codex activity is experimental local activity, not official web quota.
- Codex Limit Hints Connector is opt-in and asks the local Codex CLI app-server for limit hints.
- Manual Codex values are user-entered estimates.

## Supported Versions

Public releases will document supported versions in GitHub Releases. Until the first tagged release, security fixes apply to the default branch only.
