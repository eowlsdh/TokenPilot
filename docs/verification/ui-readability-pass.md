# UI pass: screen length, type scale, and menu bar legibility

**Date:** 2026-08-20

**Scope:** Closes the remaining UI/UX findings from the design review
(`docs/verification/design-review-followup-thresholds-dates-contrast.md` covered the first three).
The complaint this pass answers: screens were too long to scan and text was too small to read.

## 1. Screens were too long

| Screen | Before | After |
|---|---|---|
| History | 17 cards stacked flat under 2 headers | Summary card, 3 collapsible groups (Trends / Efficiency / Breakdown) with counts, export card |
| Overview | Up to 5 optional cards between the summary and the provider rows | Summary → **provider capacity rows** → one collapsed **Activity** group → alerts |
| Settings | `General → 1 → 2 → Privacy → 3 → 4 → 5 → 6` | No numbers; ordered most-used first (Source Health, Setup Guide, Notifications, Telegram, Discord, General, Language, Privacy) |

`CollapsibleSection` (`Sources/TokenApp/Views/Components.swift`) is a header-only disclosure — no card
chrome of its own, so grouped cards keep their own surface instead of nesting a card in a card. Each
header carries a count badge, so a collapsed group never hides its weight, and it is a real
accessibility header with an expanded/collapsed value and a hint.

The Overview daily-goal card also stopped rendering unconditionally: it appears once there is
activity today or a target the user actually changed.

## 2. Text was too small

macOS `.caption` and `.caption2` are both **10pt**, while the design system's `Typography.caption`
is 11pt — so the same role rendered at two sizes, and Settings used the raw 10pt fonts 128 times
against 3 token uses.

- New `Typography.explanation` (11pt regular) for multi-line copy; 64 `.caption2` sites in Settings
  moved onto it, and the remaining 64 raw caption calls moved onto `Typography.caption`. Settings now
  has **zero** raw caption fonts.
- New `Typography.axis` (9pt) replaced the 7pt and 8pt chart tick and heatmap month labels.
- New `Typography.chipGlyph` (9pt) replaced 8pt chip glyphs.
- No sub-9pt text remains in any screen.

### Menu bar

The provider label was 7pt — roughly half the size of macOS's own menu bar text. The bar is 22pt and
the block already used all of it (9pt title row + 13pt value row), so the fix was to stop reserving
descender space the uppercase labels never use: the title row is now `ceil(ascender)`, which pays for
an **8pt semibold label and an 11pt bold value in 21pt total**.

A marker legend (`E experimental · M manual · S stale · — no value yet`) now sits under the live menu
bar preview in Settings, so the single-letter suffixes are explained somewhere in the product.

## 3. Consistency

- Card padding was 10 / 12 / 14 across neighbouring cards; there are now two named steps,
  `cardPadding` (14) and `cardPaddingCompact` (12).
- Spacing values 2, 5, 7, 8, 10 were off the scale (3/4/6/9/11/12/14); all call sites in the four view
  files now use scale tokens.
- Radii 7 and 9 were off the scale; `Radius.xxs` (2) was added for progress fills and every literal
  now resolves to a token.

## 4. Contrast

A new test reads the palette out of `TokenPilotDesign.swift` and asserts 4.5:1 for every provider
accent and status color. It found four more failures, all fixed:

| Token | Before (light, on card) | After |
|---|---|---|
| Claude accent | 4.24 | 5.31 |
| Codex accent | 4.78 | 5.45 |
| JetBrains accent | 4.01 | 5.31 |
| MiniMax accent | 3.91 | 5.25 |
| warning | 4.79 (4.16 on muted) | 5.32 (4.63 on muted) |

All 12 provider accents now measure 4.91–11.16:1 in light appearance.

## 5. Accessibility

- Twelve "Check Connection" buttons announced only "Check Connection" to VoiceOver; each now carries
  its provider name, and the setup-guide cards' primary action carries its card title.
- Section and row titles gained `minimumScaleFactor(0.85)` so longer Korean, Japanese, and Chinese
  titles shrink instead of clipping.

**Correction to the review:** the 24×24pt frames it flagged as small click targets are decorative —
an icon container, a 4pt status dot, and an empty-state glyph. A sweep for interactive controls under
28pt found none, so no hit-target change was needed.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `make bundle` signed; app relaunched and
  refreshing.
- `swift test`: 701 tests, 0 failures (699 before this pass).
- New: provider-accent and status-color contrast guards; updated the section-order test to the new
  Settings composition and the absence of the numbered titles.
- Localization: 7 new strings (Trends, Efficiency, Breakdown, Activity, the disclosure hint, Source
  Health, the marker legend) in both the catalog and the Swift fallback across en/ko/ja/zh-Hans/zh-Hant.

## App Store posture (unchanged, re-checked)

`Resources/TokenPilot-AppStore.entitlements` carries app-sandbox with user-selected read-only files
and network client; `Info.plist` sets `LSUIElement`, the utilities category, and copyright;
`PrivacyInfo.xcprivacy` ships in the bundle. Nothing in this pass touched entitlements, sandboxing,
or the privacy manifest.

## Not covered

- Visual QA on the real screens is the user's to do; this pass is compile- and test-verified.
- The `.system(size:)` metric fonts (10–14pt) still sit inline rather than in tokens; they are all on
  the scale and legible.
