# Design audit, and what raising the floor to macOS 26 actually cost

**Date:** 2026-08-21

## What the audit found — and what it did not

Measured rather than eyeballed, across the four view files and the design system:

| Checked | Result |
|---|---|
| Hardcoded colors in views | **0**. The only direct color is `NSColor.labelColor` in the menu bar, which is the correct system semantic |
| Dark mode | Complete. `SemanticColorDefinition` pairs light/dark and adds increased-contrast variants |
| Contrast | 4.5:1 enforced by four tests over text tokens, provider accents, and status colors |
| Empty / loading / error | All three exist — `EmptyStateCard` ×6, `ProgressView` ×3, banner ×4, `isRefreshing` wired |
| Click targets | No violation. The four 24×24 frames were opened and are decorative icon containers, two of them `accessibilityHidden` |
| zh-Hant | Complete at runtime; the catalog's gaps are covered by the Swift fallback table |
| Spacing literals | 22 remaining against 237 token uses — six of them (7, 10, 16) off the scale entirely |
| Popover size | Written out at **four** call sites |
| Inline fonts | 29 `.system(size:)` calls in views |

Two findings had to be corrected mid-audit, which is worth recording because both would have
produced worse code than doing nothing:

**The typography finding was wrong as first stated.** "29 sites bypass existing tokens" implied a
mechanical substitution. Reading the actual attributes showed they were reaching for *combinations
the ramp did not cover* — `.system(size: 16, weight: .semibold)` is not `appTitle`, which is 16
semibold **rounded**. Substituting into the nearest token would have changed how the app looks while
claiming to be a no-op. Three tokens now cover the recurring combinations (`metricCompact`,
`metricSmall`, `captionStrong`) and 17 sites moved onto them. The remaining 12 are genuine one-offs;
12 tokens for 12 sites would leave the ramp worse than the literals do.

**Dynamic Type was raised as S1 and withdrawn.** macOS has no system-wide equivalent — its
Accessibility text size applies only to apps that opt in — so converting 13 tokens to `relativeTo:`
would have risked layout regressions in exchange for a setting the platform does not broadly expose.
The app already handles what macOS *does* expose: reduce transparency (9 sites), reduce motion (33),
increased contrast (27), colour differentiation (4), behind 119 accessibility labels.

## The floor was in three places holding two values

`Package.swift` said 13, `project.yml` said 14, and `build.sh` wrote 14 as a literal while
`Info.plist` read the build setting. A package that builds for Macs the app refuses to launch on is
a bug only a user finds. There is now one declaration, in `project.yml`; `Package.swift` states it as
`.macOS("26.0")` — the string form, because this toolchain's `PackageDescription` has no `.v26` case
— and `build.sh` reads it and fails the build if it is missing. Two tests pin that the spellings
agree and that the script reads rather than restates.

## Raising to 26 broke CI, silently

The workflow ran on `macos-15` pinned to Xcode 16.2, whose SDK is macOS 15. A deployment target above
the SDK does not build, so the first push would have failed on a step unrelated to what it was
testing. It now runs on `macos-26`, and the Xcode pin was **removed rather than bumped**: a
hardcoded `/Applications/Xcode_16.2.app` breaks whenever the runner image renames a version, and
fails with a missing-directory message that explains nothing. The step selects the newest installed
Xcode, prints the SDK, reads the floor from `project.yml`, and fails explicitly when the SDK is
older. Verified locally — extraction yields `26`, the comparison passes against SDK 26.5, the YAML
parses.

## Documentation was describing a different product

Three drifts, all of which a buyer would have hit:

- **No README stated a system requirement at all**, and the platform badge still said macOS 14. With
  a 26 floor that is not cosmetic: someone on macOS 15 downloads an app that cannot launch, warned by
  nothing. All four READMEs now say it, and the store listing carries it as an availability note.
- **JetBrains, MiniMax, Z.ai, and OpenRouter appeared zero times** in either README while being fully
  wired providers — and the store listing claims twelve, so the two documents would have contradicted
  each other in front of a buyer.
- **`stats`, `report`, `audit`, and `blocks` were undocumented**, and the daily goal removed the day
  before was still in the feature table. Both READMEs also counted four languages; the app ships five.

## Not done, and why

- **Liquid Glass.** `GlassCard` already hand-rolls it — `.regularMaterial` plus tint, highlight, and
  stroke, with a `reduceTransparency` fallback. On macOS 26 `glassEffect` would replace that
  natively, but the swap restyles every card in the app. That is a visual decision, not a cleanup,
  and it belongs in its own change with someone looking at the screen.
- **Icon Composer.** The icon is still a legacy `AppIcon.appiconset` / `.icns`. It renders correctly
  on macOS 26 but does not get the layered treatment. Producing a `.icon` needs the Icon Composer
  GUI, which cannot be driven from here.
- **The menu bar block.** `ProviderMetricsMenuBarNSView` draws directly into an `NSView`, so it is
  unaffected by the system's new appearance — which is both why it is safe and why it may end up
  looking unlike its neighbours. It fits 8pt label + 11pt value into 21pt of a 22pt bar, with no
  slack, and it is the app's signature. Not to be touched without looking at the real bar.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **768 tests, 0 failures**.
- `xcodebuild` at macOS 26 succeeded; `xcodegen generate` regenerated cleanly.
- Bundle reports version 1.0.0 (1), `LSMinimumSystemVersion 26.0`, `LSUIElement`, the right bundle
  identifier, all three required resources, signed with a real Team ID.
- The sandboxed App Store configuration also builds at the new floor with app-sandbox,
  user-selected read-only files, and network client intact; the Developer ID build was restored
  afterwards and relaunched.
