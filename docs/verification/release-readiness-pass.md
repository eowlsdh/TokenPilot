# Release readiness: one version, one language

**Date:** 2026-08-20

The remaining pre-submission work, minus the screenshots, which cannot be produced from here.

## 1. The version existed in two places

`project.yml` declared `MARKETING_VERSION: 1.0.0` and `CURRENT_PROJECT_VERSION: 1`; `build.sh` wrote
`CFBundleShortVersionString` and `CFBundleVersion` as literals. They agreed today and would not have
agreed for long — and the failure mode is nasty: the bundle `build.sh` produces and the one Xcode
produces would claim to be different builds, and an App Store build number that silently goes
backwards is rejected at upload, by which point the mismatch is invisible.

`build.sh` now reads both settings out of `project.yml` and **fails the build** if either is missing.
A quiet default would have recreated exactly the drift the read removes.

The version itself stays at **1.0.0 (1)**. Nothing has shipped, so that is the correct first
submission value; bumping to 1.0.1 would claim a released 1.0.0 that does not exist.

## 2. Most status messages reached non-English users in English

Provider status messages are the sentence someone reads when a provider is not behaving — in the
Overview row and in the Setup Guide. A sweep of the adapters found **64 of them, of which 42 had no
translation entry at all**. That is the worst possible moment to switch languages on a reader.

All of them are now translated across en/ko/ja/zh-Hans/zh-Hant, in both the Swift fallback table and
the string catalog — except two that are bare product names (`MiniMax Token Plan`, `OpenCode Bar`),
which the guard exempts explicitly rather than silently. Two details worth recording:

- **The uppercase markers stay as they are.** `MOCK`, `STALE`, `EXPERIMENTAL`, `UNOFFICIAL`, `LOCAL`,
  `est.` are deliberate language-neutral flags, like the menu bar's E/M/S suffixes. Translating them
  would soften precisely the labels that exist to stop sample or unofficial data being mistaken for
  real quota. Only the description after the marker moves.
- **`Connect Claude statusline` was Korean-only.** It lived in `koreanFallback`, so Japanese and both
  Chinese locales saw the raw English key. It is now in the five-language table.

### The guard is a sweep, not a list

`Tests/StatusMessageLocalizationTests` walks `Sources/` for `statusMessage` literals and asserts each
one resolves to something other than itself. That matters: the hand survey that started this pass
found 35, and the sweep immediately found 7 more the survey's regex had missed. A hand-maintained
list would have shipped those. A new status message can no longer be added without a translation.

A third test asserts the honesty markers survive translation in every language, so the guard cannot
be satisfied by softening a warning.

## 3. Listing copy

`docs/app-store-listing.md` holds name, subtitle, promotional text, description, keywords, and the
first-release "What's New", with every length checked against Apple's limits (subtitle 25/30,
promotional 157/170, keywords 82/100). Claims were checked against the code: 12 providers, 5
languages.

It also records what the copy deliberately does **not** claim — no "official quota" for
activity-only providers, Grok's local reading described as context window rather than subscription
quota, and no affiliation with any provider.

`docs/app-store-review-notes.md`'s pre-submission checklist now points at `project.yml` as the single
place to change the version, and at the listing doc.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `./build.sh` signed; the produced bundle reports
  `CFBundleShortVersionString 1.0.0` / `CFBundleVersion 1`, read from the spec.
- `swift test`: **766 tests, 0 failures** (761 before this pass).
- New: the status-message sweep (3 tests) and two build-script guards — that the version is read
  rather than restated, and that the spec declares both settings.

## Still open, and needs the user

- **Screenshots.** The popover has to be opened by hand and screen capture needs permission this
  environment does not have. `docs/app-store-listing.md` specifies the five shots, the build to take
  them from, and what to crop out.
