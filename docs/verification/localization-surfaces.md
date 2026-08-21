# Localization: one app, two surfaces, three defects

**Date:** 2026-08-21

Sweeping the axes that were not the alerting pass, the five shipped languages were the one headline
feature never measured. Counting them found that the string catalog the shipped app carries could
not be read from it, that the two builds of this app localized differently, and that Traditional
Chinese was a fifth of the size of the other four.

## What was measured

TokenPilot carries two localization surfaces: `Localizable.xcstrings`, and the Swift fallback tables
in `TokenPilotLocalization.swift`. Counting keys in each, per language:

| Surface | en | ja | ko | zh-Hans | zh-Hant |
|---|---|---|---|---|---|
| String catalog (before) | 747 | 747 | 747 | 747 | **135** |
| Compiled `.lproj` in an Xcode build (before) | 746 | 746 | 746 | 746 | **135** |
| Compiled `.lproj` in an Xcode build (after) | 746 | 746 | 746 | 746 | **746** |

The Swift tables were the healthy surface: 602 supplemental entries carrying all five languages plus
308–423 per language, with one or two English-only keys each.

## 1. The catalog the shipped app carries cannot be read from it

`build.sh` copies the SwiftPM resource bundle into the app and then verifies the catalog arrived:

```
if [[ ! -f "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME/Localizable.xcstrings" ]]; then
```

That check passes. The file is there. It is one level down inside `TokenMonitor_TokenApp.bundle`,
and `url(forResource:)` does not descend into a nested bundle — which is the only place the loader
looked. Probed against the real bundle:

```
app bundle loaded: TokenPilot.app
  url(forResource: Localizable, xcstrings) -> nil
nested bundle loaded
  url(forResource:) -> …/TokenMonitor_TokenApp.bundle/Localizable.xcstrings
```

So a build step verified presence, not reachability, and would have passed just as happily on an
empty catalog. Every string in the Developer ID app came from the fallback tables instead. The
tables are complete, so nothing looked wrong.

## 2. The two builds localized differently

Xcode does not ship the catalog as a file; it compiles it into `.lproj` folders in
`Contents/Resources`, where `Bundle.main` finds it. So the Xcode-built app read the catalog, the
`build.sh`-built app read the tables, and where the two disagreed the same app said different things.

They disagreed in fourteen places, in four languages. `Weekly window` was in the catalog **twice**
with different Korean — JSON keeps one of two entries silently, Xcode kept `주간 창`, and the tables
said `주간 윈도우`.

Each divergence was resolved by picking the better string rather than defaulting to either surface:
`주간 창` matches the app's own `5시간 창` / `월간 창`; `TokenPilot` keeps its Latin spelling and its
surrounding spaces in Japanese; `Last updated` in Korean is `마지막 업데이트`, not `업데이트`; and
`수동 한도 힌트 fallback` had an untranslated English word in the middle of a Korean sentence.

## 3. Traditional Chinese was a fifth of the app

135 of 747 keys, against 747 for every other language — and the shape of the failure is why it went
unnoticed for so long. Both halves of the catalog lookup answered in **English** when the requested
language was missing:

```swift
if langCode != "en", let fallback = xcstringsCatalog["en"], let value = fallback[key] { return value }
```

English is filled in for every key, so this always succeeds, and the translation tables below were
never reached. Reproduced against the real Xcode build, before the fix:

```
Overview | zh-Hant -> Overview | zh-Hans -> 概览
History  | zh-Hant -> History  | zh-Hans -> 历史
Settings | zh-Hant -> Settings | zh-Hans -> 设置
```

Correct Traditional Chinese for all three was sitting in the tables the whole time. 599 strings were
translated and unreachable; 12 had no Traditional anywhere.

The generic-bundle half had the same shape and a second problem: a bundle that is not
language-specific resolves in whatever language the *system* prefers, which is the wrong answer for
someone reading the app in one language and running macOS in another.

A third copy of the shape sat one level further down, in the shared table
(`values[language] ?? values[.en]`). It never fired, because all 602 rows happen to carry all five
languages — but nothing required them to, so a half-filled row would have skipped the per-language
table that covers it. Removed, and the completeness it relied on is now asserted.

## 4. The shipped app told macOS it was English-only

`Bundle.localizations`, read from the two real builds:

```
build.sh     localizations: ["en"]
xcode build  localizations: ["en", "ja", "ko", "zh-Hans", "zh-Hant"]
```

macOS infers what an app speaks from its `.lproj` folders, and the Developer ID artifact has none —
its translations arrive as a catalog. So the app offered no per-app language override and would have
listed one language wherever the system asks. `CFBundleLocalizations` now declares the five, and a
test asserts the declaration against `TokenPilotLanguage` so a sixth language cannot be added in only
one of the two places.

## What changed

- The loader looks inside the SwiftPM resource bundle, by name. Matching by name rather than
  scanning for `.bundle` children means a neighbouring app's catalog can never be picked up, and the
  name is asserted equal to `build.sh`'s so a rename cannot quietly break it again.
- Neither half of the catalog lookup answers in English for another language. A missing translation
  falls through to the tables, and English is only the last resort.
- The catalog is complete: 746 keys × 5 languages, no duplicate key, no empty value. 599 Traditional
  Chinese strings came from the tables unchanged, 12 were written for this pass in the vocabulary the
  existing 900 already use (`數據源`, `檢測`, `啓用`), not a Taiwan register the rest of the app does
  not speak.
- The fourteen divergences are resolved on both surfaces, so making the catalog readable changes no
  copy anyone was already seeing.

Checked separately, and clean: 0 of 900 Traditional values contain a Simplified-only character,
tested by running each through `Simplified-Traditional` and comparing.

## Guards, and the one that did not hold

Twelve tests in `LocalizationSurfaceTests`. Each was verified by reintroducing the defect and
watching it fail, which is the only reason to trust it:

| Guard | Broken by | Result |
|---|---|---|
| Catalog found where the app keeps it | removing the nested search | fails |
| A catalog-only string is served | removing the nested search | fails — returns the raw key |
| Every string in all five languages | deleting one `zh-Hant` block | fails, naming the key |
| No key declared twice | duplicating an entry | fails, naming the key |
| The two surfaces agree | changing one Korean value | fails, naming key and language |
| Catalog never answers in English | restoring the short-circuit | fails |
| `.lproj` never borrows English | restoring the short-circuit | fails |
| Shared table complete in five languages | — | asserted per row |
| Bundle name matches `build.sh` | — | asserted directly |
| `Info.plist` declares what the enum offers | — | asserted directly |

The eighth attempt at the fall-through guard **passed with the bug reintroduced**. It asked about a
key that is in no catalog at all, so the English short-circuit it was meant to catch never ran. The
lookup was split into two pure functions and given a synthesized catalog and a synthesized `.lproj`
pair, and both now fail on the real shape — a `zh-Hant` bundle missing `Overview` while `en` has it.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **827 tests, 0 failures** (815 at
  the start of this pass).
- Xcode build re-run: `zh-Hant.lproj` went from 135 keys to 746, and `Overview` resolves to `概覽`.
- `build.sh` bundle rebuilt and the app relaunched, no crash report. Read back from the shipped
  bundle: five declared localizations, 746 catalog keys, `Overview → 概覽`.
- `make security-scan`: no leaks, history and worktree.
- `TokenPilot.xcodeproj` regenerated — the committed copy was missing `CapacityAlertCatalogue.swift`
  and `CapacityAlertReconciler.swift` from the previous pass. CI regenerates before building, so it
  was never broken there, only stale in the tree.
