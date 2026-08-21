# Liquid Glass: from four stacked fills to the system effect

**Date:** 2026-08-21

The app hand-rolled Liquid Glass because macOS did not have it. macOS 26 does. This records the
conversion, what was measured before each decision, and the two places where the obvious move turned
out to be wrong.

## What it was

`LiquidGlassBackground` — the single view every card in the app sits on — stacked four fills:

```swift
shape.fill(.regularMaterial)
shape.fill(palette.glassTint.opacity(0.75 * intensity))
shape.fill(palette.surface(surface).opacity(0.46...0.76))
shape.fill(palette.glassHighlight.opacity(0.14))
```

Hand-tuned opacity ramps cannot sample what is behind the view, react to motion or lighting, or carry
the system's edge treatment. `glassEffect` does all three.

## How this was verified at all

Two findings shaped the method:

- **`glassEffect` renders as nothing in `ImageRenderer`.** The first harness rendered the surfaces
  offscreen and produced a picture with one card in it and three blank spaces — the effect samples a
  real backdrop and there is none offscreen. Every comparison here is therefore a real `NSWindow`,
  captured with `screencapture`.
- **A control renders inactive in a window that cannot become key.** The first button comparison
  showed every glass label greyed out and the tint missing, which read as a contrast failure. It was
  the harness: a `.borderless` window never becomes key. With `canBecomeKey` overridden, the same
  buttons rendered correctly. The rule from earlier this week held — when a result looks alarming,
  suspect the harness first.

## Cards

Measured over the app's **real** backgrounds, not a decorative gradient — that distinction reversed
the answer. Over a purple gradient, `.regular.tint(card)` looked closest to the old cards. Over the
app's actual near-black and near-white backgrounds, the tint produced **grey** cards in light
appearance, visibly worse than the white they replaced. Plain `.regular` was closest in both.

Two things were kept rather than handed to the system:

- **`reduceTransparency` still swaps in a flat opaque surface.** That setting means "no
  translucency", and the contrast guarantees in `DesignConsistencyTests` are computed against those
  opaque tokens.
- **The border stroke stays.** Glass supplies its own rim, but a card on a near-white background
  loses its edge without it — checked by rendering both.

The `intensity` parameter was removed rather than left ignored. It only ever scaled the opacity ramps
that no longer exist; keeping it would have been one more setting that does nothing.

## Buttons: the blanket swap was a regression

39 buttons. The obvious mapping — `.bordered` → `.glass`, `.borderedProminent` → `.glassProminent` —
is wrong for a third of them, and rendering it showed why:

**`.glass` takes a tint as its fill.** A `.bordered` button tinted with the app's danger colour reads
as a *secondary destructive* action: subtle background, red label. The same button as `.glass` becomes
a **solid red call to action**. "Delete Token" would have gone from a quiet button to the loudest
thing on the screen.

So the mapping is:

| Was | Becomes | Count |
|---|---|---|
| `.bordered`, untinted | `.glass` | 26 |
| `.bordered` with a tint | `.glass`, tint moved to `foregroundStyle` | 5 |
| `.borderedProminent` | `.glassProminent` | 8 |

Moving the tint to the label keeps the hierarchy the design already had: a neutral glass capsule with
a coloured label. Verified against the app's real `calm` and `danger` colours in both appearances.

## The popover backdrop stays an NSVisualEffectView

`glassEffect` samples what is inside the window. A menu bar popover has to blend with the **desktop**,
which is what `NSVisualEffectView(.sidebar, blendingMode: .behindWindow)` does — and on macOS 26 that
material is already the system's glass. Rendering the panel with and without the manual tint overlay
showed no meaningful difference, so it was left alone rather than churned.

## A landmine found by rendering it

`GlassEffectContainer` is the documented way to group glass elements. Wrapping the app's cards in one
produces **smeared, unreadable text**:

The cards apply glass as `.background { Color.clear.glassEffect(...) }`. Inside a container, that form
composites the card's own content into the sampling. Applying the effect to the content instead is
container-safe and renders crisply — but that is a different shape from the six other call sites, so
the change was not made. A guard fails if a container is added while the background form is in use,
which turns a silent visual bug into a test failure.

## Verification

- `swift build -Xswiftc -warnings-as-errors` clean; `swift test`: **861 tests, 0 failures**.
- Six new guards, each checked by reverting the change: putting one button back on `.bordered` names
  `SettingsScreen.swift:198`; restoring `.fill(.regularMaterial)` fails both card assertions; adding a
  `GlassEffectContainer` names the line.
- **Verified on the running app**, not only in a harness: the bundle was rebuilt, relaunched, and the
  popover opened and captured. Clicking and capturing had to happen inside one `osascript` — as
  separate steps the popover dismissed before the capture, which is why earlier attempts came back
  empty. The captured popover shows the converted cards, the segmented picker, and the glass capsule
  buttons, with text contrast intact and no layout breakage.
- `make security-scan`: no leaks.

## Not done

The six non-card call sites still use `LiquidGlassBackground` as a `.background`, which is why the
container question is deferred rather than settled. Converting `GlassCard` to apply the effect to its
content would close that, and it should be done as its own change with its own before-and-after
capture.
