# TokenPilot Release Notes Template

**Status:** public release checklist template

---

## Versioning policy draft

- Marketing version: start at `1.0.0` when the first commercial candidate is ready.
- Build number: start at `1`, increment for every submitted archive/TestFlight build.
- Do not reuse a build number once uploaded.
- Local unsigned builds may remain development-only and must not be described as App Store-ready.

---

## v1.0.0 release notes draft

TokenPilot is a local-first macOS menu bar utility for monitoring AI coding-tool usage metadata.

Initial release candidate includes:

- Compact menu bar glance for supported provider usage pressure.
- Overview cards for Claude Code, Codex, and Gemini CLI usage signals.
- History view with local usage summaries.
- Settings for data sources, alerts, language, and privacy.
- Optional sample preview data, off by default.
- Conservative Codex limit hints/manual estimates, clearly labeled.
- App privacy manifest and icon resources prepared.
- User-selected Claude/Gemini source bookmarks for sandbox-readiness.

Known limitations:

- TokenPilot is not an official provider billing or quota authority.
- Codex local/manual values are hints, not guaranteed official web quota.
- Provider CLI log formats may change.
- External alerts require explicit user setup and are off by default.

---

## Pre-release QA checklist

- [ ] `swift build`
- [ ] `swift build -Xswiftc -warnings-as-errors`
- [ ] `swift test`
- [ ] `xcodegen generate`
- [ ] unsigned Xcode Debug build
- [ ] `make bundle`
- [ ] manual bundle resource smoke
- [ ] launch smoke with isolated HOME
- [ ] menu bar numbers, Overview rows, and Settings privacy copy checked manually
- [ ] screenshots contain no private paths/secrets
- [ ] privacy/security docs and release notes match final behavior
- [ ] signing/notarization/TestFlight only after explicit approval

---

## Rollback notes template

If a release candidate fails:

- Record failing build number and exact gate.
- Keep failed archive local unless upload already happened.
- Do not overwrite release notes with optimistic language.
- Rebuild only after the failing gate has a test or documented manual QA step.
