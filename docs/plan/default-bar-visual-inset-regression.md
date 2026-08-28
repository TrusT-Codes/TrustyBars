# Default bar visual-inset feature: disabled after live regression

Status: **disabled, needs live-client re-diagnosis** (root cause not yet
understood - see below).

## What happened

The v1.0 polish pass added `BTV:GetElementVisualInset` (`Core.lua`) to make
default bars' (id 1-5) edit-mode overlay and drag-snap boxes match their
*visible* border extent instead of their bare frame - since `Button.lua`'s
`self.border` texture is drawn at `BTV.BORDER_RATIO` (66/36) of the button
size, overhanging the frame on every side.

Live-client testing found this made things considerably worse than the
original bug it was meant to fix:

- The edit-mode blue overlay for default bars became "way too big" -
  much larger than the border area itself, not just slightly bigger than
  the bare button/icon area it replaced.
- Snapping default bars to each other, or to Extra Bars, became
  effectively unusable ("impossible to align").
- This was confirmed to already happen on `main` (i.e. in the original
  commit that introduced this, before any of the later codebase-cleanup
  pass) - it is not a regression introduced by the cleanup work.

## Why it's confusing

The inset formula itself, evaluated on paper, only produces a modest
result: `buttonSize * (BTV.BORDER_RATIO - 1) / 2` is `~15px` for the
default 36px button, and at most `~27px` even at the addon's maximum
allowed button size (64px, `Settings.lua`'s `BUTTON_SIZE_MAX`). That's
consistent with "a bit bigger than the border," not "way bigger than the
border area." The diff between "border-accurate" (intended) and "way too
big" (reported) doesn't obviously fall out of this formula alone - a
plain re-read of `Core.lua`'s `GetElementVisualInset`, `Bar.lua`'s
`EnsureBarOverlay`, and `DefaultBars.lua`'s `ApplyDragSnap` (the three
places this value is used) didn't turn up an obvious sign error, unit
mismatch, or double-application bug either.

Plausible directions for the real cause, none confirmed:

- The inset may be getting applied per-button somewhere it should only
  apply once per bar (or vice versa), effectively multiplying by the
  bar's column/row count.
- `frame.config.buttonSize` might not hold what's assumed at the point
  `EnsureBarOverlay` runs for some bar configurations.
- The overlay's inflated box might be interacting with something else
  entirely (frame strata, a stale cached overlay from before a resize,
  scale double-application between `bar` and `overlay`).

## Current state

