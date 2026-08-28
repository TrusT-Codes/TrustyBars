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

## What to do once a live client is available

1. In-game, enter Edit Layout Mode with a single default bar and use
   `/run` to print `BTV:GetElementVisualInset(BTV.bars[1])` (or whichever
   bar id) directly, and compare it against that bar's actual
   `GetWidth()`/`GetHeight()` and its buttons' `buttonSize`. This isolates
   whether the *formula's output* is actually the huge number it appears
   to be, or whether the bug is downstream in how that number gets
   applied.
2. If the formula's output is small (as the paper math suggests) but the
   overlay is still huge, temporarily re-enable it for a single bar and
   inspect `overlay:GetLeft()/GetRight()/GetTop()/GetBottom()` directly
   against `bar:GetLeft()/...` to see exactly how large the actual
   discrepancy is and in which direction.
3. Fix the root cause, then also fix the small cosmetic issue noted by
   the same live-test pass: default bars have a persistent ~1-2px gap
   between the icon and the border on the left/bottom that the border
   texture doesn't cover (independent of this regression - likely a
   separate pixel-rounding or texture-art-asymmetry issue, needs its own
   live investigation before touching `Button.lua`'s icon inset or
   border anchor code blindly).

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
approach) - this needs live measurement (print each Micro Menu button's
real `GetTop()/GetBottom()/GetHeight()` before/after reparenting, and the
Page Indicator's real native bounds) rather than a blind fix, per this
repo's "capture, don't guess" convention.
