# App Store readiness: sandbox source grants

**Date:** 2026-08-20

**Scope:** The one finding that would have made a Mac App Store build non-functional, plus the
build path needed to test that configuration locally.

## The problem

`Resources/TokenPilot-AppStore.entitlements` declares App Sandbox with
`files.user-selected.read-only` and `network.client`, but it was wired into **no build**:
`project.yml` signs with `Resources/TokenPilot.entitlements` (an empty dict, i.e. no sandbox) and
`build.sh` passed no `--entitlements` at all.

That mattered because seven providers read fixed home-relative paths — `~/.claude/projects`,
`~/.codex`, `~/.local/share/opencode`, `~/.kiro`, `~/.commandcode`, `~/.grok`,
`~/Library/Application Support/JetBrains`. Under App Sandbox none of them are readable unless the
user selected them, so a submitted build would have installed cleanly, launched cleanly, and then
reported "folder not found" for nearly every provider — a monitoring app monitoring nothing.

Only Claude's statusline file and the Antigravity telemetry source had a picker and a
security-scoped bookmark; every other provider had no way to be granted access at all.

## What changed

1. **Per-provider grants.** `MonitoredProviderSettings` already carried `customPaths`; it now also
   carries `customBookmarks: [Provider: Data]`, a read-only security-scoped bookmark per provider,
   encoded and decoded alongside the paths.
2. **One resolver.** `ProviderSourceAccess.resolve(provider:settings:defaults:)`
   (`Sources/TokenCore/Services/ProviderSourceAccess.swift`) returns the roots an adapter may read
   plus the scoped accesses to release afterwards. Outside the sandbox it passes the default paths
   through unchanged; inside it returns the granted folder, or `needsUserGrant` when there is none —
   it never hands back a default path the process cannot read. Sandbox detection fails closed.
3. **Adapters route through it**: Claude projects fallback, Codex, opencode, Kiro, Command Code, Grok, and JetBrains now
   resolve their roots this way and release access when the read finishes. An ungranted sandboxed
   build reports "Choose the … folder to grant access" instead of "not found".
4. **Settings UI**: each file-backed provider gained a **Choose Folder** row showing the granted
   folder name (never the path) with a Reset action. The caption adapts: in a sandboxed build it
   explains that only granted folders are readable; otherwise it says the grant is only needed for a
   non-default install location.
5. **Buildable App Store configuration**: `build.sh` takes `TOKENPILOT_ENTITLEMENTS`, defaulting to
   the Developer ID entitlements, so the sandboxed configuration can be built and run locally:

   ```bash
   TOKENPILOT_ENTITLEMENTS="$PWD/Resources/TokenPilot-AppStore.entitlements" ./build.sh
   ```

## Verification

- Sandboxed configuration built, signed, and launched: `codesign -d --entitlements :-` shows
  app-sandbox, user-selected read-only, and network client; macOS created
  `~/Library/Containers/com.tokenpilot.macos`, confirming the sandbox is active; no crash report was
  produced for the run.
- Developer ID configuration rebuilt and relaunched afterwards; it still reads the default paths and
  refreshes normally.
- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: 709 tests, 0 failures (701 before this work).
- New `ProviderSourceAccessTests`: default paths preserved unsandboxed, sandboxed-without-grant
  returns no roots and asks for a grant, a granted folder wins over defaults, a real bookmark
  resolves and satisfies a sandboxed build, grants survive a settings round trip, the adapter reports
  the grant state, and the grant strings are translated in all four non-English locales.

## Already fine for review (re-checked)

- `PrivacyInfo.xcprivacy` declares exactly the required-reason APIs the code uses: UserDefaults
  (CA92.1) and file timestamp (C617.1). No disk-space or active-keyboard API is used. No collected
  data types, no tracking.
- `Info.plist`: `LSUIElement`, utilities category, copyright, versions from the build settings.
- No credential store is read without explicit consent, and the consent-gated probes are off by
  default — relevant to App Review's data-access questions.

## Follow-up completed the same day

- **All seven file-backed providers** now resolve through `ProviderSourceAccess`: Claude's `projects`
  fallback, Codex, opencode, Kiro, Command Code, Grok local signals, and the JetBrains quota cache.
  JetBrains additionally discovers its per-IDE `options/AIAssistantQuotaManager2.xml` underneath a
  granted parent folder. A test asserts every one of them has a grant row in Settings, so a new
  provider cannot ship ungrantable.
- **Review notes drafted** in `docs/app-store-review-notes.md`: why the app asks for folders, which
  folders a tester would grant, how to see the UI without installing an assistant, what is never
  read, and the App Privacy answers.

## Still open before an actual submission

- **Screenshots** from the sandboxed build, and the store description text.
- A sandboxed run leaves `~/Library/Containers/com.tokenpilot.macos` behind; the one created while
  testing was left in place because removing it is the user's call.