`BTV:GetElementVisualInset` (`Core.lua`) now unconditionally returns `0`,
which makes every call site that consumes it (`Core.lua`'s
`GetRealScreenBounds`/`GetAllSnapTargetBoxes`, `DefaultBars.lua`'s
`ApplyDragSnap`, `Bar.lua`'s `EnsureBarOverlay`) a no-op - default bars are
back to plain frame-flush overlay/snap behavior, exactly as before this
feature was ever added. All the plumbing (the optional `inset` parameter
on `GetRealScreenBounds`, the inflate/deflate math in `ApplyDragSnap`, the
conditional `SetPoint` vs. `SetAllPoints` branch in `EnsureBarOverlay`) is
left in place so re-enabling this is a one-line change once the actual
bug is found.

**UPDATE (live-tested):** confirmed disabled state now behaves like the
pre-feature baseline - the overlay is flush with the bar frame again and
default-bar dragging/snapping works. So the fix so far is confirmed
correct; what's still open is only the eventual re-enable/re-tune.

## What to do once a live client is available

Run `/btv diag2` (bar 1) or `/btv diag2 <id>` for another default bar
(id 2-5). This client caps a `/run` command at 511 characters including
the leading `/run `, too short for a useful multi-line dump - so this is
wired up as a permanent-until-resolved `BTV:DiagDefaultBarInset(id)`
function (`Core.lua`, alongside `diag1`/`diag3`, see that file's comment
for the temporary-code note). It prints:

- the bar frame's own `L/R/T/B`
- button 1's `.border` texture's `L/R/T/B`
- button 1's `.icon` texture's `L/R/T/B` (useful for the separate
  icon/border gap issue below too)
- what the old formula (`buttonSize * (BORDER_RATIO - 1) / 2`) would
  compute
- what `BTV:GetElementVisualInset` actually returns right now (`0`)

1. Compare the bar's `L/R/T/B` against button 1's `.border` `L/R/T/B` -
   this tells you the REAL overhang in real numbers, to check against the
   "formula inset would be" line. If they don't roughly match (border
   overhang per side ≈ formula's inset value), the bug is in how
   `EnsureBarOverlay`/`ApplyDragSnap` apply the inset, not the formula
   itself. If they DO roughly match, the bug is likely elsewhere (overlay
   overlapping with a neighboring element, a stale cached overlay from
   before a resize, etc.) - re-enable `GetElementVisualInset` for a single
   bar and directly compare `overlay:GetLeft()/GetRight()/GetTop()/GetBottom()`
   against `bar`'s and the formula's expected values to pin down exactly
   where the discrepancy appears.
2. Fix the root cause once found.

## Separately confirmed live: icon/border gap on left and bottom

Live-tested screenshot confirms a persistent ~1-2px gap between the icon
and the border texture on the LEFT and BOTTOM edges specifically (not
top/right) - independent of the regression above (this predates it).
`Button.lua`'s icon inset (`iconInset = 2`, both anchors symmetric) and
the border's anchor (`CENTER`, `x=0, y=-1`) don't obviously explain an
asymmetric left+bottom-only gap from source alone: the icon inset is
uniform on all 4 sides, and the border's `y=-1` offset (if anything) very
slightly *reduces* bottom overhang and *increases* top overhang by
shifting the whole texture down - the opposite direction from what's
reported. This suggests either the border texture asset
(`Interface\Buttons\UI-Quickslot2`) isn't pixel-symmetric within its own
66x66 canvas, or a pixel-rounding/scale artifact from not using
`PixelUtil`-based anchoring for the border/icon (this addon already wraps
`PixelUtil` as `PixelSetPoint`/`PixelSetSize` elsewhere, e.g.
`DefaultBars.lua`, but `Button.lua`'s icon/border use bare `SetPoint`).

**Do not guess a pixel-offset fix blind.** Run `/btv diag2` and report the
four `.icon` vs `.border` deltas on each side (left/right/top/bottom) -
with exact numbers, the fix is either a precise compensation constant or
confirms switching to `PixelUtil`/`PixelSetPoint` resolves it outright,
rather than a guessed nudge that might fix one client's rounding and break
another's.

## Separately reported, pre-existing (not caused by this feature)

The same live-test pass also reported Micro Menu's and Page Indicator's
edit-mode overlay boxes as wrong (Micro Menu too big on top, Page
Indicator too small) - these are chain-anchored containers
(`DefaultBars.lua`'s `BuildChainAnchoredContainer`/`ApplyChainAnchoredShape`),
whose sizing is untouched by `GetElementVisualInset` (it returns `0` for
them both before and after this regression). A static read of
`BuildChainAnchoredContainer`/`ApplyChainAnchoredShape` didn't turn up an
obvious bug (height is computed as `max()` of each button's real
`GetHeight()` for horizontal chains, which is the standard/correct
approach) - this needs live measurement rather than a blind fix, per this
repo's "capture, don't guess" convention.

Run `/btv diag3` in-game for this - prints each Micro Menu button's
`shown`/`L`/`T`/`W`/`H`, the `microMenuContainer`'s own `L/R/T/B`, the
Page Indicator's three wrapped native frames'
(`ActionBarUpButton`/`ActionBarDownButton`/`MainMenuBarPageNumber`) sizes,
and `pageIndicatorContainer`'s own `L/R/T/B` (`BTV:DiagMicroMenuPageIndicator`,
`Core.lua`, alongside `diag1`/`diag2`). Compare these against what the
blue overlay box actually looks like in Edit Layout Mode - a screenshot
alongside the printed numbers is the fastest way to see the mismatch.
